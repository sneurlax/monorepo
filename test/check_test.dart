import 'dart:io';

import 'package:monorepo/src/check/coverage.dart';
import 'package:monorepo/src/check/shell.dart';
import 'package:monorepo/src/check/workflows.dart';
import 'package:monorepo/src/config.dart';
import 'package:monorepo/src/model.dart';
import 'package:monorepo/src/ownership.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('shell subset', () {
    test('tracks subshell cd without leaking it to siblings', () {
      final commands = parseShell(
        '(cd packages/a && dart test) && (cd packages/b && flutter test)\ndart analyze',
      );
      expect(commands.map((c) => '${c.cwd}:${c.argv.join(' ')}'), [
        '.:cd packages/a',
        'packages/a:dart test',
        '.:cd packages/b',
        'packages/b:flutter test',
        '.:dart analyze',
      ]);
    });

    test('bare cd affects following commands in a chain', () {
      final commands = parseShell(
        'cd packages/a; dart test\ncd ../b && dart analyze',
      );
      expect(commands.last.cwd, 'packages/b');
      expect(commands[1].cwd, 'packages/a');
    });

    test('expands literal single-level loop and quoted variable', () {
      final commands = parseShell(
        r'for package in packages/a packages/b; do (cd "$package" && dart analyze --fatal-infos); done',
      );
      expect(commands.where((c) => c.argv.first == 'dart').map((c) => c.cwd), [
        'packages/a',
        'packages/b',
      ]);
      expect(commands.where((c) => c.warning != null), isEmpty);
    });

    test('expands braced variable while preserving unrelated variable', () {
      final commands = parseShell(
        r'for package in a b; do (cd "${package}" && dart test "$OTHER"); done',
      );
      expect(commands.last.cwd, 'b');
      expect(commands.last.argv.last, r'$OTHER');
    });

    test('warns on dynamic and nested loops without inferring bodies', () {
      final dynamic = parseShell(
        r'for package in $PACKAGES; do dart test; done',
      );
      expect(dynamic.single.warning, contains('Unsupported shell loop'));
      final nested = parseShell(
        'for a in x; do for b in y; do dart test; done; done',
      );
      expect(nested.single.warning, contains('Unsupported shell loop'));
    });

    test('strips timeout env assignments xvfb and global-run wrappers', () {
      final commands = parseShell(r'''
timeout --signal=TERM --kill-after=30s 10m dart test
env KEEP=1 SOUND_DART_LIB="$ROOT/lib.so" dart test test/a_test.dart
xvfb-run --auto-servernum flutter test integration_test -d linux
timeout -s TERM -k 30s 15m dart pub global run melos run test:ci
''');
      expect(commands.map((c) => c.argv), [
        ['dart', 'test'],
        ['dart', 'test', 'test/a_test.dart'],
        ['flutter', 'test', 'integration_test', '-d', 'linux'],
        ['melos', 'run', 'test:ci'],
      ]);
    });

    test('keeps quoted shell operators and command substitutions in words', () {
      final commands = parseShell(
        r'''SOUND_DART_LIB="$(find build -name lib.so)" dart test 'test/a; b_test.dart' && echo "x && y"''',
      );
      expect(commands.first.argv, ['dart', 'test', 'test/a; b_test.dart']);
      expect(commands.last.argv, ['echo', 'x && y']);
    });

    test('does not parse heredoc bodies as commands', () {
      final commands = parseShell(
        'python3 - <<\'PY\'\ndart test missing/test\nPY\ndart analyze .',
      );
      expect(commands.where((c) => c.argv.first == 'dart').single.argv, [
        'dart',
        'analyze',
        '.',
      ]);
    });

    test(
      'here-string does not swallow subsequent commands and redirections are stripped',
      () {
        final commands = parseShell(
          'cat <<<"EOF"\ndart test packages/a 2>&1 > /tmp/out.log\n',
        );
        expect(commands.where((c) => c.argv.first == 'dart').single.argv, [
          'dart',
          'test',
          'packages/a',
        ]);
      },
    );

    test('handles multiline continuations', () {
      final commands = parseShell(
        'dart format --output none \\\n --set-exit-if-changed packages/a/lib\n',
      );
      expect(commands.single.argv, [
        'dart',
        'format',
        '--output',
        'none',
        '--set-exit-if-changed',
        'packages/a/lib',
      ]);
    });

    test('recurses literal sh -c without leaking its cd', () {
      final commands = parseShell(
        'timeout 10m sh -c \'(cd a && dart test) && (cd b && dart test)\'\ndart analyze .',
      );
      expect(commands.where((c) => c.argv.first == 'dart').map((c) => c.cwd), [
        'a',
        'b',
        '.',
      ]);
    });
  });

  group('workflow extraction', () {
    late Directory fixture;
    setUp(
      () => fixture = Directory.systemTemp.createTempSync('monorepo-check-'),
    );
    tearDown(() => fixture.deleteSync(recursive: true));

    void write(String path, String text) {
      final file = File(p.join(fixture.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    test(
      'inherits defaults with step precedence and strips own checkout prefix',
      () {
        write('.github/workflows/ci.yaml', '''
defaults:
  run:
    working-directory: Project/packages/a
jobs:
  first:
    defaults:
      run:
        working-directory: Project/packages/b
    steps:
      - uses: actions/checkout@v4
        with: {path: Project}
      - uses: actions/checkout@v4
        with: {path: Other, repository: example/other}
      - run: dart test
      - run: dart analyze
        working-directory: Project/packages/c
  second:
    steps:
      - uses: actions/checkout@v4
        with: {path: Project}
      - run: dart analyze
''');
        final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
        expect(steps.map((s) => s.workingDirectory), [
          'packages/b',
          'packages/c',
          'packages/a',
        ]);
        expect(steps.first.line, 14);
      },
    );

    test(
      'folded and literal YAML retain shell commands and mark matrix context',
      () {
        write('.github/workflows/ci.yml', r'''
jobs:
  verify:
    steps:
      - run: >-
          dart format --output none
          packages/a/lib
      - run: |
          dart analyze .
          dart test packages/a
      - run: dart test
        working-directory: ${{ matrix.package }}
''');
        final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
        expect(steps[0].run, 'dart format --output none packages/a/lib');
        expect(steps[0].line, 5);
        expect(steps[1].run, contains('\ndart test'));
        expect(steps[2].dynamicContext, isTrue);
      },
    );

    test('invalid workflow yaml is an environment error', () {
      write('.github/workflows/ci.yml', 'jobs: [unterminated');
      expect(
        () => readWorkflowSteps(fixture.path, ['.github/workflows']),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('coverage and stale paths', () {
    late Directory fixture;
    late Workspace workspace;
    late Map<String, OwnedFiles> ownership;
    void write(String path, [String text = '']) {
      final file = File(p.join(fixture.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('monorepo-coverage-');
      write('pubspec.yaml', 'name: root\n');
      final packages = <Package>[];
      for (final name in ['a', 'b']) {
        final path = 'packages/$name';
        write('$path/pubspec.yaml', 'name: $name\n');
        write('$path/lib/$name.dart');
        write('$path/test/${name}_test.dart');
        write('$path/test/other_test.dart');
        write('$path/Cargo.toml');
        packages.add(
          Package(
            name: name,
            path: p.join(fixture.path, path),
            relPath: path,
            hasTest: true,
          ),
        );
      }
      write('packages/b/example/pubspec.yaml', 'name: example\n');
      write('packages/b/example/lib/main.dart');
      write('packages/b/example/test/widget_test.dart');
      Directory(
        p.join(fixture.path, 'packages/b/example/integration_test'),
      ).createSync();
      packages.add(
        Package(
          name: 'example',
          path: p.join(fixture.path, 'packages/b/example'),
          relPath: 'packages/b/example',
          isFlutter: true,
          hasTest: true,
          hasIntegrationTest: true,
        ),
      );
      workspace = Workspace(root: fixture.path, packages: packages);
      ownership = collectOwnership(workspace, const Config());
    });
    tearDown(() => fixture.deleteSync(recursive: true));

    void workflow(String body, {String directory = '.'}) {
      write('.github/workflows/ci.yml', '''
jobs:
  check:
    steps:
      - working-directory: $directory
        run: |
${body.split('\n').map((line) => '          $line').join('\n')}
''');
    }

    CheckReport report([Config config = const Config()]) =>
        checkWorkspace(workspace, config, ownership);

    test('no CI reports all relevant members uncovered', () {
      final result = report();
      expect(result.errors.map((f) => f.package), ['a', 'b', 'example']);
      expect(result.warnings.where((f) => f.kind == 'analyze'), hasLength(3));
      expect(result.warnings.where((f) => f.kind == 'format'), hasLength(3));
      expect(result.toJson().keys, ['errors', 'warnings']);
      expect(result.renderHuman(), contains('3 error(s), 6 warning(s)'));
    });

    test(
      'root analysis and formatting cover all members but parent tests do not',
      () {
        workflow(
          'dart analyze .\ndart format --output none --set-exit-if-changed packages\ndart test packages/a\nflutter test packages/b/test',
        );
        final result = report();
        expect(result.errors.map((f) => f.package), ['example']);
        expect(result.warnings, isEmpty);
      },
    );

    test('subshell and loop test commands provide full coverage', () {
      workflow(
        'dart analyze .\ndart format packages\nfor package in packages/a packages/b packages/b/example; do (cd "\$package" && dart test); done',
      );
      expect(report().hasProblems(strict: true), isFalse);
    });

    test('format gaps include count and at most five sample files', () {
      for (var i = 0; i < 8; i++) {
        write('packages/a/lib/file$i.dart');
      }
      ownership = collectOwnership(workspace, const Config());
      workflow('dart format packages/a/test packages/b\ndart analyze .');
      final finding = report().warnings.singleWhere((f) => f.kind == 'format');
      expect(finding.package, 'a');
      expect(finding.message, contains('9 owned Dart file(s)'));
      expect(finding.message, contains('file3.dart'));
      expect(finding.message, isNot(contains('file4.dart')));
    });

    test('partial file test remains a gap unless another full run exists', () {
      workflow(
        'SOUND_DART_LIB="\$root/lib.so" dart test packages/a/test/a_test.dart',
      );
      var result = report();
      expect(
        result.warnings.where((f) => f.kind == 'partial-test').single.package,
        'a',
      );
      expect(result.warnings.where((f) => f.kind == 'unparsed'), isEmpty);
      workflow(
        'dart test packages/a/test/a_test.dart\n(cd packages/a && dart test)',
      );
      result = report();
      expect(result.errors.where((f) => f.package == 'a'), isEmpty);
      expect(result.warnings.where((f) => f.kind == 'partial-test'), isEmpty);
    });

    test('allow suppresses uncovered tests and partial warning', () {
      workflow('dart test packages/a/test/a_test.dart');
      final result = report(
        const Config(allow: [Allow('test', 'a', 'Explicit elsewhere')]),
      );
      expect(result.errors.where((f) => f.package == 'a'), isEmpty);
      expect(result.warnings.where((f) => f.kind == 'partial-test'), isEmpty);
    });

    test('integration tests never cover unit tests', () {
      workflow(
        'xvfb-run -a flutter test integration_test -d linux',
        directory: 'packages/b/example',
      );
      expect(
        report().errors.where((f) => f.kind == 'test').map((f) => f.package),
        ['a', 'b', 'example'],
      );
    });

    test('validates cd working-directory test and cargo manifest paths', () {
      workflow(
        'cd missing\ndart test test\ncargo test --manifest-path nowhere/Cargo.toml',
      );
      final result = report();
      expect(result.errors.where((f) => f.kind == 'stale-path'), hasLength(3));
      workflow('dart analyze', directory: 'nonexistent');
      expect(
        report().errors.where((f) => f.kind == 'stale-path').single.message,
        contains('working-directory'),
      );
    });

    test(
      'malformed static test input is an error even when package ignored',
      () {
        workflow('dart test packages/a/missing_test.dart');
        final result = report(const Config(ignore: ['a']));
        expect(
          result.errors.singleWhere((f) => f.kind == 'stale-path').package,
          'a',
        );
        expect(
          result.errors.where((f) => f.kind == 'test').map((f) => f.package),
          ['b', 'example'],
        );
      },
    );

    test('dynamic path and matrix working-directory warn without coverage', () {
      workflow(r'dart analyze "$PACKAGE"');
      var result = report();
      expect(result.warnings.where((f) => f.kind == 'unparsed'), hasLength(1));
      expect(result.warnings.where((f) => f.kind == 'analyze'), hasLength(3));
      workflow('dart test', directory: r'${{ matrix.package }}');
      result = report();
      expect(result.warnings.where((f) => f.kind == 'unparsed'), hasLength(1));
    });

    test(
      'unknown options warn rather than assigning their value as a path',
      () {
        workflow('dart test --unknown value packages/a');
        expect(
          report().warnings.where((f) => f.kind == 'unparsed'),
          hasLength(1),
        );
        expect(report().errors.where((f) => f.kind == 'stale-path'), isEmpty);
      },
    );

    test(
      'checks monorepo and legacy script paths without granting CI coverage',
      () {
        workspace = Workspace(
          root: fixture.path,
          packages: workspace.packages,
          pubspec: {
            'melos': {
              'scripts': {
                'test': {'run': 'flutter test packages/airdrop_flutter/test'},
              },
            },
          },
        );
        final result = report(
          const Config(
            scripts: {
              'native:test': Script(
                'cd packages/a && cargo test --manifest-path wrong/Cargo.toml',
              ),
            },
          ),
        );
        expect(
          result.errors.where((f) => f.kind == 'stale-path'),
          hasLength(2),
        );
        expect(result.errors.where((f) => f.kind == 'test'), hasLength(3));
      },
    );

    test('Melos is reported without claiming indirect coverage', () {
      workflow(
        'dart run melos run test\ntimeout 10m dart pub global run melos run analyze\ndart pub global activate melos',
      );
      final result = report();
      expect(result.warnings.where((f) => f.kind == 'melos'), hasLength(3));
      expect(result.errors.where((f) => f.kind == 'test'), hasLength(3));
    });

    test('check never executes script bodies', () {
      final sentinel = p.join(fixture.path, 'executed');
      workflow('touch "$sentinel"\ndart analyze .');
      report(Config(scripts: {'danger': Script('touch "$sentinel"')}));
      expect(File(sentinel).existsSync(), isFalse);
    });

    test('static shell wrapper and conditional setup preserve coverage', () {
      workflow(
        'timeout 10m sh -c \'(cd packages/a && if [ -f tool/fetch_web_test_assets.dart ]; then dart run tool/fetch_web_test_assets.dart || exit; fi; dart test -p chrome -j 1)\'',
      );
      expect(
        report().errors.where((f) => f.kind == 'test').map((f) => f.package),
        ['b', 'example'],
      );
    });

    test('strict changes warning-only result without mutating report', () {
      workflow(
        'dart test packages/a\ndart test packages/b\nflutter test packages/b/example',
      );
      final result = report();
      expect(result.hasProblems(), isFalse);
      expect(result.hasProblems(strict: true), isTrue);
      expect(result.errors, isEmpty);
    });

    test(
      'flutter test --coverage does not consume a single test file path as its value',
      () {
        workflow(
          'flutter test --coverage packages/b/example/test/widget_test.dart',
        );
        final result = report();
        expect(
          result.warnings.where((f) => f.kind == 'partial-test').single.package,
          'example',
        );
        expect(
          result.errors.where((f) => f.kind == 'test').map((f) => f.package),
          contains('example'),
        );
      },
    );

    test(
      'hidden dart files are not counted as covered by directory format commands',
      () {
        write('packages/a/lib/.hidden.dart');
        ownership = collectOwnership(workspace, const Config());
        workflow('dart format packages/a/lib packages/a/test packages/b');
        final finding = report().warnings.singleWhere(
          (f) => f.kind == 'format',
        );
        expect(finding.package, 'a');
        expect(finding.message, contains('packages/a/lib/.hidden.dart'));
      },
    );
  });
}

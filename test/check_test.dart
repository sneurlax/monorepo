import 'dart:io';

import 'package:monorepo/src/check/coverage.dart';
import 'package:monorepo/src/check/shell.dart';
import 'package:monorepo/src/check/workflows.dart';
import 'package:monorepo/src/config.dart';
import 'package:monorepo/src/model.dart';
import 'package:monorepo/src/ownership.dart';
import 'package:monorepo/src/planner.dart' show shellQuote;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

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

    test('dynamic loop bodies are uncertain and nested literal loops expand', () {
      final dynamic = parseShell(
        r'for package in $PACKAGES; do dart test; done; dart analyze',
      );
      expect(dynamic.map((c) => (c.argv.join(' '), c.uncertain)), [
        ('dart test', true),
        ('dart analyze', false),
      ]);
      expect(dynamic.where((c) => c.warning != null), isEmpty);
      final nested = parseShell(
        r'for a in x y; do for b in 1 2; do (cd "$a" && dart test "$b"); done; done',
      );
      expect(
        nested
            .where((c) => c.argv.first == 'dart')
            .map((c) => '${c.cwd}:${c.argv.last}:${c.uncertain}'),
        ['x:1:false', 'x:2:false', 'y:1:false', 'y:2:false'],
      );
    });

    test(
      'glob and substitution loops, while and until bodies are uncertain',
      () {
        final commands = parseShell(r'''
for f in scripts/verify_*.py; do python3 "$f"; done
for i in $(seq 1 3); do dart test; done
while dart analyze; do flutter test; done
until false; do cd packages/a; done
dart format .
''');
        expect(
          commands.map((c) => '${c.uncertain ? '?' : ' '}${c.argv.first}'),
          ['?python3', '?dart', ' dart', '?flutter', ' false', '?cd', ' dart'],
        );
        // A cd inside a body that may not run leaves the directory unknown.
        expect(commands.last.cwd, contains(r'$'));
      },
    );

    test('loops end at the done that matches their own keyword', () {
      final commands = parseShell(
        r'for p in a b; do while x; do y; done; (cd "$p" && dart test); done',
      );
      expect(commands.where((c) => c.argv.first == 'dart').map((c) => c.cwd), [
        'a',
        'b',
      ]);
    });

    test('expands known variables outside single quotes only', () {
      final commands = parseShell(
        r'''dart test "$PKG" ${PKG}/test '$PKG' \$PKG $OTHER''',
        environment: {'PKG': 'packages/a'},
      );
      expect(commands.single.argv, [
        'dart',
        'test',
        'packages/a',
        'packages/a/test',
        r'$PKG',
        r'$PKG',
        r'$OTHER',
      ]);
    });

    test('never expands names the script assigns or unsafe values', () {
      final commands = parseShell(
        'PKG=elsewhere\ndart test "\$PKG" "\$BAD"\nfor X in a; do echo \$X; done',
        environment: {'PKG': 'packages/a', 'BAD': 'a;b', 'X': 'z'},
      );
      expect(commands[0].argv, ['dart', 'test', r'$PKG', r'$BAD']);
      expect(commands[1].argv, ['echo', 'a']);
    });

    test('comment apostrophes do not hide later variables', () {
      final commands = parseShell(
        "# it's fine\ndart test \"\$PKG\"",
        environment: {'PKG': 'packages/a'},
      );
      expect(commands.single.argv.last, 'packages/a');
    });

    test('unquoted expansion splits loop words', () {
      final commands = parseShell(
        r'for t in $TARGETS; do (cd "$t" && dart test); done',
        environment: {'TARGETS': 'a b'},
      );
      expect(commands.where((c) => c.argv.first == 'dart').map((c) => c.cwd), [
        'a',
        'b',
      ]);
    });

    test('bash array literals are not subshells', () {
      final commands = parseShell(
        r'args=(); args+=(--target "$t"); dart run tool.dart "${args[@]}"',
      );
      expect(commands.map((c) => c.argv.first), ['dart']);
    });

    test('commands are recognized by basename', () {
      final commands = parseShell(r'"$SDK/bin/flutter" test packages/a');
      expect(commands.single.argv, ['flutter', 'test', 'packages/a']);
    });

    test('workspace and external markers rebase cd targets', () {
      final commands = parseShell(
        r'cd "$GITHUB_WORKSPACE/packages/a" && dart test; cd "$RUNNER_TEMP" && dart test',
        environment: {
          'GITHUB_WORKSPACE': workspaceMarker,
          'RUNNER_TEMP': '$externalMarker/temp',
        },
      );
      final dart = commands.where((c) => c.argv.first == 'dart').toList();
      expect(dart.first.cwd, 'packages/a');
      expect(isExternal(dart.last.cwd), isTrue);
      expect(rebasePath('..'), startsWith(externalMarker));
      // The default directory of a path checkout sits outside it, yet cd
      // back into the checkout lands on a member.
      final checkout = parseShell(
        'cd Repo/packages/a && dart test',
        cwd: workspaceMarker,
        root: '$workspaceMarker/Repo',
      );
      expect(isExternal(checkout.first.cwd), isTrue);
      expect(checkout.first.location, workspaceMarker);
      expect(checkout.last.cwd, 'packages/a');
      expect(
        parseShell(r'cd "$X" && cd .. && dart test').last.cwd,
        contains(r'$'),
      );
      expect(
        rebasePath('$workspaceMarker/Repo/x', root: '$workspaceMarker/Repo'),
        'x',
      );
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

    List<String> show(List<ShellCommand> commands) => [
      for (final c in commands)
        if (c.warning == null)
          '${c.uncertain ? '?' : ''}${c.cwd.contains(r'$') ? r'$' : c.cwd}:${c.argv.join(' ')}'
        else
          'warning:${c.warning}',
    ];

    test('names any builtin assigns or unsets are never substituted', () {
      const environment = {'PKG': 'packages/b'};
      expect(
        parseShell(
          'echo "\$PKG"\ncd "\$PKG"\ndart test',
          environment: environment,
        ).last.cwd,
        'packages/b',
      );
      for (final script in [
        "printf -v PKG '%s' packages/a",
        "printf -vPKG '%s' packages/a",
        'declare PKG=packages/a',
        'typeset -x PKG=packages/a',
        'f() { local PKG=packages/a; }',
        'unset PKG',
        'unset -v PKG',
        'let PKG=1',
        'let "PKG += 1"',
        'read -r PKG < file',
        'IFS= read -r -d "" PKG',
        'mapfile -t PKG < file',
        'readarray PKG < file',
        'getopts ab PKG',
        'declare -n REF=PKG; REF=packages/a',
        'typeset -n REF=PKG',
        ': "\${PKG:=packages/a}"',
        '(( PKG = 1 ))',
        'PKG[0]=packages/a',
      ]) {
        final commands = parseShell(
          '$script\ncd "\$PKG" && dart test',
          environment: environment,
        );
        expect(
          commands.lastWhere((c) => c.argv.first == 'dart').cwd,
          contains(r'$'),
          reason: script,
        );
      }
    });

    test('function bodies run only where they are called', () {
      expect(
        show(
          parseShell('test_b() { cd packages/b && dart test; }\necho defined'),
        ),
        ['.:echo defined', '?.:cd packages/b', '?packages/b:dart test'],
      );
      expect(
        parseShell(
          'test_b() { cd packages/b && dart test; }',
        ).last.uncertainReason,
        'inside a shell function that is never called',
      );
      // A definition changes nothing; the cd in its body is not run.
      expect(
        show(parseShell('go_b() { cd ../b; }\ndart test', cwd: 'packages/a')),
        ['packages/a:dart test', '?packages/a:cd ../b'],
      );
      expect(
        show(
          parseShell('''
function go_b {
  cd packages/b
}
go_b
dart test
run_a() ( cd packages/a; dart test )
run_a
dart analyze
function noop() { :; }
'''),
        ),
        [
          '.:cd packages/b',
          'packages/b:dart test',
          'packages/b:cd packages/a',
          'packages/b/packages/a:dart test',
          // A parenthesized body is a subshell; its cd does not persist.
          'packages/b:dart analyze',
          '?packages/b::',
        ],
      );
      expect(show(parseShell('f() { f; }\nf')), [
        'warning:Recursive shell function "f"; coverage is not inferred',
      ]);
      // Wrappers run executables, never shell functions.
      expect(show(parseShell('f() { cd a; }\ntimeout 5 f\ndart test')), [
        '.:f',
        '.:dart test',
        '?.:cd a',
      ]);
    });

    test('pushd, popd, cd - and env -C move or scope the directory', () {
      expect(
        show(
          parseShell('''
pushd packages/b && dart test && popd && dart analyze
cd packages/a; cd -; dart format .
env -C packages/a dart test; env --chdir=/opt dart test; dart test
pushd packages/a; pushd ../b; pushd; dart test; popd; popd; dart analyze
popd; dart analyze
pushd +1; dart test
'''),
        ),
        [
          '.:pushd packages/b',
          'packages/b:dart test',
          'packages/b:popd',
          '.:dart analyze',
          '.:cd packages/a',
          'packages/a:cd -',
          '.:dart format .',
          '.:env -C packages/a',
          'packages/a:dart test',
          '.:env -C /opt',
          '$externalMarker/host/opt:dart test',
          '.:dart test',
          '.:pushd packages/a',
          'packages/a:pushd ../b',
          'packages/b:pushd',
          'packages/a:dart test',
          'packages/a:popd',
          'packages/b:popd',
          '.:dart analyze',
          '.:popd',
          '.:dart analyze',
          '.:pushd +1',
          r'$:dart test',
        ],
      );
    });

    test('break, continue, return and a silent exit may skip later commands', () {
      String? reason(String script) => parseShell(script)
          .lastWhere((c) => c.argv.isNotEmpty && c.argv.first == 'dart')
          .uncertainReason;
      const skip = 'after a break, continue, return or exit that may skip it';
      expect(
        reason(
          'for d in packages/a; do\n[ "\$d" = never ] || continue\n(cd packages/b && dart test)\ndone',
        ),
        skip,
      );
      expect(
        reason(
          'for p in a b; do [ -f x ] && break; (cd "\$p" && dart test); done',
        ),
        skip,
      );
      expect(reason('[ -n "\$X" ] || exit 0\ndart test'), skip);
      expect(reason('if [ -z "\$CI" ]; then exit; fi; dart test'), skip);
      expect(reason('f() { [ -f x ] || return; dart test; }\nf'), skip);
      expect(reason('exit "\$rc"\ndart test'), skip);
      // Failing exits end the step visibly instead of skipping silently.
      expect(reason('cd packages/a || exit 1; dart test'), isNull);
      expect(reason('dart run tool.dart || exit; dart test'), isNull);
      expect(reason('[ -f x ] || exit 3\ndart test'), isNull);
      expect(reason('(exit 0); dart test'), isNull);
      expect(
        parseShell('cd packages/a || exit 1; dart test').last.cwd,
        'packages/a',
      );
      // continue skips the rest of one iteration only.
      expect(
        show(
          parseShell(
            'for p in a b; do (cd "\$p" && dart test); [ x ] || continue; echo; done',
          ),
        ).where((s) => s.endsWith('dart test')),
        ['a:dart test', 'b:dart test'],
      );
    });

    test('a cd that may not run leaves the directory unknown', () {
      String last(String script) {
        final cwd = parseShell(script).last.cwd;
        return cwd.contains(r'$') ? r'$' : cwd;
      }

      expect(last('if [ -n "\$X" ]; then cd packages/b; fi; dart test'), r'$');
      expect(
        last('if [ -n "\$X" ]; then cd a; else cd b; fi\ndart test'),
        r'$',
      );
      expect(
        last(
          'case "\$X" in\n  a) cd packages/a ;;\n  b|c) cd packages/b ;;\nesac\ndart test',
        ),
        r'$',
      );
      expect(last('[ -f x ] && cd packages/b; dart test'), r'$');
      expect(last('cd packages/a || cd packages/b; dart test'), r'$');
      expect(
        last(
          'cd packages/a && dart test && cd ../b && dart test; dart analyze',
        ),
        r'$',
      );
      expect(last('cd packages && cd a; dart test'), 'packages/a');
      expect(last('cd packages/b | cat; dart test'), '.');
      expect(last('cd packages/b & dart test'), '.');
      expect(
        last('if [ -f x ]; then dart run x; fi; cd packages/a; dart test'),
        'packages/a',
      );
      final chained = parseShell(
        'cd packages/a && dart test && cd ../b && dart test',
      ).where((c) => c.argv.first == 'dart');
      expect(chained.map((c) => c.cwd), ['packages/a', 'packages/b']);
      // Commands in a case arm are still checked, without the pattern.
      expect(
        show(parseShell('case "\$X" in\n  (a) dart test packages/a;;\nesac')),
        ['.:dart test packages/a'],
      );
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

    test('matrix follows GitHub include and exclude semantics', () {
      final job =
          loadYaml('''
strategy:
  matrix:
    fruit: [apple, pear]
    animal: [cat, dog]
    exclude:
      - {fruit: pear, animal: dog}
    include:
      - color: green
      - {color: pink, animal: cat}
      - {fruit: apple, shape: circle}
      - fruit: banana
      - {fruit: banana, animal: cat}
''')
              as YamlMap;
      expect(matrixCombinations(job), [
        {'fruit': 'apple', 'animal': 'cat', 'color': 'pink', 'shape': 'circle'},
        {
          'fruit': 'apple',
          'animal': 'dog',
          'color': 'green',
          'shape': 'circle',
        },
        {'fruit': 'pear', 'animal': 'cat', 'color': 'pink'},
        {'fruit': 'banana'},
        {'fruit': 'banana', 'animal': 'cat'},
      ]);
      expect(
        matrixCombinations(
          loadYaml(r"strategy: {matrix: '${{ fromJSON(needs.a.outputs.m) }}'}")
              as YamlMap,
        ),
        isNull,
      );
      expect(matrixCombinations(loadYaml('steps: []') as YamlMap), [
        <String, Object?>{},
      ]);
    });

    test('expands matrix, env, workspace and runner expressions per job', () {
      write('.github/workflows/ci.yml', r'''
env:
  TOOL: packages/tool
jobs:
  build:
    strategy:
      matrix:
        include:
          - {app: packages/a, target: linux}
          - {app: packages/b, target: web}
    env:
      APP: ${{ matrix.app }}
    steps:
      - working-directory: ${{ runner.temp }}
        run: dart test
      - working-directory: ${{ github.workspace }}
        run: flutter build ${{ matrix.target }} "$APP"
      - working-directory: ${{ matrix.app }}
        run: dart test
      - working-directory: ${{ env.TOOL }}
        run: dart pub get
      - working-directory: ${{ inputs.dir }}
        run: dart test
''');
      final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
      expect(steps.map((s) => s.job).toSet(), {'build'});
      expect(steps.map((s) => s.workingDirectory).toList(), [
        '$externalMarker/temp',
        '.',
        'packages/a',
        'packages/tool',
        r'${{inputs.dir}}',
        '$externalMarker/temp',
        '.',
        'packages/b',
        'packages/tool',
        r'${{inputs.dir}}',
      ]);
      expect(steps[1].run, r'flutter build linux "$APP"');
      expect(steps[1].environment['APP'], 'packages/a');
      expect(steps[6].run, r'flutter build web "$APP"');
      expect(steps[4].dynamicContext, isTrue);
      expect(steps[4].dynamicReason, contains('inputs.dir'));
      expect(steps.where((s) => s.dynamicContext), hasLength(2));
    });

    test('GITHUB_ENV writes make later values unknown', () {
      write('.github/workflows/ci.yml', r'''
env:
  A: packages/a
  B: packages/b
jobs:
  check:
    steps:
      - run: echo "A=elsewhere" >> "$GITHUB_ENV"
      - run: dart test "$A" "$B"
        env:
          A: packages/a
      - run: cat values >> $GITHUB_ENV
      - run: dart test "$B"
''');
      final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
      expect(steps[1].environment.containsKey('A'), isFalse);
      expect(steps[1].environment['B'], 'packages/b');
      expect(steps[3].environment.containsKey('B'), isFalse);
      expect(steps[3].environment['GITHUB_WORKSPACE'], workspaceMarker);
      expect(githubEnvWrites(r'echo "X=1" >> $GITHUB_ENV'), {'X'});
      expect(githubEnvWrites(r'printf "Y<<EOF" >> "${GITHUB_ENV}"'), {'Y'});
      expect(githubEnvWrites(r'{ echo X=1; } >> $GITHUB_ENV'), isNull);
    });

    test('every GITHUB_ENV append counts, through either spelling', () {
      write('.github/workflows/ci.yml', r'''
env:
  A: packages/a
  B: packages/b
  C: packages/c
  D: packages/d
jobs:
  check:
    steps:
      - run: echo "A=x" >> ${{ github.env }}
      - run: echo "X=1" >> "$GITHUB_ENV"; echo "B=x" >> "$GITHUB_ENV"
      - run: dart test
      - run: echo C=x >> "$GITHUB_ENV" && echo "Y=1" >> $GITHUB_ENV
      - run: dart test
''');
      final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
      expect(steps[2].environment.keys, isNot(contains('A')));
      expect(steps[2].environment.keys, isNot(contains('B')));
      expect(steps[2].environment['C'], 'packages/c');
      expect(steps[4].environment.keys, isNot(contains('C')));
      expect(steps[4].environment['D'], 'packages/d');
      expect(
        githubEnvWrites(
          'echo "X=1" >> "\$GITHUB_ENV"; echo "PKG=a" >> "\$GITHUB_ENV"',
        ),
        {'X', 'PKG'},
      );
      expect(githubEnvWrites(r'echo "A=1;B" >> $GITHUB_ENV'), {'A'});
      expect(githubEnvWrites(r'echo X=1 | tee -a "$GITHUB_ENV"'), isNull);
      expect(githubEnvWrites('echo X=1 \\\n  >> "\$GITHUB_ENV"'), {'X'});
    });

    test('a variable naming the env file makes appends unattributable', () {
      write('.github/workflows/ci.yml', r'''
env:
  PKG: packages/b
jobs:
  check:
    steps:
      - run: echo "PKG=packages/a" >> "$OUT"
        env:
          OUT: ${{ github.env }}
      - run: dart test "$PKG"
''');
      final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
      expect(steps[1].environment.keys, isNot(contains('PKG')));
      expect(steps[1].environment['GITHUB_WORKSPACE'], workspaceMarker);
    });

    test('runner variables are in the shell but not the env context', () {
      write('.github/workflows/ci.yml', r'''
jobs:
  check:
    steps:
      - run: dart test
        working-directory: ${{ env.GITHUB_WORKSPACE }}/packages/b
      - run: dart test
        working-directory: ${{ env.HOME }}
      - run: dart test
        working-directory: ${{ env.HOME }}/x
        env:
          HOME: packages
      - run: cd "$HOME" && cd "$GITHUB_WORKSPACE"
''');
      final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
      expect(steps[0].dynamicContext, isTrue);
      expect(steps[0].dynamicReason, contains('env.GITHUB_WORKSPACE'));
      expect(steps[1].dynamicContext, isTrue);
      expect(steps[2].workingDirectory, 'packages/x');
      expect(steps[2].environment['HOME'], 'packages');
      expect(steps[3].environment['HOME'], '$externalMarker/home');
      expect(steps[3].environment['GITHUB_WORKSPACE'], workspaceMarker);
    });

    test('directories outside a path checkout are external', () {
      write('.github/workflows/ci.yml', r'''
jobs:
  check:
    steps:
      - uses: actions/checkout@v4
        with: {path: Project}
      - run: dart test
      - run: dart test
        working-directory: Sibling
      - run: dart test
        working-directory: ${{ github.workspace }}/Project/packages/a
''');
      final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
      expect(isExternal(steps[0].workingDirectory), isTrue);
      expect(isExternal(steps[1].workingDirectory), isTrue);
      expect(steps[2].workingDirectory, 'packages/a');
    });

    test('checkout is recognized by shorthand and full URL', () {
      for (final uses in [
        'actions/checkout@v4',
        'https://github.com/actions/checkout@v4',
        'https://gitea.com/actions/checkout@v4',
        'https://code.forgejo.org/actions/checkout.git@v4',
      ]) {
        write('.github/workflows/ci.yml', '''
jobs:
  check:
    steps:
      - uses: $uses
        with: {path: repo}
      - run: dart test
        working-directory: repo/packages/a
''');
        final steps = readWorkflowSteps(fixture.path, ['.github/workflows']);
        expect(steps.single.workingDirectory, 'packages/a', reason: uses);
      }
      expect(isCheckoutAction('actions/checkout-extra@v1'), isFalse);
      expect(isCheckoutAction('my/actions/checkout@v1'), isFalse);
    });

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

    CheckReport report([
      Config config = const Config(),
      bool verbose = false,
    ]) => checkWorkspace(workspace, config, ownership, verbose: verbose);

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

    test('monorepo and melos scripts with one name collapse separately', () {
      workspace = Workspace(
        root: fixture.path,
        packages: workspace.packages,
        pubspec: {
          'melos': {
            'scripts': {'test': r'dart test "$B" && dart analyze "$C"'},
          },
        },
      );
      final unparsed = report(
        const Config(scripts: {'test': Script(r'dart analyze "$A"')}),
      ).warnings.where((f) => f.kind == 'unparsed');
      expect(unparsed.map((f) => f.message), [
        startsWith('Dynamic analyze path'),
        startsWith('melos script test: 2 commands'),
      ]);
    });

    test('Melos is reported without claiming indirect coverage', () {
      workflow(
        'dart run melos run test\ntimeout 10m dart pub global run melos run analyze\ndart pub global activate melos',
      );
      final result = report();
      final melos = result.warnings.singleWhere((f) => f.kind == 'melos');
      expect(melos.message, contains('job "check": 3 Melos invocations'));
      expect(melos.message, contains('lines 6, 7, 8'));
      expect(melos.sites, hasLength(3));
      expect(melos.toJson()['sites'], hasLength(3));
      expect(
        report(const Config(), true).warnings.where((f) => f.kind == 'melos'),
        hasLength(3),
      );
      expect(result.errors.where((f) => f.kind == 'test'), hasLength(3));
    });

    void rawWorkflow(String text) => write('.github/workflows/ci.yml', text);

    test('matrix values cover each member and stale values are errors', () {
      rawWorkflow(r'''
jobs:
  test:
    strategy:
      matrix:
        package: [packages/a, packages/b, packages/b/example, packages/gone]
    steps:
      - run: dart analyze . && dart format packages
      - run: dart test
        working-directory: ${{ matrix.package }}
''');
      final result = report();
      expect(result.errors.where((f) => f.kind == 'test'), isEmpty);
      expect(
        result.errors.singleWhere((f) => f.kind == 'stale-path').message,
        contains('packages/gone'),
      );
      expect(result.warnings, isEmpty);
    });

    test('loops over dynamic lists never establish coverage', () {
      rawWorkflow(r'''
jobs:
  test:
    steps:
      - run: |
          dart analyze .
          dart format packages
          for p in packages/*; do (cd "$p" && dart test); done
          for i in $(seq 1 3); do dart test packages/a; done
          for f in tool/*.py; do python3 "$f"; done
''');
      final result = report();
      expect(
        result.errors.where((f) => f.kind == 'test').map((f) => f.package),
        ['a', 'b', 'example'],
      );
      final unparsed = result.warnings.singleWhere((f) => f.kind == 'unparsed');
      expect(unparsed.message, contains('job "test": 3 commands'));
      expect(unparsed.sites!.map((f) => f.message), [
        'Dynamic cd path "\$p"; cannot verify it',
        'Dynamic test path; no coverage inferred',
        'dart test inside a loop over a dynamic list; no coverage inferred',
      ]);
    });

    test('commands outside the checkout give no coverage and no warning', () {
      rawWorkflow(r'''
jobs:
  test:
    steps:
      - working-directory: ${{ runner.temp }}
        run: dart test && dart --version
      - run: cd "$RUNNER_TEMP" && dart analyze .
''');
      final result = report();
      expect(result.errors.where((f) => f.kind == 'test'), hasLength(3));
      expect(result.warnings.where((f) => f.kind == 'analyze'), hasLength(3));
      expect(result.warnings.where((f) => f.kind == 'unparsed'), isEmpty);
    });

    test('env-resolved paths cover members through GITHUB_WORKSPACE', () {
      rawWorkflow(r'''
env:
  PKG: packages/a
jobs:
  test:
    steps:
      - run: cd "$GITHUB_WORKSPACE/$PKG" && dart test
''');
      expect(
        report().errors.where((f) => f.kind == 'test').map((f) => f.package),
        ['b', 'example'],
      );
    });

    test('help and version runs give no coverage', () {
      for (final option in ['--help', '-h', '--version']) {
        workflow('dart test $option', directory: 'packages/a');
        expect(
          report().errors.where((f) => f.kind == 'test').map((f) => f.package),
          ['a', 'b', 'example'],
          reason: option,
        );
      }
      workflow('dart test -- --help', directory: 'packages/a');
      expect(
        report().errors.where((f) => f.kind == 'test' && f.package == 'a'),
        hasLength(1),
      );
      expect(
        report().errors.singleWhere((f) => f.kind == 'stale-path').message,
        'test path does not exist: packages/a/--help',
      );
    });

    test('env -C and pushd move the command and check the directory', () {
      workflow(
        'env -C /tmp dart test\nenv -C ../a dart test\nenv -C missing dart test\npushd "\$RUNNER_TEMP" && dart test',
        directory: 'packages/b',
      );
      final result = report();
      expect(
        result.errors.where((f) => f.kind == 'test').map((f) => f.package),
        ['b', 'example'],
      );
      expect(
        result.errors.singleWhere((f) => f.kind == 'stale-path').message,
        'env -C path does not exist as a directory: packages/b/missing',
      );
    });

    test('uncalled function and skipped commands warn without coverage', () {
      workflow(r'''
test_b() { cd packages/b && dart test; }
for d in packages/a; do
  [ "$d" = never ] || continue
  (cd packages/a && dart test)
done''');
      final result = report(const Config(), true);
      expect(
        result.errors.where((f) => f.kind == 'test').map((f) => f.package),
        ['a', 'b', 'example'],
      );
      expect(
        result.warnings
            .where((f) => f.kind == 'unparsed')
            .map((f) => f.message),
        [
          'dart test inside a shell function that is never called; no coverage inferred',
          'dart test after a break, continue, return or exit that may skip it; no coverage inferred',
        ],
      );
    });

    test('paths through a checkout path resolve from the CI workspace', () {
      rawWorkflow(r'''
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
        with:
          path: repo
      - run: cd repo/packages/b && dart test
      - run: cd repo/packages/missing && dart test
      - run: dart test
        working-directory: repo/packages/a
      - run: cd packages/b/example && flutter test
        working-directory: repo
      - run: cd ../elsewhere && cd ../repo/packages/a && dart test
''');
      final result = report();
      expect(result.errors.where((f) => f.kind == 'test'), isEmpty);
      expect(
        result.errors.singleWhere((f) => f.kind == 'stale-path').message,
        'cd path does not exist as a directory: packages/missing',
      );
    });

    test('paths outside the checkout are external and never looked up', () {
      final host = Directory.systemTemp.path;
      rawWorkflow('''
jobs:
  test:
    steps:
      - run: cd /opt/hostedtoolcache && ls
      - run: cd ${shellQuote(host)} && ls
      - run: cd / && dart test && cd /definitely/missing/here
      - run: git clone https://example.invalid/tools ../tools
      - run: ls && dart test
        working-directory: ../tools
      - run: cargo test --manifest-path /nowhere/Cargo.toml
      - run: dart test C:/work/packages/a
''');
      final result = report();
      expect(result.errors.where((f) => f.kind == 'stale-path'), isEmpty);
      expect(result.errors.where((f) => f.kind == 'test'), hasLength(3));
      expect(result.warnings.where((f) => f.kind == 'unparsed'), isEmpty);
      expect(isExternal(rebasePath('/opt/hostedtoolcache')), isTrue);
      expect(isExternal(rebasePath(host)), isTrue);
      expect(isExternal(rebasePath('../../x')), isTrue);
      expect(isExternal(rebasePath(r'C:\work')), isTrue);
    });

    test('Windows host paths classify the same on every host', () {
      // The runner shell is POSIX whatever OS runs the check, so these are
      // the words a workflow written on or for a Windows machine can hold.
      rawWorkflow(r'''
jobs:
  test:
    steps:
      - run: cd 'C:\Users\runneradmin\AppData\Local\Temp' && ls
      - run: cd 'C:\Users\RUNNER~1\AppData\Local\Temp' && ls
      - run: cd "D:/a/_temp" && dart test
      - run: cd '\\server\share\tools' && ls
      - run: cd ~/tools && ls
      - run: cd C:\Users\me && ls
''');
      final result = report(const Config(), true);
      // Unquoted, the shell drops each backslash, leaving a relative path.
      expect(
        result.errors
            .where((f) => f.kind == 'stale-path')
            .map((f) => f.message),
        ['cd path does not exist as a directory: C:Usersme'],
      );
      expect(
        result.warnings.where((f) => f.kind == 'unparsed').map((f) => f.line),
        [8],
      );
      expect(isExternal(rebasePath(r'C:\Users\RUNNER~1\Temp')), isTrue);
      expect(isExternal(rebasePath(r'\\server\share')), isTrue);
      expect(isExternal(joinLocation(workspaceMarker, 'D:/a/_temp')), isTrue);
    });

    test('a GITHUB_ENV append hides the declared value from later steps', () {
      for (final append in [
        r'echo "PKG=packages/a" >> ${{ github.env }}',
        r'echo "X=1" >> "$GITHUB_ENV"; echo "PKG=packages/a" >> "$GITHUB_ENV"',
      ]) {
        rawWorkflow('''
env:
  PKG: packages/b
jobs:
  test:
    steps:
      - run: $append
      - run: cd \$PKG && dart test
''');
        final result = report();
        expect(
          result.errors.where((f) => f.kind == 'test').map((f) => f.package),
          ['a', 'b', 'example'],
          reason: append,
        );
        expect(
          result.warnings.singleWhere((f) => f.kind == 'unparsed').sites,
          hasLength(2),
        );
      }
    });

    test('unresolved sites collapse per job, verbose lists each', () {
      rawWorkflow(r'''
jobs:
  one:
    steps:
      - run: dart test "$A" && dart analyze "$B"
      - run: dart test
        working-directory: ${{ inputs.dir }}
  two:
    steps:
      - run: $CMD test
''');
      final collapsed = report().warnings.where((f) => f.kind == 'unparsed');
      expect(collapsed.map((f) => f.message.split(';').first), [
        startsWith('job "one"'),
        'Dynamic command "\$CMD"',
      ]);
      expect(collapsed.first.message, contains('3 commands'));
      expect(collapsed.first.message, contains('lines 4, 5'));
      expect(
        report(
          const Config(),
          true,
        ).warnings.where((f) => f.kind == 'unparsed'),
        hasLength(4),
      );
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

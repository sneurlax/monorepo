import 'dart:io';
import 'package:monorepo/src/config.dart';
import 'package:monorepo/src/filters.dart';
import 'package:monorepo/src/model.dart';
import 'package:monorepo/src/ownership.dart';
import 'package:monorepo/src/planner.dart';
import 'package:monorepo/src/render.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'ownership fences vendor packages, nested members, build and hidden dirs',
    () {
      final temp = Directory.systemTemp.createTempSync('monorepo-owned-');
      addTearDown(() => temp.deleteSync(recursive: true));
      for (final path in [
        'pkg/pubspec.yaml',
        'pkg/lib/a.dart',
        'pkg/lib/b.g.dart',
        'pkg/test/a_test.dart',
        'pkg/cargokit/build_tool/pubspec.yaml',
        'pkg/cargokit/build_tool/a.dart',
        'pkg/build/a.dart',
        'pkg/.hidden/a.dart',
        'pkg/example/pubspec.yaml',
        'pkg/example/main.dart',
      ]) {
        final f = File(p.join(temp.path, path));
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('');
      }
      final owned = ownedFiles(
        temp.path,
        p.join(temp.path, 'pkg'),
        exclude: ['**/*.g.dart'],
      );
      expect(owned.files, ['pkg/lib/a.dart', 'pkg/test/a_test.dart']);
      expect(owned.paths, ['pkg/lib/a.dart', 'pkg/test']);
      expect(ownedFiles(temp.path, p.join(temp.path, 'pkg/example')).paths, [
        'pkg/example',
      ]);
      File(p.join(temp.path, 'pkg/example/.hidden.dart')).writeAsStringSync('');
      expect(ownedFiles(temp.path, p.join(temp.path, 'pkg/example')).paths, [
        'pkg/example/.hidden.dart',
        'pkg/example/main.dart',
      ]);
    },
  );
  const workspace = Workspace(
    root: '/workspace',
    packages: [
      Package(
        name: 'a',
        path: '/workspace/packages/a',
        relPath: 'packages/a',
        hasTest: true,
      ),
      Package(
        name: 'b',
        path: '/workspace/packages/b',
        relPath: 'packages/b',
        isFlutter: true,
      ),
      Package(
        name: 'example',
        path: '/workspace/packages/b/example',
        relPath: 'packages/b/example',
        isFlutter: true,
        hasTest: true,
      ),
    ],
  );
  test(
    'test golden uses package cwd, runner kind, skip reason, and exit handling',
    () {
      final plan = buildPlan(
        workspace,
        const Config(),
        const Request('test', arguments: ['--tags=fast']),
      );
      expect(renderPlan(plan), '''rc=0
(cd packages/a && (dart test --tags=fast || [ \$? -eq 79 ])) || rc=1
# skip packages/b: no test/ directory
(cd packages/b/example && (flutter test --tags=fast || [ \$? -eq 79 ])) || rc=1
exit \$rc''');
      expect(plan.steps[0].acceptedExitCodes, [0, 79]);
      expect(
        buildPlan(
          workspace,
          const Config(),
          const Request('test'),
        ).steps[0].acceptedExitCodes,
        [0],
      );
      expect(renderPlan(plan, lines: true), isNot(contains('skip')));
    },
  );
  test('analyze covers nested selected member with its parent', () {
    final plan = buildPlan(
      workspace,
      const Config(analyzeArgs: ['--fatal-infos']),
      const Request('analyze', arguments: ['--no-fatal-warnings']),
    );
    expect(plan.steps.single.argv, [
      'dart',
      'analyze',
      '--fatal-infos',
      '--no-fatal-warnings',
      'packages/a',
      'packages/b',
    ]);
    final childOnly = buildPlan(
      workspace,
      const Config(),
      const Request('analyze', filters: Filters(scope: ['example'])),
    );
    expect(childOnly.steps.last.argv, [
      'dart',
      'analyze',
      'packages/b/example',
    ]);
    expect(
      renderPlan(
        buildPlan(workspace, const Config(), const Request('analyze')),
        lines: true,
      ),
      'dart analyze packages/a packages/b',
    );
  });
  test(
    'analyze expands parent paths or warns when nested child is ignored',
    () {
      final expanded = buildPlan(
        workspace,
        const Config(ignore: ['example']),
        const Request('analyze'),
        ownership: {
          'a': const OwnedFiles(
            files: ['packages/a/lib/a.dart'],
            paths: ['packages/a'],
          ),
          'b': const OwnedFiles(
            files: ['packages/b/lib/b.dart'],
            paths: ['packages/b/lib'],
          ),
        },
      );
      expect(expanded.steps.last.argv, [
        'dart',
        'analyze',
        'packages/a',
        'packages/b/lib',
      ]);
      final warned = buildPlan(
        workspace,
        const Config(ignore: ['example']),
        const Request('analyze'),
      );
      expect(
        warned.comments.single,
        contains(
          'packages/b/example is nested under analyzed parent packages/b',
        ),
      );
    },
  );
  test('format batches paths across selected members without root cd', () {
    final plan = buildPlan(
      workspace,
      const Config(),
      const Request('format', check: true),
      ownership: {
        'a': const OwnedFiles(
          files: ['packages/a/lib/a.dart'],
          paths: ['packages/a/lib'],
        ),
        'b': const OwnedFiles(
          files: ['packages/b/lib/b.dart'],
          paths: ['packages/b/lib'],
        ),
        'example': const OwnedFiles(
          files: ['packages/b/example/lib/main.dart'],
          paths: ['packages/b/example/lib'],
        ),
      },
    );
    expect(
      renderPlan(plan, lines: true),
      'dart format --output none --set-exit-if-changed packages/a/lib packages/b/lib packages/b/example/lib',
    );
  });
  test('format batches shell-escaped paths below command budget', () {
    final paths = List.generate(500, (i) => "packages/a/long file '$i.dart");
    final plan = buildPlan(
      workspace,
      const Config(),
      const Request('format', check: true, filters: Filters(scope: ['a'])),
      ownership: {'a': OwnedFiles(files: paths, paths: paths)},
    );
    final real = plan.steps.where((step) => step.skipReason == null).toList();
    expect(real.length, greaterThan(1));
    expect(real.expand((step) => step.argv.skip(5)), paths);
    for (final step in real) {
      expect(renderStep(step).length, lessThan(7000));
    }
  });
  test('config arguments precede CLI arguments, cycles appear as comments', () {
    final ws = Workspace(
      root: workspace.root,
      packages: workspace.packages,
      cycles: const [
        ['a', 'b'],
      ],
    );
    final plan = buildPlan(
      ws,
      const Config(testArgs: ['--exclude-tags=slow', '-j', '1']),
      const Request('test', arguments: ['-j', '2']),
    );
    expect(plan.steps.first.argv, [
      'dart',
      'test',
      '--exclude-tags=slow',
      '-j',
      '1',
      '-j',
      '2',
    ]);
    expect(renderPlan(plan), startsWith('# dependency cycle: a, b'));
  });
  test('exec and run export root and preserve quoted argument boundaries', () {
    final plan = buildPlan(
      workspace,
      const Config(),
      const Request(
        'exec',
        arguments: ['printf', '%s', 'a b', r'$(bad)', "a'b"],
      ),
    );
    expect(plan.steps.first.env, {'MONOREPO_ROOT': '/workspace'});
    expect(renderPlan(plan), contains("'a b'"));
    final script = buildPlan(
      workspace,
      const Config(
        scripts: {
          'hello': Script('echo hello\n'),
          'multi': Script('cd rust\ncargo build\n'),
          'loop': Script('for p in a b; do (cd "\$p" && dart test); done\n'),
        },
      ),
      const Request('run', script: 'hello', arguments: ['a b']),
    );
    expect(script.steps.single.argv, ['sh', '-c', "echo hello 'a b'"]);
    final multi = buildPlan(
      workspace,
      const Config(scripts: {'multi': Script('cd rust\ncargo build\n')}),
      const Request('run', script: 'multi', arguments: ['--release']),
    );
    expect(multi.steps.single.argv, [
      'sh',
      '-c',
      'cd rust\ncargo build --release',
    ]);
    expect(
      () => buildPlan(
        workspace,
        const Config(
          scripts: {
            'loop': Script('for p in a b; do (cd "\$p" && dart test); done\n'),
          },
        ),
        const Request('run', script: 'loop', arguments: ['--release']),
      ),
      throwsA(isA<ToolException>()),
    );
  });
  test('script steps, cwd and env become ordered plan steps', () {
    final workspace = Workspace(root: '/workspace', packages: const []);
    final config = Config(
      scripts: {
        'web': const Script.full(
          run: 'dart test -p chrome\nflutter test',
          steps: ['dart test -p chrome', 'flutter test "\$@"'],
          cwd: 'packages/a',
          env: {'LIB': r'${MONOREPO_ROOT}/lib', 'KEEP': r'$MONOREPO_ROOTS'},
        ),
        'one': const Script.full(run: 'cargo test', cwd: 'rust'),
      },
    );
    final plan = buildPlan(
      workspace,
      config,
      const Request('run', script: 'web', arguments: ['-x', 'slow']),
    );
    expect(plan.steps.map((s) => s.package), ['web step 1', 'web step 2']);
    expect(plan.steps.map((s) => s.argv), [
      ['sh', '-c', 'dart test -p chrome', 'sh', '-x', 'slow'],
      ['sh', '-c', 'flutter test "\$@"', 'sh', '-x', 'slow'],
    ]);
    expect(plan.steps.first.cwd, 'packages/a');
    expect(plan.steps.first.env, {
      'MONOREPO_ROOT': '/workspace',
      'LIB': '/workspace/lib',
      'KEEP': r'$MONOREPO_ROOTS',
    });
    final failFast = buildPlan(
      workspace,
      config,
      const Request('run', script: 'web', failFast: true),
    );
    expect(renderPlan(failFast), startsWith('set -e\n(cd packages/a && env'));
    final one = buildPlan(
      workspace,
      config,
      const Request('run', script: 'one', arguments: ['--release']),
    );
    expect(one.steps.single.cwd, 'rust');
    expect(one.steps.single.argv, ['sh', '-c', 'cargo test --release']);
  });
  test('filters recognize short and long test selectors only', () {
    for (final arg in [
      '--tags=x',
      '-tfoo',
      '-xfoo',
      '--name=x',
      '-nfoo',
      '-Nfoo',
      '--plain-name',
      '--exclude-tags',
    ]) {
      expect(hasTestFilter([arg]), isTrue, reason: arg);
    }
    expect(hasTestFilter(['-j', '2']), isFalse);
    expect(hasTestFilter(['--', '--name=x']), isFalse);
  });
}

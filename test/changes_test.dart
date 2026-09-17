import 'dart:convert';
import 'dart:io';

import 'package:monorepo/monorepo.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Package member(String name, String relPath, [Set<String> deps = const {}]) =>
    Package(name: name, path: '/w/$relPath', relPath: relPath, localDeps: deps);

void main() {
  final workspace = Workspace(
    root: '/w',
    packages: [
      member('core', 'packages/core'),
      member('ui', 'packages/ui', {'core'}),
      member('app', 'apps/app', {'ui'}),
      member('example', 'packages/ui/example', {'ui'}),
      member('tool', 'tool'),
    ],
  );
  bool fences(String directory) => directory == 'packages/ui/cargokit/build';

  test('nested members own their files and non-member packages fence', () {
    expect(
      owners(workspace, [
        'packages/ui/lib/a.dart',
        'packages/ui/example/lib/main.dart',
        'packages/ui/cargokit/build/lib/x.dart',
        'packages/ui/cargokit/README.md',
        'README.md',
        'packages/core/pubspec.yaml',
      ], isPackageDirectory: fences),
      {
        'packages/ui/lib/a.dart': 'ui',
        'packages/ui/example/lib/main.dart': 'example',
        'packages/ui/cargokit/build/lib/x.dart': null,
        'packages/ui/cargokit/README.md': 'ui',
        'README.md': null,
        'packages/core/pubspec.yaml': 'core',
      },
    );
  });

  test('dependents are added transitively through local dependencies', () {
    expect(withDependents(workspace, {'core'}), {
      'core',
      'ui',
      'app',
      'example',
    });
    expect(withDependents(workspace, {'example'}), {'example'});
  });

  test('root workspace files select every member', () {
    final changes = changeSet(workspace, 'main', [
      'pubspec.lock',
      'packages/core/lib/c.dart',
    ], isPackageDirectory: fences);
    expect(changes.packages, hasLength(5));
    expect(changes.changed, {'core'});
    expect(changes.comments.single, contains('pubspec.lock'));
    final nested = changeSet(workspace, 'main', [
      'packages/core/pubspec.lock',
    ], isPackageDirectory: fences);
    expect(nested.packages, {'core'});
    expect(nested.comments, isEmpty);
  });

  test('unchanged members are planned as skips', () {
    final changes = changeSet(
      workspace,
      'main',
      ['packages/ui/lib/a.dart'],
      includeDependents: true,
      isPackageDirectory: fences,
    );
    final plan = buildPlan(
      workspace,
      const Config(),
      Request(
        'exec',
        arguments: const ['true'],
        filters: Filters(changedPackages: changes.packages, since: 'main'),
      ),
    );
    expect(
      {for (final step in plan.steps) step.package: step.skipReason},
      {
        'core': 'unchanged since main',
        'ui': null,
        'app': null,
        'example': null,
        'tool': 'unchanged since main',
      },
    );
  });

  group('empty selection', () {
    Plan plan(String command, Filters filters) => buildPlan(
      workspace,
      const Config(),
      Request(command, filters: filters, arguments: const ['true']),
    );
    const none = Filters(changedPackages: {}, since: 'main');

    test('plans say nothing changed, --lines included', () {
      for (final command in ['test', 'analyze', 'format', 'exec']) {
        final built = plan(command, none);
        expect(built.notice, 'no members changed since main', reason: command);
        expect(
          renderPlan(built, lines: true),
          '# no members changed since main',
        );
        expect(
          renderPlan(built),
          allOf(
            contains('# no members changed since main\nrc=0\n'),
            endsWith('exit \$rc'),
          ),
        );
      }
      expect(
        plan(
          'test',
          const Filters(
            scope: ['tool'],
            changedPackages: {'core'},
            since: 'main',
          ),
        ).notice,
        'none of the members changed since main are selected',
      );
      expect(
        plan(
          'test',
          const Filters(changedPackages: {'core'}, since: 'main'),
        ).notice,
        isNull,
      );
      expect(plan('test', const Filters(scope: ['nothing'])).notice, isNull);
    });

    test(
      'empty --lines and full plans are valid scripts that exit 0',
      () async {
        final built = plan('test', none);
        for (final script in [
          renderPlan(built, lines: true),
          renderPlan(built),
          renderPlan(
            buildPlan(
              workspace,
              const Config(),
              const Request('test', filters: none, failFast: true),
            ),
          ),
        ]) {
          final syntax = await Process.run('sh', ['-n', '-c', script]);
          expect(syntax.exitCode, 0, reason: '$script\n${syntax.stderr}');
          final run = await Process.run('sh', ['-c', script]);
          expect(run.exitCode, 0, reason: script);
          expect(run.stdout, isEmpty);
        }
      },
      testOn: '!windows',
    );

    test('execution prints the notice alone and exits 0', () async {
      final output = StringBuffer();
      final result = await Executor(
        write: output.write,
        runner: (step, root, buffered) => fail('nothing should run'),
      ).execute(plan('test', none));
      expect(result.exitCode, 0);
      expect(output.toString(), 'no members changed since main\n');
      final json = StringBuffer();
      final document = await Executor(
        write: json.write,
        reporter: Reporter.json,
      ).execute(plan('test', none));
      expect(document.exitCode, 0);
      expect(jsonDecode(json.toString())['summary']['skipped'], 5);
    });
  });

  group('git', () {
    late Directory repo;
    Future<void> git(List<String> args) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: repo.path,
      );
      if (result.exitCode != 0) fail('git $args: ${result.stderr}');
    }

    void write(String path, String text) {
      final file = File(p.join(repo.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    setUp(() async {
      repo = Directory.systemTemp.createTempSync('monorepo-since-');
      await git(['init', '-q', '-b', 'main']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'user.name', 'Test']);
      write('a/lib/a.dart', '');
      write('b/lib/b.dart', '');
      write('README.md', '');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'base']);
    });
    tearDown(() => repo.deleteSync(recursive: true));

    test(
      'merges committed, uncommitted, staged and untracked changes',
      () async {
        await git(['checkout', '-q', '-b', 'topic']);
        write('a/lib/a.dart', 'void a() {}');
        await git(['commit', '-q', '-am', 'change a']);
        write('b/lib/b.dart', 'void b() {}');
        write('c/new.dart', '');
        write('README.md', 'staged');
        await git(['add', 'README.md']);
        final before = File(p.join(repo.path, '.git', 'index')).statSync();
        expect(await changedFiles(repo.path, 'main'), [
          'README.md',
          'a/lib/a.dart',
          'b/lib/b.dart',
          'c/new.dart',
        ]);
        final after = File(p.join(repo.path, '.git', 'index')).statSync();
        expect(after.modified, before.modified, reason: 'git stays read-only');
      },
    );

    test(
      'paths are relative to a workspace below the repository root',
      () async {
        write('sub/x/lib/x.dart', '');
        write('outside.txt', '');
        expect(await changedFiles(p.join(repo.path, 'sub'), 'HEAD'), [
          'x/lib/x.dart',
        ]);
      },
    );

    test('rejects unknown refs and option-like refs', () async {
      expect(
        () => changedFiles(repo.path, 'nope'),
        throwsA(
          isA<ToolException>().having(
            (e) => e.message,
            'message',
            contains('unknown git ref'),
          ),
        ),
      );
      expect(
        () => changedFiles(repo.path, '--output=/tmp/x'),
        throwsA(isA<ToolException>()),
      );
    });
  });
}

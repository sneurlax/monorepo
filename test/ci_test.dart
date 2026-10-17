import 'dart:io';

import 'package:monorepo/monorepo.dart';
import 'package:monorepo/src/check/coverage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// A member to create on disk: its files, relative to the member directory.
typedef Spec = ({
  String name,
  String path,
  bool flutter,
  List<String> files,
  Set<String> deps,
});

Spec member(
  String name,
  String path, {
  bool flutter = false,
  List<String> files = const ['lib/x.dart', 'test/x_test.dart'],
  Set<String> deps = const {},
}) => (name: name, path: path, flutter: flutter, files: files, deps: deps);

class Fixture {
  final Directory directory;
  final Workspace workspace;
  final Config config;
  Fixture(this.directory, this.workspace, this.config);

  String get root => directory.path;

  void write(String path, [String text = '']) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  Map<String, OwnedFiles> get ownership => collectOwnership(workspace, config);

  List<Plan> plans(
    List<String> commands, {
    Filters filters = const Filters(),
    List<String> testArguments = const [],
  }) => [
    for (final command in commands)
      buildPlan(
        workspace,
        config,
        Request(
          command,
          filters: filters,
          arguments: command == 'test' ? testArguments : const [],
          check: command == 'format',
        ),
        ownership: ownership,
      ),
  ];

  CheckReport check() => checkWorkspace(workspace, config, ownership);
}

Fixture fixture(
  List<Spec> members, {
  Map<String, Object?> config = const {},
  List<String> extra = const [],
}) {
  final directory = Directory.systemTemp.createTempSync('monorepo-ci-');
  addTearDown(() => directory.deleteSync(recursive: true));
  void write(String path, [String text = '']) {
    final file = File(p.join(directory.path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  write('pubspec.yaml', 'name: root\n');
  final packages = <Package>[];
  for (final spec in members) {
    write('${spec.path}/pubspec.yaml', 'name: ${spec.name}\n');
    for (final file in spec.files) {
      write('${spec.path}/$file');
    }
    packages.add(
      Package(
        name: spec.name,
        path: p.join(directory.path, spec.path),
        relPath: spec.path,
        isFlutter: spec.flutter,
        hasTest: Directory(
          p.join(directory.path, spec.path, 'test'),
        ).existsSync(),
        localDeps: spec.deps,
      ),
    );
  }
  for (final path in extra) {
    write(path);
  }
  final workspace = Workspace(root: directory.path, packages: packages);
  return Fixture(directory, workspace, Config.parse(config, packages));
}

/// Findings that a generated workflow must not leave: anything about the
/// [covered] members for the [kinds] it includes, and anything at all that
/// is not a coverage gap.
List<Finding> problems(
  CheckReport report,
  Set<String> covered,
  Set<String> kinds,
) {
  const gaps = {'test', 'partial-test', 'analyze', 'format'};
  return [
    for (final finding in [...report.errors, ...report.warnings])
      if (!gaps.contains(finding.kind) ||
          (kinds.contains(
                finding.kind == 'partial-test' ? 'test' : finding.kind,
              ) &&
              covered.contains(finding.package)))
        finding,
  ];
}

Set<String> selected(Fixture fx, Filters filters, String command) => {
  for (final package in fx.workspace.packages)
    if (filters.skipReason(package, fx.config, command) == null) package.name,
};

void main() {
  final shapes = <String, Fixture Function()>{
    'flat Dart members': () => fixture([
      member('a', 'packages/a'),
      member('b', 'packages/b', deps: {'a'}),
    ]),
    'nested Flutter example, member without tests, fenced package': () =>
        fixture(
          [
            member('core', 'packages/core'),
            member(
              'ui',
              'packages/ui',
              flutter: true,
              files: ['lib/ui.dart', 'test/ui_test.dart', '.hidden/x.dart'],
            ),
            member(
              'example',
              'packages/ui/example',
              flutter: true,
              files: ['lib/main.dart', 'test/widget_test.dart'],
            ),
            member('tool', 'tool', files: ['bin/tool.dart']),
          ],
          extra: [
            'packages/ui/cargokit/build_tool/pubspec.yaml',
            'packages/ui/cargokit/build_tool/lib/b.dart',
          ],
        ),
    'paths that need quoting': () => fixture([
      member('spaced', 'packages/a space'),
      member('quoted', "packages/b'quote", flutter: true),
      member('hashed', 'packages/c #1'),
    ]),
    'config ignores, test args and format excludes': () => fixture(
      [
        member('kept', 'packages/kept'),
        member('app', 'apps/app', flutter: true),
        member('skipped', 'packages/skipped'),
        member(
          'generated',
          'packages/generated',
          files: ['lib/a.dart', 'lib/src/gen/g.dart', 'test/a_test.dart'],
        ),
      ],
      config: {
        'ignore': ['skipped'],
        'test': {
          'ignore': ['app'],
          'args': ['--exclude-tags=slow', '-j', '1'],
        },
        'analyze': {
          'args': ['--fatal-infos'],
        },
        'format': {
          'exclude': ['packages/generated/lib/src/gen/**'],
        },
      },
    ),
    'format batches over the command budget': () => fixture([
      member(
        'wide',
        'packages/wide',
        files: [
          'test/wide_test.dart',
          for (var i = 0; i < 400; i++) 'lib/a_rather_long_file_name_$i.dart',
          'lib/.keep.dart',
        ],
      ),
    ]),
  };

  final variants = <String, (CiOptions, String)>{
    'github': (const CiOptions(), '.github/workflows/ci.yml'),
    'gitea with a runner label and timeout': (
      const CiOptions(
        provider: 'gitea',
        runsOn: 'manymath-maintenance-linux-x64',
        job: 'verify',
        timeout: 15,
        enforceLockfile: true,
      ),
      '.gitea/workflows/ci.yml',
    ),
  };

  group('generated workflows pass check', () {
    for (final shape in shapes.entries) {
      for (final variant in variants.entries) {
        test('${shape.key}, ${variant.key}', () {
          final fx = shape.value();
          final (options, file) = variant.value;
          fx.write(
            file,
            renderWorkflow(
              fx.workspace,
              fx.plans(['format', 'analyze', 'test']),
              options,
            ),
          );
          final report = fx.check();
          expect(
            [...report.errors, ...report.warnings].map((f) => f.toJson()),
            isEmpty,
          );
        });
      }
    }

    test('steps-only output pasted into an existing job', () {
      for (final make in shapes.values) {
        final fx = make();
        final steps = renderWorkflow(
          fx.workspace,
          fx.plans(['format', 'analyze', 'test']),
          const CiOptions(stepsOnly: true, timeout: 5),
        );
        fx.write('.gitea/workflows/existing.yml', '''
jobs:
  existing:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: dart pub get
${steps.split('\n').map((line) => '      $line').join('\n')}
''');
        expect(fx.check().hasProblems(strict: true), isFalse, reason: steps);
      }
    });

    test('filters and operation subsets cover what they select', () {
      final cases = <(Filters, List<String>)>[
        (
          const Filters(scope: ['packages/ui/**']),
          ['format', 'analyze', 'test'],
        ),
        (const Filters(flutter: true), ['test']),
        (const Filters(flutter: false), ['analyze', 'format']),
        (const Filters(scope: ['core']), ['analyze']),
        (const Filters(ignore: ['tool']), ['format', 'test']),
      ];
      for (final (filters, commands) in cases) {
        final fx =
            shapes['nested Flutter example, member without tests, fenced package']!();
        fx.write(
          '.github/workflows/ci.yml',
          renderWorkflow(
            fx.workspace,
            fx.plans(commands, filters: filters),
            const CiOptions(),
          ),
        );
        final covered = {
          for (final command in commands) ...selected(fx, filters, command),
        };
        expect(
          problems(
            fx.check(),
            covered,
            commands.toSet(),
          ).map((f) => f.toJson()),
          isEmpty,
          reason: '${filters.scope} ${filters.flutter} $commands',
        );
      }
    });

    test('CLI test arguments with a filter accept exit 79 and still count', () {
      final fx = shapes['flat Dart members']!();
      final yaml = renderWorkflow(
        fx.workspace,
        fx.plans(['format', 'analyze', 'test'], testArguments: ['-t', 'unit']),
        const CiOptions(timeout: 10),
      );
      expect(
        yaml,
        contains(
          'run: \'timeout --signal=TERM --kill-after=30s 10m dart test -t unit || [ \$? -eq 79 ]\'',
        ),
      );
      fx.write('.github/workflows/ci.yml', yaml);
      expect(fx.check().hasProblems(strict: true), isFalse);
    });

    test('an ignored nested member leaves its parent analyzed by paths', () {
      // The plan analyzes the parent's owned paths so the child is skipped.
      // check counts analysis of a member root only, so it warns; this is
      // conservative and documented.
      final fx =
          shapes['nested Flutter example, member without tests, fenced package']!();
      const filters = Filters(ignore: ['example']);
      fx.write(
        '.github/workflows/ci.yml',
        renderWorkflow(
          fx.workspace,
          fx.plans(['format', 'analyze', 'test'], filters: filters),
          const CiOptions(),
        ),
      );
      final found = problems(fx.check(), selected(fx, filters, 'test'), {
        'format',
        'analyze',
        'test',
      });
      expect(found.map((f) => (f.kind, f.package)), [('analyze', 'ui')]);
    });
  });

  group('commands match plan --lines', () {
    test(
      'every run step is the plan step with its cd as working-directory',
      () {
        for (final make in shapes.values) {
          final fx = make();
          final plans = fx.plans(['format', 'analyze', 'test']);
          final document =
              loadYaml(renderWorkflow(fx.workspace, plans, const CiOptions()))
                  as YamlMap;
          final steps = (document['jobs']['ci']['steps'] as YamlList)
              .whereType<YamlMap>()
              .where(
                (s) => s['name'] != 'Resolve dependencies' && s['run'] != null,
              )
              .toList();
          final runnable = [
            for (final plan in plans)
              ...plan.steps.where((s) => s.skipReason == null),
          ];
          expect(steps, hasLength(runnable.length));
          for (var i = 0; i < steps.length; i++) {
            final step = runnable[i];
            final cwd = steps[i]['working-directory'] as String?;
            final run = steps[i]['run'] as String;
            // Rebuild the --lines form from the workflow step.
            final status = renderAcceptedStatus(step);
            final command = status == null
                ? run
                : '(${run.replaceFirst(' || $status', '')} || $status)';
            expect(
              cwd == null ? command : '(cd ${shellQuote(cwd)} && $command)',
              renderStep(step),
            );
            expect(cwd ?? '.', step.cwd);
          }
        }
      },
    );

    test('running the workflow steps runs what plan --lines runs', () async {
      final fx = fixture(
        [
          member('spaced', 'packages/a space'),
          member('quoted', "packages/b'quote", flutter: true),
          member('plain', 'packages/plain'),
        ],
        config: {
          'test': {
            'args': ['--name', "it's"],
          },
        },
      );
      final bin = Directory(p.join(fx.root, '.bin'))..createSync();
      final log = p.join(fx.root, '.log');
      for (final name in ['dart', 'flutter']) {
        final stub = File(p.join(bin.path, name))
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'printf "%s|%s" "\$(pwd)" "\$(basename "\$0")" >> "$log"\n'
            'for a in "\$@"; do printf "|%s" "\$a" >> "$log"; done\n'
            'echo >> "$log"\n'
            'exit 79\n',
          );
        await Process.run('chmod', ['+x', stub.path]);
      }
      final env = {'PATH': '${bin.path}:${Platform.environment['PATH']}'};
      final plans = fx.plans(['format', 'analyze', 'test']);
      Future<String> drain() async {
        final file = File(log);
        final text = file.existsSync() ? file.readAsStringSync() : '';
        if (file.existsSync()) file.deleteSync();
        return text;
      }

      final lines = plans
          .map((plan) => renderPlan(plan, lines: true))
          .where((text) => text.isNotEmpty)
          .join('\n');
      for (final line in lines.split('\n')) {
        await Process.run(
          'sh',
          ['-c', line],
          workingDirectory: fx.root,
          environment: env,
        );
      }
      final expected = await drain();
      final document =
          loadYaml(
                renderWorkflow(
                  fx.workspace,
                  plans,
                  const CiOptions(stepsOnly: true),
                ),
              )
              as YamlList;
      final codes = <int>[];
      for (final step in document.cast<YamlMap>()) {
        final result = await Process.run(
          'sh',
          ['-c', step['run'] as String],
          workingDirectory: p.join(
            fx.root,
            step['working-directory'] as String? ?? '.',
          ),
          environment: env,
        );
        codes.add(result.exitCode);
      }
      expect(await drain(), expected);
      expect(expected.split('\n').where((l) => l.isNotEmpty), hasLength(5));
      // A 79 fails format and analyze steps; filtered tests accept it.
      expect(codes, [79, 79, 0, 0, 0]);
    }, testOn: '!windows');
  });

  group('output', () {
    test('github sets up the SDK, gitea checks the provisioned one', () {
      final dart = fixture([member('a', 'packages/a')]);
      final flutter = fixture([member('b', 'packages/b', flutter: true)]);
      String render(Fixture fx, CiOptions options) =>
          renderWorkflow(fx.workspace, fx.plans(['test']), options);
      expect(
        render(dart, const CiOptions()),
        contains('- uses: dart-lang/setup-dart@v1\n'),
      );
      expect(
        render(flutter, const CiOptions()),
        contains(
          '- uses: subosito/flutter-action@v2\n        with:\n          channel: stable\n',
        ),
      );
      expect(
        render(
          flutter,
          const CiOptions(provider: 'gitea', enforceLockfile: true),
        ),
        allOf(
          contains(
            'run: |\n          dart --version\n          flutter --version\n',
          ),
          contains('run: flutter pub get --enforce-lockfile\n'),
          isNot(contains('setup-dart')),
        ),
      );
      expect(render(dart, const CiOptions()), contains('run: dart pub get\n'));
    });

    test('runs-on, job and header are rendered as given', () {
      final fx = fixture([member('a', 'packages/a')]);
      final yaml = renderWorkflow(
        fx.workspace,
        fx.plans(['test']),
        const CiOptions(
          runsOn: 'self-hosted: linux',
          job: 'verify',
          invocation: ['--test', '--scope', 'a*'],
        ),
      );
      expect(
        yaml,
        startsWith(
          "# Generated by monorepo $toolVersion: monorepo ci --test --scope 'a*'\n",
        ),
      );
      final document = loadYaml(yaml) as YamlMap;
      expect(document['jobs']['verify']['runs-on'], 'self-hosted: linux');
      expect(document['on'].keys, [
        'push',
        'pull_request',
        'workflow_dispatch',
      ]);
    });

    test('skips and plan comments become YAML comments once each', () {
      final fx = fixture([
        member('a', 'packages/a'),
        member('b', 'packages/b', files: ['lib/b.dart']),
      ]);
      final yaml = renderWorkflow(
        fx.workspace,
        fx.plans([
          'format',
          'analyze',
          'test',
        ], filters: const Filters(changedPackages: {'b'}, since: 'main')),
        const CiOptions(stepsOnly: true),
      );
      expect(yaml.split('\n').where((l) => l.startsWith('#')).skip(3), [
        '# skip packages/a: unchanged since main',
        '# skip packages/b: no test/ directory',
      ]);
    });

    test('an empty --since selection says so and stays valid YAML', () {
      final fx = fixture([member('a', 'packages/a')]);
      const filters = Filters(changedPackages: {}, since: 'origin/main');
      final steps = renderWorkflow(
        fx.workspace,
        fx.plans(['format', 'analyze', 'test'], filters: filters),
        const CiOptions(stepsOnly: true),
      );
      expect(steps, contains('\n# no members changed since origin/main\n'));
      expect(loadYaml(steps), isNull);
      final full = renderWorkflow(
        fx.workspace,
        fx.plans(['format', 'analyze', 'test'], filters: filters),
        const CiOptions(),
      );
      expect((loadYaml(full) as YamlMap)['jobs']['ci']['steps'], hasLength(3));
    });

    test('scalars stay plain only when YAML reads them back unchanged', () {
      for (final value in [
        'dart test',
        'packages/a',
        'manymath-maintenance-linux-x64',
        'true',
        'No',
        '1.0',
        '-x',
        'a: b',
        'a #b',
        "it's",
        r'dart test || [ $? -eq 79 ]',
        '*glob',
        '',
        'trailing ',
      ]) {
        expect(loadYaml('k: ${yamlScalar(value)}')['k'], value, reason: value);
      }
      expect(yamlScalar('packages/a'), 'packages/a');
    });
  });
}

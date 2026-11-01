import 'dart:convert';
import 'dart:io';
import 'package:monorepo/src/config.dart';
import 'package:monorepo/src/filters.dart';
import 'package:monorepo/src/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' as yaml;

void main() {
  test('the reported version matches the pubspec', () {
    final pubspec =
        yaml.loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
    expect(toolVersion, pubspec['version']);
  });

  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('monorepo-model-'));
  tearDown(() => temp.deleteSync(recursive: true));
  void put(String path, String text) {
    final file = File(p.join(temp.path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  test(
    'discovery reads mixed packages, nested example and dev dependency graph',
    () {
      put(
        'pubspec.yaml',
        'name: fixture\nworkspace: [packages/core, packages/ui, packages/ui/example]\n',
      );
      put(
        'packages/core/pubspec.yaml',
        'name: core\ndev_dependencies:\n  ui: any\n',
      );
      put('packages/core/test/test.dart', '');
      put(
        'packages/ui/pubspec.yaml',
        'name: ui\ndependencies:\n  flutter: {sdk: flutter}\n  core: any\n',
      );
      put('packages/ui/integration_test/test.dart', '');
      put(
        'packages/ui/example/pubspec.yaml',
        'name: ui_example\ndev_dependencies:\n  flutter_test: {sdk: flutter}\n  ui: any\n',
      );
      put('packages/ui/cargokit/build_tool/pubspec.yaml', 'name: vendored\n');
      final workspace = workspaceFromJson(
        jsonEncode({
          'packages': [
            {'name': 'fixture', 'path': temp.path},
            for (final entry in {
              'core': 'packages/core',
              'ui': 'packages/ui',
              'ui_example': 'packages/ui/example',
            }.entries)
              {'name': entry.key, 'path': p.join(temp.path, entry.value)},
          ],
        }),
      );
      expect(workspace.packages.map((p) => p.name), [
        'core',
        'ui',
        'ui_example',
      ]);
      expect(workspace.cycles, [
        ['core', 'ui'],
      ]);
      expect(workspace.packages.first.hasTest, isTrue);
      expect(workspace.packages[1].hasTest, isFalse);
      expect(workspace.packages[1].hasIntegrationTest, isTrue);
      expect(workspace.packages.map((p) => p.isFlutter), [false, true, true]);
      expect(workspace.packages[1].relPath, 'packages/ui');
    },
  );
  test(
    'topology keeps downstream nodes after a cycle and breaks ties by name',
    () {
      final result = orderPackages([
        const Package(
          name: 'a_user',
          path: '',
          relPath: '',
          localDeps: {'z_cycle'},
        ),
        const Package(
          name: 'z_cycle',
          path: '',
          relPath: '',
          localDeps: {'y_cycle'},
        ),
        const Package(
          name: 'y_cycle',
          path: '',
          relPath: '',
          localDeps: {'z_cycle'},
        ),
        const Package(name: 'b_free', path: '', relPath: ''),
      ]);
      expect(result.packages.map((p) => p.name), [
        'b_free',
        'y_cycle',
        'z_cycle',
        'a_user',
      ]);
      expect(result.cycles, [
        ['y_cycle', 'z_cycle'],
      ]);
    },
  );
  test('malformed discovery is an environment error', () {
    for (final input in [
      'no json',
      '{}',
      '{"packages": []}',
      '{"packages": [null]}',
    ]) {
      expect(() => workspaceFromJson(input), throwsA(isA<ToolException>()));
    }
  });
  const packages = [
    Package(name: 'core', path: '/w/core', relPath: 'packages/core'),
    Package(name: 'ui', path: '/w/ui', relPath: 'packages/ui', isFlutter: true),
  ];
  test('full config and script forms', () {
    final config = Config.parse({
      'ignore': ['ui'],
      'test': {
        'ignore': ['core'],
        'args': ['--tags=x', '-j', '1'],
      },
      'analyze': {
        'args': ['--fatal-infos'],
      },
      'format': {
        'exclude': ['**/*.g.dart'],
      },
      'scripts': {
        'short': 'echo ok',
        'long': {'run': 'echo long', 'description': 'A script'},
        'steps': {
          'steps': ['echo one', 'echo two'],
          'cwd': 'packages/core',
          'env': {'LD_LIBRARY_PATH': r'$MONOREPO_ROOT/lib', 'N': 1},
        },
      },
      'check': {
        'workflows': ['ci'],
        'allow': [
          {'kind': 'test', 'package': 'core', 'reason': 'External runner'},
        ],
      },
    }, packages);
    expect(config.testArgs, ['--tags=x', '-j', '1']);
    expect(config.scripts['long']!.description, 'A script');
    final steps = config.scripts['steps']!;
    expect(steps.bodies, ['echo one', 'echo two']);
    expect(steps.cwd, 'packages/core');
    expect(steps.env, {'LD_LIBRARY_PATH': r'$MONOREPO_ROOT/lib', 'N': '1'});
    expect(config.scripts['short']!.bodies, ['echo ok']);
    expect(config.allow.single.reason, 'External runner');
    expect(config.workflows, ['ci']);
  });
  test('script env values keep the text written in pubspec.yaml', () {
    final root = yaml.loadYaml('''
scripts:
  envs:
    run: echo
    env:
      SDK_VERSION: 3.10
      MODE: 0755
      HEX: 0x1F
      FLAG: yes
      ON: true
      EXP: 1e3
      QUOTED: "3.10"
      SINGLE: '0755'
      FOLDED: >-
        3.10
''');
    final config = Config.parse(root, const []);
    expect(config.scripts['envs']!.env, {
      'SDK_VERSION': '3.10',
      'MODE': '0755',
      'HEX': '0x1F',
      'FLAG': 'yes',
      'ON': 'true',
      'EXP': '1e3',
      'QUOTED': '3.10',
      'SINGLE': '0755',
      'FOLDED': '3.10',
    });
  });
  for (final entry in <String, Object?>{
    'root string': 'bad',
    'unknown root': {'typo': []},
    'unknown package': {
      'ignore': ['missing'],
    },
    'null nested': {'test': null},
    'null args': {
      'test': {'args': null},
    },
    'wrong args': {
      'test': {
        'args': ['-j', 1],
      },
    },
    'unknown test key': {
      'test': {'arg': []},
    },
    'unknown analyze key': {
      'analyze': {'arg': []},
    },
    'unknown format key': {
      'format': {'excludes': []},
    },
    'wrong exclude': {
      'format': {'exclude': 'x'},
    },
    'unknown test package': {
      'test': {
        'ignore': ['missing'],
      },
    },
    'scripts list': {'scripts': []},
    'script empty': {
      'scripts': {'x': ''},
    },
    'script missing run': {
      'scripts': {
        'x': {'description': 'x'},
      },
    },
    'script unknown': {
      'scripts': {
        'x': {'run': 'x', 'other': true},
      },
    },
    'script desc type': {
      'scripts': {
        'x': {'run': 'x', 'description': 4},
      },
    },
    'script run and steps': {
      'scripts': {
        'x': {
          'run': 'x',
          'steps': ['y'],
        },
      },
    },
    'script empty steps': {
      'scripts': {
        'x': {'steps': <String>[]},
      },
    },
    'script blank step': {
      'scripts': {
        'x': {
          'steps': ['a', ' '],
        },
      },
    },
    'script escaping cwd': {
      'scripts': {
        'x': {'run': 'x', 'cwd': '../other'},
      },
    },
    'script absolute cwd': {
      'scripts': {
        'x': {'run': 'x', 'cwd': '/tmp'},
      },
    },
    'script env name': {
      'scripts': {
        'x': {
          'run': 'x',
          'env': {'BAD-NAME': '1'},
        },
      },
    },
    'script env root': {
      'scripts': {
        'x': {
          'run': 'x',
          'env': {'MONOREPO_ROOT': '/elsewhere'},
        },
      },
    },
    'script env list': {
      'scripts': {
        'x': {
          'run': 'x',
          'env': {
            'A': ['1'],
          },
        },
      },
    },
    'script null cwd': {
      'scripts': {
        'x': {'run': 'x', 'cwd': null},
      },
    },
    'check unknown': {
      'check': {'x': 1},
    },
    'check workflows': {
      'check': {'workflows': 3},
    },
    'allow type': {
      'check': {'allow': {}},
    },
    'allow package': {
      'check': {
        'allow': [
          {'kind': 'test', 'package': 'missing', 'reason': 'x'},
        ],
      },
    },
    'allow kind': {
      'check': {
        'allow': [
          {'kind': 'foo', 'package': 'core', 'reason': 'x'},
        ],
      },
    },
    'allow reason': {
      'check': {
        'allow': [
          {'kind': 'test', 'package': 'core', 'reason': ''},
        ],
      },
    },
  }.entries) {
    test(
      'config rejects ${entry.key}',
      () => expect(
        () => Config.parse(entry.value, packages),
        throwsA(isA<ToolException>()),
      ),
    );
  }
  test('filters apply glob paths, kinds and explicit-name ignore override', () {
    const config = Config(ignore: ['ui'], testIgnore: ['core']);
    expect(
      const Filters(scope: ['*']).skipReason(packages[1], config, 'test'),
      'ignored by config',
    );
    expect(
      const Filters(scope: ['ui']).skipReason(packages[1], config, 'test'),
      isNull,
    );
    expect(
      const Filters(
        scope: ['packages/ui'],
      ).skipReason(packages[1], config, 'test'),
      isNull,
    );
    expect(
      const Filters(
        scope: ['packages/*'],
      ).skipReason(packages[0], const Config(), 'test'),
      isNull,
    );
    expect(
      const Filters(
        scope: ['core'],
        ignore: ['core'],
      ).skipReason(packages[0], config, 'test'),
      'ignored by command line',
    );
    expect(
      const Filters(
        flutter: true,
      ).skipReason(packages[0], const Config(), 'test'),
      'package kind filter',
    );
    expect(
      const Filters(
        directoryPackages: {'ui'},
      ).skipReason(packages[0], const Config(), 'test'),
      'directory filter',
    );
    expect(
      const Filters(
        filePackages: {'ui'},
      ).skipReason(packages[0], const Config(), 'test'),
      'file filter',
    );
    expect(globMatches('**/*.g.dart', 'a.g.dart'), isTrue);
    expect(globMatches('packages/*', 'packages/ui/example'), isFalse);
  });
}

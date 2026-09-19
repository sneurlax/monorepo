import 'dart:convert';

import 'package:monorepo/monorepo.dart';
import 'package:test/test.dart';

void main() {
  Package pkg(
    String name,
    String relPath, {
    Map<String, Object?> deps = const {},
    Map<String, Object?> dev = const {},
    bool flutter = false,
  }) => Package(
    name: name,
    path: '/w/$relPath',
    relPath: relPath,
    isFlutter: flutter,
    localDeps: {...deps.keys, ...dev.keys},
    pubspec: {'name': name, 'dependencies': deps, 'dev_dependencies': dev},
  );

  final workspace = Workspace(
    root: '/w',
    packages: [
      pkg('core', 'packages/core', dev: {'test': '^1.0.0'}),
      pkg(
        'ui',
        'packages/ui',
        deps: {
          'core': null,
          'flutter': {'sdk': 'flutter'},
        },
        flutter: true,
      ),
      pkg(
        'example',
        'packages/ui/example',
        deps: {'ui': null},
        dev: {'core': null, 'ui': null},
        flutter: true,
      ),
    ],
  );
  final nodes = dependencyGraph(workspace);

  test('dependencies win over dev edges and external packages are ignored', () {
    expect(nodes.map((n) => '${n.dependencies} ${n.devDependencies}'), [
      '[] []',
      '[core] []',
      '[ui] [core]',
    ]);
  });

  test('text lists members in dependency order with their edges', () {
    expect(renderGraph(nodes, const [], 'text'), '''
core (packages/core, dart)
ui (packages/ui, flutter)
  -> core
example (packages/ui/example, flutter)
  -> ui
  -> core (dev)''');
  });

  test('dot marks dev edges dashed and Flutter members rounded', () {
    expect(renderGraph(nodes, const [], 'dot'), r'''
digraph workspace {
  node [shape=box];
  "core" [label="core\npackages/core"];
  "ui" [label="ui\npackages/ui", style=rounded];
  "example" [label="example\npackages/ui/example", style=rounded];
  "ui" -> "core";
  "example" -> "ui";
  "example" -> "core" [style=dashed, label="dev"];
}''');
  });

  test('mermaid prefixes ids and labels dev edges', () {
    expect(renderGraph(nodes, const [], 'mermaid'), '''
graph TD
  p_core["core"]
  p_ui("ui")
  p_example("example")
  p_ui --> p_core
  p_example --> p_ui
  p_example -. dev .-> p_core''');
  });

  test('json carries kind, edges and cycles among selected members', () {
    final json =
        jsonDecode(
              renderGraph(dependencyGraph(workspace, {'ui', 'example'}), const [
                ['example', 'ui'],
                ['core', 'other'],
              ], 'json'),
            )
            as Map<String, Object?>;
    expect(json['packages'], [
      {
        'name': 'ui',
        'path': 'packages/ui',
        'kind': 'flutter',
        'dependencies': <String>[],
        'devDependencies': <String>[],
      },
      {
        'name': 'example',
        'path': 'packages/ui/example',
        'kind': 'flutter',
        'dependencies': ['ui'],
        'devDependencies': <String>[],
      },
    ]);
    expect(json['cycles'], [
      ['example', 'ui'],
    ]);
  });
}

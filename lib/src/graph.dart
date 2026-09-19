import 'dart:convert';
import 'model.dart';

/// One member and its edges to other selected members, in workspace order.
class GraphNode {
  final Package package;
  final List<String> dependencies;
  final List<String> devDependencies;
  const GraphNode(this.package, this.dependencies, this.devDependencies);
}

/// The dependency graph between [selected] members. A member listed under
/// both dependencies and dev_dependencies counts as a regular dependency.
List<GraphNode> dependencyGraph(Workspace workspace, [Set<String>? selected]) {
  final names = selected ?? workspace.packages.map((p) => p.name).toSet();
  final order = {
    for (var i = 0; i < workspace.packages.length; i++)
      workspace.packages[i].name: i,
  };
  List<String> edges(Object? section, Package package) {
    if (section is! Map) return [];
    return section.keys
        .whereType<String>()
        .where((name) => names.contains(name) && name != package.name)
        .toList()
      ..sort((a, b) => order[a]!.compareTo(order[b]!));
  }

  return [
    for (final package in workspace.packages)
      if (names.contains(package.name))
        () {
          final deps = edges(package.pubspec['dependencies'], package);
          final dev = edges(
            package.pubspec['dev_dependencies'],
            package,
          ).where((name) => !deps.contains(name)).toList();
          return GraphNode(package, deps, dev);
        }(),
  ];
}

String _kind(Package package) => package.isFlutter ? 'flutter' : 'dart';

String _dotEscape(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

String _dotQuote(String value) => '"${_dotEscape(value)}"';

/// Renders the graph as `text`, `dot`, `mermaid`, or `json`. Nodes appear in
/// dependency order and edges point from a member to what it depends on.
String renderGraph(
  List<GraphNode> nodes,
  List<List<String>> cycles,
  String format,
) {
  final names = nodes.map((node) => node.package.name).toSet();
  final relevantCycles = cycles
      .where((cycle) => cycle.every(names.contains))
      .toList();
  switch (format) {
    case 'json':
      return const JsonEncoder.withIndent('  ').convert({
        'packages': [
          for (final node in nodes)
            {
              'name': node.package.name,
              'path': node.package.relPath,
              'kind': _kind(node.package),
              'dependencies': node.dependencies,
              'devDependencies': node.devDependencies,
            },
        ],
        'cycles': relevantCycles,
      });
    case 'dot':
      final buffer = StringBuffer('digraph workspace {\n')
        ..writeln('  node [shape=box];');
      for (final node in nodes) {
        buffer.writeln(
          '  ${_dotQuote(node.package.name)} [label="${_dotEscape(node.package.name)}\\n${_dotEscape(node.package.relPath)}"${node.package.isFlutter ? ', style=rounded' : ''}];',
        );
      }
      for (final node in nodes) {
        for (final dep in node.dependencies) {
          buffer.writeln(
            '  ${_dotQuote(node.package.name)} -> ${_dotQuote(dep)};',
          );
        }
        for (final dep in node.devDependencies) {
          buffer.writeln(
            '  ${_dotQuote(node.package.name)} -> ${_dotQuote(dep)} [style=dashed, label="dev"];',
          );
        }
      }
      buffer.write('}');
      return buffer.toString();
    case 'mermaid':
      // Prefixed ids keep package names such as `end` from being keywords.
      String id(String name) => 'p_$name';
      final buffer = StringBuffer('graph TD\n');
      for (final node in nodes) {
        final shape = node.package.isFlutter ? ['(', ')'] : ['[', ']'];
        buffer.writeln(
          '  ${id(node.package.name)}${shape[0]}"${node.package.name}"${shape[1]}',
        );
      }
      for (final node in nodes) {
        for (final dep in node.dependencies) {
          buffer.writeln('  ${id(node.package.name)} --> ${id(dep)}');
        }
        for (final dep in node.devDependencies) {
          buffer.writeln('  ${id(node.package.name)} -. dev .-> ${id(dep)}');
        }
      }
      return buffer.toString().trimRight();
    default:
      final buffer = StringBuffer();
      for (final node in nodes) {
        buffer.writeln(
          '${node.package.name} (${node.package.relPath}, ${_kind(node.package)})',
        );
        for (final dep in node.dependencies) {
          buffer.writeln('  -> $dep');
        }
        for (final dep in node.devDependencies) {
          buffer.writeln('  -> $dep (dev)');
        }
      }
      for (final cycle in relevantCycles) {
        buffer.writeln('cycle: ${cycle.join(', ')} (ordered by name)');
      }
      return buffer.toString().trimRight();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'model.dart';

export 'model.dart';

Map<String, Object?> readPubspec(String path) {
  final file = File(p.join(path, 'pubspec.yaml'));
  try {
    final value = loadYaml(file.readAsStringSync());
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw ToolException('${file.path} must be a mapping');
    }
    return value.cast<String, Object?>();
  } on FileSystemException catch (error) {
    throw ToolException('Cannot read ${file.path}: ${error.message}');
  } on YamlException catch (error) {
    throw ToolException('Invalid ${file.path}: $error');
  }
}

String forward(String path) => path.replaceAll('\\', '/');

Future<Workspace> discoverWorkspace({
  String? directory,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final cwd = p.normalize(p.absolute(directory ?? Directory.current.path));
  final Process process;
  try {
    process = await Process.start(
      'dart',
      ['pub', 'workspace', 'list', '--json'],
      workingDirectory: cwd,
      runInShell: Platform.isWindows,
      environment: {
        'DASH__SUPPRESS_ANALYTICS': 'true',
        'FLUTTER_SUPPRESS_ANALYTICS': 'true',
      },
    );
  } on ProcessException catch (error) {
    throw ToolException('Cannot discover workspace: ${error.message}');
  }
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(timeout);
    final out = await output;
    final err = await errors;
    if (code != 0) {
      throw ToolException(
        'dart pub workspace list failed ($code): ${err.trim()}',
      );
    }
    return workspaceFromJson(out);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw ToolException(
      'dart pub workspace list timed out after ${timeout.inSeconds}s',
    );
  }
}

Workspace workspaceFromJson(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (error) {
    throw ToolException('Invalid workspace discovery JSON: ${error.message}');
  }
  if (decoded is! Map ||
      decoded['packages'] is! List ||
      (decoded['packages'] as List).isEmpty) {
    throw const ToolException('Workspace discovery returned no packages');
  }
  final entries = (decoded['packages'] as List).map((entry) {
    if (entry is! Map || entry['name'] is! String || entry['path'] is! String) {
      throw const ToolException('Malformed workspace package entry');
    }
    return (
      name: entry['name'] as String,
      path: p.normalize(p.absolute(entry['path'] as String)),
    );
  }).toList();
  final root = entries.first.path;
  final members = entries.skip(1).toList();
  final names = members.map((entry) => entry.name).toSet();
  if (names.length != members.length) {
    throw const ToolException('Duplicate workspace package names');
  }
  final packages = <Package>[];
  for (final entry in members) {
    if (!p.isWithin(root, entry.path)) {
      throw ToolException('Workspace member ${entry.name} is outside $root');
    }
    final spec = readPubspec(entry.path);
    if (spec['name'] != entry.name) {
      throw ToolException('Workspace name mismatch at ${entry.path}');
    }
    final deps = spec['dependencies'] is Map
        ? spec['dependencies'] as Map
        : <Object?, Object?>{};
    final dev = spec['dev_dependencies'] is Map
        ? spec['dev_dependencies'] as Map
        : <Object?, Object?>{};
    bool sdk(Object? value) => value is Map && value['sdk'] == 'flutter';
    packages.add(
      Package(
        name: entry.name,
        path: entry.path,
        relPath: forward(p.relative(entry.path, from: root)),
        isFlutter: sdk(deps['flutter']) || sdk(dev['flutter_test']),
        hasTest: Directory(p.join(entry.path, 'test')).existsSync(),
        hasIntegrationTest: Directory(
          p.join(entry.path, 'integration_test'),
        ).existsSync(),
        localDeps: {
          ...deps.keys.whereType<String>(),
          ...dev.keys.whereType<String>(),
        }.intersection(names),
        pubspec: spec,
      ),
    );
  }
  final sorted = orderPackages(packages);
  return Workspace(
    root: root,
    packages: sorted.packages,
    cycles: sorted.cycles,
    pubspec: readPubspec(root),
  );
}

/// Sort strongly connected components, retaining dependency order outside cycles.
({List<Package> packages, List<List<String>> cycles}) orderPackages(
  List<Package> packages,
) {
  final byName = {for (final package in packages) package.name: package};
  final names = byName.keys.toList()..sort();
  final indexes = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final components = <List<String>>[];
  var index = 0;
  void visit(String name) {
    indexes[name] = index;
    low[name] = index++;
    stack.add(name);
    onStack.add(name);
    final deps = byName[name]!.localDeps.where(byName.containsKey).toList()
      ..sort();
    for (final dep in deps) {
      if (!indexes.containsKey(dep)) {
        visit(dep);
        if (low[dep]! < low[name]!) low[name] = low[dep]!;
      } else if (onStack.contains(dep) && indexes[dep]! < low[name]!) {
        low[name] = indexes[dep]!;
      }
    }
    if (low[name] == indexes[name]) {
      final component = <String>[];
      String item;
      do {
        item = stack.removeLast();
        onStack.remove(item);
        component.add(item);
      } while (item != name);
      component.sort();
      components.add(component);
    }
  }

  for (final name in names) {
    if (!indexes.containsKey(name)) visit(name);
  }
  final componentOf = <String, int>{};
  for (var i = 0; i < components.length; i++) {
    for (final name in components[i]) {
      componentOf[name] = i;
    }
  }
  final remaining = {for (var i = 0; i < components.length; i++) i};
  final done = <int>{};
  final result = <Package>[];
  while (remaining.isNotEmpty) {
    final ready =
        remaining
            .where(
              (i) => components[i].every(
                (name) => byName[name]!.localDeps
                    .where(componentOf.containsKey)
                    .every(
                      (dep) =>
                          componentOf[dep] == i ||
                          done.contains(componentOf[dep]),
                    ),
              ),
            )
            .toList()
          ..sort((a, b) => components[a].first.compareTo(components[b].first));
    final selected = ready.first;
    result.addAll(components[selected].map((name) => byName[name]!));
    remaining.remove(selected);
    done.add(selected);
  }
  final cycles =
      components
          .where(
            (c) =>
                c.length > 1 || byName[c.single]!.localDeps.contains(c.single),
          )
          .toList()
        ..sort((a, b) => a.first.compareTo(b.first));
  return (packages: result, cycles: cycles);
}

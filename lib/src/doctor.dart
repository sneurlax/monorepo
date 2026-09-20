import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';
import 'config.dart';
import 'filters.dart';
import 'model.dart';
import 'workspace.dart' show discoverWorkspace, forward;

class Diagnosis {
  /// `error`, `warning`, or `info`.
  final String severity;
  final String kind;
  final String message;
  const Diagnosis(this.severity, this.kind, this.message);
  Map<String, Object?> toJson() => {
    'severity': severity,
    'kind': kind,
    'message': message,
  };
}

class DoctorReport {
  final String? root;
  final List<Diagnosis> items;
  const DoctorReport(this.root, this.items);

  Iterable<Diagnosis> get errors => items.where((d) => d.severity == 'error');
  Iterable<Diagnosis> get warnings =>
      items.where((d) => d.severity == 'warning');

  bool hasProblems({bool strict = false}) =>
      errors.isNotEmpty || (strict && warnings.isNotEmpty);

  Map<String, Object?> toJson() => {
    'root': root,
    'errors': errors.map((d) => d.toJson()).toList(),
    'warnings': warnings.map((d) => d.toJson()).toList(),
    'info': items
        .where((d) => d.severity == 'info')
        .map((d) => d.toJson())
        .toList(),
  };

  String renderHuman() {
    final buffer = StringBuffer();
    if (root != null) buffer.writeln('workspace: $root');
    for (final item in items) {
      buffer.writeln(
        '${item.severity.padRight(7)}  ${item.kind}: ${item.message}',
      );
    }
    buffer.write('${errors.length} error(s), ${warnings.length} warning(s).');
    return buffer.toString();
  }
}

/// Runs an executable for a version probe and returns its combined output,
/// or null when it cannot be started or fails.
typedef ToolProbe =
    Future<String?> Function(String executable, List<String> arguments);

Future<String?> _probe(String executable, List<String> arguments) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: Platform.isWindows,
      environment: const {
        'DASH__SUPPRESS_ANALYTICS': 'true',
        'FLUTTER_SUPPRESS_ANALYTICS': 'true',
      },
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 60));
    if (result.exitCode != 0) return null;
    return '${result.stdout}${result.stderr}';
  } on ProcessException {
    return null;
  } on TimeoutException {
    return null;
  }
}

String? _which(String name) {
  final path = Platform.environment['PATH'] ?? '';
  final extensions = Platform.isWindows ? ['.exe', '.bat', '.cmd', ''] : [''];
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    for (final extension in extensions) {
      final candidate = p.join(directory, '$name$extension');
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

Future<void> _discover(String root) => discoverWorkspace(directory: root);

/// The nearest directory at or above [start] whose pubspec declares a
/// workspace.
String? findWorkspaceRoot(String start) {
  var directory = p.normalize(p.absolute(start));
  while (true) {
    final file = File(p.join(directory, 'pubspec.yaml'));
    if (file.existsSync()) {
      try {
        final yaml = loadYaml(file.readAsStringSync());
        if (yaml is Map && yaml.containsKey('workspace')) return directory;
      } on YamlException {
        // Keep walking; a broken nested pubspec is not the root.
      }
    }
    final parent = p.dirname(directory);
    if (parent == directory) return null;
    directory = parent;
  }
}

/// Directory names never searched for nested pubspecs.
bool _skipDirectory(Directory directory) {
  final name = p.basename(directory.path);
  return name.startsWith('.') ||
      name == 'build' ||
      name == 'node_modules' ||
      File(p.join(directory.path, 'CACHEDIR.TAG')).existsSync();
}

/// Expands one workspace entry, which may use `*`, `?` and `[...]` within
/// path segments, to the directories it names.
List<String> _expandEntry(String root, String entry) {
  final segments = p.posix.split(p.posix.normalize(entry));
  var matches = [''];
  for (final segment in segments) {
    final next = <String>[];
    for (final prefix in matches) {
      if (!RegExp(r'[*?\[]').hasMatch(segment)) {
        next.add(p.posix.join(prefix, segment));
        continue;
      }
      final directory = Directory(p.join(root, prefix));
      if (!directory.existsSync()) continue;
      final names =
          directory
              .listSync(followLinks: false)
              .whereType<Directory>()
              .map((d) => p.basename(d.path))
              .where(
                (name) => !name.startsWith('.') && globMatches(segment, name),
              )
              .toList()
            ..sort();
      next.addAll(names.map((name) => p.posix.join(prefix, name)));
    }
    matches = next;
  }
  return matches;
}

/// Labels grouped by what their constraints allow, so `>=3.10.0 <4.0.0`
/// and `^3.10.0` are one group. Text that is not a version constraint, such
/// as a path or git dependency, groups by its spelling.
class _ConstraintGroups {
  final _groups =
      <({Object key, List<String> spellings, List<String> labels})>[];

  int get length => _groups.length;

  void add(String text, String label) {
    Object key;
    try {
      key = VersionConstraint.parse(text);
    } on FormatException {
      key = text;
    }
    for (final group in _groups) {
      if (group.key == key) {
        if (!group.spellings.contains(text)) group.spellings.add(text);
        group.labels.add(label);
        return;
      }
    }
    _groups.add((key: key, spellings: [text], labels: [label]));
  }

  /// `spelling (labels); ...`, sorted by spelling; equivalent spellings are
  /// joined with ` = `.
  String describe() {
    final parts = [
      for (final group in _groups)
        '${(group.spellings..sort()).join(' = ')} (${(group.labels..sort()).join(', ')})',
    ]..sort();
    return parts.join('; ');
  }
}

String _constraint(Object? value) {
  if (value == null) return 'any';
  if (value is String) return value;
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return keys
        .map((key) {
          final v = value[key];
          return '$key: ${v is Map ? '{${_constraint(v)}}' : v}';
        })
        .join(', ');
  }
  return value.toString();
}

/// Reads workspace health without running pub or changing files. Only
/// `dart`/`flutter --version` and the metadata-only workspace listing run.
Future<DoctorReport> diagnose(
  String start, {
  ToolProbe probe = _probe,
  String? Function(String name) which = _which,
  Future<void> Function(String root) discover = _discover,
}) async {
  final items = <Diagnosis>[];
  void add(String severity, String kind, String message) =>
      items.add(Diagnosis(severity, kind, message));

  final dartPath = which('dart');
  final dartOutput = dartPath == null
      ? null
      : await probe('dart', ['--version']);
  final dartVersionText = dartOutput == null
      ? null
      : RegExp(r'Dart SDK version: (\S+)').firstMatch(dartOutput)?.group(1);
  Version? dartVersion;
  if (dartVersionText != null) {
    try {
      dartVersion = Version.parse(dartVersionText);
    } on FormatException {
      dartVersion = null;
    }
  }

  final root = findWorkspaceRoot(start);
  if (root == null) {
    add(
      'error',
      'workspace',
      'no pubspec.yaml with a workspace: list at or above ${p.normalize(p.absolute(start))}',
    );
  }

  final members = <String, Map<Object?, Object?>>{}; // relPath -> pubspec
  final names = <String, String>{}; // name -> relPath
  Map<Object?, Object?> rootSpec = const {};
  if (root != null) {
    rootSpec =
        loadYaml(File(p.join(root, 'pubspec.yaml')).readAsStringSync())
            as Map<Object?, Object?>;
    final entries = rootSpec['workspace'];
    if (entries is! List || entries.any((e) => e is! String)) {
      add('error', 'workspace', 'workspace: must be a list of paths');
    } else {
      final seen = <String>{};
      for (final entry in entries.cast<String>()) {
        final normalized = p.posix.normalize(entry.replaceAll('\\', '/'));
        if (!seen.add(normalized)) {
          add('warning', 'workspace', 'entry $entry is listed more than once');
          continue;
        }
        final glob = RegExp(r'[*?\[]').hasMatch(normalized);
        final directories = _expandEntry(root, normalized);
        // Pub skips glob matches without a pubspec.yaml; only an explicit
        // entry must have one.
        final expanded = glob
            ? directories
                  .where(
                    (relPath) => File(
                      p.join(root, relPath, 'pubspec.yaml'),
                    ).existsSync(),
                  )
                  .toList()
            : directories;
        if (directories.isEmpty) {
          add('error', 'workspace', 'entry $entry matches no directory');
        } else if (expanded.isEmpty) {
          add(
            'error',
            'workspace',
            'entry $entry matches no directory with a pubspec.yaml',
          );
        }
        for (final relPath in expanded) {
          final directory = Directory(p.join(root, relPath));
          final pubspec = File(p.join(directory.path, 'pubspec.yaml'));
          if (!directory.existsSync()) {
            add('error', 'workspace', 'entry $relPath does not exist');
            continue;
          }
          if (!pubspec.existsSync()) {
            add('error', 'workspace', 'entry $relPath has no pubspec.yaml');
            continue;
          }
          final Object? spec;
          try {
            spec = loadYaml(pubspec.readAsStringSync());
          } on YamlException catch (error) {
            add('error', 'pubspec', '$relPath/pubspec.yaml: ${error.message}');
            continue;
          }
          if (spec is! Map) {
            add('error', 'pubspec', '$relPath/pubspec.yaml is not a mapping');
            continue;
          }
          final name = spec['name'];
          if (name is! String) {
            add('error', 'pubspec', '$relPath/pubspec.yaml has no name');
            continue;
          }
          if (names.containsKey(name)) {
            add(
              'error',
              'workspace',
              'package name $name is used by ${names[name]} and $relPath',
            );
            continue;
          }
          names[name] = relPath;
          members[relPath] = spec.cast<Object?, Object?>();
          if (spec['resolution'] != 'workspace') {
            add(
              'error',
              'resolution',
              '$name ($relPath) is listed in the workspace but lacks resolution: workspace',
            );
          }
        }
      }
    }
  }

  if (root != null) {
    // Nested packages that are not members.
    final memberPaths = members.keys.toSet();
    final nested = <String>[];
    final claiming = <String>[];
    void walk(Directory directory) {
      final entries = directory.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        if (entry is! Directory || _skipDirectory(entry)) continue;
        final relPath = forward(p.relative(entry.path, from: root));
        final pubspec = File(p.join(entry.path, 'pubspec.yaml'));
        if (pubspec.existsSync() && !memberPaths.contains(relPath)) {
          Object? spec;
          try {
            spec = loadYaml(pubspec.readAsStringSync());
          } on YamlException {
            spec = null;
          }
          if (spec is Map && spec['resolution'] == 'workspace') {
            claiming.add(relPath);
          } else {
            nested.add(relPath);
          }
        }
        walk(entry);
      }
    }

    walk(Directory(root));
    for (final relPath in claiming) {
      add(
        'warning',
        'membership',
        '$relPath declares resolution: workspace but is not listed in the root workspace',
      );
    }
    if (nested.isNotEmpty) {
      add(
        'info',
        'membership',
        '${nested.length} nested non-member package(s), fenced out of formatting and --since: ${nested.join(', ')}',
      );
    }

    // Lockfiles and resolution output.
    if (!File(p.join(root, 'pubspec.lock')).existsSync()) {
      add(
        'warning',
        'lockfile',
        'no root pubspec.lock; run dart pub get (or check that an untracked lock is intended)',
      );
    }
    if (!File(p.join(root, '.dart_tool', 'package_config.json')).existsSync()) {
      add(
        'warning',
        'resolution',
        'no .dart_tool/package_config.json at the root; run dart pub get before analyze, format or test',
      );
    }
    for (final relPath in members.keys.toList()..sort()) {
      for (final stray in ['pubspec.lock', '.dart_tool/package_config.json']) {
        if (File(p.join(root, relPath, stray)).existsSync()) {
          add(
            'warning',
            'lockfile',
            '$relPath/$stray is stray; workspace members resolve through the root',
          );
        }
      }
    }

    // SDK constraints.
    for (final sdk in ['sdk', 'flutter']) {
      final groups = _ConstraintGroups();
      for (final entry in {'.': rootSpec, ...members}.entries) {
        final environment = entry.value['environment'];
        final value = environment is Map ? environment[sdk] : null;
        if (value == null) continue;
        final label = entry.key == '.'
            ? '(root)'
            : (entry.value['name'] as String);
        groups.add(value.toString(), label);
        if (sdk == 'sdk' && dartVersion != null) {
          try {
            final constraint = VersionConstraint.parse(value.toString());
            if (!constraint.allows(dartVersion)) {
              add(
                'error',
                'sdk',
                '$label requires Dart $value but dart on PATH is $dartVersion',
              );
            }
          } on FormatException {
            add('error', 'sdk', '$label has an invalid SDK constraint: $value');
          }
        }
      }
      if (groups.length > 1) {
        add(
          'warning',
          'sdk',
          'members use different ${sdk == 'sdk' ? 'Dart SDK' : 'Flutter'} constraints: ${groups.describe()}',
        );
      }
    }

    // The same external dependency constrained differently.
    final constraints = <String, _ConstraintGroups>{};
    for (final spec in members.values) {
      for (final section in ['dependencies', 'dev_dependencies']) {
        final deps = spec[section];
        if (deps is! Map) continue;
        for (final entry in deps.entries) {
          final dep = entry.key.toString();
          final value = entry.value;
          if (names.containsKey(dep) ||
              (value is Map && value['sdk'] != null)) {
            continue;
          }
          constraints
              .putIfAbsent(dep, _ConstraintGroups.new)
              .add(_constraint(value), spec['name'] as String);
        }
      }
    }
    for (final dep in constraints.keys.toList()..sort()) {
      final groups = constraints[dep]!;
      if (groups.length < 2) continue;
      add(
        'warning',
        'dependencies',
        '$dep is constrained differently: ${groups.describe()}',
      );
    }

    // Optional configuration.
    if (rootSpec.containsKey('monorepo')) {
      try {
        if (rootSpec['monorepo'] == null) {
          throw const ToolException('monorepo must be a mapping, not null');
        }
        Config.parse(
          rootSpec['monorepo'],
          names.entries.map(
            (e) => Package(
              name: e.key,
              path: p.join(root, e.value),
              relPath: e.value,
            ),
          ),
        );
      } on ToolException catch (error) {
        add('error', 'config', error.message);
      }
    }
  }

  // Tools on PATH.
  if (dartPath == null) {
    add('error', 'tools', 'dart is not on PATH');
  } else if (dartVersion == null) {
    add('error', 'tools', 'dart at $dartPath did not report a version');
  } else {
    add('info', 'tools', 'dart $dartVersion ($dartPath)');
  }
  final needsFlutter = members.values.any((spec) {
    bool sdk(Object? v) => v is Map && v['sdk'] == 'flutter';
    final deps = spec['dependencies'];
    final dev = spec['dev_dependencies'];
    return (deps is Map && sdk(deps['flutter'])) ||
        (dev is Map && sdk(dev['flutter_test']));
  });
  final flutterPath = which('flutter');
  if (flutterPath == null) {
    add(
      needsFlutter ? 'error' : 'info',
      'tools',
      needsFlutter
          ? 'flutter is not on PATH but Flutter members exist'
          : 'flutter is not on PATH (no Flutter members)',
    );
  } else {
    final output = await probe('flutter', ['--version', '--machine']);
    final start = output?.indexOf('{') ?? -1;
    Object? json;
    if (output != null && start >= 0) {
      try {
        json = jsonDecode(output.substring(start, output.lastIndexOf('}') + 1));
      } on FormatException {
        json = null;
      }
    }
    if (json is Map && json['frameworkVersion'] is String) {
      add(
        'info',
        'tools',
        'flutter ${json['frameworkVersion']} with Dart ${json['dartSdkVersion']} ($flutterPath)',
      );
      Version? flutterVersion;
      try {
        flutterVersion = Version.parse(json['frameworkVersion'] as String);
      } on FormatException {
        flutterVersion = null;
      }
      for (final entry in {'.': rootSpec, ...members}.entries) {
        final environment = entry.value['environment'];
        final value = environment is Map ? environment['flutter'] : null;
        if (value == null || flutterVersion == null) continue;
        try {
          if (!VersionConstraint.parse(
            value.toString(),
          ).allows(flutterVersion)) {
            add(
              'error',
              'sdk',
              '${entry.key == '.' ? '(root)' : entry.value['name']} requires Flutter $value but flutter on PATH is $flutterVersion',
            );
          }
        } on FormatException {
          add('error', 'sdk', 'invalid Flutter constraint: $value');
        }
      }
    } else {
      add(
        needsFlutter ? 'error' : 'warning',
        'tools',
        'flutter at $flutterPath did not report a version',
      );
    }
  }

  // The discovery every other command relies on.
  if (root != null && dartVersion != null) {
    try {
      await discover(root);
    } on ToolException catch (error) {
      add(
        'error',
        'workspace',
        '${error.message}; other monorepo commands exit 2 until this succeeds',
      );
    }
  }

  const order = {'error': 0, 'warning': 1, 'info': 2};
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final severity = order[a.$2.severity]!.compareTo(order[b.$2.severity]!);
    return severity != 0 ? severity : a.$1.compareTo(b.$1);
  });
  return DoctorReport(root, [for (final (_, item) in indexed) item]);
}

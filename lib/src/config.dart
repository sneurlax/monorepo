import 'package:yaml/yaml.dart';

import 'model.dart';

class Script {
  /// The shell body, or the steps joined by newlines for listing.
  final String run;
  final String description;

  /// Ordered shell bodies run as separate steps; empty for a single body.
  final List<String> steps;

  /// Root-relative directory the script runs in.
  final String cwd;

  /// Extra environment; `$MONOREPO_ROOT` in values becomes the root path.
  final Map<String, String> env;
  const Script(this.run, [this.description = ''])
    : steps = const [],
      cwd = '.',
      env = const {};
  const Script.full({
    required this.run,
    this.description = '',
    this.steps = const [],
    this.cwd = '.',
    this.env = const {},
  });

  /// The bodies that run, in order.
  List<String> get bodies => steps.isEmpty ? [run] : steps;
}

class Allow {
  final String kind;
  final String package;
  final String reason;
  const Allow(this.kind, this.package, this.reason);
}

class Config {
  final List<String> ignore;
  final List<String> testIgnore;
  final List<String> testArgs;
  final List<String> analyzeArgs;
  final List<String> formatExclude;
  final Map<String, Script> scripts;
  final List<String> workflows;
  final List<Allow> allow;
  const Config({
    this.ignore = const [],
    this.testIgnore = const [],
    this.testArgs = const [],
    this.analyzeArgs = const [],
    this.formatExclude = const [],
    this.scripts = const {},
    this.workflows = const ['.gitea/workflows', '.github/workflows'],
    this.allow = const [],
  });

  factory Config.parse(Object? input, Iterable<Package> packages) {
    if (input == null) return const Config();
    final names = packages.map((p) => p.name).toSet();
    final map = _map(input, 'monorepo', {
      'ignore',
      'test',
      'analyze',
      'format',
      'scripts',
      'check',
    });
    List<String> strings(Object? value, String at) {
      if (value == null) return [];
      if (value is! List || value.any((v) => v is! String || v.isEmpty)) {
        throw ToolException('$at must be a list of non-empty strings');
      }
      return value.cast<String>();
    }

    List<String> known(Object? value, String at) {
      final result = strings(value, at);
      for (final name in result) {
        if (!names.contains(name)) {
          throw ToolException('$at: unknown package "$name"');
        }
      }
      return result;
    }

    final test = _map(map['test'] ?? <String, Object?>{}, 'monorepo.test', {
      'ignore',
      'args',
    });
    final analyze = _map(
      map['analyze'] ?? <String, Object?>{},
      'monorepo.analyze',
      {'args'},
    );
    final format = _map(
      map['format'] ?? <String, Object?>{},
      'monorepo.format',
      {'exclude'},
    );
    final check = _map(map['check'] ?? <String, Object?>{}, 'monorepo.check', {
      'workflows',
      'allow',
    });
    final scripts = <String, Script>{};
    final rawScripts = map['scripts'] ?? <String, Object?>{};
    if (rawScripts is! Map) {
      throw const ToolException('monorepo.scripts must be a mapping');
    }
    for (final entry in rawScripts.entries) {
      if (entry.key is! String || (entry.key as String).isEmpty) {
        throw const ToolException('Script names must be non-empty strings');
      }
      final value = entry.value;
      if (value is String && value.trim().isNotEmpty) {
        scripts[entry.key as String] = Script(value);
      } else {
        final name = entry.key as String;
        final script = _map(value, 'script $name', {
          'run',
          'steps',
          'description',
          'cwd',
          'env',
        });
        _rejectNulls(script, 'script $name');
        final run = script['run'];
        final rawSteps = script['steps'];
        final description = script['description'] ?? '';
        if ((run == null) == (rawSteps == null) ||
            (run != null && (run is! String || run.trim().isEmpty)) ||
            description is! String) {
          throw ToolException(
            'Script $name requires either a run string or a steps list, and an optional description string',
          );
        }
        final steps = rawSteps == null
            ? const <String>[]
            : rawSteps is List &&
                  rawSteps.isNotEmpty &&
                  rawSteps.every((s) => s is String && s.trim().isNotEmpty)
            ? rawSteps.cast<String>().toList()
            : throw ToolException(
                'Script $name steps must be a non-empty list of non-empty strings',
              );
        final rawCwd = script['cwd'] ?? '.';
        if (rawCwd is! String ||
            rawCwd.isEmpty ||
            rawCwd.startsWith('/') ||
            RegExp(r'^[A-Za-z]:').hasMatch(rawCwd) ||
            rawCwd.replaceAll('\\', '/').split('/').contains('..')) {
          throw ToolException(
            'Script $name cwd must be a relative path inside the workspace',
          );
        }
        final rawEnv = script['env'] ?? <String, Object?>{};
        if (rawEnv is! Map ||
            rawEnv.entries.any(
              (e) =>
                  e.key is! String ||
                  !RegExp(
                    r'^[A-Za-z_][A-Za-z0-9_]*$',
                  ).hasMatch(e.key as String) ||
                  e.key == 'MONOREPO_ROOT' ||
                  e.value is Map ||
                  e.value is List,
            )) {
          throw ToolException(
            'Script $name env must map variable names other than MONOREPO_ROOT to scalar values',
          );
        }
        scripts[name] = Script.full(
          run: run as String? ?? steps.join('\n'),
          description: description,
          steps: steps,
          cwd: rawCwd.replaceAll('\\', '/'),
          env: {
            for (final e in rawEnv.entries)
              e.key as String: _scalarText(rawEnv, e.key, e.value),
          },
        );
      }
    }
    final allowed = <Allow>[];
    if (check.containsKey('allow')) {
      final raw = check['allow'];
      if (raw is! List) {
        throw const ToolException('monorepo.check.allow must be a list');
      }
      for (final value in raw) {
        final rule = _map(value, 'check.allow entry', {
          'kind',
          'package',
          'reason',
        });
        if (!{'test', 'analyze', 'format'}.contains(rule['kind']) ||
            rule['package'] is! String ||
            !names.contains(rule['package']) ||
            rule['reason'] is! String ||
            (rule['reason'] as String).trim().isEmpty) {
          throw const ToolException(
            'check.allow needs kind test/analyze/format, a known package, and a non-empty reason',
          );
        }
        allowed.add(
          Allow(
            rule['kind'] as String,
            rule['package'] as String,
            rule['reason'] as String,
          ),
        );
      }
    }
    // A present null is malformed, rather than silently falling back to defaults.
    _rejectNulls(map, 'monorepo');
    return Config(
      ignore: known(map['ignore'], 'monorepo.ignore'),
      testIgnore: known(test['ignore'], 'monorepo.test.ignore'),
      testArgs: strings(test['args'], 'monorepo.test.args'),
      analyzeArgs: strings(analyze['args'], 'monorepo.analyze.args'),
      formatExclude: strings(format['exclude'], 'monorepo.format.exclude'),
      scripts: scripts,
      workflows: check.containsKey('workflows')
          ? strings(check['workflows'], 'monorepo.check.workflows')
          : const ['.gitea/workflows', '.github/workflows'],
      allow: allowed,
    );
  }
}

/// The text a variable gets, as written: YAML would read a plain `3.10` as
/// the number 3.1 and `0755` as 755, so plain scalars keep their source text.
/// Quoted and block scalars are strings already.
String _scalarText(Map<Object?, Object?> map, Object? key, Object? value) {
  if (value is String) return value;
  final node = map is YamlMap ? map.nodes[key] : null;
  if (node is YamlScalar && node.style == ScalarStyle.PLAIN) {
    return node.span.text;
  }
  return value.toString();
}

void _rejectNulls(Map<Object?, Object?> map, String at) {
  for (final entry in map.entries) {
    if (entry.value == null) {
      throw ToolException('$at.${entry.key} must not be null');
    }
    if (entry.value is Map) {
      _rejectNulls(
        (entry.value as Map).cast<Object?, Object?>(),
        '$at.${entry.key}',
      );
    }
  }
}

Map<Object?, Object?> _map(Object? input, String at, Set<String> keys) {
  if (input is! Map) throw ToolException('$at must be a mapping');
  for (final key in input.keys) {
    if (key is! String || !keys.contains(key)) {
      throw ToolException('$at: unknown key "$key"');
    }
  }
  return input.cast<Object?, Object?>();
}

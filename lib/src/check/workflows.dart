import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../model.dart';
import 'shell.dart';

/// A shell body and its static workflow context. This never executes the body.
class WorkflowStep {
  final String file;
  final int line;
  final String run;

  /// Root-relative or an [externalMarker] path.
  final String workingDirectory;

  /// [workingDirectory] as an absolute marker path, so paths relative to a
  /// directory outside the checkout still resolve.
  String get location =>
      _location ??
      (p.posix.isAbsolute(workingDirectory) || workingDirectory.contains(r'$')
          ? workingDirectory
          : p.posix.normalize(p.posix.join(root, workingDirectory)));
  final String? _location;
  final bool dynamicContext;

  /// Why [dynamicContext] is set, for the warning message.
  final String? dynamicReason;

  /// The job id, or the script name for configured scripts.
  final String job;

  /// Shell variables whose values are statically known for this step.
  final Map<String, String> environment;

  /// Where the checkout root sits relative to [workspaceMarker].
  final String root;

  const WorkflowStep({
    required this.file,
    required this.line,
    required this.run,
    required this.workingDirectory,
    this.dynamicContext = false,
    this.dynamicReason,
    this.job = '',
    this.environment = const {},
    this.root = workspaceMarker,
    String? location,
  }) : _location = location;
}

/// Extracts jobs' run steps, honoring workflow/job/step directory precedence.
/// Jobs with a static `strategy.matrix` yield one copy of each step per
/// matrix combination, with `${{ matrix.* }}` and `${{ env.* }}` resolved.
List<WorkflowStep> readWorkflowSteps(String root, List<String> directories) {
  final files = <String>{};
  for (final directory in directories) {
    final location = p.normalize(p.join(root, directory));
    final type = FileSystemEntity.typeSync(location);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.directory) {
      throw ToolException('Workflow directory is not a directory: $directory');
    }
    for (final entity in Directory(
      location,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is File &&
          {'.yml', '.yaml'}.contains(p.extension(entity.path))) {
        files.add(entity.path);
      }
    }
  }
  final steps = <WorkflowStep>[];
  for (final file in files.toList()..sort()) {
    final text = File(file).readAsStringSync();
    final YamlNode document;
    try {
      document = loadYamlNode(text, sourceUrl: Uri.file(file));
    } on YamlException catch (error) {
      throw ToolException('Invalid workflow $file: $error');
    }
    if (document is! YamlMap) continue;
    final jobs = document['jobs'];
    if (jobs is! YamlMap) continue;
    final relativeFile = p.relative(file, from: root).replaceAll('\\', '/');
    final workflowDirectory = _defaultDirectory(document);
    for (final entry in jobs.entries) {
      final job = entry.value;
      if (job is! YamlMap) continue;
      final jobSteps = job['steps'];
      if (jobSteps is! YamlList) continue;
      final combinations = matrixCombinations(job);
      for (final matrix in combinations ?? [null]) {
        steps.addAll(
          _jobSteps(
            relativeFile,
            entry.key.toString(),
            document,
            job,
            jobSteps,
            matrix,
            workflowDirectory,
          ),
        );
      }
    }
  }
  return steps;
}

/// Values available to `${{ }}` expressions. A null [matrix] means the job's
/// matrix is not static, so matrix references stay unresolved. [env] holds
/// the declared `env:` values only; runner variables such as `HOME` are not
/// part of the `env` context. A null value is declared but not static.
class _Context {
  final Map<String, Object?>? matrix;
  final Map<String, String?> env;
  const _Context(this.matrix, this.env);

  String? evaluate(String expression) {
    final text = expression.trim();
    final literal = RegExp(r"^'((?:[^']|'')*)'$").firstMatch(text);
    if (literal != null) return literal.group(1)!.replaceAll("''", "'");
    if (!RegExp(r'^[A-Za-z_][\w-]*(?:\.[\w-]+)*$').hasMatch(text)) return null;
    final parts = text.split('.');
    switch (parts.first) {
      case 'matrix':
        Object? value = matrix;
        if (value == null) return null;
        for (final part in parts.skip(1)) {
          if (value is! Map || !value.containsKey(part)) return null;
          value = value[part];
        }
        return value is String || value is num || value is bool
            ? value.toString()
            : null;
      case 'env':
        return parts.length == 2 ? env[parts[1]] : null;
      case 'github':
        return switch (text) {
          'github.workspace' => workspaceMarker,
          // The same files the shell reaches through these variables, so
          // appends through either spelling are tracked alike.
          'github.env' => r'$GITHUB_ENV',
          'github.path' => r'$GITHUB_PATH',
          _ => null,
        };
      case 'runner':
        return {'runner.temp', 'runner.tool_cache'}.contains(text)
            ? '$externalMarker/${parts[1]}'
            : null;
    }
    return null;
  }

  /// Substitutes every expression, as the runner does before a shell starts.
  /// Unresolved expressions become a single dynamic word.
  ({String text, List<String> unresolved}) expand(String input) {
    final unresolved = <String>[];
    final text = input.replaceAllMapped(RegExp(r'\$\{\{(.*?)\}\}'), (match) {
      final value = evaluate(match.group(1)!);
      if (value != null) return value;
      unresolved.add(match.group(0)!);
      return '\${{${match.group(1)!.trim().replaceAll(RegExp(r'[^\w.-]+'), '_')}}}';
    });
    return (text: text, unresolved: unresolved);
  }
}

/// Runner variables the shell sees. They are not in the `env` context.
const _builtinEnvironment = {
  'GITHUB_WORKSPACE': workspaceMarker,
  'RUNNER_TEMP': '$externalMarker/temp',
  'RUNNER_TOOL_CACHE': '$externalMarker/tool_cache',
  'HOME': '$externalMarker/home',
};

// The runner owns these; whether a declared or appended value wins is not
// something the check relies on.
bool _protected(String name) =>
    name.startsWith('GITHUB_') || name.startsWith('RUNNER_');

/// Layers an `env:` mapping over [base]. A value that is not static maps the
/// name to null, so an unknown value never falls back to an outer definition.
Map<String, String?> _layerEnvironment(
  Map<String, String?> base,
  Object? env,
  Map<String, Object?>? matrix,
) {
  final result = {...base};
  if (env is! Map) return result;
  final context = _Context(matrix, base);
  for (final entry in env.entries) {
    final name = entry.key.toString();
    final value = entry.value;
    String? text;
    if (value is String || value is num || value is bool) {
      final expanded = context.expand(value.toString());
      if (expanded.unresolved.isEmpty) text = expanded.text;
    }
    result[name] = text;
  }
  return result;
}

/// The shell environment: runner variables overlaid with declared values.
/// [written] holds names earlier steps appended to `$GITHUB_ENV`; null means
/// an append could not be attributed, which leaves only protected runner
/// variables known.
Map<String, String> _shellEnvironment(
  Map<String, String?> declared,
  Set<String>? written,
) {
  final result = <String, String>{};
  for (final entry in _builtinEnvironment.entries) {
    final name = entry.key;
    if (written == null && !_protected(name)) continue;
    if (written != null && written.contains(name)) continue;
    if (declared.containsKey(name)) continue;
    result[name] = entry.value;
  }
  if (written == null) return result;
  for (final entry in declared.entries) {
    final value = entry.value;
    if (value == null || written.contains(entry.key)) continue;
    if (_builtinEnvironment.containsKey(entry.key) && _protected(entry.key)) {
      continue;
    }
    result[entry.key] = value;
  }
  return result;
}

/// Whether a `uses:` value names actions/checkout, written as a GitHub
/// shorthand or as a full URL such as Gitea accepts.
bool isCheckoutAction(Object? uses) => RegExp(
  r'^(?:https?://[^/\s]+/)?actions/checkout(?:\.git)?@',
).hasMatch(uses?.toString().trim() ?? '');

List<WorkflowStep> _jobSteps(
  String file,
  String jobName,
  YamlMap document,
  YamlMap job,
  YamlList jobSteps,
  Map<String, Object?>? matrix,
  String? workflowDirectory,
) {
  String? checkoutPath;
  for (final step in jobSteps) {
    if (step is! YamlMap || !isCheckoutAction(step['uses'])) continue;
    final withOptions = step['with'];
    if (withOptions is YamlMap && withOptions['repository'] != null) {
      continue; // A sibling repository's checkout is not our root.
    }
    checkoutPath = withOptions is YamlMap
        ? withOptions['path']?.toString()
        : null;
    break;
  }
  final dynamicCheckout = checkoutPath != null && checkoutPath.contains(r'$');
  final root = checkoutPath == null || dynamicCheckout
      ? workspaceMarker
      : p.posix.normalize(
          p.posix.join(workspaceMarker, checkoutPath.replaceAll('\\', '/')),
        );
  final workflowEnv = _layerEnvironment(const {}, document['env'], null);
  final jobEnv = _layerEnvironment(workflowEnv, job['env'], matrix);
  // Names a previous step appended to GITHUB_ENV; null once any write could
  // not be attributed, which leaves only runner-defined variables known.
  Set<String>? written = {};
  final jobDirectory = _defaultDirectory(job) ?? workflowDirectory;
  final result = <WorkflowStep>[];
  for (final step in jobSteps) {
    if (step is! YamlMap || !step.containsKey('run')) continue;
    final run = step['run'];
    if (run is! String) {
      throw ToolException('Workflow run value must be a string: $file');
    }
    final rawDirectory = step['working-directory'] ?? jobDirectory ?? '.';
    if (rawDirectory is! String) {
      throw ToolException('Workflow working-directory must be a string: $file');
    }
    final layered = _layerEnvironment(jobEnv, step['env'], matrix);
    final stepEnv = _shellEnvironment(layered, written);
    // After an append, `env.NAME` reflects the appended value as well.
    final context = _Context(matrix, {
      for (final entry in layered.entries)
        if (written != null && !written.contains(entry.key))
          entry.key: entry.value,
    });
    final directory = context.expand(rawDirectory.replaceAll('\\', '/'));
    final body = context.expand(run);
    String? reason;
    if (directory.unresolved.isNotEmpty) {
      reason =
          'working-directory ${directory.unresolved.first} is not static; no coverage inferred';
    } else if (directory.text.contains(r'$')) {
      reason =
          'working-directory "${directory.text}" is not static; no coverage inferred';
    } else if (dynamicCheckout) {
      reason =
          'checkout path "$checkoutPath" is not static; no coverage inferred';
    }
    // Relative directories are relative to the CI workspace, which holds
    // the checkout at its path.
    final location = joinLocation(workspaceMarker, directory.text);
    final runNode = step.nodes['run'];
    final spanText = (runNode?.span.text ?? '').trimLeft();
    final block = spanText.startsWith('|') || spanText.startsWith('>');
    result.add(
      WorkflowStep(
        file: file,
        line: (runNode?.span.start.line ?? 0) + (block ? 2 : 1),
        run: body.text,
        workingDirectory: reason == null
            ? rebasePath(location, root: root)
            : directory.text,
        location: reason == null ? location : directory.text,
        dynamicContext: reason != null,
        dynamicReason: reason,
        job: jobName,
        environment: stepEnv,
        root: root,
      ),
    );
    // A variable holding the env file's path appends to it too.
    var text = body.text;
    for (final entry in layered.entries) {
      if (entry.value?.contains('GITHUB_ENV') ?? false) {
        text = text.replaceAll(
          RegExp('\\\$\\{?${RegExp.escape(entry.key)}(?![A-Za-z0-9_])\\}?'),
          r'$GITHUB_ENV',
        );
      }
    }
    final writes = githubEnvWrites(text);
    written = writes == null || written == null
        ? null
        : {...written, ...writes};
  }
  return result;
}

/// Names a run body writes to `$GITHUB_ENV`, or null when a write cannot be
/// attributed to specific names. Every command that mentions the file must be
/// a plain `echo NAME=...` or `printf NAME=...` append to it; anything else
/// (grouped commands, `tee`, here-documents, an alias variable) is
/// unattributable.
Set<String>? githubEnvWrites(String run) {
  final names = <String>{};
  final append = RegExp(
    r'''^\s*(?:echo|printf)\s+(?:-[A-Za-z]+\s+)*["']?([A-Za-z_][A-Za-z0-9_]*)(?:=|<<)[^>]*>>\s*["']?\$\{?GITHUB_ENV\}?["']?\s*$''',
  );
  for (final command in _commandTexts(run)) {
    if (!command.contains('GITHUB_ENV')) continue;
    final match = append.firstMatch(command);
    if (match == null) return null;
    names.add(match.group(1)!);
  }
  return names;
}

/// Splits shell text into command texts at unquoted newlines, `;`, `&`, and
/// `|`, joining backslash continuations. Quotes stay in the text.
List<String> _commandTexts(String run) {
  final commands = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var i = 0; i < run.length; i++) {
    final char = run[i];
    if (char == '\\' && quote != "'" && i + 1 < run.length) {
      if (run[i + 1] != '\n') buffer.write(char + run[i + 1]);
      i++;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      buffer.write(char);
      continue;
    }
    if (char == '"' || char == "'") quote = char;
    if (char == '\n' || char == ';' || char == '&' || char == '|') {
      commands.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  commands.add(buffer.toString());
  return commands;
}

Object? _plain(Object? value) {
  if (value is YamlMap) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _plain(entry.value),
    };
  }
  if (value is YamlList) return value.map(_plain).toList();
  if (value is YamlScalar) return value.value;
  return value;
}

bool _matches(Object? actual, Object? expected) {
  if (expected is Map) {
    // GitHub treats exclude and include objects as partial matches.
    return actual is Map &&
        expected.entries.every(
          (e) => actual.containsKey(e.key) && _matches(actual[e.key], e.value),
        );
  }
  if (expected is List) {
    return actual is List &&
        actual.length == expected.length &&
        [
          for (var i = 0; i < actual.length; i++)
            _matches(actual[i], expected[i]),
        ].every((v) => v);
  }
  return actual == expected;
}

/// Static matrix combinations in GitHub's documented order: the cartesian
/// product, then `exclude`, then `include`. Returns `[{}]` for a job without
/// a matrix and null when the matrix is computed by an expression.
List<Map<String, Object?>>? matrixCombinations(YamlMap job) {
  final strategy = job['strategy'];
  if (strategy is! YamlMap || strategy['matrix'] == null) {
    return [<String, Object?>{}];
  }
  final matrix = _plain(strategy['matrix']);
  if (matrix is! Map) return null;
  bool computed(Object? value) =>
      value is String && value.contains(r'${{') ||
      value is Map && value.values.any(computed) ||
      value is List && value.any(computed);
  if (computed(matrix)) return null;
  final dimensions = <String, List<Object?>>{};
  for (final entry in matrix.entries) {
    if (entry.key == 'include' || entry.key == 'exclude') continue;
    if (entry.value is! List) return null;
    dimensions[entry.key.toString()] = entry.value as List<Object?>;
  }
  var combinations = <Map<String, Object?>>[];
  if (dimensions.isNotEmpty) {
    combinations = [<String, Object?>{}];
    for (final entry in dimensions.entries) {
      combinations = [
        for (final combination in combinations)
          for (final value in entry.value) {...combination, entry.key: value},
      ];
    }
  }
  for (final key in ['exclude', 'include']) {
    final value = matrix[key];
    if (value != null && (value is! List || value.any((v) => v is! Map))) {
      return null;
    }
  }
  final excludes = (matrix['exclude'] as List?)?.cast<Map<Object?, Object?>>();
  for (final exclude in excludes ?? const <Map<Object?, Object?>>[]) {
    combinations.removeWhere((combination) => _matches(combination, exclude));
  }
  final original = combinations.length;
  final includes = (matrix['include'] as List?)?.cast<Map<Object?, Object?>>();
  for (final include in includes ?? const <Map<Object?, Object?>>[]) {
    final values = {
      for (final entry in include.entries) entry.key.toString(): entry.value,
    };
    var added = false;
    for (var i = 0; i < original; i++) {
      final combination = combinations[i];
      // Included values may replace earlier included values, never the
      // original matrix values.
      final fits = values.entries.every(
        (e) =>
            !dimensions.containsKey(e.key) ||
            _matches(combination[e.key], e.value) &&
                _matches(e.value, combination[e.key]),
      );
      if (fits) {
        combination.addAll(values);
        added = true;
      }
    }
    if (!added) combinations.add(values);
  }
  return combinations;
}

String? _defaultDirectory(YamlMap map) {
  final defaults = map['defaults'];
  if (defaults is! YamlMap) return null;
  final run = defaults['run'];
  if (run is! YamlMap) return null;
  final directory = run['working-directory'];
  if (directory == null) return null;
  if (directory is! String) {
    throw const ToolException(
      'Workflow default working-directory must be a string',
    );
  }
  return directory;
}

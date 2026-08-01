import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config.dart';
import '../model.dart';
import '../ownership.dart';
import 'shell.dart';
import 'workflows.dart';

class Finding {
  final String kind;
  final String? package;
  final String file;
  final int line;
  final String message;

  const Finding({
    required this.kind,
    this.package,
    required this.file,
    required this.line,
    required this.message,
  });

  Map<String, Object?> toJson() => {
    'kind': kind,
    'package': package,
    'file': file,
    'line': line,
    'message': message,
  };
}

class CheckReport {
  final List<Finding> errors;
  final List<Finding> warnings;
  const CheckReport({required this.errors, required this.warnings});

  bool hasProblems({bool strict = false}) =>
      errors.isNotEmpty || (strict && warnings.isNotEmpty);

  Map<String, Object?> toJson() => {
    'errors': errors.map((f) => f.toJson()).toList(),
    'warnings': warnings.map((f) => f.toJson()).toList(),
  };

  String renderHuman() {
    final buffer = StringBuffer();
    final kinds = {
      ...errors.map((f) => f.kind),
      ...warnings.map((f) => f.kind),
    }.toList()..sort();
    for (final kind in kinds) {
      buffer.writeln('$kind:');
      for (final (severity, findings) in [
        ('error', errors),
        ('warning', warnings),
      ]) {
        for (final finding in findings.where((f) => f.kind == kind)) {
          final owner = finding.package == null ? '' : '${finding.package}: ';
          buffer.writeln(
            '  $severity $owner${finding.message} (${finding.file}:${finding.line})',
          );
        }
      }
    }
    buffer.writeln('${errors.length} error(s), ${warnings.length} warning(s).');
    return buffer.toString().trimRight();
  }
}

/// Examines workflow text and filesystem paths without running any shell code.
CheckReport checkWorkspace(
  Workspace workspace,
  Config config,
  Map<String, OwnedFiles> ownership,
) {
  return _Checker(workspace, config, ownership).run();
}

class _Checker {
  final Workspace workspace;
  final Config config;
  final Map<String, OwnedFiles> ownership;
  final errors = <Finding>[];
  final warnings = <Finding>[];
  final analyzed = <String>{};
  final tested = <String>{};
  final partial = <String, List<Finding>>{};
  final formatted = <String>{};

  _Checker(this.workspace, this.config, this.ownership);

  CheckReport run() {
    for (final step in readWorkflowSteps(workspace.root, config.workflows)) {
      _body(step, coverage: true);
    }
    for (final step in _scriptSteps()) {
      _body(step, coverage: false);
    }
    for (final package in workspace.packages) {
      if (config.ignore.contains(package.name)) continue;
      if (!analyzed.contains(package.name) && !_allowed('analyze', package)) {
        warnings.add(
          _gap('analyze', package, 'No workflow analyzes ${package.relPath}'),
        );
      }
      final missing =
          (ownership[package.name]?.files ?? const <String>[])
              .where((file) => !formatted.contains(file))
              .toList()
            ..sort();
      if (missing.isNotEmpty && !_allowed('format', package)) {
        warnings.add(
          _gap(
            'format',
            package,
            '${missing.length} owned Dart file(s) are not covered by workflow formatting: ${missing.take(5).join(', ')}',
          ),
        );
      }
      if (package.hasTest &&
          !config.testIgnore.contains(package.name) &&
          !tested.contains(package.name) &&
          !_allowed('test', package)) {
        errors.add(
          _gap(
            'test',
            package,
            'No workflow fully tests ${package.relPath}/test',
          ),
        );
        warnings.addAll(partial[package.name] ?? const []);
      }
    }
    int compare(Finding a, Finding b) {
      for (final difference in [
        a.kind.compareTo(b.kind),
        (a.package ?? '').compareTo(b.package ?? ''),
        a.file.compareTo(b.file),
        a.line.compareTo(b.line),
        a.message.compareTo(b.message),
      ]) {
        if (difference != 0) return difference;
      }
      return 0;
    }

    // A command can trigger the same warning through more than one path.
    List<Finding> unique(List<Finding> values) {
      final seen = <String>{};
      return values.where((f) => seen.add(f.toJson().toString())).toList()
        ..sort(compare);
    }

    return CheckReport(errors: unique(errors), warnings: unique(warnings));
  }

  bool _allowed(String kind, Package package) => config.allow.any(
    (allow) => allow.kind == kind && allow.package == package.name,
  );

  Finding _gap(String kind, Package package, String message) => Finding(
    kind: kind,
    package: package.name,
    file: 'pubspec.yaml',
    line: 1,
    message: message,
  );

  void _body(WorkflowStep step, {required bool coverage}) {
    if (step.dynamicContext) {
      warnings.add(
        Finding(
          kind: 'unparsed',
          file: step.file,
          line: step.line,
          message: 'Dynamic workflow context; no coverage inferred',
        ),
      );
      return;
    }
    if (!_path(
      step.workingDirectory,
      '.',
      step,
      step.line,
      kind: 'working-directory',
      directory: true,
    )) {
      return;
    }
    for (final command in parseShell(
      step.run,
      cwd: step.workingDirectory,
      line: step.line,
    )) {
      if (command.warning != null) {
        warnings.add(
          Finding(
            kind: 'unparsed',
            file: step.file,
            line: command.line,
            message: command.warning!,
          ),
        );
        continue;
      }
      final argv = command.argv;
      if (argv.isEmpty) continue;
      if (argv.first == 'cd') {
        final args = argv.skip(1).where((a) => a != '--').toList();
        if (args.length != 1 || args.first.startsWith('-')) {
          _unparsed(step, command, 'Unsupported cd arguments');
        } else {
          _path(
            args.first,
            command.cwd,
            step,
            command.line,
            kind: 'cd',
            directory: true,
          );
        }
        continue;
      }
      if (_isMelos(argv)) {
        if (coverage) {
          warnings.add(
            Finding(
              kind: 'melos',
              file: step.file,
              line: command.line,
              message:
                  'Melos invocation in CI; replace with raw commands. Coverage through Melos is not inferred.',
            ),
          );
        }
        continue;
      }
      if (argv.first == 'cargo') {
        for (var i = 1; i < argv.length; i++) {
          if (argv[i] == '--manifest-path') {
            if (i + 1 < argv.length) {
              _path(
                argv[++i],
                command.cwd,
                step,
                command.line,
                kind: 'cargo manifest',
              );
            } else {
              _unparsed(step, command, 'Missing cargo manifest path');
            }
          } else if (argv[i].startsWith('--manifest-path=')) {
            _path(
              argv[i].substring('--manifest-path='.length),
              command.cwd,
              step,
              command.line,
              kind: 'cargo manifest',
            );
          }
        }
        continue;
      }
      if (argv.length < 2 ||
          !{'dart', 'flutter'}.contains(argv.first) ||
          !{'analyze', 'format', 'test'}.contains(argv[1])) {
        // Setup and unrelated tools are outside this checker's coverage model.
        if (argv.any((a) => a == '__MONOREPO_UNPARSED_QUOTE__')) {
          _unparsed(step, command, 'Unclosed shell quote or substitution');
        }
        continue;
      }
      final runner = argv.first;
      final kind = argv[1];
      final paths = _arguments(argv.skip(2).toList(), kind, runner: runner);
      if (paths == null) {
        _unparsed(
          step,
          command,
          'Unsupported $kind options; no coverage inferred',
        );
        continue;
      }
      if (command.cwd.contains(r'$') || paths.any(_dynamicPath)) {
        _unparsed(step, command, 'Dynamic $kind path; no coverage inferred');
        continue;
      }
      var valid = true;
      for (final path in paths) {
        valid =
            _path(path, command.cwd, step, command.line, kind: kind) && valid;
      }
      if (!valid || !coverage) continue;
      final targets = paths.isEmpty
          ? [p.posix.normalize(command.cwd)]
          : paths.map((path) => _resolve(command.cwd, path)).toList();
      switch (kind) {
        case 'analyze':
          for (final package in workspace.packages) {
            if (targets.any((target) => _under(package.relPath, target))) {
              analyzed.add(package.name);
            }
          }
        case 'format':
          for (final files in ownership.values) {
            formatted.addAll(
              files.files.where(
                (file) => targets.any(
                  (target) =>
                      p.posix.normalize(file) == p.posix.normalize(target) ||
                      (_under(file, target) &&
                          !p.posix.basename(file).startsWith('.')),
                ),
              ),
            );
          }
        case 'test':
          for (final package in workspace.packages) {
            if (!package.hasTest) continue;
            final root = p.posix.normalize(package.relPath);
            final tests = p.posix.join(root, 'test');
            if (targets.any((target) => target == root || target == tests)) {
              tested.add(package.name);
            } else if (targets.any((target) => _under(target, tests))) {
              partial
                  .putIfAbsent(package.name, () => [])
                  .add(
                    Finding(
                      kind: 'partial-test',
                      package: package.name,
                      file: step.file,
                      line: command.line,
                      message:
                          'Workflow covers only part of ${package.relPath}/test',
                    ),
                  );
            }
          }
      }
    }
  }

  bool _path(
    String value,
    String cwd,
    WorkflowStep step,
    int line, {
    required String kind,
    bool directory = false,
  }) {
    if (_dynamicPath(value) || _dynamicPath(cwd)) {
      warnings.add(
        Finding(
          kind: 'unparsed',
          file: step.file,
          line: line,
          message: 'Dynamic $kind path "$value"; cannot verify it',
        ),
      );
      return false;
    }
    final relative = _resolve(cwd, value);
    final absolute = p.isAbsolute(relative)
        ? relative
        : p.join(workspace.root, relative);
    final type = FileSystemEntity.typeSync(absolute);
    if (type == FileSystemEntityType.notFound ||
        (directory && type != FileSystemEntityType.directory)) {
      errors.add(
        Finding(
          kind: 'stale-path',
          package: _owner(relative),
          file: step.file,
          line: line,
          message:
              '$kind path does not exist${directory ? ' as a directory' : ''}: $relative',
        ),
      );
      return false;
    }
    return true;
  }

  String? _owner(String path) {
    final matches =
        workspace.packages.where((pkg) => _under(path, pkg.relPath)).toList()
          ..sort((a, b) => b.relPath.length.compareTo(a.relPath.length));
    return matches.isEmpty ? null : matches.first.name;
  }

  void _unparsed(WorkflowStep step, ShellCommand command, String message) {
    warnings.add(
      Finding(
        kind: 'unparsed',
        file: step.file,
        line: command.line,
        message: message,
      ),
    );
  }

  Iterable<WorkflowStep> _scriptSteps() sync* {
    final pubspecFile = File(p.join(workspace.root, 'pubspec.yaml'));
    final YamlNode? node = pubspecFile.existsSync()
        ? loadYamlNode(pubspecFile.readAsStringSync())
        : null;
    int scriptLine(String section, String name) {
      if (node is! YamlMap) return 1;
      final parent = node[section];
      final scripts = parent is YamlMap ? parent['scripts'] : null;
      if (scripts is! YamlMap) return 1;
      final value = scripts.nodes[name];
      final run = value is YamlMap ? value.nodes['run'] : value;
      if (run == null) return 1;
      final block =
          run.span.text.trimLeft().startsWith('|') ||
          run.span.text.trimLeft().startsWith('>');
      return run.span.start.line + (block ? 2 : 1);
    }

    for (final entry in config.scripts.entries) {
      yield WorkflowStep(
        file: 'pubspec.yaml',
        line: scriptLine('monorepo', entry.key),
        run: entry.value.run,
        workingDirectory: '.',
      );
    }
    final melos = workspace.pubspec['melos'];
    final scripts = melos is Map ? melos['scripts'] : null;
    if (scripts is Map) {
      for (final entry in scripts.entries) {
        final value = entry.value;
        final run = value is String
            ? value
            : (value is Map ? value['run'] : null);
        if (run is String) {
          yield WorkflowStep(
            file: 'pubspec.yaml',
            line: scriptLine('melos', entry.key.toString()),
            run: run,
            workingDirectory: '.',
          );
        }
      }
    }
  }
}

bool _isMelos(List<String> argv) =>
    argv.first == 'melos' ||
    (argv.length >= 5 &&
        argv.take(4).join(' ') == 'dart pub global activate' &&
        argv[4] == 'melos');

bool _dynamicPath(String value) => RegExp(r'[$*?\[\]~]').hasMatch(value);

String _resolve(String cwd, String target) => p.posix.normalize(
  p.posix.join(cwd.replaceAll('\\', '/'), target.replaceAll('\\', '/')),
);

bool _under(String path, String parent) {
  final normalizedPath = p.posix.normalize(path);
  final normalizedParent = p.posix.normalize(parent);
  return normalizedPath == normalizedParent ||
      p.posix.isWithin(normalizedParent, normalizedPath);
}

List<String>? _arguments(
  List<String> args,
  String kind, {
  String runner = 'dart',
}) {
  final values = {
    '--output',
    '-o',
    '--line-length',
    '-l',
    '--page-width',
    '--language-version',
    '--concurrency',
    '-j',
    '--reporter',
    '-r',
    '--platform',
    '-p',
    '--device-id',
    '-d',
    '--tags',
    '-t',
    '--exclude-tags',
    '-x',
    '--name',
    '-n',
    '--plain-name',
    '-N',
    '--timeout',
    if (runner == 'dart') '--coverage',
    '--coverage-path',
    '--coverage-package',
    '--test-randomize-ordering-seed',
    '--total-shards',
    '--shard-index',
    '--file-reporter',
    '--preset',
    '-P',
    '--dart-define',
    '--dart-define-from-file',
    '--device-timeout',
    '--flavor',
    '--test-assets',
    '--use-application-binary',
    '--target-platform',
    '--dds-port',
    '--host-vmservice-port',
    '--vm-service-port',
  };
  final switches = {
    '--fatal-infos',
    '--no-fatal-infos',
    '--fatal-warnings',
    '--no-fatal-warnings',
    '--watch',
    '--no-pub',
    '--pub',
    '--set-exit-if-changed',
    '--fix',
    '--help',
    '-h',
    '--version',
    '--verbose',
    '-v',
    '--chain-stack-traces',
    '--no-chain-stack-traces',
    '--pause-after-load',
    '--run-skipped',
    '--fail-fast',
    '--no-fail-fast',
    '--ignore-timeouts',
    if (runner == 'flutter') ...['--coverage', '--no-coverage'],
    '--collect-coverage',
    '--merge-coverage',
    '--branch-coverage',
    '--no-track-widget-creation',
    '--track-widget-creation',
    '--update-goldens',
    '--reporter-verbose',
    '--enable-asserts',
    '--no-enable-asserts',
    '--test-randomize-ordering',
    '--null-assertions',
    '--enable-vmservice',
    '--no-enable-vmservice',
    '--enable-software-rendering',
    '--no-enable-impeller',
    '--enable-impeller',
    '--no-dds',
    '--dds',
    '--disable-service-auth-codes',
    '--enable-experiment',
  };
  final paths = <String>[];
  var literal = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (literal) {
      paths.add(arg);
    } else if (arg == '--') {
      literal = true;
    } else if (values.contains(arg)) {
      if (++i >= args.length) return null;
    } else if (switches.contains(arg)) {
      continue;
    } else if (arg.startsWith('-') && arg.contains('=')) {
      if (!values.contains(arg.split('=').first) &&
          !switches.contains(arg.split('=').first)) {
        return null;
      }
    } else if (RegExp(r'^-[jrtxnpNPdoPl].+').hasMatch(arg)) {
      continue;
    } else if (arg.startsWith('-')) {
      return null;
    } else {
      paths.add(arg);
    }
  }
  // Both runners require a path for formatting; no-path analysis/test use cwd.
  if (kind == 'format' && paths.isEmpty) return null;
  return paths;
}

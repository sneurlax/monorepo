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

  /// Individual sites summarized by a collapsed finding.
  final List<Finding>? sites;

  const Finding({
    required this.kind,
    this.package,
    required this.file,
    required this.line,
    required this.message,
    this.sites,
  });

  Map<String, Object?> toJson() => {
    'kind': kind,
    'package': package,
    'file': file,
    'line': line,
    'message': message,
    if (sites != null)
      'sites': [
        for (final site in sites!) {'line': site.line, 'message': site.message},
      ],
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

  /// GitHub workflow commands, one per finding, which Gitea Actions also
  /// turns into annotations. [prefix] is the workspace root's directory
  /// inside the repository, since annotation paths are repository-relative.
  String renderGithub({String prefix = ''}) {
    final buffer = StringBuffer();
    for (final (severity, findings) in [
      ('error', errors),
      ('warning', warnings),
    ]) {
      for (final finding in findings) {
        final file = prefix.isEmpty ? finding.file : '$prefix/${finding.file}';
        final owner = finding.package == null ? '' : '${finding.package}: ';
        buffer.writeln(
          '::$severity file=${_property(file)},line=${finding.line},'
          'title=${_property('monorepo check ${finding.kind}')}'
          '::${_data('$owner${finding.message}')}',
        );
      }
    }
    return buffer.toString();
  }
}

String _data(String value) => value
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A');

String _property(String value) =>
    _data(value).replaceAll(':', '%3A').replaceAll(',', '%2C');

/// The workspace root's path inside its git checkout, found by looking for
/// `.git` in [root] and its parents. Empty at the top or outside git.
String repositoryPrefix(String root) {
  var directory = p.normalize(p.absolute(root));
  while (true) {
    if (FileSystemEntity.typeSync(p.join(directory, '.git')) !=
        FileSystemEntityType.notFound) {
      final relative = p.relative(root, from: directory);
      return relative == '.' ? '' : relative.replaceAll('\\', '/');
    }
    final parent = p.dirname(directory);
    if (parent == directory) return '';
    directory = parent;
  }
}

/// Examines workflow text and filesystem paths without running any shell code.
///
/// Unresolved commands and Melos invocations are collapsed to one finding per
/// job unless [verbose] asks for every site.
CheckReport checkWorkspace(
  Workspace workspace,
  Config config,
  Map<String, OwnedFiles> ownership, {
  bool verbose = false,
}) {
  return _Checker(workspace, config, ownership, verbose).run();
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
  final bool verbose;

  /// Unparsed and Melos sites keyed by kind, file, and job before collapsing.
  final sites = <(String, String, String), List<Finding>>{};

  _Checker(this.workspace, this.config, this.ownership, this.verbose);

  CheckReport run() {
    for (final step in readWorkflowSteps(workspace.root, config.workflows)) {
      _body(step, coverage: true);
    }
    for (final step in _scriptSteps()) {
      _body(step, coverage: false);
    }
    _collapse();
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

  void _site(WorkflowStep step, String kind, int line, String message) {
    final finding = Finding(
      kind: kind,
      file: step.file,
      line: line,
      message: message,
    );
    final key = (kind, step.file, step.job);
    final list = sites.putIfAbsent(key, () => []);
    if (!list.any((f) => f.line == line && f.message == message)) {
      list.add(finding);
    }
  }

  void _collapse() {
    final keys = sites.keys.toList()
      ..sort((a, b) {
        for (final difference in [
          a.$1.compareTo(b.$1),
          a.$2.compareTo(b.$2),
          a.$3.compareTo(b.$3),
        ]) {
          if (difference != 0) return difference;
        }
        return 0;
      });
    for (final key in keys) {
      final list = sites[key]!
        ..sort((a, b) {
          final line = a.line.compareTo(b.line);
          return line != 0 ? line : a.message.compareTo(b.message);
        });
      if (verbose || list.length == 1) {
        warnings.addAll(list);
        continue;
      }
      final (kind, file, job) = key;
      final lines = {for (final f in list) f.line}.join(', ');
      final where = job.isEmpty ? '' : '${_jobLabel(job)}: ';
      warnings.add(
        Finding(
          kind: kind,
          file: file,
          line: list.first.line,
          message: kind == 'melos'
              ? '$where${list.length} Melos invocations (lines $lines); replace with raw commands. Coverage through Melos is not inferred.'
              : '$where${list.length} commands could not be resolved statically (lines $lines); no coverage inferred from them. First: ${list.first.message}. Use --verbose to list each.',
          sites: list,
        ),
      );
    }
  }

  String _jobLabel(String job) =>
      job.startsWith('script ') || job.startsWith('melos script ')
      ? job
      : 'job "$job"';

  void _body(WorkflowStep step, {required bool coverage}) {
    if (step.dynamicContext) {
      _site(
        step,
        'unparsed',
        step.line,
        step.dynamicReason ?? 'Dynamic workflow context; no coverage inferred',
      );
      return;
    }
    if (!_path(
      '.',
      step.location,
      step,
      step.line,
      kind: 'working-directory',
      directory: true,
    )) {
      return;
    }
    for (final command in parseShell(
      step.run,
      cwd: step.location,
      line: step.line,
      environment: step.environment,
      root: step.root,
    )) {
      if (command.warning != null) {
        _site(step, 'unparsed', command.line, command.warning!);
        continue;
      }
      final argv = command.argv;
      if (argv.isEmpty) continue;
      if (argv.first.contains(r'$')) {
        _unparsed(
          step,
          command,
          'Dynamic command "${argv.first}"; no coverage inferred',
        );
        continue;
      }
      if (argv.first == 'cd' || argv.first == 'pushd') {
        final args = argv.skip(1).where((a) => a != '--').toList();
        // `cd -` returns to a directory checked when it was entered, and a
        // bare `pushd` swaps the top two stack entries.
        if ((argv.first == 'cd' && args.length == 1 && args.first == '-') ||
            (argv.first == 'pushd' && args.isEmpty)) {
          continue;
        }
        if (args.length != 1 ||
            args.first.startsWith('-') ||
            args.first.startsWith('+')) {
          _unparsed(step, command, 'Unsupported ${argv.first} arguments');
        } else {
          _path(
            args.first,
            command.location,
            step,
            command.line,
            kind: argv.first,
            directory: true,
          );
        }
        continue;
      }
      if (argv.first == 'popd') {
        if (argv.length > 1) {
          _unparsed(step, command, 'Unsupported popd arguments');
        }
        continue;
      }
      if (argv.length == 3 && argv[0] == 'env' && argv[1] == '-C') {
        _path(
          argv[2],
          command.location,
          step,
          command.line,
          kind: 'env -C',
          directory: true,
        );
        continue;
      }
      if (_isMelos(argv)) {
        if (coverage) {
          _site(
            step,
            'melos',
            command.line,
            'Melos invocation in CI; replace with raw commands. Coverage through Melos is not inferred.',
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
                command.location,
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
              command.location,
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
      if (isExternal(command.cwd)) {
        // Outside the checkout, relative paths name no member.
        continue;
      }
      // Usage and version output exits successfully without running anything.
      if (argv
          .skip(2)
          .takeWhile((a) => a != '--')
          .any((a) => {'--help', '-h', '--version'}.contains(a))) {
        continue;
      }
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
            _path(path, command.location, step, command.line, kind: kind) &&
            valid;
      }
      if (valid && coverage && command.uncertain) {
        _unparsed(
          step,
          command,
          '$runner $kind ${command.uncertainReason}; no coverage inferred',
        );
        continue;
      }
      if (!valid || !coverage) continue;
      final targets = paths.isEmpty
          ? [p.posix.normalize(command.cwd)]
          : paths
                .map((path) => _resolve(command.location, path, step.root))
                .toList();
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

  /// Checks [value] relative to the absolute [location]. Paths outside the
  /// checkout are external and never looked up on this machine.
  bool _path(
    String value,
    String location,
    WorkflowStep step,
    int line, {
    required String kind,
    bool directory = false,
  }) {
    if (_dynamicPath(value) || _dynamicPath(location)) {
      _site(
        step,
        'unparsed',
        line,
        'Dynamic $kind path "$value"; cannot verify it',
      );
      return false;
    }
    final relative = _resolve(location, value, step.root);
    // CI-created locations outside the checkout are not repository drift.
    if (isExternal(relative)) return true;
    final type = FileSystemEntity.typeSync(p.join(workspace.root, relative));
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

  void _unparsed(WorkflowStep step, ShellCommand command, String message) =>
      _site(step, 'unparsed', command.line, message);

  Iterable<WorkflowStep> _scriptSteps() sync* {
    final pubspecFile = File(p.join(workspace.root, 'pubspec.yaml'));
    final YamlNode? node = pubspecFile.existsSync()
        ? loadYamlNode(pubspecFile.readAsStringSync())
        : null;
    int scriptLine(String section, String name, [int? step]) {
      if (node is! YamlMap) return 1;
      final parent = node[section];
      final scripts = parent is YamlMap ? parent['scripts'] : null;
      if (scripts is! YamlMap) return 1;
      final value = scripts.nodes[name];
      final steps = value is YamlMap ? value.nodes['steps'] : null;
      final run = step != null && steps is YamlList && step < steps.length
          ? steps.nodes[step]
          : value is YamlMap
          ? value.nodes['run']
          : value;
      if (run == null) return 1;
      final block =
          run.span.text.trimLeft().startsWith('|') ||
          run.span.text.trimLeft().startsWith('>');
      return run.span.start.line + (block ? 2 : 1);
    }

    for (final entry in config.scripts.entries) {
      final script = entry.value;
      final env = {
        'MONOREPO_ROOT': workspaceMarker,
        for (final e in script.env.entries)
          e.key: e.value
              .replaceAll(r'${MONOREPO_ROOT}', workspaceMarker)
              .replaceAll(
                RegExp(r'\$MONOREPO_ROOT(?![A-Za-z0-9_])'),
                workspaceMarker,
              ),
      };
      for (var i = 0; i < script.bodies.length; i++) {
        yield WorkflowStep(
          file: 'pubspec.yaml',
          line: scriptLine(
            'monorepo',
            entry.key,
            script.steps.isEmpty ? null : i,
          ),
          run: script.bodies[i],
          workingDirectory: script.cwd,
          job: 'script ${entry.key}',
          environment: env,
        );
      }
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
            // Distinct from a monorepo script of the same name, so their
            // collapsed findings stay separate.
            job: 'melos script ${entry.key}',
            environment: const {'MELOS_ROOT_PATH': workspaceMarker},
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

/// Globs and expansions make a path dynamic. The shell expands `~` only at
/// the start of a word, so `RUNNER~1` in a Windows short name stays literal.
bool _dynamicPath(String value) => RegExp(r'[$*?\[\]]|^~').hasMatch(value);

/// Root-relative path of [target] from the absolute [location], or an
/// [externalMarker] path when it lies outside the checkout at [root].
String _resolve(String location, String target, String root) =>
    rebasePath(joinLocation(location, target), root: root);

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

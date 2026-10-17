import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import '../changes.dart';
import '../check/coverage.dart';
import '../ci.dart';
import '../completion.dart';
import '../config.dart';
import '../doctor.dart';
import '../executor.dart';
import '../filters.dart';
import '../graph.dart';
import '../ownership.dart';
import '../planner.dart';
import '../render.dart';
import '../workspace.dart';

class MonorepoRunner extends CommandRunner<int> {
  MonorepoRunner()
    : super('monorepo', 'Optional, inspectable pub workspace commands.') {
    argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the installed version.',
    );
    addCommand(ListCommand());
    addCommand(GraphCommand());
    addCommand(DoctorCommand());
    addCommand(CompletionCommand());
    addCommand(CheckCommand());
    addCommand(CiCommand());
    for (final name in ['test', 'analyze', 'format', 'exec', 'run']) {
      addCommand(OperationCommand(name));
    }
    addCommand(PlanCommand());
  }
}

Future<(Workspace, Config)> loadWorkspace() async {
  final workspace = await discoverWorkspace();
  if (workspace.pubspec.containsKey('monorepo') &&
      workspace.pubspec['monorepo'] == null) {
    throw const ToolException('monorepo must be a mapping, not null');
  }
  return (
    workspace,
    Config.parse(workspace.pubspec['monorepo'], workspace.packages),
  );
}

/// Adds the member selection options shared by list, graph, and operations.
void addFilterOptions(ArgParser parser) {
  parser
    ..addMultiOption('scope', splitCommas: false, valueHelp: 'name|glob')
    ..addMultiOption('ignore', splitCommas: false, valueHelp: 'name|glob')
    ..addFlag(
      'flutter',
      defaultsTo: false,
      help: 'Select Flutter packages, or --no-flutter for Dart.',
    )
    ..addOption('dir-exists', valueHelp: 'relative/path')
    ..addOption('file-exists', valueHelp: 'relative/path')
    ..addOption(
      'since',
      valueHelp: 'git-ref',
      help:
          'Select members owning files changed in <ref>...HEAD or uncommitted.',
    )
    ..addFlag(
      'include-dependents',
      negatable: false,
      help: 'With --since, also select members that depend on changed ones.',
    );
}

/// Resolves filter options against the workspace. Presence checks and git
/// run here, so planning itself performs no I/O.
Future<(Filters, List<String>)> parseFilters(
  ArgResults options,
  Workspace workspace,
) async {
  Set<String>? presence(String option, bool directory) {
    final value = options[option] as String?;
    if (value == null) return null;
    if (value.isEmpty ||
        p.isAbsolute(value) ||
        p.split(p.normalize(value)).contains('..')) {
      throw ToolException('--$option must be a relative path within a member');
    }
    return workspace.packages
        .where(
          (package) => directory
              ? Directory(p.join(package.path, value)).existsSync()
              : File(p.join(package.path, value)).existsSync(),
        )
        .map((p) => p.name)
        .toSet();
  }

  final since = options['since'] as String?;
  final dependents = options['include-dependents'] as bool;
  if (dependents && since == null) {
    throw UsageException(
      '--include-dependents requires --since',
      'Usage: --since <git-ref> --include-dependents',
    );
  }
  ChangeSet? changes;
  if (since != null) {
    changes = changeSet(
      workspace,
      since,
      await changedFiles(workspace.root, since),
      includeDependents: dependents,
    );
  }
  return (
    Filters(
      scope: options['scope'] as List<String>,
      ignore: options['ignore'] as List<String>,
      flutter: options.wasParsed('flutter') ? options['flutter'] as bool : null,
      directoryPackages: presence('dir-exists', true),
      filePackages: presence('file-exists', false),
      changedPackages: changes?.packages,
      since: since,
    ),
    changes?.comments ?? const <String>[],
  );
}

class ListCommand extends Command<int> {
  @override
  String get name => 'list';
  @override
  String get description =>
      'List pub workspace members, package kind, and test directories.';
  ListCommand() {
    argParser.addFlag('json', negatable: false);
    addFilterOptions(argParser);
  }
  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('list takes no positional arguments');
    }
    final (workspace, config) = await loadWorkspace();
    final (filters, _) = await parseFilters(argResults!, workspace);
    // Config ignores are shown in a column rather than hiding members.
    final packages = workspace.packages
        .where(
          (package) =>
              filters.skipReason(package, const Config(), 'list') == null,
        )
        .toList();
    final entries = packages
        .map(
          (package) => {
            ...package.toJson(),
            'ignored': config.ignore.contains(package.name),
            'testIgnored': config.testIgnore.contains(package.name),
          },
        )
        .toList();
    if (argResults!['json'] as bool) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(entries));
    } else {
      stdout.writeln('package\tpath\tkind\ttest\tintegration_test\tignored');
      for (final package in packages) {
        final ignored = config.ignore.contains(package.name)
            ? 'all'
            : config.testIgnore.contains(package.name)
            ? 'test'
            : '-';
        stdout.writeln(
          '${package.name}\t${package.relPath}\t${package.isFlutter ? 'flutter' : 'dart'}\t${package.hasTest}\t${package.hasIntegrationTest}\t$ignored',
        );
      }
    }
    return 0;
  }
}

class GraphCommand extends Command<int> {
  @override
  String get name => 'graph';
  @override
  String get description =>
      'Print the dependency graph between workspace members.';
  GraphCommand() {
    argParser.addOption(
      'format',
      allowed: ['text', 'dot', 'mermaid', 'json'],
      defaultsTo: 'text',
      help: 'Edges point from a member to the members it depends on.',
    );
    addFilterOptions(argParser);
  }
  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('graph takes no positional arguments');
    }
    final (workspace, _) = await loadWorkspace();
    final (filters, _) = await parseFilters(argResults!, workspace);
    final selected = workspace.packages
        .where(
          (package) =>
              filters.skipReason(package, const Config(), 'graph') == null,
        )
        .map((package) => package.name)
        .toSet();
    stdout.writeln(
      renderGraph(
        dependencyGraph(workspace, selected),
        workspace.cycles,
        argResults!['format'] as String,
      ),
    );
    return 0;
  }
}

class CompletionCommand extends Command<int> {
  @override
  String get name => 'completion';
  @override
  String get description => 'Print a completion script for bash, zsh, or fish.';
  @override
  String get invocation => 'monorepo completion <bash|zsh|fish>';
  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1 || !{'bash', 'zsh', 'fish'}.contains(rest.single)) {
      usageException('completion takes one shell: bash, zsh, or fish');
    }
    stdout.writeln(completionScript(rest.single, runner!));
    return 0;
  }
}

class DoctorCommand extends Command<int> {
  @override
  String get name => 'doctor';
  @override
  String get description =>
      'Report workspace health and toolchains without changing anything.';
  DoctorCommand() {
    argParser
      ..addFlag('json', negatable: false)
      ..addFlag(
        'strict',
        negatable: false,
        help: 'Exit 1 on warnings as well as errors.',
      );
  }
  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('doctor takes no positional arguments');
    }
    final report = await diagnose(Directory.current.path);
    stdout.writeln(
      argResults!['json'] as bool
          ? const JsonEncoder.withIndent('  ').convert(report.toJson())
          : report.renderHuman(),
    );
    return report.hasProblems(strict: argResults!['strict'] as bool) ? 1 : 0;
  }
}

class CheckCommand extends Command<int> {
  @override
  String get name => 'check';
  @override
  String get description =>
      'Inspect workflow coverage and stale paths without running their commands.';
  CheckCommand() {
    argParser
      ..addOption(
        'reporter',
        allowed: ['text', 'json', 'github'],
        defaultsTo: 'text',
        help:
            'github prints ::error and ::warning workflow commands, which '
            'Gitea Actions also reads, before the text report.',
      )
      ..addFlag('json', negatable: false, help: 'Same as --reporter json.')
      ..addFlag('strict', negatable: false)
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'List every unresolved site instead of one summary per job.',
      );
  }
  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('check takes no positional arguments');
    }
    var reporter = argResults!['reporter'] as String;
    if (argResults!['json'] as bool) {
      if (argResults!.wasParsed('reporter') && reporter != 'json') {
        usageException('--json conflicts with --reporter $reporter');
      }
      reporter = 'json';
    }
    final (workspace, config) = await loadWorkspace();
    final report = checkWorkspace(
      workspace,
      config,
      collectOwnership(workspace, config),
      verbose: argResults!['verbose'] as bool,
    );
    if (reporter == 'github') {
      stdout.write(
        report.renderGithub(prefix: repositoryPrefix(workspace.root)),
      );
    }
    stdout.writeln(
      reporter == 'json'
          ? const JsonEncoder.withIndent('  ').convert(report.toJson())
          : report.renderHuman(),
    );
    return report.hasProblems(strict: argResults!['strict'] as bool) ? 1 : 0;
  }
}

class CiCommand extends Command<int> {
  @override
  String get name => 'ci';
  @override
  String get description =>
      'Print workflow YAML running the planned format, analyze and test '
      'commands. Writes no file.';
  @override
  String get invocation => 'monorepo ci [options] [-- <test arguments>]';
  CiCommand() {
    argParser
      ..addOption(
        'provider',
        allowed: ['github', 'gitea'],
        defaultsTo: 'github',
        help:
            'github adds SDK setup actions; gitea expects the SDKs on the '
            'runner and prints their versions.',
      )
      ..addFlag('test', negatable: false, help: 'Include test steps.')
      ..addFlag('analyze', negatable: false, help: 'Include analysis.')
      ..addFlag(
        'format-check',
        negatable: false,
        help: 'Include the format check. Without any of these, all three.',
      )
      ..addOption('runs-on', defaultsTo: 'ubuntu-latest', valueHelp: 'label')
      ..addOption('job', defaultsTo: 'ci', valueHelp: 'name')
      ..addOption(
        'timeout',
        valueHelp: 'minutes',
        help:
            'Wrap each command in timeout --signal=TERM --kill-after=30s '
            '<minutes>m.',
      )
      ..addFlag(
        'steps-only',
        negatable: false,
        help: 'Print only the format, analyze and test steps as a list.',
      );
    addFilterOptions(argParser);
  }
  @override
  Future<int> run() async {
    final options = argResults!;
    final chosen = [
      for (final (flag, command) in [
        ('format-check', 'format'),
        ('analyze', 'analyze'),
        ('test', 'test'),
      ])
        if (options[flag] as bool) command,
    ];
    final commands = chosen.isEmpty ? ['format', 'analyze', 'test'] : chosen;
    if (options.rest.isNotEmpty && !commands.contains('test')) {
      usageException('Arguments after -- go to dart test; add --test');
    }
    final job = options['job'] as String;
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(job)) {
      usageException(
        '--job must start with a letter or _ and contain only '
        'letters, digits, - and _',
      );
    }
    final runsOn = options['runs-on'] as String;
    if (runsOn.trim().isEmpty) usageException('--runs-on needs a label');
    int? timeout;
    if (options['timeout'] != null) {
      timeout = int.tryParse(options['timeout'] as String);
      if (timeout == null || timeout < 1) {
        usageException('--timeout must be a positive number of minutes');
      }
    }
    final (workspace, config) = await loadWorkspace();
    final (filters, notes) = await parseFilters(options, workspace);
    final ownership = collectOwnership(workspace, config);
    final plans = [
      for (final command in commands)
        buildPlan(
          workspace,
          config,
          Request(
            command,
            filters: filters,
            comments: notes,
            arguments: command == 'test' ? options.rest : const [],
            check: command == 'format',
          ),
          ownership: ownership,
        ),
    ];
    stdout.writeln(
      renderWorkflow(
        workspace,
        plans,
        CiOptions(
          provider: options['provider'] as String,
          runsOn: runsOn,
          job: job,
          timeout: timeout,
          stepsOnly: options['steps-only'] as bool,
          enforceLockfile: options['steps-only'] as bool
              ? false
              : File(p.join(workspace.root, 'pubspec.lock')).existsSync() &&
                    await isTracked(workspace.root, 'pubspec.lock'),
          invocation: options.arguments,
        ),
      ),
    );
    return 0;
  }
}

class PlanCommand extends Command<int> {
  @override
  String get name => 'plan';
  @override
  String get description =>
      'Print the same steps used by test, analyze, format, exec, or run.';
  PlanCommand() {
    argParser
      ..addFlag('json', negatable: false)
      ..addFlag('lines', negatable: false);
    for (final name in ['test', 'analyze', 'format', 'exec', 'run']) {
      addSubcommand(OperationCommand(name, plan: true));
    }
  }
}

class OperationCommand extends Command<int> {
  @override
  final String name;
  final bool plan;
  @override
  String get description => switch (name) {
    'test' => 'Run each package test suite with the package as cwd.',
    'analyze' => 'Analyze selected package roots in one Dart invocation.',
    'format' =>
      'Format owned Dart sources, respecting nested package boundaries.',
    'exec' => 'Run -- <command...> in each selected package directory.',
    _ => 'Run a configured script, or list available scripts.',
  };
  OperationCommand(this.name, {this.plan = false}) {
    if (name != 'run') addFilterOptions(argParser);
    if (name == 'run') {
      argParser.addFlag(
        'fail-fast',
        negatable: false,
        help: 'For a script with steps, stop after the first failing step.',
      );
    }
    if (name == 'test' || name == 'exec') {
      argParser
        ..addOption(
          'concurrency',
          abbr: 'j',
          defaultsTo: '1',
          help:
              'Number of package processes, not test file concurrency. '
              'exec waits for the members a step depends on.',
        )
        ..addFlag(
          'fail-fast',
          negatable: false,
          help: 'Stop starting new work after the first failure.',
        );
    }
    if (name == 'format') argParser.addFlag('check', negatable: false);
    if (!plan) {
      argParser.addOption(
        'reporter',
        allowed: ['text', 'json'],
        defaultsTo: 'text',
        help:
            'text streams output and ends with a summary table; json prints '
            'one document with each step\'s status, duration and output.',
      );
    }
    if (plan) {
      argParser
        ..addFlag('json', negatable: false)
        ..addFlag('lines', negatable: false);
    }
  }
  @override
  Future<int> run() async {
    final options = argResults!;
    final (workspace, config) = await loadWorkspace();
    if (name == 'run' && options.rest.isEmpty) {
      if (plan) usageException('plan run requires a script name');
      for (final entry in config.scripts.entries) {
        final script = entry.value;
        stdout.writeln('${entry.key}\t${script.description}');
        if (script.cwd != '.') stdout.writeln('  cwd: ${script.cwd}');
        for (final env in script.env.entries) {
          stdout.writeln('  env: ${env.key}=${env.value}');
        }
        for (var i = 0; i < script.bodies.length; i++) {
          final prefix = script.steps.isEmpty ? '  ' : '  ${i + 1}. ';
          stdout.writeln(
            '$prefix${script.bodies[i].trimRight().replaceAll('\n', '\n${' ' * prefix.length}')}',
          );
        }
      }
      if (config.scripts.isEmpty) {
        stdout.writeln('No monorepo.scripts configured.');
      }
      return 0;
    }
    var concurrency = 1;
    if (name == 'test' || name == 'exec') {
      concurrency = int.tryParse(options['concurrency'] as String) ?? 0;
      if (concurrency < 1) {
        usageException('--concurrency must be a positive integer');
      }
    }
    if (name == 'format') {
      if (options.rest.isNotEmpty) {
        usageException('format does not take positional arguments');
      }
      if (!File(
        p.join(workspace.root, '.dart_tool', 'package_config.json'),
      ).existsSync()) {
        throw const ToolException(
          'Missing .dart_tool/package_config.json; run dart pub get before formatting.',
        );
      }
    }
    final (filters, notes) = name == 'run'
        ? (const Filters(), const <String>[])
        : await parseFilters(options, workspace);
    final request = Request(
      name,
      filters: filters,
      comments: notes,
      arguments: name == 'run' ? options.rest.skip(1).toList() : options.rest,
      concurrency: concurrency,
      failFast:
          (name == 'test' || name == 'exec' || name == 'run') &&
          options['fail-fast'] as bool,
      check: name == 'format' && options['check'] as bool,
      script: name == 'run' ? options.rest.first : null,
      windows: Platform.isWindows,
    );
    final built = buildPlan(
      workspace,
      config,
      request,
      ownership: name == 'format' || name == 'analyze'
          ? collectOwnership(workspace, config)
          : const {},
    );
    if (plan) {
      final parentOptions = parent?.argResults;
      final json =
          options['json'] as bool || (parentOptions?['json'] as bool? ?? false);
      final lines =
          options['lines'] as bool ||
          (parentOptions?['lines'] as bool? ?? false);
      if (json && lines) usageException('Choose either --json or --lines');
      stdout.writeln(renderPlan(built, json: json, lines: lines));
      return 0;
    }
    return (await Executor(
      reporter: options['reporter'] == 'json' ? Reporter.json : Reporter.text,
      handleSignals: true,
    ).execute(built)).exitCode;
  }
}

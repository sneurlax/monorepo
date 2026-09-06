import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import '../changes.dart';
import '../check/coverage.dart';
import '../config.dart';
import '../executor.dart';
import '../filters.dart';
import '../ownership.dart';
import '../planner.dart';
import '../render.dart';
import '../workspace.dart';

const toolVersion = '0.1.0';

class MonorepoRunner extends CommandRunner<int> {
  MonorepoRunner()
    : super('monorepo', 'Optional, inspectable pub workspace commands.') {
    argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the installed version.',
    );
    addCommand(ListCommand());
    addCommand(CheckCommand());
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

class CheckCommand extends Command<int> {
  @override
  String get name => 'check';
  @override
  String get description =>
      'Inspect workflow coverage and stale paths without running their commands.';
  CheckCommand() {
    argParser
      ..addFlag('json', negatable: false)
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
    final (workspace, config) = await loadWorkspace();
    final report = checkWorkspace(
      workspace,
      config,
      collectOwnership(workspace, config),
      verbose: argResults!['verbose'] as bool,
    );
    stdout.writeln(
      argResults!['json'] as bool
          ? const JsonEncoder.withIndent('  ').convert(report.toJson())
          : report.renderHuman(),
    );
    return report.hasProblems(strict: argResults!['strict'] as bool) ? 1 : 0;
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
    if (name == 'test' || name == 'exec') {
      argParser
        ..addOption(
          'concurrency',
          defaultsTo: '1',
          help: 'Number of package processes, not test file concurrency.',
        )
        ..addFlag(
          'fail-fast',
          negatable: false,
          help: 'Stop starting new work after the first failure.',
        );
    }
    if (name == 'format') argParser.addFlag('check', negatable: false);
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
        stdout.writeln(
          '${entry.key}\t${entry.value.description}\n  ${entry.value.run}',
        );
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
          (name == 'test' || name == 'exec') && options['fail-fast'] as bool,
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
    return (await Executor().execute(built)).exitCode;
  }
}

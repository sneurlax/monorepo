import 'package:path/path.dart' as p;
import 'config.dart';
import 'filters.dart';
import 'model.dart';
import 'ownership.dart';

class Request {
  final String command;
  final Filters filters;
  final List<String> arguments;
  final int concurrency;
  final bool failFast;
  final bool check;
  final String? script;
  final bool windows;

  /// Notes about how the selection was made, printed as plan comments.
  final List<String> comments;
  const Request(
    this.command, {
    this.filters = const Filters(),
    this.arguments = const [],
    this.concurrency = 1,
    this.failFast = false,
    this.check = false,
    this.script,
    this.windows = false,
    this.comments = const [],
  });
}

class PlanStep {
  final String package;

  /// Root-relative working directory, with forward slashes.
  final String cwd;
  final List<String> argv;
  final Map<String, String> env;
  final List<int> acceptedExitCodes;
  final String? skipReason;

  /// Packages of earlier steps that must finish before this one starts when
  /// execution is parallel. Sequential order already satisfies them.
  final List<String> dependsOn;
  const PlanStep({
    required this.package,
    required this.cwd,
    this.argv = const [],
    this.env = const {},
    this.acceptedExitCodes = const [0],
    this.skipReason,
    this.dependsOn = const [],
  });
  Map<String, Object?> toJson() => {
    'package': package,
    'cwd': cwd,
    'argv': argv,
    'env': env,
    'acceptedExitCodes': acceptedExitCodes,
    'skipReason': skipReason,
    if (dependsOn.isNotEmpty) 'dependsOn': dependsOn,
  };
}

class Plan {
  final String root;
  final String command;
  final List<PlanStep> steps;
  final List<String> comments;
  final int concurrency;
  final bool failFast;

  /// Why nothing runs when `--since` selects no member. Shell plans print it
  /// as a comment, `--lines` included, and execution prints it alone.
  final String? notice;
  const Plan({
    required this.root,
    required this.command,
    required this.steps,
    this.comments = const [],
    this.concurrency = 1,
    this.failFast = false,
    this.notice,
  });
}

/// The nearest selected members [package] depends on, looking through
/// unselected members, limited to those earlier in workspace order so a
/// cycle can never block execution.
List<String> _selectedDependencies(
  Workspace workspace,
  Package package,
  List<Package> selected,
) {
  final order = {
    for (var i = 0; i < workspace.packages.length; i++)
      workspace.packages[i].name: i,
  };
  final byName = {for (final pkg in workspace.packages) pkg.name: pkg};
  final names = selected.map((pkg) => pkg.name).toSet();
  final result = <String>{};
  final seen = <String>{package.name};
  final pending = [...package.localDeps];
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    if (!seen.add(name) || !byName.containsKey(name)) continue;
    if (names.contains(name)) {
      if (order[name]! < order[package.name]!) result.add(name);
    } else {
      pending.addAll(byName[name]!.localDeps);
    }
  }
  return result.toList()..sort((a, b) => order[a]!.compareTo(order[b]!));
}

bool hasTestFilter(List<String> arguments) {
  const flags = [
    '--tags',
    '-t',
    '--exclude-tags',
    '-x',
    '--name',
    '-n',
    '--plain-name',
    '-N',
  ];
  for (final argument in arguments) {
    if (argument == '--') break;
    for (final flag in flags) {
      if (argument == flag || argument.startsWith('$flag=')) return true;
      if (flag.length == 2 &&
          argument.startsWith(flag) &&
          argument.length > 2) {
        return true;
      }
    }
  }
  return false;
}

String shellQuote(String argument) =>
    RegExp(r'^[a-zA-Z0-9_./:=+,-]+$').hasMatch(argument)
    ? argument
    : "'${argument.replaceAll("'", "'\\''")}'";

/// The planner consumes snapshots only. It does not read files or run tools.
Plan buildPlan(
  Workspace workspace,
  Config config,
  Request request, {
  Map<String, OwnedFiles> ownership = const {},
}) {
  if (request.concurrency < 1) {
    throw const ToolException('Concurrency must be at least 1');
  }
  final steps = <PlanStep>[];
  final comments = [
    for (final cycle in workspace.cycles)
      'dependency cycle: ${cycle.join(', ')} (ordered by name)',
    ...request.comments,
  ];
  final selected = <Package>[];
  for (final package in workspace.packages) {
    final reason = request.filters.skipReason(package, config, request.command);
    if (reason != null) {
      steps.add(
        PlanStep(
          package: package.name,
          cwd: package.relPath,
          skipReason: reason,
        ),
      );
    } else {
      selected.add(package);
    }
  }
  final since = request.filters.since;
  final String? notice;
  if (since == null || selected.isNotEmpty) {
    notice = null;
  } else if (request.filters.changedPackages?.isEmpty ?? true) {
    notice = 'no members changed since $since';
  } else {
    notice = 'none of the members changed since $since are selected';
  }
  switch (request.command) {
    case 'test':
      final arguments = [...config.testArgs, ...request.arguments];
      for (final package in selected) {
        steps.add(
          PlanStep(
            package: package.name,
            cwd: package.relPath,
            argv: package.hasTest
                ? [package.isFlutter ? 'flutter' : 'dart', 'test', ...arguments]
                : [],
            acceptedExitCodes: hasTestFilter(arguments) ? [0, 79] : [0],
            skipReason: package.hasTest ? null : 'no test/ directory',
          ),
        );
      }
    case 'analyze':
      final paths = <String>[];
      for (final pkg in selected) {
        if (selected.any(
          (parent) =>
              parent.name != pkg.name &&
              p.posix.isWithin(parent.relPath, pkg.relPath) &&
              !workspace.packages.any(
                (other) =>
                    !selected.contains(other) &&
                    p.posix.isWithin(parent.relPath, other.relPath),
              ),
        )) {
          continue;
        }
        final skippedChildren = workspace.packages
            .where(
              (other) =>
                  !selected.contains(other) &&
                  p.posix.isWithin(pkg.relPath, other.relPath),
            )
            .toList();
        if (skippedChildren.isEmpty) {
          paths.add(pkg.relPath);
        } else if (ownership.containsKey(pkg.name)) {
          paths.addAll(ownership[pkg.name]!.paths);
        } else {
          paths.add(pkg.relPath);
          for (final child in skippedChildren) {
            comments.add(
              'warning: ${child.relPath} is nested under analyzed parent ${pkg.relPath}',
            );
          }
        }
      }
      if (paths.isNotEmpty) {
        steps.add(
          PlanStep(
            package: 'workspace',
            cwd: '.',
            argv: [
              'dart',
              'analyze',
              ...config.analyzeArgs,
              ...request.arguments,
              ...paths,
            ],
          ),
        );
      }
    case 'format':
      final prefix = [
        'dart',
        'format',
        if (request.check) ...['--output', 'none', '--set-exit-if-changed'],
      ];
      final allPaths = <String>[];
      for (final package in selected) {
        final owned = ownership[package.name];
        if (owned == null) {
          throw ToolException('Missing ownership snapshot for ${package.name}');
        }
        if (owned.paths.isEmpty) {
          steps.add(
            PlanStep(
              package: package.name,
              cwd: package.relPath,
              skipReason: 'no owned Dart files',
            ),
          );
        } else {
          allPaths.addAll(owned.paths);
        }
      }
      if (allPaths.isNotEmpty) {
        var batch = <String>[];
        final baseLength = prefix.map(shellQuote).join(' ').length + 128;
        var length = baseLength;
        for (final path in allPaths) {
          final cost = shellQuote(path).length + 1;
          if (baseLength + cost > 7000) {
            throw ToolException(
              'Format path exceeds command-line budget: $path',
            );
          }
          if (length + cost > 7000 && batch.isNotEmpty) {
            steps.add(
              PlanStep(
                package: 'workspace',
                cwd: '.',
                argv: [...prefix, ...batch],
              ),
            );
            batch = [];
            length = baseLength;
          }
          batch.add(path);
          length += cost;
        }
        if (batch.isNotEmpty) {
          steps.add(
            PlanStep(
              package: 'workspace',
              cwd: '.',
              argv: [...prefix, ...batch],
            ),
          );
        }
      }
    case 'exec':
      if (request.arguments.isEmpty) {
        throw const ToolException('exec requires -- <command...>');
      }
      final extraEnv = <String, String>{};
      var cmdIndex = 0;
      while (cmdIndex < request.arguments.length &&
          RegExp(
            r'^[A-Za-z_][A-Za-z0-9_]*=',
          ).hasMatch(request.arguments[cmdIndex])) {
        final token = request.arguments[cmdIndex++];
        final eq = token.indexOf('=');
        extraEnv[token.substring(0, eq)] = token.substring(eq + 1);
      }
      final argv = request.arguments.sublist(cmdIndex);
      if (argv.isEmpty) {
        throw const ToolException(
          'exec requires a command after environment assignments',
        );
      }
      for (final package in selected) {
        steps.add(
          PlanStep(
            package: package.name,
            cwd: package.relPath,
            argv: argv,
            env: {'MONOREPO_ROOT': workspace.root, ...extraEnv},
            dependsOn: _selectedDependencies(workspace, package, selected),
          ),
        );
      }
    case 'run':
      final script = config.scripts[request.script];
      if (script == null) {
        throw ToolException('Unknown script: ${request.script}');
      }
      steps.clear();
      final body = script.run.trimRight();
      final shell = request.windows ? 'bash' : 'sh';
      final List<String> argv;
      if (request.arguments.isEmpty) {
        argv = [shell, '-c', body];
      } else if (RegExp(r'\$(?:[@*#1-9]|\{[0-9@*#])').hasMatch(body)) {
        argv = [shell, '-c', body, shell, ...request.arguments];
      } else if (RegExp(r'(?:^|[;\s])(?:done|fi|esac|\})\s*$').hasMatch(body)) {
        throw ToolException(
          'Script ${request.script} ends with a shell block and cannot take appended arguments without "\$@"',
        );
      } else {
        final suffix = ' ${request.arguments.map(shellQuote).join(' ')}';
        argv = [shell, '-c', '$body$suffix'];
      }
      steps.add(
        PlanStep(
          package: request.script!,
          cwd: '.',
          argv: argv,
          env: {'MONOREPO_ROOT': workspace.root},
        ),
      );
    default:
      throw ToolException('Unknown plan command: ${request.command}');
  }
  // Keep skips in the same stable package order as real steps.
  if (request.command == 'test' || request.command == 'exec') {
    final index = {
      for (var i = 0; i < workspace.packages.length; i++)
        workspace.packages[i].name: i,
    };
    steps.sort((a, b) => index[a.package]!.compareTo(index[b.package]!));
  }
  return Plan(
    root: workspace.root,
    command: request.command,
    steps: steps,
    comments: comments,
    concurrency: request.concurrency,
    failFast: request.failFast,
    notice: notice,
  );
}

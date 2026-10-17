import 'model.dart';
import 'planner.dart';
import 'render.dart';

/// How `monorepo ci` lays out the workflow around the planned commands.
class CiOptions {
  /// `github` adds SDK setup actions; `gitea` expects a runner with the SDKs
  /// installed and prints their versions instead.
  final String provider;
  final String runsOn;
  final String job;

  /// Minutes for the `timeout` wrapper around each command, or null.
  final int? timeout;
  final bool stepsOnly;

  /// Whether `pub get` passes `--enforce-lockfile`.
  final bool enforceLockfile;

  /// The `monorepo ci` arguments, repeated in the header comment.
  final List<String> invocation;
  const CiOptions({
    this.provider = 'github',
    this.runsOn = 'ubuntu-latest',
    this.job = 'ci',
    this.timeout,
    this.stepsOnly = false,
    this.enforceLockfile = false,
    this.invocation = const [],
  });
}

class _Step {
  final String? name;
  final String? uses;
  final Map<String, String> with_;
  final String? workingDirectory;
  final String? run;
  const _Step({
    this.name,
    this.uses,
    this.with_ = const {},
    this.workingDirectory,
    this.run,
  });
}

/// Renders workflow YAML whose run commands are the executable steps of
/// [plans], in order. Each plan step becomes one workflow step: the command
/// `plan --lines` prints, with its `cd` turned into `working-directory`.
/// Nothing here reads files or runs tools.
String renderWorkflow(
  Workspace workspace,
  List<Plan> plans,
  CiOptions options,
) {
  final lines = <String>[];
  final indent = options.stepsOnly ? '' : '      ';
  final seen = <String>{};
  void comment(String text) {
    if (seen.add(text)) lines.add('$indent# ${text.replaceAll('\n', ' ')}');
  }

  void step(_Step step) {
    final fields = <(String, String)>[
      if (step.name != null) ('name', step.name!),
      if (step.uses != null) ('uses', step.uses!),
      if (step.workingDirectory != null)
        ('working-directory', step.workingDirectory!),
      if (step.run != null) ('run', step.run!),
    ];
    for (var i = 0; i < fields.length; i++) {
      final (key, value) = fields[i];
      final lead = i == 0 ? '$indent- ' : '$indent  ';
      if (value.contains('\n')) {
        lines.add('$lead$key: |');
        for (final line in value.trimRight().split('\n')) {
          lines.add('$indent    $line');
        }
      } else {
        lines.add('$lead$key: ${yamlScalar(value)}');
      }
      if (key == 'uses' && step.with_.isNotEmpty) {
        lines.add('$indent  with:');
        for (final entry in step.with_.entries) {
          lines.add('$indent    ${entry.key}: ${yamlScalar(entry.value)}');
        }
      }
    }
  }

  String wrap(String command) => options.timeout == null
      ? command
      : 'timeout --signal=TERM --kill-after=30s ${options.timeout}m $command';

  final flutter = workspace.packages.any((package) => package.isFlutter);
  if (!options.stepsOnly) {
    step(const _Step(uses: 'actions/checkout@v4'));
    if (options.provider == 'github') {
      step(
        flutter
            ? const _Step(
                uses: 'subosito/flutter-action@v2',
                with_: {'channel': 'stable'},
              )
            : const _Step(uses: 'dart-lang/setup-dart@v1'),
      );
    } else {
      step(
        _Step(
          name: 'Provisioned SDK',
          run: flutter
              ? 'dart --version\nflutter --version\n'
              : 'dart --version',
        ),
      );
    }
    step(
      _Step(
        name: 'Resolve dependencies',
        run: wrap(
          '${flutter ? 'flutter' : 'dart'} pub get'
          '${options.enforceLockfile ? ' --enforce-lockfile' : ''}',
        ),
      ),
    );
  }
  final notice = plans
      .map((plan) => plan.notice)
      .firstWhere((notice) => notice != null, orElse: () => null);
  if (notice != null) comment(notice);
  for (final plan in plans) {
    for (final text in plan.comments) {
      comment(text);
    }
    final runnable = plan.steps.where((s) => s.skipReason == null).toList();
    var batch = 0;
    for (final planStep in plan.steps) {
      if (planStep.skipReason != null) {
        // Selection skips repeat in every plan; print each once.
        comment('skip ${planStep.cwd}: ${planStep.skipReason}');
        continue;
      }
      final status = renderAcceptedStatus(planStep);
      final command = wrap(renderCommand(planStep));
      final name = switch (plan.command) {
        'format' =>
          runnable.length == 1
              ? 'Check formatting'
              : 'Check formatting (${++batch} of ${runnable.length})',
        'analyze' => 'Analyze',
        'test' => 'Test ${planStep.package}',
        _ => '${plan.command} ${planStep.package}',
      };
      step(
        _Step(
          name: name,
          workingDirectory: planStep.cwd == '.' ? null : planStep.cwd,
          run: status == null ? command : '$command || $status',
        ),
      );
    }
  }
  final header = [
    '# Generated by monorepo $toolVersion: monorepo ci${options.invocation.map((a) => ' ${shellQuote(a)}').join()}',
    '# The commands match `monorepo plan --lines`. Regenerate this when members',
    '# change; `monorepo check` reports drift.',
  ];
  if (options.stepsOnly) {
    return [...header, ...lines].join('\n');
  }
  return [
    ...header,
    'name: CI',
    'on:',
    '  push:',
    '    branches: [main]',
    '  pull_request:',
    '  workflow_dispatch:',
    'permissions:',
    '  contents: read',
    'env:',
    "  DASH__SUPPRESS_ANALYTICS: 'true'",
    "  FLUTTER_SUPPRESS_ANALYTICS: 'true'",
    'jobs:',
    '  ${options.job}:',
    '    runs-on: ${yamlScalar(options.runsOn)}',
    '    steps:',
    ...lines,
  ].join('\n');
}

/// A YAML scalar for [value]: plain when that reads back as the same string,
/// single-quoted otherwise.
String yamlScalar(String value) {
  const reserved = {
    'y', 'n', 'yes', 'no', 'true', 'false', 'on', 'off', 'null', '~', //
  };
  final plain =
      RegExp(r'^[A-Za-z_/][A-Za-z0-9_ ./=+@-]*$').hasMatch(value) &&
      !value.endsWith(' ') &&
      !reserved.contains(value.toLowerCase());
  return plain ? value : "'${value.replaceAll("'", "''")}'";
}

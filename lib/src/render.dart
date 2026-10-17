import 'dart:convert';
import 'planner.dart';

/// The step's environment and argument vector as one shell command, without
/// its directory or accepted-status handling.
String renderCommand(PlanStep step) {
  final argv = step.argv.map(shellQuote).join(' ');
  final env = step.env.isEmpty
      ? ''
      : 'env ${step.env.entries.map((e) => shellQuote('${e.key}=${e.value}')).join(' ')} ';
  return '$env$argv';
}

/// A shell test that succeeds for the step's accepted nonzero statuses, or
/// null when only 0 is accepted.
String? renderAcceptedStatus(PlanStep step) {
  final accepted = step.acceptedExitCodes.where((code) => code != 0).toList();
  return accepted.isEmpty
      ? null
      : accepted.length == 1
      ? '[ \$? -eq ${accepted.single} ]'
      : '{ code=\$?; ${accepted.map((code) => '[ "\$code" -eq $code ]').join(' || ')}; }';
}

String renderStep(PlanStep step) {
  final command = renderCommand(step);
  final status = renderAcceptedStatus(step);
  if (step.cwd == '.') {
    return status == null ? command : '($command || $status)';
  }
  if (status == null) return '(cd ${shellQuote(step.cwd)} && $command)';
  return '(cd ${shellQuote(step.cwd)} && ($command || $status))';
}

String renderPlan(Plan plan, {bool lines = false, bool json = false}) {
  if (json) {
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(plan.steps.map((step) => step.toJson()).toList());
  }
  final buffer = StringBuffer();
  for (final comment in lines ? <String>[] : plan.comments) {
    buffer.writeln('# ${comment.replaceAll('\n', ' ')}');
  }
  if (plan.notice != null) buffer.writeln('# ${plan.notice}');
  if (!lines && plan.concurrency > 1) {
    buffer.writeln(
      '# Shell replay is sequential; execution uses ${plan.concurrency} workers.',
    );
    if (plan.failFast) {
      buffer.writeln(
        '# Parallel execution drains already-started steps after failure.',
      );
    }
  }
  if (!lines) buffer.writeln(plan.failFast ? 'set -e' : 'rc=0');
  for (final step in plan.steps) {
    if (step.skipReason != null) {
      if (!lines) {
        buffer.writeln(
          '# skip ${step.cwd}: ${step.skipReason}'.replaceAll('\n', ' '),
        );
      }
    } else {
      buffer.writeln(
        '${renderStep(step)}${!lines && !plan.failFast ? ' || rc=1' : ''}',
      );
    }
  }
  if (!lines && !plan.failFast) buffer.writeln('exit \$rc');
  return buffer.toString().trimRight();
}

import 'dart:convert';
import 'planner.dart';

String renderStep(PlanStep step) {
  final argv = step.argv.map(shellQuote).join(' ');
  final env = step.env.isEmpty
      ? ''
      : 'env ${step.env.entries.map((e) => shellQuote('${e.key}=${e.value}')).join(' ')} ';
  final command = '$env$argv';
  final accepted = step.acceptedExitCodes.where((code) => code != 0).toList();
  final status = accepted.isEmpty
      ? null
      : accepted.length == 1
      ? '[ \$? -eq ${accepted.single} ]'
      : 'code=\$?; ${accepted.map((code) => '[ "\$code" -eq $code ]').join(' || ')}';
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
  for (final comment in plan.comments) {
    buffer.writeln('# ${comment.replaceAll('\n', ' ')}');
  }
  if (plan.concurrency > 1) {
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

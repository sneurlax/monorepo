import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'planner.dart';

class StepResult {
  final PlanStep step;
  final int? exitCode;
  final Duration elapsed;
  final String? skipReason;
  final String output;
  final bool environmentError;
  const StepResult(
    this.step,
    this.exitCode,
    this.elapsed,
    this.output, {
    this.skipReason,
    this.environmentError = false,
  });
  bool get failed =>
      skipReason == null && !step.acceptedExitCodes.contains(exitCode);
  String get result => skipReason != null
      ? 'skip: $skipReason'
      : exitCode == 79 && !failed
      ? 'no matching tests'
      : failed
      ? 'failed ($exitCode)'
      : 'passed';
}

class ExecutionResult {
  final List<StepResult> results;
  final int exitCode;
  const ExecutionResult(this.results, this.exitCode);
}

typedef StepRunner =
    Future<StepResult> Function(PlanStep step, String root, bool buffered);

class Executor {
  final void Function(String) write;
  final Map<String, String> environment;
  final StepRunner? runner;
  Executor({
    void Function(String)? write,
    this.environment = const {},
    this.runner,
  }) : write = write ?? stdout.write;

  Future<StepResult> _run(PlanStep step, String root, bool buffered) async {
    final watch = Stopwatch()..start();
    final output = StringBuffer();
    try {
      final process = await Process.start(
        step.argv.first,
        step.argv.skip(1).toList(),
        workingDirectory: p.join(root, p.fromUri(step.cwd)),
        environment: {...environment, ...step.env},
        runInShell: Platform.isWindows,
      );
      void emit(String text) {
        output.write(text);
        if (!buffered) write(text);
      }

      final out = process.stdout
          .transform(utf8.decoder)
          .listen(emit)
          .asFuture<void>();
      final err = process.stderr
          .transform(utf8.decoder)
          .listen(emit)
          .asFuture<void>();
      final code = await process.exitCode;
      await Future.wait([out, err]);
      return StepResult(step, code, watch.elapsed, output.toString());
    } on ProcessException catch (error) {
      final text =
          'Cannot start ${step.argv.map(shellQuote).join(' ')}: ${error.message}\n';
      if (!buffered) write(text);
      return StepResult(step, 2, watch.elapsed, text, environmentError: true);
    }
  }

  Future<ExecutionResult> execute(Plan plan) async {
    final results = List<StepResult?>.filled(plan.steps.length, null);
    var next = 0;
    var failed = false;
    Future<void> worker() async {
      while (next < plan.steps.length) {
        final index = next++;
        final step = plan.steps[index];
        final reason =
            step.skipReason ?? (failed && plan.failFast ? 'fail-fast' : null);
        if (reason != null) {
          results[index] = StepResult(
            step,
            null,
            Duration.zero,
            '',
            skipReason: reason,
          );
          continue;
        }
        final result = await (runner ?? _run)(
          step,
          plan.root,
          plan.concurrency > 1,
        );
        results[index] = result;
        if (plan.concurrency > 1) write('[${step.package}]\n${result.output}');
        failed |= result.failed;
      }
    }

    await Future.wait(List.generate(plan.concurrency, (_) => worker()));
    final completed = results.cast<StepResult>();
    write('package\trunner\tresult\tseconds\n');
    for (final result in completed) {
      final runner = result.step.argv.isEmpty ? '-' : result.step.argv.first;
      write(
        '${result.step.package}\t$runner\t${result.result}\t${(result.elapsed.inMicroseconds / 1000000).toStringAsFixed(2)}\n',
      );
    }
    return ExecutionResult(
      completed,
      completed.any((result) => result.environmentError)
          ? 2
          : failed
          ? 1
          : 0,
    );
  }
}

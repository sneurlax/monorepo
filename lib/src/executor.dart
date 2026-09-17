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

  /// One of `passed`, `failed`, `skipped`, or `no-tests`.
  String get status => skipReason != null
      ? 'skipped'
      : failed
      ? 'failed'
      : exitCode == 79
      ? 'no-tests'
      : 'passed';
  String get result => skipReason != null
      ? 'skip: $skipReason'
      : exitCode == 79 && !failed
      ? 'no matching tests'
      : failed
      ? 'failed ($exitCode)'
      : 'passed';
  Map<String, Object?> toJson() => {
    ...step.toJson(),
    'status': status,
    'exitCode': exitCode,
    'skipReason': skipReason,
    'seconds': _seconds(elapsed),
    'output': output,
  };
}

double _seconds(Duration duration) =>
    (duration.inMicroseconds / 1000).round() / 1000;

class ExecutionResult {
  final List<StepResult> results;
  final int exitCode;
  final Duration elapsed;
  const ExecutionResult(
    this.results,
    this.exitCode, [
    this.elapsed = Duration.zero,
  ]);

  Map<String, int> get counts => {
    for (final status in ['passed', 'no-tests', 'failed', 'skipped'])
      status: results.where((r) => r.status == status).length,
  };

  Map<String, Object?> toJson(Plan plan) => {
    'command': plan.command,
    'exitCode': exitCode,
    'seconds': _seconds(elapsed),
    'summary': counts,
    'steps': [for (final result in results) result.toJson()],
  };
}

/// How execution reports progress and results.
enum Reporter {
  /// Child output with a header per step, then a summary table.
  text,

  /// Only a JSON document on completion; child output is captured into it.
  json,
}

String _truncate(String text, int width) =>
    text.length <= width ? text : '${text.substring(0, width - 3)}...';

String _command(PlanStep step) => step.argv.map(shellQuote).join(' ');

/// The end-of-run table: package, command, status, and duration.
String renderSummary(ExecutionResult execution) {
  final rows = [
    ['package', 'command', 'status', 'duration'],
    for (final result in execution.results)
      [
        result.step.package,
        result.step.argv.isEmpty ? '-' : _truncate(_command(result.step), 48),
        result.result,
        result.skipReason != null
            ? '-'
            : '${(result.elapsed.inMicroseconds / 1000000).toStringAsFixed(2)}s',
      ],
  ];
  final widths = [
    for (var column = 0; column < 3; column++)
      rows.map((row) => row[column].length).reduce((a, b) => a > b ? a : b),
  ];
  final buffer = StringBuffer();
  for (final row in rows) {
    buffer.writeln(
      [
        for (var column = 0; column < 3; column++)
          row[column].padRight(widths[column]),
        row[3],
      ].join('  ').trimRight(),
    );
  }
  final counts = execution.counts;
  final parts = [
    '${counts['passed']! + counts['no-tests']!} passed',
    if (counts['no-tests']! > 0) '${counts['no-tests']} with no matching tests',
    '${counts['failed']} failed',
    '${counts['skipped']} skipped',
  ];
  buffer.write(
    '${parts.join(', ')} in ${(execution.elapsed.inMicroseconds / 1000000).toStringAsFixed(2)}s\n',
  );
  return buffer.toString();
}

typedef StepRunner =
    Future<StepResult> Function(PlanStep step, String root, bool buffered);

class Executor {
  final void Function(String) write;
  final Map<String, String> environment;
  final StepRunner? runner;
  final bool windows;
  final bool Function(String, Map<String, String>) commandAvailable;

  /// Finds the directory of a Git Bash `bash.exe` for [windows] runs.
  final String? Function(Map<String, String>) gitBashDirectory;
  final Reporter reporter;

  /// Whether [execute] handles SIGINT and SIGTERM: it stops running children,
  /// skips queued steps, prints the summary, and exits 130 or 143.
  final bool handleSignals;
  Executor({
    void Function(String)? write,
    this.environment = const {},
    this.runner,
    bool? windows,
    bool Function(String, Map<String, String>)? commandAvailable,
    String? Function(Map<String, String>)? gitBashDirectory,
    this.reporter = Reporter.text,
    this.handleSignals = false,
  }) : write = write ?? stdout.write,
       windows = windows ?? Platform.isWindows,
       commandAvailable = commandAvailable ?? _executableAvailable,
       gitBashDirectory = gitBashDirectory ?? _realGitBashDirectory;

  final _children = <Process>{};
  ProcessSignal? _interrupted;
  Timer? _escalation;

  void _interrupt(ProcessSignal signal) {
    if (_interrupted != null) {
      // A second signal does not wait for children to clean up.
      for (final child in [..._children]) {
        _signalTree(child, ProcessSignal.sigkill);
      }
      return;
    }
    _interrupted = signal;
    for (final child in [..._children]) {
      _signalTree(child, ProcessSignal.sigterm);
    }
    _escalation = Timer(const Duration(seconds: 10), () {
      for (final child in [..._children]) {
        _signalTree(child, ProcessSignal.sigkill);
      }
    });
  }

  /// Signals [process] and every process below it. Dart cannot start a child
  /// in its own process group, so the tree comes from `ps` instead; a
  /// grandchild left running would hold the output pipes open.
  void _signalTree(Process process, ProcessSignal signal) {
    if (windows) {
      try {
        Process.runSync('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
      } on ProcessException {
        // Fall back to the child alone.
      }
      process.kill();
      return;
    }
    final pids = <int>[process.pid];
    try {
      final table = Process.runSync('ps', ['-A', '-o', 'pid=', '-o', 'ppid=']);
      final children = <int, List<int>>{};
      for (final line in (table.stdout as String).split('\n')) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length != 2) continue;
        final pid = int.tryParse(fields[0]);
        final parent = int.tryParse(fields[1]);
        if (pid != null && parent != null) {
          children.putIfAbsent(parent, () => []).add(pid);
        }
      }
      for (var i = 0; i < pids.length; i++) {
        pids.addAll(children[pids[i]] ?? const []);
      }
    } on ProcessException {
      // Without ps only the direct child is signalled.
    }
    for (final pid in pids) {
      Process.killPid(pid, signal);
    }
  }

  Future<StepResult> _run(PlanStep step, String root, bool buffered) async {
    final watch = Stopwatch()..start();
    final output = StringBuffer();
    var stepEnv = step.env;
    if (windows) {
      final env = {...Platform.environment, ...environment, ...step.env};
      if (step.argv.first == 'bash') {
        // A bare `bash` on Windows can be the WSL launcher in System32, which
        // runs the script inside Linux. Put Git Bash first on the child PATH.
        final dir = gitBashDirectory(env);
        if (dir == null) {
          final text =
              'Git Bash is required on Windows. Command: ${step.argv.map(shellQuote).join(' ')}\n';
          if (!buffered) write(text);
          return StepResult(
            step,
            2,
            watch.elapsed,
            text,
            environmentError: true,
          );
        }
        final pathKey = env.keys.firstWhere(
          (key) => key.toUpperCase() == 'PATH',
          orElse: () => 'PATH',
        );
        stepEnv = {...step.env, pathKey: '$dir;${env[pathKey] ?? ''}'};
      } else if (_needsPathLookup(step.argv.first) &&
          !commandAvailable(step.argv.first, env)) {
        // cmd.exe reports an unknown command as exit 1, which would look like
        // a failing step instead of an environment problem.
        final text =
            'Cannot start ${step.argv.map(shellQuote).join(' ')}: command not found on PATH\n';
        if (!buffered) write(text);
        return StepResult(step, 2, watch.elapsed, text, environmentError: true);
      }
    }
    try {
      final process = await Process.start(
        step.argv.first,
        step.argv.skip(1).toList(),
        workingDirectory: p.join(root, step.cwd),
        environment: {...environment, ...stepEnv},
        runInShell: windows,
      );
      _children.add(process);
      if (_interrupted != null) _signalTree(process, ProcessSignal.sigterm);
      // Children get no input. Closing stdin at once means a command that
      // reads sees end of file instead of waiting on a pipe nobody writes,
      // for every concurrency and reporter alike.
      unawaited(process.stdin.close().then((_) {}, onError: (_) {}));
      void emit(String text) {
        output.write(text);
        if (!buffered) write(text);
      }

      final out = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(emit)
          .asFuture<void>();
      final err = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(emit)
          .asFuture<void>();
      final code = await process.exitCode;
      _children.remove(process);
      await Future.wait([out, err]);
      return StepResult(step, code, watch.elapsed, output.toString());
    } on ProcessException catch (error) {
      final text =
          'Cannot start ${step.argv.map(shellQuote).join(' ')}: ${error.message}\n';
      if (!buffered) write(text);
      return StepResult(step, 2, watch.elapsed, text, environmentError: true);
    }
  }

  /// Runs [plan] with up to `plan.concurrency` steps at once. A step starts
  /// only after the steps of its [PlanStep.dependsOn] packages finish, and
  /// otherwise in plan order. With fail-fast, queued steps are skipped after
  /// the first failure while running steps finish. After an interrupt,
  /// running steps are stopped and queued steps are skipped.
  Future<ExecutionResult> execute(Plan plan) async {
    _interrupted = null;
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    if (handleSignals) {
      for (final signal in [
        ProcessSignal.sigint,
        if (!Platform.isWindows) ProcessSignal.sigterm,
      ]) {
        try {
          subscriptions.add(signal.watch().listen(_interrupt));
        } on SignalException {
          // Not supported here; the default handling applies.
        }
      }
    }
    try {
      return await _execute(plan);
    } finally {
      _escalation?.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }

  Future<ExecutionResult> _execute(Plan plan) async {
    final watch = Stopwatch()..start();
    final steps = plan.steps;
    final results = List<StepResult?>.filled(steps.length, null);
    final buffered = plan.concurrency > 1 || reporter == Reporter.json;
    if (plan.notice != null &&
        reporter == Reporter.text &&
        steps.every((step) => step.skipReason != null)) {
      // An empty --since selection is a normal outcome, not a run to report.
      write('${plan.notice}\n');
      return ExecutionResult([
        for (final step in steps)
          StepResult(
            step,
            null,
            Duration.zero,
            '',
            skipReason: step.skipReason,
          ),
      ], 0);
    }
    final unfinished = <String, int>{};
    for (final step in steps) {
      if (step.skipReason == null) {
        unfinished[step.package] = (unfinished[step.package] ?? 0) + 1;
      }
    }
    void done(int index, StepResult result) {
      results[index] = result;
      if (steps[index].skipReason == null) {
        unfinished[steps[index].package] =
            unfinished[steps[index].package]! - 1;
      }
    }

    var failed = false;
    final queue = [for (var i = 0; i < steps.length; i++) i];
    final running = <int, Future<void>>{};
    while (queue.isNotEmpty || running.isNotEmpty) {
      for (var q = 0; q < queue.length && running.length < plan.concurrency;) {
        final index = queue[q];
        final step = steps[index];
        final reason =
            step.skipReason ??
            (_interrupted != null
                ? 'interrupted'
                : failed && plan.failFast
                ? 'fail-fast'
                : null);
        if (reason != null) {
          queue.removeAt(q);
          done(
            index,
            StepResult(step, null, Duration.zero, '', skipReason: reason),
          );
          continue;
        }
        // An empty pool must start something, so a malformed dependency can
        // delay a step but never deadlock the run.
        if (running.isNotEmpty &&
            step.dependsOn.any((name) => (unfinished[name] ?? 0) > 0)) {
          q++;
          continue;
        }
        queue.removeAt(q);
        if (reporter == Reporter.text && !buffered) write(_header(step));
        running[index] = (runner ?? _run)(step, plan.root, buffered).then((
          result,
        ) {
          running.remove(index);
          done(index, result);
          failed |= result.failed;
          if (reporter == Reporter.text && buffered) {
            final output = result.output;
            write(
              '${_header(step)}$output${output.isEmpty || output.endsWith('\n') ? '' : '\n'}',
            );
          }
        });
      }
      if (running.isNotEmpty) await Future.any(running.values);
    }
    watch.stop();
    final completed = results.cast<StepResult>();
    final interrupted = _interrupted;
    final execution = ExecutionResult(
      completed,
      interrupted != null
          ? 128 + (interrupted == ProcessSignal.sigint ? 2 : 15)
          : completed.any((result) => result.environmentError)
          ? 2
          : failed
          ? 1
          : 0,
      watch.elapsed,
    );
    write(
      reporter == Reporter.json
          ? '${const JsonEncoder.withIndent('  ').convert(execution.toJson(plan))}\n'
          : renderSummary(execution),
    );
    return execution;
  }

  String _header(PlanStep step) =>
      '[${step.package}] ${_truncate(_command(step), 160)}\n';
}

bool _executableAvailable(String name, Map<String, String> environment) {
  String? value(String name) {
    for (final entry in environment.entries) {
      if (entry.key.toUpperCase() == name) return entry.value;
    }
    return null;
  }

  final extensions = Platform.isWindows
      ? (value('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD').split(';')
      : [''];
  for (final directory in (value('PATH') ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    if (directory.isEmpty) continue;
    for (final extension in ['', ...extensions]) {
      if (File(p.join(directory, '$name$extension')).existsSync()) return true;
    }
  }
  return false;
}

const _cmdBuiltins = {
  'assoc', 'call', 'cd', 'chdir', 'cls', 'copy', 'date', 'del', 'dir', 'echo',
  'erase', 'ftype', 'md', 'mkdir', 'mklink', 'move', 'path', 'pause', 'popd',
  'pushd', 'rd', 'ren', 'rename', 'rmdir', 'set', 'start', 'time', 'title',
  'type', 'ver', 'vol', //
};

bool _needsPathLookup(String command) =>
    !command.contains('/') &&
    !command.contains(r'\') &&
    !_cmdBuiltins.contains(command.toLowerCase());

String? _realGitBashDirectory(Map<String, String> environment) =>
    findGitBashDirectory(environment, (path) => File(path).existsSync());

/// Returns the directory holding Git Bash's `bash.exe`, or null.
///
/// PATH entries that hold the WSL launcher (System32, WindowsApps) are skipped.
/// When no other PATH entry has `bash.exe`, the install location is derived
/// from `git.exe` and then from the usual Program Files locations.
String? findGitBashDirectory(
  Map<String, String> environment,
  bool Function(String path) exists,
) {
  final win = p.windows;
  String? value(String name) {
    for (final entry in environment.entries) {
      if (entry.key.toUpperCase() == name.toUpperCase()) return entry.value;
    }
    return null;
  }

  bool launcherDirectory(String directory) {
    final lower = win.normalize(directory).toLowerCase();
    return lower.endsWith(r'\windows\system32') ||
        lower.endsWith(r'\windows\sysnative') ||
        lower.endsWith(r'\windows\syswow64') ||
        lower.contains(r'\windowsapps');
  }

  final directories = [
    for (final d in (value('PATH') ?? '').split(';'))
      if (d.isNotEmpty) d.replaceAll('"', ''),
  ];
  for (final directory in directories) {
    if (launcherDirectory(directory)) continue;
    if (exists(win.join(directory, 'bash.exe'))) return directory;
  }
  final candidates = <String>[];
  for (final directory in directories) {
    if (exists(win.join(directory, 'git.exe'))) {
      final root = win.dirname(directory);
      candidates.addAll([win.join(root, 'bin'), win.join(root, 'usr', 'bin')]);
    }
  }
  for (final name in ['ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432']) {
    final base = value(name);
    if (base != null) candidates.add(win.join(base, 'Git', 'bin'));
  }
  final local = value('LOCALAPPDATA');
  if (local != null) candidates.add(win.join(local, 'Programs', 'Git', 'bin'));
  for (final directory in candidates) {
    if (exists(win.join(directory, 'bash.exe'))) return directory;
  }
  return null;
}

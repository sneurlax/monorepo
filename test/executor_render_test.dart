import 'dart:convert';
import 'dart:io';
import 'package:monorepo/src/config.dart';
import 'package:monorepo/src/executor.dart';
import 'package:monorepo/src/filters.dart';
import 'package:monorepo/src/model.dart';
import 'package:monorepo/src/planner.dart';
import 'package:monorepo/src/render.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group(
    'POSIX shell replay and executor equivalence',
    () {
      late Directory temp;
      late Workspace workspace;
      late Map<String, String> env;
      setUp(() async {
        temp = Directory.systemTemp.createTempSync('monorepo-equivalence-');
        Directory(p.join(temp.path, 'bin')).createSync();
        for (final pkg in ['a space%20semi;', "b'quote"]) {
          Directory(p.join(temp.path, pkg)).createSync();
        }
        const stub = r'''#!/usr/bin/env python3
import json,os,sys
code=int(open('.exit').read()) if os.path.exists('.exit') else 0
with open(os.environ['LOG'],'a') as f:
 f.write(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd(),'root':os.getenv('MONOREPO_ROOT'),'extra':os.getenv('EXTRA_ENV'),'code':code})+'\n')
sys.exit(code)
''';
        for (final name in ['dart', 'flutter', 'stub']) {
          final f = File(p.join(temp.path, 'bin', name))
            ..writeAsStringSync(stub);
          await Process.run('chmod', ['+x', f.path]);
        }
        env = {
          'PATH': '${p.join(temp.path, 'bin')}:${Platform.environment['PATH']}',
          'LOG': p.join(temp.path, 'log'),
        };
        workspace = Workspace(
          root: temp.path,
          packages: [
            Package(
              name: 'a',
              path: p.join(temp.path, 'a space%20semi;'),
              relPath: 'a space%20semi;',
              hasTest: true,
            ),
            Package(
              name: 'b',
              path: p.join(temp.path, "b'quote"),
              relPath: "b'quote",
              hasTest: true,
              isFlutter: true,
            ),
          ],
        );
      });
      tearDown(() => temp.deleteSync(recursive: true));
      Future<void> compare(Plan plan) async {
        final log = File(env['LOG']!);
        final native = await Executor(
          write: (_) {},
          environment: env,
        ).execute(plan);
        final nativeLog = log.existsSync()
            ? log.readAsLinesSync().map(jsonDecode).toList()
            : [];
        if (log.existsSync()) log.deleteSync();
        final script = File(p.join(temp.path, 'replay.sh'))
          ..writeAsStringSync(renderPlan(plan));
        final replay = await Process.run(
          'sh',
          [script.path],
          workingDirectory: temp.path,
          environment: env,
        );
        final shellLog = log.existsSync()
            ? log.readAsLinesSync().map(jsonDecode).toList()
            : [];
        expect(
          replay.exitCode == 0,
          native.exitCode == 0,
          reason: '${replay.stderr}\n${script.readAsStringSync()}',
        );
        expect(shellLog, nativeLog);
      }

      for (final code in [0, 1, 65, 79]) {
        for (final filtered in [false, true]) {
          for (final failFast in [false, true]) {
            test(
              'exit $code, filtered $filtered, fail-fast $failFast',
              () async {
                File(
                  p.join(temp.path, 'a space%20semi;', '.exit'),
                ).writeAsStringSync('$code');
                final args = [
                  if (filtered) '--tags=t',
                  '--reporter',
                  "a b'\"\$HOME;*\nline",
                ];
                final plan = buildPlan(
                  workspace,
                  const Config(),
                  Request('test', arguments: args, failFast: failFast),
                );
                await compare(plan);
              },
            );
          }
        }
      }
      test(
        'multiple accepted statuses preserve successful command behavior',
        () async {
          for (final code in [0, 65, 79, 1]) {
            File(p.join(temp.path, '.exit')).writeAsStringSync('$code');
            final log = File(env['LOG']!);
            if (log.existsSync()) log.deleteSync();
            await compare(
              Plan(
                root: temp.path,
                command: 'exec',
                steps: [
                  const PlanStep(
                    package: 'root',
                    cwd: '.',
                    argv: ['stub'],
                    acceptedExitCodes: [0, 65, 79],
                  ),
                ],
              ),
            );
          }
        },
      );
      test(
        'exec passes empty arguments, shell metacharacters, env assignments and MONOREPO_ROOT',
        () async {
          await compare(
            buildPlan(
              workspace,
              const Config(),
              const Request(
                'exec',
                arguments: [
                  'EXTRA_ENV=1',
                  'stub',
                  '',
                  "a'b",
                  r'$(echo danger)',
                  'line\nbreak',
                ],
              ),
            ),
          );
        },
      );
      test('run appends quoted arguments and exports MONOREPO_ROOT', () async {
        await compare(
          buildPlan(
            workspace,
            const Config(scripts: {'s': Script('stub original')}),
            const Request(
              'run',
              script: 's',
              arguments: ['a b', r'$VALUE', ''],
            ),
          ),
        );
      });
    },
    skip: Platform.isWindows
        ? 'POSIX replay test requires sh and python3'
        : false,
  );

  test(
    'parallel workers respect limit and buffer output per completed package',
    () async {
      var active = 0;
      var maximum = 0;
      final output = <String>[];
      final steps = List.generate(
        6,
        (i) => PlanStep(package: 'p$i', cwd: '.', argv: ['stub']),
      );
      final executor = Executor(
        write: output.add,
        runner: (step, root, buffered) async {
          expect(buffered, isTrue);
          active++;
          if (active > maximum) maximum = active;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          return StepResult(step, 0, Duration.zero, 'one\ntwo\n');
        },
      );
      final result = await executor.execute(
        Plan(root: '.', command: 'exec', steps: steps, concurrency: 3),
      );
      expect(maximum, 3);
      expect(result.exitCode, 0);
      expect(output.where((line) => line.startsWith('[p')).length, 6);
      expect(
        output
            .where((line) => line.startsWith('[p'))
            .every((line) => line.endsWith('one\ntwo\n')),
        isTrue,
      );
    },
  );
  test(
    'fail-fast drains active workers and does not start queued work',
    () async {
      final starts = <String>[];
      final steps = List.generate(
        5,
        (i) => PlanStep(package: 'p$i', cwd: '.', argv: ['stub']),
      );
      final result =
          await Executor(
            write: (_) {},
            runner: (step, root, buffered) async {
              starts.add(step.package);
              await Future<void>.delayed(
                Duration(milliseconds: step.package == 'p0' ? 1 : 15),
              );
              return StepResult(
                step,
                step.package == 'p0' ? 1 : 0,
                Duration.zero,
                '',
              );
            },
          ).execute(
            Plan(
              root: '.',
              command: 'exec',
              steps: steps,
              concurrency: 2,
              failFast: true,
            ),
          );
      expect(starts, ['p0', 'p1']);
      expect(result.exitCode, 1);
      expect(
        result.results.skip(2).every((r) => r.skipReason == 'fail-fast'),
        isTrue,
      );
    },
  );
  test('spawn failure is environment exit 2', () async {
    final result = await Executor(write: (_) {}).execute(
      Plan(
        root: Directory.current.path,
        command: 'exec',
        steps: [
          const PlanStep(
            package: 'missing',
            cwd: '.',
            argv: ['monorepo-no-such-command-0123456789'],
          ),
        ],
      ),
    );
    expect(result.exitCode, 2);
  });
  test('Windows bash lookup skips the WSL launcher and finds Git Bash', () {
    const wsl = r'C:\WINDOWS\system32\bash.exe';
    const apps = r'C:\Users\u\AppData\Local\Microsoft\WindowsApps\bash.exe';
    const git = r'C:\Program Files\Git\bin\bash.exe';
    final env = {
      'Path':
          r'C:\WINDOWS\system32;C:\Users\u\AppData\Local\Microsoft\WindowsApps;C:\Program Files\Git\cmd',
      'ProgramFiles': r'C:\Program Files',
    };
    // Only the WSL launchers exist on PATH; fall back to git.exe's install.
    expect(
      findGitBashDirectory(env, (f) => {wsl, apps, git}.contains(f)),
      r'C:\Program Files\Git\bin',
    );
    expect(findGitBashDirectory(env, (f) => {wsl, apps}.contains(f)), isNull);
    // A real bash.exe earlier on PATH wins over the fallbacks.
    final withBin = {
      'PATH': r'C:\WINDOWS\system32;D:\git\bin',
      'ProgramFiles': r'C:\Program Files',
    };
    expect(
      findGitBashDirectory(
        withBin,
        (f) => {wsl, r'D:\git\bin\bash.exe', git}.contains(f),
      ),
      r'D:\git\bin',
    );
  });
  test(
    'Windows unknown command is environment exit 2, not cmd exit 1',
    () async {
      final output = <String>[];
      final result =
          await Executor(
            windows: true,
            commandAvailable: (name, env) => name == 'dart',
            write: output.add,
          ).execute(
            const Plan(
              root: '.',
              command: 'exec',
              steps: [
                PlanStep(package: 's', cwd: '.', argv: ['no-such-tool', '--x']),
              ],
            ),
          );
      expect(result.exitCode, 2);
      expect(output.join(), contains('Cannot start no-such-tool --x'));
    },
  );
  test(
    'Windows run reports missing bash as environment error with command',
    () async {
      final output = <String>[];
      final result =
          await Executor(
            windows: true,
            commandAvailable: (name, env) => false,
            gitBashDirectory: (env) => null,
            write: output.add,
          ).execute(
            const Plan(
              root: '.',
              command: 'run',
              steps: [
                PlanStep(
                  package: 's',
                  cwd: '.',
                  argv: ['bash', '-c', 'echo hello'],
                ),
              ],
            ),
          );
      expect(result.exitCode, 2);
      expect(output.join(), contains('bash -c'));
      expect(output.join(), contains('Git Bash is required'));
    },
  );
  test('arbitrary binary subprocess output cannot crash decoding', () async {
    final output = <String>[];
    final result = await Executor(write: output.add).execute(
      Plan(
        root: Directory.current.path,
        command: 'exec',
        steps: [
          const PlanStep(
            package: 'binary',
            cwd: '.',
            argv: [
              'python3',
              '-c',
              'import sys; sys.stdout.buffer.write(bytes([255]))',
            ],
          ),
        ],
      ),
    );
    expect(result.exitCode, 0);
    expect(output.join(), contains('\uFFFD'));
  }, skip: Platform.isWindows);

  group('dependency-aware scheduling', () {
    Future<List<String>> events(Plan plan) async {
      final log = <String>[];
      await Executor(
        write: (_) {},
        runner: (step, root, buffered) async {
          log.add('start ${step.package}');
          await Future<void>.delayed(
            Duration(milliseconds: step.package == 'core' ? 20 : 5),
          );
          log.add('end ${step.package}');
          return StepResult(step, 0, Duration.zero, '');
        },
      ).execute(plan);
      return log;
    }

    test('exec steps wait for the members they depend on', () async {
      final log = await events(
        const Plan(
          root: '.',
          command: 'exec',
          concurrency: 3,
          steps: [
            PlanStep(package: 'core', cwd: 'core', argv: ['x']),
            PlanStep(package: 'other', cwd: 'other', argv: ['x']),
            PlanStep(
              package: 'ui',
              cwd: 'ui',
              argv: ['x'],
              dependsOn: ['core'],
            ),
          ],
        ),
      );
      expect(log.indexOf('start ui'), greaterThan(log.indexOf('end core')));
      expect(log.indexOf('start other'), lessThan(log.indexOf('end core')));
    });

    test('steps without dependencies start in plan order at once', () async {
      final log = await events(
        Plan(
          root: '.',
          command: 'test',
          concurrency: 3,
          steps: [
            for (final name in ['core', 'ui', 'app'])
              PlanStep(package: name, cwd: name, argv: const ['x']),
          ],
        ),
      );
      expect(log.take(3), ['start core', 'start ui', 'start app']);
    });

    test('planner lists nearest selected dependencies, through skips', () {
      Package pkg(String name, [Set<String> deps = const {}]) =>
          Package(name: name, path: '/w/$name', relPath: name, localDeps: deps);
      final workspace = Workspace(
        root: '/w',
        packages: [
          pkg('core'),
          pkg('mid', {'core'}),
          pkg('app', {'mid'}),
        ],
      );
      final plan = buildPlan(
        workspace,
        const Config(),
        const Request(
          'exec',
          arguments: ['x'],
          filters: Filters(ignore: ['mid']),
        ),
      );
      expect(plan.steps.map((s) => s.dependsOn), [
        isEmpty,
        isEmpty,
        ['core'],
      ]);
      expect(plan.steps.last.toJson()['dependsOn'], ['core']);
      expect(plan.steps.first.toJson().containsKey('dependsOn'), isFalse);
      final test = buildPlan(workspace, const Config(), const Request('test'));
      expect(test.steps.every((s) => s.dependsOn.isEmpty), isTrue);
    });
  });

  group('reporting', () {
    final plan = Plan(
      root: '.',
      command: 'test',
      steps: const [
        PlanStep(package: 'a', cwd: 'a', argv: ['dart', 'test']),
        PlanStep(
          package: 'b',
          cwd: 'b',
          argv: ['dart', 'test', '-x', 'slow'],
          acceptedExitCodes: [0, 79],
        ),
        PlanStep(package: 'c', cwd: 'c', argv: ['flutter', 'test']),
        PlanStep(package: 'd', cwd: 'd', skipReason: 'no test/ directory'),
      ],
    );
    StepResult fake(PlanStep step, String root, bool buffered) => StepResult(
      step,
      {'a': 0, 'b': 79, 'c': 1}[step.package],
      const Duration(milliseconds: 1250),
      'out ${step.package}\n',
    );

    test('text output frames each step and ends with a summary', () async {
      final output = <String>[];
      final result = await Executor(
        write: output.add,
        runner: (step, root, buffered) async => fake(step, root, buffered),
      ).execute(plan);
      expect(result.exitCode, 1);
      final text = output.join();
      expect(text, startsWith('[a] dart test\n'));
      final summary = text.substring(text.indexOf('package  '));
      expect(summary.split('\n').take(5), [
        'package  command            status                    duration',
        'a        dart test          passed                    1.25s',
        'b        dart test -x slow  no matching tests         1.25s',
        'c        flutter test       failed (1)                1.25s',
        'd        -                  skip: no test/ directory  -',
      ]);
      expect(
        summary,
        contains('2 passed, 1 with no matching tests, 1 failed, 1 skipped in'),
      );
    });

    test('json reporter prints one document with captured output', () async {
      final output = <String>[];
      final buffering = <bool>[];
      await Executor(
        write: output.add,
        reporter: Reporter.json,
        runner: (step, root, buffered) async {
          buffering.add(buffered);
          return fake(step, root, buffered);
        },
      ).execute(plan);
      expect(buffering, everyElement(isTrue));
      expect(output, hasLength(1));
      final json = jsonDecode(output.single) as Map<String, Object?>;
      expect(json['command'], 'test');
      expect(json['exitCode'], 1);
      expect(json['summary'], {
        'passed': 1,
        'no-tests': 1,
        'failed': 1,
        'skipped': 1,
      });
      final steps = (json['steps'] as List).cast<Map<String, Object?>>();
      expect(steps.map((s) => s['status']), [
        'passed',
        'no-tests',
        'failed',
        'skipped',
      ]);
      expect(steps.first['output'], 'out a\n');
      expect(steps.first['seconds'], 1.25);
      expect(steps.last['skipReason'], 'no test/ directory');
    });
  });

  test('child stdin is closed, so a read sees end of file', () async {
    for (final concurrency in [1, 2]) {
      final result = await Executor(write: (_) {})
          .execute(
            Plan(
              root: Directory.current.path,
              command: 'exec',
              concurrency: concurrency,
              steps: [
                for (final name in ['a', 'b'])
                  PlanStep(
                    package: name,
                    cwd: '.',
                    argv: [
                      'bash',
                      '-c',
                      r'if read -r line; then echo "read:$line"; else echo eof; fi',
                    ],
                  ),
              ],
            ),
          )
          .timeout(const Duration(seconds: 30));
      expect(result.results.map((r) => r.output), ['eof\n', 'eof\n']);
    }
  }, skip: Platform.isWindows ? 'needs bash' : false);

  group('signals', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('monorepo-signal-'));
    tearDown(() => temp.deleteSync(recursive: true));

    for (final (signal, code) in [
      (ProcessSignal.sigterm, 143),
      (ProcessSignal.sigint, 130),
    ]) {
      test(
        '$signal stops the child tree, prints the summary, exits $code',
        () async {
          final script = File(p.join(temp.path, 'run.dart'))
            ..writeAsStringSync(r'''
import 'dart:io';
import 'package:monorepo/src/executor.dart';
import 'package:monorepo/src/planner.dart';

Future<void> main(List<String> args) async {
  final result = await Executor(handleSignals: true).execute(
    Plan(
      root: args.first,
      command: 'exec',
      concurrency: 2,
      steps: const [
        PlanStep(
          package: 'slow',
          cwd: '.',
          argv: ['bash', '-c', r'echo started; sleep 60 & echo $! > grandchild; wait'],
        ),
        PlanStep(package: 'queued', cwd: '.', argv: ['sleep', '60'], dependsOn: ['slow']),
      ],
    ),
  );
  exitCode = result.exitCode;
}
''');
          final process = await Process.start(Platform.resolvedExecutable, [
            '--packages=${p.join(Directory.current.path, '.dart_tool/package_config.json')}',
            script.path,
            temp.path,
          ]);
          final out = process.stdout.transform(utf8.decoder).join();
          final err = process.stderr.transform(utf8.decoder).join();
          final pidFile = File(p.join(temp.path, 'grandchild'));
          final deadline = DateTime.now().add(const Duration(seconds: 60));
          while (!pidFile.existsSync() ||
              pidFile.readAsStringSync().trim().isEmpty) {
            if (DateTime.now().isAfter(deadline)) fail('child never started');
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          final grandchild = int.parse(pidFile.readAsStringSync().trim());
          process.kill(signal);
          final exit = await process.exitCode.timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              process.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
          final stdoutText = await out;
          expect(exit, code, reason: '$stdoutText\n${await err}');
          // Buffered output of the stopped step is flushed before the summary.
          expect(stdoutText, contains('[slow] bash -c'));
          expect(stdoutText, contains('started'));
          expect(stdoutText, contains('skip: interrupted'));
          expect(stdoutText, contains('0 passed, 1 failed, 1 skipped'));
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(Directory('/proc/$grandchild').existsSync(), isFalse);
        },
        skip: Platform.isLinux ? false : 'signal delivery is tested on Linux',
      );
    }
  });
}

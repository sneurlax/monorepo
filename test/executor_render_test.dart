import 'dart:convert';
import 'dart:io';
import 'package:monorepo/src/config.dart';
import 'package:monorepo/src/executor.dart';
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
 f.write(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd(),'root':os.getenv('MONOREPO_ROOT'),'code':code})+'\n')
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
        'exec passes empty arguments, shell metacharacters and MONOREPO_ROOT',
        () async {
          await compare(
            buildPlan(
              workspace,
              const Config(),
              const Request(
                'exec',
                arguments: [
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
}

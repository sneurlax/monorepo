@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:monorepo/src/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final project = Directory.current.path;
  final executable = p.join(project, 'bin/monorepo.dart');
  final packageConfig = p.join(project, '.dart_tool/package_config.json');
  final env = {
    'DASH__SUPPRESS_ANALYTICS': 'true',
    'FLUTTER_SUPPRESS_ANALYTICS': 'true',
  };
  late Directory fixture;
  void put(String path, String content) {
    final f = File(p.join(fixture.path, path));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  Future<ProcessResult> tool(List<String> args, {String? cwd}) => Process.run(
    Platform.resolvedExecutable,
    ['--packages=$packageConfig', executable, ...args],
    workingDirectory: cwd ?? fixture.path,
    environment: env,
  );
  Future<ProcessResult> run(
    String command,
    List<String> args,
    String cwd,
  ) async {
    final process = await Process.start(
      command,
      args,
      workingDirectory: cwd,
      environment: env,
      runInShell: Platform.isWindows,
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return 124;
      },
    );
    return ProcessResult(process.pid, code, await out, await err);
  }

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('monorepo-real-');
    put('pubspec.yaml', '''name: fixture_workspace
publish_to: none
environment:
  sdk: ^3.10.0
workspace: [dart_pkg, flutter_pkg, hook_pkg, empty_dart, empty_flutter]
monorepo:
  scripts:
    print: 'printf "%s\\n"'
''');
    for (final name in ['dart_pkg', 'hook_pkg', 'empty_dart']) {
      put('$name/pubspec.yaml', '''name: $name
resolution: workspace
environment:
  sdk: ^3.10.0
${name == 'hook_pkg' ? "dependencies:\n  hooks: '>=1.0.0 <3.0.0'\n" : ''}dev_dependencies:
  test: ^1.26.3
''');
    }
    for (final name in ['flutter_pkg', 'empty_flutter']) {
      put('$name/pubspec.yaml', '''name: $name
resolution: workspace
environment:
  sdk: ^3.10.0
dependencies:
  flutter: {sdk: flutter}
dev_dependencies:
  flutter_test: {sdk: flutter}
''');
    }
    const dartTest =
        "import 'dart:io';\nimport 'package:test/test.dart';\nvoid main() { test('cwd', () { expect(Directory.current.path.endsWith('dart_pkg'), isTrue); }); }\n";
    put('dart_pkg/test/cwd_test.dart', dartTest);
    put(
      'flutter_pkg/test/simple_test.dart',
      "import 'package:flutter_test/flutter_test.dart';\nvoid main() { test('works', () => expect(1 + 1, 2)); }\n",
    );
    put(
      'hook_pkg/hook/build.dart',
      "import 'dart:io';\nimport 'package:hooks/hooks.dart';\nvoid main(List<String> args) async { await build(args, (input, output) async { File.fromUri(input.packageRoot.resolve('hook-ran')).writeAsStringSync('yes'); }); }\n",
    );
    put(
      'hook_pkg/test/hook_test.dart',
      "import 'dart:io';\nimport 'package:test/test.dart';\nvoid main() { test('hook ran from package cwd', () { expect(File('hook-ran').existsSync(), isTrue); expect(Directory.current.path.endsWith('hook_pkg'), isTrue); }); }\n",
    );
    final result = await run('flutter', [
      'pub',
      'get',
      '--offline',
    ], fixture.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));
  test('version, help and usage error', () async {
    expect((await tool(['--version'])).stdout, '0.1.0\n');
    expect((await tool(['help', 'test'])).stdout, contains('--concurrency'));
    expect((await tool(['unknown'])).exitCode, 2);
  });
  test('list discovers members from a nested working directory', () async {
    final result = await tool([
      'list',
      '--json',
    ], cwd: p.join(fixture.path, 'dart_pkg'));
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final list = jsonDecode(result.stdout as String) as List;
    expect(list.length, 5);
    expect(list.any((p) => (p as Map)['name'] == 'fixture_workspace'), isFalse);
    expect(list.where((p) => (p as Map)['isFlutter'] == true).length, 2);
  });
  test(
    'plan and check do not edit pubspec, lockfile or package config',
    () async {
      final paths = [
        'pubspec.yaml',
        'pubspec.lock',
        '.dart_tool/package_config.json',
      ];
      final before = {
        for (final file in paths)
          file: File(p.join(fixture.path, file)).readAsBytesSync(),
      };
      for (final args in [
        ['plan', 'test'],
        ['plan', 'analyze'],
        ['plan', 'format', '--check'],
        ['check', '--json'],
      ]) {
        final result = await tool(args);
        expect(
          result.exitCode,
          args.first == 'check' ? 1 : 0,
          reason: '${result.stderr}',
        );
      }
      for (final file in paths) {
        expect(
          File(p.join(fixture.path, file)).readAsBytesSync(),
          before[file],
        );
      }
    },
  );
  test(
    'real Dart and Flutter runner empty/filter exit codes are not conflated',
    () async {
      expect(
        (await run('dart', [
          'test',
        ], p.join(fixture.path, 'empty_dart'))).exitCode,
        65,
      );
      expect(
        (await run('flutter', [
          'test',
        ], p.join(fixture.path, 'empty_flutter'))).exitCode,
        1,
      );
      expect(
        (await run('dart', [
          'test',
          '--name=DOES_NOT_EXIST',
        ], p.join(fixture.path, 'dart_pkg'))).exitCode,
        79,
      );
      expect(
        (await run('flutter', [
          'test',
          '--name=DOES_NOT_EXIST',
        ], p.join(fixture.path, 'flutter_pkg'))).exitCode,
        79,
      );
      final result = await tool([
        'test',
        '--ignore',
        'hook_pkg',
        '--',
        '--name=DOES_NOT_EXIST',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('no matching tests'));
      expect(result.stdout, contains('no test/ directory'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('real execution honors cwd and runs package build hook', () async {
    final result = await tool(['test']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      File(p.join(fixture.path, 'hook_pkg/hook-ran')).existsSync(),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
  test('format requires package config, script args keep spaces', () async {
    final config = File(p.join(fixture.path, '.dart_tool/package_config.json'));
    final saved = config.readAsBytesSync();
    config.deleteSync();
    try {
      final result = await tool(['plan', 'format', '--check']);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('run dart pub get'));
    } finally {
      config.writeAsBytesSync(saved);
    }
    final result = await tool(['run', 'print', '--', 'hello world']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, startsWith('hello world\n'));
  });
  test('discovery timeout terminates its child', () async {
    await expectLater(
      discoverWorkspace(directory: fixture.path, timeout: Duration.zero),
      throwsA(isA<ToolException>()),
    );
  });
}

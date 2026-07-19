import 'dart:io';
import 'package:args/command_runner.dart';

const version = '0.1.0';

Future<int> runMonorepo(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'monorepo',
    'Optional pub workspace commands.',
  )..argParser.addFlag('version', negatable: false);
  try {
    final parsed = runner.parse(arguments);
    if (parsed['version'] as bool) {
      stdout.writeln(version);
      return 0;
    }
    return await runner.runCommand(parsed) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return 2;
  }
}

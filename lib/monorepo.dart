import 'dart:io';
import 'package:args/command_runner.dart';
import 'src/commands/runner.dart';
import 'src/model.dart';

export 'src/changes.dart';
export 'src/config.dart';
export 'src/doctor.dart';
export 'src/executor.dart';
export 'src/filters.dart';
export 'src/graph.dart';
export 'src/model.dart';
export 'src/ownership.dart';
export 'src/planner.dart';
export 'src/render.dart';
export 'src/workspace.dart';

Future<int> runMonorepo(List<String> arguments) async {
  final runner = MonorepoRunner();
  try {
    final parsed = runner.parse(arguments);
    if (parsed['version'] as bool) {
      stdout.writeln(toolVersion);
      return 0;
    }
    return await runner.runCommand(parsed) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return 2;
  } on ToolException catch (error) {
    stderr.writeln(error.message);
    return 2;
  } on FileSystemException catch (error) {
    stderr.writeln(error.message);
    return 2;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return 2;
  }
}

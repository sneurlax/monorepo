import 'dart:io';
import 'package:monorepo/monorepo.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runMonorepo(arguments);
}

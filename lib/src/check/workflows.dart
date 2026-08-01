import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../model.dart';

/// A shell body and its static workflow context. This never executes the body.
class WorkflowStep {
  final String file;
  final int line;
  final String run;
  final String workingDirectory;
  final bool dynamicContext;

  const WorkflowStep({
    required this.file,
    required this.line,
    required this.run,
    required this.workingDirectory,
    this.dynamicContext = false,
  });
}

/// Extracts jobs' run steps, honoring workflow/job/step directory precedence.
List<WorkflowStep> readWorkflowSteps(String root, List<String> directories) {
  final files = <String>{};
  for (final directory in directories) {
    final location = p.normalize(p.join(root, directory));
    final type = FileSystemEntity.typeSync(location);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.directory) {
      throw ToolException('Workflow directory is not a directory: $directory');
    }
    for (final entity in Directory(
      location,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is File &&
          {'.yml', '.yaml'}.contains(p.extension(entity.path))) {
        files.add(entity.path);
      }
    }
  }
  final steps = <WorkflowStep>[];
  for (final file in files.toList()..sort()) {
    final text = File(file).readAsStringSync();
    final YamlNode document;
    try {
      document = loadYamlNode(text, sourceUrl: Uri.file(file));
    } on YamlException catch (error) {
      throw ToolException('Invalid workflow $file: $error');
    }
    if (document is! YamlMap) continue;
    final jobs = document['jobs'];
    if (jobs is! YamlMap) continue;
    final defaultDirectory = _defaultDirectory(document) ?? '.';
    for (final job in jobs.values) {
      if (job is! YamlMap) continue;
      final jobSteps = job['steps'];
      if (jobSteps is! YamlList) continue;
      String? checkoutPath;
      for (final step in jobSteps) {
        if (step is! YamlMap ||
            !(step['uses']?.toString().startsWith('actions/checkout@') ??
                false)) {
          continue;
        }
        final withOptions = step['with'];
        if (withOptions is YamlMap && withOptions['repository'] != null) {
          continue; // A sibling repository's checkout is not our root.
        }
        checkoutPath = withOptions is YamlMap
            ? withOptions['path']?.toString()
            : null;
        break;
      }
      final jobDirectory = _defaultDirectory(job) ?? defaultDirectory;
      for (final step in jobSteps) {
        if (step is! YamlMap || !step.containsKey('run')) continue;
        final run = step['run'];
        if (run is! String) {
          throw ToolException('Workflow run value must be a string: $file');
        }
        final rawDirectory = step['working-directory'] ?? jobDirectory;
        if (rawDirectory is! String) {
          throw ToolException(
            'Workflow working-directory must be a string: $file',
          );
        }
        var directory = rawDirectory.replaceAll('\\', '/');
        if (checkoutPath != null && !checkoutPath.contains(r'$')) {
          final prefix = p.posix.normalize(checkoutPath.replaceAll('\\', '/'));
          directory = p.posix.normalize(directory);
          if (directory == prefix) {
            directory = '.';
          } else if (directory.startsWith('$prefix/')) {
            directory = directory.substring(prefix.length + 1);
          }
        }
        final runNode = step.nodes['run'];
        final spanText = (runNode?.span.text ?? '').trimLeft();
        final block = spanText.startsWith('|') || spanText.startsWith('>');
        steps.add(
          WorkflowStep(
            file: p.relative(file, from: root).replaceAll('\\', '/'),
            line: (runNode?.span.start.line ?? 0) + (block ? 2 : 1),
            run: run,
            workingDirectory: directory,
            dynamicContext:
                directory.contains(r'$') ||
                RegExp(r'\$\{\{\s*matrix\.').hasMatch(run),
          ),
        );
      }
    }
  }
  return steps;
}

String? _defaultDirectory(YamlMap map) {
  final defaults = map['defaults'];
  if (defaults is! YamlMap) return null;
  final run = defaults['run'];
  if (run is! YamlMap) return null;
  final directory = run['working-directory'];
  if (directory == null) return null;
  if (directory is! String) {
    throw const ToolException(
      'Workflow default working-directory must be a string',
    );
  }
  return directory;
}

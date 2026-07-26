import 'dart:io';
import 'package:path/path.dart' as p;
import 'config.dart';
import 'filters.dart';
import 'model.dart';
import 'workspace.dart' show forward;

class OwnedFiles {
  final List<String> files;
  final List<String> paths;
  const OwnedFiles({required this.files, required this.paths});
}

Map<String, OwnedFiles> collectOwnership(Workspace workspace, Config config) =>
    {
      for (final package in workspace.packages)
        package.name: ownedFiles(
          workspace.root,
          package.path,
          exclude: config.formatExclude,
        ),
    };

OwnedFiles ownedFiles(
  String root,
  String packageRoot, {
  List<String> exclude = const [],
}) {
  final files = <String>[];
  String rel(String path) => forward(p.relative(path, from: root));
  ({bool complete, List<String> paths}) walk(String directory) {
    var complete = true;
    final paths = <String>[];
    final entries = Directory(directory).listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        if (name.startsWith('.') ||
            name == 'build' ||
            File(p.join(entry.path, 'pubspec.yaml')).existsSync()) {
          complete = false;
          continue;
        }
        final child = walk(entry.path);
        complete &= child.complete;
        paths.addAll(child.paths);
      } else if (entry is Link) {
        // Never follow links out of ownership or compress across them.
        complete = false;
      } else if (entry is File && name.endsWith('.dart')) {
        final path = rel(entry.path);
        if (exclude.any((pattern) => globMatches(pattern, path))) {
          complete = false;
        } else {
          if (name.startsWith('.')) complete = false;
          files.add(path);
          paths.add(path);
        }
      }
    }
    return (
      complete: complete,
      paths: complete && paths.isNotEmpty ? [rel(directory)] : paths,
    );
  }

  final result = walk(packageRoot);
  files.sort();
  return OwnedFiles(files: files, paths: result.paths);
}

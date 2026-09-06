import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'model.dart';
import 'workspace.dart' show forward;

/// Root files whose change can affect every member's resolution or lints.
const workspaceFiles = {
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
};

/// Members selected by `--since`, and why.
class ChangeSet {
  final String ref;

  /// Root-relative paths changed since [ref], sorted.
  final List<String> files;

  /// Changed root workspace files; when non-empty every member is selected.
  final List<String> workspaceChanges;

  /// Members that own a changed file, before dependents are added.
  final Set<String> changed;

  /// The selected members: [changed], plus dependents when requested.
  final Set<String> packages;

  const ChangeSet({
    required this.ref,
    required this.files,
    required this.workspaceChanges,
    required this.changed,
    required this.packages,
  });

  /// Plan comments describing a selection that is not obvious from skips.
  List<String> get comments => [
    if (workspaceChanges.isNotEmpty)
      'workspace files changed since $ref (${workspaceChanges.join(', ')}); every member is selected',
  ];
}

/// Lists files changed in `<ref>...HEAD` plus uncommitted and untracked
/// files under [root]. Git runs read-only, without optional index locks.
Future<List<String>> changedFiles(
  String root,
  String ref, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (ref.isEmpty || ref.startsWith('-')) {
    throw ToolException('--since needs a git ref, not "$ref"');
  }
  Future<String> git(List<String> arguments) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'git',
        arguments,
        workingDirectory: root,
        environment: {'GIT_OPTIONAL_LOCKS': '0'},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
    } on ProcessException catch (error) {
      throw ToolException('Cannot run git for --since: ${error.message}');
    } on TimeoutException {
      throw ToolException(
        'git ${arguments.first} timed out after ${timeout.inSeconds}s',
      );
    }
    if (result.exitCode != 0) {
      final detail = (result.stderr as String).trim();
      throw ToolException(
        'git ${arguments.join(' ')} failed (${result.exitCode})${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    return result.stdout as String;
  }

  try {
    await git(['rev-parse', '--verify', '--quiet', '$ref^{commit}']);
  } on ToolException {
    throw ToolException('--since: unknown git ref "$ref"');
  }
  final outputs = await Future.wait([
    git([
      'diff',
      '--name-only',
      '--no-renames',
      '--relative',
      '-z',
      '$ref...HEAD',
    ]),
    git(['diff', '--name-only', '--no-renames', '--relative', '-z', 'HEAD']),
    git(['ls-files', '--others', '--exclude-standard', '-z']),
  ]);
  final files = {
    for (final output in outputs)
      ...output.split('\u0000').where((f) => f.isNotEmpty).map(forward),
  }.toList()..sort();
  return files;
}

/// Maps root-relative [files] to the member that owns each one, using the
/// same fences as formatting: the deepest member directory wins, and a
/// directory with its own pubspec that is not a member belongs to nobody.
/// [isPackageDirectory] reports whether a root-relative directory holds a
/// pubspec, so tests can supply a snapshot.
Map<String, String?> owners(
  Workspace workspace,
  Iterable<String> files, {
  bool Function(String directory)? isPackageDirectory,
}) {
  final hasPubspec =
      isPackageDirectory ??
      (directory) =>
          File(p.join(workspace.root, directory, 'pubspec.yaml')).existsSync();
  final members = [...workspace.packages]
    ..sort((a, b) => b.relPath.length.compareTo(a.relPath.length));
  final result = <String, String?>{};
  for (final file in files) {
    String? owner;
    for (final member in members) {
      if (!p.posix.isWithin(member.relPath, file)) continue;
      var directory = p.posix.dirname(file);
      var fenced = false;
      while (directory != member.relPath && directory != '.') {
        if (hasPubspec(directory)) {
          fenced = true;
          break;
        }
        directory = p.posix.dirname(directory);
      }
      if (!fenced) owner = member.name;
      break;
    }
    result[file] = owner;
  }
  return result;
}

/// Adds every member that depends on [names], directly or transitively,
/// through dependencies or dev_dependencies.
Set<String> withDependents(Workspace workspace, Set<String> names) {
  final result = {...names};
  var added = true;
  while (added) {
    added = false;
    for (final package in workspace.packages) {
      if (!result.contains(package.name) &&
          package.localDeps.any(result.contains)) {
        result.add(package.name);
        added = true;
      }
    }
  }
  return result;
}

/// Builds the `--since` selection from a list of changed files.
ChangeSet changeSet(
  Workspace workspace,
  String ref,
  List<String> files, {
  bool includeDependents = false,
  bool Function(String directory)? isPackageDirectory,
}) {
  final rootChanges = files.where(workspaceFiles.contains).toList()..sort();
  final changed = owners(
    workspace,
    files,
    isPackageDirectory: isPackageDirectory,
  ).values.whereType<String>().toSet();
  final selected = rootChanges.isNotEmpty
      ? workspace.packages.map((package) => package.name).toSet()
      : includeDependents
      ? withDependents(workspace, changed)
      : changed;
  return ChangeSet(
    ref: ref,
    files: files,
    workspaceChanges: rootChanges,
    changed: changed,
    packages: selected,
  );
}

/// The version `--version` prints; the pubspec version, checked by a test.
const toolVersion = '0.1.0';

/// Immutable package and workspace input shared by planners and drift checks.
class Package {
  final String name;
  final String path;
  final String relPath;
  final bool isFlutter;
  final bool hasTest;
  final bool hasIntegrationTest;
  final Set<String> localDeps;
  final Map<String, Object?> pubspec;
  const Package({
    required this.name,
    required this.path,
    required this.relPath,
    this.isFlutter = false,
    this.hasTest = false,
    this.hasIntegrationTest = false,
    this.localDeps = const {},
    this.pubspec = const {},
  });
  Map<String, Object?> toJson() => {
    'name': name,
    'path': path,
    'relPath': relPath,
    'isFlutter': isFlutter,
    'hasTest': hasTest,
    'hasIntegrationTest': hasIntegrationTest,
    'localDeps': localDeps.toList()..sort(),
  };
}

class Workspace {
  final String root;
  final List<Package> packages;
  final Map<String, Object?> pubspec;
  final List<List<String>> cycles;
  const Workspace({
    required this.root,
    required this.packages,
    this.pubspec = const {},
    this.cycles = const [],
  });
}

class ToolException implements Exception {
  final String message;
  const ToolException(this.message);
  @override
  String toString() => message;
}

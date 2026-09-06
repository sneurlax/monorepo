import 'package:path/path.dart' as p;
import 'config.dart';
import 'model.dart';

/// Portable glob matching. `*` never crosses `/`; `**` does.
bool globMatches(String pattern, String value) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        i++;
        if (i + 1 < pattern.length && pattern[i + 1] == '/') {
          i++;
          buffer.write('(?:.*/)?');
        } else {
          buffer.write('.*');
        }
      } else {
        buffer.write('[^/]*');
      }
    } else if (c == '?') {
      buffer.write('[^/]');
    } else {
      buffer.write(RegExp.escape(c));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString()).hasMatch(value);
}

class Filters {
  final List<String> scope;
  final List<String> ignore;
  final bool? flutter;
  // Presence is resolved before planning, so selection performs no I/O.
  final Set<String>? directoryPackages;
  final Set<String>? filePackages;

  /// Members selected by `--since`, resolved from git before planning.
  final Set<String>? changedPackages;

  /// The `--since` ref, for skip reasons.
  final String? since;
  const Filters({
    this.scope = const [],
    this.ignore = const [],
    this.flutter,
    this.directoryPackages,
    this.filePackages,
    this.changedPackages,
    this.since,
  });

  String? skipReason(Package package, Config config, String command) {
    bool matches(String value) => globMatches(
      value,
      value.contains('/') ? package.relPath : package.name,
    );
    if (scope.isNotEmpty && !scope.any(matches)) return 'outside scope';
    if (ignore.any(matches)) return 'ignored by command line';
    final explicit =
        scope.contains(package.name) ||
        scope
            .map((s) => p.posix.normalize(s.replaceAll('\\', '/')))
            .contains(package.relPath);
    if (!explicit && config.ignore.contains(package.name)) {
      return 'ignored by config';
    }
    if (!explicit &&
        command == 'test' &&
        config.testIgnore.contains(package.name)) {
      return 'ignored by test config';
    }
    if (flutter != null && package.isFlutter != flutter) {
      return 'package kind filter';
    }
    if (directoryPackages != null &&
        !directoryPackages!.contains(package.name)) {
      return 'directory filter';
    }
    if (filePackages != null && !filePackages!.contains(package.name)) {
      return 'file filter';
    }
    if (changedPackages != null && !changedPackages!.contains(package.name)) {
      return 'unchanged since $since';
    }
    return null;
  }
}

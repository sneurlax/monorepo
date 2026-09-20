import 'dart:io';

import 'package:monorepo/monorepo.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  void write(String path, String text) {
    final file = File(p.join(root.path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  Future<String?> probe(String executable, List<String> args) async =>
      executable == 'dart'
      ? 'Dart SDK version: 3.13.2 (stable) on "linux_x64"\n'
      : 'Waiting for lock\n{"frameworkVersion": "3.47.2", "dartSdkVersion": "3.13.2"}\n';
  String? which(String name) => '/sdk/bin/$name';
  Future<void> discovered(String root) async {}

  setUp(() {
    root = Directory.systemTemp.createTempSync('monorepo-doctor-');
    write('pubspec.yaml', '''
name: root
environment: {sdk: ^3.10.0}
workspace: [packages/a, packages/b, packages/gone, "apps/*"]
''');
    write('pubspec.lock', '');
    write('.dart_tool/package_config.json', '{}');
    write('packages/a/pubspec.yaml', '''
name: a
resolution: workspace
environment: {sdk: ^3.10.0}
dependencies: {yaml: ^3.1.0, b: any}
''');
    write('packages/b/pubspec.yaml', '''
name: b
environment: {sdk: ^3.12.0}
dev_dependencies: {yaml: ^3.1.3, flutter_test: {sdk: flutter}}
''');
    write('packages/b/pubspec.lock', '');
    write('apps/app/pubspec.yaml', '''
name: app
resolution: workspace
environment: {sdk: ">=3.14.0 <4.0.0", flutter: ">=3.99.0"}
''');
    write('packages/a/tool/vendored/pubspec.yaml', 'name: vendored\n');
    write(
      'packages/extra/pubspec.yaml',
      'name: extra\nresolution: workspace\n',
    );
    write('packages/a/build/ignored/pubspec.yaml', 'name: built\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<DoctorReport> run({ToolProbe? tools}) => diagnose(
    p.join(root.path, 'packages', 'a'),
    probe: tools ?? probe,
    which: which,
    discover: discovered,
  );

  test(
    'reports workspace, resolution, lockfile and constraint problems',
    () async {
      final report = await run();
      expect(report.root, root.path);
      String lines(Iterable<Diagnosis> items) =>
          items.map((d) => '${d.kind}: ${d.message}').join('\n');
      expect(lines(report.errors), '''
resolution: b (packages/b) is listed in the workspace but lacks resolution: workspace
workspace: entry packages/gone does not exist
sdk: app requires Dart >=3.14.0 <4.0.0 but dart on PATH is 3.13.2
sdk: app requires Flutter >=3.99.0 but flutter on PATH is 3.47.2''');
      expect(lines(report.warnings), '''
membership: packages/extra declares resolution: workspace but is not listed in the root workspace
lockfile: packages/b/pubspec.lock is stray; workspace members resolve through the root
sdk: members use different Dart SDK constraints: >=3.14.0 <4.0.0 (app); ^3.10.0 ((root), a); ^3.12.0 (b)
dependencies: yaml is constrained differently: ^3.1.0 (a); ^3.1.3 (b)''');
      expect(
        report.items.where((d) => d.severity == 'info').map((d) => d.message),
        [
          contains('packages/a/tool/vendored'),
          'dart 3.13.2 (/sdk/bin/dart)',
          'flutter 3.47.2 with Dart 3.13.2 (/sdk/bin/flutter)',
        ],
      );
      expect(report.hasProblems(), isTrue);
      expect(report.toJson().keys, ['root', 'errors', 'warnings', 'info']);
      expect(report.renderHuman(), endsWith('4 error(s), 4 warning(s).'));
    },
  );

  test('warnings alone pass unless strict', () async {
    write('pubspec.yaml', 'name: root\nworkspace: [packages/a]\n');
    write('packages/a/pubspec.yaml', '''
name: a
resolution: workspace
dependencies: {flutter: {sdk: flutter}}
''');
    File(p.join(root.path, 'pubspec.lock')).deleteSync();
    final report = await run();
    expect(report.errors, isEmpty);
    expect(
      report.warnings.map((d) => d.message),
      contains(startsWith('no root pubspec.lock')),
    );
    expect(report.hasProblems(), isFalse);
    expect(report.hasProblems(strict: true), isTrue);
  });

  test('missing flutter is an error only when Flutter members exist', () async {
    write('pubspec.yaml', 'name: root\nworkspace: [packages/a]\n');
    write('packages/a/pubspec.yaml', 'name: a\nresolution: workspace\n');
    final report = await diagnose(
      root.path,
      probe: probe,
      which: (name) => name == 'dart' ? '/sdk/bin/dart' : null,
      discover: discovered,
    );
    expect(report.errors, isEmpty);
    expect(
      report.items.last.message,
      'flutter is not on PATH (no Flutter members)',
    );
  });

  test('outside a workspace and failing discovery are errors', () async {
    final outside = Directory.systemTemp.createTempSync('monorepo-none-');
    addTearDown(() => outside.deleteSync(recursive: true));
    final none = await diagnose(
      outside.path,
      probe: probe,
      which: which,
      discover: discovered,
    );
    expect(none.root, isNull);
    expect(none.errors.single.message, contains('no pubspec.yaml'));
    final failing = await diagnose(
      root.path,
      probe: probe,
      which: which,
      discover: (_) async =>
          throw const ToolException('dart pub workspace list failed (65): x'),
    );
    expect(
      failing.errors.map((d) => d.message),
      contains(startsWith('dart pub workspace list failed (65)')),
    );
  });

  test('invalid monorepo config is reported as an error', () async {
    write('pubspec.yaml', '''
name: root
workspace: [packages/a]
monorepo:
  ignore: [nope]
''');
    write('packages/a/pubspec.yaml', 'name: a\nresolution: workspace\n');
    final report = await run();
    expect(
      report.errors.single.message,
      'monorepo.ignore: unknown package "nope"',
    );
  });

  test(
    'glob matches without a pubspec are skipped, explicit ones are not',
    () async {
      write('pubspec.yaml', '''
name: root
environment: {sdk: ^3.10.0}
workspace: [packages/a, packages/empty, "tools/*", "docs/*"]
''');
      write('packages/a/pubspec.yaml', 'name: a\nresolution: workspace\n');
      Directory(p.join(root.path, 'packages/empty')).createSync();
      write('tools/notes/README.md', 'not a package');
      write('tools/cli/pubspec.yaml', 'name: cli\nresolution: workspace\n');
      write('docs/site/index.md', 'not a package');
      final report = await run();
      expect(report.errors.map((d) => '${d.kind}: ${d.message}'), [
        'workspace: entry packages/empty has no pubspec.yaml',
        'workspace: entry docs/* matches no directory with a pubspec.yaml',
      ]);
    },
  );

  test('equivalent constraints are not drift', () async {
    write('pubspec.yaml', '''
name: root
environment: {sdk: ^3.10.0}
workspace: [packages/a, packages/b, packages/c]
''');
    write('packages/a/pubspec.yaml', '''
name: a
resolution: workspace
environment: {sdk: ">=3.10.0 <4.0.0"}
dependencies: {yaml: ^3.1.0, path: {path: ../../vendor/path}}
''');
    write('packages/b/pubspec.yaml', '''
name: b
resolution: workspace
environment: {sdk: ^3.10.0}
dependencies: {yaml: ">=3.1.0 <4.0.0", path: {path: ../../vendor/path}}
''');
    write('packages/c/pubspec.yaml', '''
name: c
resolution: workspace
environment: {sdk: ^3.10.0}
dependencies: {yaml: ">=3.1.0 <3.2.0"}
''');
    final report = await run();
    expect(report.warnings.where((d) => d.kind == 'sdk'), isEmpty);
    expect(
      report.warnings
          .where((d) => d.kind == 'dependencies')
          .map((d) => d.message),
      [
        'yaml is constrained differently: >=3.1.0 <3.2.0 (c); >=3.1.0 <4.0.0 = ^3.1.0 (a, b)',
      ],
    );
  });
}

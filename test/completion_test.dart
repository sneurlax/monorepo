import 'dart:io';

import 'package:monorepo/src/commands/runner.dart';
import 'package:monorepo/src/completion.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final runner = MonorepoRunner();

  test('every shell script names each command and option', () {
    for (final shell in ['bash', 'zsh', 'fish']) {
      final script = completionScript(shell, runner);
      for (final word in [
        'doctor',
        'graph',
        'completion',
        'plan',
        'reporter',
        'include-dependents',
        'verbose',
        'mermaid',
      ]) {
        expect(script, contains(word), reason: '$shell lacks $word');
      }
    }
  });

  test('zsh never shadows PATH and shifts words for subcommands', () {
    final script = completionScript('zsh', runner);
    expect(script, isNot(contains('local path')));
    expect(script, contains(r'words=("${(@)words[last,-1]}")'));
    expect(script, startsWith('#compdef monorepo\n'));
  });

  test('bash completes commands, subcommands and option values', () async {
    final temp = Directory.systemTemp.createTempSync('monorepo-completion-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File(p.join(temp.path, 'completion.bash'))
      ..writeAsStringSync(completionScript('bash', runner));
    Future<String> complete(String words) async {
      final result = await Process.run('bash', [
        '-c',
        'source "\$1"; COMP_WORDS=($words); '
            'COMP_CWORD=\$((\${#COMP_WORDS[@]} - 1)); _monorepo; '
            'echo "\${COMPREPLY[*]}"',
        'bash',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return (result.stdout as String).trim();
    }

    expect(await complete('monorepo pl'), 'plan');
    expect(await complete('monorepo plan te'), 'test');
    expect(await complete('monorepo plan test --li'), '--lines');
    expect(
      await complete('monorepo graph --format ""'),
      'text dot mermaid json',
    );
    expect(await complete('monorepo test --reporter j'), 'json');
    expect(await complete('monorepo completion z'), 'zsh');
    expect(await complete('monorepo test -- --na'), '');
  }, skip: Platform.isWindows);

  test('bash completes script names that contain a colon', () async {
    final temp = Directory.systemTemp.createTempSync('monorepo-completion-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File(p.join(temp.path, 'completion.bash'))
      ..writeAsStringSync(completionScript('bash', runner));
    // A stand-in for `monorepo run`, which lists scripts as name<TAB>text.
    final bin = Directory(p.join(temp.path, 'bin'))..createSync();
    final fake = File(p.join(bin.path, 'monorepo'))
      ..writeAsStringSync(
        '#!/bin/sh\nprintf "native:test\\tRun native tests\\nnative:build\\t\\nlint\\t\\n"\n',
      );
    await Process.run('chmod', ['+x', fake.path]);
    // Bash splits the line at COMP_WORDBREAKS, which includes the colon.
    Future<String> complete(String line, String words) async {
      final result = await Process.run(
        'bash',
        [
          '-c',
          'source "\$1"; COMP_LINE="\$2"; COMP_POINT=\${#COMP_LINE}; '
              'COMP_WORDS=(\$3); COMP_CWORD=\$((\${#COMP_WORDS[@]} - 1)); '
              '_monorepo; echo "\${COMPREPLY[*]}"',
          'bash',
          file.path,
          line,
          words,
        ],
        environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return (result.stdout as String).trim();
    }

    expect(
      await complete('monorepo run nat', 'monorepo run nat'),
      'native:test native:build',
    );
    expect(
      await complete('monorepo run native:', 'monorepo run native :'),
      'test build',
    );
    expect(
      await complete('monorepo run native:t', 'monorepo run native : t'),
      'test',
    );
    expect(
      await complete(
        'monorepo plan run native:b',
        'monorepo plan run native : b',
      ),
      'build',
    );
  }, skip: Platform.isWindows);

  test('zsh escapes colons in script names; fish needs no escaping', () {
    expect(
      completionScript('zsh', runner),
      contains(
        r'''cut -f1)"}//:/\\:}); _describe -t scripts script scripts; }''',
      ),
    );
    // fish candidates are whole lines; only a tab starts a description.
    expect(
      completionScript('fish', runner),
      contains(r"string replace -r '\t.*' ''"),
    );
  });
}

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

/// One completable command: `test`, or `plan test`.
class _Node {
  final List<String> path;
  final String description;
  final ArgParser parser;
  final List<_Node> children;
  const _Node(this.path, this.description, this.parser, this.children);
  String get key => path.join(' ');
}

List<_Node> _nodes(Map<String, Command<int>> commands, List<String> prefix) {
  final names = commands.keys.toSet().toList()..sort();
  return [
    for (final name in names)
      if (!commands[name]!.hidden && commands[name]!.name == name)
        _Node(
          [...prefix, name],
          commands[name]!.summary,
          commands[name]!.argParser,
          _nodes(commands[name]!.subcommands, [...prefix, name]),
        ),
  ];
}

Iterable<_Node> _flatten(List<_Node> nodes) sync* {
  for (final node in nodes) {
    yield node;
    yield* _flatten(node.children);
  }
}

/// How an option's value is completed.
String? _valueKind(Option option) {
  if (option.isFlag) return null;
  if (option.allowed != null) return 'choice';
  return switch (option.name) {
    'since' => 'ref',
    'scope' || 'ignore' => 'package',
    'dir-exists' || 'file-exists' => 'path',
    _ => 'value',
  };
}

List<String> _optionWords(ArgParser parser) => [
  for (final option in parser.options.values)
    if (!option.hide) ...[
      '--${option.name}',
      if (option.isFlag && option.negatable == true) '--no-${option.name}',
      if (option.abbr != null) '-${option.abbr}',
    ],
];

String _shellWords(Iterable<String> words) => words.join(' ');

/// Positional values a command completes: shells for `completion`, script
/// names for `run` and `plan run`.
String? _positional(_Node node) => switch (node.path.last) {
  'completion' => 'shell',
  'run' => 'script',
  _ => null,
};

const _shells = ['bash', 'zsh', 'fish'];

String completionScript(String shell, CommandRunner<int> runner) {
  final roots = _nodes(runner.commands, const []);
  final all = _flatten(roots).toList();
  return switch (shell) {
    'bash' => _bash(runner, roots, all),
    'zsh' => _zsh(runner, roots, all),
    'fish' => _fish(runner, roots, all),
    _ => throw ArgumentError.value(shell, 'shell'),
  };
}

const _helpers = r'''
_monorepo_refs() { git for-each-ref --format='%(refname:short)' refs/heads refs/tags refs/remotes 2>/dev/null; }
_monorepo_packages() { monorepo list 2>/dev/null | tail -n +2 | cut -f1; }
_monorepo_scripts() { monorepo run 2>/dev/null | grep -v '^ ' | grep "$(printf '\t')" | cut -f1; }
''';

String _bash(CommandRunner<int> runner, List<_Node> roots, List<_Node> all) {
  final buffer = StringBuffer()
    ..writeln('# bash completion for ${runner.executableName}.')
    ..writeln('# Load it with: source <(monorepo completion bash)')
    ..write(_helpers)
    ..writeln('_monorepo() {')
    ..writeln(r'  local cur="${COMP_WORDS[COMP_CWORD]}"')
    // COMP_WORDBREAKS splits a word such as native:test at the colon. Take
    // the whole word from the line; the reply is trimmed below, as
    // bash-completion's __ltrim_colon_completions does.
    ..writeln(r'  local whole="${COMP_LINE:0:${COMP_POINT:-${#COMP_LINE}}}"')
    ..writeln(r'  whole="${whole##*[[:space:]]}"')
    ..writeln(r'  [[ "$whole" == *:* ]] && cur="$whole"')
    ..writeln(r'  local prev="${COMP_WORDS[COMP_CWORD-1]}"')
    ..writeln('  local cmd="" i word')
    ..writeln(r'  for ((i = 1; i < COMP_CWORD; i++)); do')
    ..writeln(r'    word="${COMP_WORDS[i]}"')
    ..writeln(r'    [[ "$word" == -- ]] && return 0')
    ..writeln(r'    case "$cmd:$word" in');
  for (final node in all) {
    final parent = node.path.take(node.path.length - 1).join(' ');
    buffer.writeln('      "$parent:${node.path.last}") cmd="${node.key}" ;;');
  }
  buffer
    ..writeln('    esac')
    ..writeln('  done')
    ..writeln(r'  case "$prev" in');
  final values = <String, String>{};
  for (final node in all) {
    for (final option in node.parser.options.values) {
      final kind = _valueKind(option);
      if (kind == null) continue;
      final action = switch (kind) {
        'choice' =>
          'COMPREPLY=(\$(compgen -W "${_shellWords(option.allowed!)}" -- "\$cur")); return 0',
        'ref' =>
          r'COMPREPLY=($(compgen -W "$(_monorepo_refs)" -- "$cur")); return 0',
        'package' =>
          r'COMPREPLY=($(compgen -W "$(_monorepo_packages)" -- "$cur")); return 0',
        'path' => r'COMPREPLY=($(compgen -f -- "$cur")); return 0',
        _ => 'return 0',
      };
      for (final spelling in [
        '--${option.name}',
        if (option.abbr != null) '-${option.abbr}',
      ]) {
        values.putIfAbsent(spelling, () => action);
      }
    }
  }
  for (final entry in values.entries) {
    buffer.writeln('    ${entry.key}) ${entry.value} ;;');
  }
  buffer
    ..writeln('  esac')
    ..writeln('  local words')
    ..writeln(r'  case "$cmd" in')
    ..writeln(
      '    "") words="${_shellWords([...roots.map((n) => n.path.last), ..._optionWords(runner.argParser)])}" ;;',
    );
  for (final node in all) {
    final positional = _positional(node);
    final extra = positional == 'script'
        ? r' $(_monorepo_scripts)'
        : positional == 'shell'
        ? ' ${_shellWords(_shells)}'
        : '';
    buffer.writeln(
      '    "${node.key}") words="${_shellWords([...node.children.map((n) => n.path.last), ..._optionWords(node.parser)])}$extra" ;;',
    );
  }
  buffer
    ..writeln('  esac')
    ..writeln(r'  COMPREPLY=($(compgen -W "$words" -- "$cur"))')
    ..writeln(
      r'  if [[ "$cur" == *:* && "${COMP_WORDBREAKS-:}" == *:* ]]; then',
    )
    ..writeln(r'    local colon="${cur%"${cur##*:}"}"')
    ..writeln(r'    COMPREPLY=("${COMPREPLY[@]#"$colon"}")')
    ..writeln('  fi')
    ..writeln('}')
    ..write('complete -o default -F _monorepo ${runner.executableName}');
  return buffer.toString();
}

String _zshQuote(String text) => "'${text.replaceAll("'", r"'\''")}'";

String _zshHelp(String? help) => (help ?? '')
    .split('\n')
    .first
    .replaceAll(r'\', r'\\')
    .replaceAll('[', r'\[')
    .replaceAll(']', r'\]')
    .replaceAll(':', r'\:');

String _zsh(CommandRunner<int> runner, List<_Node> roots, List<_Node> all) {
  List<String> specs(_Node? node) {
    final parser = node?.parser ?? runner.argParser;
    final result = <String>[];
    for (final option in parser.options.values) {
      if (option.hide) continue;
      final help = _zshHelp(option.help);
      final kind = _valueKind(option);
      final action = switch (kind) {
        null => '',
        'choice' =>
          ':${option.valueHelp ?? option.name}:(${option.allowed!.join(' ')})',
        'ref' => ':git ref:_monorepo_refs',
        'package' => ':package:_monorepo_packages',
        'path' => ':path:_files',
        _ => ':${option.valueHelp ?? option.name}: ',
      };
      final repeat = option.isMultiple ? '*' : '';
      final equals = kind == null ? '' : '=';
      result.add(_zshQuote('$repeat--${option.name}$equals[$help]$action'));
      if (option.isFlag && option.negatable == true) {
        result.add(_zshQuote('--no-${option.name}[$help]'));
      }
      if (option.abbr != null) {
        result.add(_zshQuote('$repeat-${option.abbr}[$help]$action'));
      }
    }
    if (node != null) {
      final positional = _positional(node);
      if (positional == 'script') {
        result.add(_zshQuote('1:script:_monorepo_scripts'));
      } else if (positional == 'shell') {
        result.add(_zshQuote('1:shell:(${_shells.join(' ')})'));
      }
    }
    return result;
  }

  String describe(List<_Node> nodes) => [
    for (final node in nodes)
      _zshQuote('${node.path.last}:${node.description.replaceAll(':', r'\:')}'),
  ].join(' ');

  final buffer = StringBuffer()
    ..writeln('#compdef ${runner.executableName}')
    ..writeln('# zsh completion for ${runner.executableName}.')
    ..writeln(
      '# Load it with: source <(monorepo completion zsh), or save it as _monorepo on your fpath.',
    )
    ..writeln(
      r'''_monorepo_refs() { local -a refs; refs=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads refs/tags refs/remotes 2>/dev/null)"}); _describe -t refs 'git ref' refs; }''',
    )
    ..writeln(
      r'_monorepo_packages() { local -a packages; packages=(${(f)"$(monorepo list 2>/dev/null | tail -n +2 | cut -f1)"}); _describe -t packages package packages; }',
    )
    ..writeln(
      // _describe splits items at the first colon, so names escape theirs.
      r'''_monorepo_scripts() { local -a scripts; scripts=(${${(f)"$(monorepo run 2>/dev/null | grep -v '^ ' | grep "$(printf '\t')" | cut -f1)"}//:/\\:}); _describe -t scripts script scripts; }''',
    )
    ..writeln('_monorepo() {')
    // `path` is tied to PATH in zsh, so the command path is `cmd`.
    ..writeln('  local cmd="" i last=1')
    ..writeln(r'  for ((i = 2; i < CURRENT; i++)); do')
    ..writeln(r'    [[ "$words[i]" == -- ]] && { _default; return; }')
    ..writeln(r'    case "$cmd:$words[i]" in');
  for (final node in all) {
    final parent = node.path.take(node.path.length - 1).join(' ');
    buffer.writeln(
      '      "$parent:${node.path.last}") cmd="${node.key}"; last=\$i ;;',
    );
  }
  buffer
    ..writeln('    esac')
    ..writeln('  done')
    // _arguments must see the innermost command as words[1].
    ..writeln(r'  words=("${(@)words[last,-1]}"); (( CURRENT -= last - 1 ))')
    ..writeln(r'  case "$cmd" in')
    ..writeln('    "")')
    ..writeln('      local -a commands; commands=(${describe(roots)})')
    ..writeln(
      '      _arguments ${specs(null).join(' ')} \'1:command:->command\' && return',
    )
    ..writeln(r"      _describe -t commands 'monorepo command' commands ;;");
  for (final node in all) {
    buffer.writeln('    "${node.key}")');
    if (node.children.isNotEmpty) {
      buffer
        ..writeln(
          '      local -a commands; commands=(${describe(node.children)})',
        )
        ..writeln(
          '      _arguments ${specs(node).join(' ')} \'1:command:->command\' && return',
        )
        ..writeln(r"      _describe -t commands 'subcommand' commands ;;");
    } else {
      buffer.writeln('      _arguments ${specs(node).join(' ')} ;;');
    }
  }
  buffer
    ..writeln('  esac')
    ..writeln('}')
    ..write(
      'if [[ "\${zsh_eval_context[-1]}" == loadautofunc ]]; then _monorepo "\$@"; else compdef _monorepo ${runner.executableName}; fi',
    );
  return buffer.toString();
}

String _fishQuote(String text) =>
    "'${text.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

String _fish(CommandRunner<int> runner, List<_Node> roots, List<_Node> all) {
  final exe = runner.executableName;
  final buffer = StringBuffer()
    ..writeln('# fish completion for $exe.')
    ..writeln(
      '# Load it with: monorepo completion fish | source, or save it in ~/.config/fish/completions/$exe.fish.',
    )
    ..writeln(
      "function __monorepo_refs; git for-each-ref --format='%(refname:short)' refs/heads refs/tags refs/remotes 2>/dev/null; end",
    )
    ..writeln(
      'function __monorepo_packages; monorepo list 2>/dev/null | tail -n +2 | cut -f1; end',
    )
    ..writeln(
      r"function __monorepo_scripts; monorepo run 2>/dev/null | string match -rv '^ ' | string match -r '^[^\t]+\t' | string replace -r '\t.*' ''; end",
    )
    // The command path, ignoring option values, up to the cursor.
    ..writeln('function __monorepo_path')
    ..writeln('  set -l cmd')
    ..writeln('  for word in (commandline -opc)[2..-1]')
    ..writeln("    test \"\$word\" = '--'; and echo '--'; and return")
    ..writeln('    switch "\$cmd:\$word"');
  for (final node in all) {
    final parent = node.path.take(node.path.length - 1).join(' ');
    buffer.writeln("      case '$parent:${node.path.last}'");
    buffer.writeln("        set cmd '${node.key}'");
  }
  buffer
    ..writeln('    end')
    ..writeln('  end')
    ..writeln(r'  echo "$cmd"')
    ..writeln('end')
    ..writeln('function __monorepo_at; test (__monorepo_path) = "\$argv"; end')
    ..writeln('complete -c $exe -f');
  void options(String condition, ArgParser parser) {
    for (final option in parser.options.values) {
      if (option.hide) continue;
      final parts = ['complete -c $exe -n $condition -l ${option.name}'];
      if (option.abbr != null) parts.add('-s ${option.abbr}');
      final kind = _valueKind(option);
      switch (kind) {
        case 'choice':
          parts.add('-xa ${_fishQuote(option.allowed!.join(' '))}');
        case 'ref':
          parts.add("-xa '(__monorepo_refs)'");
        case 'package':
          parts.add("-xa '(__monorepo_packages)'");
        case 'path':
          parts.add('-rF');
        case 'value':
          parts.add('-x');
      }
      if ((option.help ?? '').isNotEmpty) {
        parts.add('-d ${_fishQuote(option.help!.split('\n').first)}');
      }
      buffer.writeln(parts.join(' '));
      if (option.isFlag && option.negatable == true) {
        buffer.writeln(
          'complete -c $exe -n $condition -l no-${option.name}${(option.help ?? '').isEmpty ? '' : ' -d ${_fishQuote(option.help!.split('\n').first)}'}',
        );
      }
    }
  }

  options("'__monorepo_at \"\"'", runner.argParser);
  for (final node in roots) {
    buffer.writeln(
      "complete -c $exe -n '__monorepo_at \"\"' -a ${node.path.last} -d ${_fishQuote(node.description)}",
    );
  }
  for (final node in all) {
    final condition = "'__monorepo_at \"${node.key}\"'";
    for (final child in node.children) {
      buffer.writeln(
        'complete -c $exe -n $condition -a ${child.path.last} -d ${_fishQuote(child.description)}',
      );
    }
    switch (_positional(node)) {
      case 'script':
        buffer.writeln(
          "complete -c $exe -n $condition -a '(__monorepo_scripts)'",
        );
      case 'shell':
        buffer.writeln(
          'complete -c $exe -n $condition -a ${_fishQuote(_shells.join(' '))}',
        );
    }
    options(condition, node.parser);
  }
  return buffer.toString().trimRight();
}

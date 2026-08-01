import 'package:path/path.dart' as p;

/// A statically recognized command. [cwd] is relative to the workspace root.
class ShellCommand {
  final List<String> argv;
  final String cwd;
  final int line;
  final String? warning;
  const ShellCommand(this.argv, this.cwd, this.line, {this.warning});
}

class _Token {
  final String text;
  final int line;
  final bool operator;
  const _Token(this.text, this.line, [this.operator = false]);
  _Token expand(String variable, String value) => _Token(
    text
        .replaceAll('\${$variable}', value)
        .replaceAllMapped(
          RegExp('\\\$$variable(?![A-Za-z0-9_])'),
          (_) => value,
        ),
    line,
    operator,
  );
}

/// Tokenizes the deliberately limited shell subset in the public check contract.
/// It does not evaluate substitutions, environment variables, or executables.
List<ShellCommand> parseShell(String script, {String cwd = '.', int line = 1}) {
  final result = <ShellCommand>[];
  final tokens = _tokenize(_withoutHeredocs(script), line);
  _parse(tokens, cwd, result);
  return result;
}

String _parse(
  List<_Token> tokens,
  String initialDirectory,
  List<ShellCommand> result,
) {
  var cwd = initialDirectory;
  var index = 0;
  while (index < tokens.length) {
    final token = tokens[index];
    if (token.operator) {
      if (token.text == '(') {
        var depth = 1;
        var end = index + 1;
        while (end < tokens.length && depth != 0) {
          if (tokens[end].operator && tokens[end].text == '(') depth++;
          if (tokens[end].operator && tokens[end].text == ')') depth--;
          end++;
        }
        if (depth != 0) {
          result.add(
            ShellCommand(
              [],
              cwd,
              token.line,
              warning: 'Unclosed shell subshell',
            ),
          );
          break;
        }
        _parse(tokens.sublist(index + 1, end - 1), cwd, result);
        index = end;
      } else {
        index++;
      }
      continue;
    }
    if (token.text == 'for') {
      final doIndex = tokens.indexWhere((t) => t.text == 'do', index + 1);
      var end = doIndex < 0 ? -1 : doIndex + 1;
      var depth = 1;
      var nested = false;
      while (end >= 0 && end < tokens.length) {
        if (tokens[end].text == 'for') {
          depth++;
          nested = true;
        }
        if (tokens[end].text == 'done') {
          depth--;
          if (depth == 0) break;
        }
        end++;
      }
      final validBounds =
          doIndex >= index + 4 && end >= 0 && end < tokens.length;
      final words = validBounds
          ? tokens
                .sublist(index + 3, doIndex)
                .where((t) => !t.operator)
                .toList()
          : <_Token>[];
      if (!validBounds ||
          nested ||
          tokens[index + 2].text != 'in' ||
          words.any((t) => RegExp(r'[$*?\[\]]').hasMatch(t.text))) {
        result.add(
          ShellCommand(
            [],
            cwd,
            token.line,
            warning: 'Unsupported shell loop; coverage is not inferred',
          ),
        );
      } else {
        final variable = tokens[index + 1].text;
        for (final word in words) {
          final body = tokens
              .sublist(doIndex + 1, end)
              .map((t) => t.expand(variable, word.text))
              .toList();
          cwd = _parse(body, cwd, result);
        }
      }
      index = validBounds ? end + 1 : tokens.length;
      continue;
    }
    var end = index;
    while (end < tokens.length && !tokens[end].operator) {
      end++;
    }
    var argv = tokens.sublist(index, end).map((t) => t.text).toList();
    while (argv.isNotEmpty &&
        {'then', 'else', 'do', '!', '{'}.contains(argv.first)) {
      argv = argv.sublist(1);
    }
    if (argv.isNotEmpty && !{'fi', 'done', '}'}.contains(argv.first)) {
      argv = stripPrefixes(argv);
      if (argv.isNotEmpty) {
        if ({'sh', 'bash'}.contains(argv.first) && argv.contains('-c')) {
          final commandIndex = argv.indexOf('-c') + 1;
          if (commandIndex < argv.length) {
            result.addAll(
              parseShell(argv[commandIndex], cwd: cwd, line: token.line),
            );
          } else {
            result.add(
              ShellCommand(
                [],
                cwd,
                token.line,
                warning: 'Missing shell -c body',
              ),
            );
          }
          index = end;
          continue;
        }
        result.add(ShellCommand(argv, cwd, token.line));
        if (argv.first == 'cd') {
          final target = argv.length > 1 && argv[1] == '--'
              ? (argv.length > 2 ? argv[2] : r'$HOME')
              : (argv.length > 1 ? argv[1] : r'$HOME');
          cwd = p.posix.normalize(p.posix.join(cwd, target));
        }
      }
    }
    index = end;
  }
  return cwd;
}

/// Removes wrappers without interpreting assignment values as path arguments.
List<String> stripPrefixes(List<String> input) {
  var words = input;
  while (words.isNotEmpty) {
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words.first)) {
      words = words.sublist(1);
    } else if (words.first == 'env') {
      var i = 1;
      while (i < words.length && words[i].startsWith('-')) {
        if ({'-u', '--unset', '-C', '--chdir'}.contains(words[i])) i++;
        i++;
      }
      words = words.sublist(i.clamp(0, words.length));
    } else if (words.first == 'timeout') {
      var i = 1;
      while (i < words.length && words[i].startsWith('-')) {
        if ({'-s', '--signal', '-k', '--kill-after'}.contains(words[i])) i++;
        i++;
      }
      if (i < words.length) i++; // Duration.
      words = words.sublist(i.clamp(0, words.length));
    } else if (words.first == 'xvfb-run') {
      var i = 1;
      while (i < words.length &&
          {'-a', '--auto-servernum'}.contains(words[i])) {
        i++;
      }
      words = words.sublist(i);
    } else if (words.length >= 4 &&
        words.take(4).join(' ') == 'dart pub global run') {
      words = words.sublist(4);
    } else if (words.length >= 3 &&
        words.take(3).join(' ') == 'dart run melos') {
      words = words.sublist(2);
    } else {
      break;
    }
  }
  return words;
}

List<_Token> _tokenize(String source, int initialLine) {
  final tokens = <_Token>[];
  var buffer = StringBuffer();
  var line = initialLine;
  var tokenLine = line;
  String? quote;
  var wordStarted = false;
  var substitutionDepth = 0;
  void flush() {
    if (wordStarted) tokens.add(_Token(buffer.toString(), tokenLine));
    buffer = StringBuffer();
    wordStarted = false;
  }

  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (!wordStarted) tokenLine = line;
    if (char == '\n') line++;
    if (char == '\\' && quote != "'" && i + 1 < source.length) {
      if (source[i + 1] == '\n') {
        i++;
        line++;
      } else {
        buffer.write(source[++i]);
        wordStarted = true;
      }
      continue;
    }
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(char);
      }
      wordStarted = true;
      continue;
    }
    if (substitutionDepth > 0) {
      buffer.write(char);
      if (char == '(') substitutionDepth++;
      if (char == ')') substitutionDepth--;
      continue;
    }
    if (char == r'$' && i + 1 < source.length && source[i + 1] == '(') {
      buffer.write(r'$(');
      i++;
      substitutionDepth = 1;
      wordStarted = true;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      wordStarted = true;
      continue;
    }
    if (char == '#' && !wordStarted) {
      while (i + 1 < source.length && source[i + 1] != '\n') {
        i++;
      }
      continue;
    }
    if (char == '<' || char == '>') {
      if (wordStarted && RegExp(r'^\d+$').hasMatch(buffer.toString())) {
        buffer = StringBuffer();
        wordStarted = false;
      } else {
        flush();
      }
      if (char == '<' &&
          i + 2 < source.length &&
          source[i + 1] == '<' &&
          (source[i + 2] == '<' || source[i + 2] == '-')) {
        i += 2;
      } else if (i + 1 < source.length &&
          ((char == '<' && '<&>'.contains(source[i + 1])) ||
              (char == '>' && '>&|'.contains(source[i + 1])))) {
        i++;
      }
      while (i + 1 < source.length &&
          (source[i + 1] == ' ' || source[i + 1] == '\t')) {
        i++;
      }
      String? redirQuote;
      var redirSub = 0;
      while (i + 1 < source.length) {
        final next = source[i + 1];
        if (next == '\\' && redirQuote != "'" && i + 2 < source.length) {
          if (source[i + 2] == '\n') line++;
          i += 2;
          continue;
        }
        if (redirQuote != null) {
          if (next == '\n') line++;
          if (next == redirQuote) redirQuote = null;
          i++;
          continue;
        }
        if (redirSub > 0) {
          if (next == '\n') line++;
          if (next == '(') redirSub++;
          if (next == ')') redirSub--;
          i++;
          continue;
        }
        if (next == r'$' && i + 2 < source.length && source[i + 2] == '(') {
          redirSub = 1;
          i += 2;
          continue;
        }
        if (next == '"' || next == "'") {
          redirQuote = next;
          i++;
          continue;
        }
        if (next == '\n' || next.trim().isEmpty || ';()|&<>'.contains(next)) {
          break;
        }
        i++;
      }
      if (redirQuote != null || redirSub != 0) {
        tokens.add(_Token('__MONOREPO_UNPARSED_QUOTE__', line));
      }
      continue;
    }
    if (char == '\n' || ';()|&'.contains(char)) {
      flush();
      var operator = char;
      if (i + 1 < source.length &&
          source[i + 1] == char &&
          '|&'.contains(char)) {
        operator += source[++i];
      }
      tokens.add(_Token(operator, char == '\n' ? line - 1 : line, true));
    } else if (char.trim().isEmpty) {
      flush();
    } else {
      wordStarted = true;
      buffer.write(char);
    }
  }
  flush();
  if (quote != null || substitutionDepth != 0) {
    tokens.add(_Token('__MONOREPO_UNPARSED_QUOTE__', line));
  }
  return tokens;
}

String _withoutHeredocs(String script) {
  final lines = script.split('\n');
  String? delimiter;
  for (var i = 0; i < lines.length; i++) {
    if (delimiter != null) {
      final last = lines[i].trim() == delimiter;
      lines[i] = '';
      if (last) delimiter = null;
    } else {
      final match = RegExp(
        r'''(?<!<)<<(?!<)-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?''',
      ).firstMatch(lines[i]);
      if (match != null) {
        delimiter = match.group(1);
        lines[i] = lines[i].replaceRange(match.start, match.end, '');
      }
    }
  }
  return lines.join('\n');
}

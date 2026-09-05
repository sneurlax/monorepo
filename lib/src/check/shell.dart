import 'package:path/path.dart' as p;

/// Placeholder for `${{ github.workspace }}` and `$GITHUB_WORKSPACE`. It never
/// reaches the filesystem; [rebasePath] maps it back to workspace paths.
const workspaceMarker = '/__monorepo_workspace__';

/// Placeholder for CI locations outside the checkout, such as `runner.temp`.
const externalMarker = '/__monorepo_external__';

bool isExternal(String path) =>
    path == externalMarker || path.startsWith('$externalMarker/');

final _windowsAbsolute = RegExp(r'^[A-Za-z]:[/\\]');

/// Maps a path to a root-relative path when it lies inside the checkout at
/// [root], and to an [externalMarker] path otherwise. Relative paths resolve
/// against [root]. Elsewhere in the CI workspace, CI-created locations, host
/// absolute paths, and paths escaping the workspace are all external, so the
/// result never depends on the machine running the check.
String rebasePath(String path, {String root = workspaceMarker}) {
  final normalized = path.replaceAll('\\', '/');
  if (_windowsAbsolute.hasMatch(normalized)) return '$externalMarker/host';
  final absolute = p.posix.normalize(
    p.posix.isAbsolute(normalized)
        ? normalized
        : p.posix.join(root, normalized),
  );
  if (absolute == root) return '.';
  if (p.posix.isWithin(root, absolute)) {
    return p.posix.relative(absolute, from: root);
  }
  if (isExternal(absolute)) return absolute;
  if (absolute == workspaceMarker ||
      p.posix.isWithin(workspaceMarker, absolute)) {
    return p.posix.normalize(
      p.posix.join(
        externalMarker,
        'workspace',
        p.posix.relative(absolute, from: workspaceMarker),
      ),
    );
  }
  return p.posix.normalize('$externalMarker/host$absolute');
}

/// Joins [target] onto the absolute [location] the way `cd` does. A dynamic
/// part keeps the result dynamic: `$X/..` is not folded away, since `$X` may
/// hold several segments.
String joinLocation(String location, String target) {
  final path = target.replaceAll('\\', '/');
  if (_windowsAbsolute.hasMatch(path)) return '$externalMarker/host';
  if (p.posix.isAbsolute(path)) {
    return path.contains(r'$') ? path : p.posix.normalize(path);
  }
  if (location.contains(r'$') || path.contains(r'$')) {
    return path.isEmpty ? location : '$location/$path';
  }
  return p.posix.normalize(p.posix.join(location, path));
}

/// A statically recognized command. [cwd] is relative to the workspace root,
/// or an [externalMarker] path for commands that run outside the checkout.
/// [location] is the same directory as an absolute marker path, which keeps
/// paths relative to it resolvable when it lies outside the checkout.
/// An [uncertainReason] means the command may not run, so it never
/// establishes coverage.
class ShellCommand {
  final List<String> argv;
  final String cwd;
  final String location;
  final int line;
  final String? warning;
  final String? uncertainReason;
  const ShellCommand(
    this.argv,
    this.cwd,
    this.line, {
    this.warning,
    this.uncertainReason,
    String? location,
  }) : location = location ?? cwd;

  bool get uncertain => uncertainReason != null;
}

// Single-quoted dollars are literal; this private-use character keeps loop and
// environment expansion away from them until the command is emitted.
const _literalDollar = '';

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
/// It does not evaluate substitutions or executables. [environment] holds
/// variables whose values are statically known; plain `$NAME` and `${NAME}`
/// references to them are expanded unless the script assigns the name itself.
/// [cwd] is relative to [root], or absolute; [root] locates the checkout.
List<ShellCommand> parseShell(
  String script, {
  String cwd = '.',
  int line = 1,
  Map<String, String> environment = const {},
  String root = workspaceMarker,
}) {
  final result = <ShellCommand>[];
  final source = substituteVariables(_withoutHeredocs(script), environment);
  final tokens = _tokenize(source, line);
  final parser = _Parser(root, environment, result);
  final scope = _Scope(
    p.posix.isAbsolute(cwd) ? cwd : joinLocation(root, cwd),
    stack: [],
  );
  parser.parse(tokens, scope, null);
  parser.finish();
  return result;
}

final _safeValue = RegExp(r'^[A-Za-z0-9_./:=+,@%\- ]*$');

/// Replaces `$NAME` and `${NAME}` outside single quotes when [environment]
/// knows NAME, the script never assigns it, and its value cannot change how
/// the surrounding shell text is parsed.
String substituteVariables(String script, Map<String, String> environment) {
  if (environment.isEmpty ||
      RegExp(
        r'(?:^|[;&|(\n]\s*)(?:eval|source|\.)\s+[^\s;&|]',
      ).hasMatch(script) ||
      // A nameref can assign any variable through another name.
      RegExp(
        r'(?:^|[\s;&|(!{])(?:declare|typeset|local)\s+(?:[-+]\w+\s+)*[-+][A-Za-z]*n',
      ).hasMatch(script)) {
    return script;
  }
  final assigned = assignedNames(script);
  String? value(String name) {
    if (assigned.contains(name)) return null;
    final known = environment[name];
    return known != null && _safeValue.hasMatch(known) ? known : null;
  }

  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < script.length; i++) {
    final char = script[i];
    if (char == '\\' && quote != "'" && i + 1 < script.length) {
      out
        ..write(char)
        ..write(script[++i]);
      continue;
    }
    if (quote == "'") {
      out.write(char);
      if (char == "'") quote = null;
      continue;
    }
    if (char == '#' &&
        quote == null &&
        (i == 0 || RegExp(r'[\s;&|()]').hasMatch(script[i - 1]))) {
      final end = script.indexOf('\n', i);
      out.write(script.substring(i, end < 0 ? script.length : end));
      i = (end < 0 ? script.length : end) - 1;
      continue;
    }
    if (char == "'" && quote == null) quote = "'";
    if (char == '"') quote = quote == '"' ? null : '"';
    if (char == r'$') {
      final match = RegExp(
        r'\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*)',
      ).matchAsPrefix(script, i + 1);
      final replacement = match == null
          ? null
          : value(match.group(1) ?? match.group(2)!);
      if (replacement != null) {
        out.write(replacement);
        i = match!.end - 1;
        continue;
      }
    }
    out.write(char);
  }
  return out.toString();
}

final _identifier = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');

/// Names a script may assign or unset. This is a deliberate superset: plain
/// and command-scoped assignments, loop variables, every identifier-like
/// argument of the builtins that assign or unset (`declare`, `typeset`,
/// `local`, `export`, `readonly`, `unset`, `let`, `read`, `getopts`,
/// `mapfile`, `readarray`), `printf -v` targets, `${NAME:=value}` defaults,
/// and identifiers inside arithmetic `(( ))`.
Set<String> assignedNames(String script) {
  final names = <String>{};
  for (final match in RegExp(
    r'(?:^|[\s;&|(!{])([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\+?=',
  ).allMatches(script)) {
    names.add(match.group(1)!);
  }
  for (final match in RegExp(
    r'(?:^|[\s;&|(])(?:for|select)\s+([A-Za-z_][A-Za-z0-9_]*)',
  ).allMatches(script)) {
    names.add(match.group(1)!);
  }
  for (final match in RegExp(
    r'(?:^|[\s;&|(!{])(?:declare|typeset|local|export|readonly|unset|let|read|getopts|mapfile|readarray)\b([^;&|\n]*)',
  ).allMatches(script)) {
    for (final word in match.group(1)!.trim().split(RegExp(r'\s+'))) {
      final name = _identifier.firstMatch(word);
      if (name != null) names.add(name.group(0)!);
    }
  }
  for (final match in RegExp(
    r'''(?:^|[\s;&|(!{])printf\s+(?:\S+\s+)*?-v\s*["']?([A-Za-z_][A-Za-z0-9_]*)''',
  ).allMatches(script)) {
    names.add(match.group(1)!);
  }
  for (final match in RegExp(
    r'\$\{([A-Za-z_][A-Za-z0-9_]*):?[=?]',
  ).allMatches(script)) {
    names.add(match.group(1)!);
  }
  for (final match in RegExp(r'\(\(([^)]*)\)\)').allMatches(script)) {
    names.addAll(_identifier.allMatches(match.group(1)!).map((m) => m[0]!));
  }
  return names;
}

// A dollar left after expansion makes a path or command dynamic. Unresolved
// loop iterations and cwd changes inside them use this value.
const _unknownDirectory = r'$(unresolved directory)';

const _loopKeywords = {'for', 'while', 'until', 'select'};
const _reservedWords = {
  ..._loopKeywords,
  'if',
  'then',
  'elif',
  'else',
  'fi',
  'do',
  'done',
  'case',
  'esac',
  'in',
  'function',
  '{',
  '}',
  '!',
  'time',
};

const _prefixWords = {'then', 'else', 'elif', 'do', '!', '{'};

const _loopReason = 'inside a loop over a dynamic list';
const _skipReason = 'after a break, continue, return or exit that may skip it';
const _uncalledReason = 'inside a shell function that is never called';

/// How a construct leaves the code after it: [none] falls through; the others
/// skip the rest of the loop iteration, loop, function, or shell.
enum _Stop { none, continueLoop, breakLoop, returnFunction, exitShell }

_Stop _max(_Stop a, _Stop b) => a.index >= b.index ? a : b;

/// The shell's directory state: an absolute marker path (or a dynamic one),
/// `OLDPWD` for `cd -`, and the `pushd` stack. A null [stack] or [oldpwd] is
/// unknown.
class _Scope {
  String cwd;
  String? oldpwd;
  List<String>? stack;
  _Scope(this.cwd, {this.oldpwd, this.stack});

  _Scope copy() =>
      _Scope(cwd, oldpwd: oldpwd, stack: stack == null ? null : [...stack!]);

  bool _sameStack(_Scope other) => stack == null
      ? other.stack == null
      : other.stack != null && stack!.join('\n') == other.stack!.join('\n');

  bool same(_Scope other) =>
      cwd == other.cwd && oldpwd == other.oldpwd && _sameStack(other);

  /// Joins a path that may or may not have run: whatever differs between
  /// this state and [other] becomes unknown.
  void merge(_Scope other) {
    if (cwd != other.cwd) cwd = _unknownDirectory;
    if (oldpwd != other.oldpwd) oldpwd = null;
    if (!_sameStack(other)) stack = null;
  }

  void forget() {
    cwd = _unknownDirectory;
    oldpwd = null;
    stack = null;
  }
}

class _Function {
  final List<_Token> body;
  final bool subshell;
  final _Scope defined;
  bool visited = false;
  _Function(this.body, this.subshell, this.defined);
}

class _Parser {
  final String root;
  final Map<String, String> environment;
  final List<ShellCommand> result;
  final functions = <String, _Function>{};
  final calling = <String>{};
  _Parser(this.root, this.environment, this.result);

  String _relative(String location) =>
      location.contains(r'$') ? location : rebasePath(location, root: root);

  void add(List<String> argv, String location, int line, String? reason) {
    result.add(
      ShellCommand(
        argv.map((word) => word.replaceAll(_literalDollar, r'$')).toList(),
        _relative(location),
        line,
        uncertainReason: reason,
        location: location,
      ),
    );
  }

  void warn(String message, _Scope scope, int line) => result.add(
    ShellCommand(
      [],
      _relative(scope.cwd),
      line,
      warning: message,
      location: scope.cwd,
    ),
  );

  /// Parses function bodies nothing called, so their paths are still checked
  /// while their commands never count as coverage.
  void finish() {
    while (true) {
      final pending = functions.values.where((f) => !f.visited).toList();
      if (pending.isEmpty) return;
      for (final function in pending) {
        function.visited = true;
        parse(function.body, function.defined.copy(), _uncalledReason);
      }
    }
  }

  /// Index of the `done` that closes a loop body starting after [doIndex].
  int closing(List<_Token> tokens, int doIndex) {
    var depth = 1;
    for (var i = doIndex + 1; i < tokens.length; i++) {
      if (!_commandStart(tokens, i)) continue;
      if (_loopKeywords.contains(tokens[i].text)) depth++;
      if (tokens[i].text == 'done' && --depth == 0) return i;
    }
    return -1;
  }

  /// Index of the [close] word matching an [open] word just before [from].
  int matching(List<_Token> tokens, int from, String open, String close) {
    var depth = 1;
    for (var i = from; i < tokens.length; i++) {
      if (tokens[i].operator || !_commandStart(tokens, i)) continue;
      if (tokens[i].text == open) depth++;
      if (tokens[i].text == close && --depth == 0) return i;
    }
    return -1;
  }

  /// Index of the `)` matching the `(` at [open].
  int closeParen(List<_Token> tokens, int open) {
    var depth = 0;
    for (var i = open; i < tokens.length; i++) {
      if (!tokens[i].operator) continue;
      if (tokens[i].text == '(') depth++;
      if (tokens[i].text == ')' && --depth == 0) return i;
    }
    return -1;
  }

  int keyword(List<_Token> tokens, String word, int from) {
    for (var i = from; i < tokens.length; i++) {
      if (tokens[i].text == word && _commandStart(tokens, i)) return i;
    }
    return -1;
  }

  /// Parses [tokens] in [scope], mutating it as the shell would. A non-null
  /// [reason] marks every command as possibly not running.
  _Stop parse(List<_Token> tokens, _Scope scope, String? reason) {
    var stop = _Stop.none;
    var index = 0;
    // State of the current and-or list (commands joined by && and ||).
    var listStart = scope.copy();
    var conditional = false;
    var onlyDirectories = true;
    String? previous;
    void endList() {
      // A directory change that ran only when an earlier command succeeded
      // or failed leaves the directory after the list unknown.
      if (conditional) scope.merge(listStart);
      listStart = scope.copy();
      conditional = false;
      onlyDirectories = true;
      previous = null;
    }

    while (index < tokens.length) {
      final token = tokens[index];
      if (token.operator && token.text != '(') {
        if ({'&&', '||', '|'}.contains(token.text)) {
          previous = token.text;
        } else {
          endList();
        }
        index++;
        continue;
      }
      // NAME=( ... ) is a bash array literal, never a subshell.
      if (token.operator &&
          index > 0 &&
          !tokens[index - 1].operator &&
          RegExp(
            r'^[A-Za-z_][A-Za-z0-9_]*\+?=$',
          ).hasMatch(tokens[index - 1].text)) {
        final end = closeParen(tokens, index);
        if (end < 0) {
          warn('Unclosed shell array', scope, token.line);
          break;
        }
        index = end + 1;
        continue;
      }
      final end = _elementEnd(tokens, index, scope);
      if (end < 0) break;
      final next = end < tokens.length && tokens[end].operator
          ? tokens[end].text
          : null;
      // Pipeline members and background commands run in subshells.
      final isolated = previous == '|' || next == '|' || next == '&';
      final alternative = previous == '||';
      final before = scope.copy();
      // After ||, the command runs only when the left side failed, so it is
      // an alternative branch with its own copy of the directory state.
      final target = isolated || alternative ? scope.copy() : scope;
      if (alternative && !scope.same(listStart)) target.forget();
      final start = target.copy();
      final effect = _element(
        tokens.sublist(index, end),
        target,
        stop == _Stop.none ? reason : reason ?? _skipReason,
        previous,
      );
      if (!isolated) {
        if (effect.stop != _Stop.none) stop = _max(stop, effect.stop);
        if (alternative && !target.same(start)) {
          scope.merge(target);
        } else if (!scope.same(before) &&
            previous == '&&' &&
            !onlyDirectories) {
          conditional = true;
        }
      }
      if (!effect.directory) onlyDirectories = false;
      index = end;
    }
    endList();
    return stop;
  }

  /// End index (exclusive) of the construct starting at [index], or -1 after
  /// a warning when it is unterminated.
  int _elementEnd(List<_Token> tokens, int index, _Scope scope) {
    final token = tokens[index];
    if (token.operator) {
      final end = closeParen(tokens, index);
      if (end < 0) warn('Unclosed shell subshell', scope, token.line);
      return end < 0 ? -1 : end + 1;
    }
    if (_commandStart(tokens, index)) {
      // Reserved prefixes stand alone so the construct after them is seen.
      if (_prefixWords.contains(token.text)) return index + 1;
      final function = _functionHeader(tokens, index);
      if (function != null) {
        final body = _functionBody(tokens, function);
        if (body == null) {
          warn(
            'Unsupported shell function body; coverage is not inferred',
            scope,
            token.line,
          );
          return -1;
        }
        return body.end;
      }
      if (_loopKeywords.contains(token.text)) {
        final doIndex = keyword(tokens, 'do', index + 1);
        final end = doIndex < 0 ? -1 : closing(tokens, doIndex);
        if (end < 0) {
          warn(
            'Unterminated shell loop; coverage is not inferred',
            scope,
            token.line,
          );
          return -1;
        }
        return end + 1;
      }
      if (token.text == 'if' || token.text == 'case') {
        final end = matching(
          tokens,
          index + 1,
          token.text,
          token.text == 'if' ? 'fi' : 'esac',
        );
        if (end < 0) {
          warn(
            'Unterminated shell ${token.text}; coverage is not inferred',
            scope,
            token.line,
          );
          return -1;
        }
        return end + 1;
      }
    }
    var end = index;
    while (end < tokens.length && !tokens[end].operator) {
      end++;
    }
    return end;
  }

  /// For `name() body` or `function name [()] body`, the index where the body
  /// starts, and the name.
  ({String name, int body})? _functionHeader(List<_Token> tokens, int index) {
    bool paren(int i, String text) =>
        i < tokens.length && tokens[i].operator && tokens[i].text == text;
    final name = RegExp(r'^[A-Za-z_][A-Za-z0-9_:.\-]*$');
    var i = index;
    String? found;
    if (tokens[i].text == 'function' &&
        i + 1 < tokens.length &&
        !tokens[i + 1].operator) {
      found = tokens[i + 1].text;
      i += 2;
      if (paren(i, '(') && paren(i + 1, ')')) i += 2;
    } else if (name.hasMatch(tokens[i].text) &&
        !_reservedWords.contains(tokens[i].text) &&
        paren(i + 1, '(') &&
        paren(i + 2, ')')) {
      found = tokens[i].text;
      i += 3;
    } else {
      return null;
    }
    while (paren(i, '\n')) {
      i++;
    }
    return (name: found, body: i);
  }

  ({String name, List<_Token> body, bool subshell, int end})? _functionBody(
    List<_Token> tokens,
    ({String name, int body}) header,
  ) {
    final start = header.body;
    if (start >= tokens.length) return null;
    if (tokens[start].operator && tokens[start].text == '(') {
      final close = closeParen(tokens, start);
      if (close < 0) return null;
      return (
        name: header.name,
        body: tokens.sublist(start + 1, close),
        subshell: true,
        end: close + 1,
      );
    }
    if (tokens[start].text != '{') return null;
    final close = matching(tokens, start + 1, '{', '}');
    if (close < 0) return null;
    return (
      name: header.name,
      body: tokens.sublist(start + 1, close),
      subshell: false,
      end: close + 1,
    );
  }

  /// Runs one construct. [directory] reports a plain static `cd` or `pushd`,
  /// whose failure the check reports as a stale path.
  ({_Stop stop, bool directory}) _element(
    List<_Token> tokens,
    _Scope scope,
    String? reason,
    String? previous,
  ) {
    const none = (stop: _Stop.none, directory: false);
    final token = tokens.first;
    if (token.operator) {
      // A subshell keeps its directory and absorbs exit, break, and return.
      parse(tokens.sublist(1, tokens.length - 1), scope.copy(), reason);
      return none;
    }
    final header = _commandStart(tokens, 0) ? _functionHeader(tokens, 0) : null;
    if (header != null) {
      final body = _functionBody(tokens, header)!;
      functions[body.name] = _Function(body.body, body.subshell, scope.copy());
      return none;
    }
    if (_loopKeywords.contains(token.text)) {
      return (stop: _loop(tokens, scope, reason), directory: false);
    }
    if (token.text == 'if') {
      final thenIndex = keyword(tokens, 'then', 1);
      final condition = tokens.sublist(1, thenIndex < 0 ? 1 : thenIndex);
      var stop = parse(condition, scope, reason);
      // Branches may not run; a directory change inside one leaves the
      // directory after `fi` unknown.
      final branch = scope.copy();
      stop = _max(
        stop,
        parse(
          tokens.sublist(thenIndex < 0 ? 1 : thenIndex + 1, tokens.length - 1),
          branch,
          stop == _Stop.none ? reason : reason ?? _skipReason,
        ),
      );
      scope.merge(branch);
      return (stop: stop, directory: false);
    }
    if (token.text == 'case') {
      final inIndex = tokens.indexWhere(
        (t) => !t.operator && t.text == 'in',
        1,
      );
      final branch = scope.copy();
      final stop = parse(
        _withoutCasePatterns(
          tokens.sublist(inIndex < 0 ? 1 : inIndex + 1, tokens.length - 1),
        ),
        branch,
        reason,
      );
      scope.merge(branch);
      return (stop: stop, directory: false);
    }
    return _simple(tokens, scope, reason, previous);
  }

  _Stop _loop(List<_Token> tokens, _Scope scope, String? reason) {
    final token = tokens.first;
    final doIndex = keyword(tokens, 'do', 1);
    final body = tokens.sublist(doIndex + 1, tokens.length - 1);
    List<String>? words;
    if (token.text == 'for' && doIndex >= 3 && tokens[2].text == 'in') {
      final list = tokens
          .sublist(3, doIndex)
          .where((t) => !t.operator)
          .toList();
      if (!list.any(
        (t) =>
            RegExp(r'[$*?\[\]{}]').hasMatch(t.text) ||
            t.text == '__MONOREPO_UNPARSED_QUOTE__',
      )) {
        words = list.map((t) => t.text).toList();
      }
    }
    var stop = _Stop.none;
    if (token.text != 'for' && token.text != 'select') {
      // A while/until condition runs at least once; its body may not.
      stop = parse(tokens.sublist(1, doIndex), scope, reason);
    }
    var skipped = stop != _Stop.none;
    if (words != null) {
      final variable = tokens[1].text;
      for (final word in words) {
        final result = parse(
          body.map((t) => t.expand(variable, word)).toList(),
          scope,
          skipped ? reason ?? _skipReason : reason,
        );
        // `break` (or anything stronger) may skip later iterations.
        if (result.index >= _Stop.breakLoop.index) skipped = true;
        if (result.index > _Stop.breakLoop.index) stop = _max(stop, result);
      }
    } else {
      final branch = scope.copy();
      final result = parse(body, branch, reason ?? _loopReason);
      scope.merge(branch);
      if (result.index > _Stop.breakLoop.index) stop = _max(stop, result);
    }
    return stop;
  }

  ({_Stop stop, bool directory}) _simple(
    List<_Token> tokens,
    _Scope scope,
    String? reason,
    String? previous,
  ) {
    const none = (stop: _Stop.none, directory: false);
    final line = tokens.first.line;
    var argv = tokens.map((t) => t.text).toList();
    while (argv.isNotEmpty &&
        (_prefixWords.contains(argv.first) || argv.first == 'if')) {
      argv = argv.sublist(1);
    }
    if (argv.isEmpty || {'fi', 'done', '}', 'esac'}.contains(argv.first)) {
      return none;
    }
    final unwrapped = _unwrap(argv);
    var location = scope.cwd;
    for (final directory in unwrapped.directories) {
      add(['env', '-C', directory], location, line, reason);
      location = joinLocation(location, directory);
    }
    argv = unwrapped.words;
    if (argv.isEmpty) return none;
    if ({'sh', 'bash'}.contains(argv.first) && argv.contains('-c')) {
      final commandIndex = argv.indexOf('-c') + 1;
      if (commandIndex < argv.length) {
        final nested = parseShell(
          argv[commandIndex].replaceAll(_literalDollar, r'$'),
          cwd: location,
          line: line,
          environment: environment,
          root: root,
        );
        result.addAll(
          reason == null
              ? nested
              : nested.map(
                  (c) => ShellCommand(
                    c.argv,
                    c.cwd,
                    c.line,
                    warning: c.warning,
                    uncertainReason: c.uncertainReason ?? reason,
                    location: c.location,
                  ),
                ),
        );
      } else {
        warn('Missing shell -c body', scope, line);
      }
      return none;
    }
    final function = unwrapped.wrapped ? null : functions[argv.first];
    if (function != null) {
      return _call(argv.first, function, scope, line, reason);
    }
    add(argv, location, line, reason);
    // Builtins below change this shell only when run directly.
    if (unwrapped.wrapped || unwrapped.directories.isNotEmpty) return none;
    final args = argv.skip(1).toList();
    switch (argv.first) {
      case 'cd':
        _cd(args, scope);
        return (
          stop: _Stop.none,
          directory: args.length == 1 && !args.first.startsWith('-'),
        );
      case 'pushd':
        _pushd(args, scope);
        return (
          stop: _Stop.none,
          directory: args.length == 1 && !RegExp(r'^[-+]').hasMatch(args.first),
        );
      case 'popd':
        _popd(args, scope);
      case 'dirs':
        if (args.isNotEmpty) scope.stack = null;
      case 'continue':
        return (stop: _Stop.continueLoop, directory: false);
      case 'break':
        return (stop: _Stop.breakLoop, directory: false);
      case 'return':
        return (stop: _Stop.returnFunction, directory: false);
      case 'exit':
        // `exit 1` and `|| exit` fail the step visibly; only an exit that can
        // succeed silently skips later commands.
        final status = args.isEmpty ? null : int.tryParse(args.first);
        final failing =
            (status != null && status != 0) ||
            ((args.isEmpty || args.first == r'$?') && previous == '||');
        return (stop: failing ? _Stop.none : _Stop.exitShell, directory: false);
    }
    return none;
  }

  ({_Stop stop, bool directory}) _call(
    String name,
    _Function function,
    _Scope scope,
    int line,
    String? reason,
  ) {
    function.visited = true;
    if (!calling.add(name)) {
      warn(
        'Recursive shell function "$name"; coverage is not inferred',
        scope,
        line,
      );
      return (stop: _Stop.none, directory: false);
    }
    // A brace body runs in the caller's shell, so its cd persists; a
    // parenthesized body is a subshell.
    final target = function.subshell ? scope.copy() : scope;
    final stop = parse(function.body, target, reason);
    calling.remove(name);
    return (
      stop: stop == _Stop.returnFunction || function.subshell
          ? _Stop.none
          : stop,
      directory: false,
    );
  }

  void _cd(List<String> input, _Scope scope) {
    final args = input.isNotEmpty && input.first == '--'
        ? input.sublist(1)
        : input;
    String target;
    if (args.isEmpty) {
      target = r'$HOME';
    } else if (args.length > 1 ||
        (args.first.startsWith('-') && args.first != '-')) {
      scope.forget();
      return;
    } else if (args.first == '-') {
      target = scope.oldpwd ?? r'$OLDPWD';
    } else {
      target = args.first;
    }
    final next = joinLocation(scope.cwd, target);
    scope
      ..oldpwd = scope.cwd
      ..cwd = next;
  }

  void _pushd(List<String> input, _Scope scope) {
    final args = input.isNotEmpty && input.first == '--'
        ? input.sublist(1)
        : input;
    final stack = scope.stack;
    if (args.isEmpty) {
      if (stack == null) {
        scope.forget();
      } else if (stack.isNotEmpty) {
        final top = stack.first;
        stack[0] = scope.cwd;
        scope
          ..oldpwd = scope.cwd
          ..cwd = top;
      }
      return;
    }
    if (args.length > 1 || RegExp(r'^[-+]').hasMatch(args.first)) {
      scope.forget();
      return;
    }
    stack?.insert(0, scope.cwd);
    scope
      ..oldpwd = scope.cwd
      ..cwd = joinLocation(scope.cwd, args.first);
  }

  void _popd(List<String> args, _Scope scope) {
    final stack = scope.stack;
    if (args.isNotEmpty || stack == null) {
      scope.forget();
      return;
    }
    // popd on an empty stack fails and leaves the directory alone.
    if (stack.isEmpty) return;
    scope
      ..oldpwd = scope.cwd
      ..cwd = stack.removeAt(0);
  }
}

/// Removes `case` arm patterns, leaving each arm's commands separated by `;`.
List<_Token> _withoutCasePatterns(List<_Token> tokens) {
  final out = <_Token>[];
  var armStart = true;
  var i = 0;
  while (i < tokens.length) {
    final token = tokens[i];
    if (armStart) {
      if (token.operator && (token.text == '\n' || token.text == ';')) {
        i++;
        continue;
      }
      var j = i;
      while (j < tokens.length &&
          !(tokens[j].operator && tokens[j].text == ')')) {
        if (j > i && tokens[j].operator && tokens[j].text == '\n') break;
        j++;
      }
      i = j + 1;
      armStart = false;
      continue;
    }
    if (!token.operator && token.text == 'case' && _commandStart(tokens, i)) {
      // Copy a nested case whole so its `;;` do not end this arm.
      var depth = 0;
      var j = i;
      for (; j < tokens.length; j++) {
        if (tokens[j].operator || !_commandStart(tokens, j)) continue;
        if (tokens[j].text == 'case') depth++;
        if (tokens[j].text == 'esac' && --depth == 0) break;
      }
      final end = j < tokens.length ? j + 1 : tokens.length;
      out.addAll(tokens.sublist(i, end));
      i = end;
      continue;
    }
    if (token.operator &&
        token.text == ';' &&
        i + 1 < tokens.length &&
        tokens[i + 1].operator &&
        (tokens[i + 1].text == ';' || tokens[i + 1].text == '&')) {
      out.add(_Token(';', token.line, true));
      i += 2;
      if (i < tokens.length && tokens[i].operator && tokens[i].text == '&') i++;
      armStart = true;
      continue;
    }
    out.add(token);
    i++;
  }
  return out;
}

bool _commandStart(List<_Token> tokens, int index) {
  if (index == 0) return true;
  final previous = tokens[index - 1];
  return previous.operator ||
      {'do', 'then', 'else', 'elif', '{', '!', 'if'}.contains(previous.text);
}

const _knownCommands = {
  'env',
  'timeout',
  'xvfb-run',
  'dart',
  'flutter',
  'melos',
  'cargo',
  'sh',
  'bash',
};

/// Removes wrappers without interpreting assignment values as path arguments.
List<String> stripPrefixes(List<String> input) => _unwrap(input).words;

/// Removes assignment prefixes and the `env`, `timeout`, `xvfb-run`, and
/// global-run wrappers. [directories] collects `env -C` targets in order;
/// [wrapped] means an external wrapper runs the command, so it cannot be a
/// shell function or a builtin that changes this shell.
({List<String> words, List<String> directories, bool wrapped}) _unwrap(
  List<String> input,
) {
  var words = input;
  final directories = <String>[];
  var wrapped = false;
  while (words.isNotEmpty) {
    final base = p.posix.basename(words.first);
    if (base != words.first && _knownCommands.contains(base)) {
      // "$SDK/bin/flutter" runs flutter whatever directory holds it.
      words = [base, ...words.skip(1)];
    }
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\+?=').hasMatch(words.first)) {
      words = words.sublist(1);
    } else if (words.first == 'env') {
      wrapped = true;
      var i = 1;
      while (i < words.length && words[i].startsWith('-')) {
        final word = words[i];
        if (word == '--' || word == '-') {
          i++;
          break;
        }
        if (word == '-S' ||
            word == '--split-string' ||
            word.startsWith('--split-string=') ||
            (word.startsWith('-S') && word.length > 2)) {
          // The command is inside a string env splits itself.
          return (words: words, directories: directories, wrapped: true);
        }
        if (word == '-C' || word == '--chdir') {
          if (i + 1 < words.length) directories.add(words[i + 1]);
          i += 2;
          continue;
        }
        if (word.startsWith('--chdir=')) {
          directories.add(word.substring('--chdir='.length));
        } else if (word.startsWith('-C') && word.length > 2) {
          directories.add(word.substring(2));
        } else if (word == '-u' || word == '--unset') {
          i++;
        }
        i++;
      }
      words = words.sublist(i.clamp(0, words.length));
    } else if (words.first == 'timeout') {
      wrapped = true;
      var i = 1;
      while (i < words.length && words[i].startsWith('-')) {
        if ({'-s', '--signal', '-k', '--kill-after'}.contains(words[i])) i++;
        i++;
      }
      if (i < words.length) i++; // Duration.
      words = words.sublist(i.clamp(0, words.length));
    } else if (words.first == 'xvfb-run') {
      wrapped = true;
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
  return (words: words, directories: directories, wrapped: wrapped);
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
        final escaped = source[++i];
        buffer.write(escaped == r'$' ? _literalDollar : escaped);
        wordStarted = true;
      }
      continue;
    }
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(quote == "'" && char == r'$' ? _literalDollar : char);
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

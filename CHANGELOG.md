# Changelog

## 0.2.0

### check

- Expands static `strategy.matrix` values, including `include` and `exclude`, so `${{ matrix.* }}` in `run` and `working-directory` resolves to each concrete combination.
- Resolves `${{ env.* }}` and shell `$NAME` references from workflow, job, and step `env:` literals, and tracks names a step appends to `$GITHUB_ENV`.
- Understands `${{ github.workspace }}`, `$GITHUB_WORKSPACE`, `${{ runner.temp }}`, `$RUNNER_TEMP`, and `$HOME`. Commands outside the checkout no longer warn, and directories outside an `actions/checkout` `path:` are treated as outside the repository.
- Expands nested literal `for` loops. Loops over globs, variables, or command substitutions, and `while`/`until` bodies, are parsed as possibly running zero times: their test, analyze, and format commands warn and never count as coverage, and bodies without such commands produce no finding.
- Recognizes commands by basename (`"$SDK/bin/flutter" test`), skips bash array literals, and warns about dynamic command names.
- Collapses unparsed and Melos findings to one warning per job or script, with a count and line list. `--verbose` lists every site; JSON keeps them under `sites`.
- Tracks every `$GITHUB_ENV` append on a line and appends through `${{ github.env }}`. An append through a variable that holds the file's path is unattributable.
- `${{ env.GITHUB_WORKSPACE }}`, `${{ env.HOME }}` and other runner variables are unresolved unless the workflow declares them; the runner values apply only to shell `$NAME`.
- With an `actions/checkout` `path:`, directories resolve from the CI workspace, so `cd P/packages/a` reaches a member and a stale `cd P/packages/missing` is reported. Absolute and escaping paths are external and never looked up on the machine running the check.
- Models shell functions: a body counts only where the function is called, with a brace body's `cd` persisting after the call, and an uncalled body warns instead of counting. Models `pushd`, `popd`, `cd -`, and `env -C`, and keeps pipeline and background `cd` from leaking.
- A `cd` inside `if`, `case`, after `||`, or after a non-`cd` command joined by `&&` leaves the directory unknown afterwards. Commands after `break`, `continue`, `return`, or an `exit` that can succeed warn instead of counting.
- Stops substituting names assigned through `printf -v`, `declare`, `typeset`, `local`, `unset`, `let`, `read`, `mapfile`, `readarray`, `${NAME:=x}`, and arithmetic; a nameref turns substitution off. `dart test --help` and `--version` no longer count as coverage.
- Recognizes `actions/checkout` written as a full URL (`https://github.com/actions/checkout@v4`, `https://gitea.com/actions/checkout@v4`), including its `path:`.
- `--reporter text|json|github`. `github` prints `::error` and `::warning` workflow commands, which Gitea Actions also reads, before the text report, with paths relative to the repository root. `--json` stays as short for `--reporter json`.
- Collapsed warnings for a `melos.scripts` entry are labelled `melos script NAME` and no longer merge with a `monorepo.scripts` entry of the same name.
- A `~` makes a path dynamic only at the start of a word, where the shell expands it, so a Windows short name such as `RUNNER~1` is checked as written.

### Selection

- `--since <ref>` selects members owning files changed in `<ref>...HEAD` plus uncommitted and untracked files, with fenced ownership. Root `pubspec.yaml`, `pubspec.lock`, and `analysis_options.yaml` changes select every member. `--include-dependents` adds transitive dependents.
- `list` and `graph` accept the same filters as the operations.
- When `--since` selects no member, plans print `# no members changed since <ref>`, including with `--lines`, and execution prints that one line and exits 0 instead of a table of skips.

### Execution

- `-j` is short for `--concurrency`. Exec steps wait for the members they depend on, recorded as `dependsOn` in plan JSON; test steps stay independent.
- Each step's output starts with a `[package] command` header, and buffered output prints whole.
- Runs end with an aligned package, command, status, and duration table with totals. `--reporter json` prints one machine-readable document instead.
- Configured scripts accept `cwd`, `env`, and ordered `steps`; `run --fail-fast` stops a stepped script at its first failure.
- Script `env` values keep their source text, so `3.10` and `0755` are no longer read as the numbers `3.1` and `755`.
- Closes each child's stdin as soon as it starts, so a step that reads input sees end of file instead of hanging on a pipe nothing writes to.
- On SIGINT or SIGTERM, signals each running step's process tree, skips queued steps as `interrupted`, flushes buffered output, prints the summary, and exits 130 or 143.

### New commands

- `ci` prints a GitHub or Gitea Actions workflow, or with `--steps-only` a steps list, whose commands are the `plan` commands for format check, analyze, and test, with the same filters and config. Test steps use `working-directory` per member. `--runs-on`, `--job`, and `--timeout` (the `timeout --signal=TERM --kill-after=30s` wrapper) shape it, and it never writes a file. Tests require that `check` passes on what it generates.
- `graph` prints the member dependency graph as text, DOT, Mermaid, or JSON.
- `doctor` reports workspace entries, `resolution: workspace`, unlisted nested members, lockfiles, SDK and dependency constraint drift, config validity, and the toolchains on PATH. Errors exit 1; warnings only with `--strict`.
- `doctor` skips directories a glob workspace entry matches that have no `pubspec.yaml`, as pub does. An explicit entry without one is still an error.
- `doctor` compares SDK and dependency constraints by what they allow, so `>=3.10.0 <4.0.0` and `^3.10.0` are not reported as drift.
- `completion bash|zsh|fish` prints shell completion generated from the command definitions. Script names containing `:`, such as `native:test`, complete whole in bash and zsh.

### Repository

- `.gitea/workflows/ci.yml` runs on `main`, `maintenance/**`, and pull requests, compiles the executable, checks this repository's workflows, and checks that `example/.github/workflows/ci.yml` matches `monorepo ci` and passes `monorepo check --strict`.

### Install

- Documented git activation pinned to a commit, and `tool/install.sh`, which compiles a native executable. Both avoid the dependency resolution a path activation prints on every launch.

## 0.1.0

- Add optional planning, execution, and workflow drift checks for pub workspaces.

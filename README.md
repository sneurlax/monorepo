# monorepo

I use `monorepo` to run the right command in each Dart pub workspace member and to see where handwritten CI commands have drifted. Pub remains responsible for workspace resolution. This tool is an optional global executable. Repositories do not depend on it, and CI can use the raw commands printed by `plan`.

`monorepo` discovers members through `dart pub workspace list --json`. It never runs `pub get`, edits manifests or lockfiles, or creates a repository cache. Only `format` without `--check` intentionally changes source files. Commands it starts remain ordinary Dart, Flutter, or user scripts and may have their own side effects, including test output and SDK caches.

## Install

Requires Dart 3.10 or later. Flutter must also be on PATH to run Flutter package tests. Install from a local checkout:

```sh
export DASH__SUPPRESS_ANALYTICS=true
export FLUTTER_SUPPRESS_ANALYTICS=true
timeout 300 dart pub global activate --source path ~/src/ManyMath/monorepo
export PATH="$HOME/.pub-cache/bin:$PATH"
monorepo --version
```

Windows users should add `%LOCALAPPDATA%\Pub\Cache\bin` to PATH as appropriate for their Dart installation. Git Bash is required only for configured shell scripts (`run`); missing bash produces exit 2 and prints the attempted command. Dart and Flutter commands launch through the Windows shell so `.bat` launchers work.

The package is not published and this repository has no configured remote. A later installation from Git should pin a reviewed commit. No activation belongs in a consumer's `pubspec.yaml`.

Run commands from a workspace root or one of its members. Run `dart pub get` yourself before tests, analysis, or formatting. Discovery is metadata-only and has a 30-second subprocess timeout.

## List and select members

```sh
monorepo list
monorepo list --json
monorepo test --scope 'manytype_*'
monorepo test --ignore manytype
monorepo test --no-flutter
monorepo exec --file-exists ffigen.yaml -- dart run ffigen --config ffigen.yaml
```

The workspace root is not a member. Filters narrow the list, but config ignores are shown in the last column instead of hiding members. The list shows name, relative path, Dart/Flutter kind, test and integration-test directories, and config ignores. A direct Flutter SDK dependency, or a Flutter test SDK dev dependency, marks a member as Flutter. Member dependencies and dev dependencies determine dependency-first order; ties use package name. Cycles are collapsed, their members ordered by name, and plans print a comment.

`list`, `graph`, `ci`, `test`, `analyze`, `format`, `exec`, and the matching `plan` subcommands share these filters:

| Filter | Meaning |
| --- | --- |
| `--scope name-or-glob` | Include matching members; repeat to select several patterns |
| `--ignore name-or-glob` | Exclude matching members; repeat as needed |
| `--flutter`, `--no-flutter` | Select Flutter or Dart members |
| `--dir-exists relative/path` | Require this directory inside the member |
| `--file-exists relative/path` | Require this file inside the member |
| `--since git-ref` | Select members that own a file changed since the ref |
| `--include-dependents` | With `--since`, also select members that depend on a changed member |

`--since main` selects members owning a file listed by `git diff --name-only main...HEAD`, plus uncommitted (staged or unstaged) and untracked files that git does not ignore. Ownership uses the same fences as formatting: a file belongs to the deepest member directory containing it, so a nested example's change selects the example and not its parent. A file under a directory that has its own pubspec but is not a member, such as `cargokit/build_tool`, selects nobody. Files outside every member, such as the README or workflows, select nobody. A change to the root `pubspec.yaml`, `pubspec.lock`, or `analysis_options.yaml` selects every member, because it can change every member's resolution or lints; plans print a comment saying so. `--include-dependents` adds members that depend on a changed member through dependencies or dev dependencies, transitively. Unselected members appear in plans as `unchanged since <ref>`. When `--since` leaves no member selected, plans print `# no members changed since <ref>` (with `--lines` too, so the output is still a valid script that does nothing), and execution prints `no members changed since <ref>` and exits 0. If members changed but other filters exclude them all, the line reads `none of the members changed since <ref> are selected`. Git is only asked to read: `rev-parse`, `diff`, and `ls-files` run with `GIT_OPTIONAL_LOCKS=0` so they do not refresh the index.

```sh
monorepo test --since origin/main --include-dependents
monorepo plan analyze --since HEAD~1 --lines
monorepo list --since main
```

Patterns containing `/` match workspace-relative paths. Others match pubspec names. Globs support `*`, `?`, and `**`; `*` does not cross `/`. Quote globs to keep the shell from expanding them. An exact package name in `--scope` overrides a config ignore, including `test.ignore`. A wildcard or path scope does not. CLI `--ignore` still wins. Filters that match nothing produce no executable steps.

## Show the dependency graph

```sh
monorepo graph
monorepo graph --format dot | dot -Tsvg > workspace.svg
monorepo graph --format mermaid
monorepo graph --format json --scope 'keepass*'
```

`graph` prints members in dependency order with edges from each member to the members it depends on. Text output marks dev-dependency edges with `(dev)`; DOT draws them dashed and Flutter members rounded; Mermaid labels them `dev` and draws Flutter members with round ends. A member listed in both `dependencies` and `dev_dependencies` is a regular dependency. JSON has `packages` (name, path, kind, `dependencies`, `devDependencies`) and `cycles`. Filters, including `--since`, select the nodes; edges to unselected members are left out.

## Inspect plans before running

Every operation builds a plan containing package, working directory, argument vector, environment, accepted exit codes, and any skip reason. Execution consumes that same plan.

```sh
monorepo plan test
monorepo plan test --json
monorepo plan format --check --lines
monorepo plan exec --scope manytype_cli -- dart run build_runner build
```

This measured plan comes from the tract workspace:

```sh
rc=0
(cd packages/tract && dart test) || rc=1
(cd packages/tract_flutter && flutter test) || rc=1
(cd packages/tract_flutter/example && flutter test) || rc=1
exit $rc
```

`monorepo plan analyze --lines` there prints:

```sh
dart analyze packages/tract packages/tract_flutter
```

The nested example is covered by its selected parent when both are selected. If a nested member is ignored or outside `--scope`, `analyze` expands its parent to owned paths so the skipped child is not analyzed. Tests always run from each package's own directory, including examples. This preserves build-hook and package-relative fixture behavior.

For ManyType, keep its VM test policy explicit:

```sh
monorepo plan test --ignore manytype -- --exclude-tags=round_trip -j 1
```

Its three Dart package steps run from `packages/manytype_protocol`, `packages/manytype_core`, and `packages/manytype_cli`. Each command is `dart test --exclude-tags=round_trip -j 1`; each accepts exit 79 because a test filter is present. The application is shown as skipped. The same policy can be stored in the optional config below.

Default shell plans collect failures with `rc=0` and `exit $rc`. `--fail-fast` renders `set -e`. `--lines` prints bare subshell commands for an existing CI `run:` block; that block decides whether to stop after a failed line. `--json` prints the step list. Shell quoting preserves literal spaces, apostrophes, empty arguments, and metacharacters.

Paste plans into a POSIX shell at the workspace root. Built-in paths are relative and portable between checkouts. `exec` and `run` plans include the absolute `MONOREPO_ROOT` of the inspected checkout; regenerate those plans when moving a checkout.

Shell replay is sequential, including when `--concurrency` exceeds 1. A comment in full shell plans calls this out. At concurrency 1, executable steps, cwd, argv, explicit env, accepted statuses, and fail-fast selection match the executor. Parallel execution changes scheduling and can start more work before the first failure is observed. In that case a shell replay preserves the commands and status policy, not parallel timing or fail-fast scheduling. Summaries and buffered output are executor presentation, not part of the shell plan. The specified fail-fast shell form uses `set -e`, which returns a failing child's status; the CLI normalizes step failures to 1 and environment failures to 2. Replay equivalence therefore concerns executed child commands and accepted statuses, not every outer nonzero numeric exit code.

## Test

```sh
monorepo test
monorepo test -j 3
monorepo test --reporter json > results.json
monorepo test --fail-fast -- --name='serialization'
monorepo test -- --exclude-tags=round_trip -j 1
```

Each selected member with `test/` runs `dart test` or `flutter test` in its package directory. Missing test directories are skipped before invocation with `no test/ directory`. Integration tests are never selected by default; use an explicit script with device arguments for them.

Configuration `test.args` comes before CLI arguments following `--`. Arguments after that separator are passed unchanged to the test runner. `--concurrency N` (`-j N` before `--`) controls simultaneous package processes, defaulting to 1. `-j` after `--` controls test-file concurrency inside each runner. They are independent: `monorepo test -j 3 -- -j 1` runs three packages at a time, each with one test file at a time.

Exit 79 is accepted as `no matching tests` only when arguments include `--tags`/`-t`, `--exclude-tags`/`-x`, `--name`/`-n`, or `--plain-name`/`-N`. Without a filter it is a failure. Exit 65 and Flutter exit 1 are never interpreted as a missing test directory.

All selected packages run by default, with an aggregate failure at the end. Fail-fast stops starting queued work; processes already running finish. Each step's output starts with a `[package] command` header. At concurrency 1 output streams as it is produced; above 1 it is buffered per step and printed whole when the step finishes, so packages never interleave. Captured child output is retained for the invocation, so memory use grows with total output; use smaller scopes for particularly noisy commands.

Test steps start in plan order as soon as a worker is free. Each test runner compiles its dependencies from source, so a package's tests never need another package's tests to finish first. Exec steps also wait for the steps of the members they depend on (through dependencies or dev dependencies, looking through unselected members), because exec commands such as `build_runner` or `ffigen` often produce code a dependent consumes. A failed dependency does not cancel its dependents unless `--fail-fast` is set. The plan records this as `dependsOn` in `plan exec --json`; the shell plan is sequential and dependency-ordered already, so it needs no extra syntax. Concurrency never changes the plan itself.

Every executing command ends with a summary table of package, command, status, and duration, followed by totals. From `monorepo exec -j 2 --ignore tract_flutter_example -- dart --version` in tract:

```text
[tract] dart --version
Dart SDK version: 3.13.2 (stable) (Tue Aug 25 01:01:12 2026 -0700) on "linux_x64"
[tract_flutter] dart --version
Dart SDK version: 3.13.2 (stable) (Tue Aug 25 01:01:12 2026 -0700) on "linux_x64"
package                command         status                         duration
tract                  dart --version  passed                         0.03s
tract_flutter          dart --version  passed                         0.03s
tract_flutter_example  -               skip: ignored by command line  -
2 passed, 0 failed, 1 skipped in 0.06s
```

Test steps that accept exit 79 report `no matching tests`, counted with the passes in the totals line.

`--reporter json` replaces the streamed output and the table with one JSON document on stdout: `command`, `exitCode`, `seconds`, a `summary` of counts by status (`passed`, `no-tests`, `failed`, `skipped`), and `steps`. Each step has the plan fields plus `status`, `exitCode`, `seconds`, and the captured `output`. Exit statuses are the same as with the text reporter. `test`, `analyze`, `format`, `exec`, and `run` all accept `--reporter`.

Steps get no input: each child's stdin is closed as soon as it starts, at every concurrency, so a command that reads stdin sees end of file instead of waiting. A command that needs input should be run directly, or through the shell replay from `monorepo plan <cmd> --lines`, where stdin is the terminal.

On SIGINT or SIGTERM, the tool signals each running step's whole process tree, skips queued steps as `interrupted`, prints their buffered output and the summary (or the JSON document), and exits 130 for SIGINT or 143 for SIGTERM. Children that ignore the signal are killed after ten seconds, or at once on a second signal.

## Analyze and format

```sh
monorepo analyze -- --fatal-infos
monorepo format --check
monorepo format
```

Analyze runs one `dart analyze` at the workspace root over the smallest set of selected member roots. A selected parent covers its nested members, even when a nested member was filtered out. This is analysis over directories, not isolated package execution. `analyze.args` precedes CLI pass-through arguments.

Format walks owned `.dart` files. It does not enter hidden directories, `build/`, symbolic links, or a nested directory containing a pubspec. Nested workspace members are visited separately; non-member packages such as `cargokit/build_tool` are fenced out. `format.exclude` applies to workspace-relative paths. Exclusions and package boundaries are checked before paths are compressed into whole directories.

Commands are batched below a conservative 7000-character shell-quoted budget. `--check` adds `--output none --set-exit-if-changed`, making it read-only. If the root `.dart_tool/package_config.json` is missing, formatting stops with exit 2 and asks you to run `dart pub get`; the formatter needs resolved language versions.

## Execute commands and scripts

```sh
monorepo exec --scope manytype_cli -- dart run build_runner build --delete-conflicting-outputs
monorepo exec --flutter -- flutter clean
monorepo run
monorepo run native:test
monorepo run custom -- 'argument with spaces'
monorepo run --fail-fast test:web
```

Exec runs the command vector in each selected package directory, with the same concurrency/fail-fast options as test and the dependency ordering described above. Run executes a configured shell body at the workspace root via `sh -c` on POSIX or `bash -c` on Windows. Extra arguments are shell-quoted and appended to the body. Scripts should be written to accept arguments at the end. Both commands export `MONOREPO_ROOT`.

A script is either a string body or a mapping with `run` or `steps` (exactly one), and optional `description`, `cwd`, and `env`. `cwd` is a workspace-relative directory the body runs in, checked by `check` like a workflow `working-directory`. `env` adds literal variables, each exactly as written (a plain `3.10` stays `3.10` and `0755` stays `0755`); `$MONOREPO_ROOT` or `${MONOREPO_ROOT}` in a value becomes the workspace root, and `MONOREPO_ROOT` itself cannot be overridden. `steps` run in order as separate plan steps named `<script> step N`, each in its own shell, so a `cd` in one step does not carry into the next. Like `test`, every step runs and the script fails at the end if any failed; `monorepo run --fail-fast <script>` stops after the first failing step. Extra arguments reach each step as its positional parameters (`"$@"`) and are never appended to a step body.

`monorepo run` without a name lists scripts and descriptions, with their `cwd`, `env`, and numbered steps. Scripts can be copied and run directly; avoid making one script depend on `monorepo` itself. The tool does not sandbox arbitrary commands or undo their side effects.

## Optional configuration

Only the root pubspec is read for configuration. No config is required. This example shows every supported field:

```yaml
monorepo:
  ignore: [some_pkg]
  test:
    ignore: [manytype]
    args: [--exclude-tags=round_trip, -j, "1"]
  analyze:
    args: [--fatal-infos]
  format:
    exclude: ["packages/foo/lib/src/generated/**"]
  scripts:
    native:test: cd packages/tract/native && cargo test
    native:build:
      run: cargo build --manifest-path packages/bluetooth_flutter/rust/Cargo.toml
      description: Build the native shared library.
    test:oracle:
      description: Run the round_trip tests against a local oracle.
      cwd: packages/anytype
      env:
        LD_LIBRARY_PATH: $MONOREPO_ROOT/rust/target/release
      run: dart test --tags=round_trip -j 1
    test:web:
      description: Run the chrome suites.
      steps:
        - cd packages/manytype_protocol && dart test -p chrome -j 1
        - cd packages/anytype && dart run tool/fetch_web_test_assets.dart && dart test -p chrome -j 1
  check:
    workflows: [.gitea/workflows, .github/workflows]
    allow:
      - kind: test
        package: manytype
        reason: Runs in product-web.yml outside this static check's supported forms.
```

The names are illustrative; replace them with members of your workspace. Unknown keys, unknown package names in ignore/allow lists, null sections, and malformed values are errors. `check.allow` accepts `test`, `analyze`, or `format` and requires a non-empty reason. Ignore lists use exact pubspec names; CLI selectors use globs.

## Generate CI steps

```sh
monorepo ci > .github/workflows/ci.yml
monorepo ci --provider gitea --runs-on manymath-maintenance-linux-x64 > .gitea/workflows/ci.yml
monorepo ci --steps-only --test --analyze
monorepo ci --test --ignore manytype -- --exclude-tags=round_trip -j 1
```

`ci` is the inverse of `check`. It prints workflow YAML to stdout and never writes a file; redirect it where you want it. The run commands come from the same plans as `monorepo plan format --check`, `plan analyze`, and `plan test`, with the same filters, config, and arguments after `--` (which go to the test runner). Each plan step becomes one workflow step, and a step that `plan --lines` prints as `(cd packages/a && dart test)` becomes `working-directory: packages/a` with `run: dart test`, so Flutter members get `flutter test` from their own directory. Skipped members and plan notes become YAML comments.

| Option | Meaning |
| --- | --- |
| `--provider github` | Default. Adds `dart-lang/setup-dart@v1`, or `subosito/flutter-action@v2` on the stable channel when any member is Flutter |
| `--provider gitea` | Expects the SDKs on the runner and adds a step printing their versions |
| `--test`, `--analyze`, `--format-check` | Include only these operations; without any of them, all three |
| `--runs-on label` | The runner label, `ubuntu-latest` by default |
| `--job name` | The job id, `ci` by default |
| `--timeout minutes` | Wrap each command in `timeout --signal=TERM --kill-after=30s <minutes>m`, as the ManyMath workflows do |
| `--steps-only` | Print only the format, analyze, and test steps, as a list to paste into an existing job |

A full workflow runs on pushes to `main`, pull requests, and manual dispatch, with read-only `contents` permission and analytics suppressed. It checks out the repository, sets up or reports the SDK, and runs `flutter pub get` (or `dart pub get` when no member is Flutter), adding `--enforce-lockfile` when git tracks the root `pubspec.lock`. Steps-only output leaves out checkout, SDK setup, and `pub get`, since the job you paste into has them. Edit the triggers, add a forge guard, or add non-Dart jobs as you need; the header comment records the arguments that produced the file.

From tract, `monorepo ci --steps-only --test --analyze` prints:

```yaml
# Generated by monorepo 0.2.0: monorepo ci --steps-only --test --analyze
# The commands match `monorepo plan --lines`. Regenerate this when members
# change; `monorepo check` reports drift.
- name: Analyze
  run: dart analyze packages/tract packages/tract_flutter
- name: Test tract
  working-directory: packages/tract
  run: dart test
- name: Test tract_flutter
  working-directory: packages/tract_flutter
  run: flutter test
- name: Test tract_flutter_example
  working-directory: packages/tract_flutter/example
  run: flutter test
```

Tests hold `ci` to this: for each fixture shape (nested Flutter examples, fenced non-member packages, paths that need quoting, config ignores and test arguments, batched format commands), `check` reports no error and no warning about the members a generated workflow covers. One case stays a warning by design: when a nested member is ignored, the plan analyzes its parent's owned paths instead of the parent directory, and `check` only counts analysis of a member's root.

## Check drift

```sh
monorepo check
monorepo check --json
monorepo check --reporter github
monorepo check --strict
monorepo check --verbose
```

Check reads YAML workflow files and configured script bodies. It does not execute any workflow or script. Like other commands, it first uses the metadata-only pub workspace discovery command.

It understands workflow, job, and step working-directory defaults; checkout path prefixes; multiline/folded YAML; `cd` and subshells; `&&`, `||`, semicolons; `timeout`, `env`, assignment, and `xvfb-run` wrappers; and static `sh -c`/`bash -c` bodies. Coverage is inferred only for recognized Dart/Flutter analyze, format, and test commands. Commands are recognized by basename, so `"$SDK/bin/flutter" test` counts as `flutter test`.

Workflow context is resolved the way the runner resolves it, before the shell starts:

- A static `strategy.matrix` expands into one copy of each step per combination, following GitHub's order: the cartesian product, then `exclude`, then `include`. `${{ matrix.x }}` and nested `${{ matrix.x.y }}` resolve to each concrete value. A matrix computed by an expression (`fromJSON(...)`) stays unresolved.
- `${{ env.X }}` and shell `$X`/`${X}` resolve from workflow, job, and step `env:` literals, with step values winning. A value that is itself an unresolved expression hides outer definitions instead of falling back to them. Shell variables are expanded only outside single quotes, only when the script never assigns the name, and only when the value contains no shell metacharacters. A step that appends a name to `$GITHUB_ENV` or `${{ github.env }}` makes it unknown for later steps, including several appends on one line. An append that cannot be attributed to names, such as `tee`, a grouped redirection, or a variable holding the file's path, makes every workflow variable unknown. Actions (`uses:` steps) are assumed not to overwrite variables the workflow declares.
- `${{ github.workspace }}` and `$GITHUB_WORKSPACE` are the CI workspace. Runner variables such as `GITHUB_WORKSPACE` and `HOME` exist only in the shell; `${{ env.GITHUB_WORKSPACE }}` and `${{ env.HOME }}` resolve only when the workflow declares them. With `actions/checkout` `path: P` (also written as a full URL such as `https://gitea.com/actions/checkout@v4`), the repository is `P` inside it: steps start in the workspace, so `cd P/packages/a` reaches a member and `cd P/packages/missing` is a stale path. Directories outside `P` are outside the checkout. `${{ runner.temp }}`, `$RUNNER_TEMP`, `$HOME`, absolute paths such as `/opt/hostedtoolcache`, and relative paths that leave the workspace are outside the checkout too. Commands there cannot cover a member, and their paths are never looked up, so results do not depend on the machine running the check.
- `for x in a b c; do ...; done` with literal words expands once per word, including nested loops. A loop over globs, variables, or command substitutions, and `while`/`until` bodies, may run zero times. Their commands still get stale-path checks, but a test, analyze, or format command inside them is a warning and never coverage. Loops whose bodies contain no such commands produce no finding. Bash array literals such as `args+=(--target "$t")` are not subshells.
- Shell functions (`name() { ...; }` and `function name { ...; }`) run where they are called. A brace body's `cd` persists after the call and a parenthesized body's does not. A function nothing calls is checked for stale paths, and its test, analyze, or format commands warn. `pushd`, `popd`, `cd -`, and `env -C dir` move the directory; pipeline members and background commands do not change it for later commands.
- A `cd` that may not run leaves the directory unknown afterwards: inside `if`, `case`, or a loop that may run zero times, after `||`, or after a command other than `cd` joined by `&&`. Commands after `break`, `continue`, `return`, or an `exit` that can succeed may be skipped, so they warn and never count; `exit 1` and `|| exit` fail the step visibly and do not.
- Names a script assigns, unsets, or reads into through any builtin (`printf -v`, `declare`, `typeset`, `local`, `unset`, `let`, `read`, `mapfile`, `readarray`, `${NAME:=x}`, arithmetic) are never substituted, and a nameref (`declare -n`) turns substitution off for the script. `--help`, `-h`, and `--version` runs never count as coverage.

| Finding | Severity |
| --- | --- |
| Nonexistent command path, working directory, or Cargo manifest | Error |
| Member has `test/` but no full workflow test command | Error |
| Member is not analyzed | Warning |
| Owned Dart files are not formatted | Warning with count and first five paths |
| Only specific test files run | Partial-test warning and uncovered-suite error |
| Dynamic paths, unresolved expressions, or unsupported relevant syntax | Unparsed warning |
| Melos invocation in CI | Warning |

Unparsed and Melos findings collapse to one warning per job (or per configured script), with the count, the line numbers, and the first reason. `--verbose` (`-v`) lists every site instead. In JSON, a collapsed finding carries a `sites` array with each site's `line` and `message`.

Analyze over a directory covers member roots below it. Format covers owned files beneath each named path. Test over a member or its `test/` directory covers that member; an individual file gives partial coverage. `integration_test/` is outside the v0 coverage model. A full test invocation elsewhere, a config ignore, or a reasoned allow entry resolves the test gap. With no workflows, every member is uncovered.

Check also validates paths in `monorepo.scripts` and transitional `melos.scripts` bodies, but these scripts do not establish CI coverage. It does not emulate Melos or follow arbitrary helper scripts. Melos-only workflows remain unproven and show warnings/gaps until raw commands are visible. It does not prove a workflow is enabled, its conditions hold, commands succeed, a device exists, or runtime libraries are installed. Dynamic expressions and unsupported relevant syntax are warnings, never evidence of coverage. Review reported paths generated during CI separately.

JSON has `errors` and `warnings` arrays with `kind`, `package`, `file`, `line`, and `message`. `--json` is short for `--reporter json`.

In a workflow, `--reporter github` prints one `::error` or `::warning` workflow command per finding, then the usual text report. GitHub and Gitea Actions both turn these into annotations on the named file and line. Paths are relative to the repository root, found by looking for `.git` above the workspace, so a workspace in a subdirectory still annotates the right file. A finding about a member's coverage points at line 1 of the root `pubspec.yaml`, where an allow entry would go. Strict mode treats warnings as a failing exit status while retaining their warning classification in JSON. It does not modify CI or write allow entries.

Exit statuses are 0 for success, 1 for failed steps or check findings, 2 for usage, configuration, or environment errors, and 130 or 143 when a run is interrupted by SIGINT or SIGTERM. Default check warnings alone do not fail; strict warnings do.

## Check workspace health

```sh
monorepo doctor
monorepo doctor --json
monorepo doctor --strict
```

Doctor reads the root and member pubspecs and the tree around them. It runs only `dart --version`, `flutter --version --machine`, and the metadata-only `dart pub workspace list --json`; it never runs `pub get` or writes a file. It works from anywhere inside the workspace and still reports when discovery itself fails, which makes it the first thing to run when other commands exit 2.

| Check | Severity |
| --- | --- |
| Workspace entry missing, matching no directory, or without a pubspec | Error |
| Member without `resolution: workspace`, or duplicate member names | Error |
| `dart pub workspace list` fails | Error |
| A member's SDK or Flutter constraint excludes the toolchain on PATH | Error |
| `dart` missing, or `flutter` missing while Flutter members exist | Error |
| Invalid `monorepo:` configuration | Error |
| Nested pubspec with `resolution: workspace` that the root does not list | Warning |
| No root `pubspec.lock` or root `.dart_tool/package_config.json` | Warning |
| Stray member `pubspec.lock` or `.dart_tool/package_config.json` | Warning |
| Members with different Dart SDK or Flutter constraints | Warning |
| The same external dependency constrained differently across members | Warning |
| Nested non-member packages, such as `cargokit/build_tool` | Info |
| `dart` and `flutter` versions and paths | Info |

Workspace entries may use `*`, `?` and `[...]` within a path segment. The nested-package search skips hidden directories, `build/`, `node_modules/`, and directories marked with `CACHEDIR.TAG` (Cargo `target/`). Errors exit 1. Warnings do not, unless `--strict`. JSON has `root` and `errors`, `warnings`, and `info` arrays of `severity`, `kind`, and `message`.

## Shell completion

```sh
source <(monorepo completion bash)                    # ~/.bashrc
source <(monorepo completion zsh)                     # ~/.zshrc, after compinit
monorepo completion fish > ~/.config/fish/completions/monorepo.fish
```

The scripts are generated from the command definitions, so they cover every command, subcommand, and option, including `plan` subcommands and option values with fixed choices. `--since` completes local branches, tags, and remote branches through `git for-each-ref`; `--scope` and `--ignore` complete member names through `monorepo list`; `run` completes configured script names through `monorepo run`. Those lookups run only when you complete those values. Nothing is completed after `--`, where bash falls back to file names. For zsh you can also save the output as `_monorepo` in a directory on your `fpath`.

## Drop the tool

Copy the commands, then stop using it:

```sh
monorepo plan test --lines > test-steps.sh
sh -e test-steps.sh
```

Use `monorepo plan test > test-all.sh` for a self-contained script that runs every suite and returns an aggregate status. Nothing in pub resolution depends on the tool, so removing its global activation needs no repository change.

## Develop and verify

[Real-repository acceptance](docs/acceptance.md) records the 13-workspace discovery, plan, drift, runtime, and original-state checks. The [gate record](docs/acceptance.json) identifies the tested implementation revision and expected baseline failures.

```sh
export DASH__SUPPRESS_ANALYTICS=true FLUTTER_SUPPRESS_ANALYTICS=true
timeout 300 dart pub get --offline
dart format --output none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

`.gitea/workflows/ci.yml` runs these on pushes to `main` and `maintenance/**` and on pull requests, on the `manymath-maintenance-linux-x64` runner after the primary-forge guard and a Dart 3.13.2 check. It also compiles `bin/monorepo.dart`, runs `monorepo check --strict` on this repository (which has no workspace members, so this proves its own workflow parses and its paths exist), and dogfoods the generator on `example/`: a small workspace whose `.github/workflows/ci.yml` was printed by `monorepo ci`, which must still match the generator and pass `monorepo check --strict`. After changing `ci` output, regenerate it from `example/` with `dart run ../bin/monorepo.dart ci > .github/workflows/ci.yml`. No runner is registered for this repository yet, so the workflow has not run; I run its commands by hand.

The `e2e` tag covers real Dart/Flutter runners, workspace discovery and a build-hook fixture. Tests resolve temporary fixture dependencies with an offline, time-limited pub invocation, so an SDK cache containing the declared Flutter/test/hooks dependencies is required. Run `dart test --exclude-tags=e2e` for parser/planner/unit tests only. POSIX shell replay tests also require `sh`, Python 3, and `chmod`; those tests skip on Windows. Native Windows execution is implemented but not validated on a Windows host in this change.

Licensed under the MIT License; Copyright (c) 2026 ManyMath LLC.

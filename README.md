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

The workspace root is not a member. The list shows name, relative path, Dart/Flutter kind, test and integration-test directories, and config ignores. A direct Flutter SDK dependency, or a Flutter test SDK dev dependency, marks a member as Flutter. Member dependencies and dev dependencies determine dependency-first order; ties use package name. Cycles are collapsed, their members ordered by name, and plans print a comment.

`test`, `analyze`, `format`, and `exec` share these filters:

| Filter | Meaning |
| --- | --- |
| `--scope name-or-glob` | Include matching members; repeat to select several patterns |
| `--ignore name-or-glob` | Exclude matching members; repeat as needed |
| `--flutter`, `--no-flutter` | Select Flutter or Dart members |
| `--dir-exists relative/path` | Require this directory inside the member |
| `--file-exists relative/path` | Require this file inside the member |

Patterns containing `/` match workspace-relative paths. Others match pubspec names. Globs support `*`, `?`, and `**`; `*` does not cross `/`. Quote globs to keep the shell from expanding them. An exact package name in `--scope` overrides a config ignore, including `test.ignore`. A wildcard or path scope does not. CLI `--ignore` still wins. Filters that match nothing produce no executable steps.

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

Shell replay is sequential, including when `--concurrency` exceeds 1. A comment in full shell plans calls this out. At concurrency 1, executable steps, cwd, argv, explicit env, accepted statuses, and fail-fast selection match the executor. Parallel execution changes scheduling and can start more work before the first failure is observed. In that case a shell replay preserves the commands and status policy, not parallel timing or fail-fast scheduling. Summaries and buffered output are executor presentation, not part of the shell plan.

## Test

```sh
monorepo test
monorepo test --concurrency 3
monorepo test --fail-fast -- --name='serialization'
monorepo test -- --exclude-tags=round_trip -j 1
```

Each selected member with `test/` runs `dart test` or `flutter test` in its package directory. Missing test directories are skipped before invocation with `no test/ directory`. Integration tests are never selected by default; use an explicit script with device arguments for them.

Configuration `test.args` comes before CLI arguments following `--`. Arguments after that separator are passed unchanged to the test runner. `--concurrency` controls simultaneous package processes, defaulting to 1. `-j` after `--` controls test-file concurrency inside each runner. They are independent.

Exit 79 is accepted as `no matching tests` only when arguments include `--tags`/`-t`, `--exclude-tags`/`-x`, `--name`/`-n`, or `--plain-name`/`-N`. Without a filter it is a failure. Exit 65 and Flutter exit 1 are never interpreted as a missing test directory.

All selected packages run by default, with an aggregate failure at the end. Fail-fast stops starting queued work; processes already running finish. Parallel output is buffered per package and printed when it finishes. A summary lists package, runner, result, and elapsed seconds.

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
```

Exec runs the command vector in each selected package directory, with the same concurrency/fail-fast options as test. Run executes a configured shell body at the workspace root via `sh -c` on POSIX or `bash -c` on Windows. Extra arguments are shell-quoted and appended to the body. Scripts should be written to accept arguments at the end. Both commands export `MONOREPO_ROOT`.

`monorepo run` without a name lists scripts and descriptions. Scripts can be copied and run directly; avoid making one script depend on `monorepo` itself. The tool does not sandbox arbitrary commands or undo their side effects.

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
  check:
    workflows: [.gitea/workflows, .github/workflows]
    allow:
      - kind: test
        package: manytype
        reason: Runs in product-web.yml outside this static check's supported forms.
```

The names are illustrative; replace them with members of your workspace. Unknown keys, unknown package names in ignore/allow lists, null sections, and malformed values are errors. `check.allow` accepts `test`, `analyze`, or `format` and requires a non-empty reason. Ignore lists use exact pubspec names; CLI selectors use globs.

## Check drift

```sh
monorepo check
monorepo check --json
monorepo check --strict
```

Check reads YAML workflow files and configured script bodies. It does not execute any workflow or script. Like other commands, it first uses the metadata-only pub workspace discovery command.

It understands workflow, job, and step working-directory defaults; checkout path prefixes; multiline/folded YAML; literal one-level shell loops; `cd` and subshells; `&&`, `||`, semicolons; `timeout`, `env`, assignment, and `xvfb-run` wrappers; and static `sh -c`/`bash -c` bodies. Coverage is inferred only for recognized Dart/Flutter analyze, format, and test commands.

| Finding | Severity |
| --- | --- |
| Nonexistent command path, working directory, or Cargo manifest | Error |
| Member has `test/` but no full workflow test command | Error |
| Member is not analyzed | Warning |
| Owned Dart files are not formatted | Warning with count and first five paths |
| Only specific test files run | Partial-test warning and uncovered-suite error |
| Dynamic paths, matrix context, or unsupported relevant syntax | Unparsed warning |
| Melos invocation in CI | Warning |

Analyze over a directory covers member roots below it. Format covers owned files beneath each named path. Test over a member or its `test/` directory covers that member; an individual file gives partial coverage. `integration_test/` is outside the v0 coverage model. A full test invocation elsewhere, a config ignore, or a reasoned allow entry resolves the test gap. With no workflows, every member is uncovered.

Check also validates paths in `monorepo.scripts` and transitional `melos.scripts` bodies, but these scripts do not establish CI coverage. It does not emulate Melos or follow arbitrary helper scripts. Melos-only workflows remain unproven and show warnings/gaps until raw commands are visible. It does not prove a workflow is enabled, its conditions hold, commands succeed, a device exists, or runtime libraries are installed. Dynamic expressions and unsupported relevant syntax are warnings, never evidence of coverage. Review reported paths generated during CI separately.

JSON has `errors` and `warnings` arrays with `kind`, `package`, `file`, `line`, and `message`. Strict mode treats warnings as a failing exit status while retaining their warning classification in JSON. It does not modify CI or write allow entries.

Exit statuses are 0 for success, 1 for failed steps or check findings, and 2 for usage, configuration, or environment errors. Default check warnings alone do not fail; strict warnings do.

## Drop the tool

Copy the commands, then stop using it:

```sh
monorepo plan test --lines > test-steps.sh
sh -e test-steps.sh
```

Use `monorepo plan test > test-all.sh` for a self-contained script that runs every suite and returns an aggregate status. Nothing in pub resolution depends on the tool, so removing its global activation needs no repository change.

## Develop and verify

```sh
export DASH__SUPPRESS_ANALYTICS=true FLUTTER_SUPPRESS_ANALYTICS=true
timeout 300 dart pub get --offline
dart format --output none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The `e2e` tag covers real Dart/Flutter runners, workspace discovery and a build-hook fixture. Tests resolve temporary fixture dependencies with an offline, time-limited pub invocation, so an SDK cache containing the declared Flutter/test/hooks dependencies is required. Run `dart test --exclude-tags=e2e` for parser/planner/unit tests only. POSIX shell replay tests also require `sh`, Python 3, and `chmod`; those tests skip on Windows. Native Windows execution is implemented but not validated on a Windows host in this change.

Licensed under the MIT License; Copyright (c) 2026 ManyMath LLC.

# ManyMath real-repository acceptance

Toolchain: Dart 3.13.2, Flutter 3.47.2, Linux x64. Final metadata verified against tool revision `eb4182fdd7e3e4cbdfccb3a510b72b41c3e782ec`.

I ran the tool against the 13 original checkouts while migration commits were isolated in separate worktrees. The results below describe the original, pre-migration workspace. Expected drift findings are evidence that the checker works; a nonzero check exit does not by itself fail tool acceptance.

## Discovery, ownership, and coverage

I independently compared member counts, Dart/Flutter classification, test-directory presence, and the formatter plan against a Python filesystem walk. The expanded formatter paths contain exactly the owned Dart files and no fenced nested packages. All 13 comparisons passed.

| Repository | Original revision | Members | Owned Dart files | Check exit |
| --- | --- | ---: | ---: | ---: |
| airdrop | `c6a173e512` | 3 | 13 | 1 |
| bluetooth | `da97d348b3` | 3 | 37 | 0 |
| camera | `9267b58c7e` | 3 | 19 | 1 |
| microphone | `a4ae053792` | 3 | 35 | 0 |
| mixer | `bd150e769f` | 1 | 7 | 1 |
| ratex | `6b7babd64f` | 4 | 23 | 0 |
| sound | `1eeaf00b04` | 3 | 23 | 0 |
| tract | `3b7e913055` | 3 | 24 | 1 |
| ManyType | `371024c18f` | 4 | 310 | 1 |
| ManyKee | `8b8a2ca36a` | 11 | 182 | 1 |
| ManyMatrix | `fe4e020c18` | 2 | 41 | 1 |
| ManyMath | `50c88a9b86` | 1 | 50 | 0 |
| ManyUI | `d5b8881a8a` | 9 | 211 | 0 |

| Repository | Analyze gaps | Format gaps | Test gaps |
| --- | --- | --- | --- |
| airdrop | `airdrop_dart`, `airdrop_flutter`, `airdrop_flutter_example` | `airdrop_dart`, `airdrop_flutter`, `airdrop_flutter_example` | `airdrop_dart` |
| bluetooth | `bluetooth_flutter`, `bluetooth_flutter_example` | `bluetooth_dart`, `bluetooth_flutter`, `bluetooth_flutter_example` | none |
| camera | `camera_flutter`, `camera_flutter_example` | `camera_dart`, `camera_flutter`, `camera_flutter_example` | `camera_flutter_example` |
| microphone | `microphone_flutter` | `microphone_dart`, `microphone_flutter`, `microphone_flutter_example` | none |
| mixer | `mixer_dart` | `mixer_dart` | `mixer_dart` |
| ratex | none | none | none |
| sound | none | `sound_flutter`, `sound_flutter_example` | none |
| tract | `tract`, `tract_flutter`, `tract_flutter_example` | `tract`, `tract_flutter`, `tract_flutter_example` | `tract`, `tract_flutter`, `tract_flutter_example` |
| ManyType | `manytype_cli`, `manytype_core`, `manytype_protocol` | `manytype`, `manytype_cli`, `manytype_core`, `manytype_protocol` | `manytype_cli`, `manytype_core`, `manytype_protocol` |
| ManyKee | `keepass_ui`, `manykee_native`, `manykee_web` | `keepass_cli`, `keepass_example`, `keepass_flutter`, `keepass_flutter_example`, `keepass_web_example`, `manykee_native`, `manykee_web` | `keepass_flutter_example`, `keepass_web_example`, `manykee_native`, `manykee_web` |
| ManyMatrix | none | `manymatrix`, `manymatrix_example` | `manymatrix_example` |
| ManyMath | none | `manymath` | none |
| ManyUI | none | `example`, `manyui`, `manyui_assets`, `manyui_board`, `manyui_cli`, `manyui_compat_forui`, `manyui_hooks`, `manyui_riverpod`, `manyui_testing` | none |

All direct-coverage sets match the supplied table. The table marks tract and ManyType as covered through Melos. The checker intentionally does not infer Melos execution, so it reports their unresolved direct coverage together with explicit Melos warnings. ManyType product checks directly cover its Flutter tests and analysis; the remaining gaps above are indirect Melos coverage. No source revision difference explains any direct-coverage change.

Additional warnings identify matrix/dynamic workflow context or unsupported shell loops. They do not silently infer coverage. Airdrop additionally reports the known stale `packages/airdrop_flutter/test` script path. Sound correctly recognizes its static test path despite a dynamic `SOUND_DART_LIB` assignment. ManyKee checkout prefixes and literal loops produce the supplied gaps. ManyUI has no test gap because its actual test-bearing members are covered; its obsolete board invocation is repaired separately by B1.

## Runtime checks

| Repository | Invocation | Exit | Seconds | Result |
| --- | --- | ---: | ---: | --- |
| mixer | `monorepo test -- --reporter expanded` | 0 | 2.02 | Dart package tests pass. |
| tract | `monorepo test -- --reporter expanded` | 0 | 62.07 | All three packages pass; native build hook runs with package cwd. |
| ManyUI | `monorepo test -- --reporter expanded` | 1 | 57.53 | Default run propagates existing text-field golden pixel differences; other three suites pass; exactly five members skip for missing test/. |
| bluetooth | `monorepo format --check` | 0 | 0.87 | 37 owned files checked, zero formatting changes; cargokit packages fenced. |
| airdrop | `monorepo format --check` | 1 | 0.72 | Exactly the five expected files need formatting; check mode does not write them. |
| ManyType | `monorepo test --ignore manytype -- --exclude-tags=round_trip -j 1 --reporter expanded` | 0 | 306.83 | VM suites run in package cwd, excluding Flutter product and round_trip; see log for result. |

A supplementary `monorepo test -- --exclude-tags=golden --reporter expanded` run passed all four ManyUI suites and skipped exactly five members, matching its private CI policy. The tool itself passed 98 tests (92 unit/integration and 6 e2e), including real Dart/Flutter/build-hook fixtures, with clean analysis and formatting. The ManyUI default failure is an existing golden baseline mismatch, not a suppressed success. Its private CI already excludes the golden tag. No golden files were updated. The airdrop formatter failure is required acceptance behavior. Runtime test output is retained in the local evidence directory, alongside before/after status.

## Script-by-script migration comparison

All test replacements run from each package root. The analyzer uses one Dart invocation over minimal selected member roots. Formatting batches owned paths across selected members into a single root `dart format` invocation while fencing nested packages. Native and product-specific scripts remain named optional aliases for raw commands.

### airdrop

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. |
| `test` | `monorepo test` | Runs only airdrop_dart; skips both members without test/, replacing the stale Flutter test path. |
| `native:build` | `monorepo run native:build` | Retain the raw script body; no corresponding builtin. |
| `native:test` | `monorepo run native:test` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/airdrop_dart packages/airdrop_flutter
(cd packages/airdrop_dart && dart test)
# skip packages/airdrop_flutter: no test/ directory
# skip packages/airdrop_flutter/example: no test/ directory
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/airdrop_dart/lib packages/airdrop_dart/test packages/airdrop_flutter/lib packages/airdrop_flutter/example/lib
```

### bluetooth

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. |
| `test` | `monorepo test` | Select test-bearing members and use package cwd and appropriate runner. |
| `native:build` | `monorepo run native:build` | Retain the raw script body; no corresponding builtin. |
| `native:test` | `monorepo run native:test` | Retain the raw script body; no corresponding builtin. |
| `native:scan` | `monorepo run native:scan` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/bluetooth_dart packages/bluetooth_flutter
(cd packages/bluetooth_dart && dart test)
(cd packages/bluetooth_flutter && flutter test)
(cd packages/bluetooth_flutter/example && flutter test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/bluetooth_dart/example packages/bluetooth_dart/lib packages/bluetooth_dart/test packages/bluetooth_flutter/lib packages/bluetooth_flutter/test packages/bluetooth_flutter/example/lib packages/bluetooth_flutter/example/test
```

### camera

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. Adds existing tests omitted by the old script; includes integration_test where present. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. Adds existing tests omitted by the old script; includes integration_test where present. |
| `test` | `monorepo test` | Adds camera_flutter/example tests omitted by the old script. |
| `native:build` | `monorepo run native:build` | Retain the raw script body; no corresponding builtin. |
| `native:test` | `monorepo run native:test` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/camera_dart packages/camera_flutter
(cd packages/camera_dart && dart test)
(cd packages/camera_flutter && flutter test)
(cd packages/camera_flutter/example && flutter test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/camera_dart/example packages/camera_dart/lib packages/camera_dart/test packages/camera_flutter/lib packages/camera_flutter/test packages/camera_flutter/example/lib packages/camera_flutter/example/test
```

### microphone

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. Adds existing tests omitted by the old script; includes integration_test where present. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. Adds existing tests omitted by the old script; includes integration_test where present. |
| `test` | `monorepo test` | Select test-bearing members and use package cwd and appropriate runner. |
| `test:web` | `monorepo run test:web` | Retain the raw script body; no corresponding builtin. |
| `native:build` | `monorepo run native:build` | Retain the raw script body; no corresponding builtin. |
| `native:test` | `monorepo run native:test` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/microphone_dart packages/microphone_flutter
(cd packages/microphone_dart && dart test)
(cd packages/microphone_flutter && flutter test)
# skip packages/microphone_flutter/example: no test/ directory
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/microphone_dart/example packages/microphone_dart/lib packages/microphone_dart/test packages/microphone_flutter/lib packages/microphone_flutter/test packages/microphone_flutter/example/lib
```

### mixer

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. |
| `test` | `monorepo test` | Select test-bearing members and use package cwd and appropriate runner. |

Measured builtin plan:

```sh
dart analyze packages/mixer_dart
(cd packages/mixer_dart && dart test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/mixer_dart/lib packages/mixer_dart/test
```

### ratex

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. |
| `test` | `monorepo test` | Runs inside packages/ratex/example rather than passing its directory from root. |
| `native:build` | `monorepo run native:build` | Retain the raw script body; no corresponding builtin. |
| `native:test` | `monorepo run native:test` | Retain the raw script body; no corresponding builtin. |
| `native:build:web` | `monorepo run native:build:web` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/ratex_dart packages/ratex apps/ratex_example
(cd packages/ratex_dart && dart test)
(cd packages/ratex && flutter test)
(cd apps/ratex_example && flutter test)
(cd packages/ratex/example && flutter test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/ratex_dart/example packages/ratex_dart/lib packages/ratex_dart/test packages/ratex/lib packages/ratex/test apps/ratex_example/lib apps/ratex_example/test packages/ratex/example/lib packages/ratex/example/test
```

### sound

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. Adds existing tests omitted by the old script; includes integration_test where present. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. Adds existing tests omitted by the old script; includes integration_test where present. |
| `test` | `monorepo test` | Select test-bearing members and use package cwd and appropriate runner. |
| `native:build` | `monorepo run native:build` | Retain the raw script body; no corresponding builtin. |
| `native:test` | `monorepo run native:test` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/sound_dart packages/sound_flutter
(cd packages/sound_dart && dart test)
(cd packages/sound_flutter && flutter test)
# skip packages/sound_flutter/example: no test/ directory
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/sound_dart/example packages/sound_dart/lib packages/sound_dart/test packages/sound_flutter/lib packages/sound_flutter/test packages/sound_flutter/example/integration_test packages/sound_flutter/example/lib
```

### tract

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. |
| `test` | `monorepo test` | Select test-bearing members and use package cwd and appropriate runner. |
| `native:test` | `monorepo run native:test` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/tract packages/tract_flutter
(cd packages/tract && dart test)
(cd packages/tract_flutter && flutter test)
(cd packages/tract_flutter/example && flutter test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/tract/example packages/tract/hook packages/tract/lib packages/tract/test packages/tract_flutter/lib packages/tract_flutter/test packages/tract_flutter/example/integration_test packages/tract_flutter/example/lib packages/tract_flutter/example/test
```

### ManyType

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `test` | `monorepo test` | After migration, defaults intentionally match test:ci, including round_trip exclusion and -j 1. Explicit flags are used in original-checkout acceptance. |
| `test:web` | `monorepo run test:web` | Retains per-package optional asset fetch before Chrome tests; a bare test builtin does not replace that setup. |
| `test:ci` | `monorepo test --ignore manytype -- --exclude-tags=round_trip -j 1` | Equivalent package/argument selection; post-migration config supplies defaults. |
| `test:oracle` | `monorepo run test:oracle` | Retains manytype_cli scope and round_trip selection; oracle infrastructure remains required. |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format-check` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. |
| `codegen` | `monorepo run codegen` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze packages/manytype_protocol packages/manytype_core packages/manytype_cli apps/ManyType
(cd packages/manytype_protocol && dart test)
(cd packages/manytype_core && dart test)
(cd packages/manytype_cli && dart test)
(cd apps/ManyType && flutter test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed packages/manytype_protocol/lib packages/manytype_protocol/test packages/manytype_core/lib packages/manytype_core/test packages/manytype_cli/bin packages/manytype_cli/check_db.dart packages/manytype_cli/lib packages/manytype_cli/test packages/manytype_cli/tool apps/ManyType/lib apps/ManyType/test apps/ManyType/tool
```

### ManyMatrix

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `test` | `monorepo test` | Select test-bearing members and use package cwd and appropriate runner. |
| `test:integration` | `monorepo run test:integration` | Replace Melos scoped exec with cd flutter_plugin/example and the same raw command. |
| `build:web` | `monorepo run build:web` | Replace Melos scoped exec with cd flutter_plugin/example and the same raw command. |
| `build:extension` | `monorepo run build:extension` | Replace Melos scoped exec with cd flutter_plugin/example and the same raw command. |
| `codegen` | `monorepo exec -- dart run build_runner build --delete-conflicting-outputs` | Optional helper spelling; stored script remains a raw per-member loop. |
| `clean` | `monorepo exec -- flutter clean` | Optional helper spelling; stored script remains a raw per-member loop. |

Measured builtin plan:

```sh
dart analyze flutter_plugin
(cd flutter_plugin && flutter test)
(cd flutter_plugin/example && flutter test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed flutter_plugin/lib flutter_plugin/test flutter_plugin/example/integration_test flutter_plugin/example/lib flutter_plugin/example/test flutter_plugin/example/test_driver flutter_plugin/example/tool
```

### ManyMath

| Existing script | Optional replacement | Difference |
| --- | --- | --- |
| `analyze` | `monorepo analyze` | One dart analyze invocation over minimal member roots, including Flutter members. |
| `format` | `monorepo format --check` | Check all owned Dart files; fence nested packages, hidden/build directories. Includes owned tool scripts omitted by the old alias. |
| `format:fix` | `monorepo format` | Same ownership as format --check; writes formatting only. Includes owned tool scripts omitted by the old alias. |
| `test` | `monorepo test` | Select test-bearing members and use package cwd and appropriate runner. |
| `web:build` | `monorepo run web:build` | Retain the raw script body; no corresponding builtin. |
| `web:verify` | `monorepo run web:verify` | Retain the raw script body; no corresponding builtin. |

Measured builtin plan:

```sh
dart analyze apps/ManyMath
(cd apps/ManyMath && flutter test)
```

Measured formatter check targets:

```sh
dart format --output none --set-exit-if-changed apps/ManyMath/lib apps/ManyMath/test apps/ManyMath/tool
```

### ManyKee (retired Melos 6 configuration)

The original `melos.yaml` was dead configuration: the workspace had no Melos
root dependency or CI invocation. These comparisons describe its intended
commands. No optional ManyKee `monorepo:` configuration was added, so the
remaining script bodies are run directly from the repository root.

| Existing script | Optional replacement or raw command | Difference |
| --- | --- | --- |
| `format` | `monorepo format` | Writes formatting like the old command, but fences hidden/build directories and nested non-member packages. |
| `analyze` | `monorepo analyze -- --fatal-infos` | One invocation covers minimal member roots; the flag is explicit because no config was added. |
| `test:dart` | `monorepo test --no-flutter --fail-fast` | Selects pure-Dart members with test directories, retaining package cwd and stop-on-failure behavior. The native FFI prerequisite still applies. |
| `test:flutter` | `monorepo test --flutter --fail-fast` | Selects Flutter members with test directories; browser-only packages still need an explicit platform argument. |
| `test:integration` | `monorepo exec --flutter --dir-exists integration_test --ignore keepass_web_example --fail-fast -- flutter test integration_test -d linux` | Explicit opt-in for device tests; ordinary `monorepo test` never selects integration tests. |
| `ffigen` | `monorepo exec --file-exists ffigen.yaml -- dart run ffigen --config ffigen.yaml` | Selects only members with the config file. |
| `build:extension` | `bash scripts/build_extension.sh` | Same root script; no Melos root environment variable needed. |
| `verify:compat:official` | `bash scripts/verify_official_compat.sh` | Same root script. |
| `verify:compat:parity` | `bash scripts/verify_bidirectional_parity.sh` | Same root script. |
| `verify:compat:fixtures` | `bash scripts/verify_official_compat.sh` | Same required-mode fixture workflow. |
| `verify:compat:matrix` | `bash scripts/generate_compat_matrix.sh --check` | Same generated-matrix check. |
| `test:e2e` | `(cd packages/keepass_web/example/test/e2e && npm install --silent && npm run test:only)` | Same Puppeteer command and prerequisite extension build, with an explicit root-relative cwd. |

## Original checkout preservation

All discovery/plan/check batches left git status unchanged. Each runtime run records status before and after; a final byte-hash comparison covers existing tracked tooling configuration and the user-owned untracked ManyType lockfile. No original branch was switched, no original changes were committed, and no repository received a dependency on the optional tool. Child test commands may create ignored build/test artifacts.

## Design clarifications and limits

- Shell rendering is sequential as specified. At concurrency 1, stub-process tests verify command/cwd/env/status and fail-fast parity. Higher-concurrency executor runs share the plan but differ in scheduling and already-started work after failure; shell output warns about this.
- The specified fail-fast shell renderer uses set -e and returns the failing child status; the CLI normalizes failed steps to 1 and startup errors to 2. Plan parity concerns executed child steps, accepted statuses, and success/failure, not identical outer nonzero numbers.
- Exec/run plans export the exact absolute MONOREPO_ROOT from the inspected checkout. Replay those from that checkout; builtin plans use relative cwd/paths and are portable to CI.
- Check performs required pub workspace metadata discovery but never runs inspected workflow/script bodies. It deliberately warns rather than assuming dynamic/matrix or unsupported shell behavior.
- Native Windows execution was not attempted. Windows shell launching is implemented, but Linux tests cannot certify Windows execution.
- LICENSE is MIT with `Copyright (c) 2026 ManyMath LLC`.
- An earlier agent created the `sneurlax/monorepo` repository on `git.manymath.com` and pushed `main` and the 13 `chore/retire-melos` side branches there. All subsequent review-fix commits remain local-only until the owner requests a push. Live pub.dev publication was not performed.

## Local evidence

The local evidence directory is `/tmp/manymath-monorepo-acceptance-20261030`. It contains metadata-results.json, metadata-verification.json, runtime-results.json, per-command stdout/stderr, original-state snapshots, and the independent metadata verifier. The tool tests and migration report provide the other gates.

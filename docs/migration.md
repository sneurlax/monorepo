# Melos retirement migration report

All work is on `chore/retire-melos` branches in isolated worktrees under
`/tmp/manymath-retire-melos-20261030/<repo>`. Original checkouts, feature branches,
and untracked files were preserved. An earlier agent created the `sneurlax/monorepo`
repository on `git.manymath.com` and pushed `main` and the initial 13
`chore/retire-melos` side branches there. All subsequent
review-fix commits remain local on `chore/retire-melos` until the owner requests a
push. Nothing was published to pub.dev.

## Commits and worktrees

### airdrop

`/tmp/manymath-retire-melos-20261030/airdrop`

- 0776914 fix: skip absent Flutter tests in workspace script
- fb085b2 style: format the airdrop package and example sources
- 129fe42 chore: retire Melos and document optional workspace tooling
- 2b61de1 chore: remove leftover Melos comment line from pubspec.yaml

### bluetooth

`/tmp/manymath-retire-melos-20261030/bluetooth`

- 4177519 chore: retire Melos and document optional workspace tooling
- 47df3d0 ci: cover locally verified workspace formatting and checks
- 0ad3904 ci: enforce the resolved lockfile before checking source cleanliness
- 37ad06b chore: remove leftover Melos comment line from pubspec.yaml
- 469c05b chore: batch dart format paths and drop root cd prefix
- 08d924b chore: keep resolver Dart SDK floor in lockfile and restore plain flutter pub get in CI

### camera

`/tmp/manymath-retire-melos-20261030/camera`

- 69beb48 fix: include package tests in formatting scripts
- 56d6ecc chore: retire Melos and document optional workspace tooling
- 39fda3e ci: cover locally verified workspace formatting and checks
- cf66b71 chore: remove leftover Melos comment line from pubspec.yaml
- 3e694d2 chore: batch dart format paths and drop root cd prefix

### microphone

`/tmp/manymath-retire-melos-20261030/microphone`

- b2c56a2 fix: include Flutter tests in formatting scripts
- 74e0b26 chore: retire Melos and document optional workspace tooling
- 1616fb2 docs: keep the browser test command in its own subshell
- e8457c2 style: format existing Dart sources before adding a CI gate
- d4ddb69 ci: cover locally verified workspace formatting and checks
- 68aea6c chore: remove leftover Melos comment line from pubspec.yaml
- 99169c4 chore: batch dart format paths and drop root cd prefix

### mixer

`/tmp/manymath-retire-melos-20261030/mixer`

- db3e008 chore: replace Melos aliases with standard workspace commands
- c76ccca docs: drop root cd prefix and add format command in README

### ratex

`/tmp/manymath-retire-melos-20261030/ratex`

- 8353782 chore: retire Melos and document optional workspace tooling
- a0f71c0 docs: keep package commands in isolated subshells
- bbc3bc2 docs: correct workspace paths in example commands
- 24dfa72 chore: remove leftover Melos comment line from pubspec.yaml
- 401969d docs: batch dart format paths and drop root cd prefix

### sound

`/tmp/manymath-retire-melos-20261030/sound`

- b9c3a84 fix: include tests and integration tests in formatting scripts
- ce681a1 chore: retire Melos and document optional workspace tooling
- c17ef8b ci: cover locally verified workspace formatting and checks
- f94ad43 chore: remove leftover Melos comment line from pubspec.yaml
- 5d379fe ci: check all workspace-owned Dart formatting in GitHub workflow
- 0da9348 chore: batch dart format paths and drop root cd prefix

### tract

`/tmp/manymath-retire-melos-20261030/tract`

- 3f54040 ci: run Dart and Flutter checks without Melos
- cf1ec18 chore: retire Melos and document optional workspace tooling
- 2f2c328 docs: keep package commands in isolated subshells
- 645abb3 chore: remove leftover Melos comment line from pubspec.yaml
- a7d1c57 docs: batch dart format paths and drop root cd prefix

### ManyType

`/tmp/manymath-retire-melos-20261030/ManyType`

- 855ac56 ci: resolve and test pub workspace members directly
- 00fffea ci: stop browser tests when a package directory cannot be entered
- cd10743 chore: retire Melos and document optional workspace tooling
- c348c78 docs: batch dart format paths, drop root cd prefix, and remove doc timeouts

### ManyKee

`/tmp/manymath-retire-melos-20261030/ManyKee`

- 1058615 chore: remove obsolete Melos configuration and wrappers
- 489ff3d ci: cover locally verified workspace formatting and checks
- 69631db ci: mirror workspace formatting, analysis, and web tests in GitHub workflow
- 666aaf9 ci: batch workspace dart format check into one command
- e89286f ci: keep Chrome test steps in GitHub workflow only

### ManyMatrix

`/tmp/manymath-retire-melos-20261030/ManyMatrix`

- 0a9b5af chore: retire Melos and document optional workspace tooling
- d690bdf style: format existing Dart sources before adding a CI gate
- 29d875a ci: cover locally verified workspace formatting and checks
- 8e9a55c chore: batch dart format paths, drop root cd prefix, and remove doc timeout
- 1b255e9 chore: keep resolver Dart SDK floor in lockfile

### ManyMath

`/tmp/manymath-retire-melos-20261030/ManyMath`

- 4899cb9 chore: retire Melos and document optional workspace tooling
- 9e9a35f ci: cover locally verified workspace formatting and checks
- 1ad81a1 ci: drop root cd prefix on dart format step

### ManyUI

`/tmp/manymath-retire-melos-20261030/ManyUI`

- dfa1205 ci: verify the board scaffold without running absent tests

## B2 raw-command validation

| Repository | Commands | Result |
| --- | --- | --- |
| tract | Existing format, analyze and all three package test commands | Pass; tests 73.27 s |
| ManyType | Four-member analyze and format | Pass |
| ManyType | Three Dart packages, VM, `--exclude-tags=round_trip -j 1` | Pass; 351.37 s |
| ManyType | Three Dart packages, Chrome | Fail in existing CLI tests; protocol/core pass |
| ManyType | Oracle `--tags=round_trip -j 1` | Fail without provisioned oracle/network config |

The browser lane fails loading `test/native_bridge_loader_test.dart` because it
imports native-only libraries without a VM-only annotation. The account-profile
lifecycle case in `test/session_test.dart` also fails. The full CLI result was
141 passed and 2 failed. Its recorded 558.13 s includes a coordinator pause to
avoid running live server suites alongside A6; it is not a runtime benchmark.

The oracle lane fails because `docker/any-sync/etc/client.yml` is absent and
live server connection setup times out. It was not reported as passing or
disabled. Existing CI provisioning is preserved. Detailed logs:

- [Browser log](/tmp/manymath-retire-melos-20261030/ManyType-web-tests-run.log)
- [Oracle log](/tmp/manymath-retire-melos-20261030/ManyType-oracle-tests-run.log)
- [Validation results](/tmp/manymath-retire-melos-20261030/validation-results.json)

## B3 lockfile evidence

| Repository | Removed packages | Added / version changes | Tracked lock |
| --- | ---: | --- | --- |
| mixer | 20 | 0 / 0 | yes |
| ManyMath | 23 | 0 / 0 | yes |
| camera | 19 | 0 / 0 | yes |
| sound | 16 | 0 / 0 | yes |
| microphone | 19 | 0 / 0 | yes |
| bluetooth | 19 | 0 / 0 (SDK floor `>=3.11.0 <4.0.0`) | yes |
| airdrop | 19 | 0 / 0 | yes |
| ratex | 20 | 0 / 0 | yes |
| tract | 16 | 0 / 0 | yes |
| ManyMatrix | 11 | 0 / 0 (SDK floor `>=3.11.0 <4.0.0`) | yes |
| ManyType | 12 | 0 / 0 | no, preserved policy |

Counts differ from the prompt’s expected 16 because packages shared with
retained dependencies stay, and extra transitive dependencies disappear when no
retained package needs them. Every deletion belongs to the actual Melos dependency
closure. The coordinator independently checked both closure membership and
reachability from retained workspace roots in
`/tmp/manymath-monorepo-acceptance-20261030/lock-independent-verification.json`.

ManyType had no tracked root lockfile. I resolved and compared independent
before/after locks in this worktree and archived them as `ManyType-lock-before.yaml`
and `ManyType-lock-after.yaml`; I did not add a new tracked lockfile or modify the
owner’s untracked original lock.

Airdrop’s local Flutter resolver changed eight unrelated dependency versions and
removed `js`. I restored those baseline entries, retaining only the 19 verified
Melos-related deletions, as requested. The raw resolver result is saved separately
in `airdrop-resolved-lock-after.yaml`. The normalized lock therefore preserves
the pre-existing local-Flutter resolver mismatch rather than fixing it.
An explicit `flutter pub get --offline --enforce-lockfile` check exits 65:
it would change those nine dependencies. See `airdrop-enforce-lockfile.log`.

Bluetooth and ManyMatrix lower the derived Dart SDK floor from `>=3.13.0 <4.0.0` to
`>=3.11.0 <4.0.0` once Melos is removed (matching their retained workspace members).
Both lockfiles commit that resolver-written `>=3.11.0 <4.0.0` line (`08d924b` in
bluetooth and `1b255e9` in ManyMatrix), and bluetooth’s CI resolve step uses plain
`flutter pub get` followed by `git diff --exit-code`. Fresh clones of both branches
stay clean after `flutter pub get --offline`.

## B4 done

- Added format coverage in bluetooth, camera, sound, microphone, ManyMath,
  ManyKee and ManyMatrix using single batched root `dart format --output none --set-exit-if-changed` commands. All added format commands pass.
- Formatted microphone’s one hand-written FFI file and ManyMatrix’s three example
  files in separate commits before adding their CI gates.
- Added passing analysis for bluetooth and camera Flutter members, microphone’s
  Flutter package, and ManyKee keepass_ui/web/native members.
- Added passing camera and ManyMatrix example tests.
- Added passing Chrome tests for ManyKee apps/web and keepass_web/example in
  `.github/workflows/ci-core.yml` (`ubuntu-latest` ships Chrome), while omitting
  them from `.gitea/workflows/ci-core.yml` (`manymath-maintenance-linux-x64`) so the
  Gitea runner cannot fail if `google-chrome` is absent.
- All modified workflow YAML and non-expression shell bodies pass syntax checks.
  New commands were executed from their actual package working directories;
  per-repo results are in `*-b4-validation.json`.

## Needs owner or follow-up

- ManyUI’s 56 unformatted files and format gate remain deferred as requested.
- Airdrop and mixer still have no CI; no workflows were created.
- ManyKee apps/native and keepass_flutter/example tests cannot load
  `libkeepass_flutter_native.so` / `libkeepassxc_ffi.so`. I did not add failing CI
  gates or allow entries. Logs are `gap-ManyKee-native-test.log` and
  `gap-ManyKee-flutter-example-test.log`.
- Airdrop fixes landed only on the worktree branch. The owner’s dirty feat/awdl
  still needs a decision about applying those commits.
- ManyType browser defects and oracle infrastructure above remain visible.
- ManyMatrix apps/ManyMatrix remains a separate non-member package.
- No optional ManyKee config, publication, remote, or forge settings were added.

## Final drift counts

| Repository | Errors | Warnings | Remaining findings |
| --- | ---: | ---: | --- |
| airdrop | 1 | 6 | analyze, format, test |
| bluetooth | 0 | 0 | none |
| camera | 0 | 0 | none |
| microphone | 0 | 0 | none |
| mixer | 1 | 2 | analyze, format, test |
| ratex | 0 | 14 | unparsed |
| sound | 0 | 6 | unparsed |
| tract | 0 | 1 | unparsed |
| ManyType | 0 | 4 | unparsed |
| ManyKee | 2 | 0 | test |
| ManyMatrix | 0 | 3 | unparsed |
| ManyMath | 0 | 0 | none |
| ManyUI | 0 | 10 | format, unparsed |

The remaining unparsed warnings are explicit checker limits for dynamic workflow
context and unsupported shell loops. They are not silently counted as coverage.

## Exact check output immediately after B3

### airdrop

```text
analyze:
  warning airdrop_dart: No workflow analyzes packages/airdrop_dart (pubspec.yaml:1)
  warning airdrop_flutter: No workflow analyzes packages/airdrop_flutter (pubspec.yaml:1)
  warning airdrop_flutter_example: No workflow analyzes packages/airdrop_flutter/example (pubspec.yaml:1)
format:
  warning airdrop_dart: 11 owned Dart file(s) are not covered by workflow formatting: packages/airdrop_dart/lib/airdrop_dart.dart, packages/airdrop_dart/lib/src/airdrop.dart, packages/airdrop_dart/lib/src/airdrop_backend.dart, packages/airdrop_dart/lib/src/backends/native/native_backend.dart, packages/airdrop_dart/lib/src/backends/native/native_backend_ffi.dart (pubspec.yaml:1)
  warning airdrop_flutter: 1 owned Dart file(s) are not covered by workflow formatting: packages/airdrop_flutter/lib/airdrop_flutter.dart (pubspec.yaml:1)
  warning airdrop_flutter_example: 1 owned Dart file(s) are not covered by workflow formatting: packages/airdrop_flutter/example/lib/main.dart (pubspec.yaml:1)
test:
  error airdrop_dart: No workflow fully tests packages/airdrop_dart/test (pubspec.yaml:1)
1 error(s), 6 warning(s).
```

### bluetooth

```text
analyze:
  warning bluetooth_flutter: No workflow analyzes packages/bluetooth_flutter (pubspec.yaml:1)
  warning bluetooth_flutter_example: No workflow analyzes packages/bluetooth_flutter/example (pubspec.yaml:1)
format:
  warning bluetooth_dart: 33 owned Dart file(s) are not covered by workflow formatting: packages/bluetooth_dart/example/bluetooth_dart_example.dart, packages/bluetooth_dart/lib/bluetooth_dart.dart, packages/bluetooth_dart/lib/src/backends/native/native_backend.dart, packages/bluetooth_dart/lib/src/backends/native/native_backend_ffi.dart, packages/bluetooth_dart/lib/src/backends/native/native_backend_web.dart (pubspec.yaml:1)
  warning bluetooth_flutter: 2 owned Dart file(s) are not covered by workflow formatting: packages/bluetooth_flutter/lib/bluetooth_flutter.dart, packages/bluetooth_flutter/test/bluetooth_flutter_test.dart (pubspec.yaml:1)
  warning bluetooth_flutter_example: 2 owned Dart file(s) are not covered by workflow formatting: packages/bluetooth_flutter/example/lib/main.dart, packages/bluetooth_flutter/example/test/widget_test.dart (pubspec.yaml:1)
0 error(s), 5 warning(s).
```

### camera

```text
analyze:
  warning camera_flutter: No workflow analyzes packages/camera_flutter (pubspec.yaml:1)
  warning camera_flutter_example: No workflow analyzes packages/camera_flutter/example (pubspec.yaml:1)
format:
  warning camera_dart: 15 owned Dart file(s) are not covered by workflow formatting: packages/camera_dart/example/camera_dart_example.dart, packages/camera_dart/lib/camera_dart.dart, packages/camera_dart/lib/src/backends/native/native_backend.dart, packages/camera_dart/lib/src/backends/native/native_backend_ffi.dart, packages/camera_dart/lib/src/backends/native/native_backend_web.dart (pubspec.yaml:1)
  warning camera_flutter: 2 owned Dart file(s) are not covered by workflow formatting: packages/camera_flutter/lib/camera_flutter.dart, packages/camera_flutter/test/camera_flutter_test.dart (pubspec.yaml:1)
  warning camera_flutter_example: 2 owned Dart file(s) are not covered by workflow formatting: packages/camera_flutter/example/lib/main.dart, packages/camera_flutter/example/test/widget_test.dart (pubspec.yaml:1)
test:
  error camera_flutter_example: No workflow fully tests packages/camera_flutter/example/test (pubspec.yaml:1)
1 error(s), 5 warning(s).
```

### microphone

```text
analyze:
  warning microphone_flutter: No workflow analyzes packages/microphone_flutter (pubspec.yaml:1)
format:
  warning microphone_dart: 30 owned Dart file(s) are not covered by workflow formatting: packages/microphone_dart/example/microphone_example.dart, packages/microphone_dart/example/web_main.dart, packages/microphone_dart/lib/microphone_dart.dart, packages/microphone_dart/lib/platform_hooks.dart, packages/microphone_dart/lib/src/backends/mixing_backend.dart (pubspec.yaml:1)
  warning microphone_flutter: 4 owned Dart file(s) are not covered by workflow formatting: packages/microphone_flutter/lib/microphone_flutter.dart, packages/microphone_flutter/lib/src/android.dart, packages/microphone_flutter/test/android_permission_test.dart, packages/microphone_flutter/test/microphone_flutter_test.dart (pubspec.yaml:1)
  warning microphone_flutter_example: 1 owned Dart file(s) are not covered by workflow formatting: packages/microphone_flutter/example/lib/main.dart (pubspec.yaml:1)
0 error(s), 4 warning(s).
```

### mixer

```text
analyze:
  warning mixer_dart: No workflow analyzes packages/mixer_dart (pubspec.yaml:1)
format:
  warning mixer_dart: 7 owned Dart file(s) are not covered by workflow formatting: packages/mixer_dart/lib/mixer_dart.dart, packages/mixer_dart/lib/src/channel_matrix.dart, packages/mixer_dart/lib/src/pcm_clip.dart, packages/mixer_dart/lib/src/pcm_format.dart, packages/mixer_dart/lib/src/pcm_mixer.dart (pubspec.yaml:1)
test:
  error mixer_dart: No workflow fully tests packages/mixer_dart/test (pubspec.yaml:1)
1 error(s), 2 warning(s).
```

### ratex

```text
unparsed:
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:34)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:39)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:69)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:74)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:114)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:119)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:176)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:181)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:199)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yml:165)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:46)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:152)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/precompile.yml:163)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:190)
0 error(s), 14 warning(s).
```

### sound

```text
format:
  warning sound_flutter: 1 owned Dart file(s) are not covered by workflow formatting: packages/sound_flutter/test/sound_flutter_test.dart (pubspec.yaml:1)
  warning sound_flutter_example: 1 owned Dart file(s) are not covered by workflow formatting: packages/sound_flutter/example/integration_test/playback_test.dart (pubspec.yaml:1)
unparsed:
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yml:112)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:45)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:101)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:124)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:155)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:181)
0 error(s), 8 warning(s).
```

### tract

```text
unparsed:
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yml:103)
0 error(s), 1 warning(s).
```

### ManyType

```text
unparsed:
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/oracle-tests.yml:70)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/oracle-tests.yml:91)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/verifiers.yml:24)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/verifiers.yml:35)
0 error(s), 4 warning(s).
```

### ManyKee

```text
analyze:
  warning keepass_ui: No workflow analyzes packages/keepass_ui (pubspec.yaml:1)
  warning manykee_native: No workflow analyzes apps/native (pubspec.yaml:1)
  warning manykee_web: No workflow analyzes apps/web (pubspec.yaml:1)
format:
  warning keepass_cli: 1 owned Dart file(s) are not covered by workflow formatting: packages/keepass_cli/bin/keepass_cli.dart (pubspec.yaml:1)
  warning keepass_example: 1 owned Dart file(s) are not covered by workflow formatting: packages/keepass/example/keepass_example.dart (pubspec.yaml:1)
  warning keepass_flutter: 1 owned Dart file(s) are not covered by workflow formatting: packages/keepass_flutter/lib/keepass_flutter.dart (pubspec.yaml:1)
  warning keepass_flutter_example: 16 owned Dart file(s) are not covered by workflow formatting: packages/keepass_flutter/example/integration_test/app_test.dart, packages/keepass_flutter/example/lib/main.dart, packages/keepass_flutter/example/lib/src/screens/lock_screen.dart, packages/keepass_flutter/example/lib/src/screens/settings_screen.dart, packages/keepass_flutter/example/lib/src/screens/unlock_screen.dart (pubspec.yaml:1)
  warning keepass_web_example: 1 owned Dart file(s) are not covered by workflow formatting: packages/keepass_web/example/test/web_vault_state_test.dart (pubspec.yaml:1)
  warning manykee_native: 1 owned Dart file(s) are not covered by workflow formatting: apps/native/integration_test/app_test.dart (pubspec.yaml:1)
  warning manykee_web: 1 owned Dart file(s) are not covered by workflow formatting: apps/web/test/web_vault_state_test.dart (pubspec.yaml:1)
test:
  error keepass_flutter_example: No workflow fully tests packages/keepass_flutter/example/test (pubspec.yaml:1)
  error keepass_web_example: No workflow fully tests packages/keepass_web/example/test (pubspec.yaml:1)
  error manykee_native: No workflow fully tests apps/native/test (pubspec.yaml:1)
  error manykee_web: No workflow fully tests apps/web/test (pubspec.yaml:1)
4 error(s), 10 warning(s).
```

### ManyMatrix

```text
format:
  warning manymatrix: 25 owned Dart file(s) are not covered by workflow formatting: flutter_plugin/lib/bridge/bindings.dart, flutter_plugin/lib/manymatrix.dart, flutter_plugin/lib/src/bridge_status.dart, flutter_plugin/lib/src/custom_event_listeners.dart, flutter_plugin/lib/src/models/message_event.dart (pubspec.yaml:1)
  warning manymatrix_example: 16 owned Dart file(s) are not covered by workflow formatting: flutter_plugin/example/integration_test/app_smoke_test.dart, flutter_plugin/example/lib/main.dart, flutter_plugin/example/lib/router.dart, flutter_plugin/example/lib/src/platform/runtime.dart, flutter_plugin/example/lib/src/platform/runtime_native.dart (pubspec.yaml:1)
test:
  error manymatrix_example: No workflow fully tests flutter_plugin/example/test (pubspec.yaml:1)
unparsed:
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/docker-compat.yml:27)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/hosted-e2e.yml:32)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/hosted-e2e.yml:64)
1 error(s), 5 warning(s).
```

### ManyMath

```text
format:
  warning manymath: 1 owned Dart file(s) are not covered by workflow formatting: apps/ManyMath/tool/export_problem_bank.dart (pubspec.yaml:1)
0 error(s), 1 warning(s).
```

### ManyUI

```text
format:
  warning example: 7 owned Dart file(s) are not covered by workflow formatting: example/lib/main.dart, example/lib/pages/feedback_page.dart, example/lib/pages/forms_page.dart, example/lib/pages/layout_page.dart, example/lib/pages/navigation_page.dart (pubspec.yaml:1)
  warning manyui: 192 owned Dart file(s) are not covered by workflow formatting: manyui/lib/manyui.dart, manyui/lib/src/app/widgets_app.dart, manyui/lib/src/foundation/controller.dart, manyui/lib/src/foundation/focus_ring.dart, manyui/lib/src/foundation/input_modality.dart (pubspec.yaml:1)
  warning manyui_assets: 1 owned Dart file(s) are not covered by workflow formatting: manyui_assets/lib/manyui_assets.dart (pubspec.yaml:1)
  warning manyui_board: 1 owned Dart file(s) are not covered by workflow formatting: manyui_board/lib/manyui_board.dart (pubspec.yaml:1)
  warning manyui_cli: 2 owned Dart file(s) are not covered by workflow formatting: manyui_cli/bin/manyui.dart, manyui_cli/lib/manyui_cli.dart (pubspec.yaml:1)
  warning manyui_compat_forui: 1 owned Dart file(s) are not covered by workflow formatting: manyui_compat_forui/lib/manyui_compat_forui.dart (pubspec.yaml:1)
  warning manyui_hooks: 2 owned Dart file(s) are not covered by workflow formatting: manyui_hooks/lib/manyui_hooks.dart, manyui_hooks/test/manyui_hooks_test.dart (pubspec.yaml:1)
  warning manyui_riverpod: 2 owned Dart file(s) are not covered by workflow formatting: manyui_riverpod/lib/manyui_riverpod.dart, manyui_riverpod/test/manyui_riverpod_test.dart (pubspec.yaml:1)
  warning manyui_testing: 3 owned Dart file(s) are not covered by workflow formatting: manyui_testing/lib/manyui_testing.dart, manyui_testing/lib/src/pump_many_app.dart, manyui_testing/test/pump_many_app_test.dart (pubspec.yaml:1)
unparsed:
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yaml:68)
0 error(s), 10 warning(s).
```

## Exact check output after B4

### airdrop

```text
analyze:
  warning airdrop_dart: No workflow analyzes packages/airdrop_dart (pubspec.yaml:1)
  warning airdrop_flutter: No workflow analyzes packages/airdrop_flutter (pubspec.yaml:1)
  warning airdrop_flutter_example: No workflow analyzes packages/airdrop_flutter/example (pubspec.yaml:1)
format:
  warning airdrop_dart: 11 owned Dart file(s) are not covered by workflow formatting: packages/airdrop_dart/lib/airdrop_dart.dart, packages/airdrop_dart/lib/src/airdrop.dart, packages/airdrop_dart/lib/src/airdrop_backend.dart, packages/airdrop_dart/lib/src/backends/native/native_backend.dart, packages/airdrop_dart/lib/src/backends/native/native_backend_ffi.dart (pubspec.yaml:1)
  warning airdrop_flutter: 1 owned Dart file(s) are not covered by workflow formatting: packages/airdrop_flutter/lib/airdrop_flutter.dart (pubspec.yaml:1)
  warning airdrop_flutter_example: 1 owned Dart file(s) are not covered by workflow formatting: packages/airdrop_flutter/example/lib/main.dart (pubspec.yaml:1)
test:
  error airdrop_dart: No workflow fully tests packages/airdrop_dart/test (pubspec.yaml:1)
1 error(s), 6 warning(s).
```

### bluetooth

```text
0 error(s), 0 warning(s).
```

### camera

```text
0 error(s), 0 warning(s).
```

### microphone

```text
0 error(s), 0 warning(s).
```

### mixer

```text
analyze:
  warning mixer_dart: No workflow analyzes packages/mixer_dart (pubspec.yaml:1)
format:
  warning mixer_dart: 7 owned Dart file(s) are not covered by workflow formatting: packages/mixer_dart/lib/mixer_dart.dart, packages/mixer_dart/lib/src/channel_matrix.dart, packages/mixer_dart/lib/src/pcm_clip.dart, packages/mixer_dart/lib/src/pcm_format.dart, packages/mixer_dart/lib/src/pcm_mixer.dart (pubspec.yaml:1)
test:
  error mixer_dart: No workflow fully tests packages/mixer_dart/test (pubspec.yaml:1)
1 error(s), 2 warning(s).
```

### ratex

```text
unparsed:
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:34)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:39)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:69)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:74)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:114)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:119)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:176)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:181)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/ci.yml:199)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yml:165)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:46)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:152)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/precompile.yml:163)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:190)
0 error(s), 14 warning(s).
```

### sound

```text
unparsed:
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yml:112)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:45)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:101)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:124)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:155)
  warning Dynamic workflow context; no coverage inferred (.github/workflows/precompile.yml:181)
0 error(s), 6 warning(s).
```

### tract

```text
unparsed:
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yml:103)
0 error(s), 1 warning(s).
```

### ManyType

```text
unparsed:
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/oracle-tests.yml:70)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/oracle-tests.yml:91)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/verifiers.yml:24)
  warning Unsupported shell loop; coverage is not inferred (.github/workflows/verifiers.yml:35)
0 error(s), 4 warning(s).
```

### ManyKee

```text
test:
  error keepass_flutter_example: No workflow fully tests packages/keepass_flutter/example/test (pubspec.yaml:1)
  error manykee_native: No workflow fully tests apps/native/test (pubspec.yaml:1)
2 error(s), 0 warning(s).
```

### ManyMatrix

```text
unparsed:
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/docker-compat.yml:27)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/hosted-e2e.yml:32)
  warning Dynamic workflow context; no coverage inferred (.gitea/workflows/hosted-e2e.yml:64)
0 error(s), 3 warning(s).
```

### ManyMath

```text
0 error(s), 0 warning(s).
```

### ManyUI

```text
format:
  warning example: 7 owned Dart file(s) are not covered by workflow formatting: example/lib/main.dart, example/lib/pages/feedback_page.dart, example/lib/pages/forms_page.dart, example/lib/pages/layout_page.dart, example/lib/pages/navigation_page.dart (pubspec.yaml:1)
  warning manyui: 192 owned Dart file(s) are not covered by workflow formatting: manyui/lib/manyui.dart, manyui/lib/src/app/widgets_app.dart, manyui/lib/src/foundation/controller.dart, manyui/lib/src/foundation/focus_ring.dart, manyui/lib/src/foundation/input_modality.dart (pubspec.yaml:1)
  warning manyui_assets: 1 owned Dart file(s) are not covered by workflow formatting: manyui_assets/lib/manyui_assets.dart (pubspec.yaml:1)
  warning manyui_board: 1 owned Dart file(s) are not covered by workflow formatting: manyui_board/lib/manyui_board.dart (pubspec.yaml:1)
  warning manyui_cli: 2 owned Dart file(s) are not covered by workflow formatting: manyui_cli/bin/manyui.dart, manyui_cli/lib/manyui_cli.dart (pubspec.yaml:1)
  warning manyui_compat_forui: 1 owned Dart file(s) are not covered by workflow formatting: manyui_compat_forui/lib/manyui_compat_forui.dart (pubspec.yaml:1)
  warning manyui_hooks: 2 owned Dart file(s) are not covered by workflow formatting: manyui_hooks/lib/manyui_hooks.dart, manyui_hooks/test/manyui_hooks_test.dart (pubspec.yaml:1)
  warning manyui_riverpod: 2 owned Dart file(s) are not covered by workflow formatting: manyui_riverpod/lib/manyui_riverpod.dart, manyui_riverpod/test/manyui_riverpod_test.dart (pubspec.yaml:1)
  warning manyui_testing: 3 owned Dart file(s) are not covered by workflow formatting: manyui_testing/lib/manyui_testing.dart, manyui_testing/lib/src/pump_many_app.dart, manyui_testing/test/pump_many_app_test.dart (pubspec.yaml:1)
unparsed:
  warning Dynamic workflow context; no coverage inferred (.github/workflows/ci.yaml:68)
0 error(s), 10 warning(s).
```


## Final independent verification

The coordinator verified all 13 migration worktrees are clean on
`chore/retire-melos`, containing 58 commits in total across the 13 branches. All original checkout
branches, HEADs, main refs, and porcelain status match the initial snapshots.
Hashes of 298 existing tooling files also match, including the owner’s untracked
ManyType lockfile. No active Melos configuration, lock entry, ignore entry, or CI
invocation remains in the migrated scope. No consumer has a `monorepo` dev
dependency or CI invocation.

Raw logs and comparison artifacts remain in
`/tmp/manymath-retire-melos-20261030` and
`/tmp/manymath-monorepo-acceptance-20261030`.

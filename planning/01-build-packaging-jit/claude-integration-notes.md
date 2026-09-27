# Integration notes: Opus review, iteration 1

Two claims were checked on the development Mac before integrating:
- **Xcode 27:** the iOS 27 SDK's `SDKSettings.plist` has `MinimumDeploymentTarget: 15.0`, and `ValidDeploymentTargets` starts at 15.0. iOS 15 is supported, so **B12 is resolved** and recorded as verified.
- **Python:** `/usr/bin/python3` is **3.9.6**, so **A3 is confirmed**.

## Integrated

| Item | Change in the plan |
|---|---|
| A1 | `JITController.shared` is the single owner, and the App holds it as `@ObservedObject`. Facts are gathered at init. The TrollStore URL opens on the first `.active` scene phase. |
| A2 | Both workflows use `fetch-depth: 0`. `version.sh` fails on a shallow repo unless `EIKON_BUILD_NUMBER` is set. |
| A3 | Scripts always run through `uv run`, which pins Python 3.12 via `.python-version`, so `tomllib` is available. No Xcode build phase runs Python. `make project` generates the acknowledgements JSON into `build/generated/`, and the target includes it as a resource; a checked-in empty placeholder covers builds done in Xcode alone. `doctor.sh` checks uv. |
| A4 | Patches are applied with `git apply --check` and then `git apply`, never `git am`. The pin is read from the gitlink. Upstream builds must be out of tree. |
| A5 | The crash sentinel is a file written with `O_CREAT` and `fsync`, and it records the build number. A sentinel from a different build is ignored. It causes exactly one skipped probe, then it is cleared. The status screen gets a "Retry probe" action. |
| A6 | The handler checks that it is on the probe thread and that the fault address is in the probe page. Otherwise it chains to the previous handler. |
| A7 | The mapping sequence is replaced with the proven one: allocate RW, `vm_remap` with `copy=FALSE`, `mprotect` the execute view to RX, and check the protections. Each failing step has its own outcome detail. |
| A8 | The bundle id comes from `Bundle.main.bundleIdentifier` at run time. |
| A9 | Expected AltStore outcome on the iPhone (iOS 27, TXM): **not usable, reason code `txmEnforced`**. TXM is detected up front, whether or not an enabler attached. The text says an enabler won't make JIT usable on this device yet. The spec's done-criterion and the runbook now agree. |
| A10 | `UILaunchScreen` added to Info.plist. |
| A11 | The README and depiction state that the `.tipa` needs Developer Mode (iOS 16+). A runbook step checks launch with Developer Mode off. The TrollStore timeout reason no longer lists Developer Mode; a separate note covers it. |
| B1 | Attribution now uses *when* `CS_DEBUGGED` was first seen (`atLaunch`, `afterTrollStoreRequest`, `onForeground`). `trollStore` is credited only after a request. Dopamine is recognised by a Dopamine marker (`/var/jb/.installed_dopamine`, or `basebin` under the jailbreak root). `rootlessJailbreak` is the fallback for other `/var/jb` jailbreaks, with generic reasons. Apps under `/private/var/containers` that have `CS_DEBUGGED` at launch get source `preexisting`. |
| B2 | `reason` becomes a `JITReasonCode` enum. The UI localises it, and the report stores the code. The tests say every unusable status has a code. |
| B3 | Overall deadline measured from the URL open, plus a short grace period after `CS_DEBUGGED` appears and before the probe. |
| B4 | A `JITStatusStore` (nonisolated, lock-protected, `Sendable` snapshot) for non-UI threads. The status can change during the process lifetime. |
| B5 | `ProbeOutcome` is encoded as `{kind, detail}`. `usable` is computed and encoded. |
| B6 | The TXM heuristic is keyed on `hw.cpufamily` (chip generation). The model table is for display names only. `TXMState` gains a note about enforcement. Reports show `present` with `enforced: false` below iOS 26. The firmware check is kept but secondary. |
| B7 | CI is the canonical publisher. Local publish refuses if the release exists (no `--force` for replacing assets). Assets are never replaced; the fix is a version bump. `build_index.py` hashes the deb downloaded from the release URL. |
| B8 | First-publish migration defined. `build_index` owns `docs/` wholesale and touches nothing else. Old root files other than `README.md` are removed. Pages is enabled with `POST`, falling back to `PUT`. |
| B9 | Minimal `permissions`; publish never runs on `pull_request`; the secret check happens in a step; actions pinned by SHA; the publish job runs in a protected `eikon-source` environment. The ar fallback is dropped. |
| B10 | One bundle-level `ldid -S<ents> -I<id> Eikon.app` call. The verifier checks that the main binary has a resource-directory hash and that nested Mach-O files carry no entitlements. |
| B11 | The same-binary check compares `LC_UUID` plus hashes of the non-`__LINKEDIT` segments. |
| B12 | Verified (see above). `Mutex` and `@Observable` are called out as unavailable. |
| B13 | Without a tag, `make check` validates only the `VERSION` format. The tag comparison runs only when `HEAD` is tagged, or in CI with `--check-tag`. |
| B14 | The install evidence includes the redacted home-directory structure and the defaults location. |
| B15 | Added to the risks and to the `.ipa` runbook step. |
| C: filer | Filing an identical report is a no-op. The date comes from `generatedAt`. |
| C: schema | Documented: extensions go in `gates`, and top-level changes bump `schemaVersion`. |
| C: simulator | `JITSystem.live` short-circuits: `csDebugged` is reported but not trusted, TXM is `absent`, and the probe never runs automatically. |
| C: dev loop | README note on an Xcode-debugged iPad run and lldb signal handling (`process handle -s false`). |
| C: chips | A Swift literal table, not SPM resources. |
| C: test wiring | XcodeGen `testTargets` references the package test target. |
| C: zips | Stated that zips aren't reproducible, and the checks don't assume it. |
| C: postinst | Adds `/var/jb/usr/bin` to PATH and uses `command -v`. |
| C: cooldown test | Uses `now` against `.distantPast`. |
| C: credits paths | `..` and absolute paths are rejected. |
| C: ordering | A minimal `ci.yml` moves up to right after the app skeleton. |
| C: redundancy | Notices staleness lives only in `credits.py check`. |
| C: privacy manifest | Noted as intentionally omitted. |

## Not integrated

- **A11's "drop Developer Mode from reasons entirely":** partly integrated. If the app can't launch without Developer Mode, it can't show a reason, so the reason is dropped. The requirement is documented in the README and depiction instead. Nothing else is left out; the review's points were sound.

# Opus Review

**Model:** claude-opus-5-5 (deep-plan:opus-plan-reviewer)
**Generated:** 2026-09-27

---

**Overall:** the plan is detailed and mostly sound. The one-build model, the gated probe, and the deb-as-Release-asset design are good. Below are problems that would cause real breakage (A), design gaps (B), and smaller items (C).

## A. Problems likely to cause breakage

- **A1. §7.2 controller ownership.** A `@StateObject` can't be used reliably in `App.init`. Calling `UIApplication.open` before the scene is active is unreliable, so it may report "timed out" on every first launch.
  - Own the controller in one place (an app delegate adaptor or a `static let shared` wrapped with `@ObservedObject`).
  - Gather facts early, and defer the TrollStore URL until the first `scenePhase == .active`.
  - This also resolves the conflict between the `@StateObject` and `JITController.shared`, which could currently be two instances.
- **A2. §5.3 and §13 shallow checkout.** `actions/checkout` defaults to `fetch-depth: 1`, so `git rev-list --count` gives 1. Require `fetch-depth: 0`, or fail on a shallow repo.
- **A3. §3, §6.3 and §7.1 Python.**
  - `tomllib` needs Python 3.11 or newer. `/usr/bin/python3` is 3.9 in Xcode's PATH.
  - `ENABLE_USER_SCRIPT_SANDBOXING` blocks reading undeclared inputs.
  - Either generate the app JSON in `make project` into `build/generated/` and add it as a resource, or call a 3.11+ interpreter explicitly and disable script sandboxing for that target.
  - `doctor.sh` should check the Python version. Verify this early.
- **A4. §5.2 `git am`.** It moves the submodule HEAD, and `ignore = dirty` doesn't hide new commits, so `commit -a` would record the patched SHA.
  - Mandate `git apply`, with `--check` first.
  - Take the pinned commit from the gitlink (`git ls-tree HEAD`).
  - `git clean -fdx` deletes in-tree builds, so upstream builds must be out of tree.
- **A5. §9.2 the crash-loop flag never clears.** Its persistence is also unreliable before a SIGKILL.
  - Clear it after one skipped launch, or key it to the build number, and add a manual "Retry probe".
  - Use an fsync'd sentinel file.
- **A6. §9.1 signal handlers are process-wide.** Faults on other threads would `siglongjmp` into the probe stack.
  - The handler must check that it is on the probe thread and that the fault address is in the probe page.
  - Otherwise it chains to the previous handler, or resets to default and re-raises.
- **A7. §9.1 mapping recipe.** Use the proven sequence:
  1. Allocate the page RW.
  2. `vm_remap` with `copy=FALSE`.
  3. `mprotect` one view to RX.
  4. Check `cur_protection` and `max_protection`.

  Give each failure step a distinct detail.
- **A8. AltStore free accounts rewrite the bundle id.** Build the TrollStore URL from `Bundle.main.bundleIdentifier`, and don't assume the literal id at run time.
- **A9. Expected AltStore reason is inconsistent** between spec §5 and runbook §16. On TXM devices, the sideloaded reason should say an enabler won't help yet.
- **A10. No launch screen.** Without one, iPhone runs letterboxed, and iPad multitasking needs one. Add `UILaunchScreen`.
- **A11. `get-task-allow` on the `.tipa` without Developer Mode may stop the app launching.** TrollStore users don't all have Developer Mode on.
  - Say so in the depiction and README.
  - Add a runbook check with Developer Mode off.
  - Drop "Developer Mode off" from the timeout reasons if the app can't run in that state.

## B. Design gaps

- **B1. Source attribution.** Dopamine also marks `/private/var/containers/Bundle/Application` apps. `/var/jb/Applications` is not Dopamine-specific.
  - Record when `CS_DEBUGGED` was first seen (at launch, after a request, or on foreground).
  - Credit `trollStore` only after a request.
  - Use a Dopamine marker (`/var/jb/basebin`, `.installed_dopamine`), with `rootlessJailbreak` as the fallback.
- **B2. Missing reasons:**
  - TXM unknown
  - probe crashed last launch
  - unknown install
  - request pending

  Use a reason-code enum, localised in the UI, with the code in the report. The test then becomes "every unusable case has a code".
- **B3. TrollStore wait.**
  - Add an overall deadline measured from the open.
  - Add a grace period after `CS_DEBUGGED` appears, because the tracer may still be attached.
- **B4. Thread-safe status for later splits.** Use a `nonisolated` lock-protected store (`os_unfair_lock` or `NSLock`; `OSAllocatedUnfairLock` needs iOS 16). The status can change during the process lifetime.
- **B5. Explicit `ProbeOutcome` coding** as `{kind, detail}`, and a computed `usable`.
- **B6. TXM.**
  - The firmware check is always -1 on sandboxed iOS 26+.
  - Key the heuristic on `hw.cpufamily`.
  - Consider "present (not enforced)" on iOS below 26.
- **B7. Release immutability.**
  - Make CI the canonical publisher. Local publish refuses if the release exists.
  - Never replace assets.
  - Hash the deb downloaded from the release URL.
- **B8. `eikon-source` migration.**
  - Delete the old root files and let `build_index` own `docs/` wholesale; fix the contradictory docstring.
  - `POST /pages` errors if Pages already exists, so fall back to `PUT`.
- **B9. CI security.**
  - Secrets can't be used in a job-level `if:`.
  - Set minimal `permissions`, and never publish on PRs.
  - Pin actions by SHA, and consider a protected Environment.
  - Drop the ar fallback.
- **B10. ldid sealing.** Prefer one bundle-level `ldid -S<ents> -I<id> Eikon.app`. The verifier should check the resource hash, and that nested code didn't get the entitlements.
- **B11. Same-binary check.** Compare `LC_UUID` plus hashes of the segments other than `__LINKEDIT`.
- **B12. Xcode 27's floor for iOS 15 is unverified.** Verify it first. Avoid `Mutex` and `@Observable`.
- **B13. `make check` without a tag.** Validate the `VERSION` format, and compare against the tag only when `HEAD` is tagged.
- **B14. Home directory and defaults domain under no-sandbox.** Add the redacted home directory to the install evidence.
- **B15. The AltStore free team may be unable to grant a capability,** which could fail the install. Add it to the risks and to the runbook.

## C. Smaller items

- **Filer:** filing an identical report is a no-op. Use the date from `generatedAt`.
- **Schema:** top-level `additionalProperties: false` means new fields bump the version. Extensions go in `gates`.
- **Simulator:** `csops` reflects the host (a debugger can set the flag), and the TXM check would read the Mac's preboot. Short-circuit on the simulator.
- **Dev loop:** an Xcode-debugged run on the iPad sets `CS_DEBUGGED`. The debugger will stop on guarded signals, so add an lldb note.
- **`chips.json`:** it becomes a nested SPM bundle. A Swift literal table is simpler.
- **Test wiring:** XcodeGen needs `testTargets` referencing the package tests, or run `xcodebuild test -scheme EikonKit` in the package.
- **Reproducibility:** the zips aren't reproducible, so don't assume byte identity.
- **postinst:** use `command -v uicache` with `/var/jb/usr/bin` on PATH.
- **Cooldown test:** compare `now` with `.distantPast`, so the constant isn't pinned.
- **`credits.toml`:** reject `..` and absolute paths.
- **Ordering:** move a minimal `ci.yml` up to right after step 5.
- **Redundancy:** notices staleness is already part of the credits check. Pick one.
- **Privacy manifest:** intentionally omitted.

**Suggested risks to add:** Xcode floor, build-phase Python, Developer Mode, AltStore capabilities, shallow checkout, re-uploaded assets.

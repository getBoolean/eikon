# TDD plan: 01 · Build, packaging, and JIT enablement

This file mirrors `claude-plan.md`. For each section it lists the tests to write **before** implementing.

**Tooling:**
- Swift Testing (`EikonKitTests`, on the simulator) for app-side logic.
- pytest (`uv run pytest tests/`) for scripts.

**Owner's rule:** tests stay few and behavioral. They check what a feature does and guard against real bugs. They don't assert exact file contents, constant values, string texts or internal structure. Sections with no behavioral logic worth testing say so. Verification there comes from the artifact verifier, CI, or device reports.

---

## 1–3. Context, background, repository layout
No tests. These sections are descriptive.

## 4. Tooling and Makefile
No unit tests. `make doctor` is exercised by running it. The CI build job running the Makefile targets end to end is the check.

## 5. Third-party convention, patches and version

### 5.2 `apply_patches.py`
Fixture: a temp superproject with one submodule pinned to a commit, and a `patches/<name>/` directory.
- Test: applying the patches changes the submodule's working tree as the patches describe, and running apply a second time leaves the same tree (idempotent).
- Test: after apply, the superproject does not record a new submodule commit. `git status` / `git diff --submodule` shows no "new commits".
- Test: a patch that doesn't apply makes the command fail. The error names the component and the patch, and the submodule is left at its pinned commit with a clean tree.
- Test: restore returns a patched submodule to a clean pinned tree.

### 5.3 `version.sh`
- Test: with `VERSION` = 1.2.3 and `HEAD` tagged `v1.2.4`, `--check` fails. With the tag `v1.2.3`, it passes.
- Test: in a shallow clone without `EIKON_BUILD_NUMBER`, generation fails. With the override set, it succeeds.

These are run through pytest against temp git repos.

## 6. Licensing and credits pipeline

### 6.3 `credits.py`
Fixture: a temp repo with `licenses/`, `third_party/credits.toml` and an optional submodule.
- Test: a repo with no submodules and an empty manifest passes the check.
- Test: adding a submodule with a matching entry, an existing license file and a license text passes. Adding a second submodule **without** an entry fails, and the problem names that path. This is the spec's done criterion.
- Test: an entry whose license file is missing fails.
- Test: an entry whose path escapes the repo (`..` or absolute) fails.
- Test: after a manifest change, stale notices fail the check. Regenerating them with `notices --write` makes it pass.

## 7. Xcode project and app lifecycle
No unit tests. The CI build job (`xcodegen generate` + `xcodebuild test` + `archive`) proves the project generates, builds and launches the test host. Ownership of the controller (a single shared instance) is covered through the controller tests in section 9.

## 8. Install-method detection
Fixture: a fake `BundleEnvironment` describing a filesystem layout.
- Test: a `_TrollStore` marker next to the bundle → `trollStore`. A `_TrollStoreLite` marker → `trollStoreLite`.
- Test: a bundle under a jailbreak `Applications` path with a Dopamine marker → `dopamine`. The same path without the marker → `rootlessJailbreak`.
- Test: a bundle with `embedded.mobileprovision` and no other markers → `sideloaded`. Nothing matching → `unknown`.
- Test: the evidence never contains the raw preboot hash, jailbreak id suffix or container UUID that appeared in the input path. It is checked by searching for those input values, not by comparing to a fixed string.

## 9. JIT status, probe, store and controller

### 9.1 C layer
No simulator unit test for the probe. Executing a remapped page in the simulator is not representative, and `JITSystem.live` never probes there. The probe is verified through the Xcode-debugged device run and the device reports.

### 9.2 Pure policy
Tests use `JITFacts` built for each case.
- Test: for a representative set of combinations of install method, `CS_DEBUGGED`, TXM and probe outcome, every status has `reason == nil` exactly when `usable` is true, and a non-nil reason otherwise.
- Test: `mayProbe` is false in each of these cases, and true for a TrollStore or Dopamine install with `CS_DEBUGGED` and no TXM:
  - no `CS_DEBUGGED`
  - TXM enforced
  - TXM undetermined on iOS 26+
  - simulator
  - a sentinel from this build
- Test: `usable` is never true when the probe didn't pass, even with `CS_DEBUGGED`.
- Test: source attribution credits `trollStore` only when `CS_DEBUGGED` was seen after a request. The same flag seen at launch on a TrollStore install is not credited to TrollStore.
- Test: `shouldRequestTrollStoreJIT`:
  - true for an automatic first attempt on a TrollStore install without `CS_DEBUGGED`
  - false on a non-TrollStore install
  - false when already tried in this process
  - false with `lastAttempt = now`
  - true with `lastAttempt = .distantPast`
  - true for a manual retry even with `lastAttempt = now`

  None of these pin the cooldown constant.
- Test: `ProbeOutcome` and `JITStatus` encode and decode to equal values, and the encoded status includes `usable`.

### 9.2 Crash sentinel
- Test: with a sentinel file holding the current build number present at launch, the gathered facts block the probe. The next launch (sentinel gone) allows it.
- Test: a sentinel holding a different build number doesn't block the probe.

These use a temp directory in place of `Library/Caches`.

### 9.3 Controller and store
Tests use a fake `JITSystem` whose `csDebugged` can flip, a fake `openURL`, and a controllable clock.
- Test: on a TrollStore install without JIT, the first `sceneBecameActive` opens exactly one URL, containing the runtime bundle id. A second activation doesn't open another.
- Test: when the fake flips `CS_DEBUGGED` during the request, the status becomes usable with source `trollStore`, and `isRequestingTrollStoreJIT` clears.
- Test: when `CS_DEBUGGED` never appears, the status ends not usable with reason `trollStoreTimedOut` once the deadline passes, even if the scene never becomes active again.
- Test: when `openURL` reports failure, the request ends immediately with `trollStoreTimedOut`.
- Test: `JITStatusStore.shared.current` reflects each status the controller publishes.

## 10. Device report

### 10.1 Model
- Test: an encoded report round-trips to an equal value, and contains no key or value equal to the device name that the test's environment supplies. This is a privacy guard.

### 10.3 Schema and filing (pytest)
- Test: a valid report (fixture JSON) is filed under `device-reports/`. The filename includes the report's own date, and running the filer again with the same report succeeds without creating a second file.
- Test: a report missing a required field, or with an unknown top-level key, or with an unknown `schemaVersion`, is rejected, and nothing is written.
- Test (pytest): the shared fixture `tests/fixtures/device-report.json` validates against `schema.json`.
- Test (Swift): the same fixture is bundled as a test resource. It decodes into `DeviceReport`, and re-encoding it gives the same top-level and `jit` key sets. The fixture is the single contract between the Swift model and the schema, so any drift fails one side.

## 11. Packaging, signing and verification
No unit tests. The artifact verifier (`verify_artifacts.py`) is the check, and it runs against real artifacts in CI and locally on every `make all`. Its expectations come from the entitlements files and `VERSION`.
- Build-time check (not a test): the first CI run shows the verifier failing on a deliberately broken artifact. For example, temporarily add `dynamic-codesigning` to `tipa.plist` in a scratch branch. That confirms it catches forbidden keys. It is done once and not kept as a test.

## 12. Publishing to eikon-source

### 12.2 `build_index.py` (pytest)
Fixture: a small deb built in the test with `dpkg-deb`, skipped if `dpkg-deb` is unavailable, plus the templates.
- Test: every file listed in `Release`'s `MD5Sum:` and `SHA256:` sections exists, and its size and hashes match. `Release` contains `Architectures:` with `iphoneos-arm64` and a `Components:` line.
- Test: the `Packages` stanza's `SHA256` and `Size` match the deb, and `Filename` is the given asset URL (absolute mode) or `debs/<name>` (relative mode).
- Test: a second run with a newer deb leaves exactly one stanza, the newer version, and nothing from the old run outside the regenerated set.

### 12.4 `publish.sh`
No automated test. Its `--dry-run` is exercised manually before the first real publish.

## 13. CI
No tests. The workflows are the checks. `release.yml` is proven by the `v0.1.0` release.

## 14. Status screen
No UI tests. It is verified visually in the simulator and on devices, and captured in device reports.

## 15–18. Testing summary, runbook, order, risks
No additional tests. Device behaviour is proven by the filed reports listed in the runbook.

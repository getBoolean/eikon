<!-- PROJECT_CONFIG
runtime: swift-xcodegen-python-uv
test_command: make test
END_PROJECT_CONFIG -->

<!-- SECTION_MANIFEST
section-01-skeleton-tooling
section-02-xcode-project
section-03-patch-convention
section-04-credits-pipeline
section-05-install-detection
section-06-jit-core
section-07-jit-controller
section-08-device-report
section-09-status-ui
section-10-packaging-verifier
section-11-repo-publishing
section-12-release-runbook
END_MANIFEST -->

# Implementation Sections Index

## Section summaries

The source is `claude-plan.md` for design and `claude-plan-tdd.md` for tests. Section numbers in parentheses refer to the plan.

- **section-01-skeleton-tooling**
  - Covers: plan §3, §4, §5.3.
  - Top-level files: `VERSION` (0.1.0), `LICENSE`, `licenses/`, `.gitignore`, `README.md` update.
  - Python tooling: `.python-version`, `pyproject.toml` (pytest via uv), `tests/` scaffold.
  - `Makefile` with all targets; targets for later sections may be stubs.
  - Scripts: `scripts/doctor.sh`, `scripts/bootstrap.sh`, `scripts/version.sh` (generation, shallow-clone guard, `--check`, `--check-tag`).
  - Tests: version guard pytest tests.
- **section-02-xcode-project**
  - Covers: plan §7.1, §7.3, and a minimal §13.1.
  - Project: `project.yml`, `Config/*.xcconfig`, the local package `Packages/EikonKit` (C target `CEikonJIT` and Swift target `EikonKit`, both empty) with a Swift Testing target wired into the `Eikon` scheme.
  - App shell: `App/` with Info.plist keys (version, `EKGitCommit`, `EKPackageKind`, `UILaunchScreen`), an original app icon, a placeholder `Acknowledgements.json`.
  - Build: the app builds and launches in the simulator with `make test-swift`.
  - Debug loop: README note.
  - CI: minimal `.github/workflows/ci.yml` (scripts job and build/test job, `fetch-depth: 0`, SHA-pinned actions, read-only permissions).
- **section-03-patch-convention** (now: third-party libraries from fork releases)
  - Covers: plan §5.1 and §5.2, as revised by the owner: fork releases, not submodules or patches.
  - `third_party/README.md` (the convention, the release workflow, and notes for building in the forks) and `third_party/deps.toml` (an empty manifest of pinned release assets).
  - `scripts/deps.py` (`check`, `fetch`, `verify`, `pin`), which downloads, checks by SHA-256 and unpacks into `build/deps/`.
  - `make fetch-deps`, `verify-deps` and `pin-dep`.
  - Tests: pytest tests against a local `file://` release root.
- **section-04-credits-pipeline**
  - Covers: plan §6 and §4.2 (acknowledgements wiring).
  - `third_party/credits.toml` (empty), `scripts/credits.py` (check, notices, app-json), and the generated `THIRD_PARTY_NOTICES.md`.
  - `make check` and `make generated` wiring. XcodeGen picks the generated or placeholder acknowledgements resource.
  - Tests: pytest tests with fixture repos.
- **section-05-install-detection**
  - Covers: plan §8.
  - Swift: `InstallMethod`, `InstallEvidence` (redacted bundle path and home directory, markers), `BundleEnvironment` seam and live implementation, `detectInstallMethod`, package kind, runtime bundle id.
  - Tests: Swift Testing tests on fake layouts.
- **section-06-jit-core**
  - Covers: plan §9.1, §9.2.
  - C layer: `eikon_cs_flags`, `eikon_jit_probe` (the proven dual-map sequence, thread- and address-checked signal guard), `eikon_txm_firmware_present`.
  - Swift policy types: `TXMState`, `TXMInfo`, `CSDebuggedSeen`, `JITSource`, `JITReasonCode`, `ProbeOutcome`, `JITStatus` (computed `usable`), `JITFacts`.
  - Policy: `JITPolicy` (`mayProbe`, `status`, `shouldRequestTrollStoreJIT`) and the CPU-family TXM table.
  - Crash sentinel.
  - Tests: Swift Testing policy and sentinel tests.
- **section-07-jit-controller**
  - Covers: plan §9.3, §7.2.
  - `JITSystem` seam and live implementation (with the simulator short-circuit).
  - `JITStatusStore` (a lock-protected, `nonisolated` snapshot).
  - `JITController.shared`: `gatherFacts`, `sceneBecameActive`, the TrollStore request flow (overall deadline, grace period), `retryTrollStoreJIT`, `retryProbe`.
  - `EikonApp` ownership and scene-phase wiring.
  - Tests: Swift Testing controller tests with a fake system, URL opener and clock.
- **section-08-device-report**
  - Covers: plan §10.
  - Model: `DeviceReport` and supporting types, sysctl device info, chip display table, memory info.
  - `device-reports/schema.json` and `scripts/file_device_report.py`.
  - Export helpers (copy and share, the `UIActivityViewController` bridge).
  - Tests: a shared fixture `tests/fixtures/device-report.json`, checked by pytest schema and filer tests and by a Swift decode/re-encode contract test.
- **section-09-status-ui**
  - Covers: plan §14.
  - `StatusView` sections: app, install, JIT (with the pending row, Retry JIT, Retry probe), device, report actions.
  - `Localizable.strings`, including the text for every `JITReasonCode`.
  - Verified in the simulator; no UI tests.
- **section-10-packaging-verifier**
  - Covers: plan §11.
  - `scripts/archive.sh` (acknowledgements and arm64-only guards).
  - `packaging/entitlements/{deb,tipa,ipa}.plist` and their README (honoured-by table, forbidden list, `platform-application` rationale, the `.tipa` Developer Mode requirement).
  - `packaging/deb/{control.in,postinst,prerm}`.
  - `scripts/package.sh` (ipa, tipa, deb, bundle-level ldid signing, `EKPackageKind` stamp, version read-back, `SHA256SUMS`).
  - `scripts/verify_artifacts.py`: layout, version, stamp, hygiene, entitlements, resource-hash seal, unsigned-entitlement nested code, and a same-binary check via `LC_UUID` plus non-`__LINKEDIT` segment hashes.
  - CI: extend `ci.yml` to package and verify.
- **section-11-repo-publishing**
  - Covers: plan §12.
  - `packaging/repo/` templates and icons.
  - `scripts/repo/build_index.py` (owns `docs/` wholesale, absolute or relative `Filename`, `Release` with `MD5Sum:`/`SHA256:`, depiction with Details and Licenses tabs, `.nojekyll`).
  - `scripts/repo/publish.sh` (refuses an existing release, downloads the deb back from the asset URL, `--dry-run`).
  - README one-time setup steps: deploy key in the protected environment, Pages `POST`/`PUT`, repo description.
  - Tests: pytest index tests.
- **section-12-release-runbook**
  - Covers: plan §13.2, §16, §17 step 14.
  - `.github/workflows/release.yml`: tag guard, build, release (with `contents: write`, fails if the release exists), and publish in the `eikon-source` environment, with the secret checked in a step and `concurrency: publish`.
  - `device-reports/README.md`: the runbook for the iPad (TrollStore, Dopamine 3), the iPhone (AltStore, TXM), and filing.
  - The first `v0.1.0` release, the `eikon-source` migration, and enabling Pages, all with owner approval before any outward-facing action.
  - Device reports filed.

## Dependency graph

| Section | Depends on | Blocks | Parallelizable |
|---|---|---|---|
| section-01-skeleton-tooling | – | 02, 03, 04 | – |
| section-02-xcode-project | 01 | 04, 05, 10 | Yes, with 03 |
| section-03-patch-convention | 01 | – | Yes, with 02 |
| section-04-credits-pipeline | 01, 02 | 10 | Yes, with 05 |
| section-05-install-detection | 02 | 06, 08 | Yes, with 04 |
| section-06-jit-core | 05 | 07, 08 | – |
| section-07-jit-controller | 06 | 09 | Yes, with 08 |
| section-08-device-report | 05, 06 | 09 | Yes, with 07 |
| section-09-status-ui | 07, 08 | 12 | Yes, with 10 |
| section-10-packaging-verifier | 02, 04 | 11, 12 | Yes, with 09 |
| section-11-repo-publishing | 10 | 12 | – |
| section-12-release-runbook | 09, 10, 11 | – | – |

## Execution order

1. section-01-skeleton-tooling.
2. section-02-xcode-project and section-03-patch-convention, in parallel.
3. section-04-credits-pipeline and section-05-install-detection, in parallel.
4. section-06-jit-core.
5. section-07-jit-controller and section-08-device-report, in parallel.
6. section-09-status-ui and section-10-packaging-verifier, in parallel.
7. section-11-repo-publishing.
8. section-12-release-runbook, which includes the outward-facing steps. Ask the owner before each one.

## Cross-cutting rules for every section

- **Tests stay few and behavioral.** Don't pin exact file contents, constants, string texts, or internal structure (owner's rule).
- **No program titles** anywhere. Don't touch `/Volumes/Games`.
- **Forbidden entitlements** in every artifact: `dynamic-codesigning`, `com.apple.private.cs.debugger`, `com.apple.private.skip-library-validation`, `com.apple.private.persona-mgmt`, `platform-application`.
- **JIT:** Eikon never attaches a debugger or calls `ptrace` or task-for-pid. It never uses `MAP_JIT`.
- **Tooling:** scripts invoke compilers through `xcrun`. Python scripts run via `uv run` and use only the standard library.
- **iOS 15 API floor:** no `NavigationStack`, `@Observable`, `Mutex`, `OSAllocatedUnfairLock`, or `ShareLink`.
- **Owner approval first** for anything outward-facing: pushes, releases, repo settings, Pages, secrets.

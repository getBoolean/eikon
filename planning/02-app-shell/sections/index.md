<!-- PROJECT_CONFIG
runtime: swift-xcodegen-python-uv
test_command: make test
END_PROJECT_CONFIG -->

<!-- SECTION_MANIFEST
section-01-core-package
section-02-detection
section-03-identity
section-04-collection-scanner
section-05-settings-store
section-06-route-picker
section-07-sessions-crash
section-08-gate-store
section-09-library-drives
section-10-runtime-session-host
section-11-crash-report-controller
section-12-strings-navigation
section-13-library-ui
section-14-device-screen
section-15-credits
section-16-landing
END_MANIFEST -->

# Implementation Sections Index

The design source is `claude-plan.md`, and the tests come from `claude-plan-tdd.md`. The § numbers below refer to the plan.

## Dependency Graph

| Section | Depends On | Blocks | Parallelizable |
|---|---|---|---|
| section-01-core-package | - | all | No |
| section-02-detection | 01 | 03, 04, 06, 09 | No |
| section-03-identity | 02 | 04, 09 | Yes (with 06) |
| section-04-collection-scanner | 02, 03 | 16 | Yes |
| section-05-settings-store | 01 | 09, 13 | Yes (with 02) |
| section-06-route-picker | 02 | 09, 10, 13, 14 | Yes (with 03, 05) |
| section-07-sessions-crash | 01, 02, 03 | 10, 11 | Yes (with 04, 06) |
| section-08-gate-store | 01, 06 | 13, 14 | Yes (with 07) |
| section-09-library-drives | 03, 05, 06 | 13 | No |
| section-10-runtime-session-host | 06, 07 | 11, 14 | Yes (with 09) |
| section-11-crash-report-controller | 07, 10 | 13 | No |
| section-12-strings-navigation | 01 | 13, 14, 15 | Yes |
| section-13-library-ui | 08, 09, 11, 12 | 16 | No |
| section-14-device-screen | 08, 10, 12 | 16 | Yes (with 13) |
| section-15-credits | 12 | 16 | Yes (with 13, 14) |
| section-16-landing | 04, 13, 14, 15 | - | No |

## Execution Order

1. section-01-core-package
2. section-02-detection, section-05-settings-store, section-12-strings-navigation (parallel after 01)
3. section-03-identity, section-06-route-picker (parallel after 02)
4. section-04-collection-scanner, section-07-sessions-crash, section-08-gate-store (parallel after 03)
   Then section-10-runtime-session-host (after 06, 07)
5. section-09-library-drives (after 03, 05, 06), section-11-crash-report-controller (after 07, 10)
6. section-13-library-ui, section-14-device-screen, section-15-credits (parallel)
7. section-16-landing

## Section Summaries

### section-01-core-package
Plan §2.1, §2.4 (build parts), §3.
- New `Packages/EikonCore` with platforms iOS 15 + macOS 13, Swift 6 mode, and system `libz` linked.
- The C target `CEikonSession`, holding the in-flight atomics, the breadcrumb slot writer and the fault hook.
- An empty test target.
- EikonKit gains its dependency on EikonCore. `project.yml` adds the package and its test bundle to the scheme.
- Makefile targets `test-core` and `scan-collection`, plus the `help` text.
- The CI macOS job runs `make test-core`.
- The shared persisted-file rules (`Persisted`, §6.2).

### section-02-detection
Plan §4.
- Types: `Engine`, `EngineDetails`, `DetectionResult` (with per-platform executables and a detector version) and `BinaryInfo`, all with enum fallbacks.
- `FolderListing`, with case-insensitive, NFC-normalized lookups.
- `FolderReader`, with per-purpose budgets and zlib.
- PE, ELF and PE version-resource parsing.
- The five engine detectors.
- The wrapper rule, main-executable selection, and the exclusion table with counters.
- The `Fixtures.swift` synthesizer.

### section-03-identity
Plan §5.
- `GameID` (random UUID), `Fingerprint` and the keyed types.
- `NameNormalizer`.
- `KeyFile` per engine.
- `EngineDeclaredID` with its generic blocklist.
- `FingerprintBuilder`, which applies HMAC with the library secret.
- `IdentityMatcher`, implementing the five rules, including in-place patches keeping the game id.
- Merge and split with `merged/` link resolution.
- `FileHasher` for diagnostics.

### section-04-collection-scanner
Plan §16.
- `CollectionSummary` (pure) and the `eikon-scan` CLI, which handles a missing root, `--per-folder` and `--hash`, and reports identity statistics.
- The `make scan-collection` target.
- The opt-in `tests/test_collection_scan.py`, which compares against the requirements table parsed at run time.
- Run it against `/Volumes/Games` (read-only) and reconcile the results with `requirements.md`.

### section-05-settings-store
Plan §7.
- `ReplicaID`, `HybridClock`, `JSONValue` and `LWWMap` (merge, tombstones, preserving unknown keys, `deletedAt` shadowing).
- `SettingKey`, with the keys 02 uses and the reserved namespaces.
- `SettingsStore`: one file per replica, a forked replica when the file format is from the future, and debounced off-main persistence.

### section-06-route-picker
Plan §8.
- `RouteID`, `GateName`, `GateState`, `RuntimeCheck`/`RuntimeDeclineCode`, `RouteReason`, `RouteVerdict`, and the candidate, decision and environment types.
- The `RouteRules` table.
- `RoutePicker.decide`: native first, Box64 demoted rather than removed, planned routes, and overrides with warnings.

### section-07-sessions-crash
Plan §10.1–10.4, §10.5 (`CrashIssue`, `CrashHistory`) and §10.6.
- `SessionRecord` and `SessionSentinel`.
- Slot-based `Breadcrumbs`, backed by `BreadcrumbEvent`.
- `FaultRecord` and the C fault hook.
- `SessionOutcome` classification, with its time window.
- `CrashHistory`, which keeps snapshots of the last 5 per game.
- The `CrashIssue` URL builder, with explicit percent-encoding, a length limit and the report id.
- `.github/ISSUE_TEMPLATE/crash.yml`.

### section-08-gate-store
Plan §11.
- `GateStore` in EikonKit: passed results expire, and failures persist marked as stale.
- `states()` for the picker.
- The `DeviceReport.make` `gates` parameter, with a default that keeps 01's call sites working.

### section-09-library-drives
Plan §6.
- Models: `GameDrive` and `GameLocation`, plus `LibraryIndex`.
- `FolderAccess` and `LiveFolderAccess`, with `AccessToken.close()`.
- `DriveManager`: add, remove and re-link, with volume-kind refusals and drive states.
- `DriveScanner`: diffing, quiescence, re-detection, and a serial fingerprint worker that pauses during sessions.
- `ImportCoordinator`: pick the game, pick the drive, a "files will be copied" notice, a space check, staging, progress and cancel, coordinated reads, and replace or rename.
- `LibraryController`, which recomputes routes and handles merge and split.
- The remove flow, with `deletedAt` and the `GameDataCleanup` and `GameDataMerge` hooks.
- `Info.plist` file-sharing keys, and `Documents/` as the built-in drive.

### section-10-runtime-session-host
Plan §9.1–9.3.
- `GameRuntime`, `LaunchableGame` and `GameSessionHost`.
- `RuntimeRegistry`, with cached async checks.
- `RenderGate`, the in-flight guard.
- The `SceneEvents` seam.
- `GameSessionHostViewController`: pause, background, the resume overlay, audio, memory, the menu, and hidden system UI.
- `GameSession`: sentinel, access token, pausing background work, memory samples.
- `SessionPresenter`, which presents from the topmost controller.

### section-11-crash-report-controller
Plan §10.5 (controller side).
- Consumes the sentinel at launch into history.
- Publishes the banner.
- "Try another route", which offers only routes that can actually run.
- "Report on GitHub", which opens the prefilled issue with a clipboard fallback for the device report.

### section-12-strings-navigation
Plan §12.1, §12.7, §14.
- Move `Localizable.strings` to `en.lproj` and add `.stringsdict`.
- Exhaustive code→key maps in `App/Strings/`.
- `RootView` sidebar (Library, Game drives, This device, Credits) and the `EikonApp.init` wiring order.
- DEBUG previews that cover every reason, verdict and outcome.

### section-13-library-ui
Plan §12.2–12.4.
- `LibraryView` and `LibraryRow`, with statuses, the "Not recognized" section and the empty state.
- `GameDetailView` and `RouteSection`, with the override and the "Launch anyway" warning.
- The `IdentitySuggestion` card and the merge and split actions.
- The `ImportFlow` sheet and `RemoveGameDialog`.
- `DrivesView`.
- `CrashBanner`.

### section-14-device-screen
Plan §12.5, §9.4.
- `StatusView` extended with route-table and gate sections.
- A Developer section: run a test session, simulate a crash, the gate store, the replica id, and a warning when settings have forked.
- `TestPatternRuntime`: a `CAMetalLayer` render thread that uses the render gate and counts command-buffer errors.

### section-15-credits
Plan §15, §12.6.
- `credits.py app-json` gains an Eikon entry and an `isApp` flag. Update `test_credits.py`.
- The `Acknowledgements` model and loader.
- `CreditsView`.

### section-16-landing
Plan §2.4, §16.3, §17 (device checks), §18 step 16.
- Update the identity and game-drive decision in `planning/requirements.md`.
- Final `make test`, archive, package and verify.
- Run the scanner against the mount and reconcile the results.
- Create the `crash` label, and verify that the issue-form prefill works.
- Device checks, recorded by engine and hash only, then file a device report.

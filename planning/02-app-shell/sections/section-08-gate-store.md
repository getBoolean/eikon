# Section 08: Gate store (EikonKit/Gates)

## Purpose

Later splits run hardware and OS checks called **gates**. Split 05 writes `x18` and split 07 writes `guestWindow`. Each gate's result decides whether some routes may run on this device. This section builds the persisted store that holds those results, and it adds one change to the existing device report:

1. **`GateStore`.** A lock-guarded, file-backed store in EikonKit, kept in `gates.json`.
   - A **passed** result counts only under the app build and OS build it was measured on. After an update it reads as `unmeasured` again.
   - A **failed** result never quietly becomes "allowed". After an update it still reads as failed, marked **stale**, until something measures the gate again.
2. **`states()`.** Returns the `[GateName: GateState]` map that the route picker's `RouteEnvironment.gates` takes.
3. **`DeviceReport.make` gains a `gates` parameter.** It defaults to empty, so every existing call site from split 01 compiles and behaves the same.

Nothing writes gates in split 02. The store, its schema, its expiry rules and its readers exist now so that 05 and 07 only have to call `record`.

### Why these rules (the owner's decision)

| Gate state | Effect on a route that requires the gate |
|---|---|
| unmeasured | the route runs, with a warning (`runnableWithWarnings` plus a `gateUnmeasured` reason) |
| failed, fresh or stale | the route is unavailable (`gateFailed(name, stale:)`) |
| passed | no effect |

An app update or an OS update can change whether a gate holds.
- A **pass** under an old build is therefore not trusted. It becomes "unmeasured", which means "allowed with a warning".
- A **failure** must not turn into "allowed" just because the build changed. It stays a failure, flagged as stale, so the UI can say "Failed on this device before an update. Not re-checked yet."

## Dependencies

- **Section 01 (core package):**
  - `Packages/EikonCore` exists, and EikonKit depends on it.
  - The shared persisted-file rules (`Persisted`: `writeAtomically`, `PersistedFile`, `TolerantList`) are in `Packages/EikonCore/Sources/EikonCore/Library/Persisted.swift`.
  - Use those helpers. Don't hand-roll atomic writes or format checks.
- **Section 06 (route picker):**
  - Provides `GateName`, a `RawRepresentable` `Hashable`/`Codable`/`Sendable` struct with the constants `.x18` and `.guestWindow`.
  - Provides `GateState` (`.passed`, `.failed(stale: Bool)`, `.unmeasured`).
  - Both live in `Packages/EikonCore/Sources/EikonCore/Routes/`.
- **Already in the repo, from split 01:**
  - `GateResult` in `Packages/EikonKit/Sources/EikonKit/DeviceReport.swift`: `passed: Bool?` (nil means unmeasured), `detail: String`, `measuredAt: Date`. Reuse it as the stored result type. Don't define a second one.
  - `DeviceReport.gates: [String: GateResult]`, which `make` currently fills with `[:]`.
  - `AppInfo` (`version`, `build`, `commit`, …) and `AppInfo.from(_ bundle:)`.
  - `DeviceSystem.osBuild` and `LiveDeviceSystem.current()`, which is `@MainActor`.
  - `SystemInfo.buildNumber`.

**Blocks:**
- **Section 13 (library UI):** `LibraryController` builds `RouteEnvironment.gates` from `states()` and recomputes routes when gates change.
- **Section 14 (device screen):**
  - The Gates rows read `states()` plus each gate's detail and date.
  - The Developer section lists what the store holds.
  - The report export passes `current()` to `DeviceReport.make`.

## Files

| Action | Path |
|---|---|
| create | `Packages/EikonKit/Sources/EikonKit/Gates/GateStore.swift` |
| modify | `Packages/EikonKit/Sources/EikonKit/DeviceReport.swift` (the `make` signature) |
| create | `Packages/EikonKit/Tests/EikonKitTests/GateStoreTests.swift` |
| modify | `Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift` (add one test) |
| unchanged | `tests/fixtures/device-report.json` (the contract test must keep passing without edits) |
| unchanged | `App/StatusView.swift` (its `DeviceReport.make` call must still compile; section 14 wires gates in) |

## Tests first (EikonKitTests, run on the simulator by `make test-swift`)

Follow split 01's style:
- Swift Testing: `import Testing`, free `@Test func` functions with behavior names, and `#expect`/`#require`.
- Fakes go at the top of the file.
- Every test gets its own temp directory.

Keep the tests few and behavioral:
- Don't assert the JSON layout of `gates.json`, key names, or exact strings.
- Observe behavior only through `record`, `states()` and `current()`, and through a second store instance opened over the same directory.

Inject the build identity, so a "different build" is just another store over the same directory with a different stamp. Don't mock the file system.

`GateStoreTests.swift`:

```swift
// Helper: a store over `directory` that believes it runs under `app`/`os`.
private func store(_ directory: URL, app: String = "A1", os: String = "O1") -> GateStore

@Test func passedResultExpiresUnderAnotherBuild()
// record(.x18, passed) under (A1, O1); a store under (A1, O1) reads .passed.
// A store under (A2, O1) reads .unmeasured, and so does one under (A1, O2).

@Test func failedResultTurnsStaleUnderAnotherBuildUntilRecordedAgain()
// record(.x18, failed) under (A1, O1). A store under (A2, O1) reads .failed(stale: true).
// Recording .x18 again under (A2, O1) replaces it: a pass then reads .passed, and a
// failure reads .failed(stale: false).
```

Optional, and only if cheap: an unknown gate name (for example `GateName(rawValue: "futureGate")`) round-trips through a save and reload. This shows that the schema accepts any gate key.

`DeviceReportTests.swift` gets one addition:

```swift
@Test func reportIncludesGateStoreResults()
// Record a gate in a temp-dir store, then build DeviceReport.make(..., gates: store.current()).
// The encoded and decoded report's `gates` contains that gate's result.
```

The existing `fixtureContract` test (`tests/fixtures/device-report.json`) must keep passing unchanged. It compares top-level and `jit` key sets, and adding a parameter to `make` doesn't touch the encoded shape. Note that the fixture already carries one sample `gates` entry, which is fine: the contract is about keys. The existing `roundTripAndPrivacy` test calls `make` without `gates:` and must still compile. That call is the check that the default keeps split 01's call sites working.

## Implementation

### `GateStore`

`Packages/EikonKit/Sources/EikonKit/Gates/GateStore.swift`:

```swift
import EikonCore
import Foundation

/// The build a gate result was measured under. A passed result counts only under the
/// identical stamp.
public struct BuildStamp: Codable, Sendable, Equatable {
    public var app: String      // app build identity, see below
    public var os: String       // OS build, e.g. "21A329"
}

/// Persisted device-gate results (`gates.json`). Lock-guarded; safe from any thread.
/// Later splits (05: x18, 07: guestWindow) call `record`; 02 writes nothing.
public final class GateStore: @unchecked Sendable {
    public init(directory: URL, current: BuildStamp)
    /// Application Support/Eikon/gates.json, current app + OS build.
    @MainActor public static func live() -> GateStore

    /// Stores `result` for `name` with the current build stamp, replacing any earlier
    /// result for that gate, and persists it.
    public func record(_ name: GateName, _ result: GateResult)

    /// Every stored gate mapped through the expiry table. Gates never recorded are absent,
    /// and the picker treats a missing gate as unmeasured.
    public func states() -> [GateName: GateState]

    /// Results still meaningful on this build, for DeviceReport.make.
    public func current() -> [String: GateResult]

    /// Everything stored, with the stamp each result was measured under
    /// (for the Developer section's "gate store contents").
    public func entries() -> [GateName: (result: GateResult, stamp: BuildStamp)]  // or a small struct

    /// Called after each `record`, off the caller's thread; LibraryController uses it to
    /// recompute route decisions. Set once during app wiring.
    public var onChange: (@Sendable () -> Void)?
}
```

`entries()` may return a small public `Sendable` struct (`GateEntry { name, result, stamp }`) instead of a tuple. Use whichever reads better in section 14.

**States table.** `states()` maps each stored result as follows. Keep it one exhaustive `switch` over (`passed`, whether the stamp equals the current one):

| Stored `passed` | Stamp equals the current app + OS build | `GateState` |
|---|---|---|
| `true` | yes | `.passed` |
| `true` | no | `.unmeasured` |
| `false` | yes | `.failed(stale: false)` |
| `false` | no | `.failed(stale: true)`, until recorded again |
| `nil` (recorded as unmeasured) | either | `.unmeasured` |

**`current()`** returns results keyed by `GateName.rawValue`:
- Include passes under the current stamp.
- Include all failures, fresh and stale, each with its **original** `measuredAt`, so a reader can see how old the failure is.
- Include unmeasured records under the current stamp, since their `detail` may explain why.
- Exclude passes and unmeasured records from another build.

**Build identity:**
- `BuildStamp.app` must change whenever the installed binary changes release. Use `AppInfo.from(.main)` and combine `version` and `build` (for example `"\(version) (\(build))"`). A build number alone could repeat across versions.
- `BuildStamp.os` is `DeviceSystem.osBuild` (`kern.osversion`).
- `live()` reads both. It is `@MainActor` only because `LiveDeviceSystem.current()` is. The store itself is not actor-bound.

**Persistence** follows the shared rules from section 01's `Persisted`:
- **Location:** `Application Support/Eikon/gates.json`. Resolve it through `FileManager.url(for:in:)` and create the directory if it's missing. Never store an absolute container path.
- **Contents:** a `format` integer (start at 1) and a map from gate raw name to `{ result: GateResult, stamp: BuildStamp }`. The key is the raw string, so any gate name round-trips, including names this build doesn't know. That is what lets 05 and 07 add gates without a schema change.
- **Writes:** each write is atomic (temp file, rename, fsync) through `Persisted.writeAtomically`. The file is tiny, so writing synchronously inside `record` is fine. No debounce is needed.
- **Newer `format`:** if the file on disk has a newer `format` than this build knows, load what it can and **never rewrite it**. `record` still updates memory for this run.
- **Tolerant decoding:** entries decode one by one. A malformed entry is dropped from the in-memory view, but its raw form is kept and written back unchanged on the next save. Use `TolerantList` or the equivalent keyed helper from `Persisted`. If section 01 only provides a list helper, persist the entries as a list of `{ name, result, stamp }` objects rather than a dictionary.
- **Missing or unreadable file:** the store starts empty and never crashes.

**Concurrency:**
- Guard all state with one lock. On iOS 15 there is no `OSAllocatedUnfairLock` or `Mutex`, so use `NSLock`, as elsewhere in the codebase.
- The class is `@unchecked Sendable` under Swift 6 complete checking.
- Call `onChange` after the lock is released.

**Dates:** encode `measuredAt` as ISO-8601, as `DeviceReport` does, so the file is readable by eye and matches the report.

### `DeviceReport.make` change

In `Packages/EikonKit/Sources/EikonKit/DeviceReport.swift`, add a trailing parameter and pass it through instead of the literal `[:]`:

```swift
public static func make(app: AppInfo, installMethod: InstallMethod, evidence: InstallEvidence,
                        jit: JITStatus, system: DeviceSystem, now: Date,
                        gates: [String: GateResult] = [:]) -> DeviceReport
```

Keep these unchanged:
- `schemaVersion`
- the encoded shape
- `GateResult`

The `gates` field already exists in schema version 1, so filling it is not a schema change. The existing call in `App/StatusView.swift` keeps compiling as is. Section 14 changes it to pass `gateStore.current()`.

### Where this plugs in (for reference only; built in other sections)

- `EikonApp.init` creates the `GateStore` (via `.live()`) in step 3 of its wiring, next to `SettingsController`, `LibraryController` and `CrashReportController` (section 12/13).
- `LibraryController` sets `RouteEnvironment.gates = gateStore.states()` and recomputes decisions in `onChange` (section 09/13).
- This device → Gates rows and the Developer section's store dump (section 14).
- `CrashIssue`'s clipboard fallback exports the full `DeviceReport`, now with gates (section 11).

## Done when

- `GateStoreTests` pass on the simulator. The new `DeviceReportTests` case passes, and the existing `fixtureContract` and `roundTripAndPrivacy` pass unchanged.
- `make test` is green, and the app target still builds with its unchanged `DeviceReport.make` call.
- No code in 02 calls `record` outside tests.

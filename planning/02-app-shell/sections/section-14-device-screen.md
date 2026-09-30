# Section 14: This device screen (routes, gates, developer tools, test-pattern runtime)

## Summary

This section finishes the **"This device"** screen. It is the status screen from split 01, which already shows the app, install, JIT, device and report sections. This section adds:

1. A **Routes** section. It has one row per route and shows what that route's state would be on this device right now.
2. A **Gates** section for `x18` and `guestWindow`, each shown as passed, failed, stale or not measured, with detail and date.
3. A **Developer** section, collapsed by default and present in every build (not only DEBUG). It holds:
   - Run test session
   - Simulate crash during session
   - gate store contents
   - replica id
   - a settings-fork warning
4. `TestPatternRuntime`, a runtime used only by developers. It draws an animated pattern into a `CAMetalLayer` from its own render thread, holds the render gate around every commit, and counts command-buffer errors. It exercises the session-host contract without a game.

No game runs in this split. `TestPatternRuntime` is **not** a route and is never registered in `RuntimeRegistry`.

## Dependencies (must be done first)

- **section-08-gate-store:** provides `GateStore` in EikonKit.
  - `record(_:_:)`
  - `states() -> [GateName: GateState]`
  - `current() -> [String: GateResult]`
  - the `DeviceReport.make(..., gates:)` parameter
- **section-10-runtime-session-host:** provides:
  - `GameRuntime`, `LaunchableGame`, `GameSessionHost`
  - `RenderGate` (`enter()`, `leave()`, `close(timeout:)`)
  - `GameSession`, `SessionPresenter`, `GameSessionHostViewController` (with its "Tap to resume" overlay and menu)
  - `RuntimeRegistry` (`builtRoutes`)
- **section-12-strings-navigation:** provides:
  - `App/en.lproj/Localizable.strings`
  - the exhaustive code→key maps in `App/Strings/` (route id, verdict, reason and gate-name strings, including the `needsJIT` sentence that embeds 01's JIT reason)
  - the `RootView` sidebar entry "This device" that hosts `StatusView`
  - the `EikonApp.init` wiring that creates `SettingsController`, `GateStore`, etc.
- **Types used here from earlier sections (EikonCore):**
  - `RouteID`, `GateName` (`.x18`, `.guestWindow`), `GateState` (`.passed`, `.failed(stale:)`, `.unmeasured`), `RouteVerdict`, `RouteReason`, `RouteCandidate`, `RouteDecision`, `RouteEnvironment`
  - `RoutePicker.decide(detection:environment:override:)`
  - `DetectionResult`, `ExecutableInfo`, `Engine`, `CPUArchitecture`, `GamePlatform`
  - `GameID`
  - `SettingsStore` (replica id, fork flag)
  - `SessionRecord` (whose `route` is a `String`: a `RouteID` raw value or `"test"`)

Section 13 (library UI) can be built in parallel with this one. Section 16 (landing) depends on this section.

## Tests first

The TDD plan lists **no automated tests** for this section. This is deliberate, and follows the owner's standing rule that tests are few and behavioral, never locking in implementation details or hard-coded values:

- **§9.4 Test-pattern session:** "No automated tests. The device checks cover it."
- **§12 Screens:** "No automated UI tests. 01 has no UI test target."

Verification works like this instead:

1. **Build check.** `make test` (which runs `test-core`, `test-swift` and `test-scripts`) must still pass. The new files must compile in Swift 6 language mode with complete concurrency checking.
2. **DEBUG previews** (required). `StatusContent` stays a pure presentation struct, so previews can render every state without a device. Add previews that render:
   - every `RouteVerdict` and every `RouteReason` that can appear in a route row, including `needsJIT`, `gateFailed(stale: true)`, `gateFailed(stale: false)`, `gateUnmeasured`, `notInThisBuild` and `fexPreferredWithJIT`
   - every `GateState` for both known gates, plus an unknown gate name (it must fall back to the generic "<gate> check" string)
   - the Developer section expanded: with an empty gate store and with entries, with and without the settings-fork warning

   A missing string key then shows up as a raw key in the preview.
3. **Device checks** (manual). Record the results in a device report's notes, by engine and hash only:
   - Run test session. Pulling down Control Center pauses it: the pattern freezes and the gate is closed.
   - Going Home backgrounds it. After 30 s in the background, returning shows "Tap to resume". After resuming, the **command-buffer error count is 0**.
   - Simulate crash during session. The app aborts about 5 s after the session starts. On relaunch the crash banner appears (outcome "ended unexpectedly", route `test`, no "Try another route" action). *Report on GitHub* opens a prefilled issue that contains codes and the report id (no name for a test session).

Do not add unit tests for the route-row helper or the view code.

## Files

| Path | Action |
|---|---|
| `App/Device/StatusView.swift` | Extend (moved from `App/StatusView.swift` if section 12 has not already moved it; the plan's layout places it under `App/Device/`) |
| `App/Device/RouteTableSection.swift` | New: the Routes and Gates sections, plus the pure row builder |
| `App/Device/DeveloperSection.swift` | New: the collapsed Developer section |
| `App/Session/TestPatternRuntime.swift` | New |
| `App/en.lproj/Localizable.strings` | Add keys (see "Strings") |
| `App/Strings/` (the existing map files from section 12) | Add exhaustive maps for any new enum→key mappings (the gate-state display) |

After a move, check that `project.yml` picks up `App/Device/` and `App/Session/`. XcodeGen source globs normally include subfolders; run `make project` (or the repo's equivalent) and build.

## Background: the existing screen (from split 01)

`App/StatusView.swift` currently holds these pieces:
- **`StatusView`:** observes `JITController`, loads device facts once, and builds `DeviceReport` for the Copy and Share actions.
- **`StatusContent`:** the pure presentation struct. It takes rows plus closures, and holds the sections app, install, JIT, device and report.
- **Private row helpers:** `LabelRow`, `UnknownRow` and `SecondaryLine`.
- **Exhaustive `switch`-based key functions:** no `default:`, so a new case fails the build.
- **DEBUG `StatusView_Previews`.**

Keep all of that, and keep the style:
- Small, single-concept files.
- `LocalizedStringKey`s for labels.
- `Text(verbatim:)` for raw values.
- `.textSelection(.enabled)` on copyable values.
- Exhaustive switches.

**Navigation.** `StatusContent` currently wraps itself in its own `NavigationView` with `.navigationViewStyle(.stack)`. When hosted as the detail column of section 12's sidebar `RootView`, it must not create a second `NavigationView`. If section 12 has not already removed that wrapper, remove it here, and keep `.navigationTitle(Text("status.title"))` on the `List`. Previews can wrap `StatusContent` in a `NavigationView` themselves.

## Implementation

### 1. Extending `StatusContent`

Add these inputs to `StatusContent`. They are all plain values or closures, so previews can build any state:

```swift
struct RouteRow: Identifiable {          // one per RouteID, in RouteID.allCases order
    var route: RouteID
    var verdict: RouteVerdict
    var reasons: [RouteReason]
    var id: RouteID { route }
}

struct GateRow: Identifiable {
    var name: GateName
    var state: GateState
    var detail: String?                   // from the stored GateResult, if any
    var measuredAt: Date?
    var id: String { name.rawValue }
}

struct DeveloperRows {
    var replicaID: String
    var settingsForked: Bool              // SettingsStore forked to a new replica (§7.1)
    var gateEntries: [GateStoreEntryRow]  // raw store contents, may be empty
    var sessionActive: Bool               // disables the test buttons while a session runs
}
```

New closures: `onRunTestSession: () -> Void` and `onSimulateCrash: () -> Void`.

**Section order in the `List`:** app, install, JIT, **routes**, **gates**, device, report, **developer**. The developer section goes last.

### 2. Routes section (`RouteTableSection.swift`)

**Purpose.** Show, for each of the five routes, what its state is on this device, independent of any game.
- Each row has a caption listing the engines the route serves.
- The possible states are: available, needs JIT (with 01's JIT reason), gate failed (stale marked), gate unmeasured, or not in this build.

**Row building.** Rows come from a small pure helper in the same file:

```swift
enum DeviceRouteTable {
    /// Evaluates each route against a synthetic detection that exercises that route's
    /// full rule set, and returns that route's own candidate (not the picker's choice).
    static func rows(environment: RouteEnvironment) -> [RouteRow]
}
```

- **Synthetic detection per route.** Build one `DetectionResult` per route, in memory only. Use no real files and no names; paths are generic like `Game.exe`.
  - `native-kirikiri`: engine `.kirikiri` with a Windows i386 executable.
  - `native-renpy`: engine `.renpy` with a Windows i386 executable.
  - `wine-fex`: engine `.unknown` with a **Windows i386** executable. i386 requires both `x18` and `guestWindow`, so it shows the strictest gate requirement.
  - `wine-box64`: engine `.unknown` with a Windows i386 executable. Box64 accepts only i386.
  - `linux-fex`: engine `.unknown` with a **Linux amd64** executable.
- **Picking the candidate.** Call `RoutePicker.decide(detection:environment:override: nil)`, then take the candidate whose `route` matches the row, from `decision.candidates`. Ignore `chosen`, because the row describes the route, not the game.
- **Filtering reasons.** Drop the ordering-only reasons `nativeFirst` and `fexPreferredWithJIT` from device rows. They describe preference between routes for a game, not whether the route works here. `fexPreferredWithJIT` would otherwise appear on the Box64 row whenever JIT is usable.
- **Environment:**
  - `jitUsable`: `JITController.status.usable`.
  - `gates`: `GateStore.states()`.
  - `builtRoutes`: `RuntimeRegistry.builtRoutes`. It is empty in 02, so every otherwise-eligible route shows "Planned. Not in this build yet".
  - `runtimeChecks`: `[:]`. There is no game, so `runtimeDeclined` never appears here.
  - If `LibraryController` (section 09) already exposes a function that builds the current `RouteEnvironment`, reuse it and override `runtimeChecks` with `[:]`.

**Rendering.** Each route row shows:
- the route name (`route.id.*` key from section 12)
- a verdict label or badge (`route.verdict.*`)
- each reason as a footnote sentence (`route.reason.*`)
  - For `needsJIT`, section 12's reason map already produces "Needs JIT, which this install doesn't have: <01's JIT reason sentence>". Pass the current `JITStatus.reason` into it as that map requires.
  - `gateFailed(_, stale: true)` must read visibly differently from a fresh failure: "Failed on this device before an update. Not re-checked yet."
- a caption with the engines served, from a new exhaustive switch over `RouteID`:
  - native-kirikiri → Kirikiri
  - native-renpy → Ren'Py
  - wine-fex and wine-box64 → Windows games (Unity, Kirikiri, GameMaker, BGI and others)
  - linux-fex → Linux games

**Recomputing.** Rows are recomputed when the screen appears and when `controller.status` changes (`.onChange(of: controller.status)`; `JITStatus` is `Equatable`). JIT can flip from unusable to usable during a run. The gate store is not written by anything in 02, so recomputing on appear is enough.

### 3. Gates section (also in `RouteTableSection.swift`)

**Rows.** Always show `.x18` and `.guestWindow`, in that order. Then show any other gate name the store has a result for, sorted by raw name, so gates written by later splits appear without a UI change.

**Each row shows:**
- **The gate name.** Known constants get their own `gate.*` strings. Any other name uses the generic "<gate> check" string with the raw name.
- **The state, from `GateStore.states()`:**
  - passed
  - failed
  - failed and stale ("failed before an update, not re-checked")
  - not measured (`unmeasured`, including a passed result that expired under a new app or OS build)
  - Map `GateState` → key with an exhaustive switch, adding it to `App/Strings/` if section 12 didn't already.
- **Detail and date.** Take the `detail` and `measuredAt` from `GateStore.current()[name.rawValue]` when present, and show them as a `SecondaryLine`. Format the date with a `DateFormatter` using `.medium` date and `.short` time. A passed result that expired is absent from `current()`, so no stale detail is shown for it.

In 02 both known gates show "Not measured".

### 4. Developer section (`DeveloperSection.swift`)

**Container.** A `Section` containing a `DisclosureGroup` (available on iOS 14+) bound to `@State private var isExpanded = false`, so it is collapsed by default. It is present in **every** build: do not wrap it in `#if DEBUG`.

**Contents, in order:**

1. **Settings-fork warning** (only when `settingsForked`). The trigger (§7.1): this device's own settings file had a format newer than this build understands (after a downgrade). The store then forked to a new replica id, left the old file untouched, and merged it read-only. The message says that settings from a newer version were kept, and that edits made in this version are stored separately. Style it as a warning, with an exclamation icon and secondary text.
2. **Run test session.** A button that calls `onRunTestSession`.
3. **Simulate crash during session.** A button that calls `onSimulateCrash`. Its footnote says that the app will quit after about 5 seconds, and a crash report will appear on the next launch.
   - Both buttons are disabled while `sessionActive`.
4. **Replica id.** A selectable, monospaced value from the `SettingsStore` or `SettingsController` replica id (UUID string).
5. **Gate store.** One row per raw stored entry:
   - fields: gate name, stored result (passed, failed or unmeasured), the app build and OS build it was recorded under, `measuredAt`, and detail
   - with no entries, a single "Empty" row (`developer.gates.empty`)
   - These are raw store contents: unlike the Gates section, they are not interpreted into states.
   - If section 08's `GateStore` has no read accessor for raw entries (build stamps included), add a read-only one, for example `func entries() -> [GateStoreEntry]`, returning copies under the store's lock. Map it to `GateStoreEntryRow` in `StatusView`.

### 5. `StatusView` wiring

**New dependencies.** `StatusView` gains its dependencies through its initializer, from `RootView` and `EikonApp`:
- the `GateStore`
- the `SettingsController` (or the store) for the replica id and fork flag
- the `RuntimeRegistry`
- whatever section 10 exposes for starting a session: `SessionPresenter` and `GameSession`, plus an observable "session active" flag

**Device report.** `makeReport()` now passes `gates: gateStore.current()` to `DeviceReport.make`, so copied and shared reports include gate results. Skip this if section 08 already changed this call site.

**Run test session.**
1. Build a `LaunchableGame` for the test session:
   - `gameID`: the fixed synthetic id (see below).
   - `root`: a scratch directory under `FileManager`'s caches directory (for example `Caches/test-session/`), created if missing. No game drive or bookmark is involved; the built-in drive needs no security-scoped access.
   - `detection`: a synthetic `DetectionResult` with engine `.unknown` and no executables.
2. Start it through section 10's `GameSession`/`SessionPresenter` with a `TestPatternRuntime` instance, recording the session's route as the string `"test"`.
3. The session order from section 10 still applies:
   1. flush settings
   2. arm the sentinel (engine `unknown`, route `"test"`)
   3. suspend scans and fingerprinting
   4. launch
   5. present full screen from the topmost presented controller

**Contract gap to resolve with section 10.** `GameRuntime` declares `static var route: RouteID`, and `LaunchableGame.route` is a `RouteID`, but the test session's record route is `"test"`, which is not a `RouteID`. Use the entry point section 10 provides for test sessions. If none exists, add a minimal one in section 10's `GameSession`. Two acceptable shapes:
- `GameSession` takes a runtime *instance* plus a record-route string (`"test"`), or
- the host and session depend only on the instance lifecycle methods (`launch`, `pause`, `resume`, `stop`), split out as a base protocol that `GameRuntime` refines. `TestPatternRuntime` then conforms only to the base protocol.

Either way, `TestPatternRuntime` never enters `RuntimeRegistry`, never affects `builtRoutes`, and never appears in any route list.

**Synthetic test game id.** Derive a fixed `GameID` from the hash of a constant domain string, for example the first 16 bytes of SHA-256 over `"eikon.test-session"` (CryptoKit), with the UUID version and variant bits set.
- It is stable across launches, and it encodes nothing about any real game.
- Its first 8 characters act as the report id in crash issues.
- Section 11's `CrashReportController` recognizes `test` records by the route string, and omits "Try another route" for them.

**Simulate crash during session.** Start a test session exactly as above, but create the runtime with a crash delay of 5 s.
- The runtime schedules `abort()` on the main queue 5 s after `launch` returns.
- The sentinel is armed with phase `running`, and 02 installs no signal handler. On the next launch, section 07's classification therefore yields `endedUnexpectedly`, and the banner appears.

### 6. `TestPatternRuntime` (`App/Session/TestPatternRuntime.swift`)

A `final class` in the App target that conforms to the session runtime protocol from section 10. Its purpose is to exercise the host contract:
- pause stops GPU submission
- background happens only after the gate is closed
- resume happens only through the overlay
- the render gate never lets a command buffer commit while the app is inactive

Such a commit shows up as a command-buffer error, and the error count makes that visible.

**Signature sketch:**

```swift
final class TestPatternRuntime /* : section 10's runtime protocol */ {
    @MainActor init()                                   // required by the protocol
    @MainActor init(crashAfter: TimeInterval?)          // nil = normal test session
    @MainActor func launch(_ game: LaunchableGame, in host: GameSessionHost) async throws
    @MainActor func pause()
    @MainActor func resume()
    @MainActor func stop() async
}
```

**Launch:**
- Create a `MTLCreateSystemDefaultDevice()` device and a command queue. If either is nil, throw, and the host reports the error through `runtimeDidEnd(error:)`.
- Add a subview to `host.contentView` whose `layerClass` is `CAMetalLayer`, pinned to the edges.
- Configure the layer: pixel format `.bgra8Unorm`, and `framebufferOnly = true`.
- In the view's `layoutSubviews`, update `drawableSize` from bounds × `contentScaleFactor`. Pass the size to the render thread through a lock-guarded value.
- Add a small label in a corner of the content view showing "Command-buffer errors: N". A main-queue timer updates it about every 0.5 s. The label stays visible under the host's "Tap to resume" overlay, so the count can be read after returning from the background.
- Start the render thread (a `Thread` with a descriptive name). Keep `host.renderGate`.
- If `crashAfter` is set, schedule `abort()` after that delay.

**Render loop,** on its own thread and never on the main thread:
1. If a stop was requested, exit the loop.
2. `layer.nextDrawable()`. If nil, sleep briefly and continue. The drawable is acquired **before** entering the gate, so a blocking `nextDrawable` never holds the gate open while the host is trying to close it.
3. `guard gate.enter() else { sleep ~16 ms; continue }`. While the gate is closed, frames are skipped and the drawable is dropped.
4. Encode one frame, the animated pattern:
   - The minimal acceptable form is a render pass whose clear color cycles with time.
   - Optionally, add moving bands using scissor rects or a shader compiled at runtime with `device.makeLibrary(source:options:)`. This avoids adding a `.metal` file to the project.
   - The animation time freezes while paused.
5. `commandBuffer.addCompletedHandler`: if `status == .error` or `error != nil`, increment the error counter. The counter is guarded by an `NSLock`, because iOS 15 has no Swift atomics.
6. `present(drawable)`, `commit()`, then `gate.leave()` immediately after `commit()` returns. Never touch or wait on the main thread between `enter` and `leave`; this is the render-gate rule from section 10.
7. Pace to about 60 fps with a short sleep. A display link is not required.

**Lifecycle methods (main actor):**
- **`pause()`:** sets a lock-guarded `paused` flag that freezes animation time. The host has already closed the gate before calling it, so no GPU work is submitted.
- **`resume()`:** clears `paused`. The host opens the gate first.
- **`stop()`:**
  - Requests the thread to exit and waits for it with a bounded wait (a semaphore signalled when the loop exits; give up after about 1 s rather than block forever).
  - Invalidates the label timer.
  - Removes the Metal view.
  - Releases the device and queue.
  - Safe to call twice.

**Concurrency.** The class is main-actor-bound for protocol calls. The state shared with the render thread is:
- the stop flag
- the paused flag
- the drawable size
- the error count
- the animation clock

Keep it in a separate `final class ... : @unchecked Sendable` box guarded by one `NSLock`, so Swift 6 strict concurrency accepts it. The render thread captures only that box, the layer, the queue and the gate.

**Privacy.** This runtime has no game and no files. Its breadcrumbs are the host's standard ones, `sessionStart` through `sessionStop`, which are codes and integers only.

### 7. Strings

Add these keys to `App/en.lproj/Localizable.strings`, in the namespaces section 12 defined. Key names are suggestions; keep them consistent with section 12's maps.
- `status.section.routes`, `status.section.gates`, `status.section.developer`
- `route.serves.native-kirikiri`, `route.serves.native-renpy`, `route.serves.wine-fex`, `route.serves.wine-box64`, `route.serves.linux-fex`: engine captions, reached by an exhaustive switch over `RouteID`, never by string-building from the raw value
- `gate.state.passed`, `gate.state.failed`, `gate.state.failedStale`, `gate.state.unmeasured`
- `developer.runTestSession`, `developer.simulateCrash`, `developer.simulateCrash.footnote`
- `developer.replicaID`
- `developer.gates`, `developer.gates.empty`
- `developer.settingsForked`
- `developer.testPattern.errors` (a format string with an integer; add a `.stringsdict` plural entry if the wording needs one)

Reason sentences follow the plan's rules (§14): short sentences a non-expert can act on. For example:
- "Not yet verified on this device (x18 check). It may not work."
- "Planned. Not in this build yet."

These route strings already exist from section 12. Only add what is missing.

## Constraints to respect

- **No program titles anywhere.** The route table uses synthetic detections with generic names, and the test session has a synthetic id and route `"test"`. Nothing on this screen reads game folders.
- **iOS 15 minimum:**
  - use `ObservableObject`, `@ObservedObject` and `DisclosureGroup`
  - no `ShareLink`, `@Observable`, Swift `Atomic`/`Mutex` or `OSAllocatedUnfairLock`
  - `.onChange(of:)` with the single-value closure form is fine on iOS 14+
- **Swift 6 language mode** with complete concurrency checking.
- **Exhaustive enum→key switches** with no `default:`. `GateName` is a `RawRepresentable` struct, so switch over the known constants with `if`/`==` and fall back to the generic "<gate> check" string for others. That fallback is the one intended non-exhaustive case.
- **Main thread:** the main thread never waits unbounded on the render thread. The host's `close(timeout:)` is bounded, and `stop()` waits for at most about 1 s.

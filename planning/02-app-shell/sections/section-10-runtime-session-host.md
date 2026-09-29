# Section 10: Runtime protocol, render gate and game-session host

> **From section 07 (as built):** consume the sentinel at launch before any `arm`, because arming discards unconsumed evidence. Add the consumed session to `CrashHistory` right after consuming, because consuming deletes the files. `SessionSentinel.setPhase` throws when the sentinel is missing, so surface that rather than ignore it. The breadcrumb and fault writers are safe to call from any thread while `close` runs.

## Goal

This section builds the contract that every later runtime split plugs into, plus the full-screen host that runs a game session. The runtime splits are 03 (Kirikiri), 06–08 (Wine), 10 (Ren'Py), 13 (Linux) and 14 (Box64). It covers:

- `GameRuntime`, `LaunchableGame` and `GameSessionHost`, the protocol surface.
- `RuntimeRegistry`, which registers runtimes and caches their async can-run checks.
- `RenderGate`, the Swift face of the C in-flight guard, which stops GPU work when the app leaves the foreground.
- `SceneEvents`, an injectable seam for scene, audio and memory notifications.
- `GameSessionHostViewController`, the full-screen UIKit host. It handles pause, background, the "Tap to resume" overlay, audio interruptions, memory warnings, a small menu and hidden system UI.
- `GameSession`, which owns one session: the sentinel, the access token, suspending background work, and memory samples.
- `SessionPresenter`, which presents the host from the topmost presented controller.

No game runs in split 02 and no runtime is registered. Section 14's developer `TestPatternRuntime` is not a route, but it exercises this host.

## Background you need

- **Eikon** is an iPhone/iPad app (iOS 15 minimum, Swift 6 language mode with complete concurrency checking). Games will run **in-process**, so a crash in a game ends the app.
- **Two packages.**
  - `Packages/EikonCore` is platform-neutral (iOS 15 + macOS 13, no UIKit). It holds the pure logic, plus the C target `CEikonSession` (from section 01), which contains the render-gate atomics, the breadcrumb slot writer and the fault hook.
  - `Packages/EikonKit` is iOS-only and imports UIKit. It depends on EikonCore. Everything in this section lives in EikonKit, except `SessionPresenter`, which is thin App-target glue.
- **iOS 15 constraints.** There is no Swift `Atomic`/`Mutex` and no `OSAllocatedUnfairLock`, so atomics come from C11 in `CEikonSession`. Use `ObservableObject`, not `@Observable`.
- **01's code style.**
  - Small single-concept files.
  - `Sendable` protocol seams with a `Live*` implementation and a `.live` accessor.
  - Pure logic in caseless enums.
  - Exhaustive switches with no `default:`.
  - Fakes sit at the top of test files.
- **Owner's testing rule.** Tests are few and behavioral. Never assert constants, exact strings, timings or internal structure.
- **Privacy rule.** No program titles anywhere: not in logs, breadcrumbs or reports. Breadcrumbs carry only app-defined event codes and integers.
- **Types from earlier sections that this section uses** (reference only):
  - Section 02: `DetectionResult`, `Engine`, `CPUArchitecture`, `GamePlatform`, `ExecutableInfo`.
  - Section 03: `GameID` (random UUID) and `Keyed` (the HMAC hex value of a fingerprint's `exact` signal).
  - Section 06: `RouteID` (`native-kirikiri`, `native-renpy`, `wine-fex`, `wine-box64`, `linux-fex`) and `RuntimeCheck` (`.ok` / `.declined(RuntimeDeclineCode)`).
  - Section 07: `SessionRecord` (fields `sessionID`, `gameID`, `engine`, `architecture?`, `route: String` holding a `RouteID` raw value or `"test"`, `appBuild`, `startedAt`, `phase: running/background`), `SessionSentinel` (`arm(_:)`, `setPhase(_:)`, `disarm()`), `Breadcrumbs` with `BreadcrumbEvent`, and the fault-file open/close API over the C `eikon_session_fault_open`.
  - `BreadcrumbEvent` cases this section emits: `sessionStart`, `sessionPaused`, `sessionBackgrounded`, `sessionResumed`, `sessionStop`, `memoryWarning`, `memorySample(availableMB)`, `audioInterrupted`, `renderGateTimeout`, `runtimeError(code)`.
  - Section 01: the render-gate C functions in `CEikonSession`. The gate is an opaque heap-allocated handle with create, destroy, enter, leave, close-mark, open and in-flight-count operations. Use whatever names section 01 landed.

## Dependencies

- **Requires section 06** (`RouteID`, `RuntimeCheck`).
- **Requires section 07** (`SessionRecord`, `SessionSentinel`, `Breadcrumbs`/`BreadcrumbEvent`, the fault-file API). Transitively this also requires 01, 02 and 03.
- **Parallel with section 09.** Section 09 owns `FolderAccess`/`AccessToken`, `DriveScanner`/the fingerprint worker, `LibraryController` and the `GameDataCleanup`/`GameDataMerge` hooks. This section must **not** import those types. `GameSession` reaches them through small closure or protocol seams (see "GameSession environment"), and the App or section 09 wires the live values.
- `SettingsStore` flushing (section 05) is also reached through a closure seam.
- **Blocks:** section 11 (the crash report controller uses the sentinel lifecycle defined here) and section 14 (`TestPatternRuntime` and the developer "Run test session" and "Simulate crash" actions).

## Files

Create in `Packages/EikonKit/Sources/EikonKit/Runtime/`:

- `GameRuntime.swift`: the `GameRuntime` protocol, `LaunchableGame` and `GameSessionHost`.
- `RuntimeRegistry.swift`
- `RenderGate.swift`
- `SceneEvents.swift`: the `SceneEvent` enum, the `SceneEvents` protocol and `LiveSceneEvents`.
- `SessionRecorder.swift`: a seam over sentinel, breadcrumbs and fault file, plus its live implementation over section 07's types. It could live in `GameSession.swift` instead if small.
- `GameSession.swift`
- `GameSessionHostViewController.swift`
- `SessionPresentation.swift`: the pure "topmost presented controller" lookup, kept in EikonKit so it is testable.

Create in the App target:

- `App/Session/SessionPresenter.swift`: finds the key window scene's root controller, then uses the EikonKit lookup to present.

Tests in `Packages/EikonKit/Tests/EikonKitTests/`:

- `RuntimeTests.swift`: render gate and registry.
- `SessionHostTests.swift`: lifecycle and presentation.

Note: `Runtime/GameDataCleanup.swift` is in the same folder in the plan's layout but belongs to section 09. Don't create it here.

Package wiring:

- EikonKit needs `import CEikonSession` for `RenderGate`. If section 01 did not expose `CEikonSession` as a library product of the EikonCore package, add a product for it in `Packages/EikonCore/Package.swift`, and add it to the `EikonKit` target's dependencies in `Packages/EikonKit/Package.swift`.
- `AVFAudio`/`AVFoundation` (for `AVAudioSession`) and `os` (for `os_proc_available_memory()`) are system frameworks and need no package change.

## Tests first

Use Swift Testing (`import Testing`, free `@Test func` with behavior names, `#expect`/`#require`). These run on the simulator via `scripts/test_swift.sh` (`make test-swift`).

Fakes go at the top of the test file:

- **`FakeRuntime`** (a `GameRuntime`) records its calls (`launch`, `pause`, `resume`, `stop`) into a shared ordered log.
  - Its static `check` increments a lock-guarded call counter. Swift 6 disallows unguarded static mutable state: use a small lock-guarded class or `nonisolated(unsafe)` behind a lock.
  - A second fake runtime type with a different `route` is used for the "new registration" test.
- **`FakeSceneEvents`** lets the test send any `SceneEvent` synchronously.
- **`FakeSessionRecorder`** appends `arm`, `setPhase(.running/.background)`, breadcrumb events and `disarm` into the same ordered log. This lets tests check ordering against the gate and runtime calls.
- The **environment closures** (flush settings, open access returning a closer, suspend/resume background work, begin background task running its work immediately) append to the log.

### RenderGate

The C atomics are exercised through the Swift API.

```swift
@Test func renderGateEnterSucceedsWhileOpenAndFailsAfterClose()
@Test func renderGateCloseWaitsForInFlightFrameToLeave()
@Test func renderGateCloseReturnsFalseWhenFrameNeverLeaves()
```

- **Wait for `leave`:** a background thread calls `enter()`, signals, waits on a semaphore, then calls `leave()`. Assert `close` has not returned before the release, then that it returns `true` after it. Don't assert durations.
- **Timeout:** `enter()` and never `leave()`, then `close(timeout:)` with a small timeout returns `false`.

### Lifecycle

These use the host controller plus `GameSession`, with a fake runtime and fake `SceneEvents`. The controller can be created without presenting it. Drive it through its internal methods: `handle(_ event:)`, the overlay resume action, and quit.

```swift
@Test func willDeactivateClosesGateAndPausesRuntime()
@Test func phaseBecomesBackgroundOnlyOnDidEnterBackgroundAfterGateClosed()
@Test func didActivateSetsRunningButWaitsForOverlayResume()
@Test func audioInterruptionPausesAndItsEndDoesNotAutoResume()
@Test func quitStopsRuntimeDisarmsSentinelAndClosesAccessToken()
```

- **Background ordering:** after `willDeactivate` alone, the recorder has no `.background` phase. After `didEnterBackground`, `.background` appears in the log after the pause, and `renderGate.enter()` returns false.
- **Activation:** after `didActivate`, the phase is `.running`, `resume` has not been called, the overlay is visible, and `enter()` still fails. After the overlay resume action, `enter()` succeeds and `resume` was called once.
- **Audio interruption:** after `audioInterruptionBegan`, the runtime is paused. After `audioInterruptionEnded`, it is not resumed and the overlay is visible.
- **Quit:** the log shows `stop`, then `disarm`, then the access closer ran, and background work was resumed.

### Registry

```swift
@Test func runtimeChecksAreCachedPerRouteGameAndBuildAndRequeriedAfterRegistration()
```

- Checking the same (route, game id, build) twice calls the fake's static `check` once.
- A different build key calls it again.
- Registering another runtime type and checking the first key again calls it again.

### Presentation

```swift
@Test func presenterUsesTopmostPresentedController()
```

- Build a stub hierarchy: a root controller whose `presentedViewController` is A, whose presented controller is B. Use `UIViewController` subclasses that override `presentedViewController`, or run the lookup over a tiny protocol that `UIViewController` conforms to.
- Assert that the lookup returns B, and that presenting goes through B.

The test-pattern session (section 14) has no automated tests; device checks cover it.

## Implementation

### 1. `GameRuntime.swift`

The protocol, as the plan specifies it:

```swift
public protocol GameRuntime: AnyObject {
    static var route: RouteID { get }
    /// Game-specific check beyond RouteRules (plugins, Ren'Py version, ...). Runs off the
    /// main actor, may read files, must be cheap enough to run once per (game, build).
    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck
    @MainActor init()
    @MainActor func launch(_ game: LaunchableGame, in host: GameSessionHost) async throws
    @MainActor func pause()          // stop game time, audio, and GPU submission
    @MainActor func resume()
    @MainActor func stop() async     // tear down; release files
}

public struct LaunchableGame: Sendable {
    public var gameID: GameID
    public var root: URL             // game root, accessible for the session
    public var detection: DetectionResult
    public var route: RouteID
}

@MainActor public protocol GameSessionHost: AnyObject {
    var contentView: UIView { get }
    var renderGate: RenderGate { get }
    func runtimeDidEnd(error: Error?)
}
```

Documentation comments must state the render contract:

- Render threads call `host.renderGate.enter()` before encoding or committing GPU work, and `leave()` after `commit()` returns.
- When `enter()` returns false, skip the frame.
- Never block the render path on the main thread between `enter` and `leave`. The host may be waiting in `close(timeout:)` on the main thread.
- `pause()` must stop game time, audio and GPU submission. `resume()` undoes it.
- `stop()` must release every file under `root`.
- A runtime reports its own end (the game quit, or a fatal error) through `host.runtimeDidEnd(error:)`.

### 2. `RuntimeRegistry.swift`

`@MainActor public final class RuntimeRegistry: ObservableObject`:

- **`register<T: GameRuntime>(_ type: T.Type)`**
  - Stores the type, keyed by `T.route`.
  - Captures `T.check` into a `@Sendable (DetectionResult, URL) async -> RuntimeCheck` closure at registration. This avoids sending a non-`Sendable` metatype across isolation in Swift 6.
  - Invalidates the whole check cache.
  - Bumps a published value, so `LibraryController` (section 09) recomputes route decisions.
- **`builtRoutes: Set<RouteID>`** (published), which feeds `RouteEnvironment.builtRoutes`.
- **`runtimeType(for route: RouteID) -> (any GameRuntime.Type)?`**
- **`check(route:detection:root:cacheKey:) async -> RuntimeCheck`**
  - `cacheKey` is a small `Hashable` struct `RuntimeCheckKey { gameID: GameID; build: Keyed }`, where `build` is the location's exact fingerprint signal. A patch that changes the files therefore re-runs the check.
  - The cache key is (route, `RuntimeCheckKey`).
  - Store the in-flight `Task` in the cache, so concurrent callers share one check.
  - The check runs off the main actor, as a detached or nonisolated task calling the captured closure.
  - Only built routes are queried. For an unregistered route, `assertionFailure` in debug and return `.ok`. Callers should use the helper below instead.
- **Helper `checks(detection:root:cacheKey:) async -> [RouteID: RuntimeCheck]`** covers every registered route. This is what `RouteEnvironment.runtimeChecks` needs.

Runtimes are registered in `EikonApp.init` (section 12's wiring order, step 2). In 02 none are registered.

### 3. `RenderGate.swift`

`public final class RenderGate: @unchecked Sendable` wraps the opaque C handle. It is not actor-isolated, because render threads call it.

- `init()` creates the handle open. `deinit` destroys it.
- **`enter() -> Bool`** atomically increments the in-flight count. If the gate is closed, it undoes the increment and returns false. The C side is responsible for the correct ordering between the closed flag and the count.
- **`leave()`** decrements the count.
- **`close(timeout: TimeInterval = 0.1) -> Bool`** marks the gate closed, then polls the in-flight count with short sleeps (about 1 ms, `usleep`) until it is zero or the timeout passes.
  - Returns true when drained.
  - Never waits unbounded.
- **`open()`** clears the closed flag.

On `false`, the host records breadcrumb `renderGateTimeout` and continues. The host never calls `close` while holding anything a render thread needs.

### 4. `SceneEvents.swift`

```swift
public enum SceneEvent: Sendable, Equatable {
    case willDeactivate, didEnterBackground, didActivate
    case audioInterruptionBegan, audioInterruptionEnded
    case audioOldDeviceUnavailable
    case memoryWarning
}

@MainActor public protocol SceneEvents: AnyObject {
    /// Starts delivering events on the main actor. Delivery stops when the returned
    /// subscription is cancelled or released.
    func subscribe(_ handler: @escaping @MainActor (SceneEvent) -> Void) -> SceneEventsSubscription
}
```

`LiveSceneEvents(scene: UIWindowScene)` observes these notifications:

| Notification | Filter | Event |
|---|---|---|
| `UIScene.willDeactivateNotification` | `object:` = the host's own scene | `willDeactivate` |
| `UIScene.didEnterBackgroundNotification` | `object:` = the host's own scene | `didEnterBackground` |
| `UIScene.didActivateNotification` | `object:` = the host's own scene | `didActivate` |
| `AVAudioSession.interruptionNotification` | interruption type `.began` / `.ended` | `audioInterruptionBegan` / `audioInterruptionEnded` |
| `AVAudioSession.routeChangeNotification` | reason `.oldDeviceUnavailable` only | `audioOldDeviceUnavailable` |
| `UIApplication.didReceiveMemoryWarningNotification` | none | `memoryWarning` |

Filtering by scene means another window scene on iPad does not pause the game. Hop to the main actor before calling the handler. The host gets its scene from `view.window?.windowScene` once it is in a window, or the presenter passes it in.

### 5. `SessionRecorder.swift`

This is an EikonKit seam, so tests can observe the sentinel phase without consuming the files:

```swift
@MainActor public protocol SessionRecorder: AnyObject {
    func arm(_ record: SessionRecord) throws   // sentinel arm + open fault file
    func setPhase(_ phase: SessionRecord.Phase)
    func add(_ event: BreadcrumbEvent)
    func disarm()                              // close fault file + sentinel disarm (removes breadcrumbs/fault)
}
```

`LiveSessionRecorder` wraps section 07's `SessionSentinel`, `Breadcrumbs` and fault-file API over `Application Support/Eikon/sessions/`.

### 6. `GameSession.swift`

`@MainActor public final class GameSession` owns one session.

**GameSession environment.** Seams are injected, so this section never names section 05 or 09 types:

- `flushSettings: @MainActor () -> Void`
- `openAccess: @MainActor () throws -> (@MainActor () -> Void)`. It opens the drive's access token and returns its closer. Section 09's `AccessToken.close()` is wired in by the caller. Test sessions pass a no-op.
- `backgroundWork: SessionBackgroundWork`, a protocol with `suspendForSession()` and `resumeAfterSession()`. Section 09's scanner and fingerprint worker implement it, and the App wires them.
- `recorder: SessionRecorder`
- `appBuild: String`, `now: () -> Date`, `availableMemoryMB: () -> Int` (live: `os_proc_available_memory() / 1_048_576`)
- `beginBackgroundTask: @MainActor (_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) -> Void`. The live version wraps `UIApplication.shared.beginBackgroundTask`/`endBackgroundTask`. Fakes run the work immediately.

Inputs are the `LaunchableGame`, the runtime type (`any GameRuntime.Type`) and a `sentinelRoute: String`, which defaults to `game.route.rawValue`. Section 14's test sessions pass `"test"` and a fixed synthetic game id; the test-pattern runtime ignores `game.route`.

**Start**, in exactly this order:

1. `flushSettings()`.
2. Open the access token (`openAccess`).
3. Arm the sentinel and open the fault file: `recorder.arm(SessionRecord(...))` with a new session UUID, phase `running`.
   - `engine` comes from the detection.
   - `architecture` is the main executable's architecture for the route's platform: `wine-*` → windows, `linux-fex` → linux, native routes → the Windows executable if there is one, otherwise nil.
   - Then add breadcrumb `sessionStart`.
4. `backgroundWork.suspendForSession()`.
5. Create the runtime (`type.init()`), open the render gate, and `await runtime.launch(game, in: host)`.

If any step throws, unwind the steps already done in reverse order. If `launch` throws, add breadcrumb `runtimeError(code)`, using the `NSError` code of the error; codes and integers only. Then report the error to the caller.

**End.** This path is idempotent, and quit, `runtimeDidEnd` and launch failure all share it:

1. `await runtime.stop()`, unless the runtime itself reported the end.
2. Add breadcrumb `sessionStop`, then `recorder.disarm()`, which closes the fault file and removes the sentinel.
3. Run the access closer.
4. `backgroundWork.resumeAfterSession()`.
5. Invalidate the memory timer.

**Memory samples.** A repeating timer runs every 30 s while the session is running. It records `memorySample(availableMB)`. The host also records a sample on a memory warning.

Only one session may be active at a time. The presenter refuses a second one.

### 7. `GameSessionHostViewController.swift`

`@MainActor public final class GameSessionHostViewController: UIViewController, GameSessionHost`.

**Hidden system UI.**
- Override `prefersStatusBarHidden` → `true`, `prefersHomeIndicatorAutoHidden` → `true`, and `preferredScreenEdgesDeferringSystemGestures` → `.all`.
- Set `modalPresentationStyle = .fullScreen` and `modalPresentationCapturesStatusBarAppearance = true`.
- Call the `setNeedsUpdateOf…` methods after appearing.

**Views.**
- `contentView` is a full-bleed subview that the runtime owns.
- The "Tap to resume" overlay sits above it. Expose an `isResumeOverlayVisible` read for tests.
- A small auto-hiding menu button opens a menu with **Resume** and **Quit**. Resume is the same action as the overlay tap.
- Strings come from `Localizable.strings` keys under `session.*`. Section 12 owns the string files, so add the keys there, or leave them as keys until 12 lands.

**Event handling.** `handle(_ event: SceneEvent)` is internal, so tests can call it. Keep an `isPaused` flag so that pausing is idempotent: `runtime.pause()` is called once per pause episode.

| Event | Action |
|---|---|
| `willDeactivate` | `pauseSession()`: close the render gate (`close(timeout:)`, adding `renderGateTimeout` if it returns false), call `runtime.pause()`, add breadcrumb `sessionPaused`. |
| `didEnterBackground` | Inside `beginBackgroundTask`: make sure the pause has completed and the gate is closed (call `pauseSession()` if not already paused). Then `recorder.setPhase(.background)`, `flushSettings()`, breadcrumb `sessionBackgrounded`, and end the task. The phase must not change to `background` anywhere else. |
| `didActivate` | `recorder.setPhase(.running)` and show the resume overlay. Do **not** open the gate or resume. |
| `audioInterruptionBegan` | Breadcrumb `audioInterrupted`, then `pauseSession()`. |
| `audioInterruptionEnded` | Show the overlay. Never auto-resume. |
| `audioOldDeviceUnavailable` | `pauseSession()` and show the overlay. |
| `memoryWarning` | Breadcrumb `memoryWarning` plus a `memorySample`. |

- **Resume action** (overlay tap or menu Resume): open the gate, call `runtime.resume()`, add `sessionResumed`, hide the overlay, and clear `isPaused`.
- **Quit** (menu): end the session through `GameSession`'s end path, which awaits `runtime.stop()`. Then dismiss.
- **`runtimeDidEnd(error:)`:** if there is an error, add `runtimeError(code)`. Then end the session without calling `stop()` again, and dismiss.

Subscribe to `SceneEvents` when the session starts and cancel the subscription on end. The host holds the drive's access token through `GameSession` for the whole session. Unplugging a USB drive mid-game may crash the app; that is an accepted risk, and the sentinel reports it on the next launch.

### 8. `SessionPresentation.swift` (EikonKit) and `App/Session/SessionPresenter.swift`

**EikonKit.** A caseless enum, `SessionPresentation`, with:
- `static func topmostPresented(from root: UIViewController) -> UIViewController`, which follows `presentedViewController` to the end of the chain.
- `static func present(_ host: GameSessionHostViewController, from root: UIViewController)`, which presents the host full screen, non-animated or animated, from that topmost controller.

**App.** `SessionPresenter` (`@MainActor`):
1. Finds the foreground-active `UIWindowScene`'s key window and takes its `rootViewController`.
2. Builds the `GameSession` environment from the app's live objects: the settings flush, the drive access opener from `LibraryController`/`DriveManager`, the scanner as `SessionBackgroundWork`, and `LiveSessionRecorder`.
3. Creates the host with `LiveSceneEvents(scene:)` and presents it through `SessionPresentation`.

`SessionPresenter` is the single entry point used by the Launch button (section 13) and the developer test-session actions (section 14). It refuses to start while a session is already active.

## Done when

- `RuntimeTests.swift` and `SessionHostTests.swift` pass under `make test-swift`.
- `make test` stays green.
- The app builds with no runtimes registered, and `RuntimeRegistry.builtRoutes` is empty.
- The device checks run with section 14's test pattern:
  - Pulling down Control Center pauses the session.
  - Going Home backgrounds it.
  - After 30 s in the background, returning shows "Tap to resume", and the command-buffer error count stays 0.

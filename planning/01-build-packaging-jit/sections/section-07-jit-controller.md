# Section 07 · JIT controller, status store and app wiring

## Goal

Tie the pure JIT policy (section 06) to the running app:

- a `JITSystem` seam over the C layer and sysctl, with a live implementation that short-circuits in the simulator
- a small `JITClock` seam, so tests control time
- `JITStatusStore`, a lock-protected snapshot any thread can read
- `JITController.shared`, the single main-actor owner of JIT state: gathering facts at launch, reacting to scene activation, the TrollStore enable-JIT request flow, and the two retry actions
- `EikonApp` holding the controller and forwarding scene-phase changes

When this section is done, the app computes a real `JITStatus` at launch, asks TrollStore for JIT once when appropriate without bouncing, notices JIT that appears later, and publishes every status change both to SwiftUI and to the thread-safe store.

## Dependencies

- **Section 05 (install detection):** `InstallMethod`, `InstallEvidence`, `BundleEnvironment` (and its live implementation), `detectInstallMethod(_:)`, the run-time bundle id helper.
- **Section 06 (JIT core):** the C functions `eikon_cs_flags`, `eikon_jit_probe`, `eikon_txm_firmware_present`; the Swift types `TXMState`, `TXMInfo`, `CSDebuggedSeen`, `JITSource`, `JITReasonCode`, `ProbeOutcome`, `JITStatus`, `JITFacts`, `TrollStoreRequestState` (`none`, `pending`, `timedOut`); `JITPolicy.mayProbe`, `JITPolicy.status`, `JITPolicy.shouldRequestTrollStoreJIT`; the TXM derivation (`JITPolicy.txmInfo(firmware:osMajor:cpuFamily:)` or equivalent); the crash sentinel `ProbeSentinel` (a directory plus a build number, with `arm()`, `disarm()` and `consumeAtLaunch() -> Bool`); and the cooldown constant. If section 06 named any of these differently, use its names; the behaviour below does not change.
- **Blocks section 09** (status UI), which reads the controller's published properties and calls the retry actions.
- Can be built in parallel with section 08 (device report). Section 08 may reuse the `SystemInfo` helpers defined here.

## Background

"JIT" means the process may execute pages it wrote itself. On iOS that holds when the kernel has set `CS_DEBUGGED` in the process's code-signing flags. Eikon never attaches a debugger, never calls `ptrace` or task-for-pid, and never uses `MAP_JIT`. It relies on:

- **Dopamine:** sets `CS_DEBUGGED` before `main()`. Nothing to request.
- **TrollStore 2.0.12+:** opening `apple-magnifier://enable-jit?bundle-id=<bundle id>` switches to TrollStore, which attaches to the **running** process, waits about 100 ms, detaches, and brings the app back. `CS_DEBUGGED` stays set. The app is **not relaunched**. The failure to guard against is bouncing to TrollStore repeatedly. On older TrollStore, or with its URL scheme disabled, nothing happens, so the app waits with a deadline.
- **AltStore:** an external enabler may attach and detach while the app runs. Eikon only detects this, typically on returning to the foreground.
- **Bundle id:** AltStore free accounts may rewrite it. Always use the run-time `Bundle.main.bundleIdentifier`, never the literal project bundle id.

Why the probe is gated: without JIT, mapping a page RX succeeds but executing it gets an uncatchable SIGKILL. The probe therefore runs only when `JITPolicy.mayProbe` allows it, and is only a confirmation. `usable = csDebugged && probe passed`, and it can change from false to true during the process lifetime. Consumers must tolerate that.

In the simulator, `csops` reflects host conditions (for example an attached debugger), and the TXM firmware check would read the Mac's preboot. Neither is trusted there.

**iOS 15 API floor.** No `Mutex`, `OSAllocatedUnfairLock`, `@Observable` or Swift's `Clock` protocol (all iOS 16+). The controller is an `ObservableObject`; the store uses `NSLock` (or a small `os_unfair_lock` wrapper); time goes through the `JITClock` seam defined here. `Task.sleep(nanoseconds:)` is available on iOS 15.

## Tests first

File: `Packages/EikonKit/Tests/EikonKitTests/JITControllerTests.swift` (Swift Testing, `@testable import EikonKit`, tests marked `@MainActor`).

Owner's rule: few, behavioral tests. Do not assert timing constants, URL string texts beyond containing the bundle id, reason-code texts, or internal structure.

### Test doubles (in the test target)

- **`FakeJITSystem`** (`final class`, `@unchecked Sendable`, state behind a lock): a settable `csDebugged` flag that can flip at any time; `txm(...)` returns a fixed `TXMInfo` with state `absent`, not enforced; `probe()` returns `.passed` and counts calls.
- **URL recorder:** a small main-actor class holding the opened URLs, a configurable result (`true`/`false`), and an optional closure run on open (used to flip the fake's `csDebugged`, simulating TrollStore attaching). The controller receives `{ await recorder.open($0) }`.
- **`FakeClock`** (conforms to `JITClock`): virtual time that starts at a fixed date; `sleep(seconds:)` advances virtual time by the requested amount and calls `await Task.yield()`, so deadlines pass instantly and no test depends on the real duration of any constant.
- **Bundle environment:** reuse section 05's fake `BundleEnvironment` if it lives in the test target; otherwise add a minimal one in `Tests/EikonKitTests/Support/FakeBundleEnvironment.swift` that reports a `_TrollStore` marker next to the bundle, so detection yields `trollStore`.
- **Isolation:** each test gets its own `UserDefaults(suiteName: UUID().uuidString)` (removed at the end), a temporary directory for the `ProbeSentinel`, its own `JITStatusStore` instance, and a non-default bundle id such as a rewritten sideload-style id. Swift Testing runs tests in parallel, so no test touches `JITController.shared` or `JITStatusStore.shared`.

### Tests

1. **One request, no bounce.** On a TrollStore install without JIT, the first `sceneBecameActive()` opens exactly one URL, and that URL contains the injected run-time bundle id. After the request finishes (await `waitForPendingRequest()`), a second `sceneBecameActive()` opens nothing more.
2. **JIT arrives from TrollStore.** The recorder's open closure flips the fake's `csDebugged` to true. After `waitForPendingRequest()`, `status.usable` is true, `status.source == .trollStore`, and `isRequestingTrollStoreJIT` is false.
3. **Deadline without reactivation.** `csDebugged` never becomes true. After the first `sceneBecameActive()` and `waitForPendingRequest()`, with no further activation, the status is not usable with reason `.trollStoreTimedOut` and `isRequestingTrollStoreJIT` is false.
4. **Open fails.** The recorder returns `false`. The request ends with reason `.trollStoreTimedOut` and the flag cleared, and the fake clock shows no elapsed time. That proves it didn't wait out the deadline, without comparing against the deadline constant.
5. **Store mirrors the controller.** The `JITStatusStore` passed to the controller has `current == controller.status` after `gatherFacts()`, and again after the request in test 2 changes the status.

No simulator test runs the real probe. The real probe is verified through the Xcode-debugged device run and device reports.

## Implementation

All new Swift files go in `Packages/EikonKit/Sources/EikonKit/`. Types used by the app are `public`; test-only hooks are `internal`.

### `JITClock.swift`

```swift
/// Minimal time seam (Swift's Clock protocol needs iOS 16).
public protocol JITClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct LiveJITClock: JITClock { /* Date(); Task.sleep(nanoseconds:) */ }
```

### `SystemInfo.swift`

Small helpers, reusable by section 08:

- `SystemInfo.osMajor: Int` from `ProcessInfo.processInfo.operatingSystemVersion.majorVersion`.
- `SystemInfo.cpuFamily: UInt32` from `sysctlbyname("hw.cpufamily")` (0 if the call fails).
- `SystemInfo.isSimulator: Bool` via `#if targetEnvironment(simulator)`.
- `SystemInfo.buildNumber: String` from the main bundle's `CFBundleVersion`.

### `JITSystem.swift`

```swift
/// Seam over the C layer and sysctl so tests inject facts without a device.
public protocol JITSystem: Sendable {
    func csDebugged() -> Bool
    func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo
    func probe() -> ProbeOutcome
}

public struct LiveJITSystem: JITSystem { ... }
extension JITSystem where Self == LiveJITSystem { public static var live: LiveJITSystem { get } }
```

Live behaviour:

- `csDebugged()`: calls `eikon_cs_flags`; true when it returns 0 and the flags contain `CS_DEBUGGED` (`0x10000000`). False on error.
- `txm(osMajor:cpuFamily:)`: in the simulator, returns state `absent`, `enforced = false`, basis "simulator". On device, passes `eikon_txm_firmware_present()` with the arguments to section 06's TXM derivation; it does not duplicate the table or the rules.
- `probe()`: in the simulator, returns `notRun` with a detail saying simulator, and never calls the C probe. On device, calls `eikon_jit_probe()` and maps the result to `ProbeOutcome` (`passed`, or `failed` with a detail naming the failed step, or the signal number, or the errno). Callers guarantee `mayProbe` was true; the live system does not re-check policy.

### `JITStatusStore.swift`

```swift
/// Thread-safe snapshot for non-UI code (FEX/Box64 threads in later splits).
public final class JITStatusStore: @unchecked Sendable {
    public static let shared: JITStatusStore
    public init(initial: JITStatus = .placeholder)
    public var current: JITStatus { get }      // nonisolated; lock-protected read
    func update(_ status: JITStatus)           // lock-protected write; called by JITController
}
```

- Lock: `NSLock` (or an `os_unfair_lock` wrapper allocated once on the heap). No iOS 16 locks.
- `JITStatus.placeholder` (defined here as an extension): a conservative not-usable status for reads before the controller has gathered facts. Build it by calling `JITPolicy.status` on facts with install method `unknown`, `csDebugged = false`, seen `never`, TXM `unknown` and treated as enforced (basis "not gathered"), request `none`, sentinel not blocking, and probe `notRun` ("not gathered"). Going through the policy keeps the "reason is nil exactly when usable" rule.

### `JITController.swift`

```swift
@MainActor
public final class JITController: ObservableObject {
    public static let shared: JITController          // live environment, .live system, .standard defaults,
                                                     // UIApplication open, LiveJITClock, Bundle.main id,
                                                     // sentinel in Library/Caches, JITStatusStore.shared
    @Published public private(set) var status: JITStatus
    @Published public private(set) var installMethod: InstallMethod
    @Published public private(set) var evidence: InstallEvidence
    @Published public private(set) var isRequestingTrollStoreJIT: Bool

    public init(environment: BundleEnvironment,
                system: JITSystem,
                defaults: UserDefaults,
                openURL: @escaping @MainActor (URL) async -> Bool,
                clock: JITClock,
                bundleIdentifier: String?,
                sentinel: ProbeSentinel,
                store: JITStatusStore)

    public func gatherFacts()          // at App init; may probe
    public func sceneBecameActive()    // first call may request TrollStore JIT; later calls re-check
    public func retryTrollStoreJIT()   // Retry JIT button
    public func retryProbe()           // Retry probe button

    func waitForPendingRequest() async // internal test hook: awaits the in-flight request task, if any
}
```

The extra `init` parameters beyond the plan's (`bundleIdentifier`, `sentinel`, `store`) exist so tests can inject a rewritten bundle id, a temporary sentinel directory and a private store. `.shared` is created lazily on first access (a `static let`), and nothing but tests constructs another instance.

The live `openURL` for `.shared` uses `UIApplication.shared.open(url)` (the async form returning `Bool`) inside `#if canImport(UIKit)`.

**Internal state** (private): the current `JITFacts` (install method, `csDebugged`, `csDebuggedSeen`, TXM, TrollStore request state, sentinel block), the last `ProbeOutcome`, `hasActivated` (first activation seen), `triedTrollStoreThisProcess`, and `requestTask: Task<Void, Never>?`.

**Named timing constants** (private, not asserted by tests): overall request deadline about 10 s, poll interval about 200 ms, grace period about 300 ms. The cooldown constant and its `UserDefaults` key come from section 06 if it defines them; otherwise define them here (about one minute; key such as `eikon.lastTrollStoreJITAttempt`).

**`init`:** detects the install method and evidence (`detectInstallMethod`) so the published properties are real from the start, sets `status` to `.placeholder`, and pushes it to the store. No probing, no URL calls.

**`publish()` (private):** `status = JITPolicy.status(facts, probe: lastProbe)`, then `store.update(status)`. Every state change goes through it.

**`gatherFacts()`:**
1. Re-detect the install method and evidence.
2. `csDebugged = system.csDebugged()`; if true, `csDebuggedSeen = .atLaunch`, else `.never`.
3. `txm = system.txm(osMajor: SystemInfo.osMajor, cpuFamily: SystemInfo.cpuFamily)`.
4. `probeBlockedBySentinel = sentinel.consumeAtLaunch()` (a sentinel from this build blocks exactly one launch; it is deleted either way).
5. Request state `none`.
6. `runProbeIfAllowed()`, then `publish()`.

**`runProbeIfAllowed()` (private):** if the last probe already passed, do nothing. If `JITPolicy.mayProbe(facts)`: `sentinel.arm()`, `lastProbe = system.probe()`, `sentinel.disarm()`. Otherwise leave `lastProbe` as `notRun` with a short detail (for example no `CS_DEBUGGED`, TXM, simulator, or skipped after crash).

**`sceneBecameActive()`:**
- **First call** (`hasActivated == false`): set `hasActivated`. Then evaluate `JITPolicy.shouldRequestTrollStoreJIT(installMethod:, csDebugged:, triedThisProcess:, lastAttempt: defaults value, now: clock.now(), manual: false)`.
  - If true, start the request flow.
  - If false on a TrollStore or TrollStore Lite install without `CS_DEBUGGED` (the cooldown suppressed it), set the request state to `timedOut` and publish, so the UI offers Retry JIT instead of a pending row forever.
  - Otherwise fall through to the re-check below.
- **Re-check** (first call when no request started, and every later call): if a request is in flight, do nothing (its poll loop owns detection). Otherwise read `system.csDebugged()`. If it changed from false to true, set `csDebuggedSeen = .onForeground`, run `runProbeIfAllowed()`, and publish. If nothing changed, do not publish.

**Request flow (`startTrollStoreRequest(manual:)`, private):**
1. Record the attempt time in `defaults` and call `synchronize()`. Set `triedTrollStoreThisProcess = true`, `isRequestingTrollStoreJIT = true`, request state `pending`; publish (reason `trollStoreRequestPending`).
2. Build the URL with `URLComponents`: scheme `apple-magnifier`, host `enable-jit`, query item `bundle-id` = the injected run-time bundle id. If the bundle id is nil, treat it as an open failure.
3. `requestTask = Task { @MainActor in ... }`:
   - `let opened = await openURL(url)`. If `false`, finish as timed out immediately (no waiting).
   - Note `start = clock.now()`. Loop while `clock.now() - start < deadline`: `try? await clock.sleep(seconds: pollInterval)`; if `system.csDebugged()` is true, break out as success. The loop runs regardless of scene phase.
   - **Success:** set `csDebugged = true`, `csDebuggedSeen = .afterTrollStoreRequest`, sleep the grace period so TrollStore's tracer has detached, `runProbeIfAllowed()`, request state back to `none`, clear `isRequestingTrollStoreJIT`, publish. Source attribution (`trollStore`) comes from the policy.
   - **Timeout or open failure:** request state `timedOut`, clear `isRequestingTrollStoreJIT`, publish.
4. Only one request runs at a time; a call while one is in flight is ignored.

**`retryTrollStoreJIT()`:** if no request is in flight and `shouldRequestTrollStoreJIT(..., manual: true)` is true, run the same flow with `manual: true` (cooldown ignored; the attempt time is still recorded).

**`retryProbe()`:** clears `probeBlockedBySentinel` and a previous failed/not-run outcome, re-reads `system.csDebugged()` (keeping the earliest `csDebuggedSeen`, or `.onForeground` if newly set), runs `runProbeIfAllowed()` (which arms the sentinel again, so a crash here skips the probe once on the next launch), and publishes.

**Simulator:** the install method is `simulator`, `mayProbe` is false and the live system never probes, so the status reason is `simulator`. No TrollStore request is made because the install method is not TrollStore.

### App wiring (`App/EikonApp.swift`)

- `EikonApp` holds `@ObservedObject private var jit = JITController.shared` and reads `@Environment(\.scenePhase)`.
- `init()` accesses `JITController.shared` and calls `gatherFacts()`. No UI and no URL calls at init.
- The `WindowGroup` root view (whatever section 02 created; section 09 replaces it with `StatusView`) receives the controller with `.environmentObject(jit)`.
- `.onChange(of: scenePhase)` (iOS 14+): on `.active`, call `jit.sceneBecameActive()`. Every activation is forwarded; the controller decides what the first one does.
- In the simulator, confirm by running the app that the first `.active` transition reaches the controller (the status then shows the `simulator` reason and nothing is opened).

### Consumers

Later splits read `JITStatusStore.shared.current.usable` from any thread, or observe `JITController.shared` on the main actor. Both must tolerate `usable` changing from false to true.

## Done when

- `make test-swift` passes, including the five controller tests.
- The app launches in the simulator, shows the simulator reason, and opens no URL.
- No file in this section contains a program or game title, and nothing uses an iOS 16+ API.

---

## Implementation notes (as built)

Files in `Packages/EikonKit/Sources/EikonKit/`: `JITClock.swift`, `SystemInfo.swift`, `JITSystem.swift`, `JITStatusStore.swift` and `JITController.swift`. Tests are in `Tests/EikonKitTests/JITControllerTests.swift`: the five behavioural tests from the plan. `App/EikonApp.swift` holds `JITController.shared`, calls `gatherFacts()` from `init`, passes the controller to the existing placeholder `StatusView` with `.environmentObject`, and forwards every `.active` scene phase.

Differences from the plan:

- Section 06 did not define a UserDefaults key, so the controller uses `eikon.lastTrollStoreJITAttempt`. The interval stays `JITPolicy.trollStoreCooldown` (one minute).
- If `ProbeSentinel.arm()` throws, the probe does not run. The outcome stays `notRun`.
- The placeholder status screen does not display the JIT reason; section 09 does. `make test-swift` passed (19 Swift tests, including the five controller tests) and the installed app stayed running in the simulator. On the simulator the install method is `.simulator`, so the policy reason is `simulator` and no TrollStore URL is opened.

The review found nothing to change. The trail is in `../implementation/code_review/section-07-*.md`.

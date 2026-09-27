# Section 06: JIT core (C layer, pure policy, crash sentinel)

## Goal

This section builds the parts of Eikon's JIT support that make no decisions about timing or UI:

1. **The C layer** (`CEikonJIT`). It reads the process's code-signing flags, runs a functional JIT probe, and checks for TXM firmware.
2. **The Swift policy types and `JITPolicy`** (`EikonKit`). These are pure functions that turn gathered facts into a `JITStatus`: whether JIT is usable, where it came from, and a reason code when it isn't. They also decide when the probe may run and when to ask TrollStore for JIT.
3. **The TXM table.** It maps each CPU family to the first iOS major version on which TXM is enforced.
4. **The crash sentinel.** It makes sure a probe that killed the process is skipped on exactly one following launch.

The controller that calls all of this at launch and on foreground, the TrollStore URL flow, the `JITSystem` seam and the thread-safe status store belong to section 07. The status screen belongs to section 09.

## Dependencies

- **Requires section 05 (install detection).** This section uses `InstallMethod` (`dopamine`, `rootlessJailbreak`, `trollStore`, `trollStoreLite`, `sideloaded`, `simulator`, `unknown`) from `EikonKit`.
- **Requires section 02 (Xcode project).** It uses the empty `CEikonJIT` C target, the `EikonKit` Swift target and the `EikonKitTests` Swift Testing target in `Packages/EikonKit`, which run through `make test-swift` on the simulator.
- **Blocks section 07** (controller and store) and **section 08** (the device report embeds `JITStatus`).

## Background

### What "JIT" means here

"JIT" means the process may execute pages it wrote itself. On iOS this holds when the kernel has set `CS_DEBUGGED` (`0x10000000`) in the process's code-signing flags. The flags are read with the private libsystem call `csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags)`, which needs no entitlement.

How each install method gets `CS_DEBUGGED`:

- **Dopamine 2.1+ and 3.x.** The jailbreak sets `CS_DEBUGGED` before `main()` for apps under its `Applications` directory when "Allow JIT in Apps" is on (the default). It may also do so for apps in the normal container directory, so a `.tipa` or `.ipa` on a Dopamine device can start with JIT. JIT is absent when the toggle is off, tweak injection is disabled for the app (Choicy), the device is in safe mode, or the jailbreak is Dopamine 2.0.x.
- **Other rootless jailbreaks** (also using `/var/jb`) may or may not provide JIT.
- **TrollStore 2.0.12+.** Opening `apple-magnifier://enable-jit?bundle-id=<bundle id>` makes TrollStore attach briefly to the **running** app and detach, leaving `CS_DEBUGGED` set. Older TrollStore, or a disabled URL scheme, does nothing. The request flow itself is section 07; this section only decides whether a request should happen.
- **AltStore / sideloaded.** An external enabler may set `CS_DEBUGGED`. Eikon only detects it.
- **TXM (iOS 26+, on chips that have it).** `CS_DEBUGGED` is not enough. Every executable JIT region must be approved by a debugger that stays attached, and executing an unapproved region kills the process. Eikon reports `txmEnforced` and must never execute JIT code there.

**Hard rules.** Eikon never attaches a debugger and never calls `ptrace` or task-for-pid. It never uses `MAP_JIT` and never relies on `dynamic-codesigning`.

### Why the probe is gated

Without JIT, mapping a page RX *succeeds*, but executing it makes the kernel send `SIGKILL`, which can't be caught. So the probe is only a **confirmation**. It runs only when `CS_DEBUGGED` is set, TXM doesn't block it, it isn't a simulator, and the crash sentinel doesn't forbid it. It is never used to discover JIT.

### Why `usable`

Later splits pick routes from one question: can this process run generated code now? The answer is `usable = csDebugged && probe passed`. It can change from false to true during the process lifetime, for example when TrollStore or an enabler attaches.

## Files

Create:

- `Packages/EikonKit/Sources/CEikonJIT/include/CEikonJIT.h`: the public C header.
- `Packages/EikonKit/Sources/CEikonJIT/CEikonJIT.c`: `eikon_cs_flags`, `eikon_jit_probe`, `eikon_txm_firmware_present`. Splitting it into several `.c` files is fine.
- `Packages/EikonKit/Sources/EikonKit/JITTypes.swift`: `TXMState`, `TXMInfo`, `CSDebuggedSeen`, `JITSource`, `JITReasonCode`, `ProbeOutcome`, `TrollStoreRequestState`, `JITStatus`, `JITFacts`.
- `Packages/EikonKit/Sources/EikonKit/JITPolicy.swift`: `JITPolicy`.
- `Packages/EikonKit/Sources/EikonKit/TXMTable.swift`: the CPU-family table and TXM derivation.
- `Packages/EikonKit/Sources/EikonKit/ProbeSentinel.swift`: the crash sentinel.
- `Packages/EikonKit/Tests/EikonKitTests/JITPolicyTests.swift`
- `Packages/EikonKit/Tests/EikonKitTests/ProbeSentinelTests.swift`

Modify only if needed: `Packages/EikonKit/Package.swift`, so that `EikonKit` depends on `CEikonJIT`. Section 02 may already have done this.

Types used by the app target must be `public`. The package builds in Swift 6 language mode with complete strict concurrency, so every type here is `Sendable`. The iOS 15 floor applies: no `Mutex`, no `OSAllocatedUnfairLock`, no Swift `Regex`.

## Tests first

These are Swift Testing tests in `EikonKitTests`, run on the simulator. They are few and behavioral. They must not pin constant values (such as the cooldown length or the table's entries), string texts, or internal structure. Build `JITFacts` by hand for each case. A small test-local helper such as `facts(install:csDebugged:seen:txm:request:sentinel:)` with sensible defaults keeps the cases short.

### C layer

No simulator unit test for the probe. Executing a remapped page in the simulator is not representative, and the live system (section 07) never probes there. The probe is verified through an Xcode-debugged run on a device and through device reports.

### `JITPolicyTests.swift`

1. **Reason exactly when not usable.** Walk a representative set of combinations of install method × `CS_DEBUGGED` × TXM (absent, enforced, unknown) × probe outcome (`notRun`, `passed`, `failed`). For every resulting status, `reason == nil` exactly when `usable` is true.
2. **`usable` needs a passed probe.** With `CS_DEBUGGED` set but the probe `notRun` or `failed`, `usable` is false.
3. **`mayProbe` refuses when unsafe.** It is false in each of these cases:
   - no `CS_DEBUGGED`
   - TXM enforced
   - TXM undetermined (`unknown`) on iOS 26+
   - simulator install
   - `probeBlockedBySentinel`

   It is true for a TrollStore install and for a Dopamine install with `CS_DEBUGGED` and TXM absent.
4. **Attribution needs a request.** On a TrollStore install with `CS_DEBUGGED`, the source is `trollStore` when it was seen `afterTrollStoreRequest`, and not `trollStore` when it was seen `atLaunch`.
5. **`shouldRequestTrollStoreJIT`.** Use a fixed `now`.
   - true for an automatic first attempt on a TrollStore install without `CS_DEBUGGED` and `lastAttempt: nil`
   - false on a non-TrollStore install
   - false when `triedThisProcess` is true
   - false with `lastAttempt = now`
   - true with `lastAttempt = .distantPast`
   - true for a manual retry even with `lastAttempt = now` and `triedThisProcess` true

   None of these reference the cooldown constant.
6. **Unknown CPU families are conservative.** A CPU family that isn't in the table, with the firmware check undeterminable, gives TXM enforced on iOS 26+ and not enforced below 26.
7. **Round trip.** A `ProbeOutcome` and a `JITStatus` each encode with `JSONEncoder` and decode to equal values. The encoded status contains a `usable` key.

### `ProbeSentinelTests.swift`

Use a fresh temporary directory in place of `Library/Caches`.

1. **Skip exactly one launch.** Arm a sentinel for build number `B` and don't disarm it (a simulated crash). A new sentinel for build `B` in the same directory returns true from `consumeAtLaunch()`. Facts built with that result are refused by `mayProbe`. A second `consumeAtLaunch()` (the next launch) returns false, and facts built from it allow the probe.
2. **Other builds don't block.** Arm for build `A`, then `consumeAtLaunch()` for build `B` returns false. A later call for `A` also returns false, because the old sentinel was deleted.

## Implementation

### C layer: `CEikonJIT.h`

```c
#include <stdint.h>

/* 0 and *flags from csops(getpid(), CS_OPS_STATUS, …); errno otherwise. */
int eikon_cs_flags(uint32_t *flags);

typedef enum {
  EIKON_PROBE_PASSED = 0,
  EIKON_PROBE_ALLOC_FAILED,       /* RW allocation failed */
  EIKON_PROBE_REMAP_FAILED,       /* vm_remap alias failed */
  EIKON_PROBE_PROTECT_FAILED,     /* mprotect(RX) on the execute view failed */
  EIKON_PROBE_PROTECTION_MISMATCH,/* remap cur/max protections cannot give RX + RW */
  EIKON_PROBE_WRONG_RESULT,       /* code ran but did not return 42 */
  EIKON_PROBE_SIGNAL              /* guarded signal while executing */
} eikon_probe_status;

typedef struct { eikon_probe_status status; int signal; int error; } eikon_probe_result;

/* MUST only be called when JITPolicy.mayProbe is true. */
eikon_probe_result eikon_jit_probe(void);

/* 1 present, 0 absent, -1 undeterminable. */
int eikon_txm_firmware_present(void);
```

**`eikon_cs_flags`.** Declare `csops` as `extern` in the `.c` file, because it is private libsystem API with no public header. Return 0 and fill `*flags` on success, or `errno` on failure. Callers test the flags against `CS_DEBUGGED` (`0x10000000`); define that constant in the header or in Swift.

**`eikon_jit_probe`.** The probe confirms that JIT really works. It uses the dual-mapping write path that UTM and Dolphin use, and that Eikon's later JIT code will use:

- Allocate one page (size from `getpagesize()`) read-write, without `MAP_JIT`.
- Create a second view of the same memory with `vm_remap` (`copy = FALSE`). Check the returned current and maximum protections. If they can't give an RX view and an RW view, return `PROTECTION_MISMATCH`.
- `mprotect` the execute view to RX and keep the other view RW. Neither view is ever RWX.
- Write a tiny function that returns 42 (`mov w0,#42 ; ret`) through the RW view, invalidate the instruction cache for the RX view (`sys_icache_invalidate`), and call it.
- Return `PASSED` when it returns 42, and `WRONG_RESULT` otherwise. Each failed step returns its own status, with `errno` or the kern return in `error`.

**Signal guard.** The call runs under a `sigsetjmp` guard. Handlers for `SIGBUS`, `SIGSEGV`, `SIGILL` and `SIGTRAP` are installed with `sigaction(SA_SIGINFO)`. A handler jumps back only when it is running on the probe's own thread **and** the faulting address or PC lies inside the probe page. Any other signal goes to the previously installed handler, or the handler restores `SIG_DFL` and re-raises. The guard then reports `EIKON_PROBE_SIGNAL` with the signal number. The previous handlers are always restored, a mutex serialises calls, and both views are unmapped before the function returns on every path.

The guard can't catch the `SIGKILL` that a process without JIT receives. That is why the probe is gated by policy and by the crash sentinel.

**`eikon_txm_firmware_present`.** Look for `Ap,TrustedExecutionMonitor.img4` under `/private/preboot/<hash>/usr/standalone/firmware/FUD/`. Enumerate the preboot hash directories rather than assuming one. Return 1 if found, 0 if the directory is readable and the file isn't there, and -1 if it can't be determined. Sandboxed installs typically get -1.

**Swift bridge.** Add an internal initializer `ProbeOutcome(_ result: eikon_probe_result)` in `EikonKit` that maps `PASSED` to `.passed` and every other status to `.failed`, with a `detail` naming the failed step and the signal or error number. Section 07's live `JITSystem.probe()` uses it.

### Swift types (`JITTypes.swift`)

```swift
public enum TXMState: String, Codable, Sendable { case present, absent, unknown }

public enum CSDebuggedSeen: String, Codable, Sendable { case never, atLaunch, afterTrollStoreRequest, onForeground }

public enum JITSource: String, Codable, Sendable {
    case none, dopamine, rootlessJailbreak, trollStore, externalEnabler, preexisting, unknown
}

public enum JITReasonCode: String, Codable, Sendable, CaseIterable {
    case dopamineJITOff              // toggle off, Choicy, safe mode, or Dopamine 2.0
    case rootlessJailbreakNoJIT      // non-Dopamine /var/jb jailbreak without JIT
    case trollStoreRequestPending
    case trollStoreTimedOut          // TrollStore < 2.0.12, or its URL scheme disabled; Retry offered
    case sideloadedNoJIT             // says what runs without it
    case txmEnforced                 // JIT from a debugger is not usable on this device yet
    case txmUndetermined             // iOS 26+ and TXM could not be ruled out
    case probeSkippedAfterCrash      // the previous launch died during the probe; Retry probe offered
    case probeFailed                 // unexpected; detail in probe outcome
    case unknownInstallNoJIT
    case simulator
}

public struct ProbeOutcome: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case notRun, passed, failed }
    public var kind: Kind
    public var detail: String?       // why not run, or which step failed / which signal
}

public struct TXMInfo: Codable, Sendable, Equatable {
    public var state: TXMState
    public var enforced: Bool        // true only on iOS 26+ with state present (or unknown, treated so)
    public var basis: String         // "firmware", "cpufamily heuristic", "os below 26", "simulator"
}

public enum TrollStoreRequestState: String, Codable, Sendable { case none, pending, timedOut }

public struct JITStatus: Codable, Sendable, Equatable {
    public var csDebugged: Bool
    public var csDebuggedSeen: CSDebuggedSeen
    public var txm: TXMInfo
    public var probe: ProbeOutcome
    public var source: JITSource
    public var reason: JITReasonCode?   // nil exactly when usable
    public var usable: Bool { csDebugged && probe.kind == .passed }   // computed; also encoded
}

public struct JITFacts: Sendable, Equatable {
    public var installMethod: InstallMethod
    public var csDebugged: Bool
    public var csDebuggedSeen: CSDebuggedSeen
    public var txm: TXMInfo
    public var trollStoreRequest: TrollStoreRequestState
    public var probeBlockedBySentinel: Bool
}
```

Notes:

- **`JITStatus` coding.** `usable` stays computed, and a custom `encode(to:)` also writes it, so the device report (section 08) and its schema carry it. Decoding ignores the encoded `usable` and recomputes it. Encode `reason` as absent or null when nil.
- **Initializers.** Give each struct a public memberwise initializer. Swift doesn't synthesise public ones.
- **`basis`** is informational text for the report. No logic and no test depends on its exact wording.

### Policy (`JITPolicy.swift`)

```swift
public enum JITPolicy {
    /// Minimum time between automatic TrollStore requests (about one minute).
    public static let trollStoreCooldown: TimeInterval

    public static func mayProbe(_ facts: JITFacts) -> Bool
    public static func status(_ facts: JITFacts, probe: ProbeOutcome) -> JITStatus
    public static func shouldRequestTrollStoreJIT(installMethod: InstallMethod, csDebugged: Bool,
                                                  triedThisProcess: Bool, lastAttempt: Date?,
                                                  now: Date, manual: Bool) -> Bool
    public static func txmInfo(firmware: Int32, osMajor: Int, cpuFamily: UInt32) -> TXMInfo
}
```

**`mayProbe(facts)`** is true only when all of these hold:
- `csDebugged` is true
- `installMethod != .simulator`
- `txm.enforced` is false and `txm.state != .unknown`
- `probeBlockedBySentinel` is false

**`status(facts, probe:)`** copies `csDebugged`, `csDebuggedSeen`, `txm` and `probe` into the status, then sets `source` and `reason`.

The **source** is `none` when `csDebugged` is false. Otherwise:

| Install | When seen | Source |
|---|---|---|
| dopamine | any | `dopamine` |
| rootlessJailbreak | any | `rootlessJailbreak` |
| trollStore / Lite | `afterTrollStoreRequest` | `trollStore` |
| trollStore / Lite | `atLaunch` or `never` | `preexisting` ("Open with JIT" from TrollStore's menu, or a Dopamine device marking container apps) |
| trollStore / Lite | `onForeground` | `externalEnabler` |
| sideloaded | `onForeground` | `externalEnabler` |
| sideloaded | `atLaunch` or `never` | `preexisting` |
| sideloaded | `afterTrollStoreRequest` | `externalEnabler` |
| simulator, unknown | any | `unknown` |

`never` with the flag set can't normally happen, so treat it as `atLaunch`.

The **reason** is nil when `usable` is true. Otherwise it is the first match in this order:
1. `installMethod == .simulator` → `simulator`.
2. TXM on iOS 26+ with `txm.state == .unknown` → `txmUndetermined`. Otherwise `txm.enforced` → `txmEnforced`. This comes before the `CS_DEBUGGED` check, so an AltStore install on a TXM device reports `txmEnforced` with or without an enabler.
3. `probeBlockedBySentinel` → `probeSkippedAfterCrash`.
4. `csDebugged` but the probe didn't pass → `probeFailed`. A probe that is `notRun` with nothing else blocking it also lands here, and its `detail` explains why.
5. TrollStore or TrollStore Lite: `trollStoreRequest` of `pending` or `none` → `trollStoreRequestPending`; `timedOut` → `trollStoreTimedOut`. When the cooldown suppresses the automatic request, section 07 sets the request to `timedOut` so that Retry JIT is offered.
6. By install method: `dopamine` → `dopamineJITOff`, `rootlessJailbreak` → `rootlessJailbreakNoJIT`, `sideloaded` → `sideloadedNoJIT`, `unknown` → `unknownInstallNoJIT`.

Step 2 needs to know the TXM state was left undetermined on iOS 26+. Below iOS 26 the derivation never produces `unknown` (see below), so `txm.state == .unknown` alone is enough.

**`shouldRequestTrollStoreJIT`:**
- Only `trollStore` or `trollStoreLite` installs without `CS_DEBUGGED` qualify. Everything else returns false.
- When `manual` is true, return true. Retry ignores the per-process flag and the cooldown.
- Otherwise return true only when `triedThisProcess` is false, and `lastAttempt` is nil or at least `trollStoreCooldown` before `now`.

This function is pure. Storing `lastAttempt` in `UserDefaults` (followed by `synchronize()`) belongs to section 07.

### TXM derivation (`TXMTable.swift`)

`JITPolicy.txmInfo(firmware:osMajor:cpuFamily:)` takes the result of `eikon_txm_firmware_present()`, the OS major version and `hw.cpufamily`. Section 07's live `JITSystem.txm` reads the last two and calls it.

1. **Firmware result 1 or 0.** Use it: `present` or `absent`, basis "firmware". `enforced` is `state == .present && osMajor >= 26`. Reports below iOS 26 may therefore show `present` with `enforced == false`.
2. **Firmware result -1, iOS below 26.** `absent`, `enforced = false`, basis "os below 26".
3. **Firmware result -1, iOS 26+.** Look up `cpuFamily` in the table, with basis "cpufamily heuristic".
   - The family is listed with a first-enforcing major version: `present`, with `enforced = osMajor >= thatVersion`.
   - The family is listed as having no TXM: `absent`, not enforced.
   - The family isn't listed: `unknown`, `enforced = true`. This is deliberately conservative.

The table is a Swift literal dictionary keyed by the `CPUFAMILY_ARM_*` values from `<mach/machine.h>`. Each value is either "first iOS major version with TXM enforced" or "no TXM". Seed it from what is known. The A15 family is enforced from 26, as on the owner's A15 test phone on iOS 27. Add other families only where they are confirmed; unlisted families fall to the conservative default. Device reports correct the table over time. The table is data, and no test asserts its entries.

The simulator short-circuit (TXM `absent`, basis "simulator") lives in section 07's `JITSystem.live`, not here.

### Crash sentinel (`ProbeSentinel.swift`)

```swift
public struct ProbeSentinel: Sendable {
    public init(directory: URL, buildNumber: String)
    /// Live location: Library/Caches (FileManager .cachesDirectory).
    public static func live(buildNumber: String) -> ProbeSentinel

    /// Before calling eikon_jit_probe: open(O_CREAT|O_TRUNC|O_WRONLY), write the build number, fsync, close.
    public func arm() throws
    /// After the probe returns: delete the file.
    public func disarm()
    /// At launch: true iff a sentinel holding *this* build number exists. Always deletes any sentinel,
    /// so exactly one launch is skipped and sentinels from other builds are simply dropped.
    public func consumeAtLaunch() -> Bool
}
```

- The file name is `eikon-probe-sentinel` inside `directory`.
- Use POSIX `open`/`write`/`fsync` for `arm()`, not `Data.write`, so the file is on disk before the probe can kill the process.
- The build number is `CFBundleVersion`, which section 07 passes in.
- If `arm()` throws, the caller must not probe.
- Section 07 calls `consumeAtLaunch()` in `gatherFacts()` to set `JITFacts.probeBlockedBySentinel`. Its "Retry probe" action runs arm, probe and disarm on demand.

## Done when

- `CEikonJIT` builds for device and simulator. The header exposes the three functions and the result types, and `EikonKit` imports it.
- The `JITPolicy` and `ProbeSentinel` tests above pass under `make test-swift`.
- Nothing in this section calls a URL, touches UI, attaches a debugger, uses `ptrace`, task-for-pid or `MAP_JIT`, or names any program title.

---

## Implementation status (partial)

Done (commit "Add the JIT policy types and JITPolicy"):
- `JITTypes.swift`: `TXMState`, `CSDebuggedSeen`, `JITSource`, `JITReasonCode`, `ProbeOutcome`, `TXMInfo`, `TrollStoreRequestState`, `JITStatus` (encodes `usable`, recomputes it on decode) and `JITFacts`.
- `JITPolicy.swift`: `mayProbe`, `status`, `shouldRequestTrollStoreJIT` and the cooldown.
- `TXMTable.swift`: `JITPolicy.txmInfo` and the CPU-family table. It is seeded only with A15 (enforced from iOS 26); unlisted families are treated as enforced on iOS 26+.
- `JITPolicyTests.swift`: the seven policy tests from the plan. They pass under `make test-swift`.

Done by the owner (commit "Add the probe crash sentinel"):
- `ProbeSentinel.swift` and `ProbeSentinelTests.swift`, as planned. After review, `arm()` also creates its directory if it's missing, and flushes the directory entry after the file (best effort).

Not done, left for the owner:
- the C layer (`CEikonJIT`)
- the `ProbeOutcome(_: eikon_probe_result)` bridge

The section isn't marked complete in the implementation state.

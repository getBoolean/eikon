# Section 06: Route picker

## Purpose

This section adds the pure, platform-neutral **route model and route picker** to `Packages/EikonCore`. Given a game's detection result, the device environment (whether JIT is usable, the device gates, which runtimes this build contains, and each runtime's per-game check) and an optional user override, the picker decides how the game would run. The possible routes are native Kirikiri, native Ren'Py, Wine+FEX, Wine+Box64 and Linux+FEX. If none fits, the game is unavailable. Every candidate carries machine-readable reasons, which the UI later turns into sentences.

No game runs in this split. The runtimes arrive later: 03 (Kirikiri), 06–08 (Wine), 10 (Ren'Py), 13 (Linux) and 14 (Box64). The picker is still useful now because routes that aren't built yet are chosen as normal and marked "planned".

## Dependencies

- **section-01-core-package.** `Packages/EikonCore` must exist, with Swift 6 language mode, platforms iOS 15 and macOS 13, and the `EikonCoreTests` target. It is run by `make test-core` (`swift test --package-path Packages/EikonCore`).
- **section-02-detection.** It provides `Engine` (`unity, kirikiri, renpy, gameMaker, bgi, unknown`), `GamePlatform` (`windows, linux`), `CPUArchitecture` (`i386, amd64, arm64, other`), `ExecutableInfo` (`path`, `format`, `architecture`, `machine`, `isGUI`) and `DetectionResult`. The picker reads these fields of `DetectionResult`:
  - `engine: Engine`
  - `executables: [GamePlatform: ExecutableInfo]`, the main executable per platform
  - The rest (`details`, `gameRoot`, `keyFile`, `detectorVersion`) is not needed here.
- **Later sections that use this one (reference only):**
  - 08 (the gate store produces `[GateName: GateState]`)
  - 09 (`LibraryController` recomputes decisions)
  - 10 (`GameRuntime.route`, and `RuntimeRegistry` supplies `builtRoutes` and `runtimeChecks`)
  - 12, 13 and 14 (UI strings, the route section, the device route table)

  Do not implement any of those here.

## Constraints that apply

- **Swift 6 language mode**, with complete concurrency checking. All types are `Sendable`.
- **01's style:**
  - small files, one concept each
  - pure logic in caseless enums
  - exhaustive switches with no `default:`, wherever you switch over these enums
- **iOS 15 minimum.** No UIKit in EikonCore.
- **Core code returns codes, never user-facing strings.** Strings are mapped in the app (section 12).
- **Tests are few and behavioral.** They must not assert constants, exact strings or internal structure, and must not lock in the order of reasons within an array beyond what behavior requires. Assert the chosen route, verdicts, and whether a given reason is *present*.

## Files

All new, under `/Volumes/WD_SN770_1T/dev/GitHub/eikon/Packages/EikonCore/`:

```
Sources/EikonCore/Routes/
  RouteID.swift
  GateName.swift              # RawRepresentable struct + known constants
  GateState.swift
  RuntimeCheck.swift          # RuntimeCheck + RuntimeDeclineCode
  RouteReason.swift
  RouteVerdict.swift          # + RouteCandidate, RouteDecision, RouteEnvironment
  RouteRules.swift
  RoutePicker.swift
Tests/EikonCoreTests/
  RoutePickerTests.swift
```

## Tests first (`Tests/EikonCoreTests/RoutePickerTests.swift`)

Use Swift Testing (`import Testing`, `@testable import EikonCore`), with free `@Test func`s named after behavior and `#expect`/`#require`.
- Prefer a table-driven `@Test(arguments:)` over rows of (detection, environment, override, expectation). Separate tests are fine where a row would need a special assertion.
- Build `DetectionResult` values directly in small helpers at the top of the file, for example `windows(.i386)`, `linux(.amd64)`, `engine(.kirikiri, withWindows: .i386)` and `unity(windows: .amd64, linux: .amd64)`. There is no need for on-disk fixtures, because the picker is pure.
- Build environments with a helper such as `env(jit:gates:built:checks:)`. Default it to "everything built, all gates passed, all checks ok" so each row states only what it varies.

Behaviors to cover:

1. **Native first.** Kirikiri and Ren'Py choose their native route when it is runnable. When the native runtime's check is `declined`, Wine is chosen, and the Wine candidate carries `nativeFirst`. The same row covers "a declined runtime falls through to the next route".
2. **With JIT usable,** a Windows i386 exe and a Windows amd64 exe both choose `wine-fex`.
3. **Without JIT:**
   - i386 chooses `wine-box64`.
   - amd64 has no chosen route (`chosen == nil`), and its `wine-fex` candidate is unavailable with `needsJIT`.
4. **Box64 is demoted, not removed.** With JIT usable, i386 chooses `wine-box64` in each of these three cases (three rows):
   - ~~`wine-fex` is gated out (failed `x18`)~~ **Dropped:** it contradicts the rules table. wine-box64 also requires `x18`, because the Box64 route still runs Wine's Windows ARM64 modules, which keep the TEB in `x18`. A failed `x18` blocks both Wine routes.
   - `wine-fex` is declined by its runtime
   - `wine-fex` is not built (planned) while `wine-box64` is built
5. **An unmeasured required gate** gives `runnableWithWarnings`, with a `gateUnmeasured` reason naming that gate. Include a row where the gate is absent from the `gates` map, since missing means unmeasured.
6. **A failed gate** makes the route unavailable, and so does a **stale** failed gate (two rows).
7. **With no built runtimes at all,** the preferred route is chosen with the verdict `planned`.
8. **An override to an unavailable route** is chosen. `isOverride` is true, and `overrideWarnings` lists that route's reasons (non-empty and containing the blocking reason).
9. **An override to a runnable route** is chosen with empty `overrideWarnings`.
10. **Linux amd64** chooses `linux-fex` only with JIT usable. Without JIT, nothing is chosen.
11. **A multi-platform Unity folder** (Windows amd64 + Linux amd64) lists both a `wine-fex` and a `linux-fex` candidate.
12. **An ARM64 PE, or an `other`-architecture PE,** produces no runnable Wine candidate.

Don't test the strings, the `RouteRules` table's literal contents, or the raw values of `RouteID`/`GateName`.

## Implementation

### Types

Copy these signatures. Add public memberwise initializers where the compiler won't synthesize public ones.

```swift
public enum RouteID: String, Codable, Sendable, CaseIterable {
    case nativeKirikiri = "native-kirikiri", nativeRenPy = "native-renpy"
    case wineFEX = "wine-fex", wineBox64 = "wine-box64", linuxFEX = "linux-fex"
}

public struct GateName: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String)
    public static let x18: GateName          // "x18"
    public static let guestWindow: GateName  // "guestWindow"
}

public enum GateState: Sendable, Equatable { case passed, failed(stale: Bool), unmeasured }

public struct RuntimeDeclineCode: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String)
}  // values are owned by the runtime splits; 02 defines none

public enum RuntimeCheck: Sendable, Equatable { case ok, declined(RuntimeDeclineCode) }

public enum RouteVerdict: Sendable, Equatable { case runnable, runnableWithWarnings, planned, unavailable }

public enum RouteReason: Sendable, Equatable {
    case engineNotHandled(Engine)
    case needsWindowsBinary, needsLinuxBinary
    case architectureUnsupported(CPUArchitecture)
    case needsJIT
    case box64Only32Bit
    case fexPreferredWithJIT          // Box64 demoted, still runnable
    case gateFailed(GateName, stale: Bool)
    case gateUnmeasured(GateName)
    case notInThisBuild
    case runtimeDeclined(RuntimeDeclineCode)
    case nativeFirst
    case overriddenByUser
}

public struct RouteCandidate: Sendable, Equatable { public var route: RouteID; public var verdict: RouteVerdict; public var reasons: [RouteReason] }
public struct RouteDecision: Sendable, Equatable {
    public var chosen: RouteCandidate?            // nil = unavailable
    public var candidates: [RouteCandidate]       // preference order
    public var isOverride: Bool
    public var overrideWarnings: [RouteReason]
}
public struct RouteEnvironment: Sendable {
    public var jitUsable: Bool
    public var gates: [GateName: GateState]       // missing = unmeasured
    public var builtRoutes: Set<RouteID>
    public var runtimeChecks: [RouteID: RuntimeCheck]   // for this game, from built runtimes
}
```

Notes:
- **`GateName` is an open struct, not an enum.** Splits 05 and 07 will measure these gates and may add more. The UI (section 12) gives the known constants their own strings, and uses a generic "<gate> check" sentence with the raw name for anything else.
- **`RuntimeDeclineCode` is open for the same reason.** The UI maps it to the key `route.decline.<raw>`, which the owning split adds, with a generic fallback sentence. Nothing in EikonCore needs to know the codes.
- **A missing `runtimeChecks` entry** for a built route is treated as `.ok`. The registry may not have finished the async check yet.
- **No install-method input.** The picker doesn't take an install method. The install method matters only through `jitUsable`, and the UI shows 01's JIT reason wherever `needsJIT` appears.

### `RouteRules` (one static table)

Implemented as a caseless enum with `rule(for: RouteID) -> Rule`, an exhaustive switch, so a new route is a compile error rather than a silent gap. Each `Rule` has a target, `needsJIT`, architecture-independent `gates` and `gatesByArchitecture`. `nativeRoute(for: Engine)` is an exhaustive switch too.

| Route | Applies to | Needs JIT | Required gates |
|---|---|---|---|
| native-kirikiri | engine `kirikiri` | no | none |
| native-renpy | engine `renpy` | no | none |
| wine-fex | a Windows executable, i386 or amd64 | yes | amd64: `x18`; i386: `x18`, `guestWindow` |
| wine-box64 | a Windows executable, i386 only | no | `x18`, `guestWindow` |
| linux-fex | a Linux executable, amd64 | yes | none |

- **Required gates can depend on the architecture** (see wine-fex), so model them as a function of the architecture, or as a per-architecture map.
- **Splits 05 and 07 may adjust the table** when they land, so keep it data-like and in one place.
- **The table also says which route is native for an engine** (kirikiri → native-kirikiri, renpy → native-renpy). The picker's ordering uses this.

The "applies to" check produces these reasons when it fails:
- **Native routes on another engine:** `engineNotHandled(engine)`.
- **Wine routes with no `executables[.windows]`:** `needsWindowsBinary`. **Linux route with no `executables[.linux]`:** `needsLinuxBinary`.
- **Executable architecture outside the route's set:** `architectureUnsupported(arch)`. This covers `arm64` and `other` on any Wine route, and a non-amd64 Linux binary.
- **wine-box64 with an amd64 exe:** unavailable with `box64Only32Bit`. That is the "Without JIT, only 32-bit Windows games can run" case, and should be used in preference to a generic `architectureUnsupported(.amd64)`.

### `RoutePicker`

```swift
public enum RoutePicker {
    /// Pure. Evaluates every RouteID, orders them by preference, picks one, applies an override.
    public static func decide(detection: DetectionResult,
                              environment: RouteEnvironment,
                              override: RouteID?) -> RouteDecision
}
```

1. **Evaluate every route** (all `RouteID.allCases`). The verdict comes from the **first** rule that applies, in this order:
   1. The engine, platform or architecture isn't met → `unavailable`, with the reason from the table check above.
   2. JIT is required but `!jitUsable` → `unavailable`, `needsJIT`.
   3. Any required gate is `failed` → `unavailable`, `gateFailed(name, stale:)`. A stale failure is still a failure. (It is fine to list every failed gate.)
   4. The route is not in `builtRoutes` → `planned`, `notInThisBuild`.
   5. The route is built and its `runtimeChecks` entry is `.declined(code)` → `unavailable`, `runtimeDeclined(code)`.
   6. Otherwise → `runnable`. It becomes `runnableWithWarnings` if any required gate is `unmeasured` (or missing from the map), and each such gate adds a `gateUnmeasured(name)` reason.

   Note that step 4 comes before step 5. A planned route never consults a runtime check.

2. **Order the candidates.**
   - The engine's native route comes first, if the engine has one.
   - Then come `wine-fex`, `wine-box64` and `linux-fex`.
   - When the engine has a native route, the Wine candidates behind it get the `nativeFirst` reason.
   - Other engines' native routes (never runnable for this game) come last.
   - Ordering reasons (`nativeFirst`, `fexPreferredWithJIT`) are added only to candidates that aren't `unavailable`, so they never appear beside a blocking reason or in `overrideWarnings`.
   - **When `jitUsable`**, `wine-box64` is still evaluated normally but is ordered after `wine-fex`, and gets `fexPreferredWithJIT`. This is a demotion, not a removal, so Box64 still wins when FEX is planned, declined or gated out.

   **Which candidates appear:** `candidates` should include every route that is relevant to the game, meaning the routes the device route table and the override picker can show. The simplest acceptable rule is to include every route and let the unavailable ones carry their reasons. The UI (sections 13 and 14) filters as it needs. Either way, the multi-platform Unity case must list both `wine-fex` and `linux-fex`.

3. **Choose.**
   - The first candidate in preference order whose verdict is `runnable` or `runnableWithWarnings` wins.
   - If there is none, the first `planned` candidate is chosen.
   - If there is none of those either, `chosen` is `nil`.

4. **Override.** When `override` is non-nil:
   - The forced route's candidate becomes `chosen` whatever its verdict, and `isOverride = true`.
   - Add `overriddenByUser` to the chosen candidate's reasons, in `chosen` and in its `candidates` entry.
   - `overrideWarnings` carries that candidate's reasons whenever its verdict is not `runnable`/`runnableWithWarnings`, which includes `planned` and `unavailable`. For a runnable forced route, `overrideWarnings` is empty.
   - The candidate order is unchanged.

   The UI later uses this to show "Launch anyway?" with the reasons listed. That is sections 13 and 14.

### How the rest of the app will use this (context only; not built here)

- **`LibraryController`** (section 09) recomputes each game's `RouteDecision` whenever any of these change:
  - JIT status, which can flip to usable mid-session
  - gates
  - `route.override` settings
  - the runtime registry
  - cached runtime checks
- **`RuntimeRegistry`** (section 10) supplies `builtRoutes` (empty in 02, where no runtimes are registered) and the per-game `runtimeChecks`.
- **The gate store** (section 08) supplies `[GateName: GateState]`:
  - A passed result expires to `unmeasured` when the app or OS build changes.
  - A failed result persists as `failed(stale: true)`.
- **The UI** maps every `RouteReason` and `RouteVerdict` through exhaustive switches (section 12). Example sentences:
  - `box64Only32Bit`: "Without JIT, only 32-bit Windows games can run."
  - `fexPreferredWithJIT`: "Slower than Wine with FEX; used if that route can't run."
  - `gateFailed(stale: true)`: "Failed on this device before an update. Not re-checked yet."
  - `notInThisBuild`: "Planned. Not in this build yet."

  The detail screen shows every reason, and the library row shows the verdict only. When adding new cases, keep them codes, with no text in EikonCore.

## Tests

`RoutePickerTests.swift`: a table of 11 chosen-route rows (including "a planned route never consults its runtime check") plus 10 focused tests for reasons, overrides, platforms and architectures.

## Done when

- `make test-core` passes with the new `RoutePickerTests`.
- The Routes files compile in Swift 6 mode with no concurrency warnings.
- `RoutePicker.decide` is a pure static function with no I/O and no global state.

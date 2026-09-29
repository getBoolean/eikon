# Section 11: Crash report controller

> **From section 07 (as built):** consume the sentinel at launch before any `arm`, because arming discards unconsumed evidence. Add the consumed session to `CrashHistory` right after consuming, because consuming deletes the files. `SessionSentinel.setPhase` throws when the sentinel is missing, so surface that rather than ignore it. The breadcrumb and fault writers are safe to call from any thread while `close` runs.

## Summary

This section adds `CrashReportController`, the EikonKit-side consumer of the crash-recording primitives from section 07. At app launch it:

1. Consumes the session sentinel left by the previous run, if there is one.
2. Classifies the outcome and snapshots it into the per-game `CrashHistory`.
3. Publishes a banner, for outcomes that warrant one.
4. Offers the banner actions:
   - **Try <route> next time.** Shown only when another route can really run.
   - **Report on GitHub.** Opens a prefilled issue form, with a clipboard fallback for the full device report.
   - **Dismiss.**

The controller also serves "Report on GitHub" for any older history entry. The game detail screen in section 13 uses that.

The SwiftUI `CrashBanner` view and the crash-history list on the game detail screen are **not** part of this section; they belong to section 13 (library UI). This section provides the observable state and the actions those views bind to.

## Dependencies

- **Section 07 (sessions and crash, EikonCore).** Provides:
  - `SessionSentinel.consumeAtLaunch() -> ConsumedSession?`, which returns the `SessionRecord`, a breadcrumbs snapshot and an optional `FaultRecord`, then removes the files
  - `SessionOutcome` classification and its banner flag
  - `CrashHistory` (last 5 per game id, newest first, each entry keeping its breadcrumbs snapshot)
  - `CrashIssue.url(repository:entry:device:reportID:)`, which returns the URL and how many breadcrumbs it dropped to stay under the 7,500-character limit
  - the small core-side device/app/JIT struct that `CrashIssue` takes (EikonCore can't see EikonKit's `DeviceReport`)
  - `.github/ISSUE_TEMPLATE/crash.yml`

  Use the exact names section 07 landed with. The names in this section describe roles.
- **Section 10 (runtime session host).** Test sessions record their route as `"test"` and use a fixed synthetic game id. Real sessions record a `RouteID` raw value. The controller must tell the two apart.
- **Section 06 (route picker), through section 09's `LibraryController`.** Supplies the current `RouteDecision` for a game: `chosen`, `candidates` in preference order, and each candidate's `verdict` (`runnable`, `runnableWithWarnings`, `planned`, `unavailable`).
- **Section 05 (settings store).** Provides the per-game `route.override` `SettingKey`, stored under `game/<id>/route.override` as the `RouteID` raw value.
- **Section 08 (gate store).** Provides `GateStore.current()` and the `DeviceReport.make(..., gates:)` parameter, used for the clipboard report.
- **Existing (split 01):**
  - `DeviceReport`, `AppInfo`, `JITController` (`installMethod`, JIT status) in `Packages/EikonKit/Sources/EikonKit/`
  - `ReportExport.copy(_:)` in `App/ReportExport.swift`, which puts the report JSON on `UIPasteboard.general`

## Background

- **Games run in-process**, so a game crash ends the app. 02 installs no signal handler; FEX and Wine use SIGSEGV/SIGBUS in normal operation, and jetsam kills can't be caught anyway. Crashes are therefore detected on the **next launch**, from the sentinel that section 10's `GameSession` armed and never disarmed.
- **Outcome table** (from section 07, repeated here for context):

  | Evidence | Outcome | Banner |
  |---|---|---|
  | Phase `running` + a matching fault record | `crashed(signal, pc)` | yes |
  | Phase `running` + a `memoryWarning` within 60 s of the last breadcrumb, or a last `memorySample` under 100 MB | `likelyMemoryKill` | yes |
  | Phase `running`, nothing else | `endedUnexpectedly` | yes |
  | Phase `background` | `killedInBackground` | no (history only) |

- **Privacy rules. These are hard constraints.**
  - A game's display name appears **only on screen**, in the banner. It never enters the issue URL, the logs or the history file.
  - The issue carries only the **report id**: the first 8 characters of the random game id. It never carries file hashes, fingerprints or folder names.
  - The user reviews the issue in Safari before submitting.
- **Persistence location.** History lives at `Library/Application Support/Eikon/sessions/history.json` and follows the shared persisted-file rules (a `format` header, atomic write, and a future format is never rewritten). All of that is implemented by section 07's `CrashHistory`; this section only calls it.
- **Repository URL.** It comes from the `EKRepositoryURL` key in `App/Info.plist` (`https://github.com/getBoolean/eikon`).

## Tests first

File: `Packages/EikonKit/Tests/EikonKitTests/CrashReportControllerTests.swift` (Swift Testing, simulator suite).

Follow the owner's testing rule: a few tests that cover behavior only.
- Don't assert on exact banner strings, URL layouts or threshold constants.
- Build inputs with section 07's real types in a temp directory: arm a sentinel, set its phase, append breadcrumbs, then create the controller. Don't hand-construct internal state.
- Use fakes for the collaborators (route decisions, settings writer, URL opener, pasteboard).

```swift
@MainActor @Suite struct CrashReportControllerTests {
    /// A consumed session whose outcome warrants a banner (phase `running`) publishes a banner
    /// for that game and route, and adds a history entry.
    @Test func highSeveritySessionPublishesBanner() async throws { }

    /// A session consumed in phase `background` adds a history entry and publishes no banner.
    @Test func backgroundKillAddsHistoryWithoutBanner() async throws { }

    /// "Try another route" appears only when the game's decision holds another candidate that
    /// is runnable or runnableWithWarnings, other than the crashed route. It is absent when
    /// the only alternatives are planned or unavailable, for a `test` record, and for a game
    /// id the library no longer knows. Choosing it writes that route to `route.override`.
    @Test(arguments: [/* rows: alternatives' verdicts, record route, game exists, offered? */])
    func tryAnotherRouteOfferedOnlyWhenRunnable(/* row */) async throws { }
}
```

Useful checks that stay behavioral:
- After launch, the sentinel files are gone, whichever outcome it was. Section 07's consume already guarantees this, so assert it only if it's cheap.
- *Report on GitHub* passes the opener a URL whose query has a `game` value equal to the report id. The query contains no display name.
- When the builder reports dropped breadcrumbs, the fake pasteboard receives the device report and the controller flags that the user should paste it.

Not tested automatically:
- the SwiftUI banner, which has DEBUG previews in section 13
- whether GitHub accepts the prefill, which is checked manually in section 16

## Implementation

### File

`Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift`

### Shape

The controller is a `@MainActor final class CrashReportController: ObservableObject`. It must be testable without UIKit globals, so every side effect goes through injected closures or protocols. The app supplies the live versions.

```swift
@MainActor
public final class CrashReportController: ObservableObject {
    /// The pending banner, or nil. Only outcomes whose classification says "banner" set it.
    @Published public private(set) var banner: CrashBanner?
    /// Set after a report whose URL dropped breadcrumbs, so the UI tells the user to paste
    /// the device report from the clipboard into the issue.
    @Published public private(set) var clipboardNotice: Bool

    public struct Dependencies {
        public var sentinel: SessionSentinel            // section 07
        public var history: CrashHistory                // section 07
        public var repository: URL                      // EKRepositoryURL
        public var routeDecision: @MainActor (GameID) -> RouteDecision?   // nil = game no longer exists
        public var displayName: @MainActor (GameID) -> String?           // on-screen only
        public var setRouteOverride: @MainActor (GameID, RouteID) -> Void
        public var deviceReport: @MainActor () -> DeviceReport           // includes GateStore.current()
        public var openURL: @MainActor (URL) -> Void                      // UIApplication.open in the app
        public var copyToPasteboard: @MainActor (DeviceReport) -> Void    // ReportExport.copy in the app
    }

    /// Consumes the sentinel, snapshots into history, and publishes a banner if warranted.
    public init(dependencies: Dependencies)

    /// History for the game detail screen (newest first, at most 5).
    public func history(for game: GameID) -> [CrashHistory.Entry]

    public func tryAlternative(_ banner: CrashBanner)
    public func report(_ entry: CrashHistory.Entry)
    public func dismiss()
}

/// Everything the banner view needs. Built fresh; never persisted.
public struct CrashBanner: Identifiable, Equatable {
    public var id: UUID                 // sessionID
    public var entry: CrashHistory.Entry
    public var outcome: SessionOutcome
    public var gameName: String?        // display name, on screen only; nil for test sessions
    public var route: String            // RouteID raw value or "test"
    public var startedAt: Date
    public var alternative: RouteID?    // non-nil only when "Try <route> next time" is offered
}
```

If section 07 already models the history entry under a different name, use that name. `CrashHistory.Entry` above stands for "one snapshotted consumed session with its outcome, breadcrumbs and fault".

### Launch flow (in `init`)

1. Call `sentinel.consumeAtLaunch()`. If it returns nil, there is no banner and nothing more to do.
2. Classify the consumed session with section 07's `SessionOutcome` classification.
3. Append the entry to `CrashHistory`: record, outcome, breadcrumbs snapshot and fault record. The history store keeps 5 per game and persists the change. Do this **before** publishing the banner, so a report can still be filed later from the game detail screen after the banner is dismissed.
4. If the outcome warrants a banner, build a `CrashBanner`:
   - `gameName`: from `displayName(gameID)`, unless the route is `"test"`.
   - `alternative`: computed as described in the next subsection.

   Publish it.

This runs synchronously inside `init`, which the app calls in `EikonApp.init` step 3, after `JITController.shared.gatherFacts()`. Section 12 owns the wiring order. When the library hasn't finished its first scan yet, `routeDecision` may return nil; in that case also recompute `alternative` whenever the library publishes new decisions. One simple way is a `refreshAlternative()` method that the app calls from a `LibraryController` change, or a Combine sink on the controller's decisions. That keeps a "game no longer exists" answer from being fixed permanently by a slow first scan.

### "Try <route> next time"

Offer `alternative` only when all of these hold:
- The record's route is not `"test"`.
- `routeDecision(gameID)` is non-nil. A nil means the game was removed, or its id no longer resolves; resolving `merged/` links is the library's job.
- The decision's `candidates`, in preference order, contain one whose `route.rawValue` differs from the crashed record's route and whose verdict is `.runnable` or `.runnableWithWarnings`. Take the **first** such candidate. `planned` and `unavailable` candidates never qualify.

`tryAlternative(_:)` calls `setRouteOverride(gameID, alternative)`, which writes per-game `route.override`, and then clears the banner. The library recomputes decisions when overrides change (section 09), so this section doesn't need to do that.

### "Report on GitHub"

`report(_ entry:)` does the following:
1. Build the core-side device input for `CrashIssue` from `deviceReport()`: app version, build and commit; device model identifier; OS version and build; install method; JIT usable, source and reason code.
2. Compute the report id: the first 8 characters of the entry's game id string. Use section 07's helper if it provides one.
3. Call `CrashIssue.url(repository:entry:device:reportID:)`. Pass it no display name, folder name or fingerprint; its signature doesn't accept them.
4. If the builder reports that breadcrumbs were dropped, call `copyToPasteboard(deviceReport())` and set `clipboardNotice = true`. The full `DeviceReport` JSON uses 01's format, now with `gates`. Also copy it when the owner's manual check finds that a field doesn't prefill; a `force` flag or always-copy is acceptable if section 16's verification shows prefill is unreliable.
5. Call `openURL(url)`. In the app this is `UIApplication.shared.open`, and the user reviews and submits the issue in Safari.

The banner's *Report on GitHub* action calls `report(banner.entry)`. The game detail screen's history rows call it too.

### Dismiss

`dismiss()` clears `banner` and `clipboardNotice`. History is untouched. The banner isn't persisted, so it doesn't come back on the next launch, because the sentinel was already consumed.

### Live wiring in the app (for section 12/13 to call)

In `EikonApp.init` step 3, construct `Dependencies` with:
- the `SessionSentinel` and `CrashHistory` rooted at `Application Support/Eikon/sessions/`
- `repository`: read from `Bundle.main.object(forInfoDictionaryKey: "EKRepositoryURL")`
- `routeDecision` and `displayName`: from `LibraryController`
- `setRouteOverride`: through `SettingsController` with the `route.override` key
- `deviceReport`: `DeviceReport.make(..., gates: gateStore.current())`, using `JITController` facts and `AppInfo.from(.main)`
- `openURL`: `UIApplication.shared.open`
- `copyToPasteboard`: `ReportExport.copy`

The only code this section writes is the closure-building helper, if one is wanted. The call site belongs to section 12.

## Acceptance

- The three tests above pass under `make test` (the simulator EikonKit suite).
- No code path puts the display name, a folder name, a fingerprint or a file hash into the issue URL or into history.
- Manual check, done in section 16: after a simulated crash in the developer test session and a relaunch, the banner appears with no "Try…" action, since it is a `test` record. *Report on GitHub* opens a prefilled issue that carries only codes and the report id.

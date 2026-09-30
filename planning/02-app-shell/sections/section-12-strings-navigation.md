# Section 12: Strings and root navigation

> **Added after section 10 (owner's request):** stores never replace a file they can't read, since the user may have hand-edited it and can still fix it. `SettingsStore`, `CrashHistory`, `LibraryIndex` and `GateStore` conform to `UnreadableFileReporting` (in EikonCore's `Persisted.swift`). After wiring, `EikonApp` gathers `unreadableFiles` from all four. If any are listed, it shows one warning that names the files by their app-relative location, never a game title. The warning says Eikon won't change them, and offers two choices: fix them and relaunch, or **Start over**, which calls `startOver()` on the affected stores and keeps each old file as a backup. The strings go under `storage.unreadable.*`.

## What this section delivers

This section covers plan §12.1, §12.7 and §14:

1. The app's English text moves from `App/Localizable.strings` to `App/en.lproj/Localizable.strings`. A `Localizable.stringsdict` is added for plurals.
2. New key namespaces are added for everything splits 02's screens show.
3. The exhaustive code→key maps live in `App/Strings/`. Core code (EikonCore/EikonKit) returns only codes and enums, never user-facing text.
4. `RootView`, a sidebar with four destinations: Library, Game drives, This device and Credits.
5. The new `EikonApp.init` wiring order and scene-phase handling.
6. DEBUG previews that render every reason, verdict, outcome, identity prompt, drive state and library status. A missing key then shows up as a raw key.

Split 09 later only adds languages. Nothing in this section should need to change for that.

## Background

Eikon is an iPhone/iPad app, iOS 15 minimum. It is built with XcodeGen (`project.yml`, where `sources: - path: App` picks up everything under `App/`), a Makefile, and `uv`-run Python scripts. Relevant constraints:

- **iOS 15 minimum.** Use `NavigationView` and `ObservableObject`. There is no `NavigationSplitView`, `@Observable` or `ShareLink`.
- **Swift 6 language mode** with complete concurrency checking.
- **01's style.** Keep files small and single-concept. Map enums to string keys with exhaustive `switch` statements and **no `default:`**, so adding a case fails the build until it gets a key. `App/StatusView.swift` already follows this pattern (`installMethodKey`, `sourceKey`, `reasonKey`, and so on, returning `LocalizedStringKey`, plus a local `localized(_:)` helper around `NSLocalizedString`). Copy that style.
- **No program titles anywhere.** Display names and folder names may appear on screen only. Strings never interpolate them into anything that is logged or exported.
- **Tests are few and behavioral** (the owner's standing rule). This section has no behavioral logic, so it has no automated tests (see below).

`App/Info.plist` already sets `CFBundleDevelopmentRegion`. Keep it as `en` (or `$(DEVELOPMENT_LANGUAGE)` resolving to `en`) so `en.lproj` is the development localization.

## Dependencies

- **Requires section-01-core-package**: the EikonCore package is linked into the app, so `import EikonCore` works in the app target.
- **The key maps compile against types defined in other sections:**
  - `Engine`, `CPUArchitecture`, `GamePlatform` (section 02)
  - `RouteID`, `RouteVerdict`, `RouteReason`, `GateName`, `GateState`, `RuntimeDeclineCode` (section 06)
  - `SessionOutcome` (section 07)
  - `DriveState` and the location identity/status states (section 09)

  If you implement this section before those land, do the strings move, the namespaces, `RootView` and the stringsdict first. Then add each map file as soon as its type exists. Each map is its own file, so this needs no stubs.
- **`EikonApp.init` wiring** uses `SettingsController` (05), `GateStore` (08), `LibraryController`/`DriveManager`/`ImportCoordinator` (09), `RuntimeRegistry` (10) and `CrashReportController` (11). Wire each step as its type becomes available, in the order given below.
- **Blocks:** section-13-library-ui, section-14-device-screen and section-15-credits. They provide the real destination views (`LibraryView`, `DrivesView`, the extended `StatusView`, `CreditsView`) and use the keys and maps defined here. They add their own screen-specific keys under the namespaces reserved here.

## Tests (write or check first)

From the TDD plan, §12 Screens and §14 Reason text rules:

- **No automated UI tests.** 01 has no UI test target, and the owner's rule keeps tests few. Reason text is string content, so it is not unit-tested.
- **The DEBUG previews are the check.** They render every `RouteReason`, `RouteVerdict`, `SessionOutcome`, identity prompt, drive state and library status, so a missing string key shows up as a raw key in the canvas. Put them next to the maps (for example `App/Strings/StringsPreviews.swift`, wrapped in `#if DEBUG`). Build the lists from `CaseIterable` where the type supports it. For payload-carrying cases (`RouteReason`, `SessionOutcome`, `GateState`), write one representative value per case in a local array. The exhaustive switches still force the preview author to handle a new case.
- **Build checks:**
  - `make test` still passes, because the maps are compiled.
  - The archive's `Eikon.app` contains `en.lproj/Localizable.strings` and `en.lproj/Localizable.stringsdict`.
  - No top-level `Localizable.strings` is left.
  - 01's artifact verifier still passes.
- **Manual check:** on the simulator, the existing status-screen text still renders as text rather than raw keys after the move.

## Implementation

### 1. Move the strings file (plan §12.7)

- `git mv App/Localizable.strings App/en.lproj/Localizable.strings`.
- Replace the header comment, which says the file moves into `en.lproj` "later". The new header should say that this is the English source, that keys are namespaced, and that core code returns codes mapped in `App/Strings/`.
- Keep every existing key unchanged. `status.*`, `install.*`, `jit.*`, `device.*` and `report.*` are all used by `StatusView`.
- XcodeGen turns `en.lproj` folders under a source path into a localized variant group, so `project.yml` needs no change. Confirm this in the generated project: the file should appear as `Localizable.strings (English)`.

### 2. Add `App/en.lproj/Localizable.stringsdict`

Add plural rules (`NSStringLocalizedFormatKey` with an `NSStringPluralRuleType` variable, `one`/`other`) for:
- games, for example "%d game(s)", used by drive and library counts
- files, used by import progress and the remove dialog
- bytes, for the rare raw-byte count. Formatted sizes use `ByteCountFormatter`.
- drives

Name the keys within the namespaces below, for example `library.count.games`, `import.count.files`, `drives.count.drives` and `import.count.bytes`. Use them through `String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), n)`.

### 3. Key namespaces

All new keys go under exactly these prefixes:

`library.*`, `drives.*`, `import.*`, `identity.*`, `game.*`, `route.id.*`, `route.reason.*`, `route.verdict.*`, `route.decline.*`, `gate.*`, `engine.*`, `arch.*`, `crash.*`, `credits.*`, `developer.*`

This section adds the keys the maps below need, plus the sidebar titles (`library.title`, `drives.title`, `status.title` which already exists, and `credits.title`). Screen sections 13–15 add their own labels under the same prefixes.

### 4. Exhaustive code→key maps in `App/Strings/`

Use one small file per concept. Every function is an exhaustive `switch` with no `default:`, returning `LocalizedStringKey` for `Text` or `String` via `NSLocalizedString` where formatting is needed. Share one `localized(_:)` helper across the folder, instead of the `private` one in `StatusView.swift`. StatusView may keep its own.

Suggested files and contents:

- **`App/Strings/RouteStrings.swift`**
  - `routeName(_ id: RouteID)` maps to `route.id.native-kirikiri`, `route.id.native-renpy`, `route.id.wine-fex`, `route.id.wine-box64` and `route.id.linux-fex`, keyed by raw value. It also covers the session record's `"test"` route string (`route.id.test`) through a separate function that takes the raw string, falling back to showing the raw value.
  - `verdictKey(_ v: RouteVerdict)` has cases `runnable`, `runnableWithWarnings`, `planned` and `unavailable`, mapped to `route.verdict.*`.
  - `reasonText(_ r: RouteReason, jitReason: JITReasonCode?) -> String` handles every `RouteReason` case:
    - `engineNotHandled(Engine)`: a sentence with the engine name from `EngineStrings`.
    - `needsWindowsBinary` and `needsLinuxBinary`.
    - `architectureUnsupported(CPUArchitecture)`: a sentence with the architecture name.
    - `needsJIT`: formats `route.reason.needsJIT` with 01's JIT reason sentence (`jit.reason.<code>`) for the current `JITStatus.reason`. If there is no reason code, use a variant without the clause.
    - `box64Only32Bit`, `fexPreferredWithJIT`, `gateFailed(GateName, stale:)`, `gateUnmeasured(GateName)`, `notInThisBuild`, `runtimeDeclined(RuntimeDeclineCode)`, `nativeFirst` and `overriddenByUser`.
    - Give stale and fresh `gateFailed` separate keys.
- **`App/Strings/GateStrings.swift`**
  - `gateName(_ g: GateName) -> String`: the known constants `.x18` and `.guestWindow` get their own keys (`gate.name.x18`, `gate.name.guestWindow`). Any other name uses the generic `gate.name.generic` ("%@ check") with the raw name. `GateName` is a `RawRepresentable` struct, so this is an `if`/`switch` on the known constants with a generic fallback. That fallback is the one intentional non-exhaustive map.
  - `gateStateKey(_ s: GateState)` covers `passed`, `failed(stale: false)`, `failed(stale: true)` and `unmeasured`, as `gate.state.*`.
- **Runtime decline text.** `declineText(_ code: RuntimeDeclineCode) -> String` looks up `route.decline.<raw>`, which the owning runtime split adds. If the key is missing, it shows the generic `route.decline.generic` ("This runtime can't run this game (%@).") with the raw code. Detect a missing key by calling `NSLocalizedString(key, value: <sentinel>, comment: "")` and comparing the result against the sentinel.
- **`App/Strings/EngineStrings.swift`**
  - `engineKey(_ e: Engine)` covers `unity`, `kirikiri`, `renpy`, `gameMaker`, `bgi` and `unknown`, as `engine.*`.
  - `archKey(_ a: CPUArchitecture)` covers `i386`, `amd64`, `arm64` and `other`, as `arch.*`.
  - `platformKey(_ p: GamePlatform)` covers `windows` and `linux`.
  - Include keys for the engine sub-details: the Unity scripting backend (mono/il2cpp), the Kirikiri flavor (krkr2/krkrZ/unknown), the Ren'Py version kind (exact/era), and the GameMaker build (vm/yyc). They go under `engine.*`.
- **`App/Strings/CrashStrings.swift`**
  - `outcomeKey(_ o: SessionOutcome)` covers `crashed(signal:pc:)`, `likelyMemoryKill`, `endedUnexpectedly` and `killedInBackground`, as `crash.outcome.*`. The signal and pc are shown as numbers elsewhere, not in the sentence.
- **`App/Strings/LibraryStrings.swift`**
  - `driveStateKey(_ s: DriveState)` covers `available`, `notConnected` and `needsRelink`, as `drives.state.*`.
  - The library status line covers Identifying…, Waiting for copy to finish, "Same game as …?", Drive not connected, Missing, and Hashing failed (`library.status.*`). Map whatever status enum section 09 publishes, exhaustively.
  - The identity prompts (`identity.*`):
    - the suggestion card text, "This might be the same game as %@ (a different version). Use one entry?", with the display name shown on screen only
    - Merge and Keep separate
    - "Same game as…"
    - "This is a different game"

**Reason text rules (plan §14).** Reasons are short sentences a non-expert can act on. The English values:

- `needsJIT`: "Needs JIT, which this install doesn't have: %@." (01's JIT reason sentence)
- `box64Only32Bit`: "Without JIT, only 32-bit Windows games can run."
- `fexPreferredWithJIT`: "Slower than Wine with FEX; used if that route can't run."
- `gateUnmeasured`: "Not yet verified on this device (%@). It may not work." (the gate name, for example "x18 check")
- `gateFailed` (stale): "Failed on this device before an update. Not re-checked yet."
- `notInThisBuild`: "Planned. Not in this build yet."

Write the remaining reasons in the same tone. Where the route is chosen: the detail screen shows every reason, and the library row shows the verdict only.

### 5. `RootView` (plan §12.1), new file `App/RootView.swift`

- **Structure.** A `NavigationView` with `.navigationViewStyle(.columns)`. It is a two-column sidebar on iPad and collapses to a stack on iPhone.
- **Sidebar.** A `List` with `.listStyle(.sidebar)` and four `NavigationLink`s using SF Symbol labels:

  | Entry | Title key |
  |---|---|
  | Library | `library.title` |
  | Game drives | `drives.title` |
  | This device | `status.title` |
  | Credits | `credits.title` |

- **Selection** is an enum `RootDestination { library, drives, device, credits }` held in `@State`.
  - It starts on `.library`, so the app opens on Library.
  - On iPad this is achieved by also supplying Library as the default detail view (the second view inside `NavigationView`).
  - On iOS 15, use `NavigationLink(tag:selection:)`.
- **Destinations.** `RootView` takes the controllers it passes down (the JIT controller, library controller, crash report controller and so on) as `@ObservedObject` or plain parameters. It builds `LibraryView`, `DrivesView`, `StatusView` and `CreditsView`. Sections 13–15 supply those views.
  - The crash banner sits at the top of Library. That is `LibraryView`'s job (section 13); `RootView` only passes the `CrashReportController` down.
- **Nested navigation fix.** `StatusContent` (in `App/StatusView.swift`) currently wraps itself in `NavigationView { … }.navigationViewStyle(.stack)`. Inside the column `NavigationView` this nests navigation views. Remove that wrapper from `StatusContent`, so it is a `List` with its `.navigationTitle`, and add the `NavigationView` inside `StatusView_Previews` instead, so the previews still look the same. Section 14 later moves and extends this file. Only the wrapper changes here.
- **Known quirk (plan §19).** On iOS 15 iPad the column style hides the sidebar in portrait, and selection can reset. This is accepted. A later `NavigationSplitView` behind `#available(iOS 16)` is possible, but it is not part of this split.

### 6. `EikonApp` wiring (plan §12.1), `App/EikonApp.swift`

`init()` sets things up in this order:

1. `JITController.shared.gatherFacts()`. This already exists.
2. Register runtimes with the `RuntimeRegistry`. In 02 there are none. `TestPatternRuntime` is **not** a route and isn't registered.
3. Create `SettingsController`, `GateStore`, `LibraryController` and `CrashReportController`. Creating `CrashReportController` consumes the session sentinel into crash history. It must come after `gatherFacts`, so outcomes and reports see the JIT facts.
4. Clean stale `.eikon-importing-*` staging folders on the drives that are available.
5. Start the drive scans.

Hold the controllers as `@StateObject`s, or as stored `@ObservedObject` properties initialized in `init`, following the current `JITController.shared` pattern. `body` shows `RootView(...)` instead of `StatusView(controller: jit)`.

Scene phase (`.onChange(of: scenePhase)`):
- **`.active`:** call `jit.sceneBecameActive()` (as today), re-evaluate the drive states, then rescan.
- **`.background`:** flush settings.

## Files

- Move: `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/Localizable.strings` to `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/en.lproj/Localizable.strings`, with the header updated and new keys added.
- New: `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/en.lproj/Localizable.stringsdict`
- New: `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/Strings/RouteStrings.swift`, `GateStrings.swift`, `EngineStrings.swift`, `CrashStrings.swift`, `LibraryStrings.swift`, and `StringsPreviews.swift` (DEBUG only)
- New: `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/RootView.swift`
- Modify: `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/EikonApp.swift` (init order, `RootView`, scene phases)
- Modify: `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/StatusView.swift` (remove the inner `NavigationView` from `StatusContent` and move it into the previews)

## Done when

- The app builds with `en.lproj` strings, and the existing status text renders.
- Every map is an exhaustive switch with no `default:`. The only exceptions are the documented fallbacks for unknown `GateName` values and missing `route.decline.<raw>` keys.
- The DEBUG previews show no raw keys for any reason, verdict, outcome, gate state, drive state, library status or identity prompt.
- The app opens on Library in a sidebar layout on iPad and a stack on iPhone, with four entries.
- The `EikonApp.init` order matches the list above, `.active` rescans, and `.background` flushes settings.
- `make test` passes.

## As built

**Files.**
- `App/en.lproj/Localizable.strings` (moved, with a new header and new keys) and `App/en.lproj/Localizable.stringsdict`, which covers games, files, bytes and drives.
- `App/Strings/`: `L10n.swift` (the shared lookup helpers), `RouteStrings.swift` (which also holds `JITStrings`), `GateStrings.swift`, `EngineStrings.swift`, `CrashStrings.swift`, `LibraryStrings.swift` and `StringsPreviews.swift` (DEBUG only).
- `App/RootView.swift`, `App/AppServices.swift` and `App/EikonApp.swift`.
- `App/StatusView.swift`: the inner `NavigationView` moved into the previews, and the preview helper is now `@MainActor`, which fixes a pre-existing warning.

**Deviations and additions.**
- **`AppServices`** holds the wiring, and `AppState` in `EikonApp.swift` creates it.
  - The order is JIT facts, then runtimes (none), then settings, gates, library, crash history and `CrashReportController` (which consumes the sentinel), then `SessionPresenter`, then `library.start()` (staging cleanup, drive states, worker, scan).
  - It also holds `AppRouteEnvironment`, the app's `RouteEnvironmentSource`. Route decisions recompute when gates change, when JIT usability changes, and when runtimes register.
- **Scene phases.**
  - `.active`: re-evaluate drives and rescan, after startup, one refresh at a time, and not during a game session.
  - `.background`: flush settings.
- **Unreadable files** (owner's rule). They are gathered once after wiring and shown in one alert, offering "Keep files" or "Start over". An unreadable library secret stops startup on its own warn-first screen, which offers Start over, keeping a backup and reopening the data.
- **`status.title`** now reads "This device", since it names the sidebar entry.
- **Extra maps:** `LibraryStrings` also maps `DriveRefusal` and `ImportOutcome`, for section 13.
- **Placeholders:** Library, Game drives and Credits are placeholders until sections 13 and 15.
- **Verification:**
  - `make test` passes.
  - `make package` and `make verify` pass.
  - The app bundle has `en.lproj/Localizable.strings` and `.stringsdict`, and no top-level strings file.
  - On the simulator, the app opens with localized text, and a corrupted `gates.json` shows the warning with the file left untouched.

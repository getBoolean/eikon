# Section 13: Library UI (App target)

> **Added after section 12 (owner's request):** harden the unreadable-file warning in `App/RootView.swift` while replacing its placeholders.
> - **The risk.** On iOS 15, an alert presented in the same frame that `NavigationLink(tag:selection:)` auto-activates `.library` can be dropped. iOS 15 and 16 can't be tested here: there's no device, and the oldest simulator runtime is iOS 17.
> - **The fix.** Show the warning only after the root view has appeared and yielded once, for example a `@State var showUnreadable` set from `.task { await Task.yield(); ... }` from `services.pendingUnreadable`. Keep "Keep files" and "Start over" wired to `AppServices` as they are.
> - **Checking.** On the iOS 17+ simulator, confirm that a corrupted `gates.json` still shows the warning at launch.

## Purpose

This section builds the screens a user sees for their games and game drives:

- the **Library** list and its rows
- **Game detail**: header, route section, the Launch button, crash history, identity tools and Remove
- the non-blocking **"Same game as…?" suggestion card**, plus the merge and split actions
- the **Import** sheet flow
- the **Remove game** dialog
- the **Game drives** screen
- the **crash banner** at the top of Library

All of these are SwiftUI views in the App target. They are thin presentation layers over controllers that earlier sections build. This section adds no new business logic. When a view seems to need logic, such as working out whether Launch is enabled or which status line a row shows, put it in a small pure presentation struct next to the view. 01's `StatusContent` works the same way. Previews can then render every state.

## Background (what Eikon is, briefly)

Eikon is an iPhone and iPad app that will run Windows and Linux x86 games (through Wine, FEX-Emu and Box64) and Kirikiri and Ren'Py games natively, all inside the app process. No game runs yet in this split (02). Runtimes arrive in later splits, so most routes show as "planned — not in this build yet".

Key concepts the UI shows:

- **Game drives.** Games sit flat inside game drives.
  - The built-in drive is the app's `Documents/` folder, shown in Files as "On My iPad/Eikon" (or "On My iPhone/Eikon").
  - Users can add folders on USB drives or other local storage as extra drives.
  - Each game is an immediate subfolder of a drive, or sits inside a single wrapper folder there.
  - Import **copies** a game folder into a drive the user picks.
- **Games and locations.** The library is a list of *games*, grouped by resolved game id (a random UUID). Each game has one or more *locations*, which are folders on drives.
  - Launch uses a reachable location. It prefers the built-in drive, then the most recently used location.
  - A location whose folder vanished while its drive is available is *missing*. It is shown and can be removed, but it is never deleted automatically.
  - Games with no locations are hidden.
- **Identity.** A location is matched to a game by content fingerprint. On real ambiguity the library posts a **non-blocking suggestion**, "same game as…?". The user can always merge ("Same game as…") or split ("This is a different game") by hand. A mistake yields a duplicate entry, never shared saves.
- **Routes.** Each game has a `RouteDecision`: a chosen candidate, all candidates with their verdicts and reasons, and an optional user override.
  - Verdicts are `runnable`, `runnableWithWarnings`, `planned` and `unavailable`.
  - Any route may be forced. If a forced route can't run, the app warns and still allows it.
- **Report id.** The first 8 characters of the random game id. It is the only game identifier that leaves the device on its own. Crash issues also carry the display name, because the user reviews the issue and chooses to submit it.

### Constraints that apply to every view here

- **No program titles anywhere except on screen.**
  - Display names and folder names are titles in practice. They may appear in the UI, and the display name in the crash issue the user reviews before submitting, but never in logs, breadcrumbs, the device report or the clipboard device report.
  - Don't `print` or `Logger` any name.
- **iOS 15 minimum.**
  - Use `NavigationView` and `ObservableObject`/`@ObservedObject`/`@EnvironmentObject`/`@StateObject`.
  - Don't use `NavigationStack`, `NavigationSplitView`, `@Observable`, `ShareLink`, `.confirmationDialog` features newer than iOS 15, `LabeledContent`, or `Grid`.
  - `.fileImporter`, `.alert(_:isPresented:actions:message:)` and `.confirmationDialog` exist on iOS 15 and are fine.
- **Swift 6 language mode** with complete concurrency checking. Views and controllers are `@MainActor`.
- **01's style.**
  - Small single-concept files.
  - Every enum→string mapping is an exhaustive `switch` with **no `default:`**. Those maps live in `App/Strings/` (section 12). Views here call them; they don't hand-write strings for codes.
- **All user-visible text comes from `App/en.lproj/Localizable.strings`/`.stringsdict`**, using the key namespaces `library.*`, `drives.*`, `import.*`, `identity.*`, `game.*`, `route.*`, `crash.*`. Plurals such as game counts, file counts, byte sizes and drive counts go through the `.stringsdict` that section 12 creates. Add any keys this section needs to those files.
- **Both builds are sandboxed.** Anything outside the container is reached only through security-scoped URLs returned by `.fileImporter`. The controllers handle bookmarks and access. The views only hand them the picked URL.

## Dependencies

These must be done first. Use their APIs; don't re-implement them.

- **Section 08 (gate store):** `GateStore`. Views here only read gate state indirectly, through `RouteDecision`.
- **Section 09 (library and drives):**
  - `LibraryController`, a `@MainActor ObservableObject` in EikonKit. It publishes drives and their states, games grouped by resolved game id with their locations, fingerprinting and identity state, suggestions, and each game's `RouteDecision`. Its entry points:
    - `addDrive`, `relinkDrive`, `removeDrive`
    - `importGame(from:to:name:)`
    - `rescan()`
    - `merge(_:into:)`, `split(location:)`, `dismissSuggestion`
    - `remove(game:deleteLocations:deleteData:)`
    - `retryFingerprint`
  - `ImportCoordinator`, which provides progress, cancel, the name-clash result and the space check.
  - `DriveManager`, which provides drive states `available`/`notConnected`/`needsRelink`, volume-kind refusals, and the relink confirmation.
  - `SettingsController`, which provides the display name (committed on submit) and `route.override`.
- **Section 11 (crash report controller):** `CrashReportController`. It publishes the current banner (outcome, game, route, time) and the per-game crash history (last 5). Its actions:
  - "Try another route", available only when another runnable candidate exists, and not for `test` records or removed games
  - "Report on GitHub", which opens the prefilled issue URL and puts the device report on the clipboard when the URL is too long
  - dismiss
- **Section 12 (strings and navigation):**
  - `RootView` with its sidebar entries: Library, Game drives, This device, Credits.
  - `en.lproj` strings and `.stringsdict`.
  - The exhaustive code→key maps in `App/Strings/`, such as `RouteStrings`, engine and architecture names, reason sentences, verdict names, outcome names and drive states.
  - The `EikonApp.init` wiring that creates and injects the controllers.
  - This section fills in the Library and Game drives destinations that `RootView` points at.
- **Section 10 (indirectly):** `SessionPresenter` and `GameSession`, which the Launch button calls. In 02 no runtimes are registered, so Launch for real games is normally disabled ("Not in this build yet"). Wire the call anyway.

Blocks: section 16 (landing: the device checks use these screens).

## Files to create

All paths are relative to the repo root `/Volumes/WD_SN770_1T/dev/GitHub/eikon/`:

```
App/Library/LibraryView.swift
App/Library/LibraryRow.swift
App/Library/GameDetailView.swift
App/Library/RouteSection.swift
App/Library/IdentitySuggestion.swift      # non-blocking "same game as…?" card + merge/split actions
App/Library/ImportFlow.swift              # pick game → pick drive → "will be copied" → progress
App/Library/RemoveGameDialog.swift
App/Library/CrashBanner.swift
App/Drives/DrivesView.swift               # list, add, relink, remove drives
```

Files to modify:
- `App/en.lproj/Localizable.strings` and `App/en.lproj/Localizable.stringsdict`: add the keys used here.
- `App/Strings/*`: add exhaustive maps for any new status enum you introduce, such as the library row status.
- `App/RootView.swift`: point the Library and Game drives sidebar destinations at `LibraryView` and `DrivesView`, if section 12 left placeholders.
- `project.yml`: only if XcodeGen doesn't already pick up the new `App/` subfolders by glob. Check this; 01 used a folder source.

Small pure presentation helpers may sit in the same file as their view, for example a `LibraryRowContent` with a `status` enum, or a `LaunchAvailability` computed from a location and a decision. Don't add new EikonKit or EikonCore types unless a controller is missing something the UI truly needs. In that case, add it to the controller in its own section's file, and keep it minimal.

## Tests (write first)

**No automated UI tests.** 01 has no UI test target, and the owner's standing rule is that tests stay few and behavioral and don't lock in implementation or hard-coded values. The behavior these screens trigger (import, merge, split, remove, override, crash actions) is already covered by EikonKit and EikonCore tests in sections 09, 11 and 06.

What stands in for tests:

1. **DEBUG previews that cover every state,** so a missing string key shows up as a raw key when rendered. Add `#if DEBUG` preview providers (`PreviewProvider`; the iOS 15 minimum rules out the `#Preview` macro for deployment, though Xcode may still allow it, so prefer `PreviewProvider`). They should render:
   - `LibraryRow` in every status: identifying, waiting for copy to finish, "same game as…?" suggestion, drive not connected, missing, hashing failed, and none. Each status also appears with every route badge style: chosen/runnable, runnable with warnings, planned, override, unavailable. Include a row with the USB-only drive indicator.
   - `LibraryView` empty state, a populated list, a list with the "Not recognized" section, and a list with the crash banner.
   - `RouteSection` for a decision containing every `RouteVerdict`, and a candidate list whose reasons together cover every `RouteReason` case (use one of each). Include an override with warnings, and the override picker.
   - The `IdentitySuggestion` card with one candidate and with several.
   - `CrashBanner` for every banner-worthy `SessionOutcome` (`crashed`, `likelyMemoryKill`, `endedUnexpectedly`), with and without the "Try another route" action.
   - `DrivesView` with drives in each `DriveState` (`available`, `notConnected`, `needsRelink`), plus the built-in drive.
   - `ImportFlow` at each step: no game found, pick drive, name clash, not enough space, progress, done.
   - `RemoveGameDialog` with locations on available and on unconnected drives.

   Previews use in-memory sample values. Build `RouteDecision`, `GameLocation`, `GameDrive` and similar values directly, or use preview-only controller instances over temp directories. Sample names must be generic, such as "Sample Game", never real titles.
2. **Build check:** `make test` (which includes `make test-swift`, and so compiles the App target) must pass.
3. **Device checks** (manual, run in section 16 and recorded by engine and hash only). They exercise these screens:
   - Import copies from Files "On My iPad" into the built-in drive (a fast clone).
   - Import copies from a USB-C drive, with working progress and cancel.
   - Add a USB-C folder as a game drive and its games appear. When it is unplugged they show "Drive not connected". When it is replugged they are available again.
   - A folder dropped into "On My iPad/Eikon" through Files appears on return to the app, after the quiescence delay.
   - The same folder name on the built-in drive and on the USB drive, with different contents, shows the same-or-different suggestion.
   - After a simulated crash (from section 14's developer action), the relaunch shows the banner. *Report on GitHub* opens a prefilled issue that contains codes and the report id (no name for a test session).

If you factor out a pure presentation helper with real branching, such as launch-button availability, you may add one small behavioral test for it in EikonKitTests, but only if the helper lives in EikonKit. The owner's rule is to keep tests few, so this is optional. Never assert exact strings or constants.

## Implementation details

### Library (`LibraryView`, `LibraryRow`)

**`LibraryView`** is the Library sidebar destination, and the app opens on it.

- **Crash banner:** when `CrashReportController` has a banner, show `CrashBanner` at the top of the list.
- **Toolbar:** a **+ Import game** button, which presents `ImportFlow` as a sheet.
- **List:** one row per game, grouped by resolved game id as `LibraryController` publishes it. Games with no locations are already hidden by the controller; don't show them. Each row navigates to `GameDetailView`.
- **"Not recognized" section:** drive folders where detection found no game (`detection == nil`). Show them with the hint *"Games must sit directly inside a game drive (one wrapper folder is fine)"*. Show the folder name on screen only.
- **Empty state:** shown when there are no games and no unrecognized folders. It explains that games live in game drives and covers three things:
  - the built-in "On My iPad/Eikon" folder in the Files app (use "On My iPhone/Eikon" on iPhone, choosing the string by `UIDevice.current.userInterfaceIdiom`)
  - adding a USB folder under **Game drives**
  - the **Import** button, which copies a game into a drive
- **Refresh:** pull-to-refresh (`.refreshable`, iOS 15) calls `LibraryController.rescan()`. Rescans also happen automatically on scene activation (section 12 wiring).

**`LibraryRow`** shows:
- the **display name**
- **engine and architecture**, through the `App/Strings` maps
- a **route badge** with one of these styles:
  - chosen/runnable
  - warning (`runnableWithWarnings`)
  - planned ("Planned")
  - override (when `decision.isOverride`)
  - "Unavailable" (when `decision.chosen == nil`)

  The row shows the **verdict only**. Reasons appear only on the detail screen.
- a **drive indicator** (a small icon or label) when the game's only locations are on non-built-in drives, for example USB
- a **status line**, only when one applies, in this priority order:
  1. *Identifying…* (fingerprinting pending or in progress; the full hash can take minutes, so show its progress. The game already has an id and can be launched and configured meanwhile)
  2. *Waiting for copy to finish* (not yet quiescent)
  3. *"Same game as …?"* (the location has a non-empty `suggestion`, minus `dismissedSuggestions`)
  4. *Drive not connected* (no reachable location because a drive is `notConnected` or `needsRelink`)
  5. *Missing* (every location is missing)
  6. *Hashing failed* (a fingerprint `failed(code)` state)

  The order above is a suggested default. What matters is that each state is distinguishable. Model the status as an enum in a small presentation struct, and map it to keys with an exhaustive switch.

### Game detail (`GameDetailView`, `RouteSection`, `IdentitySuggestion`)

`GameDetailView` shows one game, top to bottom:

1. **Suggestion card (`IdentitySuggestion`),** when the game has a pending suggestion.
   - Text: *"This might be the same game as <display name> (a different version). Use one entry?"* With several candidates, list each by display name.
   - **Merge** calls `LibraryController.merge(thisGame, into: candidate)`. With several candidates, the user picks one.
   - **Keep separate** calls `dismissSuggestion`.
   - The card is non-blocking. The rest of the screen, including Launch, is fully usable without answering. Never present it modally.
2. **Header.**
   - **Editable display name.** A `TextField` that commits through `SettingsController` on submit, not on every keystroke. The default is the first location's folder name. It stays read-only until the location has a game id, which the quick identity pass gives right after the folder is quiescent (section 09); the full hash doesn't block it.
   - **Engine details**, where present:
     - Unity scripting backend (Mono/IL2CPP) and best-effort version
     - Ren'Py version, marked exact or era
     - Kirikiri flavor (krkr2/krkrZ/unknown) and plugin base names
     - GameMaker build type (VM/YYC)
   - **Architecture per platform** (Windows/Linux → i386/amd64/arm64/other).
   - **Locations.** For each location: the drive label, whether it is reachable or not (not connected / needs relink), and missing. A missing location can be removed from here, through the Remove dialog or the controller's forget path.
3. **Route section (`RouteSection`).**
   - The **chosen route** and its reasons as sentences, using the reason-sentence map from `App/Strings`.
   - **Every candidate** in preference order, with its verdict and all its reasons.
   - An **Override** `Picker` offering *Automatic* plus every `RouteID`.
     - Unrunnable routes are selectable, with their reasons shown inline.
     - Selecting a route writes `route.override` through `SettingsController`. *Automatic* resets it. `LibraryController` recomputes the decision.
     - When `decision.isOverride` and `overrideWarnings` is non-empty, show the warnings.
   - Reason sentence style (strings come from section 12's keys; listed so the layout fits them):
     - `needsJIT`: "Needs JIT, which this install doesn't have: <01's JIT reason sentence>."
     - `box64Only32Bit`: "Without JIT, only 32-bit Windows games can run."
     - `fexPreferredWithJIT`: "Slower than Wine with FEX; used if that route can't run."
     - `gateUnmeasured(.x18)`: "Not yet verified on this device (x18 check). It may not work."
     - `gateFailed(stale: true)`: "Failed on this device before an update. Not re-checked yet."
     - `notInThisBuild`: "Planned. Not in this build yet."
     - A `runtimeDeclined(code)` uses the key `route.decline.<raw>`, falling back to a generic "This runtime can't run this game (<code>)".
     - Unknown gate names use a generic "<gate> check" sentence.
4. **Launch button.**
   - **Enabled** when the launch location has a game id, is reachable (its drive is `available` and the location isn't missing), and the chosen route is **built**, meaning its verdict isn't `planned`.
   - **Planned route:** the button is disabled, with the caption *"Not in this build yet"*.
   - **No chosen route** (unavailable): the button is disabled, and the reasons are visible in the route section.
   - **Forced route that can't run** (`isOverride` with a verdict of `unavailable`): tapping asks *"Launch anyway?"* and lists the override warnings. Confirming launches.
   - Before launching, ask `LibraryController` to re-evaluate drive states, then start the session through `GameSession`/`SessionPresenter` (section 10).
5. **Crash history.** The last 5 entries from `CrashReportController`/`CrashHistory` for this game id, read with the store's `mergeLinks()` so crashes recorded under games merged into this one appear too, each with outcome, route and date, and a *Report on GitHub* action on each. Reports can be filed later from here as well as from the banner.
6. **Identity** (a collapsed `DisclosureGroup`):
   - **Report id:** the first 8 characters of the game id. Make it selectable or copyable.
   - How many fingerprints (versions) are known.
   - **Same game as…:** pick another game from the library, then call `merge(thisGame, into: picked)`.
   - **This is a different game:** for a game with several locations, pick the location, then call `split(location:)`.
   - **Verify files:** runs `FileHasher` (full SHA-256 of the key file, for diagnostics) with progress and cancel, and shows the hash on screen. Never log it.
   - **Retry:** shown when fingerprinting failed. It calls `retryFingerprint`.
7. **Remove.** A destructive button that opens `RemoveGameDialog`.

### Import (`ImportFlow`)

This sheet drives `LibraryController.importGame(from:to:name:)`/`ImportCoordinator`.

1. **Pick the game.** Use `.fileImporter(allowedContentTypes: [.folder])`. Hand the security-scoped URL to the coordinator, which holds access for the whole import and runs detection.
   - With no game found, say so ("No game found here") and stop.
2. **Pick the drive.**
   - List the available drives with their free space. Preselect the built-in "On My iPad/Eikon" (or iPhone) drive.
   - Show the copy's size.
   - State plainly: **"The game's files will be copied to <drive>. The original folder is not changed."**
3. **Name check.** If the drive already has a folder with the same normalized name, offer three choices:
   - *Replace existing copy*. This keeps the existing game id and settings; it is how updates are installed through Import.
   - *Import with another name…*, a text field that must produce a new normalized name. Keep the confirm button disabled until it does.
   - *Cancel*.
4. **Space check.** If the coordinator reports insufficient space, show the shortfall and don't start copying.
5. **Progress.** Show a progress view with files and bytes (plurals through `.stringsdict`) and a **Cancel** button that calls the coordinator's cancel. Keep the sheet non-dismissable during the copy (`interactiveDismissDisabled`, iOS 15), or treat dismissing as cancel.
6. **Done or failed.** On success, close the sheet. The game appears in the library and settles: detection, then "Identifying…", then matched. On failure or cancel, show a one-line message. The coordinator has already removed its staging folder.

### Remove (`RemoveGameDialog`)

A sheet or form with two independent choices:

1. **Delete game files.** One checkbox (`Toggle`) per location on an **available** drive, showing the size and the drive label.
   - Locations on drives that aren't connected are listed as not deletable, and the dialog says so.
2. **Delete settings and saves (on all devices).** One toggle.

- When files are kept (not every location is checked), show *"This game will reappear while its folder is on a game drive"*.
- Confirm calls `LibraryController.remove(game:deleteLocations:deleteData:)` with the checked locations and the data toggle. With neither choice selected, the game's locations are forgotten.
- Use a destructive-styled confirm button, and add a second confirmation when files are deleted.

### Game drives (`DrivesView`)

- **Built-in drive:** "On My iPad/Eikon" (or "On My iPhone/Eikon"), with free space and game count, and a note that it is visible in the Files app. It has no remove action.
- **Other drives:** each row shows the label, the state (available / not connected / needs relink, through the `App/Strings` map), free space when available, and the game count. Actions:
  - **Find folder…** (shown for `needsRelink`, and allowed for any non-built-in drive). It opens `.fileImporter(allowedContentTypes: [.folder])` and calls `relinkDrive`. If the controller reports that the new folder contains none of the drive's known folder names, show a confirmation alert before committing.
  - **Remove drive (files are not touched).** It calls `removeDrive`. Say in the confirmation that the files and settings stay.
- **Add game drive…** opens `.fileImporter(allowedContentTypes: [.folder])` and calls `addDrive`.
  - Show the refusal reason for iCloud Drive (ubiquitous), network (SMB) and unknown volumes as a one-line message.
  - Show a caption that games on cloud-synced folders may be evicted, because other file providers can't be detected reliably.

Use one `.fileImporter` per view, with an enum that records which purpose (add or relink, and which drive) is pending. SwiftUI on iOS 15 misbehaves with several `.fileImporter` modifiers on one view.

### Crash banner (`CrashBanner`)

Shown at the top of `LibraryView` when `CrashReportController` publishes a banner. The outcomes that get one are `crashed`, `likelyMemoryKill` and `endedUnexpectedly`. A background kill never shows a banner; it goes to history only.

- **Content:** the outcome in words, the game's display name (on screen only), the route name and the time.
- **Actions:**
  - *Try <route> next time*: shown only when the controller offers it. It sets `route.override`.
  - *Report on GitHub*: the controller opens the URL with `UIApplication.open`. When the controller signals that the device report went to the clipboard, show the note telling the user to paste it into the issue.
  - *Dismiss*.

### Wiring notes

- Take the controllers from the environment (`@EnvironmentObject`), as section 12's `EikonApp`/`RootView` injects them, or by explicit init parameters, matching section 12's choice.
- `NavigationView` column style on iOS 15 iPad has quirks: the sidebar hides in portrait, and selection can reset. Keep the detail navigation (`NavigationLink` from row to `GameDetailView`) robust to the selection resetting. Don't hold critical state only in navigation selection.
- The game detail must stay correct when the underlying game changes identity while it is open, for example after a merge moves its location to another game id. Look up the game by id from the controller each time rather than caching a copy. If the id no longer resolves, follow the merge link or pop back.

## Done when

- All nine view files exist and are reachable from `RootView` (Library and Game drives in the sidebar, detail from rows, sheets from buttons).
- DEBUG previews render every row status, route verdict, route reason, banner outcome, drive state, import step and remove-dialog variant, and show no raw keys.
- No display name, folder name or fingerprint value is logged or leaves the device through these views.
- `make test` passes.

## As built

**Files.** These match the plan, with these additions:
- `App/Strings/GameStrings.swift`: route badges, launch captions and failures, identity failures, the built-in drive's name, byte sizes.
- The crash banner's view is `CrashBannerView`, because EikonKit already has a `CrashBanner` value type.

**Controller additions (minimal).**
- `LibraryController.forget(location:)` drops a *missing* location from the index. Nothing on disk is touched.
- Public memberwise initializers on `DriveSummary` and `CrashBanner`, for previews.
- No new tests. The owner's rule keeps tests few, and the build plus previews stand in for them.

**Structure.** Each screen is a stateful wrapper over a pure `…Content` view, like 01's `StatusView`/`StatusContent`. Previews render the content views:
- `LibraryContent`, `RouteSection`, `IdentitySuggestion`, `MergePicker`, `SplitPicker`, `CrashBannerView`
- `ImportContent`, `RemoveGameContent`, `DrivesContent`
- `EngineRows`, `LaunchButton` with every `LaunchState`, `CrashHistoryRow`

Controllers come in through explicit init parameters (`LibraryView(services:)`, `DrivesView(library:)`), matching section 12.

**Deviations.**
- **Route override:** the candidate list is the picker. It shows *Automatic* plus a row per candidate, and `RoutePicker` lists every `RouteID`. Each row has its verdict and reasons inline and a checkmark on the stored override. It is not a `Picker`, because labels with several lines of reasons are unreliable inside one on iOS 15.
- **Import progress:** shows "X of Y" bytes from the coordinator's fraction. No file count, because `ImportCoordinator` reports only a fraction. Success closes the sheet, so there is no "done" preview step.
- **Folders still settling** (detected, no game id yet) are listed as rows without navigation, so a copy in progress is visible.
- **Game detail:** sheets and alerts hang off the whole view, and each sheet keeps the game as it was when opened. A game that stops resolving therefore doesn't tear a flow down. After Remove, the detail pops from the sheet's `onDismiss`. A game that no longer resolves shows "This game is no longer in the library."
- **Display name:** commits on Return and when the field loses focus, never per keystroke.
- **Launch:**
  - "Verify files" is enabled only when the launch location is reachable and has a key file.
  - A missing launch location gets its own failure message.
  - `LaunchState` checks that the route is built before it checks for a forced route that can't run. An unbuilt route has no runtime to start, so "Launch anyway" couldn't run it either.
- **Unreadable-file warning:** shown from `.task { await Task.yield() … }`. After Start over, it is shown again about 0.5 s later, once the earlier alert is gone. On the iOS 26 simulator, a corrupted `gates.json` showed the warning at launch.

**Code review fixes.**
- `DrivesView`: whether the picker is showing and what it's for are kept in separate state. The alerts use `presenting:`.
- `FileVerifier` ignores late progress from a finished or replaced run.
- `forget` cancels fingerprinting only when it actually removes the location.

**Verification:** `make test` passes, and the app launches on the simulator.

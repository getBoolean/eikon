# Section 09: Status screen and localised strings

## Goal

Build Eikon's one screen, `App/StatusView.swift`, and the English `App/Localizable.strings` behind it. The screen shows:

- which build is running
- how it was installed
- whether the process has **usable** JIT, where the JIT came from, and, when JIT isn't usable, why and how to fix it
- basic device facts
- two actions that export the device report

Every user-facing string lives in `Localizable.strings`, including a cause-and-fix text for every `JITReasonCode`. That makes the app ready for translation in a later split (09 of the overall project). The screen uses system defaults for Dynamic Type and dark mode.

This section adds no game features and no new logic about JIT. It only presents what the controller (section 07) and the device report (section 08) already provide.

## Background

**What "usable" means.** "JIT" means the process may execute pages it wrote itself. On iOS that holds when the kernel has set `CS_DEBUGGED` in the process's code-signing flags. Eikon reports `usable = csDebugged && probe passed`. The probe is a small generated function that runs only when policy says it's safe. `usable` can change from false to true while the app runs, for example when TrollStore or an external enabler attaches, so the screen must update live. It must never assume that the state at launch is final.

**How each install method gets JIT.** The reason texts are written from these facts:

- **Dopamine 2.1+ and 3.x** (rootless jailbreak, app under the jailbreak's `Applications` directory). JIT is granted before `main()` when Dopamine's "Allow JIT in Apps" setting is on, which is the default. It is missing when:
  - that setting is off
  - tweak injection is disabled for the app (for example through Choicy)
  - the device is in safe mode
  - the jailbreak is Dopamine 2.0.x, which never marks apps
- **Other rootless jailbreaks** also use `/var/jb`, but they may not grant JIT.
- **TrollStore 2.0.12+.** The app opens TrollStore's enable-jit URL. TrollStore attaches to the running app, then detaches, and `CS_DEBUGGED` stays set. The app isn't relaunched. Nothing happens on TrollStore older than 2.0.12, or when TrollStore's URL scheme is disabled, so the request ends at a deadline with `trollStoreTimedOut`. The `.tipa` also needs Developer Mode on iOS 16+. Without it the app may not launch at all, so this is **not** a reason code. It is documented in the README and the depiction instead.
- **AltStore (sideloaded).** Eikon only detects JIT that an external enabler provided. It never links to, names or launches an enabler (owner decision).
- **TXM (iOS 26+ on chips that have Apple's Trusted Execution Monitor).** `CS_DEBUGGED` alone is not enough there. Eikon reports JIT as not usable (`txmEnforced`) and never runs JIT code. When TXM can't be ruled out on iOS 26+, the reason is `txmUndetermined` and the device is treated as enforced.
- **Simulator.** JIT is never probed there, and the reason is always `simulator`.

**Platform floor.** iOS 15.0. Use `NavigationView`, not `NavigationStack`, and `ObservableObject`/`@ObservedObject`, not `@Observable`. Don't use `ShareLink`; sharing uses section 08's `UIActivityViewController` bridge. Swift 6 language mode with complete strict concurrency: views are main-actor, and `JITController` is `@MainActor`.

## Dependencies

These must exist first. They are referenced here, not redefined.

- **Section 02 (Xcode project).** The `Eikon` app target builds `App/` and depends on `EikonKit`. Info.plist carries `CFBundleShortVersionString`, `CFBundleVersion`, `EKGitCommit` and `EKPackageKind`. `App/EikonApp.swift` exists.
- **Section 05 (install detection).** `InstallMethod` (`dopamine`, `rootlessJailbreak`, `trollStore`, `trollStoreLite`, `sideloaded`, `simulator`, `unknown`), `InstallEvidence`, and the helpers that read the package kind (`EKPackageKind`) and the runtime bundle id (`Bundle.main.bundleIdentifier`, never the literal id, because AltStore may rewrite it).
- **Section 06 (JIT core).** The value types the screen displays:
  - `JITStatus`: `csDebugged`, `csDebuggedSeen`, `txm`, `probe`, `source`, `reason` (nil exactly when usable), and the computed `usable`
  - `CSDebuggedSeen`: `never`, `atLaunch`, `afterTrollStoreRequest`, `onForeground`
  - `JITSource`: `none`, `dopamine`, `rootlessJailbreak`, `trollStore`, `externalEnabler`, `preexisting`, `unknown`
  - `ProbeOutcome`: `kind` (`notRun`, `passed`, `failed`) and an optional `detail`
  - `TXMInfo`: `state` (`present`, `absent`, `unknown`), `enforced` and `basis`
  - `JITReasonCode` (`CaseIterable`): `dopamineJITOff`, `rootlessJailbreakNoJIT`, `trollStoreRequestPending`, `trollStoreTimedOut`, `sideloadedNoJIT`, `txmEnforced`, `txmUndetermined`, `probeSkippedAfterCrash`, `probeFailed`, `unknownInstallNoJIT`, `simulator`
- **Section 07 (JIT controller).** `JITController.shared` (`@MainActor`, `ObservableObject`) publishes `status`, `installMethod`, `evidence` and `isRequestingTrollStoreJIT`. It offers `retryTrollStoreJIT()` and `retryProbe()`. `EikonApp` owns it with `@ObservedObject` and calls `gatherFacts()` at init and `sceneBecameActive()` on every `.active` scene phase. That wiring belongs to section 07; this section doesn't change it.
- **Section 08 (device report).** It provides:
  - the `DeviceReport` model and a way to build one from the current app, install and JIT state
  - device info: model identifier (`hw.machine`), chip display name, CPU family
  - OS info: name, version, build (`kern.osversion`)
  - memory info: available bytes from `os_proc_available_memory`
  - the export helpers in `App/ReportExport.swift`: copy JSON to the pasteboard, and a share sheet (a `UIActivityViewController` bridge that shares a temporary `.json` file)

If a name above differs slightly in the finished sections, use the finished section's name. The behaviour described here is what matters.

## Tests

**No automated UI tests** (TDD plan §14). The owner's rule holds: tests stay few and behavioral, and never pin file contents, constants or string texts. So:

- Don't write tests that assert the text of any string, any `Localizable.strings` key, or the layout or order of rows.
- Don't add a snapshot test or an XCUITest target.

Completeness is enforced by construction instead:

1. **The compiler checks that every reason code has text.** Map `JITReasonCode` to its string key with an exhaustive `switch`, with no `default:` branch. The same goes for `InstallMethod`, `JITSource`, `CSDebuggedSeen`, `ProbeOutcome.Kind` and `TXMState`. A case added later then fails the build until it gets text.
2. **A preview shows that every key exists.** A `PreviewProvider` (iOS 15-compatible; not the `#Preview` macro) renders the reason text for every `JITReasonCode.allCases` case, plus the JIT section in a few representative states. A missing entry in `Localizable.strings` shows up as a raw key.

**Manual verification in the simulator.** Do this before calling the section done.

- `make test-swift` still builds the app and passes the existing `EikonKitTests`.
- The app launches on an iPhone simulator and an iPad simulator. The screen shows all five sections.
- In the JIT section: "Not usable", the simulator reason text, source "none", probe "not run", and TXM "absent" with basis "simulator". Neither Retry button shows (the install method is `simulator`).
- No raw localisation key is visible anywhere, on the screen or in the preview.
- **Copy report** puts JSON on the pasteboard. Paste it into another app or check it with `xcrun simctl pbpaste booted`. The JSON has the report's top-level keys. It carries no device name.
- **Share report** opens the share sheet on iPhone, and on iPad without crashing. It shares a `.json` file.
- Dark mode, the largest accessibility text size, and rotation to landscape all leave text readable and unclipped. The iPad doesn't show an empty sidebar column.

Device behaviour (TrollStore pending → usable, `trollStoreTimedOut` plus Retry JIT, `dopamineJITOff`, `txmEnforced`) is checked by the device runbook in section 12 and recorded in filed device reports.

## Files

| Path | Action |
|---|---|
| `App/StatusView.swift` | Create. The screen, its row helpers, enum-to-string-key mappings, and the preview. |
| `App/Localizable.strings` | Create. English strings for everything on the screen. |
| `App/EikonApp.swift` | Modify. Make `StatusView` the root content of the `WindowGroup`, passing it the controller the app already owns. Don't touch the scene-phase or `gatherFacts()` wiring from section 07. |

`project.yml` includes `App/` as the target's sources, so XcodeGen picks up `Localizable.strings` as a resource automatically. Run `make project` and confirm it lands in the built bundle's resources. Keep the file at `App/Localizable.strings`, as the repository layout specifies. Moving it into `en.lproj` and adding other languages is the later localisation split's job. `NSLocalizedString` and `LocalizedStringKey` also find an unlocalised `Localizable.strings` at the bundle root.

## Implementation

### Structure

Split the screen into two views, so the preview can render any state without constructing a real controller:

```swift
/// Root screen. Observes the controller and gathers the static facts once.
struct StatusView: View {
    @ObservedObject var controller: JITController
    // builds the device/app info on appear; forwards Retry actions to the controller;
    // builds the DeviceReport at tap time for Copy/Share
}

/// Pure presentation of one snapshot plus action closures. Used by StatusView and the preview.
struct StatusContent: View {
    let app: AppInfoRows          // version, build, commit, package kind, bundle id
    let installMethod: InstallMethod
    let status: JITStatus
    let isRequestingTrollStoreJIT: Bool
    let device: DeviceRows         // model id, chip, OS version + build, available memory
    let onRetryJIT: () -> Void
    let onRetryProbe: () -> Void
    let onCopyReport: () -> Void
    let onShareReport: () -> Void
}
```

`AppInfoRows` and `DeviceRows` are small private structs of display-ready values. They can be whatever is convenient, and they may reuse section 08's `AppInfo`, `DeviceInfo`, `OSInfo` and `MemoryInfo` directly if those fit.

Wrap the list in a `NavigationView`, with the navigation title "Eikon" (localised) and `.navigationViewStyle(.stack)`, so the iPad shows one full-width column. Use `List` with `.listStyle(.insetGrouped)`.

### Sections and rows

Use `Section` headers from `Localizable.strings`. Use label/value rows: an `HStack` with the label leading and the value trailing in secondary colour, or `LabeledContent`-style layout built by hand, since `LabeledContent` needs iOS 16. Let rows wrap at large text sizes instead of truncating. Make identifier-like values selectable with `.textSelection(.enabled)` (iOS 15): commit, bundle id and model identifier.

**1. Eikon**
- **Version:** `CFBundleShortVersionString (CFBundleVersion)`, for example "0.1.0 (123)". Use a localised format string with two arguments.
- **Commit:** `EKGitCommit`, shown verbatim.
- **Package kind:** `EKPackageKind` (`development`, `deb`, `tipa`, `ipa`), shown verbatim. It's an identifier, not prose.
- **Bundle id:** the runtime `Bundle.main.bundleIdentifier`, shown verbatim.

A missing Info.plist value shows a localised "unknown" placeholder, never a crash or an empty row.

**2. Install**
- **Detected method,** in words, from `controller.installMethod`. Suggested words:
  - Dopamine
  - rootless jailbreak
  - TrollStore
  - TrollStore Lite
  - sideloaded
  - simulator
  - unknown

The package kind and the detected method can disagree, for example a `.tipa` installed on a Dopamine device. That's informative, not an error, so don't style it as a warning.

**3. JIT**

Rows in this order:

1. **The large state.** "Usable" or "Not usable", from `status.usable`, in a prominent font (for example `.title2.weight(.semibold)`). Pair it with an SF Symbol (`checkmark.circle.fill` or `xmark.circle.fill`) and a tint (green or secondary/orange), so colour isn't the only signal. Give the row a combined accessibility label.
2. **Pending row.** Only while `controller.isRequestingTrollStoreJIT` is true: a `ProgressView()` plus "Waiting for TrollStore…".
3. **Reason text.** When `status.reason` is non-nil: the localised cause-and-fix text for that code (see the table below), as a multi-line footnote-sized `Text`. Skip it for `trollStoreRequestPending` while the pending row is showing, so the two don't duplicate each other.
4. **Source:** `status.source` in words:

   | `JITSource` | Words |
   |---|---|
   | `none` | none |
   | `dopamine` | Dopamine |
   | `rootlessJailbreak` | rootless jailbreak |
   | `trollStore` | TrollStore |
   | `externalEnabler` | external enabler |
   | `preexisting` | already enabled at launch |
   | `unknown` | unknown |

5. **CS_DEBUGGED:** "yes" or "no", followed by when it was seen, if not `never`:

   | `CSDebuggedSeen` | Words |
   |---|---|
   | `atLaunch` | at launch |
   | `afterTrollStoreRequest` | after TrollStore request |
   | `onForeground` | on returning to the app |

   The label `CS_DEBUGGED` is a technical term. It still lives in the strings file, but its value isn't translated.
6. **Probe:** `status.probe.kind` in words ("not run", "passed", "failed"). Show `status.probe.detail` verbatim on a second, secondary line when present. It comes from the controller and C layer (which step failed, or which signal fired).
7. **TXM:** state in words ("present", "absent", "unknown"), "enforced" or "not enforced", and `txm.basis` verbatim on a secondary line.
8. **Retry JIT.** A button, visible only when all of these hold:
   - `installMethod` is `trollStore` or `trollStoreLite`
   - `!status.usable`
   - `!controller.isRequestingTrollStoreJIT`

   It calls `controller.retryTrollStoreJIT()`. The controller ignores the cooldown for manual retries.
9. **Retry probe.** A button, visible only when `status.reason` is `probeSkippedAfterCrash` or `probeFailed`. It calls `controller.retryProbe()`. The controller still writes the crash sentinel around the probe, so if the probe kills the process, the next launch skips it again. Don't add a confirmation dialog.

Both buttons fire and forget. The screen updates through the controller's `@Published` properties. Don't keep a separate copy of the state in the view.

**4. Device**
- **Model identifier** (`hw.machine`), verbatim.
- **Chip:** the display name from section 08's table, or its "unknown" fallback.
- **iOS:** version and build, for example "17.0 (21A329)", from a localised two-argument format.
- **Available memory:** section 08's available-bytes value, formatted with `ByteCountFormatter` (`.memory` style). Read it in `onAppear`, and again when the scene becomes active if that's simple. The value is a snapshot, so don't poll it on a timer.

Never show the user-assigned device name, UDID or serial number.

**5. Report**
- **Copy report.** Builds a fresh `DeviceReport` from the current state at tap time, so it reflects the latest JIT status, and hands it to section 08's copy helper. Afterwards, show brief confirmation text ("Copied"), for example a secondary label that clears after about two seconds. Use a `Task` with `Task.sleep` on the main actor; there's no need for an alert.
- **Share report.** Builds a fresh report the same way and presents section 08's share bridge in a `.sheet`. The shared file is the temporary `.json` that section 08 names.
  - On iPad, a `UIActivityViewController` presented directly needs a popover anchor, so present it through the SwiftUI sheet bridge (which avoids the popover requirement). Or, if section 08's bridge sets `popoverPresentationController.sourceView`, use that.
  - Check both iPhone and iPad in the simulator.

If building or encoding the report fails, show a localised error line in the Report section. Don't crash and don't use `fatalError`.

### String mappings

Keep the mappings from enum to key in `StatusView.swift`, as `fileprivate` extensions or helper functions. Each is an exhaustive `switch` returning a `LocalizedStringKey` (for `Text`) or calling `NSLocalizedString` (for values passed through `String(format:)`). **Don't build keys dynamically from `rawValue`.** Literal keys keep the compiler's exhaustiveness check meaningful, and they let Xcode's string extraction find them in the later localisation split.

Suggested key scheme, lowercase and dot-separated, grouped by comment blocks in the strings file:

- `status.title`
- `status.section.app`, `status.section.install`, `status.section.jit`, `status.section.device`, `status.section.report`
- `status.app.version` (format `%1$@ (%2$@)`), `status.app.commit`, `status.app.packageKind`, `status.app.bundleId`
- `status.value.unknown`, `status.value.yes`, `status.value.no`
- `install.method.dopamine` … `install.method.unknown`, one per `InstallMethod` case
- `jit.state.usable`, `jit.state.notUsable`, `jit.pending`
- `jit.source.label`, then `jit.source.<case>` for each `JITSource`
- `jit.csDebugged.label`, then `jit.seen.<case>` for each `CSDebuggedSeen` except `never`
- `jit.probe.label`, `jit.probe.notRun`, `jit.probe.passed`, `jit.probe.failed`
- `jit.txm.label`, `jit.txm.present`, `jit.txm.absent`, `jit.txm.unknown`, `jit.txm.enforced`, `jit.txm.notEnforced`
- `jit.retryJIT`, `jit.retryProbe`
- `jit.reason.<case>` for every `JITReasonCode`
- `device.model`, `device.chip`, `device.os` (format `%1$@ (%2$@)`), `device.memory`
- `report.copy`, `report.share`, `report.copied`, `report.error`

These keys are guidance, not a contract. Nothing tests them.

### Reason texts

Every non-usable status has exactly one reason code, and every code needs a text giving **the cause and the fix**. Write them in plain English, one or two short sentences each. They must not:

- name any program or game title
- link to or name any JIT enabler (for example, the `sideloadedNoJIT` text doesn't mention any)
- promise features that don't exist yet

Draft English texts follow. They are a starting point, and wording can be adjusted freely:

| Code | Cause and fix |
|---|---|
| `dopamineJITOff` | Dopamine didn't enable JIT for Eikon. Turn on "Allow JIT in Apps" in Dopamine's settings, make sure tweak injection isn't disabled for Eikon and the device isn't in safe mode, then relaunch Eikon. Dopamine 2.0 doesn't provide JIT; update to 2.1 or later. |
| `rootlessJailbreakNoJIT` | This jailbreak didn't enable JIT for Eikon. Features that need JIT are unavailable; everything else still works. |
| `trollStoreRequestPending` | Asking TrollStore to enable JIT… |
| `trollStoreTimedOut` | TrollStore didn't enable JIT. Update TrollStore to 2.0.12 or later and make sure its URL scheme is enabled in TrollStore's settings, then tap Retry JIT. |
| `sideloadedNoJIT` | JIT isn't enabled for this install. Features that need JIT are unavailable; everything else still works. |
| `txmEnforced` | This device requires a debugger to approve JIT code. Enabling JIT with an enabler won't make it usable here yet. Native routes still work. |
| `txmUndetermined` | Eikon couldn't confirm whether this device requires debugger approval for JIT, so JIT is treated as unavailable to be safe. Native routes still work. A device report helps fix this. |
| `probeSkippedAfterCrash` | The last launch ended during the JIT check, so it was skipped this time. Tap Retry probe to run it again. |
| `probeFailed` | JIT appears to be enabled, but a test of it failed (details below). Tap Retry probe, and please share a device report. |
| `unknownInstallNoJIT` | Eikon couldn't tell how it was installed, and JIT isn't enabled. Features that need JIT are unavailable; everything else still works. |
| `simulator` | JIT is never enabled in the simulator. |

Don't add a reason about Developer Mode for the `.tipa`. That requirement is documented in the README and the depiction.

### Preview

Add a `PreviewProvider` (under `#if DEBUG`) with:

- `StatusContent` in about four states, using literal `JITStatus` values and no-op closures:
  - usable (source `dopamine`)
  - pending TrollStore request
  - `trollStoreTimedOut` on a TrollStore install, so Retry JIT shows
  - `probeFailed` with a detail, so Retry probe shows
- a plain `List` that renders the reason text for every `JITReasonCode.allCases` value

Put the preview's sample values in the preview only. Don't add test-only initialisers to the EikonKit types.

### Style constraints

- System fonts, colours and list styles only. Dynamic Type and dark mode come from system defaults, with no custom colours that break in dark mode.
- Don't use `NavigationStack`, `@Observable`, `ShareLink`, `LabeledContent` or the `#Preview` macro (iOS 15 floor).
- No hard-coded user-facing English in Swift. Every visible string, including button titles, section headers and format strings, comes from `Localizable.strings`. Values that are identifiers or raw diagnostic data are shown verbatim and not translated: commit, bundle id, package kind, model identifier, OS build, probe detail and TXM basis.
- No program or game titles anywhere: code, strings, previews or comments.

## Done when

- `App/StatusView.swift` and `App/Localizable.strings` exist, and `EikonApp` shows `StatusView` as its root.
- `make test-swift` builds and passes. The app builds with no strict-concurrency warnings or errors from the new code.
- Every `JITReasonCode`, `InstallMethod`, `JITSource`, `CSDebuggedSeen`, probe kind and TXM state maps through an exhaustive `switch` to a key that exists in `Localizable.strings`. The preview shows no raw keys.
- The simulator checklist under **Tests** passes on an iPhone and an iPad simulator.

---

## Implementation notes (as built)

Files: `App/StatusView.swift` (the screen, `StatusContent`, the row helpers, the exhaustive enum→key maps, and the `#if DEBUG` preview), `App/Localizable.strings` (69 English keys), and `App/EikonApp.swift` (now `StatusView(controller: jit)`).

- Every `JITReasonCode`, `InstallMethod`, `JITSource`, `CSDebuggedSeen`, `ProbeOutcome.Kind` and `TXMState` maps through an exhaustive `switch` with no `default`, so a new case fails the build. All 69 keys used in the Swift resolve to entries in the strings file, which is bundled.
- Identifiers and diagnostics are shown verbatim and untranslated: commit, bundle id, package kind, model identifier, OS build, probe detail, TXM basis.
- Verified in the simulator on an iPhone and an iPad: five sections, a single full-width column on iPad, no raw keys, the `simulator` reason, source none, probe not run, TXM absent with basis "simulator", and neither Retry button. `make test-swift` passes (21 EikonKitTests).
- Available memory shows "Zero KB" in the simulator, because `os_proc_available_memory()` returns 0 there. It reports real values on a device.
- Review fixes: a private `ShareItem` wrapper replaced a retroactive `URL: Identifiable`; the "Copied" reset became a cancellable Task; the probe-failed preview state was made consistent; the memory cast uses `Int64(clamping:)`.

Device JIT states (TrollStore pending→usable, `trollStoreTimedOut` with Retry JIT, `dopamineJITOff`, `txmEnforced`) are checked by the section 12 runbook and filed device reports.

The review trail is in `../implementation/code_review/section-09-*.md`.

# Section 02: Xcode project, app shell and minimal CI

## Background

Eikon is an iPhone and iPad app (SwiftUI, iOS 15.0 minimum) in the public repo `github.com/getBoolean/eikon`. The first planning split creates the project from nothing: build system, packaging for three install methods (a Dopamine rootless deb, a TrollStore `.tipa`, an AltStore `.ipa`), JIT detection, a device report and a credits pipeline. One build produces **one app binary**. The three artifacts differ only in entitlements, one Info.plist stamp (`EKPackageKind`) and container format.

This section creates the Xcode side of that build:

- an XcodeGen spec (`project.yml`) plus `.xcconfig` files. The generated `.xcodeproj` is **never committed**; `.gitignore` already excludes `*.xcodeproj`.
- the local Swift package `Packages/EikonKit`, which holds the testable core. It has a C target and a Swift target, both empty for now, and a Swift Testing target wired into the app's scheme.
- a minimal app shell (`App/`) that builds and launches in the simulator and shows the version stamps from its Info.plist.
- the `make project` and `make test-swift` targets.
- a README note on the Xcode debug loop.
- a minimal `.github/workflows/ci.yml` that surfaces CI runner problems early.

Why XcodeGen, not Theos or a committed project: the spec is deterministic and easy to diff. Theos fits SwiftUI and large C++ dependencies poorly, and a committed `project.pbxproj` causes merge noise.

### Development environment facts

- macOS 27, Xcode 27.0 (iOS SDK 27.0), Swift 6.4. The iOS 27 SDK's minimum deployment target is 15.0, so iOS 15.0 is valid.
- `~/.swiftly/bin` comes before `/usr/bin` on PATH. Scripts must therefore reach Apple's toolchain through `xcrun` (`xcrun xcodebuild`, `xcrun simctl`, `xcrun swift`), never a bare `swift` or `clang`.
- System Python is 3.9.6. Any Python must run through `uv run` on Python 3.12 (pinned by `.python-version` from section 01), using only the standard library. **No Python, and no script of any kind, runs inside an Xcode build phase.**
- `xcodegen` may be missing; `make doctor` (section 01) reports it.

### Rules that apply to this section

- **Tests stay few and behavioral.** They never pin file contents, constant values, string texts or internal structure. This section has no behavioral logic, so it adds no real unit tests (see "Tests").
- **No program or game titles** anywhere: code, comments, assets, test names, commit messages. Don't touch `/Volumes/Games`.
- **iOS 15 API floor.** Don't use `NavigationStack`, `@Observable`/Observation, `Mutex`, `OSAllocatedUnfairLock` or `ShareLink`. Use `NavigationView` and `ObservableObject`.
- **No `PrivacyInfo.xcprivacy`.** It matters only for App Store distribution, which no install method uses.
- **Owner approval first** for anything outward-facing. Pushing the CI workflow to GitHub is a push, so ask first.

## Dependencies

- **Requires section 01 (skeleton and tooling).** From it this section uses:
  - `VERSION`, `.gitignore` (which already ignores `build/`, `dist/`, `*.xcodeproj`, `DerivedData` and `.venv`), `.python-version`, `pyproject.toml` and the pytest scaffold under `tests/`.
  - `scripts/version.sh`, which writes `build/generated/Version.xcconfig` with `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and `EIKON_GIT_COMMIT`. It fails on a shallow clone unless `EIKON_BUILD_NUMBER` is set.
  - the `Makefile` with every target. Targets whose work belongs to later sections are stubs that print which section implements them and exit 1. `test-swift` currently **skips** while `project.yml` doesn't exist. This section replaces the `project` and `test-swift` targets with real ones.
- **Blocks:**
  - section 04, which adds acknowledgements JSON selection to `project.yml` and the credits step to CI.
  - section 05, which adds the first real Swift code and tests to `EikonKit`.
  - section 10, which archives and packages the app and extends `ci.yml`.
- **Can run in parallel with** section 03 (patch convention). Both touch only their own files, apart from separate Makefile targets.

## Tests

The TDD plan for this part is explicit: **no unit tests.** The checks are:

1. `make project` generates the project from a clean checkout.
2. `make test-swift` builds the app and the package, runs the `EikonKitTests` target on the newest available iPhone simulator, and installs and launches the app on that simulator.
3. The CI `build` job runs step 2 on a GitHub macOS runner.

One Swift file is still needed in `Packages/EikonKit/Tests/EikonKitTests/`, because SwiftPM rejects a test target with no sources. Keep it to a single trivial smoke test that imports `EikonKit` (proving the test target links against the library) and makes one always-true expectation. Don't add assertions about constants, strings or structure.

```swift
// Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift
import Testing
@testable import EikonKit

/// Proves the test target builds, links EikonKit, and runs on the simulator.
/// Section 05 deletes this file when it adds real tests.
@Test func packageLinks() { #expect(Bool(true)) }
```

Section 05 deletes this file once it adds the install-detection tests.

## Implementation

### Files to create or modify

| Path | Action |
|---|---|
| `project.yml` | create |
| `Config/Base.xcconfig`, `Config/Debug.xcconfig`, `Config/Release.xcconfig` | create |
| `Packages/EikonKit/Package.swift` | create |
| `Packages/EikonKit/Sources/CEikonJIT/include/CEikonJIT.h` | create (empty header with include guard) |
| `Packages/EikonKit/Sources/CEikonJIT/CEikonJIT.c` | create (includes the header only) |
| `Packages/EikonKit/Sources/EikonKit/EikonKit.swift` | create (module doc comment only) |
| `Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift` | create (above) |
| `App/EikonApp.swift` | create |
| `App/StatusView.swift` | create (placeholder; section 09 replaces it) |
| `App/Info.plist` | create |
| `App/Assets.xcassets/` (`Contents.json`, `AppIcon.appiconset/`) | create |
| `App/Resources/Acknowledgements.json` | create, content `[]` |
| `scripts/test_swift.sh` | create (executable) |
| `Makefile` | modify the `project` and `test-swift` targets |
| `.gitignore` | modify: add `Config/Local.xcconfig` |
| `README.md` | modify: add "Building" and "Debug loop" notes |
| `.github/workflows/ci.yml` | create |

### `Config/*.xcconfig`

`Config/Base.xcconfig` holds every shared setting. `Debug.xcconfig` and `Release.xcconfig` each start with `#include "Base.xcconfig"` and add only configuration-specific settings (for example `SWIFT_OPTIMIZATION_LEVEL`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` in Debug, `DEBUG_INFORMATION_FORMAT`).

Base contents, in this order:

1. **Fallback version values**, so the project opens in Xcode before `make version` has ever run: `MARKETING_VERSION = 0.0.0`, `CURRENT_PROJECT_VERSION = 0`, `EIKON_GIT_COMMIT = unknown`.
2. **`#include? "../build/generated/Version.xcconfig"`**, *after* the fallbacks so the generated values win. The `?` makes the include optional. The path is relative to the `Config/` directory.
3. Platform and language:
   - `SDKROOT = iphoneos`, `SUPPORTED_PLATFORMS = iphoneos iphonesimulator`
   - `IPHONEOS_DEPLOYMENT_TARGET = 15.0`
   - `TARGETED_DEVICE_FAMILY = 1,2` (iPhone and iPad)
   - `ARCHS = arm64`, with no `x86_64` slice. Intel-Mac simulators are not supported.
   - `SWIFT_VERSION = 6.0` (Swift 6 language mode) and `SWIFT_STRICT_CONCURRENCY = complete`
4. Identity: `PRODUCT_BUNDLE_IDENTIFIER = com.getboolean.eikon`, `PRODUCT_NAME = Eikon`.
5. `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE = App/Info.plist`. The plist is hand-written and committed.
6. `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
7. Signing: `CODE_SIGN_STYLE = Automatic` with no team set, then **`#include? "Local.xcconfig"`** last. `Config/Local.xcconfig` is untracked; add it to `.gitignore`. The owner puts `DEVELOPMENT_TEAM = …` there for debug runs on a device. Simulator builds and CI never need it. Archive builds (section 10) pass `CODE_SIGNING_ALLOWED=NO`.

### `Packages/EikonKit/Package.swift`

- `// swift-tools-version:6.0`
- `platforms: [.iOS(.v15)]`
- Products: one library `EikonKit`.
- Targets:
  - `CEikonJIT`, a C target with public headers in `include/`. Later sections add the `csops` wrapper, the JIT probe and the TXM firmware check here.
  - `EikonKit`, a Swift target that depends on `CEikonJIT`.
  - `EikonKitTests`, a test target that depends on `EikonKit` and uses Swift Testing (`import Testing`). No XCTest.
- `swiftLanguageModes: [.v6]`.

Keep the sources empty apart from what compiles: an include-guarded header with a short comment on the module's purpose, a `.c` file that includes it, and a Swift file with a doc comment. The C target must exist now so later sections add code without restructuring the package.

### `project.yml`

Stubbed outline; the values are the requirements:

```yaml
name: Eikon
options:
  deploymentTarget: { iOS: "15.0" }
  createIntermediateGroups: true
configFiles:
  Debug: Config/Debug.xcconfig
  Release: Config/Release.xcconfig
packages:
  EikonKit:
    path: Packages/EikonKit
targets:
  Eikon:
    type: application
    platform: iOS
    sources:
      - path: App
    dependencies:
      - package: EikonKit
        product: EikonKit
    # No preBuildScripts / postBuildScripts: no build-phase scripts at all.
schemes:
  Eikon:
    build:
      targets: { Eikon: all }
    test:
      targets:            # XcodeGen's key is `targets`; `testTargets` is silently ignored
        - package: EikonKit/EikonKitTests
    run:
      config: Debug
    archive:
      config: Release
```

Notes:

- Keep build settings in the xcconfigs, not inline in `project.yml`, so both the project and the target read the same values. Inline settings only where XcodeGen requires them.
- **Acknowledgements resource.** In this section `App/Resources/Acknowledgements.json` (content `[]`) is bundled simply as part of the `App/` sources. Section 04 changes this so the Makefile passes the generated file's path (`build/generated/Acknowledgements.json`) when it exists and the placeholder otherwise, and excludes the placeholder from the `App/` glob. Don't build that switch here.
- **Display name** "Eikon" comes from `CFBundleDisplayName` in the Info.plist.

### `App/Info.plist`

Hand-written and committed. Values that come from build settings use `$(…)` so the version stamp flows from `VERSION` and git:

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `$(PRODUCT_BUNDLE_IDENTIFIER)` |
| `CFBundleExecutable` | `$(EXECUTABLE_NAME)` |
| `CFBundleName` | `$(PRODUCT_NAME)` |
| `CFBundleDisplayName` | `Eikon` |
| `CFBundlePackageType` | `$(PRODUCT_BUNDLE_PACKAGE_TYPE)` |
| `CFBundleShortVersionString` | `$(MARKETING_VERSION)` |
| `CFBundleVersion` | `$(CURRENT_PROJECT_VERSION)` |
| `CFBundleDevelopmentRegion` | `$(DEVELOPMENT_LANGUAGE)` |
| `CFBundleInfoDictionaryVersion` | `6.0` |
| `LSRequiresIPhoneOS` | `true` |
| `EKGitCommit` | `$(EIKON_GIT_COMMIT)` |
| `EKPackageKind` | `development`. The packager (section 10) overwrites it with `deb`, `tipa` or `ipa` in each artifact. |
| `UILaunchScreen` | an empty dictionary. This prevents letterboxing and allows iPad multitasking. |
| `UISupportedInterfaceOrientations` and `UISupportedInterfaceOrientations~ipad` | all four orientations |
| `UIApplicationSceneManifest` | `UIApplicationSupportsMultipleScenes = false` |

Don't add capability or entitlement keys. Entitlements belong to packaging (section 10).

### App shell

`App/EikonApp.swift`: an `@main struct EikonApp: App` with one `WindowGroup` showing `StatusView()`. Section 07 later adds `JITController.shared` ownership and scene-phase handling. Don't add stand-ins for them now.

`App/StatusView.swift`: a placeholder that section 09 replaces. A `NavigationView` with a `List` showing rows read from `Bundle.main.infoDictionary`:

- version and build (`CFBundleShortVersionString`, `CFBundleVersion`)
- `EKGitCommit`
- `EKPackageKind`
- the runtime bundle id (`Bundle.main.bundleIdentifier`). Never assume the literal `com.getboolean.eikon` at run time, because AltStore free accounts may rewrite it.

This lets anyone check by eye that the version stamps flow through. Use `NavigationView` (iOS 15). Missing keys show a dash, not a crash. Plain SwiftUI string literals are fine here; `Localizable.strings` arrives in section 09.

### App icon

`App/Assets.xcassets/AppIcon.appiconset` uses the single-size universal format: one 1024×1024 PNG, **opaque (no alpha channel)**, and a `Contents.json` naming it for the `universal`/`ios` idiom. `actool` derives the other sizes.

The artwork must be **original**: no third-party logos, fonts with restrictive licenses, or copied imagery. A simple geometric design is enough, for example a light abstract mark on a solid dark background. Draw it with a one-off script or a vector editor. Commit only the PNG and `Contents.json`, not the drawing script. Check that the PNG has no alpha channel (for example with `sips -g hasAlpha`), because an alpha channel causes install-time icon problems on some installers.

### `scripts/test_swift.sh`

Invoked by `make test-swift`. Uses `set -euo pipefail` and calls every Apple tool through `xcrun`.

1. **Pick the simulator.**
   - If `EIKON_SIM_DESTINATION` is set, use it as the `-destination` value.
   - Otherwise read `xcrun simctl list devices available --json` and choose an available **iPhone** device on the **newest iOS runtime**.
     - Compare runtime versions numerically, not as strings.
     - Parse the JSON with a short standard-library Python snippet run through `uv run python`, not the system Python.
   - Use the destination `platform=iOS Simulator,id=<udid>`.
   - If no iPhone simulator is available, exit non-zero with a message saying to install an iOS simulator runtime in Xcode.
2. **Test.** `xcrun xcodebuild test -project Eikon.xcodeproj -scheme Eikon -destination … -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO`. Disabling signing keeps simulator builds and CI identity-free.
3. **Launch check.**
   - Boot the chosen device if it isn't booted (`xcrun simctl boot`, tolerating "already booted").
   - Install `build/DerivedData/Build/Products/Debug-iphonesimulator/Eikon.app` with `xcrun simctl install`.
   - Read the bundle id from the built app's Info.plist with `/usr/libexec/PlistBuddy` rather than hard-coding it.
   - `xcrun simctl launch` it. Wait a few seconds, then confirm the process is still running, for example with `xcrun simctl spawn <udid> launchctl list` filtered on the bundle id.
   - Terminate the app. A launch failure or an immediate exit fails the script.

   Steps 2 and 3 together satisfy "builds and launches in the simulator".
4. Print the destination used and a one-line pass summary.

### Makefile changes

- **`project`:** `version`, then `xcodegen generate` at the repo root. Section 04 later inserts `generated` (acknowledgements JSON) before `xcodegen`. Don't add a stub for it here.
- **`test-swift`:** depends on `project`, then runs `scripts/test_swift.sh`. Remove section 01's "skip while `project.yml` doesn't exist" guard.
- `test` (= `test-swift` + `test-scripts`) and `clean` (removes `build/` and `dist/`) need no change. `build/DerivedData` lives under `build/`, so `make clean` covers it.

### README additions

Add a **Building** subsection:

- `make doctor` checks the toolchain. `make bootstrap` installs missing tools, and runs only when the owner chooses.
- `make project` generates `Eikon.xcodeproj`. It is never committed: edit `project.yml` and the xcconfigs, then regenerate.
- `make test-swift` runs the Swift tests and a launch check on the newest iPhone simulator. `EIKON_SIM_DESTINATION` overrides the choice.
- For device debug runs, create `Config/Local.xcconfig` (untracked) with `DEVELOPMENT_TEAM = <your team id>`.

Add a **Debug loop** subsection, which later JIT sections rely on:

- Running Eikon from Xcode on the iPad with the debugger attached makes the kernel set `CS_DEBUGGED`. That exercises the real JIT probe without TrollStore.
- The probe deliberately triggers guarded signals, and lldb stops on them by default. To let the probe's own handler deal with them, run `process handle SIGBUS SIGSEGV SIGILL SIGTRAP -s false -n false` in lldb, or put that line in a `.lldbinit`.

### `.github/workflows/ci.yml` (minimal)

Triggers: `push` and `pull_request` (owner decision). Both jobs skip pull requests whose head branch is in this repo, because the push already tested them, so only fork PRs run on `pull_request`. A `concurrency` group per pull request or ref cancels superseded runs. Top-level `permissions: contents: read`. This workflow never publishes or writes anything.

Pin **every action by full commit SHA**, with the version tag in a trailing comment (for example `actions/checkout@<sha> # v4.x.y`). Resolve each SHA at implementation time from the action's latest release tag (for example `gh api repos/actions/checkout/git/ref/tags/<tag>`, dereferencing annotated tags to the commit).

Every checkout uses `fetch-depth: 0`, because `version.sh` counts commits and fails on a shallow clone.

**Job `scripts`** (`runs-on: ubuntu-latest`):
1. Checkout.
2. Set up uv (`astral-sh/setup-uv`, SHA-pinned).
3. `uv run pytest tests/`.
4. `scripts/version.sh --check`.

Section 04 adds `uv run scripts/credits.py check` here.

**Job `build`** (`runs-on: macos-latest`, `timeout-minutes: 45`):
1. Checkout.
2. Select the newest installed Xcode: find the `/Applications/Xcode*.app` bundles, pick the highest version, and write `DEVELOPER_DIR=<app>/Contents/Developer` to `$GITHUB_ENV`. Print `xcodebuild -version` for the log. The runner's Xcode may lag Xcode 27, which is fine: iOS 15 is a valid target for Xcode 16 and later.
3. `brew install xcodegen uv`. Section 10 adds `ldid-procursus` and `dpkg`.
4. `make test-swift`.

Section 10 extends this job with `archive package verify` and uploads `dist/`.

Committing the workflow is fine. **Pushing it** to GitHub, and so running it for the first time, needs owner approval. After the first run, check both jobs are green and the log names the simulator used.

## Done when

- A clean clone, after `make doctor` passes, runs `make project` and then `make test-swift` successfully. The smoke test passes and the app launches and stays running on the newest iPhone simulator.
- In the launched app the placeholder screen shows the version from `VERSION`, a numeric build, the short commit (with `-dirty` when the tree is dirty), `development` as the package kind, and the runtime bundle id.
- Opening `Eikon.xcodeproj` in Xcode before `make version` has ever run still builds, using the fallback values.
- The repo has no `.xcodeproj`, no build-phase scripts, no `PrivacyInfo.xcprivacy` and no entitlements file for the app target.
- `ci.yml` has SHA-pinned actions, read-only permissions and `fetch-depth: 0`. Once the owner approves the push, both jobs pass.

---

## Implementation notes (as built)

All files in the table were created as planned. `make test-swift` passes locally: the smoke test runs, and the app launches and stays running on the newest iPhone simulator (iOS 27.0 at the time). The placeholder screen shows the version, build, commit, `development` and the bundle id. A build without `build/generated/` uses the fallback values.

Deviations, and choices the plan left open:

- **`project.yml`:**
  - `options.settingPresets: project`, with the same xcconfigs as target-level `configFiles`. XcodeGen's target presets would otherwise write settings into the target that override the xcconfigs. The generated target sets only `INFOPLIST_FILE`.
  - `Base.xcconfig` restates `LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks`, which the target preset used to supply. Section 10 should confirm the archive needs nothing else from the presets, such as `CODE_SIGN_IDENTITY`.
  - The scheme's test list uses XcodeGen's `targets:` key.
- **`scripts/test_swift.sh`:**
  - The launch check requires a `UIKitApplication:<bundle id>[…` launchd job with a numeric PID. It captures the `launchctl list` output before matching, so `pipefail` can't cause a false failure.
  - `EIKON_SIM_DESTINATION` must contain `id=<udid>` of a simulator that simctl knows. The launch check is never skipped.
  - Only the "already booted" error from `simctl boot` is tolerated.
- **`scripts/bootstrap.sh`** (owner decisions): runs `brew update`, installs the missing formulas, and runs `brew upgrade` on the Eikon formulas Homebrew already manages. `ldid-procursus` is judged by its formula only. The upgrade path has not been exercised yet; the install path ran once.
- **CI:** actions are pinned to `actions/checkout` v7.0.1 and `astral-sh/setup-uv` v10.2.0. The workflow is committed but **not pushed**; pushing it needs owner approval.

The review trail is in `../implementation/code_review/section-02-*.md`.

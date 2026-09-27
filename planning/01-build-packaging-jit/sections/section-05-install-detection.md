# Section 05: Install-method detection

## Purpose

Eikon ships one app binary in three packages: a Dopamine rootless deb (installed at `/var/jb/Applications/Eikon.app`), `Eikon.tipa` for TrollStore, and `Eikon.ipa` for AltStore. It picks JIT behaviour at run time, so it has to work out how it was installed. This section adds to the `EikonKit` Swift package:

- `InstallMethod`: the detected install method.
- `InstallEvidence`: the redacted facts behind that answer, which later go into device reports.
- `BundleEnvironment`: a filesystem seam, so detection can be tested against fake layouts, plus its live implementation.
- `detectInstallMethod(_:)`: the detection rules.
- Helpers that read the package kind (the `EKPackageKind` Info.plist stamp) and the bundle id at run time.

The code has no UI and makes no JIT decisions. Section 06 (JIT policy) reads `InstallMethod`, section 07 (JIT controller) calls detection once at launch, and section 08 (device report) encodes `InstallEvidence`, the package kind and the bundle id.

## Dependencies

- **Requires section 02 (Xcode project).** The local package `Packages/EikonKit` must already exist with its Swift target `EikonKit` and its Swift Testing target `EikonKitTests`, wired into the `Eikon` scheme's test action. `make test-swift` must run the tests on the simulator. The `App/Info.plist` must already have the `EKPackageKind` key, set to `development`; the packager (section 10) overwrites it with `deb`, `tipa` or `ipa`.
- **Blocks sections 06 and 08.**
- Can be done in parallel with section 04.

If section 02 left a trivial placeholder smoke test in `EikonKitTests` (only there so the test target had a source file), delete it once the tests below exist.

## Background: what each install method leaves behind

- **TrollStore** writes a marker file named `_TrollStore` into the bundle's container directory, next to the `.app`: `Bundle.main.bundleURL/../_TrollStore`. **TrollStore Lite** writes `_TrollStoreLite` in the same place.
- **Dopamine 2.1+ and 3.x** install jailbreak apps under the jailbreak root's `Applications` directory. `/var/jb` is a symlink, so the resolved bundle path looks like `/private/preboot/<hash>/dopamine-XXXXXX/procursus/Applications/Eikon.app`. The `<hash>` is device-unique and `XXXXXX` is a random per-install suffix.
- **Other rootless jailbreaks** (palera1n, nathanlr) also use `/var/jb`, so a `/var/jb` path alone does not mean Dopamine. Dopamine leaves two markers: the file `/var/jb/.installed_dopamine`, and a `basebin` directory under its jailbreak root.
- **Sideloaded installs** (AltStore, or an Xcode-signed build) carry `embedded.mobileprovision` inside the bundle. AltStore free accounts may also rewrite the bundle id, so the app must never assume `com.getboolean.eikon` at run time.
- **App Store-style containers** put bundles under `/private/var/containers/Bundle/Application/<UUID>/`. Data containers (the home directory) are under `/private/var/mobile/Containers/Data/Application/<UUID>/`. Both UUIDs are device-unique.
- The report shows **both** the package kind stamped at packaging time and the detected method. For example, a `.tipa` installed on a Dopamine device detects as `trollStore` but stamps `tipa`, and a development build run from Xcode stamps `development`. A mismatch is useful information, not an error.

## Tests first

Write these in `Packages/EikonKit/Tests/EikonKitTests/InstallDetectionTests.swift` with Swift Testing (`import Testing`, `@Test`, `#expect`). They run on the simulator through `make test-swift`.

**Owner's rule:** keep tests few and behavioral. Don't assert exact evidence strings, placeholder spellings, the order of markers, or any constant. Don't use program or game titles in test names, paths or fixtures.

### Fixture: a fake `BundleEnvironment`

Put a small test-only type in the test target, for example `FakeBundleEnvironment`:

- It is initialised with a bundle URL, a home directory URL, `isSimulator` (default `false`), a set of absolute paths that "exist", and an optional map of symlink prefixes. The map lets `/var/jb` resolve to a `/private/preboot/<hash>/dopamine-<suffix>/procursus` path.
- `fileExists` checks membership in the set, after normalising `..` components (use `URL.standardizedFileURL.path`).
- `resolvingSymlinks` rewrites a matching prefix and otherwise returns the URL unchanged.

Use realistic but made-up identifiers in the fixtures: a long hex preboot hash, a six-character Dopamine suffix, and `UUID().uuidString` for container UUIDs. Keep them in local variables, so the redaction test can search for them.

### Tests

1. **TrollStore markers.** A bundle at `/private/var/containers/Bundle/Application/<uuid>/Eikon.app` with `_TrollStore` in the container directory detects as `.trollStore`. The same layout with `_TrollStoreLite` instead detects as `.trollStoreLite`.
2. **Jailbreak layouts.** A bundle whose resolved path is `/private/preboot/<hash>/dopamine-<suffix>/procursus/Applications/Eikon.app` detects as `.dopamine` when a Dopamine marker exists (`/var/jb/.installed_dopamine`, or `basebin` under the jailbreak root). The same path with neither marker detects as `.rootlessJailbreak`.
3. **Fallbacks.** A container bundle with `Eikon.app/embedded.mobileprovision` and no other markers detects as `.sideloaded`. A container bundle with nothing matching detects as `.unknown`.
4. **Redaction.** For the Dopamine layout and for a container layout, the encoded `InstallEvidence` (JSON-encode it and search the resulting string, so every field is covered) does **not** contain the preboot hash, the Dopamine suffix, the bundle container UUID or the data container UUID used in the input. Check this by searching for those input values. Don't compare against a fixed expected string.

Parameterised `@Test(arguments:)` is fine for tests 1 and 3. That makes four test functions or fewer. Don't add tests for the simulator rule, the live environment, the package kind or the bundle id: the simulator rule is a one-line compile-time branch, and the rest are thin reads of `Bundle.main`.

## Implementation

All files go in `Packages/EikonKit/Sources/EikonKit/`. The app target imports these types, so make them `public`, with public memberwise initialisers where the tests or other sections need to build values. The package uses Swift 6 language mode with complete strict concurrency, so every type here must be `Sendable`.

**iOS 15 floor:** don't use Swift `Regex` or regex literals (they need iOS 16). Use path-component matching (preferred) or `NSRegularExpression`.

### `InstallMethod.swift`

```swift
public enum InstallMethod: String, Codable, Sendable, CaseIterable {
    case dopamine, rootlessJailbreak, trollStore, trollStoreLite, sideloaded, simulator, unknown
}

public struct InstallEvidence: Codable, Sendable, Equatable {
    public var bundlePath: String     // resolved bundle path, redacted to structure
    public var homeDirectory: String  // NSHomeDirectory(), redacted; shows where unsandboxed data lands
    public var markers: [String]      // marker names found, e.g. "_TrollStore", ".installed_dopamine",
                                      // "basebin", "embedded.mobileprovision"
}
```

- The raw values are the wire format of the device report (section 08) and the key for the status screen's wording (section 09). Keep the case names as listed.
- `markers` holds marker **names**, not full paths, so no identifiers leak through it. List every marker that was checked and found, including ones that did not decide the result. For example, a sideloaded bundle that is also inside a jailbreak path shows both.

### `BundleEnvironment.swift`

```swift
public protocol BundleEnvironment: Sendable {
    /// Filesystem seam so detection is testable against a fake layout.
    var bundleURL: URL { get }
    var homeDirectory: URL { get }
    var isSimulator: Bool { get }
    func fileExists(_ path: String) -> Bool
    func resolvingSymlinks(_ url: URL) -> URL
}

public struct LiveBundleEnvironment: BundleEnvironment { /* ... */ }

extension BundleEnvironment where Self == LiveBundleEnvironment {
    public static var live: LiveBundleEnvironment { get }
}
```

`LiveBundleEnvironment`:

- `bundleURL` is `Bundle.main.bundleURL`. `homeDirectory` is `URL(fileURLWithPath: NSHomeDirectory())`.
- `isSimulator` comes from `#if targetEnvironment(simulator)`.
- `fileExists` uses `FileManager.default.fileExists(atPath:)`. It returns true for directories too, which the `basebin` check relies on.
- `resolvingSymlinks` calls `realpath(3)` on the path and builds a file URL from the result, falling back to the input URL if the call fails. Don't use Foundation's `resolvingSymlinksInPath()`: it strips a leading `/private` and does not reliably expand `/var/jb`, which would hide the preboot path the rules match on.
- Its stored properties are all value types, so it is `Sendable` without `@unchecked`.

### `InstallDetection.swift`

```swift
/// Detects how this app was installed. Pure apart from the environment's filesystem queries.
public func detectInstallMethod(_ env: BundleEnvironment) -> (InstallMethod, InstallEvidence)
```

Rules, first match wins:

1. `env.isSimulator` → `.simulator`.
2. `bundleURL/../_TrollStore` exists → `.trollStore`. Otherwise, if `bundleURL/../_TrollStoreLite` exists → `.trollStoreLite`. Build the container path with `deletingLastPathComponent()` rather than a literal `..`.
3. The **resolved** bundle path (`env.resolvingSymlinks(env.bundleURL).path`) is under a jailbreak `Applications` directory. That is when either of these holds:
   - it contains `/procursus/Applications/`. The jailbreak root is then everything up to and including `/procursus`.
   - it starts with `/var/jb/Applications/` or `/private/var/jb/Applications/`. The jailbreak root is then `/var/jb` or `/private/var/jb`.

   Within this rule:
   - `.dopamine` if `/var/jb/.installed_dopamine` exists, or `<jailbreak root>/basebin` exists.
   - `.rootlessJailbreak` otherwise.
4. `bundleURL/embedded.mobileprovision` exists → `.sideloaded`.
5. Otherwise → `.unknown`.

The TrollStore rule comes before the jailbreak rule because TrollStore installs live in normal bundle containers and carry the most specific marker. The provisioning-profile rule comes after the jailbreak rule because an Xcode-signed build copied into a jailbreak path would still carry a profile.

For the evidence, check all the markers listed above (even after a rule has matched, so the evidence is complete) and record the names that exist. Redact the resolved bundle path and the home directory as described next.

### Redaction (`redactPath(_:)`)

The goal is that a report shows only the **structure** of a path, never device-unique identifiers. Work on path components (split on `/`, rewrite, rejoin) rather than on the whole string:

- The component right after `preboot` → `<hash>`.
- A component starting with `dopamine-` → `dopamine-<id>`.
- Any component that parses as a UUID (`UUID(uuidString:)` succeeds) → `<uuid>`. This covers bundle and data container UUIDs, and simulator device and container UUIDs.
- On the simulator, the host path includes the Mac's `/Users/<name>/`. Replace the component after a leading `Users` with `<user>`.

Everything else stays as it is, so later readers can still tell a `procursus/Applications` path from a container path. The placeholder spellings are not a contract. Section 08 only needs the identifiers gone.

### `AppIdentity.swift`: package kind and bundle id

```swift
public struct AppIdentity: Codable, Sendable, Equatable {
    public var packageKind: String        // Info.plist EKPackageKind: development, deb, tipa or ipa
    public var bundleIdentifier: String   // taken at run time; never assumed

    /// Reads both from a bundle; defaults to Bundle.main.
    public static func current(bundle: Bundle = .main) -> AppIdentity
}
```

- `packageKind` is `bundle.object(forInfoDictionaryKey: "EKPackageKind") as? String`. If the key is missing, it falls back to `"unknown"`. Don't validate it against the detected method.
- `bundleIdentifier` is `bundle.bundleIdentifier`, falling back to an empty string if it is nil. Section 07 builds the TrollStore enable-JIT URL from this value and section 08 reports it. Neither may hard-code `com.getboolean.eikon`, because AltStore free accounts rewrite the bundle id.
- `Bundle` is not `Sendable`, so `current(bundle:)` reads the values and returns only the plain struct.

## Integration notes for later sections (don't implement here)

- Section 07's `JITController.gatherFacts()` calls `detectInstallMethod(.live)` once at launch and publishes both the method and the evidence.
- Section 06's `JITFacts.installMethod` and the reason codes (`dopamineJITOff`, `rootlessJailbreakNoJIT`, `sideloadedNoJIT`, `unknownInstallNoJIT`, `simulator`) map from these cases.
- Section 08's `InstallInfo` holds `method` and `evidence`, and `AppInfo` includes `packageKind` and `bundleIdentifier`.

## Done when

- The four tests above pass under `make test-swift` on the simulator.
- `detectInstallMethod(.live)` returns `.simulator` in a simulator run, with redacted evidence (no simulator UUIDs or Mac user name).
- No Swift `Regex`, no hard-coded bundle id at run time, and no program titles anywhere in the code or tests.

---

## Implementation notes (as built)

Files in `Packages/EikonKit/Sources/EikonKit/`: `InstallMethod.swift` (with `InstallEvidence`), `BundleEnvironment.swift`, `InstallDetection.swift` (with `redactPath`) and `AppIdentity.swift`. Tests are in `Tests/EikonKitTests/InstallDetectionTests.swift`: four test functions, seven cases in total. The section-02 smoke test was deleted.

Differences from the plan, most from the code review:

- `detectInstallMethod(_: some BundleEnvironment)` is generic rather than existential. `detectInstallMethod(.live)` compiles and, in a simulator run, returns `.simulator` with the Mac user name redacted.
- **Jailbreak rule:** it checks the resolved path first, then the unresolved bundle path, so a `/var/jb` that resolves outside a `procursus` directory still counts. `basebin` is looked up under the resolved root when there is one.
- **Redaction** covers more than the plan listed:
  - the component directly under the preboot hash, whatever its prefix (`dopamine-XXXXXX`, palera1n's `jb-XXXXXXXX`, …), becomes `<prefix>-<id>`
  - `.jbroot-<hex>` (RootHide)
  - the two components after `var/folders` (a Mac running the iPad app)
  - UUIDs, the preboot hash and `/Users/<name>`, as planned
- **Tests:** the argument rows also pin the rule order: a TrollStore marker plus a profile is still `.trollStore`, and a jailbreak path plus a profile is still a jailbreak. The redaction test also covers a non-Dopamine rootless layout. A deliberate break of UUID redaction was confirmed to fail the redaction test.
- **Note for sections 06 and 09:** rootful installs (`/Applications/Eikon.app`) and RootHide installs detect as `.unknown` (or `.sideloaded` with a profile). That is as planned, but the wording should allow for it.
- `.gitignore` now also ignores `.build/` and `.swiftpm/`, the editor's SwiftPM index state.

The review trail is in `../implementation/code_review/section-05-*.md`.

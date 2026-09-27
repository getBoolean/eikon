# Section 08: Device report

## What this section delivers

Eikon has to prove on real devices what it detected and whether JIT is usable. It does that with a **device report**: one JSON document that the app builds, that the owner copies or shares off the device, and that a script validates and files into the repo under `device-reports/`.

This section adds:

1. **Model (EikonKit):** `DeviceReport` and its supporting types, device info read through `sysctl`, a chip display-name table, and available memory.
2. **Schema and filer (repo scripts):** `device-reports/schema.json` (JSON Schema, draft 2020-12) and `scripts/file_device_report.py`, which validates a report and writes it under a deterministic name.
3. **Export helpers (app):** `App/ReportExport.swift`, with copy to pasteboard, a temporary `.json` file for sharing, and a `UIActivityViewController` bridge for SwiftUI.
4. **One shared fixture,** `tests/fixtures/device-report.json`. pytest checks it against the schema and the filer, and a Swift test decodes and re-encodes it. That makes it the single contract between the Swift model and the schema.

The status screen buttons that call the export helpers are **not** part of this section. Section 09 adds them.

## Dependencies

- **Section 05 (install detection)** provides `InstallMethod` (a `String` raw-value enum: `dopamine`, `rootlessJailbreak`, `trollStore`, `trollStoreLite`, `sideloaded`, `simulator`, `unknown`) and `InstallEvidence` (`bundlePath`, `homeDirectory`, `markers: [String]`). The evidence is already redacted: preboot hashes, jailbreak id suffixes and container UUIDs are replaced by `<hash>`, `<id>` and `<uuid>`. This section embeds both as they are and adds no redaction of its own. Section 05 also provides the package kind, read from the Info.plist key `EKPackageKind`.
- **Section 06 (JIT core)** provides `JITStatus`, which is `Codable`, `Sendable` and `Equatable`. Its fields are `csDebugged`, `csDebuggedSeen`, `txm` (`state`, `enforced`, `basis`), `probe` (`kind`, optional `detail`), `source`, and an optional `reason` that is nil exactly when usable. It also has a computed `usable` that is **encoded but ignored on decode**. The report embeds `JITStatus` under the key `jit` without changing it. If section 06's `JITStatus` does not yet encode `usable`, that is a section 06 bug; don't work around it here.
- **Section 01** provides the pytest setup (`pyproject.toml`, `tests/`, and `make test-scripts` running `uv run pytest tests/`).
- **Section 02** provides the `EikonKit` package, its Swift Testing target `EikonKitTests` (run by `make test-swift` on the simulator), and the `App/` target.
- **Section 07** runs in parallel with this one. It may add a `sysctl` helper for `hw.cpufamily`, which the TXM heuristic needs. If one already exists when you get here, reuse it rather than adding a second. Otherwise add the helper described below, and section 07 can use it.

## Rules that apply here

- **Privacy.** A report never contains the user-assigned device name, the UDID, the serial number, or anything about games or other programs. No program titles appear anywhere: not in code, the fixture, test names or notes.
- **Tests stay few and behavioral** (owner's rule). They must not pin file contents, constant values, string texts, the chip table, or internal structure. The fixture is test *input*. No test compares output against a literal copy of it.
- **iOS 15 floor.** No `ShareLink` (iOS 16). Use a `UIViewControllerRepresentable` around `UIActivityViewController`. No `NavigationStack` or Observation.
- **Scripts:** Python 3.12 through `uv run`, standard library only. No `jsonschema` package.

---

## Tests first

Write these before the implementation. There are four behaviors in total: two Swift and two pytest groups.

### Shared fixture: `tests/fixtures/device-report.json`

This is a valid schema-version-1 report, hand-written to match what `DeviceReport` encodes. Constraints:

- It uses only neutral, non-identifying values. The model identifier and chip are real, since they aren't device-unique. The evidence paths use the redaction placeholders. `notes` holds a neutral sentence. Nothing names a program.
- **Keys for nil optionals are omitted, not written as `null`.** Swift's synthesized `Codable` leaves nil optionals out. A `null` in the fixture would decode fine but disappear on re-encode, and the key-set test would fail for the wrong reason. So either give an optional a value or leave its key out.
- `gates` holds **one** neutral entry (for example `"fixtureGate"`), so that the schema's `GateResult` shape and the Swift decode of `gates` are both exercised.
- `generatedAt` is a whole-second UTC timestamp, for example `2026-01-15T10:20:30Z`.

Illustrative shape (the key set is what matters; the values are examples):

```json
{
  "app": { "build": "12", "bundleIdentifier": "com.getboolean.eikon", "commit": "0123abc", "packageKind": "tipa", "version": "0.1.0" },
  "device": { "chip": "M2", "cpuFamily": "0xda33d83d", "modelIdentifier": "iPad14,5" },
  "gates": { "fixtureGate": { "detail": "fixture entry", "measuredAt": "2026-01-15T10:20:30Z", "passed": true } },
  "generatedAt": "2026-01-15T10:20:30Z",
  "install": { "evidence": { "bundlePath": "/private/var/containers/Bundle/Application/<uuid>/Eikon.app", "homeDirectory": "/var/mobile/Containers/Data/Application/<uuid>", "markers": ["_TrollStore"] }, "method": "trollStore" },
  "jit": { "csDebugged": true, "csDebuggedSeen": "afterTrollStoreRequest", "probe": { "kind": "passed" }, "source": "trollStore", "txm": { "basis": "os below 26", "enforced": false, "state": "absent" }, "usable": true },
  "memory": { "availableBytes": 5368709120 },
  "notes": "Fixture report used by the test suites.",
  "os": { "build": "21A329", "name": "iPadOS", "version": "17.0" },
  "schemaVersion": 1
}
```

Check the exact `JITStatus` key names against section 06's type when writing the fixture. The fixture has to decode into the real type.

### Swift Testing: `Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift`

1. **Round trip and privacy guard.**
   - Build a report with `DeviceReport.make(...)`, using a fake `DeviceSystem`, an `AppInfo`, a `JITStatus`, an install method with evidence, and a fixed `now` truncated to whole seconds. ISO-8601 encoding drops fractional seconds, so an untruncated date would not round-trip.
   - Encode it with `DeviceReport.encode()`, decode it with `DeviceReport.decode(_:)`, and expect a value equal to the original.
   - Privacy: on the simulator, read the host-supplied names `UIDevice.current.name` (from the main actor) and `ProcessInfo.processInfo.hostName`. For each non-empty one, expect that no key or string value anywhere in the encoded JSON equals it. Walk the decoded `JSONSerialization` tree, don't substring-search, because a short name could occur inside an unrelated value by chance.
   - Also build one report from `LiveDeviceSystem` and apply the same check. That covers the real `sysctl` path, which can only go wrong by picking up a name.
2. **Fixture contract.**
   - Load `tests/fixtures/device-report.json` from the repo, decode it with `DeviceReport.decode(_:)` (the decode must succeed), and re-encode it.
   - Compare **key sets only**, as sets of strings. The re-encoded top-level key set must equal the fixture's top-level key set, and the same for the `jit` object's key set.
   - Don't compare values or nested structure beyond those two levels.
   - How to locate the fixture: the tests run only on the simulator, which reads the Mac's filesystem. So resolve the fixture from the test file's own location: `URL(fileURLWithPath: #filePath)`, walk up to the repo root, then `tests/fixtures/device-report.json`. That keeps **one** copy of the fixture, with no copy in the package and no resource symlink. Put the path resolution in a small helper in the test file. If the file is missing, fail with a message naming the path.

Drift in either direction fails a test. If Swift adds or renames a field, test 2 fails on the key sets. If the schema changes, the pytest schema test on the same fixture fails.

### pytest: `tests/test_file_device_report.py`

Run the filer as a subprocess (`sys.executable scripts/file_device_report.py ...`) from the repo root, with `--out-dir` pointed at `tmp_path`. Load the fixture with `json`, and derive expectations such as the date **from the fixture**, never from literals.

1. **Fixture validates against the schema.** `--check <fixture>` exits 0 and writes nothing.
2. **Filing a valid report.**
   - Filing the fixture exits 0 and creates exactly one `.json` file in the out dir.
   - Its name starts with the `YYYY-MM-DD` date taken from the fixture's `generatedAt` (compute it in the test with `datetime`), and the script prints that path.
   - The filed file parses back to the same JSON object as the fixture.
   - Running the filer again with the same report exits 0, and the out dir still holds exactly one file.
   - Filing from stdin (`-`) produces the same single file (same name). This can go in the same test.
3. **Rejections (one parametrized test).** For each of these, the filer exits non-zero and the out dir stays empty:
   - a required top-level field removed (take any name from the schema's top-level `required` list, loaded from `device-reports/schema.json`)
   - an unknown top-level key added (a name that can't be in the schema)
   - `schemaVersion` set to an unknown value (the fixture's version plus a large offset)

Don't assert error message texts. Asserting the exit status and that nothing was written is enough.

---

## Implementation

### Files

| Path | What |
|---|---|
| `Packages/EikonKit/Sources/EikonKit/DeviceReport.swift` | `DeviceReport`, supporting types, `make`, encode and decode |
| `Packages/EikonKit/Sources/EikonKit/DeviceSystem.swift` | `DeviceSystem` seam, `LiveDeviceSystem`, `sysctl` helpers |
| `Packages/EikonKit/Sources/EikonKit/ChipNames.swift` | chip display-name table |
| `Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift` | the two Swift tests |
| `App/ReportExport.swift` | copy, temporary file, `ActivityView` bridge |
| `device-reports/schema.json` | JSON Schema (draft 2020-12) |
| `scripts/file_device_report.py` | validator and filer |
| `tests/fixtures/device-report.json` | shared fixture |
| `tests/test_file_device_report.py` | pytest tests |

`device-reports/README.md` (the runbook) belongs to section 12. Don't create it here.

### Model: `DeviceReport.swift`

```swift
public struct DeviceReport: Codable, Sendable, Equatable {
    public var schemaVersion: Int                 // 1
    public var generatedAt: Date                  // ISO-8601 UTC, whole seconds
    public var app: AppInfo
    public var device: DeviceInfo
    public var os: OSInfo
    public var install: InstallInfo
    public var jit: JITStatus
    public var memory: MemoryInfo
    public var gates: [String: GateResult]        // empty in split 01; later splits add entries
    public var notes: String?                     // free text the owner may add before filing

    public static let currentSchemaVersion = 1

    /// Assembles a report from already-gathered facts. Reads nothing global except through `system`.
    public static func make(app: AppInfo, installMethod: InstallMethod, evidence: InstallEvidence,
                            jit: JITStatus, system: DeviceSystem, now: Date) -> DeviceReport

    /// Sorted keys, pretty-printed, ISO-8601 dates.
    public func encode() throws -> Data
    public static func decode(_ data: Data) throws -> DeviceReport
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var version: String            // CFBundleShortVersionString
    public var build: String              // CFBundleVersion
    public var commit: String             // EKGitCommit
    public var packageKind: String        // EKPackageKind: development / deb / tipa / ipa
    public var bundleIdentifier: String   // Bundle.main.bundleIdentifier at run time
    /// Reads the keys above from `bundle`'s Info.plist; a missing key becomes "unknown".
    public static func from(_ bundle: Bundle) -> AppInfo
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var modelIdentifier: String    // hw.machine, e.g. "iPhone14,4"
    public var chip: String               // display name from ChipNames, or "unknown"
    public var cpuFamily: String          // hw.cpufamily as lowercase hex, "0x…"
}

public struct OSInfo: Codable, Sendable, Equatable {
    public var name: String               // "iOS" / "iPadOS"
    public var version: String            // "17.0", "15.4.1"
    public var build: String              // kern.osversion
}

public struct InstallInfo: Codable, Sendable, Equatable {
    public var method: InstallMethod
    public var evidence: InstallEvidence  // already redacted by section 05
}

public struct MemoryInfo: Codable, Sendable, Equatable {
    public var availableBytes: UInt64     // os_proc_available_memory() at report time
}

public struct GateResult: Codable, Sendable, Equatable {
    public var passed: Bool?
    public var detail: String
    public var measuredAt: Date
}
```

Notes:

- `Equatable` is needed for the round-trip test. If section 05's `InstallEvidence` isn't `Equatable` yet, add the conformance there (it's a one-word change), since it's a plain value type.
- **Encoding.** Use a `JSONEncoder` with `outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]` and `dateEncodingStrategy = .iso8601`. The decoder uses `.iso8601`. `withoutEscapingSlashes` keeps the evidence paths readable.
- `make` sets `generatedAt` to `now` truncated to whole seconds, `gates` to `[:]` and `notes` to nil. `schemaVersion` is `currentSchemaVersion`.
- **Never included.** There is no field for a device name, UDID or serial, and the `DeviceSystem` seam does not expose any of them, so the report can't pick one up by accident.
- **Evolution.** New measurements go into `gates` under a new key. Adding or renaming a **top-level** field bumps `schemaVersion`, and the filer and schema then need to accept the new version. Record that rule as a doc comment on `DeviceReport`.

### Device info: `DeviceSystem.swift`

```swift
/// Seam over sysctl and ProcessInfo so the report is testable without a device.
public protocol DeviceSystem: Sendable {
    var modelIdentifier: String { get }
    var cpuFamily: UInt32 { get }
    var osName: String { get }
    var osVersion: String { get }
    var osBuild: String { get }
    func availableMemoryBytes() -> UInt64
}

/// Values captured once; osName needs UIDevice, so construction is main-actor.
public struct LiveDeviceSystem: DeviceSystem {
    @MainActor public static func current() -> LiveDeviceSystem
}

func sysctlString(_ name: String) -> String?     // sysctlbyname, two-call size pattern
func sysctlUInt32(_ name: String) -> UInt32?
```

- `modelIdentifier`: `sysctlString("hw.machine")`. In simulator builds (`#if targetEnvironment(simulator)`), `hw.machine` returns the Mac's architecture, so use the `SIMULATOR_MODEL_IDENTIFIER` environment variable instead. If neither gives a value, use `"unknown"`.
- `cpuFamily`: `sysctlUInt32("hw.cpufamily")`, or 0 if it's unavailable. It's formatted into `DeviceInfo.cpuFamily` as `String(format: "0x%08x", …)`. TXM logic in sections 06 and 07 uses this raw number, never the chip display name.
- `osName`: `UIDevice.current.systemName` (main actor, hence `current()`).
- `osVersion`: from `ProcessInfo.processInfo.operatingSystemVersion`, as `major.minor`, plus `.patch` when the patch is non-zero.
- `osBuild`: `sysctlString("kern.osversion")`, or `"unknown"`.
- `availableMemoryBytes()`: `os_proc_available_memory()` from `<os/proc.h>` (import `os`), as `UInt64`. It returns 0 in the simulator and in processes without a memory limit. Report 0 as it is, because device reports use this value as evidence of whether the memory entitlements took effect.

### Chip names: `ChipNames.swift`

```swift
public enum ChipNames {
    /// Display-only; falls back to "unknown". Never used for TXM or policy decisions.
    public static func displayName(forModel identifier: String) -> String
}
```

- A Swift literal `[String: String]` from model identifier to chip marketing name.
- Cover the iPhone and iPad models that run iOS 15 or later on A12 and newer chips, and M-series iPads.
- It must include the two test devices: `iPhone14,4` → `A15` (iPhone 13 mini), and `iPad14,5` / `iPad14,6` → `M2` (iPad Pro 12.9" 6th gen).
- A missing entry just shows `"unknown"`, and device reports correct the table. No test covers the table's contents.

### Export: `App/ReportExport.swift`

This lives in the app target (UIKit and SwiftUI). All of it is `@MainActor`.

```swift
@MainActor
enum ReportExport {
    /// Encodes the report and puts the JSON text on UIPasteboard.general.
    static func copy(_ report: DeviceReport) throws

    /// Writes the encoded report to FileManager.default.temporaryDirectory as
    /// "eikon-report-<yyyy-MM-dd>-<modelIdentifier>-<install.method>.json" (UTC date from
    /// generatedAt; any character outside [A-Za-z0-9,._-] in the parts replaced by "_"),
    /// overwriting a previous file of the same name, and returns its URL.
    static func temporaryFile(for report: DeviceReport) throws -> URL
}

/// SwiftUI bridge for UIActivityViewController (ShareLink needs iOS 16).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)? = nil   // wired to completionWithItemsHandler
}
```

- Section 09 presents `ActivityView(items: [fileURL])` inside `.sheet(...)`. A sheet avoids the iPad popover-anchor requirement that a bare `UIActivityViewController` has.
- `onComplete` deletes the temporary file.
- Sharing a file URL, not a string, lets AirDrop and Files save a proper `.json`.
- The caller builds the report (section 09 does this from `JITController.shared` and `LiveDeviceSystem.current()`). These helpers only take a finished `DeviceReport`, so this section doesn't depend on section 07's controller.
- These helpers have no tests. They are verified by using them in the simulator once section 09 adds the buttons.

### Schema: `device-reports/schema.json`

A JSON Schema (draft 2020-12) of the model, written by hand:

- **Header.** `"$schema": "https://json-schema.org/draft/2020-12/schema"`, a `title`, and `"type": "object"`.
- **Top level.**
  - `required` lists every non-optional field: `schemaVersion`, `generatedAt`, `app`, `device`, `os`, `install`, `jit`, `memory`, `gates`.
  - `notes` is optional, with `"type": ["string", "null"]`.
  - `"additionalProperties": false`, which keeps accidental extra data out of filed reports.
- **Nested objects** (`app`, `device`, `os`, `install`, `install.evidence`, `jit`, `jit.txm`, `jit.probe`, `memory`, `GateResult`) are defined under `$defs`, referenced with `$ref`. Each one lists its non-optional fields as `required` and also sets `additionalProperties: false`.
  - Optional Swift fields are not required and allow `null`: `jit.reason`, `jit.probe.detail`, `GateResult.passed`.
- **`schemaVersion`** is `{"type": "integer", "const": 1}`.
- **Dates** (`generatedAt`, `GateResult.measuredAt`) are strings with a `pattern` for ISO-8601 UTC: `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$`.
- **Fields used in the filename.** `device.modelIdentifier` and `install.method` are strings with the pattern `^[A-Za-z0-9,._-]+$`. That also stops a report from injecting path separators into the filename.
- **`gates`** is an object whose `additionalProperties` is `{"$ref": "#/$defs/GateResult"}`, so any key is allowed but each value must have the gate shape.
- **Enum-like fields** (install method, `csDebuggedSeen`, `source`, `reason`, `probe.kind`, `txm.state`, `packageKind`) are plain strings, with **no `enum` lists**. Duplicating the Swift enums here would drift silently. Drift in the Swift enums is caught by the Swift fixture decode instead.
- `memory.availableBytes` is `{"type": "integer", "minimum": 0}`, and `jit.usable`, `jit.csDebugged` and `txm.enforced` are booleans.

### Filer: `scripts/file_device_report.py`

```
uv run scripts/file_device_report.py [--out-dir DIR] [--check] <path | ->
```

- **Input.** Read a file path, or stdin for `-`. Parse it as JSON (UTF-8). If parsing fails, exit 1.
- **Repo paths.** Resolve the repo root from the script's own location (`Path(__file__).resolve().parent.parent`). The schema is always `<root>/device-reports/schema.json`. `--out-dir` defaults to `<root>/device-reports`. Tests pass a temp dir.
- **Known versions.** Before validating, check `schemaVersion` against a module-level set of known versions (`{1}`). An unknown or missing version, or a non-integer (including a JSON boolean), is rejected with a message naming the value.
- **Validation.** A small built-in validator for the subset the schema uses:
  - `type` (a string or a list, where `integer` excludes Python `bool`, and `number` accepts int or float but not bool)
  - `properties`, `required`, `additionalProperties` (boolean or schema), `const`, `pattern` (`re.search`), `minimum`, `items`
  - `$ref` to `#/$defs/<name>`
  - Annotation keywords (`$schema`, `$id`, `title`, `description`) are ignored.
  - Any **other** keyword found in the schema raises an error, so the schema can't quietly rely on a feature the validator doesn't check.
  - The validator collects all problems as `"<json-pointer>: <what>"` strings. If there are any, print them to stderr and exit 1 without writing anything.
- **Filename.** `<YYYY-MM-DD>-<modelIdentifier>-<install.method>-<hash8>.json`, where:
  - the date is the UTC calendar date of `generatedAt` (parse it with `datetime.fromisoformat` after mapping a trailing `Z` to `+00:00`)
  - `hash8` is the first 8 hex digits of the SHA-256 of the **canonical JSON**: `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")`
- **File content.** `json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False)` plus a trailing newline, so the diff is readable and stable whatever the input formatting. The same logical report always gives the same name and bytes.
- **Idempotent.**
  - If the target already exists with identical bytes, print its path and exit 0 without writing.
  - If it exists with different bytes (only possible after a hand edit of a filed report), exit 1 and leave it untouched.
  - Otherwise, write it atomically: write a temp file in the out dir, then `os.replace`. Create the out dir if needed, then print the path.
- **`--check`.** Validate and print the path it would write, but write nothing. Exit 0 or 1 as above.
- **Exit codes.** 0 for success. 1 for an invalid report or refused write. 2 for usage errors (the `argparse` default).
- **Scope.**
  - The filer doesn't commit. The owner commits the filed report.
  - It doesn't inspect `notes`. Keeping notes free of program titles is the owner's responsibility when adding them.
- Standard library only: `argparse`, `json`, `hashlib`, `re`, `datetime`, `pathlib`, `os`, `sys`, `tempfile`.

---

## Done when

- `make test-scripts` passes the three pytest tests, and the fixture validates.
- `make test-swift` passes the round-trip/privacy test and the fixture contract test on the simulator.
- In a simulator build, `DeviceReport.make(..., system: LiveDeviceSystem.current(), ...)` produces JSON that `uv run scripts/file_device_report.py --check -` accepts. Check this once by hand, by printing the encoded report in a debug run and piping it in. Section 09's Copy report button makes this easier later.
- No file added by this section contains a device name, UDID, serial, or program title.

---

## Implementation notes (as built)

The files are the ones in the table above. `SystemInfo.cpuFamily` now calls `sysctlUInt32` from `DeviceSystem.swift`, so there is one sysctl helper.

`JITStatus` encodes a nil `reason` with `encodeIfPresent`, so the key is omitted. The previous `encode` wrote `null`, and the fixture key-set test failed until that changed. Decoding already used `decodeIfPresent`.

A simulator `DeviceReport.make(..., system: LiveDeviceSystem.current(), ...)` was accepted by `scripts/file_device_report.py --check`. On this machine the model was `iPhone18,4` and the chip was `unknown` (not in the table yet). The two named test devices, `iPhone14,4` and `iPad14,5` / `iPad14,6`, are in the table.

`make test-scripts` passed (20 tests). `make test-swift` passed, including the round-trip/privacy test and the fixture contract, and the app stayed running in the simulator.

The review found nothing to change. The trail is in `../implementation/code_review/section-08-*.md`.

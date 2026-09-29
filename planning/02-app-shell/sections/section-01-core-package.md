# Section 01: EikonCore package, build and test wiring, persisted-file rules

## Background

Eikon is an iPhone and iPad app (iOS 15 minimum) that will run x86 Windows and Linux games through Wine, FEX-Emu and Box64, and Kirikiri and Ren'Py games natively. Split 01 is done. It builds one app binary with XcodeGen, a Makefile and Python scripts run through `uv`, and it has one SwiftPM package, `Packages/EikonKit`. EikonKit imports UIKit and is iOS-only.

Split 02 (the app shell) adds a lot of platform-neutral logic: detection, identity, route rules, the settings CRDT, session sentinel and breadcrumbs, issue-URL building, and a collection scanner. The scanner has to run **the same detection code on the Mac**, and core tests should run quickly with `swift test`. So that logic goes in a **new SwiftPM package, `Packages/EikonCore`**. It supports iOS 15 and macOS 13 and does not use UIKit. EikonKit depends on it for the pieces that face UIKit.

This section is the first step. It adds:

1. The package skeleton: Swift targets, a C target, an executable target and a test target.
2. The C target `CEikonSession`. It holds the render-gate in-flight atomics, the async-signal-safe breadcrumb slot writer and the fault hook. Later sections put Swift faces on it: section 07 covers breadcrumbs and the fault record, and section 10 covers `RenderGate`.
3. Wiring: EikonKit depends on EikonCore, `project.yml` links the package and adds its test bundle, the Makefile gets `test-core` and `scan-collection`, and CI runs `make test-core`.
4. The shared persisted-file rules (`Persisted`). The settings store, gate store, library index and crash history all use them.

This section depends on no other section, and every other section depends on it.

### Constraints that apply to all code here

- **Swift 6 language mode** with complete concurrency checking.
- **iOS 15 minimum.** Swift `Atomic`/`Mutex` and `OSAllocatedUnfairLock` are not available. This is why the atomics are in C (C11 `<stdatomic.h>`).
- **01's style.** Small files that each hold one concept. `Sendable` protocol seams with a `Live*` type and `.live`. Pure logic goes in caseless enums.
- **No program titles anywhere.** Titles must not appear in the repo, logs, tests or output. Test content is original and synthesized in temp directories.
- **Tests are few and behavioral** (the owner's standing rule). They must not assert constants, exact strings, file contents or internal structure. Use Swift Testing (`import Testing`, free `@Test func` functions with behavior names, `#expect`/`#require`). Put any fakes at the top of the test file. Use temp directories for every file test.

## Tests first

### Build-level checks (no unit tests)

- `make test-core` passes on the Mac. It compiles `CEikonSession`, `EikonCore`, `eikon-scan` and `EikonCoreTests`, and runs the tests.
- `make test-swift` runs **both** `EikonCoreTests` and `EikonKitTests` on the simulator. When you first wire this up, check the xcodebuild output and confirm each suite appears exactly once.
- `make test` runs `test-core`, `test-swift` and `test-scripts`.
- `make project` still generates the project, and `make test-scripts` is unaffected.

### `Packages/EikonCore/Tests/EikonCoreTests/PersistedTests.swift`

Write these before implementing `Persisted`. Use a tiny test-local `Codable` document type that has a `format` field and one `TolerantList` of a small element struct. Build it in the test file; it is not a production type.

- **Test: a file with a newer `format` loads but is never rewritten by a save.**
  - Write raw JSON to a temp file with `format` greater than the document type's current format.
  - Load it. The known fields are available, and the result is flagged read-only.
  - Attempt a save. The file's bytes are unchanged afterwards, whether save throws or returns.
- **Test: one malformed element in a collection is dropped from the loaded view but is still present after a save.**
  - Write JSON whose list has good elements plus one element that doesn't decode as the element type, for example a wrong field type.
  - Load it. The in-memory elements are only the good ones.
  - Save, then parse the file with `JSONSerialization`. The malformed element is still there, unchanged.

This test belongs to section 09, because it needs `GameLocation`: "a location persisted mid-fingerprinting loads as `pending`". Do not write it here.

Do not assert the temp-file naming, key order or byte layout.

The C target has no tests in this section. Its behavior is tested through the Swift APIs added in section 07 (breadcrumbs, fault record) and section 10 (`RenderGate`).

## Implementation

### 1. Package layout to create

```
Packages/EikonCore/
  Package.swift
  Sources/
    CEikonSession/
      include/CEikonSession.h
      CEikonSession.c
    EikonCore/
      Library/
        Persisted.swift
    eikon-scan/
      main.swift
  Tests/
    EikonCoreTests/
      PersistedTests.swift
```

Later sections add folders under `Sources/EikonCore/`: `Detection/`, `Identity/`, `Routes/`, `Settings/`, `Sessions/`, the rest of `Library/`, and `Scan/`. They also add test files: `Fixtures.swift`, `DetectionTests.swift`, `IdentityTests.swift`, `RoutePickerTests.swift`, `SettingsTests.swift`, `SessionTests.swift` and `ScannerTests.swift`. Do not create those here.

### 2. `Packages/EikonCore/Package.swift`

- `// swift-tools-version:6.0`
- `name: "EikonCore"`
- `platforms: [.iOS(.v15), .macOS(.v13)]`
- Products:
  - `.library(name: "EikonCore", targets: ["EikonCore"])`
  - `.executable(name: "eikon-scan", targets: ["eikon-scan"])`
- Targets:
  - `.target(name: "CEikonSession")`: plain C, with no linker settings.
  - `.target(name: "EikonCore", dependencies: ["CEikonSession"], linkerSettings: [.linkedLibrary("z")])`. Detection in section 02 uses system `libz` for zlib inflate. CryptoKit is a system framework on both platforms and needs no setting.
  - `.executableTarget(name: "eikon-scan", dependencies: ["EikonCore"])`
  - `.testTarget(name: "EikonCoreTests", dependencies: ["EikonCore", "CEikonSession"])`
- `swiftLanguageModes: [.v6]`

Follow the shape of the existing `Packages/EikonKit/Package.swift`.

### 3. `CEikonSession`: header and C implementation

The C code must be plain C11 with `<stdatomic.h>`, `<stdint.h>`, `<stdbool.h>` and `<unistd.h>`/`<fcntl.h>`. It must not use Objective-C or Foundation. Everything on a fault path must be **async-signal-safe**: no malloc, no locks and no stdio. Use only `pwrite`/`write`, plus `open` in the pre-open calls.

Keep the header free of `_Atomic` types, because Swift imports them poorly. Declare the render gate as an **opaque struct** and define it in the `.c` file.

`include/CEikonSession.h` declares three groups. The names below are the contract that sections 07 and 10 build on.

**a. Render gate (in-flight guard).** It is used by `RenderGate` in EikonKit (section 10).

```c
typedef struct eikon_render_gate eikon_render_gate;   /* opaque; defined in the .c */

eikon_render_gate *eikon_render_gate_create(void);    /* starts open, in-flight 0 */
void eikon_render_gate_destroy(eikon_render_gate *gate);
bool eikon_render_gate_enter(eikon_render_gate *gate); /* false when closed; frame is skipped */
void eikon_render_gate_leave(eikon_render_gate *gate);
void eikon_render_gate_set_closed(eikon_render_gate *gate, bool closed);
int32_t eikon_render_gate_in_flight(const eikon_render_gate *gate);
```

- The struct holds an `_Atomic int32_t` in-flight count and an `_Atomic bool` closed flag. Use sequentially consistent operations.
- `enter` increments the count first and then reads `closed`. If the gate is closed, it decrements again and returns false. With this order, a host that sets `closed` and then waits for the count to reach zero can never miss a frame that is entering. Bounded polling for `close(timeout:)` lives in Swift (section 10), not here.
- Allocate the gate on the heap so it has a stable address. Swift holds it in a class and calls destroy in `deinit`.

**b. Breadcrumb slot writer.** It is used by `Breadcrumbs` in section 07.

```c
#define EIKON_BREADCRUMB_SLOTS 64
/* Size in bytes of one fixed slot; the Swift reader uses the same constant. */
#define EIKON_BREADCRUMB_SLOT_SIZE /* chosen by the implementer */

/* One pwrite of a full slot at offset (seq % EIKON_BREADCRUMB_SLOTS) * SLOT_SIZE.
   Async-signal-safe. No fsync. Returns 0 or errno. */
int eikon_breadcrumb_write(int fd, uint64_t seq, int64_t time,
                           uint16_t event, int64_t a, int64_t b);
```

- A slot holds `(seq: UInt64, time: Int64, event: UInt16, a: Int64, b: Int64)` in a fixed little-endian layout.
- Each slot also carries a trailing check value derived from the other fields. The Swift reader (section 07) uses it to reject a torn, partially written slot. Section 07's test writes a partial slot directly and expects only the valid slots back.
- Document the layout in the header so the Swift reader matches it.
- The file descriptor is opened ahead of time by Swift. This function never opens or allocates.

**c. Fault hook.** It is called by later runtimes (splits 05 and 06) from their own fault paths, and read back by `FaultRecord` in section 07.

```c
/* Opens (creates/truncates) the fault file ahead of time and writes a header
   carrying the 16-byte session id. Keeps the fd in a static. Returns 0 or errno. */
int eikon_session_fault_open(const char *path, const uint8_t session_id[16]);

/* One write(2) of a fixed-size record {signal, pc, address}. Async-signal-safe.
   No-op when no file is open. */
void eikon_session_fault_record(int signal, uintptr_t pc, uintptr_t address);

/* Closes the fd, if open. Called when a session ends. */
void eikon_session_fault_close(void);
```

- Give the header a magic value and a layout version before the session id, so the reader can reject foreign files. Section 07 accepts a fault file only when the header's session id matches the sentinel's.
- Store the file descriptor in a static `_Atomic int`, set to -1 when closed, so a signal-context read is safe.
- **02 installs no signal handler.** FEX and Wine use SIGSEGV/SIGBUS for normal operation. Put a comment in the header saying the hook exists for later runtimes to call for faults they really cannot handle.

### 4. `Sources/EikonCore/Library/Persisted.swift`: shared persisted-file rules

All JSON files in `Library/Application Support/Eikon/` share these rules. The files are `drives.json`, `locations.json`, `settings/<replica>.json`, `gates.json` and `sessions/history.json`.

1. **Format header.** Every file is a top-level JSON object carrying an integer `format`.
2. **Atomic write.** Write to a temp file in the same directory (a hidden name), `fsync` it, `rename` it over the target, then `fsync` the directory. Directory fsync is best effort, as in 01's `ProbeSentinel.syncDirectory()`. Create the directory if it is missing.
3. **A newer `format` is read-only.** If the file's `format` is newer than the app knows, load it as far as possible and **never rewrite it**.
4. **Tolerant decoding.** Collections decode element by element. An element that fails to decode is dropped from the in-memory view, but its raw JSON is kept and written back unchanged on save. A downgrade then never destroys data written by a newer build.

To keep this section independent of section 05's `JSONValue`, keep raw elements as `Data` round-tripped through `JSONSerialization`, or an equivalent private raw-JSON representation. The API below is a suggested outline, and the implementer may refine the names.

```swift
public enum Persisted {
    /// Atomic replace: temp file in the same directory, fsync, rename, fsync the directory.
    public static func writeAtomically(_ data: Data, to url: URL) throws
    /// The top-level `format` integer, or nil if the data isn't a JSON object with one.
    public static func format(of data: Data) -> Int?
}

/// A document type stored under the persisted-file rules.
public protocol PersistedDocument: Codable, Sendable {
    static var currentFormat: Int { get }
}

/// A file-backed document. Loading a newer-format file marks it read-only; saving a
/// read-only file never touches the disk (throws `PersistedError.readOnly`).
public struct PersistedFile<Document: PersistedDocument>: Sendable {
    public init(url: URL)
    public func load() throws -> Loaded?          // nil when the file doesn't exist
    public func save(_ document: Document, over loaded: Loaded?) throws
    public struct Loaded: Sendable { public var document: Document; public var isReadOnly: Bool }
}

public enum PersistedError: Error, Sendable { case readOnly }

/// Per-element tolerant array: decodes good elements, keeps undecodable ones as raw JSON,
/// and encodes both back (raw ones unchanged).
public struct TolerantList<Element: Codable & Sendable>: Codable, Sendable {
    public var elements: [Element]                // the in-memory view
    // raw undecodable elements kept privately and re-emitted on encode
}
```

**As built:**

- `save(_ document:)` has no `over loaded:` parameter. Before writing, it reads the file on disk and throws `PersistedError.readOnly` if that file is read-only. That makes the rule hold even for callers that never loaded the file. Callers serialize saves to one URL.
- A file is read-only (`Persisted.isReadOnly`) when it is a JSON object whose `format` is missing, not an integer (a Bool doesn't count), or newer than `currentFormat`. Data that isn't a JSON object at all stays overwritable: every build writes atomically, so such data can only be corruption, and refusing it would wedge the store.
- `PersistedFile` stamps the top-level `format` over whatever the document encodes (`Stamped`). Documents must encode as a JSON object.
- `TolerantList` keeps undecodable elements in a private `RawJSON` enum (null, bool, Int64, UInt64, Double, string, array, object) and re-emits them after the decoded ones. It relies on JSONDecoder not advancing the unkeyed container when a decode fails. The malformed-element test pins that behavior.
- C slot layout: 48-byte slots (seq, time, a, b, event, 6 zero bytes, then an FNV-1a 64 check over bytes 0..<40). Fault file: a 24-byte header (`EKFT`, version 1, session id) followed by 24-byte records. The header documents both, along with the rules for readers (ignore a torn trailing record, read the previous file before `fault_open` truncates it) and callers (open and close only while no runtime can call `record`). `_Static_assert`s check that the atomics are lock-free.

Notes:

- Callers choose what to do when a save is refused. The settings store (section 05) forks to a new replica. Other stores keep working in memory. So `save` must refuse loudly (throw) rather than silently succeed.
- Decoding a newer-format file relies on the document using tolerant types: optional fields, `TolerantList`, and enums with fallback cases.
- Where undecodable elements are re-emitted within the list, for example appended after the decoded ones, is an implementation choice. The tests check only that they survive.
- Mark the types `Sendable` and keep them free of UIKit.

### 5. `Sources/eikon-scan/main.swift`

The collection scanner itself is section 04. For now `main.swift` is a minimal placeholder that keeps the package building. It prints `eikon-scan: not implemented yet (section 04)` to stderr and exits non-zero, which matches the Makefile's existing `stub` convention of failing loudly rather than passing silently. Keep the top level synchronous, because section 04 depends on that.

### 6. `Packages/EikonKit/Package.swift`

- Add `dependencies: [.package(path: "../EikonCore")]`.
- The `EikonKit` target depends on `["CEikonJIT", .product(name: "EikonCore", package: "EikonCore")]`.
- Add no re-exports. The app imports both modules itself.
- Keep `platforms: [.iOS(.v15)]` for EikonKit.

### 7. `project.yml`

- Under `packages:`, add `EikonCore` with `path: Packages/EikonCore` next to `EikonKit`.
- Under the `Eikon` target's `dependencies:`, add `- package: EikonCore` with `product: EikonCore`.
- In the scheme's `test.targets`, add `- package: EikonCore/EikonCoreTests` next to `EikonKit/EikonKitTests`. `scripts/test_swift.sh` needs no change, because it runs the scheme's test action.
- `EikonCoreTests` also runs on the iOS simulator, so tests must not use macOS-only APIs such as `Process`.

### 8. `Makefile`

- Add `test-core` and `scan-collection` to `.PHONY`.
- `test: test-core test-swift test-scripts`
- New target `test-core`. It runs natively on the Mac and needs no project generation:
  ```make
  test-core:
  	@swift test --package-path Packages/EikonCore
  ```
- New target `scan-collection`. It writes nothing into the repo:
  ```make
  scan-collection:
  	@swift run --package-path Packages/EikonCore -c release eikon-scan --per-folder $(ARGS)
  ```
- Update `help` so it lists `test-core` and `scan-collection`, the latter with its optional `ARGS=`. Keep the existing wrapped-line style.

`.gitignore` already ignores `.build/` and `.swiftpm/`, so no change is needed there.

### 9. `.github/workflows/ci.yml`

- In the `build` (macOS) job, add a step named, for example, "Core tests" that runs `make test-core`. Put it after "Install tools" and before "Build, package and verify".
- Leave the Ubuntu `scripts` job unchanged.

## Done when

- `Packages/EikonCore` builds for macOS (`swift build`) and for the iOS simulator through the app scheme.
- `make test-core` passes, and the two Persisted tests pass.
- `make test-swift` shows both `EikonCoreTests` and `EikonKitTests`, each once, and the app still launches on the simulator.
- EikonKit compiles with its new EikonCore dependency, and the app target links EikonCore.
- The CI macOS job runs `make test-core`.
- `CEikonSession.h` exposes the render gate, the breadcrumb slot writer and the fault-hook functions described above. No signal handler is installed anywhere.

# section-07-sessions-crash: Session sentinel, breadcrumbs, fault hook, outcomes, crash history, issue URL

## Background

Eikon is an iPhone/iPad app that will run Windows, Linux and native-engine games **inside the app process**. So a game crash ends the whole app, and iOS jetsam kills can't be caught. Crash reporting therefore happens **on the next launch**:

- A **session sentinel** file is written before a game starts.
- **Breadcrumbs** (app-defined event codes plus integers) are appended while it runs.
- An optional **fault record** is written by a runtime's own fault path.

If the sentinel still exists at the next launch, the previous session did not end cleanly. The evidence is classified into a `SessionOutcome` and stored in `CrashHistory`. Later work (section 11) shows a banner and can open a prefilled GitHub issue, built by the pure `CrashIssue` URL builder from this section.

This section builds the **platform-neutral core** of that pipeline in the `EikonCore` SwiftPM package (`Packages/EikonCore`, iOS 15 + macOS 13, Swift 6 language mode, no UIKit), plus the GitHub issue form `.github/ISSUE_TEMPLATE/crash.yml`. Everything here is testable with `swift test` on the Mac (`make test-core`).

Out of scope, handled elsewhere:
- Who arms and disarms the sentinel, the scene-event handling, and memory sampling: `GameSession` / `GameSessionHostViewController` (section 10).
- Consuming the sentinel at launch, the banner, "Try another route", opening the URL and the clipboard fallback: `CrashReportController` (section 11).
- Banner UI and outcome strings (sections 12 and 13).

### Hard constraints that apply here

- **No program titles anywhere.** Nothing in these files may carry a game's display name, folder name, file names, fingerprint or file hash. This covers breadcrumbs, the fault file, history, and the issue URL.
  - Breadcrumbs accept only app-defined event codes and integers.
  - A game appears in an issue only as a **report id**: the first 8 characters of its random game id (`GameID` is a random UUID, so the prefix reveals nothing).
- **02 installs no signal handler.** FEX and Wine use SIGSEGV/SIGBUS for normal operation. The C fault hook exists only for later runtimes (splits 05/06) to call from their own fault paths.
- **iOS 15 minimum.** There are no Swift `Atomic`/`Mutex` types and no `OSAllocatedUnfairLock`. Use C11 atomics in the C target and `NSLock` (or similar) in Swift.
- **Swift 6 complete concurrency checking.** Types are `Sendable`. Pure logic goes in caseless enums or value types.
- **01's style.** Small single-concept files, `Sendable` value types, and no `default:` in enum switches that map codes.
- **Tests are few and behavioral.** Don't assert constants, exact strings, file contents or internal structure. Where a test needs a threshold (the 60 s window, the 64-slot capacity, the 7,500-character limit, 5 history entries), read it from the public constant instead of typing the number.

## Dependencies

- **section-01-core-package** (required). Provides:
  - the `Packages/EikonCore` package with the `CEikonSession` C target (breadcrumb slot writer, fault hook, in-flight atomics) and the `EikonCoreTests` test target
  - `make test-core`
  - the shared persisted-file rules in `Library/Persisted.swift`: a `format` integer, atomic write (temp file, rename, fsync), a newer-format file is read-only, and tolerant per-element decoding that preserves raw elements
- **Types from other core sections.** `SessionRecord` uses `Engine` and `CPUArchitecture` (section-02-detection, `Detection/Engine.swift` / `Detection/BinaryInfo.swift`) and `GameID` (section-03-identity, `Identity/GameIdentity.swift`: `public struct GameID: Hashable, Codable, Sendable { public let uuid: UUID }`). Those types must exist before this section compiles. If this section is picked up before 02/03 land, land those type declarations first; they are tiny.
- **Blocks:** section-10 (runtime/session host) and section-11 (crash report controller).

## Files

Create:
- `Packages/EikonCore/Sources/EikonCore/Sessions/SessionRecord.swift`
- `Packages/EikonCore/Sources/EikonCore/Sessions/SessionSentinel.swift`
- `Packages/EikonCore/Sources/EikonCore/Sessions/Breadcrumbs.swift` (`BreadcrumbEvent`, `Breadcrumb`, the slot file)
- `Packages/EikonCore/Sources/EikonCore/Sessions/FaultRecord.swift`
- `Packages/EikonCore/Sources/EikonCore/Sessions/SessionOutcome.swift`
- `Packages/EikonCore/Sources/EikonCore/Sessions/CrashHistory.swift`
- `Packages/EikonCore/Sources/EikonCore/Sessions/CrashIssue.swift`
- `Packages/EikonCore/Tests/EikonCoreTests/SessionTests.swift`
- `.github/ISSUE_TEMPLATE/crash.yml`

Verify or complete (created by section 01):
- `Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h`
- `Packages/EikonCore/Sources/CEikonSession/CEikonSession.c`

On-device location of the files (resolved by the caller, never hard-coded as an absolute container path): `Library/Application Support/Eikon/sessions/` holds `sentinel.json`, `breadcrumbs.bin`, `fault.bin` and `history.json`. Every type here takes a **directory URL** in its initializer, so tests pass a temp directory. Provide a `live` convenience only where it's useful to callers.

---

## Tests first (`Packages/EikonCore/Tests/EikonCoreTests/SessionTests.swift`)

Use Swift Testing (`import Testing`, free `@Test func` with behavior names, `#expect`/`#require`, `@Test(arguments:)`). Every test works in its own temp directory. Any fakes or helpers go at the top of the file. Use a synthetic `GameID(uuid: UUID())` and generic values. No titles.

**Sentinel**
- Test: arm, then consume, returns the record. A second consume returns nothing.
- Test: disarm, then consume, returns nothing, and the breadcrumbs and fault files are gone.

**Outcome classification**
- Test (one parameterized test over the four rows of the classification table below): the phase, fault record and breadcrumb inputs give the expected outcome and banner flag. Build the inputs through the real sentinel, breadcrumbs and fault APIs (arm, append, record fault, consume) where practical, so the round trip is exercised.
- Test: a memory warning more than the window (`SessionOutcome.memoryWarningWindow`) before the last breadcrumb does not count as a memory kill. The result is `endedUnexpectedly`.

**Breadcrumbs**
- Test: after more than capacity (`Breadcrumbs.capacity`) appends, only the last `capacity` remain, in order.
- Test: reading after a simulated torn write yields the valid slots. Build the torn write by writing a partial slot directly into the file (for example, overwrite the first half of one slot's bytes with the start of a different slot, or truncate the file mid-slot). The reader returns the other slots and skips the torn one.

**Fault record**
- Test: a fault record written through the C hook (`eikon_session_fault_open` then `eikon_session_fault_record`) is read back with its signal and pc.
- Test: a fault file whose header names another session is ignored. The reader returns nil when given a different session id.

**Crash history**
- Test: it keeps at most `CrashHistory.limitPerGame` entries per game, newest first, and each entry keeps its breadcrumbs snapshot. Also check that entries for a second game are unaffected.

**Issue URL**
- Test: the URL's query parses back (via `URLComponents`) to exactly the provided fields.
- Test: values containing `+`, `&`, `=` and spaces round-trip.
- Test: with many breadcrumbs, the URL stays under `CrashIssue.maxURLLength`, and the oldest breadcrumbs are the ones dropped (the newest one is still present).
- Test: the URL contains the report id and no fingerprint value. Pass an entry whose game id is known and check that the report id appears. Keep a fingerprint-like hex string in the test, which is never an input, and check that it does not appear. Also check that the full game UUID string doesn't appear.

**`crash.yml`:** no automated test. During implementation, check once by hand that the form's field `id`s match the query keys the URL builder emits. Prefill is verified manually on GitHub at landing (section 16).

---

## Implementation

### 1. `SessionRecord` (`Sessions/SessionRecord.swift`)

```swift
public struct SessionRecord: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case running, background }
    public var sessionID: UUID
    public var gameID: GameID
    public var engine: Engine
    public var architecture: CPUArchitecture?
    public var route: String               // RouteID raw value, or "test" for developer sessions
    public var appBuild: String
    public var startedAt: Date
    public var phase: Phase
}
```

- `route` is a `String`, not `RouteID`. Developer test sessions record `"test"` (section 10/14), and a record written by a newer build may carry a route this build doesn't know. Provide a `public static let testRoute = "test"` constant so callers don't retype it.
- Enum fields must decode tolerantly, like the rest of the core: an unknown `Engine` decodes to `.unknown` and an unknown architecture to `.other`/nil (section 02's fallback decoding). An unknown `Phase` should decode as `.running`, the conservative choice that still reports.

### 2. `SessionSentinel` (`Sessions/SessionSentinel.swift`)

This generalizes 01's `ProbeSentinel` (`Packages/EikonKit/Sources/EikonKit/ProbeSentinel.swift`). Reuse its durability pattern: `open`/`write` loop handling `EINTR`, then `fsync` the file, then best-effort `fsync` of the directory. The record is JSON in `sentinel.json`, written atomically (temp file, then rename), with both the file and the directory fsynced.

```swift
public struct ConsumedSession: Sendable, Equatable {
    public var record: SessionRecord
    public var breadcrumbs: [Breadcrumb]   // snapshot, sorted by seq
    public var fault: FaultRecord?         // only if its header matches record.sessionID
}

public struct SessionSentinel: Sendable {
    public init(directory: URL)
    public func arm(_ record: SessionRecord) throws      // atomic write + fsync file and dir
    public func setPhase(_ phase: SessionRecord.Phase) throws
    public func disarm()                                   // removes sentinel, breadcrumbs.bin, fault.bin
    public func consumeAtLaunch() -> ConsumedSession?      // always removes all three files afterwards
    // URLs of breadcrumbs.bin / fault.bin exposed so GameSession can open them
}
```

- `arm` creates the directory if needed. It also clears any leftover `breadcrumbs.bin`/`fault.bin` from an earlier session, so stale data can't be attributed to the new session.
- `setPhase` rewrites the record with the new phase, using the same atomic write and fsync. The phase is what separates "killed in background" from a foreground crash, so it must be durable.
- `consumeAtLaunch`:
  1. Reads the record. If it is missing, return nil. If it is unreadable, remove the files and return nil.
  2. Reads the breadcrumbs snapshot and the fault record (validated against `record.sessionID`).
  3. Removes all three files whatever happened, and returns the result.
  
  A second call therefore returns nil.
- The sentinel does not open the breadcrumb or fault descriptors itself. `GameSession` (section 10) arms the sentinel, then opens both through the APIs below. Make the file URLs available, for example `breadcrumbsURL` and `faultURL`.

### 3. C helpers (`CEikonSession`)

Section 01 created the C target. Confirm it exposes (or add) the following. All writers are **async-signal-safe**: fixed-size buffers, `pwrite`/`write` only, no allocation or locks, and descriptors opened in advance and kept in static storage.

```c
// Breadcrumb slot file
int  eikon_breadcrumbs_open(const char *path);          // opens/creates, sizes to capacity slots; 0 on success
void eikon_breadcrumbs_append(uint16_t event, int64_t a, int64_t b);  // pwrite at slot seq % capacity
void eikon_breadcrumbs_close(void);

// Fault hook
int  eikon_session_fault_open(const char *path, const uint8_t session_id_bytes[16]); // writes header
void eikon_session_fault_record(int signal, uintptr_t pc, uintptr_t address);       // one write(2)
void eikon_session_fault_close(void);
```

If 01 used different names, keep 01's names and wire the Swift side to them. Any names added here should follow the `eikon_` prefix.

**Breadcrumb slots:**
- The file holds a fixed number of slots (capacity **64**). A slot logically carries `(seq: UInt64, time: Int64, event: UInt16, a: Int64, b: Int64)`.
- `seq` is a process-wide C11 atomic counter starting at 1, so an all-zero slot means "empty". `time` is wall-clock milliseconds since the Unix epoch (`clock_gettime(CLOCK_REALTIME)`, which is async-signal-safe).
- Each append is one `pwrite` of one whole slot at offset `(seq % capacity) * slotSize`. There is **no fsync per append**. Process death doesn't lose written pages; only power loss can.
- **Torn-write detection:** the slot must be self-validating. Add a check word to the slot layout, for example a 32-bit checksum over the other fields, or the `seq` repeated at the end of the slot. The reader then rejects a slot that was only partly written. Define the slot as a packed C struct in the header, so Swift and C agree on the layout and tests can write raw partial slots.

**Fault file:**
- `fault.bin` starts with a fixed header: a magic/version plus the 16 session-id bytes. After it come fixed-size records `(signal: int32, pc: uint64, address: uint64)`, each written with a single `write(2)`.
- `eikon_session_fault_open` writes the header when it opens the file.
- Declare the header and record structs in the C header as well.

### 4. `Breadcrumbs` (`Sessions/Breadcrumbs.swift`)

```swift
public enum BreadcrumbEvent: Sendable, Equatable {
    case sessionStart, sessionPaused, sessionBackgrounded, sessionResumed, sessionStop
    case memoryWarning
    case memorySample(availableMB: Int64)
    case audioInterrupted
    case renderGateTimeout
    case runtimeError(code: Int64)
    // stable numeric codes; later splits add cases with new codes, never renumber
}

public struct Breadcrumb: Sendable, Equatable, Codable {
    public var seq: UInt64
    public var time: Date
    public var code: UInt16          // raw event code, kept even if this build doesn't know it
    public var a: Int64
    public var b: Int64
    public var event: BreadcrumbEvent? { get }   // nil for codes from a newer build
}

public enum Breadcrumbs {
    public static let capacity: Int              // 64
    public static func open(at url: URL) throws  // wraps eikon_breadcrumbs_open
    public static func append(_ event: BreadcrumbEvent)
    public static func close()
    public static func read(from url: URL) -> [Breadcrumb]   // valid slots only, sorted by seq
}
```

- `BreadcrumbEvent` is a **closed** set of app-defined events with **stable numeric codes**. Each case maps to `(code, a, b)` in one exhaustive switch, and back from `(code, a, b)` in another. Associated values are integers only, so no strings can reach the file. Keep the code↔case mapping in one place in this file, with a comment that codes are never reused or renumbered.
- `read` skips empty slots, slots that fail the check word, and anything past a truncated end. It sorts by `seq`, so the ring order is recovered. It tolerates a missing file (returns empty).
- Descriptor state lives in C. The Swift namespace is a thin wrapper, so no Swift global mutable state is needed and Swift 6 concurrency checking stays quiet.
- A **fixed-size record** is also needed in `CrashIssue` (a line of codes and integers per breadcrumb) and in `CrashHistory` (the snapshot). `Breadcrumb` is `Codable` for history.

### 5. `FaultRecord` (`Sessions/FaultRecord.swift`)

```swift
public struct FaultRecord: Codable, Sendable, Equatable {
    public var signal: Int32
    public var pc: UInt64
    public var address: UInt64
    public static func read(from url: URL, sessionID: UUID) -> FaultRecord?
    public static func open(at url: URL, sessionID: UUID) throws   // wraps eikon_session_fault_open
    public static func close()
}
```

- `read` returns nil when the file is missing, the header is malformed, or the header's session id differs from `sessionID`. That makes a fault file left by another session ignored.
- If several records exist, return the **first** one. It is the originating fault; later ones may be secondary.
- Nothing in 02 calls `eikon_session_fault_record` except tests. Runtimes in 05/06 will call it.

### 6. `SessionOutcome` (`Sessions/SessionOutcome.swift`)

```swift
public enum SessionOutcome: Codable, Sendable, Equatable {
    case crashed(signal: Int32, pc: UInt64)
    case likelyMemoryKill
    case endedUnexpectedly          // crash or system kill
    case killedInBackground

    public var showsBanner: Bool { get }
    public var code: String { get }                 // stable code for issue text / history ("crashed", ...)
    public static let memoryWarningWindow: TimeInterval   // 60 s
    public static let lowMemoryThresholdMB: Int64         // 100
    public static func classify(_ consumed: ConsumedSession) -> SessionOutcome
}
```

Classification, evaluated in this order:

| Evidence | Outcome | Banner |
|---|---|---|
| Phase `running` + a matching fault record | `crashed(signal, pc)` | yes |
| Phase `running` + a `memoryWarning` within 60 s of the last breadcrumb, or a last `memorySample` under 100 MB | `likelyMemoryKill` | yes |
| Phase `running`, nothing else | `endedUnexpectedly` (crash or system kill) | yes |
| Phase `background` | `killedInBackground` | no (history only) |

- "Within the window of the last breadcrumb" means the last breadcrumb's time minus the latest `memoryWarning`'s time is at most `memoryWarningWindow`. Note the reference is the last breadcrumb, not the launch time: the next launch may come hours later.
- "Last `memorySample`" means the sample with the highest `seq`.
- Only matching fault records ever reach `classify`, because `consumeAtLaunch` already filtered them by session id.
- `code` values are stable identifiers used in the issue URL and title. The UI maps outcomes to localized strings elsewhere (section 12) through an exhaustive switch.

### 7. `CrashHistory` (`Sessions/CrashHistory.swift`)

At launch, section 11 snapshots each consumed session into history together with its breadcrumbs and fault record. Then a report can be filed later from the game's detail screen, not only from the banner.

```swift
public struct CrashEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID                 // = record.sessionID
    public var record: SessionRecord
    public var outcome: SessionOutcome
    public var breadcrumbs: [Breadcrumb]
    public var fault: FaultRecord?
    public var recordedAt: Date
}

public final class CrashHistory: @unchecked Sendable {   // lock-guarded, file-backed
    public static let limitPerGame: Int                  // 5
    public init(directory: URL)                          // history.json in the sessions dir
    @discardableResult public func add(_ consumed: ConsumedSession, now: Date) -> CrashEntry
    public func entries(for game: GameID) -> [CrashEntry]    // newest first
    public func entry(id: UUID) -> CrashEntry?
}
```

- `add` classifies with `SessionOutcome.classify`, inserts the entry, and trims that game's entries to the newest `limitPerGame`, ordered by the session's `startedAt` (ties broken by `recordedAt`). It then persists.
- Persistence follows the shared `Persisted` rules from section 01:
  - The file carries `format: 1` and is written atomically.
  - A newer-format file is loaded read-only and never rewritten; `add` still updates memory.
  - Entries decode per element, so an unreadable entry is kept raw and written back unchanged.
- History stores game ids, codes and integers only. No display names.

### 8. `CrashIssue` (`Sessions/CrashIssue.swift`)

A pure URL builder. It **takes no display name, folder name, fingerprint or file hash**, only the report id and codes.

```swift
public enum CrashIssue {
    public static let maxURLLength: Int          // 7_500
    public static let maxBreadcrumbs: Int        // 20 (last N considered before length trimming)

    public struct Device: Sendable, Equatable {  // filled by EikonKit from DeviceReport facts
        public var appVersion, appBuild, appCommit: String
        public var modelIdentifier, osVersion, osBuild: String
        public var installMethod: String         // raw code
        public var jitUsable: Bool
        public var jitSource: String?            // raw code
        public var jitReasonCode: String?        // raw code
    }

    public struct Built: Sendable, Equatable {
        public var url: URL
        public var droppedBreadcrumbs: Int       // > 0 tells the caller to offer the clipboard report
    }

    public static func reportID(for game: GameID) -> String    // first 8 chars of the UUID string, lowercased
    public static func url(repository: URL, entry: CrashEntry, device: Device, reportID: String) -> Built
}
```

- EikonCore cannot see EikonKit's `DeviceReport`, which is why `Device` is a small value struct here. Section 11 fills it from 01's report facts (app version/build/commit, device model identifier, OS version/build, install method, JIT usable/source/reason code). Field values are codes, never localized text.
- The URL has the form `<repository>/issues/new?template=crash.yml&labels=crash&title=<outcome, engine, route>&<field>=<value>…`. The query fields are:

  | Query key | Value |
  |---|---|
  | `outcome` | `SessionOutcome.code` |
  | `engine` | engine raw value |
  | `arch` | architecture raw value, or empty |
  | `route` | record's route string |
  | `game` | the report id |
  | `app` | version, build, commit |
  | `device` | model identifier, OS version and build |
  | `install` | install method code |
  | `jit` | usable, source, reason code |
  | `fault` | signal and pc (hex), only when present |
  | `breadcrumbs` | the last `maxBreadcrumbs`, one line each: `seq time code a b` (codes and integers only; relative time from session start is fine) |

- **Explicit percent-encoding.** Build `percentEncodedQuery` by hand. Encode every value (and key) with an allowed set of only the RFC 3986 unreserved characters (`A–Z a–z 0–9 - . _ ~`). Everything else is encoded, including `+`, `&`, `=`, space and newline. Don't rely on `URLQueryItem` encoding, which leaves `+` and some others literal, and GitHub decodes `+` as a space.
- **Length limit.** If the URL would exceed `maxURLLength`, drop breadcrumbs **oldest first** and rebuild until it fits. Report how many were dropped in `droppedBreadcrumbs`. The caller (section 11) then copies the full `DeviceReport` JSON to the clipboard and tells the user to paste it. If the URL still doesn't fit with zero breadcrumbs, return it anyway; the other fields are bounded and short.
- The repository URL comes from the app's `EKRepositoryURL` Info.plist key (`https://github.com/getBoolean/eikon`), read by the caller. The builder only appends to it.

### 9. `.github/ISSUE_TEMPLATE/crash.yml`

A GitHub issue form:
- `name: Crash report`, a short `description`, `title: "Crash: "`, `labels: [crash]`.
- The first body element is a `markdown` block that repeats the rule: **do not include game titles, folder names or file names. The game appears only as its report id.**
- One field per query key above, with **`id` equal to the query key**: `outcome`, `engine`, `arch`, `route`, `game`, `app`, `device`, `install`, `jit`, `fault`, `breadcrumbs`.
  - Short values are `type: input`.
  - `breadcrumbs` and `fault` are `type: textarea` (`render: text` for breadcrumbs).
  - Required-ness: only `outcome` and `game` are required. Prefill can fail, and the user can then paste the clipboard report.
- One free-text `textarea` with a label along the lines of "What were you doing?" (id, for example, `notes`), not required.
- Before first use, the `crash` label must exist in `getBoolean/eikon`. That is an owner checklist item handled at landing (section 16), not code. Prefill from query parameters is verified once there as well.

---

## Checklist

1. Confirm or add the C API and packed slot/header structs in `CEikonSession` (breadcrumb open/append/close with a check word; fault open/record/close).
2. Write `SessionTests.swift` with the tests above (they should fail to compile or fail).
3. `SessionRecord`, then `Breadcrumbs`/`BreadcrumbEvent`/`Breadcrumb`, then `FaultRecord`.
4. `SessionSentinel` with `ConsumedSession`.
5. `SessionOutcome.classify`.
6. `CrashHistory` on the `Persisted` rules.
7. `CrashIssue` URL builder and `reportID`.
8. `.github/ISSUE_TEMPLATE/crash.yml`; check by hand that the field ids match the builder's query keys.
9. `make test-core` passes.

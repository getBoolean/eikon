diff --git a/.github/ISSUE_TEMPLATE/crash.yml b/.github/ISSUE_TEMPLATE/crash.yml
new file mode 100644
index 0000000..99a61bb
--- /dev/null
+++ b/.github/ISSUE_TEMPLATE/crash.yml
@@ -0,0 +1,63 @@
+name: Crash report
+description: A game session that ended unexpectedly. Usually prefilled by the app.
+title: "Crash: "
+labels: [crash]
+body:
+  - type: markdown
+    attributes:
+      value: |
+        **Do not include game titles, folder names or file names.** The game appears only as its report id.
+        If the app said some details didn't fit, paste the report it copied to your clipboard in the notes.
+  - type: input
+    id: outcome
+    attributes:
+      label: Outcome
+    validations:
+      required: true
+  - type: input
+    id: engine
+    attributes:
+      label: Engine
+  - type: input
+    id: arch
+    attributes:
+      label: Architecture
+  - type: input
+    id: route
+    attributes:
+      label: Route
+  - type: input
+    id: game
+    attributes:
+      label: Game report id
+    validations:
+      required: true
+  - type: input
+    id: app
+    attributes:
+      label: App version
+  - type: input
+    id: device
+    attributes:
+      label: Device and OS
+  - type: input
+    id: install
+    attributes:
+      label: Install method
+  - type: input
+    id: jit
+    attributes:
+      label: JIT
+  - type: textarea
+    id: fault
+    attributes:
+      label: Fault
+  - type: textarea
+    id: breadcrumbs
+    attributes:
+      label: Breadcrumbs
+      render: text
+  - type: textarea
+    id: notes
+    attributes:
+      label: What were you doing?
diff --git a/Packages/EikonCore/Sources/CEikonSession/CEikonSession.c b/Packages/EikonCore/Sources/CEikonSession/CEikonSession.c
index e93012a..ccf84f7 100644
--- a/Packages/EikonCore/Sources/CEikonSession/CEikonSession.c
+++ b/Packages/EikonCore/Sources/CEikonSession/CEikonSession.c
@@ -4,12 +4,14 @@
 #include <fcntl.h>
 #include <stdatomic.h>
 #include <stdlib.h>
+#include <time.h>
 #include <unistd.h>
 
 /* Everything below the render gate may run on a fault path: no malloc, no locks, no stdio. */
 
 _Static_assert(ATOMIC_INT_LOCK_FREE == 2, "fault fd and in-flight count must be lock-free");
 _Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "closed flag must be lock-free");
+_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "breadcrumb seq must be lock-free");
 
 /* ---- Render gate ---- */
 
@@ -90,6 +92,40 @@ int eikon_breadcrumb_write(int fd, uint64_t seq, int64_t time,
     return result;
 }
 
+static _Atomic int breadcrumb_fd = -1;
+static _Atomic uint64_t breadcrumb_seq = 0;
+
+int eikon_breadcrumbs_open(const char *path) {
+    eikon_breadcrumbs_close();
+    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
+    if (fd < 0) return errno;
+    if (ftruncate(fd, (off_t)EIKON_BREADCRUMB_SLOTS * EIKON_BREADCRUMB_SLOT_SIZE) != 0) {
+        int error = errno;
+        close(fd);
+        return error;
+    }
+    atomic_store(&breadcrumb_seq, 0);
+    atomic_store(&breadcrumb_fd, fd);
+    return 0;
+}
+
+void eikon_breadcrumbs_append(uint16_t event, int64_t a, int64_t b) {
+    int fd = atomic_load(&breadcrumb_fd);
+    if (fd < 0) return;
+    int saved_errno = errno;
+    struct timespec now;
+    int64_t millis = clock_gettime(CLOCK_REALTIME, &now) == 0
+        ? (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000 : 0;
+    errno = saved_errno;
+    uint64_t seq = atomic_fetch_add(&breadcrumb_seq, 1) + 1;
+    (void)eikon_breadcrumb_write(fd, seq, millis, event, a, b);
+}
+
+void eikon_breadcrumbs_close(void) {
+    int fd = atomic_exchange(&breadcrumb_fd, -1);
+    if (fd >= 0) close(fd);
+}
+
 /* ---- Fault hook ---- */
 
 static _Atomic int fault_fd = -1;
diff --git a/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h b/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
index abf6e79..f699ee8 100644
--- a/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
+++ b/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
@@ -42,6 +42,15 @@ int32_t eikon_render_gate_in_flight(const eikon_render_gate *gate);
 int eikon_breadcrumb_write(int fd, uint64_t seq, int64_t time,
                            uint16_t event, int64_t a, int64_t b);
 
+/* Session writer over eikon_breadcrumb_write, keeping the fd and a process-wide atomic seq
+   (starting at 1, so an all-zero slot is empty) in statics. open creates or truncates the
+   file, sizes it to EIKON_BREADCRUMB_SLOTS slots and resets seq; returns 0 or errno. append
+   stamps CLOCK_REALTIME milliseconds and is async-signal-safe; a no-op when nothing is open.
+   open and close must not race append. */
+int eikon_breadcrumbs_open(const char *path);
+void eikon_breadcrumbs_append(uint16_t event, int64_t a, int64_t b);
+void eikon_breadcrumbs_close(void);
+
 /* ---- Fault hook ---------------------------------------------------------------------------
    Nothing here installs a signal handler. FEX and Wine use SIGSEGV/SIGBUS in normal operation.
    The hook is for later runtimes to call from their own fault paths, only for faults they
diff --git a/Packages/EikonCore/Sources/EikonCore/Sessions/Breadcrumbs.swift b/Packages/EikonCore/Sources/EikonCore/Sessions/Breadcrumbs.swift
new file mode 100644
index 0000000..2f5a85f
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Sessions/Breadcrumbs.swift
@@ -0,0 +1,105 @@
+import CEikonSession
+import Foundation
+
+/// App-defined session events. Integers only, so no text can reach the file.
+public enum BreadcrumbEvent: Sendable, Equatable {
+    case sessionStart, sessionPaused, sessionBackgrounded, sessionResumed, sessionStop
+    case memoryWarning
+    case memorySample(availableMB: Int64)
+    case audioInterrupted
+    case renderGateTimeout
+    case runtimeError(code: Int64)
+
+    // Stable numeric codes. Later splits add cases with new codes; never reuse or renumber.
+    var encoded: (code: UInt16, a: Int64, b: Int64) {
+        switch self {
+        case .sessionStart: (1, 0, 0)
+        case .sessionPaused: (2, 0, 0)
+        case .sessionBackgrounded: (3, 0, 0)
+        case .sessionResumed: (4, 0, 0)
+        case .sessionStop: (5, 0, 0)
+        case .memoryWarning: (6, 0, 0)
+        case .memorySample(let availableMB): (7, availableMB, 0)
+        case .audioInterrupted: (8, 0, 0)
+        case .renderGateTimeout: (9, 0, 0)
+        case .runtimeError(let code): (10, code, 0)
+        }
+    }
+
+    init?(code: UInt16, a: Int64, b: Int64) {
+        switch code {
+        case 1: self = .sessionStart
+        case 2: self = .sessionPaused
+        case 3: self = .sessionBackgrounded
+        case 4: self = .sessionResumed
+        case 5: self = .sessionStop
+        case 6: self = .memoryWarning
+        case 7: self = .memorySample(availableMB: a)
+        case 8: self = .audioInterrupted
+        case 9: self = .renderGateTimeout
+        case 10: self = .runtimeError(code: a)
+        default: return nil
+        }
+    }
+}
+
+public struct Breadcrumb: Sendable, Equatable, Codable {
+    public var seq: UInt64
+    public var time: Date
+    /// The raw code, kept even when this build doesn't know it.
+    public var code: UInt16
+    public var a: Int64
+    public var b: Int64
+
+    public init(seq: UInt64, time: Date, code: UInt16, a: Int64, b: Int64) {
+        self.seq = seq
+        self.time = time
+        self.code = code
+        self.a = a
+        self.b = b
+    }
+
+    /// nil for a code from a newer build.
+    public var event: BreadcrumbEvent? { BreadcrumbEvent(code: code, a: a, b: b) }
+}
+
+/// The session's breadcrumb ring. Descriptor and sequence live in C, async-signal-safe.
+public enum Breadcrumbs {
+    public static let capacity = Int(EIKON_BREADCRUMB_SLOTS)
+    static let slotSize = Int(EIKON_BREADCRUMB_SLOT_SIZE)
+
+    /// Creates or truncates the ring for a new session.
+    public static func open(at url: URL) throws {
+        let result = url.path.withCString { eikon_breadcrumbs_open($0) }
+        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
+    }
+
+    public static func append(_ event: BreadcrumbEvent) {
+        let (code, a, b) = event.encoded
+        eikon_breadcrumbs_append(code, a, b)
+    }
+
+    public static func close() {
+        eikon_breadcrumbs_close()
+    }
+
+    /// Valid slots only, sorted by seq: empty, torn and truncated slots are skipped.
+    public static func read(from url: URL) -> [Breadcrumb] {
+        guard let data = try? Data(contentsOf: url) else { return [] }
+        var result: [Breadcrumb] = []
+        for index in 0..<(data.count / slotSize) {
+            let slot = data.subdata(in: (index * slotSize)..<((index + 1) * slotSize))
+            guard let seq = slot.uint64LE(at: 0), seq != 0, let check = slot.uint64LE(at: 40),
+                  check == fnv1a64(slot.prefix(40)), let time = slot.uint64LE(at: 8), let a = slot.uint64LE(at: 16),
+                  let b = slot.uint64LE(at: 24), let code = slot.uint16LE(at: 32) else { continue }
+            result.append(Breadcrumb(seq: seq, time: Date(timeIntervalSince1970: Double(Int64(bitPattern: time)) / 1000),
+                                     code: code, a: Int64(bitPattern: a), b: Int64(bitPattern: b)))
+        }
+        return result.sorted { $0.seq < $1.seq }
+    }
+
+    /// Must match the C writer's check word.
+    private static func fnv1a64(_ bytes: Data) -> UInt64 {
+        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Sessions/CrashHistory.swift b/Packages/EikonCore/Sources/EikonCore/Sessions/CrashHistory.swift
new file mode 100644
index 0000000..9a09860
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Sessions/CrashHistory.swift
@@ -0,0 +1,78 @@
+import Foundation
+
+/// One unclean session, kept so a report can be filed later.
+public struct CrashEntry: Codable, Sendable, Equatable, Identifiable {
+    /// The session id.
+    public var id: UUID
+    public var record: SessionRecord
+    public var outcome: SessionOutcome
+    public var breadcrumbs: [Breadcrumb]
+    public var fault: FaultRecord?
+    public var recordedAt: Date
+
+    public init(id: UUID, record: SessionRecord, outcome: SessionOutcome, breadcrumbs: [Breadcrumb],
+                fault: FaultRecord?, recordedAt: Date) {
+        self.id = id
+        self.record = record
+        self.outcome = outcome
+        self.breadcrumbs = breadcrumbs
+        self.fault = fault
+        self.recordedAt = recordedAt
+    }
+}
+
+private struct HistoryDocument: PersistedDocument {
+    static let currentFormat = 1
+    var entries: TolerantList<CrashEntry>
+}
+
+/// `history.json`: the newest `limitPerGame` unclean sessions per game. Ids, codes and
+/// integers only. A file from a newer build is never rewritten.
+public final class CrashHistory: @unchecked Sendable {
+    public static let limitPerGame = 5
+
+    private let file: PersistedFile<HistoryDocument>
+    private let lock = NSLock()
+    private var document: HistoryDocument
+    private var readOnly: Bool
+
+    public init(directory: URL) {
+        file = PersistedFile(url: directory.appendingPathComponent("history.json"))
+        let loaded = try? file.load()
+        document = loaded?.document ?? HistoryDocument(entries: TolerantList())
+        readOnly = loaded?.isReadOnly ?? false
+    }
+
+    /// Classifies, stores, trims the game's entries to the newest `limitPerGame`, persists.
+    @discardableResult
+    public func add(_ consumed: ConsumedSession, now: Date) -> CrashEntry {
+        let entry = CrashEntry(id: consumed.record.sessionID, record: consumed.record,
+                               outcome: SessionOutcome.classify(consumed), breadcrumbs: consumed.breadcrumbs,
+                               fault: consumed.fault, recordedAt: now)
+        lock.withLock {
+            var elements = document.entries.elements.filter { $0.id != entry.id }
+            elements.append(entry)
+            let game = entry.record.gameID
+            let keep = Set(Self.newestFirst(elements.filter { $0.record.gameID == game }).prefix(Self.limitPerGame).map(\.id))
+            elements.removeAll { $0.record.gameID == game && !keep.contains($0.id) }
+            document.entries.elements = elements
+            if !readOnly { try? file.save(document) }
+        }
+        return entry
+    }
+
+    /// Newest first.
+    public func entries(for game: GameID) -> [CrashEntry] {
+        lock.withLock { Self.newestFirst(document.entries.elements.filter { $0.record.gameID == game }) }
+    }
+
+    public func entry(id: UUID) -> CrashEntry? {
+        lock.withLock { document.entries.elements.first { $0.id == id } }
+    }
+
+    private static func newestFirst(_ entries: [CrashEntry]) -> [CrashEntry] {
+        entries.sorted {
+            ($0.record.startedAt, $0.recordedAt) > ($1.record.startedAt, $1.recordedAt)
+        }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Sessions/CrashIssue.swift b/Packages/EikonCore/Sources/EikonCore/Sessions/CrashIssue.swift
new file mode 100644
index 0000000..fb5db07
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Sessions/CrashIssue.swift
@@ -0,0 +1,97 @@
+import Foundation
+
+/// Builds a prefilled GitHub issue URL. Takes no title, folder name, fingerprint or hash:
+/// the game appears only as its report id.
+public enum CrashIssue {
+    public static let maxURLLength = 7_500
+    /// The last N breadcrumbs considered before length trimming.
+    public static let maxBreadcrumbs = 20
+
+    /// Device facts as codes, filled by the app from its device report.
+    public struct Device: Sendable, Equatable {
+        public var appVersion, appBuild, appCommit: String
+        public var modelIdentifier, osVersion, osBuild: String
+        public var installMethod: String
+        public var jitUsable: Bool
+        public var jitSource: String?
+        public var jitReasonCode: String?
+
+        public init(appVersion: String, appBuild: String, appCommit: String, modelIdentifier: String,
+                    osVersion: String, osBuild: String, installMethod: String, jitUsable: Bool,
+                    jitSource: String?, jitReasonCode: String?) {
+            self.appVersion = appVersion
+            self.appBuild = appBuild
+            self.appCommit = appCommit
+            self.modelIdentifier = modelIdentifier
+            self.osVersion = osVersion
+            self.osBuild = osBuild
+            self.installMethod = installMethod
+            self.jitUsable = jitUsable
+            self.jitSource = jitSource
+            self.jitReasonCode = jitReasonCode
+        }
+    }
+
+    public struct Built: Sendable, Equatable {
+        public var url: URL
+        /// Dropped to fit the length limit; above zero the caller offers the clipboard report.
+        public var droppedBreadcrumbs: Int
+    }
+
+    /// The first 8 characters of the game's random UUID, lowercased.
+    public static func reportID(for game: GameID) -> String {
+        game.reportID
+    }
+
+    public static func url(repository: URL, entry: CrashEntry, device: Device, reportID: String) -> Built {
+        var crumbs = Array(entry.breadcrumbs.sorted { $0.seq < $1.seq }.suffix(maxBreadcrumbs))
+        var dropped = 0
+        while true {
+            let url = build(repository: repository, entry: entry, device: device, reportID: reportID, crumbs: crumbs)
+            if url.absoluteString.count <= maxURLLength || crumbs.isEmpty {
+                return Built(url: url, droppedBreadcrumbs: dropped)
+            }
+            crumbs.removeFirst()
+            dropped += 1
+        }
+    }
+
+    private static func build(repository: URL, entry: CrashEntry, device: Device, reportID: String,
+                              crumbs: [Breadcrumb]) -> URL {
+        let record = entry.record
+        let start = record.startedAt
+        var fields: [(String, String)] = [
+            ("template", "crash.yml"),
+            ("labels", "crash"),
+            ("title", "Crash: \(entry.outcome.code), \(record.engine.rawValue), \(record.route)"),
+            ("outcome", entry.outcome.code),
+            ("engine", record.engine.rawValue),
+            ("arch", record.architecture?.rawValue ?? ""),
+            ("route", record.route),
+            ("game", reportID),
+            ("app", "\(device.appVersion) (\(device.appBuild)) \(device.appCommit)"),
+            ("device", "\(device.modelIdentifier), \(device.osVersion) (\(device.osBuild))"),
+            ("install", device.installMethod),
+            ("jit", "usable=\(device.jitUsable) source=\(device.jitSource ?? "-") reason=\(device.jitReasonCode ?? "-")"),
+        ]
+        if let fault = entry.fault {
+            fields.append(("fault", "signal \(fault.signal) pc 0x\(String(fault.pc, radix: 16))"))
+        }
+        fields.append(("breadcrumbs", crumbs.map { crumb in
+            let millis = Int64((crumb.time.timeIntervalSince(start) * 1000).rounded())
+            return "\(crumb.seq) +\(millis)ms \(crumb.code) \(crumb.a) \(crumb.b)"
+        }.joined(separator: "\n")))
+
+        var components = URLComponents(url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
+        components.percentEncodedQuery = fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
+        return components.url!
+    }
+
+    /// RFC 3986 unreserved characters only; everything else, `+` included, is encoded.
+    private static let unreserved = CharacterSet(charactersIn:
+        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
+
+    private static func encode(_ text: String) -> String {
+        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Sessions/FaultRecord.swift b/Packages/EikonCore/Sources/EikonCore/Sessions/FaultRecord.swift
new file mode 100644
index 0000000..1047f9c
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Sessions/FaultRecord.swift
@@ -0,0 +1,44 @@
+import CEikonSession
+import Foundation
+
+/// A fault a runtime recorded from its own fault path. 02 installs no signal handler.
+public struct FaultRecord: Codable, Sendable, Equatable {
+    public var signal: Int32
+    public var pc: UInt64
+    public var address: UInt64
+
+    public init(signal: Int32, pc: UInt64, address: UInt64) {
+        self.signal = signal
+        self.pc = pc
+        self.address = address
+    }
+
+    /// The first (originating) record, or nil when the file is missing, malformed, or
+    /// belongs to another session.
+    public static func read(from url: URL, sessionID: UUID) -> FaultRecord? {
+        let header = Int(EIKON_FAULT_HEADER_SIZE), size = Int(EIKON_FAULT_RECORD_SIZE)
+        guard let data = try? Data(contentsOf: url), data.count >= header + size,
+              data.hasBytes(Array(EIKON_FAULT_MAGIC.utf8)), data.uint32LE(at: 4) == UInt32(EIKON_FAULT_VERSION),
+              data.subdata(in: 8..<24) == sessionID.bytes,
+              let signal = data.uint32LE(at: header), let pc = data.uint64LE(at: header + 8),
+              let address = data.uint64LE(at: header + 16) else { return nil }
+        return FaultRecord(signal: Int32(bitPattern: signal), pc: pc, address: address)
+    }
+
+    /// Opens the fault file ahead of time for this session (truncating any old one).
+    public static func open(at url: URL, sessionID: UUID) throws {
+        let bytes = Array(sessionID.bytes)
+        let result = url.path.withCString { path in bytes.withUnsafeBufferPointer { eikon_session_fault_open(path, $0.baseAddress) } }
+        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
+    }
+
+    public static func close() {
+        eikon_session_fault_close()
+    }
+}
+
+extension UUID {
+    var bytes: Data {
+        withUnsafeBytes(of: uuid) { Data($0) }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Sessions/SessionOutcome.swift b/Packages/EikonCore/Sources/EikonCore/Sessions/SessionOutcome.swift
new file mode 100644
index 0000000..5aa83b1
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Sessions/SessionOutcome.swift
@@ -0,0 +1,56 @@
+import Foundation
+
+/// How an unclean session most likely ended.
+public enum SessionOutcome: Codable, Sendable, Equatable {
+    case crashed(signal: Int32, pc: UInt64)
+    case likelyMemoryKill
+    /// A crash or a system kill.
+    case endedUnexpectedly
+    case killedInBackground
+
+    /// A memory warning this close to the last breadcrumb points at a memory kill.
+    public static let memoryWarningWindow: TimeInterval = 60
+    /// A last memory sample below this points at a memory kill.
+    public static let lowMemoryThresholdMB: Int64 = 100
+
+    /// Background kills go to history only.
+    public var showsBanner: Bool {
+        switch self {
+        case .crashed, .likelyMemoryKill, .endedUnexpectedly: true
+        case .killedInBackground: false
+        }
+    }
+
+    /// A stable identifier for issue text and history.
+    public var code: String {
+        switch self {
+        case .crashed: "crashed"
+        case .likelyMemoryKill: "likelyMemoryKill"
+        case .endedUnexpectedly: "endedUnexpectedly"
+        case .killedInBackground: "killedInBackground"
+        }
+    }
+
+    /// Background first; then a fault, memory evidence, or nothing.
+    public static func classify(_ consumed: ConsumedSession) -> SessionOutcome {
+        switch consumed.record.phase {
+        case .background:
+            return .killedInBackground
+        case .running:
+            if let fault = consumed.fault { return .crashed(signal: fault.signal, pc: fault.pc) }
+            let crumbs = consumed.breadcrumbs.sorted { $0.seq < $1.seq }
+            if let last = crumbs.last,
+               let warning = crumbs.last(where: { $0.event == .memoryWarning }),
+               last.time.timeIntervalSince(warning.time) <= memoryWarningWindow {
+                return .likelyMemoryKill
+            }
+            if case .memorySample(let available)? = crumbs.last(where: {
+                if case .memorySample = $0.event { return true }
+                return false
+            })?.event, available < lowMemoryThresholdMB {
+                return .likelyMemoryKill
+            }
+            return .endedUnexpectedly
+        }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Sessions/SessionRecord.swift b/Packages/EikonCore/Sources/EikonCore/Sessions/SessionRecord.swift
new file mode 100644
index 0000000..a4a5dd5
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Sessions/SessionRecord.swift
@@ -0,0 +1,54 @@
+import Foundation
+
+/// What was running when a session started. Codes and ids only, never a title.
+public struct SessionRecord: Codable, Sendable, Equatable {
+    public enum Phase: String, Codable, Sendable {
+        case running, background
+
+        /// An unknown phase reads as `running`: the conservative choice that still reports.
+        public init(from decoder: any Decoder) throws {
+            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .running
+        }
+    }
+
+    /// The route recorded for developer test sessions.
+    public static let testRoute = "test"
+
+    public var sessionID: UUID
+    public var gameID: GameID
+    public var engine: Engine
+    public var architecture: CPUArchitecture?
+    /// A `RouteID` raw value, or `testRoute`; possibly a route from a newer build.
+    public var route: String
+    public var appBuild: String
+    public var startedAt: Date
+    public var phase: Phase
+
+    public init(sessionID: UUID = UUID(), gameID: GameID, engine: Engine, architecture: CPUArchitecture?,
+                route: String, appBuild: String, startedAt: Date, phase: Phase = .running) {
+        self.sessionID = sessionID
+        self.gameID = gameID
+        self.engine = engine
+        self.architecture = architecture
+        self.route = route
+        self.appBuild = appBuild
+        self.startedAt = startedAt
+        self.phase = phase
+    }
+
+    private enum CodingKeys: String, CodingKey {
+        case sessionID, gameID, engine, architecture, route, appBuild, startedAt, phase
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        sessionID = try container.decode(UUID.self, forKey: .sessionID)
+        gameID = try container.decode(GameID.self, forKey: .gameID)
+        engine = (try? container.decode(Engine.self, forKey: .engine)) ?? .unknown
+        architecture = try? container.decodeIfPresent(CPUArchitecture.self, forKey: .architecture)
+        route = (try? container.decode(String.self, forKey: .route)) ?? ""
+        appBuild = (try? container.decode(String.self, forKey: .appBuild)) ?? ""
+        startedAt = try container.decode(Date.self, forKey: .startedAt)
+        phase = (try? container.decode(Phase.self, forKey: .phase)) ?? .running
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Sessions/SessionSentinel.swift b/Packages/EikonCore/Sources/EikonCore/Sessions/SessionSentinel.swift
new file mode 100644
index 0000000..c0e44e7
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Sessions/SessionSentinel.swift
@@ -0,0 +1,75 @@
+import Darwin
+import Foundation
+
+/// What the previous launch left behind when its session didn't end cleanly.
+public struct ConsumedSession: Sendable, Equatable {
+    public var record: SessionRecord
+    /// Sorted by seq.
+    public var breadcrumbs: [Breadcrumb]
+    /// Only when its header names `record.sessionID`.
+    public var fault: FaultRecord?
+
+    public init(record: SessionRecord, breadcrumbs: [Breadcrumb], fault: FaultRecord?) {
+        self.record = record
+        self.breadcrumbs = breadcrumbs
+        self.fault = fault
+    }
+}
+
+/// `sentinel.json` exists while a game runs; finding it at launch means the session
+/// didn't end cleanly. Writes are atomic and fsynced, so the phase survives a kill.
+public struct SessionSentinel: Sendable {
+    public let directory: URL
+
+    public init(directory: URL) {
+        self.directory = directory
+    }
+
+    public var sentinelURL: URL { directory.appendingPathComponent("sentinel.json") }
+    public var breadcrumbsURL: URL { directory.appendingPathComponent("breadcrumbs.bin") }
+    public var faultURL: URL { directory.appendingPathComponent("fault.bin") }
+
+    /// Also clears an earlier session's breadcrumbs and fault file, so nothing stale is
+    /// attributed to this one.
+    public func arm(_ record: SessionRecord) throws {
+        removeEvidence()
+        try write(record)
+    }
+
+    public func setPhase(_ phase: SessionRecord.Phase) throws {
+        guard var record = readRecord() else { return }
+        record.phase = phase
+        try write(record)
+    }
+
+    /// A clean end: removes the sentinel, breadcrumbs and fault file.
+    public func disarm() {
+        remove(sentinelURL)
+        removeEvidence()
+    }
+
+    /// The previous session, when its sentinel is still here. Always removes all three files.
+    public func consumeAtLaunch() -> ConsumedSession? {
+        defer { disarm() }
+        guard FileManager.default.fileExists(atPath: sentinelURL.path), let record = readRecord() else { return nil }
+        return ConsumedSession(record: record, breadcrumbs: Breadcrumbs.read(from: breadcrumbsURL),
+                               fault: FaultRecord.read(from: faultURL, sessionID: record.sessionID))
+    }
+
+    private func write(_ record: SessionRecord) throws {
+        try Persisted.writeAtomically(try JSONEncoder().encode(record), to: sentinelURL)
+    }
+
+    private func readRecord() -> SessionRecord? {
+        (try? Data(contentsOf: sentinelURL)).flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }
+    }
+
+    private func removeEvidence() {
+        remove(breadcrumbsURL)
+        remove(faultURL)
+    }
+
+    private func remove(_ url: URL) {
+        url.path.withCString { _ = unlink($0) }
+    }
+}
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/SessionTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/SessionTests.swift
new file mode 100644
index 0000000..6f2924d
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/SessionTests.swift
@@ -0,0 +1,244 @@
+import CEikonSession
+import Foundation
+import Testing
+import EikonCore
+
+// MARK: Helpers
+
+private func withTempDir(_ body: (URL) throws -> Void) throws {
+    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
+    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
+    defer { try? FileManager.default.removeItem(at: dir) }
+    try body(dir)
+}
+
+private func record(game: GameID = GameID(uuid: UUID()), startedAt: Date = Date(),
+                    phase: SessionRecord.Phase = .running) -> SessionRecord {
+    SessionRecord(gameID: game, engine: .unity, architecture: .amd64, route: "wine-fex", appBuild: "1",
+                  startedAt: startedAt, phase: phase)
+}
+
+private func crumb(_ seq: UInt64, _ event: BreadcrumbEvent, at time: Date) -> Breadcrumb {
+    let encoded: (UInt16, Int64) = switch event {
+    case .memoryWarning: (6, 0)
+    case .memorySample(let mb): (7, mb)
+    case .sessionStart: (1, 0)
+    default: (5, 0)
+    }
+    return Breadcrumb(seq: seq, time: time, code: encoded.0, a: encoded.1, b: 0)
+}
+
+private let device = CrashIssue.Device(appVersion: "0.2", appBuild: "7", appCommit: "abc1234",
+                                       modelIdentifier: "iPad13,1", osVersion: "17.0", osBuild: "21A1",
+                                       installMethod: "trollstore", jitUsable: true, jitSource: "trollstore",
+                                       jitReasonCode: nil)
+private let repository = URL(string: "https://github.com/example/eikon")!
+
+private func entry(game: GameID = GameID(uuid: UUID()), crumbs: Int = 3) -> CrashEntry {
+    let rec = record(game: game)
+    let breadcrumbs = (1...max(crumbs, 1)).prefix(crumbs).map {
+        Breadcrumb(seq: UInt64($0), time: rec.startedAt + Double($0), code: 7, a: Int64($0), b: 0)
+    }
+    return CrashEntry(id: rec.sessionID, record: rec, outcome: .endedUnexpectedly, breadcrumbs: breadcrumbs,
+                      fault: FaultRecord(signal: 11, pc: 0x1000, address: 0), recordedAt: Date())
+}
+
+private func query(_ url: URL) -> [String: String] {
+    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
+    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
+}
+
+// MARK: Tests touching the process-wide C descriptors run one at a time
+
+@Suite(.serialized) struct SessionFileTests {
+    @Test func armThenConsumeReturnsTheRecordOnce() throws {
+        try withTempDir { dir in
+            let sentinel = SessionSentinel(directory: dir), rec = record()
+            try sentinel.arm(rec)
+            #expect(sentinel.consumeAtLaunch()?.record == rec)
+            #expect(sentinel.consumeAtLaunch() == nil)
+        }
+    }
+
+    @Test func disarmLeavesNothingToConsume() throws {
+        try withTempDir { dir in
+            let sentinel = SessionSentinel(directory: dir), rec = record()
+            try sentinel.arm(rec)
+            try Breadcrumbs.open(at: sentinel.breadcrumbsURL)
+            Breadcrumbs.append(.sessionStart)
+            Breadcrumbs.close()
+            try FaultRecord.open(at: sentinel.faultURL, sessionID: rec.sessionID)
+            FaultRecord.close()
+
+            sentinel.disarm()
+            #expect(sentinel.consumeAtLaunch() == nil)
+            #expect(!FileManager.default.fileExists(atPath: sentinel.breadcrumbsURL.path))
+            #expect(!FileManager.default.fileExists(atPath: sentinel.faultURL.path))
+        }
+    }
+
+    enum Evidence: CaseIterable { case fault, memoryWarning, nothing, background }
+
+    @Test(arguments: Evidence.allCases)
+    func outcomeFollowsTheEvidence(evidence: Evidence) throws {
+        try withTempDir { dir in
+            let sentinel = SessionSentinel(directory: dir), rec = record()
+            try sentinel.arm(rec)
+            try Breadcrumbs.open(at: sentinel.breadcrumbsURL)
+            Breadcrumbs.append(.sessionStart)
+            switch evidence {
+            case .fault:
+                try FaultRecord.open(at: sentinel.faultURL, sessionID: rec.sessionID)
+                eikon_session_fault_record(11, 0x4000, 0x10)
+                FaultRecord.close()
+            case .memoryWarning:
+                Breadcrumbs.append(.memoryWarning)
+                Breadcrumbs.append(.sessionPaused)
+            case .nothing:
+                Breadcrumbs.append(.memorySample(availableMB: SessionOutcome.lowMemoryThresholdMB * 10))
+            case .background:
+                try sentinel.setPhase(.background)
+            }
+            Breadcrumbs.close()
+
+            let outcome = SessionOutcome.classify(try #require(sentinel.consumeAtLaunch()))
+            switch evidence {
+            case .fault: #expect(outcome == .crashed(signal: 11, pc: 0x4000))
+            case .memoryWarning: #expect(outcome == .likelyMemoryKill)
+            case .nothing: #expect(outcome == .endedUnexpectedly)
+            case .background: #expect(outcome == .killedInBackground)
+            }
+            #expect(outcome.showsBanner == (evidence != .background))
+        }
+    }
+
+    @Test func ringKeepsTheLastCapacityInOrder() throws {
+        try withTempDir { dir in
+            let url = dir.appendingPathComponent("breadcrumbs.bin")
+            try Breadcrumbs.open(at: url)
+            let total = Breadcrumbs.capacity + 10
+            for index in 0..<total { Breadcrumbs.append(.runtimeError(code: Int64(index))) }
+            Breadcrumbs.close()
+
+            let read = Breadcrumbs.read(from: url)
+            #expect(read.map(\.a) == Array((total - Breadcrumbs.capacity)..<total).map(Int64.init))
+        }
+    }
+
+    @Test func tornSlotIsSkipped() throws {
+        try withTempDir { dir in
+            let url = dir.appendingPathComponent("breadcrumbs.bin")
+            try Breadcrumbs.open(at: url)
+            for index in 0..<4 { Breadcrumbs.append(.runtimeError(code: Int64(index))) }
+            Breadcrumbs.close()
+            let slotSize = Int(EIKON_BREADCRUMB_SLOT_SIZE)
+
+            // Overwrite the first half of slot 2 with the start of slot 3: a torn write.
+            var data = try Data(contentsOf: url)
+            data.replaceSubrange((2 * slotSize)..<(2 * slotSize + slotSize / 2),
+                                 with: data.subdata(in: (3 * slotSize)..<(3 * slotSize + slotSize / 2)))
+            try data.write(to: url)
+
+            let read = Breadcrumbs.read(from: url)
+            #expect(read.count == 3)
+            #expect(!read.map(\.a).contains(1)) // seq 2 held code 1
+        }
+    }
+
+    @Test func faultWrittenThroughTheHookReadsBack() throws {
+        try withTempDir { dir in
+            let url = dir.appendingPathComponent("fault.bin"), session = UUID()
+            try FaultRecord.open(at: url, sessionID: session)
+            eikon_session_fault_record(10, 0xDEAD_BEEF, 0x20)
+            eikon_session_fault_record(11, 0x1234, 0x30)
+            FaultRecord.close()
+
+            let fault = try #require(FaultRecord.read(from: url, sessionID: session))
+            #expect(fault.signal == 10)
+            #expect(fault.pc == 0xDEAD_BEEF)
+            #expect(FaultRecord.read(from: url, sessionID: UUID()) == nil)
+        }
+    }
+}
+
+// MARK: Outcome
+
+@Test func oldMemoryWarningIsNotAMemoryKill() {
+    let start = Date()
+    let late = start + SessionOutcome.memoryWarningWindow + 1
+    let consumed = ConsumedSession(record: record(startedAt: start),
+                                   breadcrumbs: [crumb(1, .memoryWarning, at: start), crumb(2, .sessionStart, at: late)],
+                                   fault: nil)
+    #expect(SessionOutcome.classify(consumed) == .endedUnexpectedly)
+}
+
+// MARK: History
+
+@Test func historyKeepsTheNewestEntriesPerGame() throws {
+    try withTempDir { dir in
+        let history = CrashHistory(directory: dir)
+        let game = GameID(uuid: UUID()), other = GameID(uuid: UUID())
+        let start = Date(timeIntervalSince1970: 1_700_000_000)
+        let crumbs = [crumb(1, .sessionStart, at: start)]
+        history.add(ConsumedSession(record: record(game: other, startedAt: start), breadcrumbs: crumbs, fault: nil),
+                    now: start)
+        var added: [SessionRecord] = []
+        for index in 0..<(CrashHistory.limitPerGame + 2) {
+            let rec = record(game: game, startedAt: start + Double(index))
+            added.append(rec)
+            history.add(ConsumedSession(record: rec, breadcrumbs: crumbs, fault: nil), now: start + Double(index))
+        }
+
+        let reopened = CrashHistory(directory: dir)
+        let kept = reopened.entries(for: game)
+        #expect(kept.map(\.record) == Array(added.suffix(CrashHistory.limitPerGame).reversed()))
+        #expect(kept.allSatisfy { $0.breadcrumbs == crumbs })
+        #expect(reopened.entries(for: other).count == 1)
+    }
+}
+
+// MARK: Issue URL
+
+@Test func issueQueryParsesBackToTheFields() {
+    let crash = entry()
+    let built = CrashIssue.url(repository: repository, entry: crash, device: device,
+                               reportID: CrashIssue.reportID(for: crash.record.gameID))
+    let fields = query(built.url)
+    #expect(fields["outcome"] == crash.outcome.code)
+    #expect(fields["engine"] == crash.record.engine.rawValue)
+    #expect(fields["route"] == crash.record.route)
+    #expect(fields["game"] == CrashIssue.reportID(for: crash.record.gameID))
+    #expect(fields["install"] == device.installMethod)
+    #expect(fields["fault"]?.isEmpty == false)
+    #expect(built.droppedBreadcrumbs == 0)
+}
+
+@Test func reservedCharactersRoundTrip() {
+    var crash = entry()
+    crash.record.route = "a+b & c=d"
+    let built = CrashIssue.url(repository: repository, entry: crash, device: device, reportID: "r+e&p=o t")
+    let fields = query(built.url)
+    #expect(fields["route"] == "a+b & c=d")
+    #expect(fields["game"] == "r+e&p=o t")
+}
+
+@Test func longBreadcrumbListsDropTheOldestToFit() {
+    var crash = entry(crumbs: 200)
+    crash.breadcrumbs = crash.breadcrumbs.map { var c = $0; c.a = .max; c.b = .min; return c }
+    let built = CrashIssue.url(repository: repository, entry: crash, device: device, reportID: "abcd1234")
+    #expect(built.url.absoluteString.count <= CrashIssue.maxURLLength)
+    let lines = query(built.url)["breadcrumbs"]?.split(separator: "\n") ?? []
+    let newest = crash.breadcrumbs.max { $0.seq < $1.seq }!
+    #expect(lines.last?.hasPrefix("\(newest.seq) ") == true)
+}
+
+@Test func issueCarriesTheReportIDAndNoFingerprintOrFullID() {
+    let game = GameID(uuid: UUID())
+    let crash = entry(game: game)
+    let fingerprintLike = String(repeating: "9f3c", count: 16)
+    let url = CrashIssue.url(repository: repository, entry: crash, device: device,
+                             reportID: CrashIssue.reportID(for: game)).url.absoluteString.lowercased()
+    #expect(url.contains(CrashIssue.reportID(for: game)))
+    #expect(!url.contains(fingerprintLike))
+    #expect(!url.contains(game.uuid.uuidString.lowercased()))
+}

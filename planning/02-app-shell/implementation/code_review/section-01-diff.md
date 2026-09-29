diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
index 9150c5c..c5e245b 100644
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -61,6 +61,8 @@ jobs:
         run: |
           brew list --formula ldid >/dev/null 2>&1 && brew uninstall --ignore-dependencies ldid || true
           brew install xcodegen ldid-procursus dpkg uv
+      - name: Core tests
+        run: make test-core
       - name: Build, package and verify
         run: make test-swift archive package verify
       - name: Upload artifacts
diff --git a/Makefile b/Makefile
index 5e22ff4..60d83de 100644
--- a/Makefile
+++ b/Makefile
@@ -8,12 +8,13 @@ SHELL := /bin/bash
 stub = echo "$@: not implemented yet (section $(1))" >&2; exit 1
 
 .PHONY: help doctor bootstrap version generated project check \
-	test test-swift test-scripts archive ipa deb package verify all \
+	test test-core test-swift test-scripts scan-collection archive ipa deb package verify all \
 	publish fetch-deps verify-deps pin-dep clean
 
 help:
-	@echo "Targets: doctor bootstrap version generated project check test test-swift"
-	@echo "         test-scripts archive ipa deb package verify all publish"
+	@echo "Targets: doctor bootstrap version generated project check test test-core"
+	@echo "         test-swift test-scripts scan-collection [ARGS=<args>] archive ipa deb"
+	@echo "         package verify all publish"
 	@echo "         fetch-deps verify-deps pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>] clean"
 
 doctor:
@@ -41,7 +42,11 @@ check:
 	@uv run scripts/deps.py check
 	@scripts/version.sh --check
 
-test: test-swift test-scripts
+test: test-core test-swift test-scripts
+
+# EikonCore on the Mac; needs no project.
+test-core:
+	@swift test --package-path Packages/EikonCore
 
 test-swift: project
 	@scripts/test_swift.sh
@@ -49,6 +54,10 @@ test-swift: project
 test-scripts:
 	@uv run pytest tests/
 
+# Detection over a games folder. Writes nothing into the repo.
+scan-collection:
+	@swift run --package-path Packages/EikonCore -c release eikon-scan --per-folder $(ARGS)
+
 archive:
 	@scripts/archive.sh
 
diff --git a/Packages/EikonCore/Package.swift b/Packages/EikonCore/Package.swift
new file mode 100644
index 0000000..c47938d
--- /dev/null
+++ b/Packages/EikonCore/Package.swift
@@ -0,0 +1,18 @@
+// swift-tools-version:6.0
+import PackageDescription
+
+let package = Package(
+    name: "EikonCore",
+    platforms: [.iOS(.v15), .macOS(.v13)],
+    products: [
+        .library(name: "EikonCore", targets: ["EikonCore"]),
+        .executable(name: "eikon-scan", targets: ["eikon-scan"]),
+    ],
+    targets: [
+        .target(name: "CEikonSession"),
+        .target(name: "EikonCore", dependencies: ["CEikonSession"], linkerSettings: [.linkedLibrary("z")]),
+        .executableTarget(name: "eikon-scan", dependencies: ["EikonCore"]),
+        .testTarget(name: "EikonCoreTests", dependencies: ["EikonCore", "CEikonSession"]),
+    ],
+    swiftLanguageModes: [.v6]
+)
diff --git a/Packages/EikonCore/Sources/CEikonSession/CEikonSession.c b/Packages/EikonCore/Sources/CEikonSession/CEikonSession.c
new file mode 100644
index 0000000..fcf918f
--- /dev/null
+++ b/Packages/EikonCore/Sources/CEikonSession/CEikonSession.c
@@ -0,0 +1,145 @@
+#include "CEikonSession.h"
+
+#include <errno.h>
+#include <fcntl.h>
+#include <stdatomic.h>
+#include <stdlib.h>
+#include <unistd.h>
+
+/* Everything below the render gate may run on a fault path: no malloc, no locks, no stdio. */
+
+/* ---- Render gate ---- */
+
+struct eikon_render_gate {
+    _Atomic int32_t in_flight;
+    _Atomic bool closed;
+};
+
+eikon_render_gate *eikon_render_gate_create(void) {
+    eikon_render_gate *gate = malloc(sizeof *gate);
+    if (gate == NULL) return NULL;
+    atomic_init(&gate->in_flight, 0);
+    atomic_init(&gate->closed, false);
+    return gate;
+}
+
+void eikon_render_gate_destroy(eikon_render_gate *gate) {
+    free(gate);
+}
+
+bool eikon_render_gate_enter(eikon_render_gate *gate) {
+    /* Count first, then look: a closer that saw in_flight == 0 after closing cannot miss us. */
+    atomic_fetch_add(&gate->in_flight, 1);
+    if (atomic_load(&gate->closed)) {
+        atomic_fetch_sub(&gate->in_flight, 1);
+        return false;
+    }
+    return true;
+}
+
+void eikon_render_gate_leave(eikon_render_gate *gate) {
+    atomic_fetch_sub(&gate->in_flight, 1);
+}
+
+void eikon_render_gate_set_closed(eikon_render_gate *gate, bool closed) {
+    atomic_store(&gate->closed, closed);
+}
+
+int32_t eikon_render_gate_in_flight(const eikon_render_gate *gate) {
+    return atomic_load(&gate->in_flight);
+}
+
+/* ---- Little-endian encoding ---- */
+
+static void put_le(uint8_t *out, uint64_t value, int bytes) {
+    for (int i = 0; i < bytes; i++) out[i] = (uint8_t)(value >> (8 * i));
+}
+
+static uint64_t fnv1a64(const uint8_t *bytes, int count) {
+    uint64_t hash = 0xcbf29ce484222325ull;
+    for (int i = 0; i < count; i++) {
+        hash ^= bytes[i];
+        hash *= 0x100000001b3ull;
+    }
+    return hash;
+}
+
+/* ---- Breadcrumbs ---- */
+
+int eikon_breadcrumb_write(int fd, uint64_t seq, int64_t time,
+                           uint16_t event, int64_t a, int64_t b) {
+    uint8_t slot[EIKON_BREADCRUMB_SLOT_SIZE] = {0};
+    put_le(slot + 0, seq, 8);
+    put_le(slot + 8, (uint64_t)time, 8);
+    put_le(slot + 16, (uint64_t)a, 8);
+    put_le(slot + 24, (uint64_t)b, 8);
+    put_le(slot + 32, event, 2);
+    put_le(slot + 40, fnv1a64(slot, 40), 8);
+
+    off_t offset = (off_t)(seq % EIKON_BREADCRUMB_SLOTS) * EIKON_BREADCRUMB_SLOT_SIZE;
+    ssize_t written;
+    do {
+        written = pwrite(fd, slot, sizeof slot, offset);
+    } while (written < 0 && errno == EINTR);
+    if (written < 0) return errno;
+    return written == (ssize_t)sizeof slot ? 0 : EIO;
+}
+
+/* ---- Fault hook ---- */
+
+static _Atomic int fault_fd = -1;
+
+static int write_all(int fd, const uint8_t *bytes, size_t count) {
+    while (count > 0) {
+        ssize_t written = write(fd, bytes, count);
+        if (written < 0) {
+            if (errno == EINTR) continue;
+            return errno;
+        }
+        if (written == 0) return EIO;
+        bytes += written;
+        count -= (size_t)written;
+    }
+    return 0;
+}
+
+int eikon_session_fault_open(const char *path, const uint8_t session_id[16]) {
+    eikon_session_fault_close();
+
+    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
+    if (fd < 0) return errno;
+
+    uint8_t header[EIKON_FAULT_HEADER_SIZE];
+    for (int i = 0; i < 4; i++) header[i] = (uint8_t)EIKON_FAULT_MAGIC[i];
+    put_le(header + 4, EIKON_FAULT_VERSION, 4);
+    for (int i = 0; i < 16; i++) header[8 + i] = session_id[i];
+
+    int error = write_all(fd, header, sizeof header);
+    if (error != 0) {
+        close(fd);
+        return error;
+    }
+    atomic_store(&fault_fd, fd);
+    return 0;
+}
+
+void eikon_session_fault_record(int signal, uintptr_t pc, uintptr_t address) {
+    int fd = atomic_load(&fault_fd);
+    if (fd < 0) return;
+
+    int saved_errno = errno;
+    uint8_t record[EIKON_FAULT_RECORD_SIZE] = {0};
+    put_le(record + 0, (uint32_t)signal, 4);
+    put_le(record + 8, (uint64_t)pc, 8);
+    put_le(record + 16, (uint64_t)address, 8);
+    ssize_t written;
+    do {
+        written = write(fd, record, sizeof record);
+    } while (written < 0 && errno == EINTR);
+    errno = saved_errno;
+}
+
+void eikon_session_fault_close(void) {
+    int fd = atomic_exchange(&fault_fd, -1);
+    if (fd >= 0) close(fd);
+}
diff --git a/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h b/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
new file mode 100644
index 0000000..b424846
--- /dev/null
+++ b/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
@@ -0,0 +1,73 @@
+#ifndef CEIKONSESSION_H
+#define CEIKONSESSION_H
+
+#include <stdbool.h>
+#include <stdint.h>
+
+/* ---- Render gate (in-flight guard) ------------------------------------------------------
+   A render thread calls enter before encoding a frame and leave after committing it. The
+   host closes the gate, then waits for in_flight to reach 0. enter increments before it
+   reads the closed flag, so a frame that is entering is never missed. */
+
+typedef struct eikon_render_gate eikon_render_gate; /* opaque; defined in the .c */
+
+eikon_render_gate *eikon_render_gate_create(void);     /* starts open, in-flight 0; NULL on OOM */
+void eikon_render_gate_destroy(eikon_render_gate *gate);
+bool eikon_render_gate_enter(eikon_render_gate *gate); /* false when closed; frame is skipped */
+void eikon_render_gate_leave(eikon_render_gate *gate);
+void eikon_render_gate_set_closed(eikon_render_gate *gate, bool closed);
+int32_t eikon_render_gate_in_flight(const eikon_render_gate *gate);
+
+/* ---- Breadcrumb slot writer --------------------------------------------------------------
+   A ring of EIKON_BREADCRUMB_SLOTS fixed slots. Event seq goes to slot seq % SLOTS.
+   Slot layout, all little-endian:
+     0   uint64 seq
+     8   int64  time
+     16  int64  a
+     24  int64  b
+     32  uint16 event
+     34  6 bytes, zero
+     40  uint64 check: FNV-1a 64 over bytes 0..<40
+   A slot whose check does not match is torn or empty and must be ignored. */
+
+#define EIKON_BREADCRUMB_SLOTS 64
+/* Size in bytes of one fixed slot; the Swift reader uses the same constant. */
+#define EIKON_BREADCRUMB_SLOT_SIZE 48
+
+/* One pwrite of a full slot at offset (seq % EIKON_BREADCRUMB_SLOTS) * SLOT_SIZE.
+   Async-signal-safe. No fsync. Returns 0 or errno. */
+int eikon_breadcrumb_write(int fd, uint64_t seq, int64_t time,
+                           uint16_t event, int64_t a, int64_t b);
+
+/* ---- Fault hook ---------------------------------------------------------------------------
+   Nothing here installs a signal handler. FEX and Wine use SIGSEGV/SIGBUS in normal operation.
+   The hook is for later runtimes to call from their own fault paths, only for faults they
+   really cannot handle.
+
+   File layout, all little-endian:
+     header  0  4 bytes magic "EKFT"
+             4  uint32 layout version (EIKON_FAULT_VERSION)
+             8  16 bytes session id
+     then zero or more records of EIKON_FAULT_RECORD_SIZE bytes:
+             0  int32  signal
+             4  4 bytes, zero
+             8  uint64 pc
+             16 uint64 address */
+
+#define EIKON_FAULT_MAGIC "EKFT"
+#define EIKON_FAULT_VERSION 1
+#define EIKON_FAULT_HEADER_SIZE 24
+#define EIKON_FAULT_RECORD_SIZE 24
+
+/* Opens (creates/truncates) the fault file ahead of time and writes a header
+   carrying the 16-byte session id. Keeps the fd in a static. Returns 0 or errno. */
+int eikon_session_fault_open(const char *path, const uint8_t session_id[16]);
+
+/* One write(2) of a fixed-size record {signal, pc, address}. Async-signal-safe.
+   No-op when no file is open. */
+void eikon_session_fault_record(int signal, uintptr_t pc, uintptr_t address);
+
+/* Closes the fd, if open. Called when a session ends. */
+void eikon_session_fault_close(void);
+
+#endif /* CEIKONSESSION_H */
diff --git a/Packages/EikonCore/Sources/EikonCore/Library/Persisted.swift b/Packages/EikonCore/Sources/EikonCore/Library/Persisted.swift
new file mode 100644
index 0000000..89cf94c
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Library/Persisted.swift
@@ -0,0 +1,213 @@
+import Darwin
+import Foundation
+
+/// Rules shared by every JSON file under Library/Application Support/Eikon/: a top-level
+/// integer `format`, atomic replacement, newer formats read-only, tolerant collections.
+public enum Persisted {
+    /// Atomic replace: temp file in the same directory, fsync, rename, fsync the directory.
+    public static func writeAtomically(_ data: Data, to url: URL) throws {
+        let directory = url.deletingLastPathComponent()
+        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
+        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
+
+        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644) }
+        guard fd >= 0 else { throw posixError(errno) }
+        do {
+            defer { close(fd) }
+            try writeAll(fd, data)
+            guard fsync(fd) == 0 else { throw posixError(errno) }
+        } catch {
+            temporary.path.withCString { _ = unlink($0) }
+            throw error
+        }
+
+        let renamed = temporary.path.withCString { from in url.path.withCString { to in rename(from, to) } }
+        guard renamed == 0 else {
+            let code = errno
+            temporary.path.withCString { _ = unlink($0) }
+            throw posixError(code)
+        }
+        syncDirectory(directory)
+    }
+
+    /// The top-level `format` integer, or nil if the data isn't a JSON object with one.
+    public static func format(of data: Data) -> Int? {
+        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
+        return object?["format"] as? Int
+    }
+
+    /// Also flush the directory entry, so the rename survives power loss.
+    /// Best effort: process death alone never loses the file.
+    private static func syncDirectory(_ directory: URL) {
+        let dirFD = directory.path.withCString { open($0, O_RDONLY) }
+        guard dirFD >= 0 else { return }
+        _ = fsync(dirFD)
+        close(dirFD)
+    }
+
+    private static func writeAll(_ fd: Int32, _ data: Data) throws {
+        var remaining = data[...]
+        while !remaining.isEmpty {
+            let written = remaining.withUnsafeBytes { buffer -> Int in
+                guard let base = buffer.baseAddress else { return 0 }
+                return write(fd, base, buffer.count)
+            }
+            if written < 0 {
+                if errno == EINTR { continue }
+                throw posixError(errno)
+            }
+            if written == 0 { throw POSIXError(.EIO) }
+            remaining = remaining.dropFirst(written)
+        }
+    }
+}
+
+/// A document type stored under the persisted-file rules. `PersistedFile` writes the
+/// top-level `format` itself, so the document need not encode one.
+public protocol PersistedDocument: Codable, Sendable {
+    static var currentFormat: Int { get }
+}
+
+public enum PersistedError: Error, Sendable {
+    /// The file on disk has a newer format than this build knows; it is never rewritten.
+    case readOnly
+}
+
+/// A file-backed document. A file with a newer format loads as read-only, and saving
+/// over it never touches the disk.
+public struct PersistedFile<Document: PersistedDocument>: Sendable {
+    public struct Loaded: Sendable {
+        public var document: Document
+        /// The file came from a newer build; callers keep working in memory or fork.
+        public var isReadOnly: Bool
+    }
+
+    public let url: URL
+
+    public init(url: URL) {
+        self.url = url
+    }
+
+    /// nil when the file doesn't exist.
+    public func load() throws -> Loaded? {
+        guard let data = try existingData() else { return nil }
+        let document = try JSONDecoder().decode(Document.self, from: data)
+        return Loaded(document: document, isReadOnly: isNewer(data))
+    }
+
+    /// Throws `PersistedError.readOnly`, without writing, when the file on disk is newer.
+    public func save(_ document: Document) throws {
+        if let existing = try existingData(), isNewer(existing) {
+            throw PersistedError.readOnly
+        }
+        let data = try JSONEncoder().encode(Stamped(document: document, format: Document.currentFormat))
+        try Persisted.writeAtomically(data, to: url)
+    }
+
+    private func isNewer(_ data: Data) -> Bool {
+        (Persisted.format(of: data) ?? 0) > Document.currentFormat
+    }
+
+    private func existingData() throws -> Data? {
+        do {
+            return try Data(contentsOf: url)
+        } catch CocoaError.fileReadNoSuchFile {
+            return nil
+        }
+    }
+}
+
+/// Encodes the document's own keys plus the top-level `format`.
+private struct Stamped<Document: Encodable>: Encodable {
+    private enum Key: String, CodingKey { case format }
+
+    let document: Document
+    let format: Int
+
+    func encode(to encoder: any Encoder) throws {
+        try document.encode(to: encoder)
+        var container = encoder.container(keyedBy: Key.self)
+        try container.encode(format, forKey: .format)
+    }
+}
+
+/// Per-element tolerant array: decodes good elements, keeps undecodable ones as raw JSON,
+/// and encodes both back, the raw ones unchanged after the decoded ones.
+public struct TolerantList<Element: Codable & Sendable>: Codable, Sendable {
+    /// The in-memory view: only the elements that decoded.
+    public var elements: [Element]
+    private var undecodable: [RawJSON] = []
+
+    public init(_ elements: [Element] = []) {
+        self.elements = elements
+    }
+
+    public init(from decoder: any Decoder) throws {
+        var container = try decoder.unkeyedContainer()
+        var elements: [Element] = []
+        var undecodable: [RawJSON] = []
+        while !container.isAtEnd {
+            // A failed decode doesn't advance the container, so the same value is read raw.
+            if let element = try? container.decode(Element.self) {
+                elements.append(element)
+            } else {
+                undecodable.append(try container.decode(RawJSON.self))
+            }
+        }
+        self.elements = elements
+        self.undecodable = undecodable
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var container = encoder.unkeyedContainer()
+        try container.encode(contentsOf: elements)
+        try container.encode(contentsOf: undecodable)
+    }
+}
+
+/// Any JSON value, kept verbatim for re-emission.
+private indirect enum RawJSON: Codable, Sendable {
+    case null
+    case bool(Bool)
+    case integer(Int64)
+    case number(Double)
+    case string(String)
+    case array([RawJSON])
+    case object([String: RawJSON])
+
+    init(from decoder: any Decoder) throws {
+        let container = try decoder.singleValueContainer()
+        if container.decodeNil() {
+            self = .null
+        } else if let value = try? container.decode(Bool.self) {
+            self = .bool(value)
+        } else if let value = try? container.decode(Int64.self) {
+            self = .integer(value)
+        } else if let value = try? container.decode(Double.self) {
+            self = .number(value)
+        } else if let value = try? container.decode(String.self) {
+            self = .string(value)
+        } else if let value = try? container.decode([RawJSON].self) {
+            self = .array(value)
+        } else {
+            self = .object(try container.decode([String: RawJSON].self))
+        }
+    }
+
+    func encode(to encoder: any Encoder) throws {
+        var container = encoder.singleValueContainer()
+        switch self {
+        case .null: try container.encodeNil()
+        case .bool(let value): try container.encode(value)
+        case .integer(let value): try container.encode(value)
+        case .number(let value): try container.encode(value)
+        case .string(let value): try container.encode(value)
+        case .array(let value): try container.encode(value)
+        case .object(let value): try container.encode(value)
+        }
+    }
+}
+
+private func posixError(_ code: Int32) -> POSIXError {
+    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
+}
diff --git a/Packages/EikonCore/Sources/eikon-scan/main.swift b/Packages/EikonCore/Sources/eikon-scan/main.swift
new file mode 100644
index 0000000..fbaaac1
--- /dev/null
+++ b/Packages/EikonCore/Sources/eikon-scan/main.swift
@@ -0,0 +1,4 @@
+import Foundation
+
+FileHandle.standardError.write(Data("eikon-scan: not implemented yet (section 04)\n".utf8))
+exit(1)
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/PersistedTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/PersistedTests.swift
new file mode 100644
index 0000000..87f2f2e
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/PersistedTests.swift
@@ -0,0 +1,65 @@
+import Foundation
+import Testing
+@testable import EikonCore
+
+private struct Item: Codable, Sendable, Equatable {
+    var name: String
+    var count: Int
+}
+
+private struct Document: PersistedDocument {
+    static let currentFormat = 1
+    var format: Int
+    var items: TolerantList<Item>
+}
+
+private func temporaryFile() throws -> URL {
+    let directory = FileManager.default.temporaryDirectory
+        .appendingPathComponent("persisted-\(UUID().uuidString)", isDirectory: true)
+    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
+    return directory.appendingPathComponent("document.json")
+}
+
+@Test func newerFormatLoadsButIsNeverRewritten() throws {
+    let url = try temporaryFile()
+    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
+    let json = #"{"format": 7, "items": [{"name": "a", "count": 1}], "addedLater": {"x": [1, 2]}}"#
+    try Data(json.utf8).write(to: url)
+    let before = try Data(contentsOf: url)
+
+    let file = PersistedFile<Document>(url: url)
+    let loaded = try #require(try file.load())
+    #expect(loaded.isReadOnly)
+    #expect(loaded.document.items.elements == [Item(name: "a", count: 1)])
+
+    var edited = loaded.document
+    edited.items.elements.append(Item(name: "b", count: 2))
+    #expect(throws: (any Error).self) { try file.save(edited) }
+    #expect(try Data(contentsOf: url) == before)
+}
+
+@Test func malformedElementIsDroppedInMemoryButSurvivesSave() throws {
+    let url = try temporaryFile()
+    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
+    let json = #"""
+    {"format": 1, "items": [
+        {"name": "a", "count": 1},
+        {"name": "odd", "count": "many", "tags": [true, null, 2.5]},
+        {"name": "c", "count": 3}
+    ]}
+    """#
+    try Data(json.utf8).write(to: url)
+
+    let file = PersistedFile<Document>(url: url)
+    let loaded = try #require(try file.load())
+    #expect(!loaded.isReadOnly)
+    #expect(loaded.document.items.elements == [Item(name: "a", count: 1), Item(name: "c", count: 3)])
+
+    try file.save(loaded.document)
+
+    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
+    let items = try #require(saved?["items"] as? [NSDictionary])
+    let malformed: NSDictionary = ["name": "odd", "count": "many", "tags": [true, NSNull(), 2.5]]
+    #expect(items.contains(malformed))
+    #expect(items.count == 3)
+}
diff --git a/Packages/EikonKit/Package.swift b/Packages/EikonKit/Package.swift
index b054075..920a7d9 100644
--- a/Packages/EikonKit/Package.swift
+++ b/Packages/EikonKit/Package.swift
@@ -7,9 +7,12 @@ let package = Package(
     products: [
         .library(name: "EikonKit", targets: ["EikonKit"]),
     ],
+    dependencies: [
+        .package(path: "../EikonCore"),
+    ],
     targets: [
         .target(name: "CEikonJIT", linkerSettings: [.linkedFramework("Security")]),
-        .target(name: "EikonKit", dependencies: ["CEikonJIT"]),
+        .target(name: "EikonKit", dependencies: ["CEikonJIT", .product(name: "EikonCore", package: "EikonCore")]),
         .testTarget(name: "EikonKitTests", dependencies: ["EikonKit", "CEikonJIT"]),
     ],
     swiftLanguageModes: [.v6]
diff --git a/project.yml b/project.yml
index 9ed0749..4d1cf5c 100644
--- a/project.yml
+++ b/project.yml
@@ -11,6 +11,8 @@ configFiles:
 packages:
   EikonKit:
     path: Packages/EikonKit
+  EikonCore:
+    path: Packages/EikonCore
 targets:
   Eikon:
     type: application
@@ -27,6 +29,8 @@ targets:
     dependencies:
       - package: EikonKit
         product: EikonKit
+      - package: EikonCore
+        product: EikonCore
     # No preBuildScripts or postBuildScripts: nothing runs in a build phase.
 schemes:
   Eikon:
@@ -37,6 +41,7 @@ schemes:
       config: Debug
       targets:
         - package: EikonKit/EikonKitTests
+        - package: EikonCore/EikonCoreTests
     run:
       config: Debug
     archive:

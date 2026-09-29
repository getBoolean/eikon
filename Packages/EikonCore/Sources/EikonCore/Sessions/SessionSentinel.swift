import Darwin
import Foundation

/// What the previous launch left behind when its session didn't end cleanly.
public struct ConsumedSession: Sendable, Equatable {
    public var record: SessionRecord
    /// Sorted by seq.
    public var breadcrumbs: [Breadcrumb]
    /// Only when its header names `record.sessionID`.
    public var fault: FaultRecord?

    public init(record: SessionRecord, breadcrumbs: [Breadcrumb], fault: FaultRecord?) {
        self.record = record
        self.breadcrumbs = breadcrumbs
        self.fault = fault
    }
}

/// `sentinel.json` exists while a game runs; finding it at launch means the session
/// didn't end cleanly. Writes are atomic and fsynced, so the phase survives a kill.
///
/// Callers consume at launch before any `arm` (arming discards unconsumed evidence), and
/// add the consumed session to `CrashHistory` right away (consuming deletes the files).
public struct SessionSentinel: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var sentinelURL: URL { directory.appendingPathComponent("sentinel.json") }
    public var breadcrumbsURL: URL { directory.appendingPathComponent("breadcrumbs.bin") }
    public var faultURL: URL { directory.appendingPathComponent("fault.bin") }

    /// Also clears an earlier session's breadcrumbs and fault file, so nothing stale is
    /// attributed to this one.
    public func arm(_ record: SessionRecord) throws {
        removeEvidence()
        try write(record)
    }

    /// Throws when there is no readable sentinel, so a lost phase change is noticed.
    public func setPhase(_ phase: SessionRecord.Phase) throws {
        guard var record = readRecord() else { throw CocoaError(.fileReadNoSuchFile) }
        record.phase = phase
        try write(record)
    }

    /// A clean end: removes the sentinel, breadcrumbs and fault file.
    public func disarm() {
        remove(sentinelURL)
        removeEvidence()
        syncDirectory()
    }

    /// The previous session, when its sentinel is still here. Always removes all three files.
    public func consumeAtLaunch() -> ConsumedSession? {
        defer { disarm() }
        guard FileManager.default.fileExists(atPath: sentinelURL.path), let record = readRecord() else { return nil }
        return ConsumedSession(record: record, breadcrumbs: Breadcrumbs.read(from: breadcrumbsURL),
                               fault: FaultRecord.read(from: faultURL, sessionID: record.sessionID))
    }

    private func write(_ record: SessionRecord) throws {
        try Persisted.writeAtomically(try JSONEncoder().encode(record), to: sentinelURL)
    }

    private func readRecord() -> SessionRecord? {
        (try? Data(contentsOf: sentinelURL)).flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }
    }

    private func removeEvidence() {
        remove(breadcrumbsURL)
        remove(faultURL)
    }

    /// Best effort, so a removed sentinel can't reappear after power loss.
    private func syncDirectory() {
        let fd = directory.path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    private func remove(_ url: URL) {
        url.path.withCString { _ = unlink($0) }
    }
}

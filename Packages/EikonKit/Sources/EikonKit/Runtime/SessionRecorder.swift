import EikonCore
import Foundation
import os

/// The session's evidence on disk: sentinel, breadcrumbs and fault file.
@MainActor
public protocol SessionRecorder: AnyObject {
    /// Arms the sentinel, then opens the breadcrumb ring and the fault file.
    func arm(_ record: SessionRecord) throws
    /// Throws when the sentinel is gone, so a lost phase change is noticed.
    func setPhase(_ phase: SessionRecord.Phase) throws
    func add(_ event: BreadcrumbEvent)
    /// Closes the ring and the fault file, then disarms the sentinel (removing them).
    func disarm()
}

/// Over section 07's `SessionSentinel`, `Breadcrumbs` and `FaultRecord` in
/// `Application Support/Eikon/sessions/`.
@MainActor
public final class LiveSessionRecorder: SessionRecorder {
    private static let log = Logger(subsystem: "com.getboolean.eikon", category: "session")
    public let sentinel: SessionSentinel

    public init(directory: URL = LibraryPaths.sessions) {
        sentinel = SessionSentinel(directory: directory)
    }

    /// Arming unlinks the previous ring and fault file, so both open only afterwards;
    /// opened before, every breadcrumb would go to an unlinked file. Only the sentinel is
    /// required: without the ring or fault file a crash is still reported, with less detail.
    public func arm(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(at: sentinel.directory, withIntermediateDirectories: true)
        try sentinel.arm(record)
        do {
            try Breadcrumbs.open(at: sentinel.breadcrumbsURL)
        } catch {
            Self.log.error("breadcrumbs open failed: \((error as NSError).code, privacy: .public)")
        }
        do {
            try FaultRecord.open(at: sentinel.faultURL, sessionID: record.sessionID)
        } catch {
            Self.log.error("fault file open failed: \((error as NSError).code, privacy: .public)")
        }
    }

    public func setPhase(_ phase: SessionRecord.Phase) throws {
        try sentinel.setPhase(phase)
    }

    public func add(_ event: BreadcrumbEvent) {
        Breadcrumbs.append(event)
    }

    public func disarm() {
        Breadcrumbs.close()
        FaultRecord.close()
        sentinel.disarm()
    }
}

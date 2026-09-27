import Foundation

extension JITStatus {
    /// Conservative not-usable status for reads before facts have been gathered.
    public static var placeholder: JITStatus {
        let facts = JITFacts(
            installMethod: .unknown,
            csDebugged: false,
            csDebuggedSeen: .never,
            txm: TXMInfo(state: .unknown, enforced: true, basis: "not gathered"),
            trollStoreRequest: .none,
            probeBlockedBySentinel: false
        )
        return JITPolicy.status(facts, probe: ProbeOutcome(kind: .notRun, detail: "not gathered"))
    }
}

/// Thread-safe snapshot for non-UI code.
public final class JITStatusStore: @unchecked Sendable {
    public static let shared = JITStatusStore()

    private let lock = NSLock()
    private var status: JITStatus

    public init(initial: JITStatus = .placeholder) {
        status = initial
    }

    /// Lock-protected read. Safe from any thread.
    public var current: JITStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func update(_ status: JITStatus) {
        lock.lock()
        self.status = status
        lock.unlock()
    }
}

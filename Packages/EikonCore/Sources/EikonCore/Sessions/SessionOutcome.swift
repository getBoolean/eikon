import Foundation

/// How an unclean session most likely ended.
public enum SessionOutcome: Codable, Sendable, Equatable {
    case crashed(signal: Int32, pc: UInt64)
    case likelyMemoryKill
    /// A crash or a system kill.
    case endedUnexpectedly
    case killedInBackground

    /// A memory warning this close to the last breadcrumb points at a memory kill.
    public static let memoryWarningWindow: TimeInterval = 60
    /// A last memory sample below this points at a memory kill.
    public static let lowMemoryThresholdMB: Int64 = 100

    /// Background kills go to history only.
    public var showsBanner: Bool {
        switch self {
        case .crashed, .likelyMemoryKill, .endedUnexpectedly: true
        case .killedInBackground: false
        }
    }

    /// A stable identifier for issue text and history.
    public var code: String {
        switch self {
        case .crashed: "crashed"
        case .likelyMemoryKill: "likelyMemoryKill"
        case .endedUnexpectedly: "endedUnexpectedly"
        case .killedInBackground: "killedInBackground"
        }
    }

    /// Background first; then a fault, memory evidence, or nothing.
    public static func classify(_ consumed: ConsumedSession) -> SessionOutcome {
        switch consumed.record.phase {
        case .background:
            return .killedInBackground
        case .running:
            if let fault = consumed.fault { return .crashed(signal: fault.signal, pc: fault.pc) }
            let crumbs = consumed.breadcrumbs.sorted { $0.seq < $1.seq }
            if let last = crumbs.last,
               let warning = crumbs.last(where: { $0.event == .memoryWarning }),
               (0...memoryWarningWindow).contains(last.time.timeIntervalSince(warning.time)) {
                return .likelyMemoryKill
            }
            if case .memorySample(let available)? = crumbs.last(where: {
                if case .memorySample = $0.event { return true }
                return false
            })?.event, available < lowMemoryThresholdMB {
                return .likelyMemoryKill
            }
            return .endedUnexpectedly
        }
    }
}

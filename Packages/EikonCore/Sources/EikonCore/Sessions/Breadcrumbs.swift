import CEikonSession
import Foundation

/// App-defined session events. Integers only, so no text can reach the file.
public enum BreadcrumbEvent: Sendable, Equatable {
    case sessionStart, sessionPaused, sessionBackgrounded, sessionResumed, sessionStop
    case memoryWarning
    case memorySample(availableMB: Int64)
    case audioInterrupted
    case renderGateTimeout
    case runtimeError(code: Int64)

    // Stable numeric codes. Later splits add cases with new codes; never reuse or renumber.
    var encoded: (code: UInt16, a: Int64, b: Int64) {
        switch self {
        case .sessionStart: (1, 0, 0)
        case .sessionPaused: (2, 0, 0)
        case .sessionBackgrounded: (3, 0, 0)
        case .sessionResumed: (4, 0, 0)
        case .sessionStop: (5, 0, 0)
        case .memoryWarning: (6, 0, 0)
        case .memorySample(let availableMB): (7, availableMB, 0)
        case .audioInterrupted: (8, 0, 0)
        case .renderGateTimeout: (9, 0, 0)
        case .runtimeError(let code): (10, code, 0)
        }
    }

    init?(code: UInt16, a: Int64, b: Int64) {
        switch code {
        case 1: self = .sessionStart
        case 2: self = .sessionPaused
        case 3: self = .sessionBackgrounded
        case 4: self = .sessionResumed
        case 5: self = .sessionStop
        case 6: self = .memoryWarning
        case 7: self = .memorySample(availableMB: a)
        case 8: self = .audioInterrupted
        case 9: self = .renderGateTimeout
        case 10: self = .runtimeError(code: a)
        default: return nil
        }
    }
}

public struct Breadcrumb: Sendable, Equatable, Codable {
    public var seq: UInt64
    public var time: Date
    /// The raw code, kept even when this build doesn't know it.
    public var code: UInt16
    public var a: Int64
    public var b: Int64

    public init(seq: UInt64, time: Date, code: UInt16, a: Int64, b: Int64) {
        self.seq = seq
        self.time = time
        self.code = code
        self.a = a
        self.b = b
    }

    public init(seq: UInt64, time: Date, event: BreadcrumbEvent) {
        let (code, a, b) = event.encoded
        self.init(seq: seq, time: time, code: code, a: a, b: b)
    }

    /// nil for a code from a newer build.
    public var event: BreadcrumbEvent? { BreadcrumbEvent(code: code, a: a, b: b) }
}

/// The session's breadcrumb ring. Descriptor and sequence live in C, async-signal-safe.
public enum Breadcrumbs {
    public static let capacity = Int(EIKON_BREADCRUMB_SLOTS)
    static let slotSize = Int(EIKON_BREADCRUMB_SLOT_SIZE)

    /// Creates or truncates the ring for a new session.
    public static func open(at url: URL) throws {
        let result = url.path.withCString { eikon_breadcrumbs_open($0) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    public static func append(_ event: BreadcrumbEvent) {
        let (code, a, b) = event.encoded
        eikon_breadcrumbs_append(code, a, b)
    }

    public static func close() {
        eikon_breadcrumbs_close()
    }

    /// Valid slots only, sorted by seq: empty, torn, misplaced and truncated slots are skipped.
    public static func read(from url: URL) -> [Breadcrumb] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let checkOffset = Int(EIKON_BREADCRUMB_OFFSET_CHECK)
        var result: [Breadcrumb] = []
        for index in 0..<(data.count / slotSize) {
            let slot = data.subdata(in: (index * slotSize)..<((index + 1) * slotSize))
            guard let seq = slot.uint64LE(at: Int(EIKON_BREADCRUMB_OFFSET_SEQ)), seq != 0,
                  Int(seq % UInt64(capacity)) == index,
                  let check = slot.uint64LE(at: checkOffset), check == fnv1a64(slot.prefix(checkOffset)),
                  let time = slot.uint64LE(at: Int(EIKON_BREADCRUMB_OFFSET_TIME)),
                  let a = slot.uint64LE(at: Int(EIKON_BREADCRUMB_OFFSET_A)),
                  let b = slot.uint64LE(at: Int(EIKON_BREADCRUMB_OFFSET_B)),
                  let code = slot.uint16LE(at: Int(EIKON_BREADCRUMB_OFFSET_EVENT)) else { continue }
            result.append(Breadcrumb(seq: seq, time: Date(timeIntervalSince1970: Double(Int64(bitPattern: time)) / 1000),
                                     code: code, a: Int64(bitPattern: a), b: Int64(bitPattern: b)))
        }
        return result.sorted { $0.seq < $1.seq }
    }

    /// Must match the C writer's check word.
    private static func fnv1a64(_ bytes: Data) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }
}

import Foundation

/// A hybrid logical timestamp. Totally ordered: wall clock, then counter, then replica.
public struct HybridTimestamp: Hashable, Comparable, Codable, Sendable {
    public var wallMillis: Int64
    public var counter: UInt32
    public var replica: ReplicaID

    public init(wallMillis: Int64, counter: UInt32, replica: ReplicaID) {
        self.wallMillis = wallMillis
        self.counter = counter
        self.replica = replica
    }

    public static func < (lhs: HybridTimestamp, rhs: HybridTimestamp) -> Bool {
        (lhs.wallMillis, lhs.counter, lhs.replica) < (rhs.wallMillis, rhs.counter, rhs.replica)
    }
}

/// Issues timestamps that never go backwards and that order after everything observed.
public struct HybridClock: Sendable, Equatable {
    /// The end of year 9999. Later remote times are ignored and wall clocks are clamped, so
    /// one corrupt file can't overflow the clock.
    public static let maxWallMillis: Int64 = 253_402_300_799_999

    public private(set) var last: HybridTimestamp

    public init(replica: ReplicaID, last: HybridTimestamp? = nil) {
        self.last = HybridTimestamp(wallMillis: last?.wallMillis ?? 0, counter: last?.counter ?? 0, replica: replica)
    }

    public var replica: ReplicaID { last.replica }

    public mutating func tick(now: Date) -> HybridTimestamp {
        let millis = now.timeIntervalSince1970 * 1000
        let clamped = millis.isFinite ? Int64(min(max(millis, 0), Double(Self.maxWallMillis)).rounded(.down)) : 0
        let wall = max(clamped, last.wallMillis)
        if wall > last.wallMillis {
            last = HybridTimestamp(wallMillis: wall, counter: 0, replica: replica)
        } else if last.counter == .max, wall < Self.maxWallMillis {
            last = HybridTimestamp(wallMillis: wall + 1, counter: 0, replica: replica)
        } else if last.counter == .max {
            // Saturated: only reachable by exhausting the last millisecond of year 9999.
        } else {
            last.counter += 1
        }
        return last
    }

    /// The next tick orders after `remote`, however far in the future it is.
    public mutating func observe(_ remote: HybridTimestamp) {
        guard remote.wallMillis <= Self.maxWallMillis else { return }
        if (remote.wallMillis, remote.counter) > (last.wallMillis, last.counter) {
            last = HybridTimestamp(wallMillis: remote.wallMillis, counter: remote.counter, replica: replica)
        }
    }
}

import Foundation

/// Minimal time seam. Swift's Clock protocol needs iOS 16.
public protocol JITClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct LiveJITClock: JITClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(seconds: Double) async throws {
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

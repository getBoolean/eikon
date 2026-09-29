/// Why a built runtime declined a game. Open: the runtime splits own the values, and the
/// UI maps each to `route.decline.<raw>` with a generic fallback.
public struct RuntimeDeclineCode: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A built runtime's verdict on one game.
public enum RuntimeCheck: Sendable, Equatable {
    case ok
    case declined(RuntimeDeclineCode)
}

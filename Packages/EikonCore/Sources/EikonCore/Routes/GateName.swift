/// A device capability measured at runtime. Open: later splits add gates, and the UI
/// gives unknown ones a generic sentence with the raw name.
public struct GateName: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Guest code may use x18 (Apple reserves it).
    public static let x18 = GateName(rawValue: "x18")
    /// A 32-bit guest can open a window.
    public static let guestWindow = GateName(rawValue: "guestWindow")
}

/// How this copy of the app was installed. The raw values are the device
/// report's wire format and the status screen's wording keys.
public enum InstallMethod: String, Codable, Sendable, CaseIterable {
    case dopamine, rootlessJailbreak, trollStore, trollStoreLite, sideloaded, simulator, unknown
}

/// The facts behind a detected install method, with device-unique identifiers
/// removed so they can go into a shared device report.
public struct InstallEvidence: Codable, Sendable, Equatable {
    /// The resolved bundle path, reduced to its structure.
    public var bundlePath: String
    /// The home directory, reduced to its structure. It shows which data container is in use.
    public var homeDirectory: String
    /// Names of the markers that were found, decisive or not.
    public var markers: [String]

    public init(bundlePath: String, homeDirectory: String, markers: [String]) {
        self.bundlePath = bundlePath
        self.homeDirectory = homeDirectory
        self.markers = markers
    }
}

import Foundation

/// The package kind stamped at packaging time, and the bundle id as installed.
public struct AppIdentity: Codable, Sendable, Equatable {
    /// Info.plist `EKPackageKind`: development, deb, tipa or ipa.
    public var packageKind: String
    /// Read at run time: AltStore free accounts may rewrite it.
    public var bundleIdentifier: String

    public init(packageKind: String, bundleIdentifier: String) {
        self.packageKind = packageKind
        self.bundleIdentifier = bundleIdentifier
    }

    /// Reads both from a bundle. `Bundle` isn't Sendable, so only plain values are kept.
    public static func current(bundle: Bundle = .main) -> AppIdentity {
        AppIdentity(
            packageKind: bundle.object(forInfoDictionaryKey: "EKPackageKind") as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? ""
        )
    }
}

import CEikonJIT
import Foundation

/// The filesystem and signing facts install detection reads, so it can be tested against a fake layout.
public protocol BundleEnvironment: Sendable {
    var bundleURL: URL { get }
    var homeDirectory: URL { get }
    var bundleIdentifier: String { get }
    var isSimulator: Bool { get }
    func fileExists(_ path: String) -> Bool
    func resolvingSymlinks(_ url: URL) -> URL
    /// The signed entitlement `key` when it is a string.
    func entitlementString(_ key: String) -> String?
}

public struct LiveBundleEnvironment: BundleEnvironment {
    public let bundleURL: URL
    public let homeDirectory: URL
    public let bundleIdentifier: String

    public init() {
        bundleURL = Bundle.main.bundleURL
        homeDirectory = URL(fileURLWithPath: NSHomeDirectory())
        bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
    }

    public var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func entitlementString(_ key: String) -> String? {
        guard let value = eikon_copy_entitlement_string(key) else { return nil }
        defer { free(value) }
        return String(cString: value)
    }

    /// Uses realpath(3): Foundation's resolvingSymlinksInPath() strips a leading
    /// /private and doesn't reliably expand /var/jb.
    public func resolvingSymlinks(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

extension BundleEnvironment where Self == LiveBundleEnvironment {
    public static var live: LiveBundleEnvironment { LiveBundleEnvironment() }
}

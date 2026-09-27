diff --git a/.gitignore b/.gitignore
index 6eb835c..87d0485 100644
--- a/.gitignore
+++ b/.gitignore
@@ -10,6 +10,9 @@ build/
 dist/
 *.xcodeproj
 DerivedData/
+# SwiftPM and editor index state
+.build/
+.swiftpm/
 
 # Per-developer signing settings
 Config/Local.xcconfig
diff --git a/Packages/EikonKit/Sources/EikonKit/AppIdentity.swift b/Packages/EikonKit/Sources/EikonKit/AppIdentity.swift
new file mode 100644
index 0000000..19e8ce2
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/AppIdentity.swift
@@ -0,0 +1,22 @@
+import Foundation
+
+/// The package kind stamped at packaging time, and the bundle id as installed.
+public struct AppIdentity: Codable, Sendable, Equatable {
+    /// Info.plist `EKPackageKind`: development, deb, tipa or ipa.
+    public var packageKind: String
+    /// Read at run time: AltStore free accounts may rewrite it.
+    public var bundleIdentifier: String
+
+    public init(packageKind: String, bundleIdentifier: String) {
+        self.packageKind = packageKind
+        self.bundleIdentifier = bundleIdentifier
+    }
+
+    /// Reads both from a bundle. `Bundle` isn't Sendable, so only plain values are kept.
+    public static func current(bundle: Bundle = .main) -> AppIdentity {
+        AppIdentity(
+            packageKind: bundle.object(forInfoDictionaryKey: "EKPackageKind") as? String ?? "unknown",
+            bundleIdentifier: bundle.bundleIdentifier ?? ""
+        )
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/BundleEnvironment.swift b/Packages/EikonKit/Sources/EikonKit/BundleEnvironment.swift
new file mode 100644
index 0000000..cfb8c94
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/BundleEnvironment.swift
@@ -0,0 +1,44 @@
+import Foundation
+
+/// The filesystem facts install detection reads, so it can be tested against a fake layout.
+public protocol BundleEnvironment: Sendable {
+    var bundleURL: URL { get }
+    var homeDirectory: URL { get }
+    var isSimulator: Bool { get }
+    func fileExists(_ path: String) -> Bool
+    func resolvingSymlinks(_ url: URL) -> URL
+}
+
+public struct LiveBundleEnvironment: BundleEnvironment {
+    public let bundleURL: URL
+    public let homeDirectory: URL
+
+    public init() {
+        bundleURL = Bundle.main.bundleURL
+        homeDirectory = URL(fileURLWithPath: NSHomeDirectory())
+    }
+
+    public var isSimulator: Bool {
+        #if targetEnvironment(simulator)
+        true
+        #else
+        false
+        #endif
+    }
+
+    public func fileExists(_ path: String) -> Bool {
+        FileManager.default.fileExists(atPath: path)
+    }
+
+    /// Uses realpath(3): Foundation's resolvingSymlinksInPath() strips a leading
+    /// /private and doesn't reliably expand /var/jb.
+    public func resolvingSymlinks(_ url: URL) -> URL {
+        guard let resolved = realpath(url.path, nil) else { return url }
+        defer { free(resolved) }
+        return URL(fileURLWithPath: String(cString: resolved))
+    }
+}
+
+extension BundleEnvironment where Self == LiveBundleEnvironment {
+    public static var live: LiveBundleEnvironment { LiveBundleEnvironment() }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/InstallDetection.swift b/Packages/EikonKit/Sources/EikonKit/InstallDetection.swift
new file mode 100644
index 0000000..02b3067
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/InstallDetection.swift
@@ -0,0 +1,78 @@
+import Foundation
+
+/// Detects how this app was installed. Pure apart from the environment's filesystem queries.
+public func detectInstallMethod(_ env: BundleEnvironment) -> (InstallMethod, InstallEvidence) {
+    let container = env.bundleURL.deletingLastPathComponent()
+    let resolvedPath = env.resolvingSymlinks(env.bundleURL).path
+    let jailbreakRoot = jailbreakRoot(forResolvedBundlePath: resolvedPath)
+
+    // Every marker is checked, so the evidence is complete even when an earlier rule decides.
+    var candidates: [(name: String, path: String)] = [
+        ("_TrollStore", container.appendingPathComponent("_TrollStore").path),
+        ("_TrollStoreLite", container.appendingPathComponent("_TrollStoreLite").path),
+        (".installed_dopamine", "/var/jb/.installed_dopamine"),
+        ("embedded.mobileprovision", env.bundleURL.appendingPathComponent("embedded.mobileprovision").path),
+    ]
+    if let jailbreakRoot {
+        candidates.append(("basebin", jailbreakRoot + "/basebin"))
+    }
+    let found = Set(candidates.filter { env.fileExists($0.path) }.map(\.name))
+
+    let method: InstallMethod
+    if env.isSimulator {
+        method = .simulator
+    } else if found.contains("_TrollStore") {
+        method = .trollStore
+    } else if found.contains("_TrollStoreLite") {
+        method = .trollStoreLite
+    } else if jailbreakRoot != nil {
+        method = found.contains(".installed_dopamine") || found.contains("basebin")
+            ? .dopamine : .rootlessJailbreak
+    } else if found.contains("embedded.mobileprovision") {
+        method = .sideloaded
+    } else {
+        method = .unknown
+    }
+
+    let evidence = InstallEvidence(
+        bundlePath: redactPath(resolvedPath),
+        homeDirectory: redactPath(env.homeDirectory.path),
+        markers: candidates.map(\.name).filter(found.contains)
+    )
+    return (method, evidence)
+}
+
+/// The jailbreak root when the resolved bundle path is inside a jailbreak's
+/// Applications directory: everything up to `/procursus`, or `/var/jb`.
+func jailbreakRoot(forResolvedBundlePath path: String) -> String? {
+    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
+    if let i = components.indices.dropLast(2).first(where: {
+        components[$0] == "procursus" && components[$0 + 1] == "Applications"
+    }) {
+        return components[...i].joined(separator: "/")
+    }
+    for root in ["/var/jb", "/private/var/jb"] where path.hasPrefix(root + "/Applications/") {
+        return root
+    }
+    return nil
+}
+
+/// Reduces a path to its structure: preboot hashes, Dopamine install ids,
+/// UUIDs and the Mac user name are replaced with placeholders.
+public func redactPath(_ path: String) -> String {
+    var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
+    for i in components.indices {
+        let previous = i > 0 ? components[i - 1] : nil
+        let component = components[i]
+        if previous == "preboot" && !component.isEmpty {
+            components[i] = "<hash>"
+        } else if component.hasPrefix("dopamine-") {
+            components[i] = "dopamine-<id>"
+        } else if UUID(uuidString: component) != nil {
+            components[i] = "<uuid>"
+        } else if previous == "Users" && i == 2 && components[0].isEmpty && !component.isEmpty {
+            components[i] = "<user>"
+        }
+    }
+    return components.joined(separator: "/")
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/InstallMethod.swift b/Packages/EikonKit/Sources/EikonKit/InstallMethod.swift
new file mode 100644
index 0000000..49c0a49
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/InstallMethod.swift
@@ -0,0 +1,22 @@
+/// How this copy of the app was installed. The raw values are the device
+/// report's wire format and the status screen's wording keys.
+public enum InstallMethod: String, Codable, Sendable, CaseIterable {
+    case dopamine, rootlessJailbreak, trollStore, trollStoreLite, sideloaded, simulator, unknown
+}
+
+/// The facts behind a detected install method, with device-unique identifiers
+/// removed so they can go into a shared device report.
+public struct InstallEvidence: Codable, Sendable, Equatable {
+    /// The resolved bundle path, reduced to its structure.
+    public var bundlePath: String
+    /// The home directory, reduced to its structure. It shows where unsandboxed data lands.
+    public var homeDirectory: String
+    /// Names of the markers that were found, decisive or not.
+    public var markers: [String]
+
+    public init(bundlePath: String, homeDirectory: String, markers: [String]) {
+        self.bundlePath = bundlePath
+        self.homeDirectory = homeDirectory
+        self.markers = markers
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/InstallDetectionTests.swift b/Packages/EikonKit/Tests/EikonKitTests/InstallDetectionTests.swift
new file mode 100644
index 0000000..5b5d6e7
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/InstallDetectionTests.swift
@@ -0,0 +1,89 @@
+import Foundation
+import Testing
+@testable import EikonKit
+
+/// A filesystem layout for detection tests: a set of paths that exist, and
+/// symlink prefixes that `resolvingSymlinks` rewrites.
+struct FakeBundleEnvironment: BundleEnvironment {
+    var bundleURL: URL
+    var homeDirectory: URL
+    var isSimulator = false
+    var existing: Set<String> = []
+    var symlinks: [String: String] = [:]
+
+    func fileExists(_ path: String) -> Bool {
+        existing.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
+    }
+
+    func resolvingSymlinks(_ url: URL) -> URL {
+        for (link, target) in symlinks where url.path.hasPrefix(link + "/") {
+            return URL(fileURLWithPath: target + url.path.dropFirst(link.count))
+        }
+        return url
+    }
+}
+
+private let prebootHash = "9F2C4A7B1E0D3C5A8B6F4E2D1C0B9A8F7E6D5C4B3A2918273645546372819AB0C"
+private let dopamineSuffix = "k3x9qa"
+private let jailbreakRoot = "/private/preboot/\(prebootHash)/dopamine-\(dopamineSuffix)/procursus"
+private let bundleUUID = UUID().uuidString
+private let dataUUID = UUID().uuidString
+private let containerDir = "/private/var/containers/Bundle/Application/\(bundleUUID)"
+private let dataHome = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(dataUUID)")
+
+private func containerLayout(with markers: [String]) -> FakeBundleEnvironment {
+    FakeBundleEnvironment(
+        bundleURL: URL(fileURLWithPath: "\(containerDir)/Eikon.app"),
+        homeDirectory: dataHome,
+        existing: Set(markers.map { "\(containerDir)/\($0)" })
+    )
+}
+
+private func jailbreakLayout(with markers: [String]) -> FakeBundleEnvironment {
+    FakeBundleEnvironment(
+        bundleURL: URL(fileURLWithPath: "/var/jb/Applications/Eikon.app"),
+        homeDirectory: URL(fileURLWithPath: "/var/mobile"),
+        existing: Set(markers),
+        symlinks: ["/var/jb": jailbreakRoot]
+    )
+}
+
+@Test(arguments: [
+    ("_TrollStore", InstallMethod.trollStore),
+    ("_TrollStoreLite", InstallMethod.trollStoreLite),
+])
+func trollStoreMarkers(marker: String, expected: InstallMethod) {
+    #expect(detectInstallMethod(containerLayout(with: [marker])).0 == expected)
+}
+
+@Test func jailbreakLayouts() {
+    let withMarkerFile = jailbreakLayout(with: ["/var/jb/.installed_dopamine"])
+    let withBasebin = jailbreakLayout(with: ["\(jailbreakRoot)/basebin"])
+    let withNeither = jailbreakLayout(with: [])
+
+    #expect(detectInstallMethod(withMarkerFile).0 == .dopamine)
+    #expect(detectInstallMethod(withBasebin).0 == .dopamine)
+    #expect(detectInstallMethod(withNeither).0 == .rootlessJailbreak)
+}
+
+@Test(arguments: [
+    (["Eikon.app/embedded.mobileprovision"], InstallMethod.sideloaded),
+    ([], InstallMethod.unknown),
+])
+func fallbacks(markers: [String], expected: InstallMethod) {
+    #expect(detectInstallMethod(containerLayout(with: markers)).0 == expected)
+}
+
+@Test func evidenceHidesDeviceIdentifiers() throws {
+    let layouts = [
+        jailbreakLayout(with: ["/var/jb/.installed_dopamine"]),
+        containerLayout(with: ["Eikon.app/embedded.mobileprovision"]),
+    ]
+    for layout in layouts {
+        let evidence = detectInstallMethod(layout).1
+        let json = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
+        for identifier in [prebootHash, dopamineSuffix, bundleUUID, dataUUID] {
+            #expect(!json.localizedCaseInsensitiveContains(identifier))
+        }
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift b/Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift
deleted file mode 100644
index 43ea27d..0000000
--- a/Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift
+++ /dev/null
@@ -1,6 +0,0 @@
-import Testing
-@testable import EikonKit
-
-/// Proves the test target builds, links EikonKit, and runs on the simulator.
-/// Section 05 deletes this file when it adds real tests.
-@Test func packageLinks() { #expect(Bool(true)) }

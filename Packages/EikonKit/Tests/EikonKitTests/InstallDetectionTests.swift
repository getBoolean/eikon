import Foundation
import Testing
@testable import EikonKit

/// A filesystem layout for detection tests: a set of paths that exist, and
/// symlink prefixes that `resolvingSymlinks` rewrites.
struct FakeBundleEnvironment: BundleEnvironment {
    var bundleURL: URL
    var homeDirectory: URL
    var isSimulator = false
    var existing: Set<String> = []
    var symlinks: [String: String] = [:]

    func fileExists(_ path: String) -> Bool {
        existing.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    func resolvingSymlinks(_ url: URL) -> URL {
        for (link, target) in symlinks where url.path.hasPrefix(link + "/") {
            return URL(fileURLWithPath: target + url.path.dropFirst(link.count))
        }
        return url
    }
}

private let prebootHash = "9F2C4A7B1E0D3C5A8B6F4E2D1C0B9A8F7E6D5C4B3A2918273645546372819AB0C"
private let dopamineSuffix = "k3x9qa"
private let dopamineRoot = "/private/preboot/\(prebootHash)/dopamine-\(dopamineSuffix)/procursus"
private let otherSuffix = "7fq2mz0c"
private let otherRoot = "/private/preboot/\(prebootHash)/jb-\(otherSuffix)/procursus"
private let bundleUUID = UUID().uuidString
private let dataUUID = UUID().uuidString
private let containerDir = "/private/var/containers/Bundle/Application/\(bundleUUID)"
private let dataHome = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(dataUUID)")

private func containerLayout(with markers: [String]) -> FakeBundleEnvironment {
    FakeBundleEnvironment(
        bundleURL: URL(fileURLWithPath: "\(containerDir)/Eikon.app"),
        homeDirectory: dataHome,
        existing: Set(markers.map { "\(containerDir)/\($0)" })
    )
}

private func jailbreakLayout(with markers: [String], root: String = dopamineRoot) -> FakeBundleEnvironment {
    FakeBundleEnvironment(
        bundleURL: URL(fileURLWithPath: "/var/jb/Applications/Eikon.app"),
        homeDirectory: URL(fileURLWithPath: "/var/mobile"),
        existing: Set(markers),
        symlinks: ["/var/jb": root]
    )
}

@Test(arguments: [
    (["_TrollStore"], InstallMethod.trollStore),
    (["_TrollStoreLite"], InstallMethod.trollStoreLite),
    (["_TrollStore", "Eikon.app/embedded.mobileprovision"], InstallMethod.trollStore),
])
func trollStoreMarkers(markers: [String], expected: InstallMethod) {
    #expect(detectInstallMethod(containerLayout(with: markers)).0 == expected)
}

@Test func jailbreakLayouts() {
    let withMarkerFile = jailbreakLayout(with: ["/var/jb/.installed_dopamine"])
    let withBasebin = jailbreakLayout(with: ["\(dopamineRoot)/basebin"])
    let withNeither = jailbreakLayout(with: [], root: otherRoot)
    let withProfile = jailbreakLayout(
        with: ["/var/jb/Applications/Eikon.app/embedded.mobileprovision"], root: otherRoot)

    #expect(detectInstallMethod(withMarkerFile).0 == .dopamine)
    #expect(detectInstallMethod(withBasebin).0 == .dopamine)
    #expect(detectInstallMethod(withNeither).0 == .rootlessJailbreak)
    #expect(detectInstallMethod(withProfile).0 == .rootlessJailbreak)
}

@Test(arguments: [
    (["Eikon.app/embedded.mobileprovision"], InstallMethod.sideloaded),
    ([], InstallMethod.unknown),
])
func fallbacks(markers: [String], expected: InstallMethod) {
    #expect(detectInstallMethod(containerLayout(with: markers)).0 == expected)
}

@Test func evidenceHidesDeviceIdentifiers() throws {
    let layouts = [
        jailbreakLayout(with: ["/var/jb/.installed_dopamine"]),
        jailbreakLayout(with: [], root: otherRoot),
        containerLayout(with: ["Eikon.app/embedded.mobileprovision"]),
    ]
    for layout in layouts {
        let evidence = detectInstallMethod(layout).1
        let json = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        for identifier in [prebootHash, dopamineSuffix, otherSuffix, bundleUUID, dataUUID] {
            #expect(!json.localizedCaseInsensitiveContains(identifier))
        }
    }
}

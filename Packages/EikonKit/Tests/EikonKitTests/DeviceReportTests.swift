import Foundation
import Testing
import UIKit
@testable import EikonKit

private struct FixedDeviceSystem: DeviceSystem {
    var modelIdentifier = "iPad14,5"
    var cpuFamily: UInt32 = 0xDA33_D83D
    var osName = "iPadOS"
    var osVersion = "17.0"
    var osBuild = "21A329"
    func availableMemoryBytes() -> UInt64 { 5_368_709_120 }
}

@Test @MainActor func roundTripAndPrivacy() throws {
    let now = Date(timeIntervalSince1970: 1_768_470_030)
    let report = DeviceReport.make(
        app: AppInfo(version: "0.1.0", build: "12", commit: "0123abc", packageKind: "ipa",
                     bundleIdentifier: "com.getboolean.eikon"),
        installMethod: .trollStore,
        evidence: InstallEvidence(bundlePath: "/private/var/containers/Bundle/Application/<uuid>/Eikon.app",
                                  homeDirectory: "/var/mobile/Containers/Data/Application/<uuid>",
                                  markers: ["container-required"]),
        jit: JITStatus(csDebugged: true, csDebuggedSeen: .afterTrollStoreRequest,
                       txm: TXMInfo(state: .absent, enforced: false, basis: "os below 26"),
                       probe: ProbeOutcome(kind: .passed, detail: nil),
                       source: .trollStore, reason: nil),
        system: FixedDeviceSystem(),
        now: now
    )
    let encoded = try report.encode()
    #expect(try DeviceReport.decode(encoded) == report)
    try expectPrivacy(encoded)

    let live = DeviceReport.make(
        app: report.app, installMethod: .simulator, evidence: report.install.evidence,
        jit: report.jit, system: LiveDeviceSystem.current(), now: now
    )
    try expectPrivacy(try live.encode())
}

@Test func fixtureContract() throws {
    let url = try repoFile("tests/fixtures/device-report.json")
    let fixtureData = try Data(contentsOf: url)
    let decoded = try DeviceReport.decode(fixtureData)
    let fixture = try jsonObject(fixtureData)
    let encoded = try jsonObject(try decoded.encode())
    #expect(Set(encoded.keys) == Set(fixture.keys))
    let fixtureJIT = try #require(fixture["jit"] as? [String: Any])
    let encodedJIT = try #require(encoded["jit"] as? [String: Any])
    #expect(Set(encodedJIT.keys) == Set(fixtureJIT.keys))
}

@MainActor
private func expectPrivacy(_ data: Data) throws {
    let names = [UIDevice.current.name, ProcessInfo.processInfo.hostName].filter { !$0.isEmpty }
    let found = stringKeysAndValues(try JSONSerialization.jsonObject(with: data))
    for name in names {
        #expect(!found.contains(name))
    }
}

private func stringKeysAndValues(_ value: Any) -> Set<String> {
    var found: Set<String> = []
    func walk(_ value: Any) {
        if let text = value as? String {
            found.insert(text)
        } else if let object = value as? [String: Any] {
            for (key, child) in object {
                found.insert(key)
                walk(child)
            }
        } else if let list = value as? [Any] {
            list.forEach(walk)
        }
    }
    walk(value)
    return found
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func repoFile(_ relative: String) throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
        url.deleteLastPathComponent()
        let candidate = url.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    Issue.record("missing \(relative); looked upward from \(#filePath)")
    throw CocoaError(.fileNoSuchFile)
}

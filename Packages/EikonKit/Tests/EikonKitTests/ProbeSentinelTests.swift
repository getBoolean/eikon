import Foundation
import Testing
@testable import EikonKit

private let absentTXM = TXMInfo(state: .absent, enforced: false, basis: "test")

private func facts(sentinel: Bool) -> JITFacts {
    JITFacts(installMethod: .dopamine, csDebugged: true, csDebuggedSeen: .atLaunch, txm: absentTXM,
             trollStoreRequest: .none, probeBlockedBySentinel: sentinel)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("probe-sentinel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func skipExactlyOneLaunch() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Armed and not disarmed: the probe killed the process.
    try ProbeSentinel(directory: directory, buildNumber: "B").arm()

    let blocked = ProbeSentinel(directory: directory, buildNumber: "B").consumeAtLaunch()
    #expect(blocked)
    #expect(!JITPolicy.mayProbe(facts(sentinel: blocked)))

    let nextLaunch = ProbeSentinel(directory: directory, buildNumber: "B").consumeAtLaunch()
    #expect(!nextLaunch)
    #expect(JITPolicy.mayProbe(facts(sentinel: nextLaunch)))
}

@Test func otherBuildsDoNotBlock() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    try ProbeSentinel(directory: directory, buildNumber: "A").arm()
    #expect(!ProbeSentinel(directory: directory, buildNumber: "B").consumeAtLaunch())
    #expect(!ProbeSentinel(directory: directory, buildNumber: "A").consumeAtLaunch())
}

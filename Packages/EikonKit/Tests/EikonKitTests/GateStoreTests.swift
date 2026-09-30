import EikonCore
import Foundation
import Testing
@testable import EikonKit

/// A store over `directory` that believes it runs under `app`/`os`.
private func store(_ directory: URL, app: String = "A1", os: String = "O1") -> GateStore {
    GateStore(directory: directory, current: BuildStamp(app: app, os: os))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func result(_ passed: Bool?) -> GateResult {
    GateResult(passed: passed, detail: "measured", measuredAt: Date(timeIntervalSince1970: 1_768_470_030))
}

@Test func passedResultExpiresUnderAnotherBuild() throws {
    let directory = try temporaryDirectory()
    store(directory).record(.x18, result(true))

    #expect(store(directory).states()[.x18] == .passed)
    #expect(store(directory).current()[GateName.x18.rawValue] == result(true))
    #expect(store(directory, app: "A2").states()[.x18] == .unmeasured)
    #expect(store(directory, os: "O2").states()[.x18] == .unmeasured)
    #expect(store(directory, app: "A2").current()[GateName.x18.rawValue] == nil)
}

@Test func failedResultTurnsStaleUnderAnotherBuildUntilRecordedAgain() throws {
    let directory = try temporaryDirectory()
    store(directory).record(.x18, result(false))

    let updated = store(directory, app: "A2")
    #expect(updated.states()[.x18] == .failed(stale: true))
    #expect(updated.current()[GateName.x18.rawValue] == result(false))

    updated.record(.x18, result(true))
    #expect(store(directory, app: "A2").states()[.x18] == .passed)
    updated.record(.x18, result(false))
    #expect(store(directory, app: "A2").states()[.x18] == .failed(stale: false))
}

@Test func unknownGateNameSurvivesReload() throws {
    let directory = try temporaryDirectory()
    let future = GateName(rawValue: "futureGate")
    store(directory).record(future, result(true))

    #expect(store(directory).states()[future] == .passed)
}

@Test func corruptFileIsReplacedOnNextRecord() throws {
    let directory = try temporaryDirectory()
    try Data("not json".utf8).write(to: directory.appendingPathComponent("gates.json"))
    let damaged = store(directory)
    #expect(damaged.states().isEmpty)

    damaged.record(.x18, result(true))
    #expect(store(directory).states()[.x18] == .passed)
}

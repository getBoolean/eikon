import Foundation
import Testing
import EikonCore

// MARK: Fakes

/// One synthesized collection folder and what it was built with.
private struct Built {
    let name: String
    /// Also the wrapper's name when the game sits inside one.
    let names: [String]
    let engine: Engine?
    let il2cpp: Bool
    let plugins: [String]
    let architectures: [CPUArchitecture]
    let gameExe: CPUArchitecture?
    let excluded: ExclusionRule?
}

/// A small collection covering every engine, two PE architectures plus an ELF, a wrapper,
/// a non-game folder and an excluded installer.
private func buildCollection(in root: URL) throws -> [Built] {
    var built: [Built] = []
    _ = try Fixtures.unity(.mono, named: "Alpha", in: root)
    built.append(Built(name: "Alpha", names: ["Alpha"], engine: .unity, il2cpp: false, plugins: [],
                       architectures: [.amd64], gameExe: .amd64, excluded: nil))

    let wrapper = root.appendingPathComponent("Bravo")
    _ = try Fixtures.unity(.il2cpp, named: "BravoInner", in: wrapper)
    built.append(Built(name: "Bravo", names: ["Bravo", "BravoInner"], engine: .unity, il2cpp: true, plugins: [],
                       architectures: [.amd64], gameExe: .amd64, excluded: nil))

    let kirikiri = try Fixtures.kirikiri(flavor: nil, tpm: ["extrans.tpm"], named: "Charlie", in: root)
    try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "unins000.exe", in: kirikiri)
    built.append(Built(name: "Charlie", names: ["Charlie"], engine: .kirikiri, il2cpp: false, plugins: ["extrans.tpm"],
                       architectures: [.i386], gameExe: .i386, excluded: .unins))

    _ = try Fixtures.renpy(.scriptVersion, named: "Delta", in: root)
    built.append(Built(name: "Delta", names: ["Delta"], engine: .renpy, il2cpp: false, plugins: [],
                       architectures: [.amd64, .amd64], gameExe: .amd64, excluded: nil))

    let gameMaker = root.appendingPathComponent("Echo")
    try Fixtures.write(Fixtures.gameMaker(hasCode: true), to: "data.win", in: gameMaker)
    try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Runner.exe", in: gameMaker)
    built.append(Built(name: "Echo", names: ["Echo"], engine: .gameMaker, il2cpp: false, plugins: [],
                       architectures: [.i386], gameExe: nil, excluded: nil))

    try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Foxtrot/BGI.exe", in: root)
    built.append(Built(name: "Foxtrot", names: ["Foxtrot"], engine: .bgi, il2cpp: false, plugins: [],
                       architectures: [.i386], gameExe: nil, excluded: nil))

    try Fixtures.write("notes", to: "Golf/readme.txt", in: root)
    built.append(Built(name: "Golf", names: ["Golf"], engine: nil, il2cpp: false, plugins: [],
                       architectures: [], gameExe: nil, excluded: nil))
    return built
}

private func scanned(_ root: URL, hash: Bool = false) throws -> CollectionSummary {
    guard case .scanned(let summary) = CollectionScan.run(root: root, hash: hash) else {
        throw ScanTestError.skipped
    }
    return summary
}

private enum ScanTestError: Error { case skipped }

private func counts<Key: Hashable>(_ keys: [Key]) -> [Key: Int] {
    keys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
}

// MARK: Tests

@Test func summaryCountsMatchSynthesizedCollection() throws {
    let root = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let built = try buildCollection(in: root)
    let summary = try scanned(root)

    #expect(summary.folders.count == built.count)
    #expect(summary.engineCounts == counts(built.compactMap(\.engine)))
    #expect(summary.count(.il2cpp) == built.filter(\.il2cpp).count)
    #expect(summary.pluginCounts == counts(built.flatMap(\.plugins)))
    #expect(summary.architectureCounts == counts(built.flatMap(\.architectures)))
    #expect(summary.gameExeArchitectureCounts == counts(built.compactMap(\.gameExe)))
    #expect(summary.noGameCount == built.filter { $0.engine == nil }.count)
    for rule in built.compactMap(\.excluded) {
        #expect(summary.exclusionCounts[rule, default: 0] > 0)
    }
}

@Test func formattedOutputContainsNoFolderNames() throws {
    let root = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let built = try buildCollection(in: root)
    let output = try scanned(root, hash: true).formatted(perFolder: true)

    for name in built.flatMap(\.names) {
        #expect(!output.contains(name))
    }
}

@Test func missingRootIsSkipped() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("eikon-missing-\(UUID().uuidString)")
    guard case .skipped = CollectionScan.run(root: missing, hash: false) else {
        Issue.record("expected the skipped outcome")
        return
    }
}

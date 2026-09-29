import CryptoKit
import Foundation
import Testing
import EikonCore

// MARK: Fakes

private let secret = LibrarySecret(bytes: Data(repeating: 7, count: LibrarySecret.byteCount))

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func fingerprint(_ folder: URL, secret: LibrarySecret = secret) throws -> Fingerprint {
    let detection = try #require(try GameDetector.detect(folder: folder))
    return try FingerprintBuilder.build(detection: detection, folder: folder, secret: secret)
}

private func declaredID(_ folder: URL) throws -> EngineDeclaredID.Result {
    try EngineDeclaredID.read(detection: try #require(try GameDetector.detect(folder: folder)), folder: folder)
}

/// A fingerprint from made-up tokens; tokens are hashed so they look like real keyed values.
private func fp(_ exact: String, engine: String? = nil) -> Fingerprint {
    func hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    return Fingerprint(engineID: engine.map { Keyed(hex: hex($0)) }, exact: Keyed(hex: hex(exact)))
}

/// Always mints the same id, so expectations can name it.
private final class Minter: @unchecked Sendable {
    let next = GameID.random()
    func mint() -> GameID { next }
}

// MARK: Signals and fingerprints

private enum DeclaredSource: CaseIterable {
    case renpy, unity, gameMaker, exeVersion

    func build(in dir: URL) throws -> URL {
        switch self {
        case .renpy:
            return try Fixtures.renpy(.scriptVersion, saveDirectory: "fixture-save-1234", in: dir)
        case .unity:
            return try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), in: dir)
        case .gameMaker:
            let root = dir.appendingPathComponent("Sample")
            try Fixtures.write(Fixtures.gameMaker(hasCode: true, names: ("fixture_project", "fixture-product")),
                               to: "data.win", in: root)
            try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: root)
            return root
        case .exeVersion:
            let root = dir.appendingPathComponent("Sample")
            try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, versionStrings: [
                "CompanyName": "fixture-company", "ProductName": "fixture-product",
            ]), to: "Game.exe", in: root)
            return root
        }
    }

    var plainValues: [String] {
        switch self {
        case .renpy: ["fixture-save-1234"]
        case .unity, .exeVersion: ["fixture-company", "fixture-product"]
        case .gameMaker: ["fixture_project", "fixture-product"]
        }
    }
}

@Test(arguments: DeclaredSource.allCases)
private func engineDeclaredIDIsRead(source: DeclaredSource) throws {
    try withTempDir { dir in
        let root = try source.build(in: dir)
        guard case .found = try declaredID(root) else { Issue.record("no declared id"); return }
        #expect(try fingerprint(root).engineID != nil)
    }
}

@Test func genericDeclaredValuesGiveNoEngineID() throws {
    try withTempDir { dir in
        let unity = try Fixtures.unity(.mono, appInfo: ("DefaultCompany", "My project"), named: "Unity", in: dir)
        let kirikiri = try Fixtures.kirikiri(flavor: "TVP(KIRIKIRI) Z", named: "Kirikiri", in: dir)
        for root in [unity, kirikiri] {
            #expect(try declaredID(root) == .generic)
            #expect(try fingerprint(root).engineID == nil)
        }
    }
}

@Test func renamingTheGameFolderKeepsTheFingerprint() throws {
    try withTempDir { dir in
        let root = try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), named: "Before", in: dir)
        let before = try fingerprint(root)
        let renamed = dir.appendingPathComponent("After")
        try FileManager.default.moveItem(at: root, to: renamed)
        #expect(try fingerprint(renamed) == before)
    }
}

private enum ContentChange: CaseIterable {
    case fileSize, sameSizeByteDeepInside
}

@Test(arguments: ContentChange.allCases)
private func anyContentChangeAltersExactButNotEngineID(change: ContentChange) throws {
    try withTempDir { dir in
        let root = try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), in: dir)
        let before = try fingerprint(root)

        let file = root.appendingPathComponent(change == .fileSize ? "UnityCrashHandler64.exe" : "Game_Data/globalgamemanagers")
        var data = try Data(contentsOf: file)
        switch change {
        case .fileSize: data.append(0)
        case .sameSizeByteDeepInside: data[data.count / 2] ^= 0xFF
        }
        try data.write(to: file)

        let after = try fingerprint(root)
        #expect(after.exact != before.exact)
        #expect(after.engineID == before.engineID)
    }
}

@Test func savesLeaveTheFingerprintUnchanged() throws {
    try withTempDir { dir in
        let root = try Fixtures.renpy(.scriptVersion, saveDirectory: "fixture-save-1234", in: dir)
        let before = try fingerprint(root)
        try Fixtures.write("slot", to: "game/saves/1-1-LT1.save", in: root)
        try Fixtures.write("slot", to: "savedata/data.sav", in: root)
        #expect(try fingerprint(root) == before)
    }
}

@Test func osMetadataFilesLeaveTheFingerprintUnchanged() throws {
    try withTempDir { dir in
        let root = try Fixtures.unity(.mono, in: dir)
        let before = try fingerprint(root)
        for name in [".DS_Store", "._Game.exe", "Thumbs.db", "desktop.ini"] {
            try Fixtures.write("metadata", to: name, in: root)
        }
        #expect(try fingerprint(root) == before)
    }
}

@Test(arguments: DeclaredSource.allCases)
private func fingerprintHoldsNoPlainText(source: DeclaredSource) throws {
    try withTempDir { dir in
        let root = try source.build(in: dir)
        let json = String(decoding: try JSONEncoder().encode(try fingerprint(root)), as: UTF8.self).lowercased()
        let listed = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .flatMap { $0.split(separator: "/").map(String.init) }
        for text in [root.lastPathComponent] + listed + source.plainValues {
            #expect(!json.contains(text.lowercased()))
        }
    }
}

@Test func secretDecidesTheKeyedValues() throws {
    try withTempDir { dir in
        let root = try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), in: dir)
        let other = LibrarySecret(bytes: Data(repeating: 9, count: LibrarySecret.byteCount))
        #expect(try fingerprint(root) == fingerprint(root))
        let first = try fingerprint(root), second = try fingerprint(root, secret: other)
        #expect(first.exact != second.exact)
        #expect(first.engineID != second.engineID)
    }
}

@Test func keyFileIsNeverALauncherOrPlayer() throws {
    try withTempDir { dir in
        for root in [try Fixtures.renpy(.scriptVersion, named: "RenPy", in: dir),
                     try Fixtures.unity(.mono, named: "Unity", in: dir)] {
            let detection = try #require(try GameDetector.detect(folder: root))
            let keyFile = try #require(detection.keyFile).lowercased()
            let executables = detection.executables.values.map { $0.path.lowercased() }
            #expect(!executables.contains(keyFile))
            #expect(!keyFile.contains("unityplayer"))
        }
    }
}

@Test func librarySecretIsCreatedOnceThenReadBack() throws {
    try withTempDir { dir in
        let url = dir.appendingPathComponent("support/library-secret")
        let created = try LibrarySecret.loadOrCreate(at: url)
        let loaded = try LibrarySecret.loadOrCreate(at: url)
        let game = try Fixtures.unity(.mono, in: dir)
        #expect(try fingerprint(game, secret: created) == fingerprint(game, secret: loaded))
    }
}

// MARK: Matcher

private let drive = UUID()
private let here = LocationKey(driveID: drive, folderName: "Folder")

private enum MatcherCase: CaseIterable {
    case inPlacePatch, exactUnderNewName, engineIDNotLiveHere, engineIDLiveHere,
         noEngineID, twoCandidates, noMatch, deletedGame

    func run() -> (result: MatchResult, expected: MatchResult) {
        let known = GameID.random(), other = GameID.random(), minter = Minter()
        func match(_ fingerprint: Fingerprint, _ games: [KnownGame],
                   locations: [LocationKey: GameID] = [:]) -> MatchResult {
            IdentityMatcher.match(fingerprint: fingerprint, at: here, knownLocations: locations, games: games,
                                  mint: minter.mint)
        }
        switch self {
        case .inPlacePatch:
            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e1")], hasLiveLocationHere: true)
            return (match(fp("v2", engine: "e2"), [game], locations: [here: known]), .keep(known))
        case .exactUnderNewName:
            let game = KnownGame(id: known, fingerprints: [fp("v1")], hasLiveLocationHere: true)
            return (match(fp("v1"), [game]), .attach(known, .exact))
        case .engineIDNotLiveHere:
            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e")], hasLiveLocationHere: false)
            return (match(fp("v2", engine: "e"), [game]), .attach(known, .engineID))
        case .engineIDLiveHere:
            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e")], hasLiveLocationHere: true)
            return (match(fp("v2", engine: "e"), [game]), .newGame(minter.next, suggestions: [known]))
        case .noEngineID:
            // Without an engine id, only the location or an exact match can find the game.
            let game = KnownGame(id: known, fingerprints: [fp("v1")], hasLiveLocationHere: false)
            return (match(fp("v2"), [game]), .newGame(minter.next, suggestions: []))
        case .twoCandidates:
            let games = [known, other].map {
                KnownGame(id: $0, fingerprints: [fp("v1", engine: "e")], hasLiveLocationHere: false)
            }
            return (match(fp("v2", engine: "e"), games),
                    .newGame(minter.next, suggestions: [known, other].sorted()))
        case .noMatch:
            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e1")], hasLiveLocationHere: false)
            return (match(fp("v2", engine: "e2"), [game]), .newGame(minter.next, suggestions: []))
        case .deletedGame:
            let game = KnownGame(id: known, fingerprints: [fp("v1")], hasLiveLocationHere: false, isDeleted: true)
            return (match(fp("v1"), [game], locations: [here: known]), .newGame(minter.next, suggestions: []))
        }
    }
}

@Test(arguments: MatcherCase.allCases)
private func matcherAppliesItsRules(scenario: MatcherCase) {
    let outcome = scenario.run()
    #expect(outcome.result == outcome.expected)
}

@Test func unmatchedGamesGetDistinctRandomIDs() {
    let first = IdentityMatcher.match(fingerprint: fp("a"), at: here, knownLocations: [:], games: [])
    let second = IdentityMatcher.match(fingerprint: fp("b"), at: here, knownLocations: [:], games: [])
    guard case .newGame(let a, _) = first, case .newGame(let b, _) = second else {
        Issue.record("expected new games")
        return
    }
    #expect(a != b)
}

@Test func fingerprintCapKeepsTheMostRecent() {
    let all = (0..<(Fingerprint.maxPerGame + 3)).map { fp("build-\($0)") }
    var list: [Fingerprint] = []
    for fingerprint in all { list = IdentityMatcher.adding(fingerprint, to: list) }
    #expect(list == Array(all.suffix(Fingerprint.maxPerGame)))

    let repeated = IdentityMatcher.adding(list[0], to: list)
    #expect(repeated.count == list.count)
    #expect(repeated.last == list[0])
}

// MARK: Merge and split

@Test func mergeMovesLocationsAndKeepsTheTargetsSettings() {
    let a = GameID.random(), b = GameID.random(), location = UUID()
    var ledger = IdentityLedger<String>(
        fingerprints: [a: [fp("a")], b: [fp("b")]], locations: [location: a],
        settings: [a: ["shared": "from-a", "only-a": "a"], b: ["shared": "from-b"]])
    ledger.merge(a, into: b)

    #expect(IdentityMatcher.resolve(a, links: ledger.links) == b)
    #expect(ledger.locations[location] == b)
    #expect(ledger.settings[b] == ["shared": "from-b", "only-a": "a"])
    #expect(ledger.fingerprints[b]?.contains(fp("a")) == true)
}

@Test func mergeLinksResolveThroughChainsAndCycles() {
    let ids = (0..<3).map { _ in GameID.random() }
    let chain = [ids[0]: ids[1], ids[1]: ids[2]]
    #expect(IdentityMatcher.resolve(ids[0], links: chain) == ids[2])

    let cycle = [ids[0]: ids[1], ids[1]: ids[0]]
    #expect(IdentityMatcher.resolve(ids[0], links: cycle) == IdentityMatcher.resolve(ids[1], links: cycle))
}

@Test func splitForksTheSettings() {
    let old = GameID.random(), location = UUID(), fingerprint = fp("split")
    var ledger = IdentityLedger<String>(fingerprints: [old: [fp("kept"), fingerprint]],
                                        locations: [location: old], settings: [old: ["key": "value"]])
    let new = ledger.split(location: location, fingerprint: fingerprint)

    #expect(new != old)
    #expect(ledger.locations[location] == new)
    #expect(ledger.settings[new] == ledger.settings[old])
    #expect(ledger.fingerprints[old]?.contains(fingerprint) == false)

    ledger.settings[new]?["key"] = "changed"
    ledger.settings[old]?["other"] = "added"
    #expect(ledger.settings[old]?["key"] == "value")
    #expect(ledger.settings[new]?["other"] == nil)
}

// MARK: Diagnostics hasher

@Test func fileHasherMatchesSHA256AndReportsProgress() throws {
    try withTempDir { dir in
        let data = Data((0..<(2 * FileHasher.chunkSize + 123)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = dir.appendingPathComponent("blob.bin")
        try data.write(to: url)

        var reported: [Double] = []
        let hex = try FileHasher.sha256(of: url, progress: { reported.append($0) }, isCancelled: { false })
        #expect(hex == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

@Test func fileHasherStopsEarlyOnCancel() throws {
    try withTempDir { dir in
        let url = dir.appendingPathComponent("blob.bin")
        try Data(count: 4 * FileHasher.chunkSize).write(to: url)

        var chunks = 0
        #expect(throws: CancellationError.self) {
            _ = try FileHasher.sha256(of: url, progress: { if $0 > 0 { chunks += 1 } }, isCancelled: { chunks >= 1 })
        }
        #expect(chunks == 1)
    }
}

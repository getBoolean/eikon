import Foundation
import Testing
import EikonCore

// MARK: Fakes

/// A settable wall clock.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func store(_ dir: URL, _ clock: TestClock = TestClock()) throws -> SettingsStore {
    try SettingsStore(directory: dir, now: clock.now, debounce: 3600)
}

private func ownFile(_ store: SettingsStore, in dir: URL) -> URL {
    dir.appendingPathComponent("settings/\(store.replicaID).json")
}

/// Rewrites a replica file's `format` so it looks like it came from a newer build.
private func makeFutureFormat(_ url: URL) throws {
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    object["format"] = 999
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}

/// Another device's replica file, written by a store in its own directory and copied in.
private func peerFile(into dir: URL, clock: TestClock = TestClock(), _ writes: (SettingsStore) -> Void) throws -> URL {
    let peerDir = dir.appendingPathComponent("peer-\(UUID().uuidString)")
    let peer = try store(peerDir, clock)
    writes(peer)
    peer.flush()
    let destination = dir.appendingPathComponent("settings/\(peer.replicaID).json")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: ownFile(peer, in: peerDir), to: destination)
    return destination
}

private let name = SettingKey<String>(name: "sample.name", scope: .game)
private let count = SettingKey<Int>(name: "sample.count", scope: .game)

/// A seeded generator, so the property test is deterministic.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: Merge laws

@Test func mergeIsCommutativeAssociativeAndIdempotent() {
    var random = SplitMix64(state: 42)
    let game = UUID()
    let keys = ["game/\(game.uuidString.lowercased())/a", "game/\(game.uuidString.lowercased())/b",
                "game/\(game.uuidString.lowercased())/deletedAt", "global.c"]
    let maps: [LWWMap] = (0..<3).map { _ in
        var clock = HybridClock(replica: .random())
        var map = LWWMap()
        var wall = 1_000_000.0
        for _ in 0..<200 {
            wall += Double(Int.random(in: -50...100, using: &random)) // includes backwards jumps
            let time = clock.tick(now: Date(timeIntervalSince1970: wall))
            let key = keys.randomElement(using: &random)!
            if Bool.random(using: &random) {
                map.set(key, .number(Double(Int.random(in: 0...9, using: &random))), at: time)
            } else {
                map.reset(key, at: time)
            }
        }
        return map
    }
    func merged(_ list: [LWWMap]) -> LWWMap {
        list.reduce(into: LWWMap()) { $0.merge($1) }
    }
    let reference = merged(maps)
    for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
        #expect(merged(order.map { maps[$0] }) == reference)
    }
    var left = maps[0]; left.merge(maps[1]); left.merge(maps[2])
    var right = maps[1]; right.merge(maps[2])
    var grouped = maps[0]; grouped.merge(right)
    #expect(left == grouped)

    var again = reference
    again.merge(maps[1])
    again.merge(reference)
    #expect(again == reference)
}

// MARK: Store behaviour

@Test func newerResetBeatsOlderSetAndNewerSetBeatsReset() throws {
    try withTempDir { dir in
        let clock = TestClock(), settings = try store(dir, clock), game = UUID()
        settings.set(name, "first", game: game)
        clock.advance(1)
        settings.reset(name, game: game)
        #expect(settings.value(name, game: game) == nil)
        clock.advance(1)
        settings.set(name, "second", game: game)
        #expect(settings.value(name, game: game) == "second")
    }
}

@Test func unknownKeysRoundTrip() throws {
    try withTempDir { dir in
        let unknown = SettingKey<[String: Int]>(name: "fex.fromANewerBuild", scope: .global)
        let newer = try store(dir)
        newer.set(unknown, ["x": 1])
        newer.flush()
        let before = try #require(newer.snapshot().entries[unknown.name])

        let current = try store(dir)
        current.set(name, "unrelated", game: UUID())
        current.flush()
        #expect(try store(dir).snapshot().entries[unknown.name] == before)
    }
}

@Test func clockNeverGoesBackwards() throws {
    try withTempDir { dir in
        let clock = TestClock(), settings = try store(dir, clock), game = UUID()
        settings.set(name, "earlier", game: game)
        clock.advance(-3600)
        settings.set(name, "later", game: game)
        #expect(settings.value(name, game: game) == "later")
    }
}

@Test func localWriteOrdersAfterAnObservedFutureTimestamp() throws {
    try withTempDir { dir in
        let future = TestClock(), game = UUID()
        future.advance(10 * 365 * 86_400)
        _ = try peerFile(into: dir, clock: future) { $0.set(name, "remote", game: game) }

        let settings = try store(dir)
        #expect(settings.value(name, game: game) == "remote")
        settings.set(name, "local", game: game)
        #expect(settings.value(name, game: game) == "local")
    }
}

@Test func peerFileInAFutureFormatIsMergedButNeverRewritten() throws {
    try withTempDir { dir in
        let game = UUID()
        let peer = try peerFile(into: dir) { $0.set(name, "from-peer", game: game) }
        try makeFutureFormat(peer)
        let before = try Data(contentsOf: peer)

        let settings = try store(dir)
        #expect(settings.value(name, game: game) == "from-peer")
        settings.set(count, 3, game: game)
        settings.flush()
        #expect(try Data(contentsOf: peer) == before)
    }
}

@Test func ownFileInAFutureFormatForksToANewReplica() throws {
    try withTempDir { dir in
        let game = UUID()
        let original = try store(dir)
        original.set(name, "kept", game: game)
        original.flush()
        let oldFile = ownFile(original, in: dir)
        try makeFutureFormat(oldFile)
        let before = try Data(contentsOf: oldFile)

        let forked = try store(dir)
        #expect(forked.forkedFrom == original.replicaID)
        #expect(forked.replicaID != original.replicaID)
        #expect(forked.value(name, game: game) == "kept")
        forked.set(count, 1, game: game)
        forked.flush()
        #expect(try Data(contentsOf: oldFile) == before)
        #expect(FileManager.default.fileExists(atPath: ownFile(forked, in: dir).path))

        let reopened = try store(dir)
        #expect(reopened.replicaID == forked.replicaID)
        #expect(reopened.forkedFrom == original.replicaID)
    }
}

@Test func deletedAtHidesOlderKeysOnlyForThatGame() throws {
    try withTempDir { dir in
        let clock = TestClock(), game = UUID(), other = UUID()
        _ = try peerFile(into: dir, clock: clock) { $0.set(count, 7, game: game) }
        let settings = try store(dir, clock)
        settings.set(name, "before", game: game)
        settings.set(name, "untouched", game: other)
        clock.advance(1)

        settings.removeAll(game: game)
        #expect(settings.isDeleted(game: game))
        #expect(settings.value(name, game: game) == nil)
        #expect(settings.value(count, game: game) == nil)
        #expect(settings.value(name, game: other) == "untouched")
        #expect(!settings.knownGames().contains(game))

        clock.advance(1)
        settings.set(name, "after", game: game)
        #expect(settings.value(name, game: game) == "after")
    }
}

@Test func valueOfTheWrongTypeReadsAsUnset() throws {
    try withTempDir { dir in
        let settings = try store(dir), game = UUID()
        settings.set(SettingKey<String>(name: count.name, scope: .game), "not a number", game: game)
        #expect(settings.value(count, game: game) == nil)
    }
}

@Test func writesPersistAcrossInstances() throws {
    try withTempDir { dir in
        let game = UUID()
        let first = try store(dir)
        first.set(name, "saved", game: game)
        first.set(count, Int.max, game: game)
        first.set(SettingKey<String>.merged(game), UUID().uuidString)
        first.flush()

        let second = try store(dir)
        #expect(second.replicaID == first.replicaID)
        #expect(second.value(name, game: game) == "saved")
        #expect(second.value(count, game: game) == Int.max)
        #expect(second.value(SettingKey<String>.merged(game)) == first.value(SettingKey<String>.merged(game)))
    }
}

@Test func fingerprintSlotsKeepTheMostRecent() throws {
    try withTempDir { dir in
        let clock = TestClock(), settings = try store(dir, clock), game = UUID()
        let added = (0..<(SettingsStore.fingerprintCap + 2)).map { "fingerprint-\($0)" }
        for fingerprint in added {
            settings.addFingerprint(fingerprint, scheme: 1, game: game)
            clock.advance(1)
        }
        let kept = settings.fingerprints(game: game, scheme: 1, as: String.self)
        #expect(kept == Array(added.suffix(SettingsStore.fingerprintCap).reversed()))
        #expect(!kept.contains(added[0]))
    }
}

import EikonCore
import Foundation
import Testing
@testable import EikonKit

// MARK: Fakes

/// Bookmarks are the folder's path; each can be scripted to open, be unplugged or go stale.
private final class FakeAccess: FolderAccess, @unchecked Sendable {
    enum Mode { case opened, notConnected, stale }

    private let lock = NSLock()
    private var modes: [String: Mode] = [:]
    private var kinds: [String: VolumeKind] = [:]

    func set(_ mode: Mode, for url: URL) {
        lock.withLock { modes[url.path] = mode }
    }

    func set(_ kind: VolumeKind, for url: URL) {
        lock.withLock { kinds[url.path] = kind }
    }

    func makeBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func open(bookmark: Data) throws -> AccessOutcome {
        let path = String(decoding: bookmark, as: UTF8.self)
        switch lock.withLock({ modes[path] }) ?? .opened {
        case .opened: return .opened(AccessToken(url: URL(fileURLWithPath: path, isDirectory: true)) {}, refreshedBookmark: nil)
        case .notConnected: return .notConnected
        case .stale: return .stale
        }
    }

    func volumeKind(of url: URL) -> VolumeKind {
        lock.withLock { kinds[url.path] } ?? .internal
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

private final class CountingCleanup: GameDataCleanup, @unchecked Sendable {
    private let lock = NSLock()
    private var removed: [GameID] = []

    var calls: [GameID] { lock.withLock { removed } }

    func removeData(for game: GameID) async {
        lock.withLock { removed.append(game) }
    }
}

private final class Space: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 1 << 40

    var value: Int64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

private struct NoBackground: BackgroundActivity {
    @MainActor func begin(_ name: String) -> @MainActor @Sendable () -> Void { {} }
}

// MARK: Harness

/// A tiny Ren'Py-style game. `declaredID` becomes its engine-declared id; `content`
/// varies the compiled script, so different contents make a different game build.
@discardableResult
private func makeGame(_ name: String, in directory: URL, declaredID: String? = "SampleGame", content: String = "one") throws -> URL {
    let root = directory.appendingPathComponent(name, isDirectory: true)
    try write("# engine\n", to: "renpy/__init__.py", in: root)
    try write("RPC2" + content, to: "game/script.rpyc", in: root)
    if let declaredID {
        try write("define config.save_directory = \"\(declaredID)\"\n", to: "game/options.rpy", in: root)
    }
    return root
}

private func write(_ text: String, to relative: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@MainActor
private final class Harness {
    let root: URL
    let documents: URL
    let access = FakeAccess()
    let clock = Clock()
    let space = Space()
    let hooks = GameDataHooks()
    let settings: SettingsController
    let library: LibraryController

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let clock = clock, space = space
        settings = SettingsController(store: try SettingsStore(directory: support, now: { clock.now }))
        library = LibraryController(index: LibraryIndex(directory: support), settings: settings,
                                    secret: LibrarySecret(bytes: Data(repeating: 7, count: LibrarySecret.byteCount)),
                                    access: access, builtInRoot: documents, hooks: hooks, now: { clock.now },
                                    freeSpace: { _ in space.value }, background: NoBackground())
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var builtIn: GameDrive {
        library.context.index.contents.drives.first { $0.kind == .builtIn }!
    }

    /// A new folder drive on internal storage.
    func addDrive() throws -> (url: URL, drive: GameDrive) {
        let url = root.appendingPathComponent("Drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, try library.driveManager.add(url).get())
    }

    func scan() {
        library.scanner.scanAll()
    }

    /// Two scans a quiescence interval apart, then the full pass for everything queued.
    func settle() {
        scan()
        clock.advance(DriveScanner.quiescence + 1)
        scan()
        while library.worker.processNext() {}
    }

    func location(_ name: String, on drive: GameDrive? = nil) -> GameLocation? {
        let driveID = drive?.id ?? builtIn.id
        return library.context.index.contents.locations.first { $0.driveID == driveID && $0.folderName == name }
    }

    func locations(on drive: GameDrive) -> [GameLocation] {
        library.context.index.contents.locations.filter { $0.driveID == drive.id }
    }

    /// The location's game, resolved through merges.
    func game(_ name: String, on drive: GameDrive? = nil) -> GameID? {
        location(name, on: drive)?.gameID.map { IdentityMatcher.resolve($0, links: settings.store.mergeLinks()) }
    }
}

// MARK: Drives

@Test @MainActor func addingDriveAcceptsOnlyLocalVolumes() throws {
    let harness = try Harness()
    var refusals: [DriveRefusal] = []
    for kind in [VolumeKind.ubiquitous, .network, .unknown] {
        let url = harness.root.appendingPathComponent(UUID().uuidString)
        harness.access.set(kind, for: url)
        guard case .failure(let refusal) = harness.library.driveManager.add(url) else {
            Issue.record("accepted a refused volume")
            continue
        }
        refusals.append(refusal)
    }
    #expect(Set(refusals.map { "\($0)" }).count == 3)

    for kind in [VolumeKind.internal, .externalLocal] {
        let url = harness.root.appendingPathComponent(UUID().uuidString)
        harness.access.set(kind, for: url)
        #expect((try? harness.library.driveManager.add(url).get()) != nil)
    }

    // A folder inside another drive would list its games twice.
    let nested = harness.documents.appendingPathComponent("Games", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    #expect((try? harness.library.driveManager.add(nested).get()) == nil)
}

@Test @MainActor func disconnectedDriveMakesItsGamesUnreachable() async throws {
    let harness = try Harness()
    let (url, drive) = try harness.addDrive()
    try makeGame("Sample", in: url)
    harness.settle()
    let game = try #require(harness.game("Sample", on: drive))

    harness.access.set(.notConnected, for: url)
    await harness.library.reevaluateDriveStates()
    #expect(harness.library.launchLocation(for: game) == .driveNotConnected)
}

@Test @MainActor func relinkAsksOnlyWhenNoKnownFolderIsThere() throws {
    let harness = try Harness()
    let (url, drive) = try harness.addDrive()
    try makeGame("Sample", in: url)
    harness.scan()

    let unrelated = harness.root.appendingPathComponent("Unrelated", isDirectory: true)
    try makeGame("Different", in: unrelated)
    #expect(harness.library.driveManager.relink(drive.id, to: unrelated, confirmed: false) == .needsConfirmation)

    let moved = harness.root.appendingPathComponent("Moved", isDirectory: true)
    try makeGame("Sample", in: moved)
    #expect(harness.library.driveManager.relink(drive.id, to: moved, confirmed: false) == .relinked)
    #expect(harness.location("Sample", on: drive) != nil)
}

// MARK: Scanning

@Test @MainActor func scannerSkipsDotFoldersAndInbox() throws {
    let harness = try Harness()
    try makeGame("Sample", in: harness.documents)
    try makeGame(".hidden", in: harness.documents)
    try makeGame("Sample", in: harness.documents.appendingPathComponent(".eikon-importing-\(UUID().uuidString)"))
    try makeGame("Inbox", in: harness.documents)
    harness.scan()
    #expect(harness.locations(on: harness.builtIn).count == 1)
}

@Test @MainActor func newFolderBecomesLocationAndVanishedOneGoesMissing() throws {
    let harness = try Harness()
    let folder = try makeGame("Sample", in: harness.documents)
    harness.scan()
    let location = try #require(harness.location("Sample"))

    try FileManager.default.removeItem(at: folder)
    harness.scan()
    #expect(harness.location("Sample")?.id == location.id)
    #expect(harness.location("Sample")?.identity == .missing)
}

@Test @MainActor func changingFolderGetsNoIdentityUntilItSettles() throws {
    let harness = try Harness()
    let folder = try makeGame("Sample", in: harness.documents)
    harness.scan()
    try write("RPC2two", to: "game/script.rpyc", in: folder)
    harness.clock.advance(DriveScanner.quiescence + 1)
    harness.scan()
    #expect(harness.location("Sample")?.gameID == nil)

    harness.clock.advance(DriveScanner.quiescence / 2)
    harness.scan()
    #expect(harness.location("Sample")?.gameID == nil)

    harness.clock.advance(DriveScanner.quiescence / 2 + 1)
    harness.scan()
    #expect(harness.location("Sample")?.gameID != nil)
    #expect(harness.location("Sample")?.fingerprint == nil)
}

@Test @MainActor func fingerprintOfChangingFolderIsDiscardedAndRebuilt() throws {
    let harness = try Harness()
    let folder = try makeGame("Sample", in: harness.documents)
    harness.scan()
    harness.clock.advance(DriveScanner.quiescence + 1)
    harness.scan()

    let patched = Space()
    patched.value = 0
    harness.library.worker.onProgress = { _, _ in
        guard patched.value == 0 else { return }
        patched.value = 1
        try? write("RPC2two", to: "game/script.rpyc", in: folder)
    }
    harness.library.worker.processNext()
    #expect(harness.location("Sample")?.fingerprint == nil)

    harness.library.worker.onProgress = nil
    harness.settle()
    #expect(harness.location("Sample")?.fingerprint != nil)
}

@Test @MainActor func unrecognizedFolderIsDetectedAgainAfterItChanges() throws {
    let harness = try Harness()
    let folder = harness.documents.appendingPathComponent("Sample", isDirectory: true)
    try write("notes\n", to: "readme.txt", in: folder)
    harness.scan()
    #expect(harness.location("Sample")?.detection == nil)

    try makeGame("Sample", in: harness.documents)
    harness.scan()
    #expect(harness.location("Sample")?.detection != nil)
}

// MARK: Import

@Test @MainActor func importLandsOnceAndLeavesSourceUnchanged() async throws {
    let harness = try Harness()
    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
    let before = try FileManager.default.subpathsOfDirectory(atPath: source.path).sorted()

    let outcome = await harness.library.importGame(from: source, to: harness.builtIn.id)
    guard case .imported(let id) = outcome else { Issue.record("not imported"); return }
    #expect(exists(harness.documents.appendingPathComponent("Sample/game/script.rpyc")))
    harness.scan()
    harness.scan()
    #expect(harness.locations(on: harness.builtIn).map(\.id) == [id])
    #expect(try FileManager.default.subpathsOfDirectory(atPath: source.path).sorted() == before)
}

@Test @MainActor func importOntoExistingNameOffersReplaceOrRename() async throws {
    let harness = try Harness()
    try makeGame("Sample", in: harness.documents)
    harness.settle()
    let game = try #require(harness.game("Sample"))
    harness.settings.setDisplayName("Mine", for: game)
    let update = try makeGame("Sample", in: harness.root.appendingPathComponent("Update"), content: "two")

    #expect(await harness.library.importGame(from: update, to: harness.builtIn.id) == .nameClash)
    #expect(await harness.library.importGame(from: update, to: harness.builtIn.id, naming: .rename("sample")) == .nameTaken)
    guard case .imported(let renamed) = await harness.library.importGame(from: update, to: harness.builtIn.id,
                                                                        naming: .rename("Sample Copy")) else {
        Issue.record("rename not imported")
        return
    }
    #expect(renamed != harness.location("Sample")?.id)

    let replaced = await harness.library.importGame(from: update, to: harness.builtIn.id, naming: .replaceExisting)
    #expect(replaced == .imported(try #require(harness.location("Sample")?.id)))
    harness.settle()
    #expect(harness.game("Sample") == game)
    #expect(harness.settings.displayName(for: game) == "Mine")
}

@Test @MainActor func cancelledOrFailedImportLeavesNothingBehind() async throws {
    let harness = try Harness()
    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
    #expect(await harness.library.importer.importGame(from: source, to: harness.builtIn.id, isCancelled: { true }) == .cancelled)

    let unreadable = source.appendingPathComponent("game/script.rpyc")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
    #expect(await harness.library.importer.importGame(from: source, to: harness.builtIn.id) == .failed)

    #expect(try FileManager.default.contentsOfDirectory(atPath: harness.documents.path).isEmpty)
    #expect(harness.locations(on: harness.builtIn).isEmpty)
}

@Test @MainActor func leftoverStagingIsRemovedAtStartup() throws {
    let harness = try Harness()
    let staging = harness.documents.appendingPathComponent(".eikon-importing-\(UUID().uuidString)")
    try makeGame("Sample", in: staging)
    harness.library.importer.cleanStaleStaging()
    #expect(!exists(staging))
}

@Test @MainActor func importNeedingMoreSpaceIsRefusedBeforeCopying() async throws {
    let harness = try Harness()
    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
    harness.space.value = 0
    #expect(await harness.library.importGame(from: source, to: harness.builtIn.id) == .insufficientSpace)
    #expect(try FileManager.default.contentsOfDirectory(atPath: harness.documents.path).isEmpty)
}

@Test @MainActor func importDoesNotFollowSymlinksOutOfTheSource() async throws {
    let harness = try Harness()
    let outside = harness.root.appendingPathComponent("Outside", isDirectory: true)
    try write("private\n", to: "secret.txt", in: outside)
    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: outside)

    guard case .imported = await harness.library.importGame(from: source, to: harness.builtIn.id) else {
        Issue.record("not imported")
        return
    }
    #expect(exists(harness.documents.appendingPathComponent("Sample/renpy/__init__.py")))
    #expect(!exists(harness.documents.appendingPathComponent("Sample/link/secret.txt")))
}

// MARK: Identity across drives

@Test @MainActor func patchKeepsIdentityAndSettings() throws {
    let harness = try Harness()
    let folder = try makeGame("Sample", in: harness.documents)
    harness.settle()
    let game = try #require(harness.game("Sample"))
    let detection = harness.location("Sample")?.detection
    harness.settings.setDisplayName("Mine", for: game)

    try write("RPC2two", to: "game/script.rpyc", in: folder)
    try write("(7, 4, 11)", to: "game/script_version.txt", in: folder)
    harness.settle()
    #expect(harness.game("Sample") == game)
    #expect(harness.settings.displayName(for: game) == "Mine")
    #expect(harness.location("Sample")?.detection != detection)
    #expect(harness.settings.store.fingerprints(game: game.uuid).count == 2)
}

@Test @MainActor func settledGameGetsAnIDBeforeItsFullFingerprint() throws {
    let harness = try Harness()
    try makeGame("Sample", in: harness.documents)
    harness.scan()
    harness.clock.advance(DriveScanner.quiescence + 1)
    harness.scan()

    let game = try #require(harness.game("Sample"))
    #expect(harness.location("Sample")?.fingerprint == nil)
    harness.settings.setDisplayName("Mine", for: game)
    #expect(harness.settings.displayName(for: game) == "Mine")
}

@Test @MainActor func provisionalCopyMergesSilentlyUnlessItHasSettings() throws {
    let harness = try Harness()
    let original = try makeGame("Sample", in: harness.documents)
    harness.settle()
    let game = try #require(harness.game("Sample"))

    let (first, firstDrive) = try harness.addDrive()
    try FileManager.default.copyItem(at: original, to: first.appendingPathComponent("Sample"))
    harness.settle()
    #expect(harness.game("Sample", on: firstDrive) == game)

    let (second, secondDrive) = try harness.addDrive()
    try FileManager.default.copyItem(at: original, to: second.appendingPathComponent("Sample"))
    harness.scan()
    harness.clock.advance(DriveScanner.quiescence + 1)
    harness.scan()
    let provisional = try #require(harness.game("Sample", on: secondDrive))
    harness.settings.setDisplayName("Mine", for: provisional)
    while harness.library.worker.processNext() {}
    #expect(harness.game("Sample", on: secondDrive) == provisional)
    #expect(harness.location("Sample", on: secondDrive)?.suggestion.contains(game) == true)
}

@Test @MainActor func renamingOrMovingAGameKeepsItsID() throws {
    let harness = try Harness()
    let folder = try makeGame("Sample", in: harness.documents)
    harness.settle()
    let game = try #require(harness.game("Sample"))

    let renamed = harness.documents.appendingPathComponent("Renamed")
    try FileManager.default.moveItem(at: folder, to: renamed)
    harness.settle()
    #expect(harness.game("Renamed") == game)

    let (url, drive) = try harness.addDrive()
    try FileManager.default.moveItem(at: renamed, to: url.appendingPathComponent("Renamed"))
    harness.settle()
    #expect(harness.game("Renamed", on: drive) == game)
}

@Test @MainActor func sameGameOnTwoDrivesIsOneGame() async throws {
    let harness = try Harness()
    let original = try makeGame("Sample", in: harness.documents, declaredID: nil)
    let (url, _) = try harness.addDrive()
    try FileManager.default.copyItem(at: original, to: url.appendingPathComponent("Sample"))
    harness.settle()

    await harness.library.rescan()
    #expect(harness.library.games.count == 1)
    #expect(harness.library.games.first?.locations.count == 2)
}

@Test @MainActor func differentVersionIsANewGameWithASuggestion() async throws {
    let harness = try Harness()
    try makeGame("Sample", in: harness.documents)
    harness.settle()
    let game = try #require(harness.game("Sample"))

    let (url, drive) = try harness.addDrive()
    try makeGame("Sample", in: url, content: "two")
    harness.settle()
    let other = try #require(harness.game("Sample", on: drive))
    #expect(other != game)
    #expect(harness.location("Sample", on: drive)?.suggestion.contains(game) == true)

    await harness.library.merge(other, into: game)
    #expect(harness.game("Sample", on: drive) == game)
}

// MARK: Fingerprint worker

@Test @MainActor func suspendedWorkerMakesNoProgressUntilResumed() throws {
    let harness = try Harness()
    try makeGame("Sample", in: harness.documents)
    harness.scan()
    harness.clock.advance(DriveScanner.quiescence + 1)
    harness.scan()

    harness.library.worker.suspend()
    #expect(!harness.library.worker.processNext())
    #expect(harness.location("Sample")?.fingerprint == nil)
    harness.library.worker.resume()
    #expect(harness.library.worker.processNext())
    #expect(harness.location("Sample")?.fingerprint != nil)
}

@Test @MainActor func viewedLocationIsFingerprintedFirst() throws {
    let harness = try Harness()
    try makeGame("First", in: harness.documents, content: "one")
    try makeGame("Second", in: harness.documents, content: "two")
    harness.scan()
    harness.clock.advance(DriveScanner.quiescence + 1)
    harness.scan()

    harness.library.setViewedLocation(harness.location("Second")?.id)
    harness.library.worker.processNext()
    #expect(harness.location("Second")?.fingerprint != nil)
    #expect(harness.location("First")?.fingerprint == nil)
}

// MARK: Remove

@Test @MainActor func removingWithDataUnsetsSettingsAndRunsCleanupOnce() async throws {
    let harness = try Harness()
    try makeGame("First", in: harness.documents, declaredID: "First")
    try makeGame("Second", in: harness.documents, declaredID: "Second", content: "two")
    harness.settle()
    let first = try #require(harness.game("First")), second = try #require(harness.game("Second"))
    harness.settings.setDisplayName("One", for: first)
    harness.settings.setDisplayName("Two", for: second)
    let cleanup = CountingCleanup()
    harness.hooks.register(cleanup)

    await harness.library.remove(game: first, deleteLocations: [], deleteData: true)
    #expect(harness.settings.displayName(for: first) == nil)
    #expect(harness.settings.store.fingerprints(game: first.uuid).isEmpty)
    #expect(cleanup.calls == [first])
    #expect(harness.settings.displayName(for: second) == "Two")
    #expect(harness.game("Second") == second)
}

@Test @MainActor func deletingFilesRemovesOnlyTheCheckedLocations() async throws {
    let harness = try Harness()
    let original = try makeGame("Sample", in: harness.documents)
    let (url, drive) = try harness.addDrive()
    try FileManager.default.copyItem(at: original, to: url.appendingPathComponent("Sample"))
    try makeGame("Other", in: url, declaredID: "Other", content: "two")
    harness.settle()
    let game = try #require(harness.game("Sample"))
    #expect(harness.game("Sample", on: drive) == game)

    let checked = try #require(harness.location("Sample")?.id)
    await harness.library.remove(game: game, deleteLocations: [checked], deleteData: false)
    #expect(!exists(original))
    #expect(exists(url.appendingPathComponent("Sample")))
    #expect(exists(url.appendingPathComponent("Other")))
}

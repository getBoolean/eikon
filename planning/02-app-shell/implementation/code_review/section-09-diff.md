diff --git a/App/Info.plist b/App/Info.plist
index 303de15..2c8d8c3 100644
--- a/App/Info.plist
+++ b/App/Info.plist
@@ -26,11 +26,15 @@
 	<string>development</string>
 	<key>LSRequiresIPhoneOS</key>
 	<true/>
+	<key>LSSupportsOpeningDocumentsInPlace</key>
+	<true/>
 	<key>UIApplicationSceneManifest</key>
 	<dict>
 		<key>UIApplicationSupportsMultipleScenes</key>
 		<false/>
 	</dict>
+	<key>UIFileSharingEnabled</key>
+	<true/>
 	<key>UILaunchScreen</key>
 	<dict/>
 	<key>UISupportedInterfaceOrientations</key>
diff --git a/Packages/EikonCore/Sources/EikonCore/Library/FolderAccess.swift b/Packages/EikonCore/Sources/EikonCore/Library/FolderAccess.swift
new file mode 100644
index 0000000..5f6619d
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Library/FolderAccess.swift
@@ -0,0 +1,44 @@
+import Foundation
+
+public enum AccessOutcome: Sendable {
+    /// Open until the token closes. `refreshedBookmark`: the bookmark was stale but
+    /// resolved, and this replaces it.
+    case opened(AccessToken, refreshedBookmark: Data?)
+    /// The volume is absent.
+    case notConnected
+    /// The bookmark can't be resolved any more.
+    case stale
+}
+
+/// Reaches folders outside the container through security-scoped bookmarks.
+public protocol FolderAccess: Sendable {
+    func makeBookmark(for url: URL) throws -> Data
+    func open(bookmark: Data) throws -> AccessOutcome
+    func volumeKind(of url: URL) -> VolumeKind
+}
+
+/// Access to one folder, held until `close()`. Closing is idempotent; deinit closes as a
+/// backstop.
+public final class AccessToken: @unchecked Sendable {
+    public let url: URL
+    private let onClose: @Sendable () -> Void
+    private let lock = NSLock()
+    private var closed = false
+
+    public init(url: URL, onClose: @escaping @Sendable () -> Void) {
+        self.url = url
+        self.onClose = onClose
+    }
+
+    deinit {
+        close()
+    }
+
+    public func close() {
+        let first = lock.withLock {
+            defer { closed = true }
+            return !closed
+        }
+        if first { onClose() }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Library/GameDrive.swift b/Packages/EikonCore/Sources/EikonCore/Library/GameDrive.swift
new file mode 100644
index 0000000..512b928
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Library/GameDrive.swift
@@ -0,0 +1,61 @@
+import Foundation
+
+/// A folder whose immediate subfolders are games: the app's own `Documents/`, or a folder
+/// the user picked (on the device or a USB drive).
+public struct GameDrive: Codable, Sendable, Equatable, Identifiable {
+    public var id: UUID
+    public var kind: DriveKind
+    /// User-visible and device-local (the folder's name); never logged or exported.
+    public var label: String
+
+    public init(id: UUID, kind: DriveKind, label: String) {
+        self.id = id
+        self.kind = kind
+        self.label = label
+    }
+}
+
+public enum DriveKind: Codable, Sendable, Equatable {
+    /// `Documents/`: needs no bookmark and is always available.
+    case builtIn
+    /// A picked folder, reached through its security-scoped bookmark.
+    case folder(bookmark: Data)
+
+    private enum Key: String, CodingKey { case type, bookmark }
+
+    /// An unknown kind from a newer build fails to decode, so the index keeps that drive's
+    /// raw form and writes it back unchanged.
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: Key.self)
+        switch try container.decode(String.self, forKey: .type) {
+        case "builtIn": self = .builtIn
+        case "folder": self = .folder(bookmark: try container.decode(Data.self, forKey: .bookmark))
+        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown drive kind")
+        }
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var container = encoder.container(keyedBy: Key.self)
+        switch self {
+        case .builtIn:
+            try container.encode("builtIn", forKey: .type)
+        case .folder(let bookmark):
+            try container.encode("folder", forKey: .type)
+            try container.encode(bookmark, forKey: .bookmark)
+        }
+    }
+}
+
+public enum DriveState: Sendable, Equatable {
+    case available
+    /// The volume is absent (unplugged).
+    case notConnected
+    /// The bookmark is stale and can't be resolved: the user has to find the folder again.
+    case needsRelink
+}
+
+/// Where a folder lives. Only internal and external-local volumes can be game drives:
+/// evictable or network files are unsafe under an in-process emulator.
+public enum VolumeKind: Sendable, Equatable {
+    case `internal`, externalLocal, ubiquitous, network, unknown
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Library/GameLocation.swift b/Packages/EikonCore/Sources/EikonCore/Library/GameLocation.swift
new file mode 100644
index 0000000..70206c3
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Library/GameLocation.swift
@@ -0,0 +1,111 @@
+import Foundation
+
+/// One game folder on one drive. Several locations can belong to one game.
+public struct GameLocation: Codable, Sendable, Equatable, Identifiable {
+    public var id: UUID
+    public var driveID: UUID
+    /// Device-local only; a title in practice, so never logged or exported.
+    public var folderName: String
+    /// Cached; nil when no game was found (listed under "Not recognized").
+    public var detection: DetectionResult?
+    /// The latest full fingerprint; nil until one has been computed.
+    public var fingerprint: Fingerprint?
+    /// nil only until the first match runs.
+    public var gameID: GameID?
+    public var identity: IdentityState
+    public var lastSeen: LocationSeen
+    /// The content stamp `fingerprint` was built from.
+    public var fingerprintedStamp: String?
+    /// Launch-location preference.
+    public var lastUsedAt: Date?
+    /// Non-blocking "same game as…?" candidates.
+    public var suggestion: [GameID]
+    public var dismissedSuggestions: [GameID]
+
+    public init(id: UUID = UUID(), driveID: UUID, folderName: String, detection: DetectionResult? = nil,
+                fingerprint: Fingerprint? = nil, gameID: GameID? = nil, identity: IdentityState = .pending,
+                lastSeen: LocationSeen = LocationSeen(), fingerprintedStamp: String? = nil, lastUsedAt: Date? = nil,
+                suggestion: [GameID] = [], dismissedSuggestions: [GameID] = []) {
+        self.id = id
+        self.driveID = driveID
+        self.folderName = folderName
+        self.detection = detection
+        self.fingerprint = fingerprint
+        self.gameID = gameID
+        self.identity = identity
+        self.lastSeen = lastSeen
+        self.fingerprintedStamp = fingerprintedStamp
+        self.lastUsedAt = lastUsedAt
+        self.suggestion = suggestion
+        self.dismissedSuggestions = dismissedSuggestions
+    }
+}
+
+/// Where a location is in finding its identity.
+public enum IdentityState: Codable, Sendable, Equatable {
+    /// New, or waiting for the fingerprint worker.
+    case pending
+    /// The contents are still changing (a copy or patch in progress).
+    case waitingForQuiescence
+    /// The full fingerprint is being built. Persisted, it loads as `pending`.
+    case fingerprinting
+    case identified
+    case failed(IdentityFailure)
+    /// The folder vanished while its drive was available. Never deleted automatically.
+    case missing
+
+    private enum Key: String, CodingKey { case state, code }
+
+    /// Unknown states (from a newer build) and `fingerprinting` load as `pending`.
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: Key.self)
+        switch try container.decode(String.self, forKey: .state) {
+        case "waitingForQuiescence": self = .waitingForQuiescence
+        case "identified": self = .identified
+        case "missing": self = .missing
+        case "failed": self = .failed((try? container.decode(IdentityFailure.self, forKey: .code)) ?? .unreadable)
+        default: self = .pending
+        }
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var container = encoder.container(keyedBy: Key.self)
+        switch self {
+        case .pending: try container.encode("pending", forKey: .state)
+        case .waitingForQuiescence: try container.encode("waitingForQuiescence", forKey: .state)
+        case .fingerprinting: try container.encode("fingerprinting", forKey: .state)
+        case .identified: try container.encode("identified", forKey: .state)
+        case .missing: try container.encode("missing", forKey: .state)
+        case .failed(let code):
+            try container.encode("failed", forKey: .state)
+            try container.encode(code, forKey: .code)
+        }
+    }
+}
+
+/// App-defined failure codes; never a path or name.
+public enum IdentityFailure: String, Codable, Sendable, Equatable {
+    /// A file in the game couldn't be read.
+    case unreadable
+    /// The drive couldn't be opened.
+    case driveUnavailable
+}
+
+/// What the scanner saw last, to tell when to re-detect and when a copy has settled.
+public struct LocationSeen: Codable, Sendable, Equatable {
+    /// `FingerprintBuilder.contentStamp` of the game root.
+    public var contentStamp: String?
+    /// When `contentStamp` was first seen with its current value.
+    public var stampSince: Date?
+    /// Digest of the folder's top-level names.
+    public var listingDigest: String?
+    /// The folder's modification date.
+    public var modifiedAt: Date?
+
+    public init(contentStamp: String? = nil, stampSince: Date? = nil, listingDigest: String? = nil, modifiedAt: Date? = nil) {
+        self.contentStamp = contentStamp
+        self.stampSince = stampSince
+        self.listingDigest = listingDigest
+        self.modifiedAt = modifiedAt
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Library/LibraryIndex.swift b/Packages/EikonCore/Sources/EikonCore/Library/LibraryIndex.swift
new file mode 100644
index 0000000..ea50afc
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Library/LibraryIndex.swift
@@ -0,0 +1,72 @@
+import Foundation
+
+/// Everything the library index holds.
+public struct LibraryContents: Sendable, Equatable {
+    public var drives: [GameDrive]
+    public var locations: [GameLocation]
+
+    public init(drives: [GameDrive] = [], locations: [GameLocation] = []) {
+        self.drives = drives
+        self.locations = locations
+    }
+
+    public func drive(_ id: UUID) -> GameDrive? {
+        drives.first { $0.id == id }
+    }
+
+    public func location(_ id: UUID) -> GameLocation? {
+        locations.first { $0.id == id }
+    }
+}
+
+private struct DrivesDocument: PersistedDocument {
+    static let currentFormat = 1
+    var drives: TolerantList<GameDrive>
+}
+
+private struct LocationsDocument: PersistedDocument {
+    static let currentFormat = 1
+    var locations: TolerantList<GameLocation>
+}
+
+/// `drives.json` and `locations.json`: this device's drives and game folders. Local only,
+/// never synced. Lock-guarded; every change is saved before `update` returns. A file from
+/// a newer build is never rewritten; an unreadable one is replaced by the next change.
+public final class LibraryIndex: @unchecked Sendable {
+    private let drivesFile: PersistedFile<DrivesDocument>
+    private let locationsFile: PersistedFile<LocationsDocument>
+    private let lock = NSLock()
+    private var drives: DrivesDocument
+    private var locations: LocationsDocument
+
+    /// `directory` is `…/Application Support/Eikon` (a temp directory in tests).
+    public init(directory: URL) {
+        drivesFile = PersistedFile(url: directory.appendingPathComponent("drives.json"))
+        locationsFile = PersistedFile(url: directory.appendingPathComponent("locations.json"))
+        drives = (try? drivesFile.load())?.document ?? DrivesDocument(drives: TolerantList())
+        locations = (try? locationsFile.load())?.document ?? LocationsDocument(locations: TolerantList())
+    }
+
+    public var contents: LibraryContents {
+        lock.withLock { LibraryContents(drives: drives.drives.elements, locations: locations.locations.elements) }
+    }
+
+    /// Applies `body` atomically and saves the files it changed.
+    @discardableResult
+    public func update<T>(_ body: (inout LibraryContents) throws -> T) rethrows -> T {
+        try lock.withLock {
+            var contents = LibraryContents(drives: drives.drives.elements, locations: locations.locations.elements)
+            let result = try body(&contents)
+            if contents.drives != drives.drives.elements {
+                drives.drives.elements = contents.drives
+                // Newer-format files refuse the save; the change still holds in memory.
+                try? drivesFile.save(drives)
+            }
+            if contents.locations != locations.locations.elements {
+                locations.locations.elements = contents.locations
+                try? locationsFile.save(locations)
+            }
+            return result
+        }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/SettingsStore.swift b/Packages/EikonCore/Sources/EikonCore/Settings/SettingsStore.swift
index 80a40ee..5d84b54 100644
--- a/Packages/EikonCore/Sources/EikonCore/Settings/SettingsStore.swift
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/SettingsStore.swift
@@ -112,6 +112,17 @@ public final class SettingsStore: @unchecked Sendable {
         locked { map.effectiveEntry(SettingPath.key(game: game, name: SettingPath.deletedAtName)) != nil }
     }
 
+    /// Whether the game has user data: an effective key besides fingerprints and `deletedAt`.
+    public func hasSettings(game: UUID) -> Bool {
+        locked {
+            map.entries.keys.contains { key in
+                guard let path = SettingPath(key), path.game == game, path.name != SettingPath.deletedAtName,
+                      !path.name.hasPrefix(SettingPath.fingerprintPrefix) else { return false }
+                return map.effectiveEntry(key) != nil
+            }
+        }
+    }
+
     /// Games with at least one effective key that are not deleted.
     public func knownGames() -> [UUID] {
         locked {
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/LibraryIndexTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/LibraryIndexTests.swift
new file mode 100644
index 0000000..235dee9
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/LibraryIndexTests.swift
@@ -0,0 +1,41 @@
+import Foundation
+import Testing
+import EikonCore
+
+private func temporaryDirectory() throws -> URL {
+    let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
+    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
+    return url
+}
+
+@Test func locationSavedMidFingerprintingLoadsAsPending() throws {
+    let directory = try temporaryDirectory()
+    defer { try? FileManager.default.removeItem(at: directory) }
+    let location = GameLocation(driveID: UUID(), folderName: "Sample", gameID: .random(), identity: .fingerprinting)
+    LibraryIndex(directory: directory).update { $0.locations.append(location) }
+
+    let reloaded = try #require(LibraryIndex(directory: directory).contents.location(location.id))
+    #expect(reloaded.identity == .pending)
+    #expect(reloaded.gameID == location.gameID)
+}
+
+@Test func malformedLocationIsSkippedAndKept() throws {
+    let directory = try temporaryDirectory()
+    defer { try? FileManager.default.removeItem(at: directory) }
+    let drive = UUID()
+    let first = GameLocation(driveID: drive, folderName: "Sample")
+    let second = GameLocation(driveID: drive, folderName: "Other")
+    LibraryIndex(directory: directory).update { $0.locations = [first, second] }
+
+    let url = directory.appendingPathComponent("locations.json")
+    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
+    let marker = UUID().uuidString
+    object["locations"] = (object["locations"] as? [Any] ?? []) + [["id": marker]]
+    try JSONSerialization.data(withJSONObject: object).write(to: url)
+
+    let index = LibraryIndex(directory: directory)
+    #expect(Set(index.contents.locations.map(\.id)) == [first.id, second.id])
+    index.update { $0.locations.removeAll { $0.id == second.id } }
+    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(marker))
+    #expect(LibraryIndex(directory: directory).contents.locations.map(\.id) == [first.id])
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/DriveManager.swift b/Packages/EikonKit/Sources/EikonKit/Library/DriveManager.swift
new file mode 100644
index 0000000..6178d36
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Library/DriveManager.swift
@@ -0,0 +1,139 @@
+import EikonCore
+import Foundation
+
+/// Why a folder can't become a game drive. The UI maps each to a one-line reason.
+public enum DriveRefusal: Error, Sendable, Equatable {
+    case iCloud, network, unknownVolume
+    /// The folder couldn't be bookmarked or opened.
+    case unreadable
+}
+
+public enum RelinkOutcome: Sendable, Equatable {
+    case relinked
+    /// The folder holds none of the drive's known game folders; call again with `confirmed`.
+    case needsConfirmation
+    case refused(DriveRefusal)
+}
+
+/// Adds, opens, re-links and removes game drives. The built-in drive (`Documents/`) always
+/// exists, can't be removed and is always available.
+public final class DriveManager: @unchecked Sendable {
+    public let builtInRoot: URL
+    private let index: LibraryIndex
+    private let access: any FolderAccess
+    private let lock = NSLock()
+    private var states: [UUID: DriveState] = [:]
+
+    public init(index: LibraryIndex, access: any FolderAccess, builtInRoot: URL) {
+        self.index = index
+        self.access = access
+        self.builtInRoot = builtInRoot
+        index.update { contents in
+            if !contents.drives.contains(where: { $0.kind == .builtIn }) {
+                contents.drives.insert(GameDrive(id: UUID(), kind: .builtIn, label: builtInRoot.lastPathComponent), at: 0)
+            }
+        }
+    }
+
+    /// Accepts internal and external-local folders.
+    public func add(_ url: URL) -> Result<GameDrive, DriveRefusal> {
+        if let refusal = refusal(for: url) { return .failure(refusal) }
+        guard let bookmark = try? access.makeBookmark(for: url) else { return .failure(.unreadable) }
+        let drive = GameDrive(id: UUID(), kind: .folder(bookmark: bookmark), label: url.lastPathComponent)
+        index.update { $0.drives.append(drive) }
+        lock.withLock { states[drive.id] = .available }
+        return .success(drive)
+    }
+
+    /// Opens the drive's root for as long as the token stays open; nil when the drive isn't
+    /// available. Records the state it found and persists a refreshed bookmark.
+    public func open(_ drive: GameDrive) -> AccessToken? {
+        let bookmark: Data
+        switch drive.kind {
+        case .builtIn:
+            lock.withLock { states[drive.id] = .available }
+            return AccessToken(url: builtInRoot) {}
+        case .folder(let data):
+            bookmark = data
+        }
+        let outcome = (try? access.open(bookmark: bookmark)) ?? .stale
+        switch outcome {
+        case .opened(let token, let refreshed):
+            lock.withLock { states[drive.id] = .available }
+            if let refreshed {
+                index.update { contents in
+                    if let at = contents.drives.firstIndex(where: { $0.id == drive.id }) {
+                        contents.drives[at].kind = .folder(bookmark: refreshed)
+                    }
+                }
+            }
+            return token
+        case .notConnected:
+            lock.withLock { states[drive.id] = .notConnected }
+            return nil
+        case .stale:
+            lock.withLock { states[drive.id] = .needsRelink }
+            return nil
+        }
+    }
+
+    /// Opens every drive once to refresh its state. Call at launch, on scene activation and
+    /// before launching a game.
+    @discardableResult
+    public func reevaluate() -> [UUID: DriveState] {
+        for drive in index.contents.drives {
+            open(drive)?.close()
+        }
+        return lock.withLock { states }
+    }
+
+    /// The state found by the last open, without touching the drive. The built-in drive is
+    /// always available; a drive not opened yet reads as not connected.
+    public func state(of id: UUID) -> DriveState {
+        if index.contents.drive(id)?.kind == .builtIn { return .available }
+        return lock.withLock { states[id] } ?? .notConnected
+    }
+
+    /// Points the drive at a newly picked folder, keeping its id so its locations stay
+    /// attached. A folder holding none of the drive's known game folders needs `confirmed`.
+    public func relink(_ id: UUID, to url: URL, confirmed: Bool) -> RelinkOutcome {
+        if let refusal = refusal(for: url) { return .refused(refusal) }
+        guard let bookmark = try? access.makeBookmark(for: url) else { return .refused(.unreadable) }
+        if !confirmed {
+            let known = Set(index.contents.locations.filter { $0.driveID == id }.map { NameNormalizer.normalize($0.folderName) })
+            guard case .opened(let token, _)? = try? access.open(bookmark: bookmark) else { return .refused(.unreadable) }
+            let found = (try? DriveScanner.gameFolders(in: token.url, builtIn: false)) ?? []
+            token.close()
+            if !known.isEmpty, known.isDisjoint(with: found.map { NameNormalizer.normalize($0.lastPathComponent) }) {
+                return .needsConfirmation
+            }
+        }
+        index.update { contents in
+            if let at = contents.drives.firstIndex(where: { $0.id == id }) {
+                contents.drives[at].kind = .folder(bookmark: bookmark)
+                contents.drives[at].label = url.lastPathComponent
+            }
+        }
+        lock.withLock { states[id] = .available }
+        return .relinked
+    }
+
+    /// Forgets the drive and its locations. The files on it and the games' settings stay.
+    public func remove(_ id: UUID) {
+        index.update { contents in
+            guard contents.drive(id)?.kind != .builtIn else { return }
+            contents.drives.removeAll { $0.id == id }
+            contents.locations.removeAll { $0.driveID == id }
+        }
+        lock.withLock { states[id] = nil }
+    }
+
+    private func refusal(for url: URL) -> DriveRefusal? {
+        switch access.volumeKind(of: url) {
+        case .internal, .externalLocal: nil
+        case .ubiquitous: .iCloud
+        case .network: .network
+        case .unknown: .unknownVolume
+        }
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/DriveScanner.swift b/Packages/EikonKit/Sources/EikonKit/Library/DriveScanner.swift
new file mode 100644
index 0000000..3afe6e8
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Library/DriveScanner.swift
@@ -0,0 +1,209 @@
+import CryptoKit
+import EikonCore
+import Foundation
+
+/// Diffs each available drive's game folders against its locations: new folders become
+/// locations, vanished ones go missing (never deleted), changed ones are re-detected.
+/// Once a folder's content stamp holds still for `quiescence`, it gets a game id at once
+/// (the quick pass) and joins the fingerprint worker's queue (the full pass).
+public final class DriveScanner: @unchecked Sendable {
+    /// How long a content stamp must hold before matching starts.
+    public static let quiescence: TimeInterval = 10
+
+    private let context: LibraryContext
+    private let drives: DriveManager
+    private let worker: FingerprintWorker
+    private let lock = NSLock()
+    private var suspended = false
+
+    public init(context: LibraryContext, drives: DriveManager, worker: FingerprintWorker) {
+        self.context = context
+        self.drives = drives
+        self.worker = worker
+    }
+
+    /// While suspended (a game session is active), scans do nothing.
+    public func suspend() {
+        lock.withLock { suspended = true }
+    }
+
+    public func resume() {
+        lock.withLock { suspended = false }
+    }
+
+    /// Scans every available drive. Blocking: call it off the main actor.
+    public func scanAll() {
+        for drive in context.index.contents.drives {
+            scan(drive)
+        }
+    }
+
+    public func scan(_ drive: GameDrive) {
+        guard !lock.withLock({ suspended }), let token = drives.open(drive) else { return }
+        defer { token.close() }
+        guard let folders = try? Self.gameFolders(in: token.url, builtIn: drive.kind == .builtIn) else { return }
+
+        let snapshot = context.index.contents
+        let now = context.now()
+        let observations = folders.map { folder in
+            observe(folder, existing: snapshot.locations.first { $0.driveID == drive.id && $0.folderName == folder.lastPathComponent },
+                    now: now)
+        }
+
+        let settled = context.index.update { contents -> [UUID] in
+            let present = Set(folders.map(\.lastPathComponent))
+            // Missing first, so a renamed or moved game's old location no longer counts as live.
+            for at in contents.locations.indices
+            where contents.locations[at].driveID == drive.id && !present.contains(contents.locations[at].folderName) {
+                contents.locations[at].identity = .missing
+            }
+            var settled: [UUID] = []
+            for observation in observations {
+                let at: Int
+                if let found = contents.locations.firstIndex(where: { $0.driveID == drive.id && $0.folderName == observation.name }) {
+                    at = found
+                } else {
+                    contents.locations.append(GameLocation(driveID: drive.id, folderName: observation.name))
+                    at = contents.locations.count - 1
+                }
+                if apply(observation, at: at, to: &contents, now: now) {
+                    settled.append(contents.locations[at].id)
+                }
+            }
+            return settled
+        }
+        worker.enqueue(settled)
+    }
+
+    /// A drive's game folders: immediate subfolders, minus dot folders (including import
+    /// staging) and, on the built-in drive, `Inbox`. Symlinks are not folders here.
+    static func gameFolders(in root: URL, builtIn: Bool) throws -> [URL] {
+        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
+            .filter { url in
+                let name = url.lastPathComponent
+                guard !name.hasPrefix("."), !(builtIn && name == "Inbox") else { return false }
+                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
+            }
+            .sorted { $0.lastPathComponent < $1.lastPathComponent }
+    }
+
+    // MARK: Observing (file I/O, outside the index lock)
+
+    private struct Observation {
+        var name: String
+        var modifiedAt: Date?
+        var listingDigest: String?
+        /// Set when detection ran this scan; `.some(nil)` means no game was found.
+        var detection: DetectionResult??
+        /// nil without a detection; `.failure` when the tree couldn't be read.
+        var stamp: Result<String, any Error>?
+        var engineID: Keyed?
+    }
+
+    private func observe(_ folder: URL, existing: GameLocation?, now: Date) -> Observation {
+        var observation = Observation(name: folder.lastPathComponent)
+        observation.modifiedAt = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
+        observation.listingDigest = Self.listingDigest(folder)
+
+        var detection = existing?.detection
+        func detect() {
+            detection = (try? GameDetector.detect(folder: folder)) ?? nil
+            observation.detection = .some(detection)
+        }
+        func stamp() -> Result<String, any Error>? {
+            detection.map { detection in Result { try FingerprintBuilder.contentStamp(detection: detection, folder: folder) } }
+        }
+
+        let seen = existing?.lastSeen
+        if existing == nil || detection == nil || detection?.engine == .unknown
+            || (detection?.detectorVersion ?? 0) < GameDetector.version
+            || observation.modifiedAt != seen?.modifiedAt || observation.listingDigest != seen?.listingDigest {
+            detect()
+        }
+        observation.stamp = stamp()
+        if observation.detection == nil, case .success(let current)? = observation.stamp, current != seen?.contentStamp {
+            // Contents changed below the top level: detection is a cache of them.
+            detect()
+            observation.stamp = stamp()
+        }
+
+        // Read the engine id only when the quick pass will run on this scan.
+        if let existing, existing.gameID == nil, let detection, case .success(let current)? = observation.stamp,
+           current == seen?.contentStamp, let since = seen?.stampSince, now.timeIntervalSince(since) >= Self.quiescence {
+            observation.engineID = try? FingerprintBuilder.engineID(detection: detection, folder: folder, secret: context.secret)
+        }
+        return observation
+    }
+
+    private static func listingDigest(_ folder: URL) -> String? {
+        guard let listing = try? FolderListing(url: folder) else { return nil }
+        var bytes = Data()
+        for entry in listing.entries.sorted(by: { $0.name < $1.name }) {
+            bytes.append(contentsOf: Data("\(entry.kind.rawValue):\(entry.name)\u{0}".utf8))
+        }
+        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
+    }
+
+    // MARK: Applying (under the index lock)
+
+    /// Updates the location; true when it is settled and needs the full pass.
+    private func apply(_ observation: Observation, at position: Int, to contents: inout LibraryContents, now: Date) -> Bool {
+        var location = contents.locations[position]
+        defer { contents.locations[position] = location }
+        location.lastSeen.modifiedAt = observation.modifiedAt
+        location.lastSeen.listingDigest = observation.listingDigest
+        if let detection = observation.detection {
+            location.detection = detection
+        }
+        if location.identity == .missing {
+            location.identity = .pending
+        }
+        guard location.detection != nil, let stampResult = observation.stamp else {
+            location.identity = .pending
+            return false
+        }
+        guard case .success(let stamp) = stampResult else {
+            location.identity = .failed(.unreadable)
+            return false
+        }
+
+        let changed = stamp != location.lastSeen.contentStamp || location.lastSeen.stampSince == nil
+        if changed {
+            location.lastSeen.contentStamp = stamp
+            location.lastSeen.stampSince = now
+        }
+        if stamp == location.fingerprintedStamp {
+            location.identity = .identified
+            return false
+        }
+        switch location.identity {
+        case .fingerprinting:
+            return false
+        case .failed where !changed:
+            return false
+        case .pending, .waitingForQuiescence, .identified, .failed, .missing:
+            break
+        }
+        guard let since = location.lastSeen.stampSince, now.timeIntervalSince(since) >= Self.quiescence else {
+            location.identity = .waitingForQuiescence
+            return false
+        }
+
+        if location.gameID == nil {
+            let links = context.settings.mergeLinks()
+            let result = IdentityMatcher.quickMatch(
+                engineID: observation.engineID, at: LocationKey(driveID: location.driveID, folderName: location.folderName),
+                knownLocations: LibraryIdentity.knownLocations(contents, links: links, excluding: location.id),
+                games: LibraryIdentity.knownGames(contents, settings: context.settings, links: links, excluding: location.id))
+            switch result {
+            case .keep(let game), .attach(let game, _):
+                location.gameID = game
+            case .newGame(let game, let suggestions):
+                location.gameID = game
+                location.suggestion = suggestions.filter { !location.dismissedSuggestions.contains($0) }
+            }
+        }
+        location.identity = .pending
+        return true
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/FingerprintWorker.swift b/Packages/EikonKit/Sources/EikonKit/Library/FingerprintWorker.swift
new file mode 100644
index 0000000..f96dc9a
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Library/FingerprintWorker.swift
@@ -0,0 +1,220 @@
+import EikonCore
+import Foundation
+
+/// The full identity pass, one location at a time: builds the fingerprint, then matches
+/// it against every known game. The viewed location goes first. While suspended (a game
+/// session is active) it starts nothing and cancels a build in progress, which restarts
+/// later.
+public final class FingerprintWorker: @unchecked Sendable {
+    private let context: LibraryContext
+    private let drives: DriveManager
+    private let runner = DispatchQueue(label: "eikon.library.fingerprint")
+    private let lock = NSLock()
+
+    // Guarded by `lock`.
+    private var queue: [UUID] = []
+    private var viewed: UUID?
+    private var suspended = false
+    private var cancelled: Set<UUID> = []
+    private var automatic = false
+    private var draining = false
+    private var progressHandler: (@Sendable (UUID, Double?) -> Void)?
+    private var changeHandler: (@Sendable () -> Void)?
+    private var mergeHandler: (@Sendable (GameID, GameID) -> Void)?
+
+    public init(context: LibraryContext, drives: DriveManager) {
+        self.context = context
+        self.drives = drives
+    }
+
+    /// A location's build progress in 0...1, then nil when it ends. Called on the worker's thread.
+    public var onProgress: (@Sendable (UUID, Double?) -> Void)? {
+        get { lock.withLock { progressHandler } }
+        set { lock.withLock { progressHandler = newValue } }
+    }
+
+    /// After each location is processed. Called on the worker's thread.
+    public var onChange: (@Sendable () -> Void)? {
+        get { lock.withLock { changeHandler } }
+        set { lock.withLock { changeHandler = newValue } }
+    }
+
+    /// After a silent merge (a provisional game turned out to be a copy of another), so
+    /// the merge hooks can run.
+    public var onMerge: (@Sendable (GameID, GameID) -> Void)? {
+        get { lock.withLock { mergeHandler } }
+        set { lock.withLock { mergeHandler = newValue } }
+    }
+
+    /// From now on, drains the queue in the background whenever there is work.
+    public func start() {
+        lock.withLock { automatic = true }
+        kick()
+    }
+
+    public func enqueue(_ ids: [UUID]) {
+        lock.withLock {
+            for id in ids where !queue.contains(id) {
+                queue.append(id)
+                cancelled.remove(id)
+            }
+        }
+        kick()
+    }
+
+    /// The location on screen jumps to the front of the queue.
+    public func setViewed(_ id: UUID?) {
+        lock.withLock { viewed = id }
+    }
+
+    /// Drops the locations from the queue and cancels a build in progress on them.
+    public func cancel(_ ids: some Sequence<UUID>) {
+        lock.withLock {
+            let ids = Set(ids)
+            queue.removeAll { ids.contains($0) }
+            cancelled.formUnion(ids)
+        }
+    }
+
+    public func suspend() {
+        lock.withLock { suspended = true }
+    }
+
+    public func resume() {
+        lock.withLock { suspended = false }
+        kick()
+    }
+
+    /// Processes the next queued location on the calling thread. False when suspended or
+    /// the queue is empty.
+    @discardableResult
+    public func processNext() -> Bool {
+        let next: UUID? = lock.withLock {
+            guard !suspended, !queue.isEmpty else { return nil }
+            let at = viewed.flatMap { queue.firstIndex(of: $0) } ?? 0
+            return queue.remove(at: at)
+        }
+        guard let id = next else { return false }
+        process(id)
+        onProgress?(id, nil)
+        onChange?()
+        return true
+    }
+
+    private func kick() {
+        let start = lock.withLock {
+            guard automatic, !draining, !suspended, !queue.isEmpty else { return false }
+            draining = true
+            return true
+        }
+        guard start else { return }
+        runner.async { [self] in
+            while processNext() {}
+            lock.withLock { draining = false }
+            kick()
+        }
+    }
+
+    private func process(_ id: UUID) {
+        let contents = context.index.contents
+        guard let location = contents.location(id), let detection = location.detection, location.gameID != nil,
+              location.identity != .missing, let drive = contents.drive(location.driveID) else { return }
+        // An unavailable drive is scanned, and so queued, again once it is back.
+        guard let token = drives.open(drive) else { return }
+        defer { token.close() }
+        let folder = token.url.appendingPathComponent(location.folderName, isDirectory: true)
+        setIdentity(id, .fingerprinting)
+
+        let fingerprint: Fingerprint
+        let stamp: String
+        do {
+            let before = try FingerprintBuilder.contentStamp(detection: detection, folder: folder)
+            let progress = onProgress
+            fingerprint = try FingerprintBuilder.build(
+                detection: detection, folder: folder, secret: context.secret,
+                progress: { progress?(id, $0) },
+                isCancelled: { [self] in lock.withLock { suspended || cancelled.contains(id) } })
+            stamp = try FingerprintBuilder.contentStamp(detection: detection, folder: folder)
+            guard stamp == before else {
+                // Changed while hashing: wait for the copy to settle, then build again.
+                let now = context.now()
+                update(id) {
+                    $0.identity = .waitingForQuiescence
+                    $0.lastSeen.contentStamp = stamp
+                    $0.lastSeen.stampSince = now
+                }
+                return
+            }
+        } catch is CancellationError {
+            let requeue = lock.withLock {
+                guard !cancelled.contains(id) else { return false }
+                queue.insert(id, at: 0)
+                return true
+            }
+            if requeue { setIdentity(id, .pending) }
+            return
+        } catch {
+            setIdentity(id, .failed(.unreadable))
+            return
+        }
+        identify(id, fingerprint: fingerprint, stamp: stamp)
+    }
+
+    /// Matches the new fingerprint and applies the result.
+    private func identify(_ id: UUID, fingerprint: Fingerprint, stamp: String) {
+        let settings = context.settings
+        let links = settings.mergeLinks()
+        let contents = context.index.contents
+        guard let location = contents.location(id), let assigned = location.gameID else { return }
+        let current = IdentityMatcher.resolve(assigned, links: links)
+        // The first full pass may overturn the quick one, so the location's own id doesn't count yet.
+        let firstBuild = location.fingerprint == nil
+        let result = IdentityMatcher.match(
+            fingerprint: fingerprint, at: LocationKey(driveID: location.driveID, folderName: location.folderName),
+            knownLocations: LibraryIdentity.knownLocations(contents, links: links, excluding: firstBuild ? id : nil),
+            games: LibraryIdentity.knownGames(contents, settings: settings, links: links, excluding: id))
+
+        var game = current
+        var suggestions: [GameID]?
+        switch result {
+        case .keep(let kept):
+            game = kept
+        case .attach(let other, _) where other == current:
+            break
+        case .attach(let other, _):
+            // A copy of another game: fold a provisional game without user data into it.
+            if firstBuild, !settings.hasSettings(game: current.uuid),
+               let merged = LibraryIdentity.merge(current, into: other, context: context) {
+                game = merged.into
+                onMerge?(merged.from, merged.into)
+            } else {
+                suggestions = [other]
+            }
+        case .newGame(_, let found):
+            suggestions = found
+        }
+
+        settings.addFingerprint(fingerprint, game: game.uuid)
+        update(id) { location in
+            location.gameID = game
+            location.fingerprint = fingerprint
+            location.fingerprintedStamp = stamp
+            location.identity = .identified
+            if let suggestions {
+                location.suggestion = suggestions.filter { $0 != game && !location.dismissedSuggestions.contains($0) }
+            }
+        }
+    }
+
+    private func setIdentity(_ id: UUID, _ identity: IdentityState) {
+        update(id) { $0.identity = identity }
+    }
+
+    private func update(_ id: UUID, _ body: (inout GameLocation) -> Void) {
+        context.index.update { contents in
+            if let at = contents.locations.firstIndex(where: { $0.id == id }) {
+                body(&contents.locations[at])
+            }
+        }
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/ImportCoordinator.swift b/Packages/EikonKit/Sources/EikonKit/Library/ImportCoordinator.swift
new file mode 100644
index 0000000..3062f4c
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Library/ImportCoordinator.swift
@@ -0,0 +1,303 @@
+import Darwin
+import EikonCore
+import Foundation
+import UIKit
+
+/// What to do when the drive already has a folder with the game's name.
+public enum ImportNaming: Sendable, Equatable {
+    /// Use the source folder's name; a clash returns `.nameClash`.
+    case original
+    /// Replace the existing copy, keeping its location and so its game id.
+    case replaceExisting
+    /// A name that must normalize differently from every folder on the drive.
+    case rename(String)
+}
+
+public enum ImportOutcome: Sendable, Equatable {
+    /// The location the game landed in.
+    case imported(UUID)
+    case noGameFound
+    /// Offer "Replace existing copy" or "Import with another name…".
+    case nameClash
+    /// The new name clashes too, or isn't a plain folder name.
+    case nameTaken
+    case insufficientSpace
+    case driveUnavailable
+    case cancelled
+    case failed
+}
+
+/// Keeps the app running in the background while work finishes.
+public protocol BackgroundActivity: Sendable {
+    /// Returns the call that ends the activity.
+    @MainActor func begin(_ name: String) -> @MainActor @Sendable () -> Void
+}
+
+public struct LiveBackgroundActivity: BackgroundActivity {
+    public init() {}
+
+    @MainActor
+    public func begin(_ name: String) -> @MainActor @Sendable () -> Void {
+        let task = BackgroundTask()
+        task.id = UIApplication.shared.beginBackgroundTask(withName: name) {
+            MainActor.assumeIsolated { task.end() }
+        }
+        return { task.end() }
+    }
+}
+
+@MainActor
+private final class BackgroundTask {
+    var id = UIBackgroundTaskIdentifier.invalid
+
+    func end() {
+        guard id != .invalid else { return }
+        UIApplication.shared.endBackgroundTask(id)
+        id = .invalid
+    }
+}
+
+/// Free bytes on the volume holding a URL: the "important usage" figure on internal
+/// storage, the plain one elsewhere.
+public enum FreeSpace {
+    public static let live: @Sendable (URL) -> Int64? = { url in
+        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeAvailableCapacityForImportantUsageKey,
+                                                       .volumeAvailableCapacityKey])
+        if values?.volumeIsInternal == true, let important = values?.volumeAvailableCapacityForImportantUsage {
+            return important
+        }
+        return values?.volumeAvailableCapacity.map(Int64.init)
+    }
+}
+
+/// Copies a game folder into a drive: into a hidden staging folder first, then renamed
+/// into place, so a drive never shows a partial game. The source is never changed, and
+/// symlinks in it are skipped, never followed.
+public final class ImportCoordinator: @unchecked Sendable {
+    static let stagingPrefix = ".eikon-importing-"
+
+    private let context: LibraryContext
+    private let drives: DriveManager
+    private let freeSpace: @Sendable (URL) -> Int64?
+    private let background: any BackgroundActivity
+
+    public init(context: LibraryContext, drives: DriveManager, freeSpace: @escaping @Sendable (URL) -> Int64? = FreeSpace.live,
+                background: any BackgroundActivity = LiveBackgroundActivity()) {
+        self.context = context
+        self.drives = drives
+        self.freeSpace = freeSpace
+        self.background = background
+    }
+
+    /// The copy's total size, for the drive picker; nil when no game is found there.
+    public func size(of source: URL) -> UInt64? {
+        let scoped = source.startAccessingSecurityScopedResource()
+        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
+        guard (try? GameDetector.detect(folder: source)) != nil, let items = try? Self.enumerate(source) else { return nil }
+        return items.reduce(0) { $0 + $1.size }
+    }
+
+    /// `progress` is throttled; `isCancelled` is checked between files and between chunks.
+    public func importGame(from source: URL, to driveID: UUID, naming: ImportNaming = .original,
+                           progress: @escaping @Sendable (Double) -> Void = { _ in },
+                           isCancelled: @escaping @Sendable () -> Bool = { false }) async -> ImportOutcome {
+        let end = await background.begin("eikon.import")
+        let outcome = await withCheckedContinuation { continuation in
+            DispatchQueue.global(qos: .userInitiated).async { [self] in
+                continuation.resume(returning: perform(source, driveID, naming, progress, isCancelled))
+            }
+        }
+        await end()
+        return outcome
+    }
+
+    /// Removes every staging folder left on an available drive by an import that was
+    /// interrupted (the app was suspended or killed). Call at startup, before any import.
+    public func cleanStaleStaging() {
+        for drive in context.index.contents.drives {
+            guard let token = drives.open(drive) else { continue }
+            let children = (try? FileManager.default.contentsOfDirectory(at: token.url, includingPropertiesForKeys: nil)) ?? []
+            for child in children where child.lastPathComponent.hasPrefix(Self.stagingPrefix) {
+                try? FileManager.default.removeItem(at: child)
+            }
+            token.close()
+        }
+    }
+
+    // MARK: Steps
+
+    private func perform(_ source: URL, _ driveID: UUID, _ naming: ImportNaming,
+                         _ progress: @escaping @Sendable (Double) -> Void,
+                         _ isCancelled: @escaping @Sendable () -> Bool) -> ImportOutcome {
+        let scoped = source.startAccessingSecurityScopedResource()
+        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
+        guard case let detection?? = try? GameDetector.detect(folder: source) else { return .noGameFound }
+        guard let drive = context.index.contents.drive(driveID), let token = drives.open(drive) else { return .driveUnavailable }
+        defer { token.close() }
+        let root = token.url
+
+        // Names on the drive: folders there, and locations whose folder is missing.
+        let existing = ((try? DriveScanner.gameFolders(in: root, builtIn: drive.kind == .builtIn)) ?? []).map(\.lastPathComponent)
+            + context.index.contents.locations.filter { $0.driveID == driveID }.map(\.folderName)
+        func clash(_ name: String) -> String? {
+            existing.first { NameNormalizer.normalize($0) == NameNormalizer.normalize(name) }
+        }
+        var name = source.lastPathComponent
+        var replacing = false
+        switch naming {
+        case .original:
+            if clash(name) != nil { return .nameClash }
+        case .replaceExisting:
+            if let current = clash(name) {
+                name = current
+                replacing = true
+            }
+        case .rename(let newName):
+            guard Self.isPlainName(newName), clash(newName) == nil else { return .nameTaken }
+            name = newName
+        }
+
+        guard let items = try? Self.enumerate(source) else { return .failed }
+        let total = items.reduce(0) { $0 + $1.size }
+        let margin = max(total / 20, 64 << 20)
+        guard let free = freeSpace(root), free >= 0, UInt64(free) >= total + margin else { return .insufficientSpace }
+
+        let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
+        let staged = staging.appendingPathComponent(name, isDirectory: true)
+        defer { try? FileManager.default.removeItem(at: staging) }
+        do {
+            try copy(items, from: source, to: staged, total: total, progress: progress, isCancelled: isCancelled)
+        } catch is CancellationError {
+            return .cancelled
+        } catch {
+            return .failed
+        }
+        return commit(staged, name: name, replacing: replacing, root: root, driveID: driveID, detection: detection)
+    }
+
+    /// Registers the location before the folder appears, so a scan never adds a second one.
+    private func commit(_ staged: URL, name: String, replacing: Bool, root: URL, driveID: UUID,
+                        detection: DetectionResult) -> ImportOutcome {
+        let target = root.appendingPathComponent(name, isDirectory: true)
+        let (locationID, added) = context.index.update { contents -> (UUID, Bool) in
+            if let existing = contents.locations.first(where: { $0.driveID == driveID && $0.folderName == name }) {
+                return (existing.id, false)
+            }
+            let location = GameLocation(driveID: driveID, folderName: name, detection: detection)
+            contents.locations.append(location)
+            return (location.id, true)
+        }
+        do {
+            if replacing, FileManager.default.fileExists(atPath: target.path) {
+                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
+            } else {
+                try FileManager.default.moveItem(at: staged, to: target)
+            }
+        } catch {
+            if added { context.index.update { $0.locations.removeAll { $0.id == locationID } } }
+            return .failed
+        }
+        return .imported(locationID)
+    }
+
+    private static func isPlainName(_ name: String) -> Bool {
+        !name.trimmingCharacters(in: .whitespaces).isEmpty && !name.contains("/") && !name.hasPrefix(".") && name != "Inbox"
+    }
+
+    // MARK: Copying
+
+    private struct Item {
+        var path: String
+        var isDirectory: Bool
+        var size: UInt64
+    }
+
+    /// Folders and regular files under `root`, parents first. Symlinks are skipped, so
+    /// nothing outside the source tree is ever reached.
+    private static func enumerate(_ root: URL) throws -> [Item] {
+        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
+        var items: [Item] = []
+        func walk(_ folder: URL, prefix: String) throws {
+            let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
+            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
+                let values = try child.resourceValues(forKeys: Set(keys))
+                let path = prefix + child.lastPathComponent
+                if values.isSymbolicLink == true { continue }
+                if values.isDirectory == true {
+                    items.append(Item(path: path, isDirectory: true, size: 0))
+                    try walk(child, prefix: path + "/")
+                } else if values.isRegularFile == true {
+                    items.append(Item(path: path, isDirectory: false, size: UInt64(values.fileSize ?? 0)))
+                }
+            }
+        }
+        try walk(root, prefix: "")
+        return items
+    }
+
+    private func copy(_ items: [Item], from source: URL, to destination: URL, total: UInt64,
+                      progress: (Double) -> Void, isCancelled: () -> Bool) throws {
+        var done: UInt64 = 0
+        var reported = -1.0
+        func advance(_ bytes: UInt64) {
+            done += bytes
+            let fraction = total == 0 ? 1 : min(1, Double(done) / Double(total))
+            if fraction - reported >= 0.01 || fraction == 1 {
+                reported = fraction
+                progress(fraction)
+            }
+        }
+
+        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
+        for item in items {
+            if isCancelled() { throw CancellationError() }
+            let to = destination.appendingPathComponent(item.path)
+            if item.isDirectory {
+                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
+                continue
+            }
+            try Self.copyFile(source.appendingPathComponent(item.path), to: to, isCancelled: isCancelled, advance: advance)
+        }
+        advance(0)
+    }
+
+    /// A coordinated read (file-provider placeholders download first), then an APFS clone
+    /// when source and target share a volume, else a chunked copy.
+    private static func copyFile(_ from: URL, to: URL, isCancelled: () -> Bool, advance: (UInt64) -> Void) throws {
+        var coordination: NSError?
+        var failure: (any Error)?
+        NSFileCoordinator().coordinate(readingItemAt: from, options: [], error: &coordination) { readable in
+            do {
+                let cloned = readable.path.withCString { src in
+                    to.path.withCString { dst in copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE | COPYFILE_ALL)) }
+                }
+                if cloned == 0 {
+                    let size = (try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
+                    advance(UInt64(size))
+                    return
+                }
+                try copyChunks(readable, to: to, isCancelled: isCancelled, advance: advance)
+            } catch {
+                failure = error
+            }
+        }
+        if let error = coordination ?? failure { throw error }
+    }
+
+    private static func copyChunks(_ from: URL, to: URL, isCancelled: () -> Bool, advance: (UInt64) -> Void) throws {
+        let input = try FileHandle(forReadingFrom: from)
+        defer { try? input.close() }
+        guard FileManager.default.createFile(atPath: to.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
+        let output = try FileHandle(forWritingTo: to)
+        defer { try? output.close() }
+        while true {
+            if isCancelled() { throw CancellationError() }
+            guard let chunk = try input.read(upToCount: FileHasher.chunkSize), !chunk.isEmpty else { break }
+            try output.write(contentsOf: chunk)
+            advance(UInt64(chunk.count))
+        }
+        if let permissions = try? FileManager.default.attributesOfItem(atPath: from.path)[.posixPermissions] {
+            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: to.path)
+        }
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift b/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
new file mode 100644
index 0000000..938f9e1
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
@@ -0,0 +1,461 @@
+import Combine
+import EikonCore
+import Foundation
+
+/// Supplies what the route picker needs to know about this device for one game. The app
+/// implements it from JIT status, gates, built runtimes and cached runtime checks.
+@MainActor
+public protocol RouteEnvironmentSource: AnyObject {
+    func environment(for game: GameID, detection: DetectionResult) async -> RouteEnvironment
+}
+
+public struct DriveSummary: Sendable, Equatable, Identifiable {
+    public var drive: GameDrive
+    public var state: DriveState
+    public var freeBytes: Int64?
+    public var gameCount: Int
+    public var id: UUID { drive.id }
+}
+
+/// A game's overall status, from its locations.
+public enum GameStatus: Sendable, Equatable {
+    case ready
+    case identifying
+    case waitingForCopy
+    case suggestion
+    case driveNotConnected
+    case missing
+    case fingerprintFailed
+}
+
+public struct LibraryGame: Sendable, Equatable, Identifiable {
+    /// Resolved through merge links.
+    public var id: GameID
+    /// On screen only: the `displayName` setting, else the first location's folder name.
+    public var displayName: String
+    public var locations: [GameLocation]
+    public var status: GameStatus
+    public var suggestions: [GameID]
+    /// From the launch location, else the first detected location.
+    public var detection: DetectionResult?
+}
+
+public enum LaunchLocation: Sendable, Equatable {
+    case ready(GameLocation)
+    case driveNotConnected
+    case missing
+}
+
+/// The library the UI binds to: drives, games grouped by resolved game id, and the
+/// entry points behind them. Scans and file work run off the main actor.
+@MainActor
+public final class LibraryController: ObservableObject {
+    @Published public private(set) var drives: [DriveSummary] = []
+    @Published public private(set) var games: [LibraryGame] = []
+    /// Detected, but without a game id yet (still being copied, or about to be matched).
+    @Published public private(set) var settling: [GameLocation] = []
+    /// No game found: the "Not recognized" list.
+    @Published public private(set) var unrecognized: [GameLocation] = []
+    @Published public private(set) var decisions: [GameID: RouteDecision] = [:]
+    /// Full-fingerprint progress per location, while it runs.
+    @Published public private(set) var fingerprintProgress: [UUID: Double] = [:]
+    @Published public private(set) var importProgress: Double?
+
+    public weak var environmentSource: (any RouteEnvironmentSource)?
+
+    public let context: LibraryContext
+    public let driveManager: DriveManager
+    public let scanner: DriveScanner
+    public let worker: FingerprintWorker
+    public let importer: ImportCoordinator
+    private let settings: SettingsController
+    private let hooks: GameDataHooks
+    private let freeSpace: @Sendable (URL) -> Int64?
+    private let work = DispatchQueue(label: "eikon.library.scan")
+    private var freeBytes: [UUID: Int64] = [:]
+    private var importCancel: CancelFlag?
+    private var routeTask: Task<Void, Never>?
+    private var subscriptions: Set<AnyCancellable> = []
+
+    public init(index: LibraryIndex, settings: SettingsController, secret: LibrarySecret, access: any FolderAccess,
+                builtInRoot: URL, hooks: GameDataHooks, now: @escaping @Sendable () -> Date = { Date() },
+                freeSpace: @escaping @Sendable (URL) -> Int64? = FreeSpace.live,
+                background: any BackgroundActivity = LiveBackgroundActivity()) {
+        context = LibraryContext(index: index, settings: settings.store, secret: secret, now: now)
+        driveManager = DriveManager(index: index, access: access, builtInRoot: builtInRoot)
+        worker = FingerprintWorker(context: context, drives: driveManager)
+        scanner = DriveScanner(context: context, drives: driveManager, worker: worker)
+        importer = ImportCoordinator(context: context, drives: driveManager, freeSpace: freeSpace, background: background)
+        self.settings = settings
+        self.hooks = hooks
+        self.freeSpace = freeSpace
+
+        let throttle = ProgressThrottle()
+        worker.onProgress = { [weak self] id, progress in
+            guard throttle.shouldReport(id, progress) else { return }
+            Task { @MainActor in self?.fingerprintProgress[id] = progress }
+        }
+        worker.onChange = { [weak self] in
+            Task { @MainActor in self?.refresh() }
+        }
+        worker.onMerge = { [weak self] from, into in
+            Task { @MainActor in await self?.runMergeHooks(from: from, into: into) }
+        }
+        settings.changes
+            .sink { [weak self] change in
+                self?.reload()
+                if case .routeOverride = change { self?.invalidateRoutes() }
+            }
+            .store(in: &subscriptions)
+        reload()
+    }
+
+    /// Over `Documents/` and `Application Support/Eikon`, with the live folder access.
+    public static func live(settings: SettingsController, hooks: GameDataHooks) throws -> LibraryController {
+        let support = LibraryPaths.support
+        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
+        return LibraryController(index: LibraryIndex(directory: support), settings: settings,
+                                 secret: try LibrarySecret.loadOrCreate(at: support.appendingPathComponent("library-secret")),
+                                 access: LiveFolderAccess.live, builtInRoot: LibraryPaths.documents, hooks: hooks)
+    }
+
+    /// Startup, in order: keep game files out of backups, clear interrupted imports, check
+    /// drives, scan, and start the fingerprint worker.
+    public func start() async {
+        var documents = driveManager.builtInRoot
+        var values = URLResourceValues()
+        values.isExcludedFromBackup = true
+        try? documents.setResourceValues(values)
+        let importer = importer
+        await offMain { importer.cleanStaleStaging() }
+        await reevaluateDriveStates()
+        worker.start()
+        await rescan()
+    }
+
+    // MARK: Drives
+
+    public func addDrive(_ url: URL) async -> Result<GameDrive, DriveRefusal> {
+        let manager = driveManager
+        let result = await offMain { manager.add(url) }
+        if case .success = result { await rescan() }
+        return result
+    }
+
+    public func relinkDrive(_ id: UUID, to url: URL, confirmed: Bool) async -> RelinkOutcome {
+        let manager = driveManager
+        let outcome = await offMain { manager.relink(id, to: url, confirmed: confirmed) }
+        if outcome == .relinked { await rescan() }
+        return outcome
+    }
+
+    public func removeDrive(_ id: UUID) {
+        worker.cancel(context.index.contents.locations.filter { $0.driveID == id }.map(\.id))
+        driveManager.remove(id)
+        refresh()
+    }
+
+    /// Opens every drive to refresh its state and free space.
+    public func reevaluateDriveStates() async {
+        let manager = driveManager, index = context.index, freeSpace = freeSpace
+        freeBytes = await offMain {
+            manager.reevaluate()
+            var free: [UUID: Int64] = [:]
+            for drive in index.contents.drives {
+                guard let token = manager.open(drive) else { continue }
+                free[drive.id] = freeSpace(token.url)
+                token.close()
+            }
+            return free
+        }
+        reload()
+    }
+
+    /// Scans every available drive. Does nothing while background work is suspended.
+    public func rescan() async {
+        let scanner = scanner
+        await offMain { scanner.scanAll() }
+        refresh()
+    }
+
+    // MARK: Import
+
+    public func importGame(from source: URL, to driveID: UUID, naming: ImportNaming = .original) async -> ImportOutcome {
+        let flag = CancelFlag()
+        importCancel = flag
+        importProgress = 0
+        let outcome = await importer.importGame(from: source, to: driveID, naming: naming, progress: { [weak self] progress in
+            Task { @MainActor in if self?.importCancel === flag { self?.importProgress = progress } }
+        }, isCancelled: { flag.isSet })
+        if importCancel === flag {
+            importCancel = nil
+            importProgress = nil
+        }
+        if case .imported = outcome { await rescan() }
+        return outcome
+    }
+
+    public func cancelImport() {
+        importCancel?.set()
+    }
+
+    // MARK: Identity
+
+    public func merge(_ game: GameID, into target: GameID) async {
+        guard let merged = LibraryIdentity.merge(game, into: target, context: context) else { return }
+        refresh()
+        await runMergeHooks(from: merged.from, into: merged.into)
+    }
+
+    @discardableResult
+    public func split(location: UUID) -> GameID? {
+        let id = LibraryIdentity.split(location: location, context: context)
+        refresh()
+        return id
+    }
+
+    /// Hides a "same game as…?" suggestion on this location for good.
+    public func dismissSuggestion(_ game: GameID, on location: UUID) {
+        context.index.update { contents in
+            guard let at = contents.locations.firstIndex(where: { $0.id == location }) else { return }
+            contents.locations[at].suggestion.removeAll { $0 == game }
+            if !contents.locations[at].dismissedSuggestions.contains(game) {
+                contents.locations[at].dismissedSuggestions.append(game)
+            }
+        }
+        reload()
+    }
+
+    public func retryFingerprint(_ location: UUID) {
+        context.index.update { contents in
+            guard let at = contents.locations.firstIndex(where: { $0.id == location }) else { return }
+            contents.locations[at].identity = .pending
+            contents.locations[at].lastSeen.stampSince = nil
+        }
+        reload()
+        Task { await rescan() }
+    }
+
+    /// The location on screen gets the fingerprint worker's priority.
+    public func setViewedLocation(_ location: UUID?) {
+        worker.setViewed(location)
+    }
+
+    // MARK: Remove
+
+    /// Deletes the chosen locations' folders (on available drives only), and with
+    /// `deleteData` the game's settings and saves on every device. Either way the game's
+    /// locations leave the index; folders that remain come back on the next scan.
+    public func remove(game: GameID, deleteLocations: Set<UUID>, deleteData: Bool) async {
+        let links = context.settings.mergeLinks()
+        let contents = context.index.contents
+        let mine = contents.locations.filter { $0.gameID.map { IdentityMatcher.resolve($0, links: links) } == game }
+        worker.cancel(mine.map(\.id))
+
+        let doomed = mine.filter { deleteLocations.contains($0.id) }
+        let manager = driveManager
+        await offMain {
+            for location in doomed {
+                guard let drive = contents.drive(location.driveID), let token = manager.open(drive) else { continue }
+                if let folder = Self.gameFolder(location.folderName, in: token.url) {
+                    try? FileManager.default.removeItem(at: folder)
+                }
+                token.close()
+            }
+        }
+
+        if deleteData {
+            let aliases = links.keys.filter { IdentityMatcher.resolve($0, links: links) == game }
+            for id in [game] + aliases {
+                context.settings.removeAll(game: id.uuid)
+            }
+            for hook in hooks.cleanups {
+                await hook.removeData(for: game)
+            }
+        }
+        let ids = Set(mine.map(\.id))
+        context.index.update { $0.locations.removeAll { ids.contains($0.id) } }
+        refresh()
+    }
+
+    /// A drive's immediate child with this name, or nil when the name could reach elsewhere.
+    nonisolated private static func gameFolder(_ name: String, in root: URL) -> URL? {
+        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
+        return root.appendingPathComponent(name, isDirectory: true)
+    }
+
+    // MARK: Launch
+
+    /// A reachable location, preferring the built-in drive, then the most recently used.
+    public func launchLocation(for game: GameID) -> LaunchLocation {
+        let contents = context.index.contents
+        let links = context.settings.mergeLinks()
+        let mine = contents.locations.filter { $0.gameID.map { IdentityMatcher.resolve($0, links: links) } == game }
+        let present = mine.filter { $0.identity != .missing }
+        let reachable = present.filter { driveManager.state(of: $0.driveID) == .available }
+        func isBuiltIn(_ location: GameLocation) -> Bool { contents.drive(location.driveID)?.kind == .builtIn }
+        let best = reachable.sorted { a, b in
+            if isBuiltIn(a) != isBuiltIn(b) { return isBuiltIn(a) }
+            return (a.lastUsedAt ?? .distantPast) > (b.lastUsedAt ?? .distantPast)
+        }.first
+        if let best { return .ready(best) }
+        return present.isEmpty ? .missing : .driveNotConnected
+    }
+
+    /// Records a launch, for the next launch-location choice.
+    public func noteLaunched(location: UUID) {
+        let now = context.now()
+        context.index.update { contents in
+            if let at = contents.locations.firstIndex(where: { $0.id == location }) {
+                contents.locations[at].lastUsedAt = now
+            }
+        }
+    }
+
+    // MARK: Sessions
+
+    /// A game session is starting: scans and fingerprinting pause.
+    public func suspendBackgroundWork() {
+        scanner.suspend()
+        worker.suspend()
+    }
+
+    public func resumeBackgroundWork() {
+        scanner.resume()
+        worker.resume()
+        Task { await rescan() }
+    }
+
+    // MARK: Routes
+
+    /// Recomputes every game's route decision. Call when JIT usability, gates, the runtime
+    /// registry or cached runtime checks change; overrides are watched here.
+    public func invalidateRoutes() {
+        routeTask?.cancel()
+        let games = games
+        routeTask = Task { [weak self] in
+            var decisions: [GameID: RouteDecision] = [:]
+            for game in games {
+                guard let detection = game.detection, let self else { continue }
+                let environment = await environmentSource?.environment(for: game.id, detection: detection)
+                    ?? RouteEnvironment(jitUsable: false, gates: [:], builtRoutes: [], runtimeChecks: [:])
+                decisions[game.id] = RoutePicker.decide(detection: detection, environment: environment,
+                                                        override: settings.routeOverride(for: game.id))
+            }
+            guard !Task.isCancelled else { return }
+            self?.decisions = decisions
+        }
+    }
+
+    // MARK: Publishing
+
+    private func refresh() {
+        reload()
+        invalidateRoutes()
+    }
+
+    /// Rebuilds the published state from the index, drive states and settings.
+    private func reload() {
+        let contents = context.index.contents
+        let links = context.settings.mergeLinks()
+        var grouped: [GameID: [GameLocation]] = [:]
+        var settling: [GameLocation] = []
+        var unrecognized: [GameLocation] = []
+        for location in contents.locations {
+            if location.detection == nil {
+                if location.identity != .missing { unrecognized.append(location) }
+            } else if let game = location.gameID {
+                grouped[IdentityMatcher.resolve(game, links: links), default: []].append(location)
+            } else if location.identity != .missing {
+                settling.append(location)
+            }
+        }
+
+        let states = Dictionary(uniqueKeysWithValues: contents.drives.map { ($0.id, driveManager.state(of: $0.id)) })
+        games = grouped.map { id, locations in
+            let launch = launchLocation(for: id)
+            var detection: DetectionResult?
+            if case .ready(let location) = launch { detection = location.detection }
+            var suggestions: [GameID] = []
+            for suggested in locations.flatMap(\.suggestion).map({ IdentityMatcher.resolve($0, links: links) })
+            where suggested != id && !suggestions.contains(suggested) {
+                suggestions.append(suggested)
+            }
+            return LibraryGame(
+                id: id,
+                displayName: settings.displayName(for: id) ?? locations[0].folderName,
+                locations: locations,
+                status: Self.status(locations, states: states, hasSuggestions: !suggestions.isEmpty),
+                suggestions: suggestions,
+                detection: detection ?? locations.lazy.compactMap(\.detection).first)
+        }
+        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
+        self.settling = settling
+        self.unrecognized = unrecognized
+        drives = contents.drives.map { drive in
+            DriveSummary(drive: drive, state: states[drive.id] ?? .notConnected, freeBytes: freeBytes[drive.id],
+                         gameCount: Set(grouped.filter { $0.value.contains { $0.driveID == drive.id } }.keys).count)
+        }
+    }
+
+    private static func status(_ locations: [GameLocation], states: [UUID: DriveState], hasSuggestions: Bool) -> GameStatus {
+        let present = locations.filter { $0.identity != .missing }
+        let reachable = present.filter { states[$0.driveID] == .available }
+        if reachable.isEmpty { return present.isEmpty ? .missing : .driveNotConnected }
+        var failed = false, waiting = false, identifying = false
+        for location in reachable {
+            switch location.identity {
+            case .failed: failed = true
+            case .waitingForQuiescence: waiting = true
+            case .pending, .fingerprinting: identifying = true
+            case .identified, .missing: break
+            }
+        }
+        if failed { return .fingerprintFailed }
+        if waiting { return .waitingForCopy }
+        if identifying { return .identifying }
+        return hasSuggestions ? .suggestion : .ready
+    }
+
+    private func runMergeHooks(from: GameID, into: GameID) async {
+        for hook in hooks.merges {
+            await hook.mergeData(from: from, into: into)
+        }
+    }
+
+    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
+        await withCheckedContinuation { continuation in
+            work.async { continuation.resume(returning: body()) }
+        }
+    }
+}
+
+/// A one-way cancel switch, safe from any thread.
+private final class CancelFlag: @unchecked Sendable {
+    private let lock = NSLock()
+    private var value = false
+
+    var isSet: Bool { lock.withLock { value } }
+
+    func set() {
+        lock.withLock { value = true }
+    }
+}
+
+/// Lets a progress value through only when it moved by a percent or ended.
+private final class ProgressThrottle: @unchecked Sendable {
+    private let lock = NSLock()
+    private var last: [UUID: Double] = [:]
+
+    func shouldReport(_ id: UUID, _ progress: Double?) -> Bool {
+        lock.withLock {
+            guard let progress else {
+                last[id] = nil
+                return true
+            }
+            if let previous = last[id], progress - previous < 0.01, progress < 1 { return false }
+            last[id] = progress
+            return true
+        }
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/LibraryIdentity.swift b/Packages/EikonKit/Sources/EikonKit/Library/LibraryIdentity.swift
new file mode 100644
index 0000000..6aadba0
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Library/LibraryIdentity.swift
@@ -0,0 +1,107 @@
+import EikonCore
+import Foundation
+
+/// What the library parts share.
+public struct LibraryContext: Sendable {
+    public let index: LibraryIndex
+    public let settings: SettingsStore
+    public let secret: LibrarySecret
+    public let now: @Sendable () -> Date
+
+    public init(index: LibraryIndex, settings: SettingsStore, secret: LibrarySecret,
+                now: @escaping @Sendable () -> Date = { Date() }) {
+        self.index = index
+        self.settings = settings
+        self.secret = secret
+        self.now = now
+    }
+}
+
+/// Matcher inputs and the merge and split operations over the index and settings store.
+enum LibraryIdentity {
+    /// Every location's resolved game, keyed by drive and normalized folder name.
+    static func knownLocations(_ contents: LibraryContents, links: [GameID: GameID],
+                               excluding excluded: UUID? = nil) -> [LocationKey: GameID] {
+        var known: [LocationKey: GameID] = [:]
+        for location in contents.locations where location.id != excluded {
+            guard let game = location.gameID else { continue }
+            known[LocationKey(driveID: location.driveID, folderName: location.folderName)] = IdentityMatcher.resolve(game, links: links)
+        }
+        return known
+    }
+
+    /// Every resolved game in the settings store or the index, except deleted ones.
+    static func knownGames(_ contents: LibraryContents, settings: SettingsStore, links: [GameID: GameID],
+                           excluding excluded: UUID) -> [KnownGame] {
+        let ids = Set((settings.knownGames().map(GameID.init) + contents.locations.compactMap(\.gameID))
+            .map { IdentityMatcher.resolve($0, links: links) })
+        return ids.sorted().compactMap { id in
+            guard !settings.isDeleted(game: id.uuid) else { return nil }
+            let live = contents.locations.contains { location in
+                location.id != excluded && location.identity != .missing
+                    && location.gameID.map { IdentityMatcher.resolve($0, links: links) } == id
+            }
+            return KnownGame(id: id, fingerprints: settings.fingerprints(game: id.uuid), hasLiveLocationHere: live)
+        }
+    }
+
+    /// `a` becomes an alias of `b`: B keeps its own settings and gains A's others, A's
+    /// fingerprints and locations move to B. Returns the resolved pair, or nil when they
+    /// are already one game.
+    @discardableResult
+    static func merge(_ a: GameID, into b: GameID, context: LibraryContext) -> (from: GameID, into: GameID)? {
+        let settings = context.settings
+        let links = settings.mergeLinks()
+        let source = IdentityMatcher.resolve(a, links: links), target = IdentityMatcher.resolve(b, links: links)
+        guard source != target else { return nil }
+        settings.set(.merged(source.uuid), target.uuid.uuidString.lowercased())
+        settings.copySettings(from: source.uuid, to: target.uuid, onlyWhereUnset: true)
+        let moved = settings.fingerprints(game: source.uuid)
+        // Re-adding B's own afterwards keeps them newest, as `IdentityLedger.merge` does.
+        for fingerprint in moved + settings.fingerprints(game: target.uuid) {
+            settings.addFingerprint(fingerprint, game: target.uuid)
+        }
+        for fingerprint in moved {
+            settings.removeFingerprint(fingerprint, game: source.uuid)
+        }
+        context.index.update { contents in
+            for at in contents.locations.indices {
+                var location = contents.locations[at]
+                var game = location.gameID.map { IdentityMatcher.resolve($0, links: links) }
+                if game == source {
+                    location.gameID = target
+                    game = target
+                }
+                var suggestions: [GameID] = []
+                for suggested in location.suggestion.map({ $0 == source ? target : $0 })
+                where suggested != game && !suggestions.contains(suggested) {
+                    suggestions.append(suggested)
+                }
+                location.suggestion = suggestions
+                contents.locations[at] = location
+            }
+        }
+        return (source, target)
+    }
+
+    /// Gives the location a new game with a copy of its old game's settings and the
+    /// location's own fingerprint. Returns the new id.
+    static func split(location id: UUID, context: LibraryContext) -> GameID? {
+        let settings = context.settings
+        guard let location = context.index.contents.location(id), let old = location.gameID else { return nil }
+        let oldGame = IdentityMatcher.resolve(old, links: settings.mergeLinks())
+        let new = GameID.random()
+        settings.copySettings(from: oldGame.uuid, to: new.uuid, onlyWhereUnset: false)
+        if let fingerprint = location.fingerprint {
+            settings.removeFingerprint(fingerprint, game: oldGame.uuid)
+            settings.addFingerprint(fingerprint, game: new.uuid)
+        }
+        context.index.update { contents in
+            if let at = contents.locations.firstIndex(where: { $0.id == id }) {
+                contents.locations[at].gameID = new
+                contents.locations[at].suggestion = []
+            }
+        }
+        return new
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/LiveFolderAccess.swift b/Packages/EikonKit/Sources/EikonKit/Library/LiveFolderAccess.swift
new file mode 100644
index 0000000..35e574d
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Library/LiveFolderAccess.swift
@@ -0,0 +1,47 @@
+import EikonCore
+import Foundation
+
+/// Security-scoped bookmarks for picked folders.
+public struct LiveFolderAccess: FolderAccess {
+    public static let live = LiveFolderAccess()
+
+    public init() {}
+
+    public func makeBookmark(for url: URL) throws -> Data {
+        let scoped = url.startAccessingSecurityScopedResource()
+        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
+        return try url.bookmarkData()
+    }
+
+    public func open(bookmark: Data) throws -> AccessOutcome {
+        var isStale = false
+        let url: URL
+        do {
+            url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
+        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
+            return .notConnected
+        } catch {
+            return .stale
+        }
+        let scoped = url.startAccessingSecurityScopedResource()
+        let token = AccessToken(url: url) {
+            if scoped { url.stopAccessingSecurityScopedResource() }
+        }
+        guard (try? url.checkResourceIsReachable()) == true else {
+            token.close()
+            return .notConnected
+        }
+        return .opened(token, refreshedBookmark: isStale ? try? url.bookmarkData() : nil)
+    }
+
+    public func volumeKind(of url: URL) -> VolumeKind {
+        let scoped = url.startAccessingSecurityScopedResource()
+        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
+        guard let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey, .isUbiquitousItemKey]),
+              let isLocal = values.volumeIsLocal else { return .unknown }
+        if values.isUbiquitousItem == true { return .ubiquitous }
+        if !isLocal { return .network }
+        guard let isInternal = values.volumeIsInternal else { return .unknown }
+        return isInternal ? .internal : .externalLocal
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/GameDataCleanup.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/GameDataCleanup.swift
new file mode 100644
index 0000000..c2179b8
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/GameDataCleanup.swift
@@ -0,0 +1,28 @@
+import EikonCore
+
+public protocol GameDataCleanup: Sendable {
+    /// Delete route-owned data (saves etc.) for a game. Called once per removal on this device.
+    func removeData(for game: GameID) async
+}
+
+public protocol GameDataMerge: Sendable {
+    /// Move route-owned data from one game id to another after a merge.
+    func mergeData(from: GameID, into: GameID) async
+}
+
+/// The hooks save-owning routes register. Nothing registers in split 02.
+@MainActor
+public final class GameDataHooks {
+    public private(set) var cleanups: [any GameDataCleanup] = []
+    public private(set) var merges: [any GameDataMerge] = []
+
+    public init() {}
+
+    public func register(_ hook: any GameDataCleanup) {
+        cleanups.append(hook)
+    }
+
+    public func register(_ hook: any GameDataMerge) {
+        merges.append(hook)
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Settings/SettingsController.swift b/Packages/EikonKit/Sources/EikonKit/Settings/SettingsController.swift
new file mode 100644
index 0000000..4e44131
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Settings/SettingsController.swift
@@ -0,0 +1,80 @@
+import Combine
+import EikonCore
+import Foundation
+
+/// The UI's face of the settings store: typed reads and writes for split 02's per-game
+/// keys, with a change signal so views and the library refresh.
+@MainActor
+public final class SettingsController: ObservableObject {
+    public enum Change: Sendable, Equatable {
+        case displayName(GameID)
+        case routeOverride(GameID)
+    }
+
+    public let store: SettingsStore
+    /// Sent after each write; `LibraryController` recomputes routes on `routeOverride`.
+    public let changes = PassthroughSubject<Change, Never>()
+
+    public init(store: SettingsStore) {
+        self.store = store
+    }
+
+    /// Over `Application Support/Eikon`.
+    public static func live() throws -> SettingsController {
+        SettingsController(store: try SettingsStore(directory: LibraryPaths.support))
+    }
+
+    /// nil when unset: the UI falls back to the first location's folder name.
+    public func displayName(for game: GameID) -> String? {
+        store.value(.displayName, game: game.uuid)
+    }
+
+    /// Commit on submit, not per keystroke. Empty or nil resets it.
+    public func setDisplayName(_ name: String?, for game: GameID) {
+        objectWillChange.send()
+        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
+        if trimmed.isEmpty {
+            store.reset(.displayName, game: game.uuid)
+        } else {
+            store.set(.displayName, trimmed, game: game.uuid)
+        }
+        changes.send(.displayName(game))
+    }
+
+    /// nil means Automatic; an unknown stored route reads as Automatic.
+    public func routeOverride(for game: GameID) -> RouteID? {
+        store.value(.routeOverride, game: game.uuid).flatMap(RouteID.init(rawValue:))
+    }
+
+    public func setRouteOverride(_ route: RouteID?, for game: GameID) {
+        objectWillChange.send()
+        if let route {
+            store.set(.routeOverride, route.rawValue, game: game.uuid)
+        } else {
+            store.reset(.routeOverride, game: game.uuid)
+        }
+        changes.send(.routeOverride(game))
+    }
+
+    /// Writes pending changes now: on scene background and before a session starts.
+    public func flush() {
+        store.flush()
+    }
+
+    public var replicaID: ReplicaID { store.replicaID }
+    public var forkedFrom: ReplicaID? { store.forkedFrom }
+}
+
+/// The app's storage roots, resolved from `FileManager`; never stored as absolute paths.
+public enum LibraryPaths {
+    /// `Documents/`: the built-in game drive.
+    public static var documents: URL {
+        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
+    }
+
+    /// `Library/Application Support/Eikon/`: the library index, secret and settings.
+    public static var support: URL {
+        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
+            .appendingPathComponent("Eikon", isDirectory: true)
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/LibraryTests.swift b/Packages/EikonKit/Tests/EikonKitTests/LibraryTests.swift
new file mode 100644
index 0000000..c916e1e
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/LibraryTests.swift
@@ -0,0 +1,551 @@
+import EikonCore
+import Foundation
+import Testing
+@testable import EikonKit
+
+// MARK: Fakes
+
+/// Bookmarks are the folder's path; each can be scripted to open, be unplugged or go stale.
+private final class FakeAccess: FolderAccess, @unchecked Sendable {
+    enum Mode { case opened, notConnected, stale }
+
+    private let lock = NSLock()
+    private var modes: [String: Mode] = [:]
+    private var kinds: [String: VolumeKind] = [:]
+
+    func set(_ mode: Mode, for url: URL) {
+        lock.withLock { modes[url.path] = mode }
+    }
+
+    func set(_ kind: VolumeKind, for url: URL) {
+        lock.withLock { kinds[url.path] = kind }
+    }
+
+    func makeBookmark(for url: URL) throws -> Data {
+        Data(url.path.utf8)
+    }
+
+    func open(bookmark: Data) throws -> AccessOutcome {
+        let path = String(decoding: bookmark, as: UTF8.self)
+        switch lock.withLock({ modes[path] }) ?? .opened {
+        case .opened: return .opened(AccessToken(url: URL(fileURLWithPath: path, isDirectory: true)) {}, refreshedBookmark: nil)
+        case .notConnected: return .notConnected
+        case .stale: return .stale
+        }
+    }
+
+    func volumeKind(of url: URL) -> VolumeKind {
+        lock.withLock { kinds[url.path] } ?? .internal
+    }
+}
+
+private final class Clock: @unchecked Sendable {
+    private let lock = NSLock()
+    private var current = Date(timeIntervalSince1970: 1_800_000_000)
+
+    var now: Date { lock.withLock { current } }
+
+    func advance(_ seconds: TimeInterval) {
+        lock.withLock { current += seconds }
+    }
+}
+
+private final class CountingCleanup: GameDataCleanup, @unchecked Sendable {
+    private let lock = NSLock()
+    private var removed: [GameID] = []
+
+    var calls: [GameID] { lock.withLock { removed } }
+
+    func removeData(for game: GameID) async {
+        lock.withLock { removed.append(game) }
+    }
+}
+
+private final class Space: @unchecked Sendable {
+    private let lock = NSLock()
+    private var bytes: Int64 = 1 << 40
+
+    var value: Int64 {
+        get { lock.withLock { bytes } }
+        set { lock.withLock { bytes = newValue } }
+    }
+}
+
+private struct NoBackground: BackgroundActivity {
+    @MainActor func begin(_ name: String) -> @MainActor @Sendable () -> Void { {} }
+}
+
+// MARK: Harness
+
+/// A tiny Ren'Py-style game. `declaredID` becomes its engine-declared id; `content`
+/// varies the compiled script, so different contents make a different game build.
+@discardableResult
+private func makeGame(_ name: String, in directory: URL, declaredID: String? = "SampleGame", content: String = "one") throws -> URL {
+    let root = directory.appendingPathComponent(name, isDirectory: true)
+    try write("# engine\n", to: "renpy/__init__.py", in: root)
+    try write("RPC2" + content, to: "game/script.rpyc", in: root)
+    if let declaredID {
+        try write("define config.save_directory = \"\(declaredID)\"\n", to: "game/options.rpy", in: root)
+    }
+    return root
+}
+
+private func write(_ text: String, to relative: String, in directory: URL) throws {
+    let url = directory.appendingPathComponent(relative)
+    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
+    try Data(text.utf8).write(to: url)
+}
+
+private func exists(_ url: URL) -> Bool {
+    FileManager.default.fileExists(atPath: url.path)
+}
+
+@MainActor
+private final class Harness {
+    let root: URL
+    let documents: URL
+    let access = FakeAccess()
+    let clock = Clock()
+    let space = Space()
+    let hooks = GameDataHooks()
+    let settings: SettingsController
+    let library: LibraryController
+
+    init() throws {
+        root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
+        documents = root.appendingPathComponent("Documents", isDirectory: true)
+        let support = root.appendingPathComponent("Support", isDirectory: true)
+        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
+        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
+        let clock = clock, space = space
+        settings = SettingsController(store: try SettingsStore(directory: support, now: { clock.now }))
+        library = LibraryController(index: LibraryIndex(directory: support), settings: settings,
+                                    secret: LibrarySecret(bytes: Data(repeating: 7, count: LibrarySecret.byteCount)),
+                                    access: access, builtInRoot: documents, hooks: hooks, now: { clock.now },
+                                    freeSpace: { _ in space.value }, background: NoBackground())
+    }
+
+    deinit {
+        try? FileManager.default.removeItem(at: root)
+    }
+
+    var builtIn: GameDrive {
+        library.context.index.contents.drives.first { $0.kind == .builtIn }!
+    }
+
+    /// A new folder drive on internal storage.
+    func addDrive() throws -> (url: URL, drive: GameDrive) {
+        let url = root.appendingPathComponent("Drive-\(UUID().uuidString)", isDirectory: true)
+        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
+        return (url, try library.driveManager.add(url).get())
+    }
+
+    func scan() {
+        library.scanner.scanAll()
+    }
+
+    /// Two scans a quiescence interval apart, then the full pass for everything queued.
+    func settle() {
+        scan()
+        clock.advance(DriveScanner.quiescence + 1)
+        scan()
+        while library.worker.processNext() {}
+    }
+
+    func location(_ name: String, on drive: GameDrive? = nil) -> GameLocation? {
+        let driveID = drive?.id ?? builtIn.id
+        return library.context.index.contents.locations.first { $0.driveID == driveID && $0.folderName == name }
+    }
+
+    func locations(on drive: GameDrive) -> [GameLocation] {
+        library.context.index.contents.locations.filter { $0.driveID == drive.id }
+    }
+
+    /// The location's game, resolved through merges.
+    func game(_ name: String, on drive: GameDrive? = nil) -> GameID? {
+        location(name, on: drive)?.gameID.map { IdentityMatcher.resolve($0, links: settings.store.mergeLinks()) }
+    }
+}
+
+// MARK: Drives
+
+@Test @MainActor func addingDriveAcceptsOnlyLocalVolumes() throws {
+    let harness = try Harness()
+    var refusals: [DriveRefusal] = []
+    for kind in [VolumeKind.ubiquitous, .network, .unknown] {
+        let url = harness.root.appendingPathComponent(UUID().uuidString)
+        harness.access.set(kind, for: url)
+        guard case .failure(let refusal) = harness.library.driveManager.add(url) else {
+            Issue.record("accepted a refused volume")
+            continue
+        }
+        refusals.append(refusal)
+    }
+    #expect(Set(refusals.map { "\($0)" }).count == 3)
+
+    for kind in [VolumeKind.internal, .externalLocal] {
+        let url = harness.root.appendingPathComponent(UUID().uuidString)
+        harness.access.set(kind, for: url)
+        #expect((try? harness.library.driveManager.add(url).get()) != nil)
+    }
+}
+
+@Test @MainActor func disconnectedDriveMakesItsGamesUnreachable() async throws {
+    let harness = try Harness()
+    let (url, drive) = try harness.addDrive()
+    try makeGame("Sample", in: url)
+    harness.settle()
+    let game = try #require(harness.game("Sample", on: drive))
+
+    harness.access.set(.notConnected, for: url)
+    await harness.library.reevaluateDriveStates()
+    #expect(harness.library.launchLocation(for: game) == .driveNotConnected)
+}
+
+@Test @MainActor func relinkAsksOnlyWhenNoKnownFolderIsThere() throws {
+    let harness = try Harness()
+    let (url, drive) = try harness.addDrive()
+    try makeGame("Sample", in: url)
+    harness.scan()
+
+    let unrelated = harness.root.appendingPathComponent("Unrelated", isDirectory: true)
+    try makeGame("Different", in: unrelated)
+    #expect(harness.library.driveManager.relink(drive.id, to: unrelated, confirmed: false) == .needsConfirmation)
+
+    let moved = harness.root.appendingPathComponent("Moved", isDirectory: true)
+    try makeGame("Sample", in: moved)
+    #expect(harness.library.driveManager.relink(drive.id, to: moved, confirmed: false) == .relinked)
+    #expect(harness.location("Sample", on: drive) != nil)
+}
+
+// MARK: Scanning
+
+@Test @MainActor func scannerSkipsDotFoldersAndInbox() throws {
+    let harness = try Harness()
+    try makeGame("Sample", in: harness.documents)
+    try makeGame(".hidden", in: harness.documents)
+    try makeGame("Sample", in: harness.documents.appendingPathComponent(".eikon-importing-\(UUID().uuidString)"))
+    try makeGame("Inbox", in: harness.documents)
+    harness.scan()
+    #expect(harness.locations(on: harness.builtIn).count == 1)
+}
+
+@Test @MainActor func newFolderBecomesLocationAndVanishedOneGoesMissing() throws {
+    let harness = try Harness()
+    let folder = try makeGame("Sample", in: harness.documents)
+    harness.scan()
+    let location = try #require(harness.location("Sample"))
+
+    try FileManager.default.removeItem(at: folder)
+    harness.scan()
+    #expect(harness.location("Sample")?.id == location.id)
+    #expect(harness.location("Sample")?.identity == .missing)
+}
+
+@Test @MainActor func changingFolderGetsNoIdentityUntilItSettles() throws {
+    let harness = try Harness()
+    let folder = try makeGame("Sample", in: harness.documents)
+    harness.scan()
+    try write("RPC2two", to: "game/script.rpyc", in: folder)
+    harness.clock.advance(DriveScanner.quiescence + 1)
+    harness.scan()
+    #expect(harness.location("Sample")?.gameID == nil)
+
+    harness.clock.advance(DriveScanner.quiescence / 2)
+    harness.scan()
+    #expect(harness.location("Sample")?.gameID == nil)
+
+    harness.clock.advance(DriveScanner.quiescence / 2 + 1)
+    harness.scan()
+    #expect(harness.location("Sample")?.gameID != nil)
+    #expect(harness.location("Sample")?.fingerprint == nil)
+}
+
+@Test @MainActor func fingerprintOfChangingFolderIsDiscardedAndRebuilt() throws {
+    let harness = try Harness()
+    let folder = try makeGame("Sample", in: harness.documents)
+    harness.scan()
+    harness.clock.advance(DriveScanner.quiescence + 1)
+    harness.scan()
+
+    let patched = Space()
+    patched.value = 0
+    harness.library.worker.onProgress = { _, _ in
+        guard patched.value == 0 else { return }
+        patched.value = 1
+        try? write("RPC2two", to: "game/script.rpyc", in: folder)
+    }
+    harness.library.worker.processNext()
+    #expect(harness.location("Sample")?.fingerprint == nil)
+
+    harness.library.worker.onProgress = nil
+    harness.settle()
+    #expect(harness.location("Sample")?.fingerprint != nil)
+}
+
+@Test @MainActor func unrecognizedFolderIsDetectedAgainAfterItChanges() throws {
+    let harness = try Harness()
+    let folder = harness.documents.appendingPathComponent("Sample", isDirectory: true)
+    try write("notes\n", to: "readme.txt", in: folder)
+    harness.scan()
+    #expect(harness.location("Sample")?.detection == nil)
+
+    try makeGame("Sample", in: harness.documents)
+    harness.scan()
+    #expect(harness.location("Sample")?.detection != nil)
+}
+
+// MARK: Import
+
+@Test @MainActor func importLandsOnceAndLeavesSourceUnchanged() async throws {
+    let harness = try Harness()
+    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
+    let before = try FileManager.default.subpathsOfDirectory(atPath: source.path).sorted()
+
+    let outcome = await harness.library.importGame(from: source, to: harness.builtIn.id)
+    guard case .imported(let id) = outcome else { Issue.record("not imported"); return }
+    #expect(exists(harness.documents.appendingPathComponent("Sample/game/script.rpyc")))
+    harness.scan()
+    harness.scan()
+    #expect(harness.locations(on: harness.builtIn).map(\.id) == [id])
+    #expect(try FileManager.default.subpathsOfDirectory(atPath: source.path).sorted() == before)
+}
+
+@Test @MainActor func importOntoExistingNameOffersReplaceOrRename() async throws {
+    let harness = try Harness()
+    try makeGame("Sample", in: harness.documents)
+    harness.settle()
+    let game = try #require(harness.game("Sample"))
+    harness.settings.setDisplayName("Mine", for: game)
+    let update = try makeGame("Sample", in: harness.root.appendingPathComponent("Update"), content: "two")
+
+    #expect(await harness.library.importGame(from: update, to: harness.builtIn.id) == .nameClash)
+    #expect(await harness.library.importGame(from: update, to: harness.builtIn.id, naming: .rename("sample")) == .nameTaken)
+    guard case .imported(let renamed) = await harness.library.importGame(from: update, to: harness.builtIn.id,
+                                                                        naming: .rename("Sample Copy")) else {
+        Issue.record("rename not imported")
+        return
+    }
+    #expect(renamed != harness.location("Sample")?.id)
+
+    let replaced = await harness.library.importGame(from: update, to: harness.builtIn.id, naming: .replaceExisting)
+    #expect(replaced == .imported(try #require(harness.location("Sample")?.id)))
+    harness.settle()
+    #expect(harness.game("Sample") == game)
+    #expect(harness.settings.displayName(for: game) == "Mine")
+}
+
+@Test @MainActor func cancelledOrFailedImportLeavesNothingBehind() async throws {
+    let harness = try Harness()
+    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
+    #expect(await harness.library.importer.importGame(from: source, to: harness.builtIn.id, isCancelled: { true }) == .cancelled)
+
+    let unreadable = source.appendingPathComponent("game/script.rpyc")
+    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
+    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
+    #expect(await harness.library.importer.importGame(from: source, to: harness.builtIn.id) == .failed)
+
+    #expect(try FileManager.default.contentsOfDirectory(atPath: harness.documents.path).isEmpty)
+    #expect(harness.locations(on: harness.builtIn).isEmpty)
+}
+
+@Test @MainActor func leftoverStagingIsRemovedAtStartup() throws {
+    let harness = try Harness()
+    let staging = harness.documents.appendingPathComponent(".eikon-importing-\(UUID().uuidString)")
+    try makeGame("Sample", in: staging)
+    harness.library.importer.cleanStaleStaging()
+    #expect(!exists(staging))
+}
+
+@Test @MainActor func importNeedingMoreSpaceIsRefusedBeforeCopying() async throws {
+    let harness = try Harness()
+    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
+    harness.space.value = 0
+    #expect(await harness.library.importGame(from: source, to: harness.builtIn.id) == .insufficientSpace)
+    #expect(try FileManager.default.contentsOfDirectory(atPath: harness.documents.path).isEmpty)
+}
+
+@Test @MainActor func importDoesNotFollowSymlinksOutOfTheSource() async throws {
+    let harness = try Harness()
+    let outside = harness.root.appendingPathComponent("Outside", isDirectory: true)
+    try write("private\n", to: "secret.txt", in: outside)
+    let source = try makeGame("Sample", in: harness.root.appendingPathComponent("Source"))
+    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: outside)
+
+    guard case .imported = await harness.library.importGame(from: source, to: harness.builtIn.id) else {
+        Issue.record("not imported")
+        return
+    }
+    #expect(exists(harness.documents.appendingPathComponent("Sample/renpy/__init__.py")))
+    #expect(!exists(harness.documents.appendingPathComponent("Sample/link/secret.txt")))
+}
+
+// MARK: Identity across drives
+
+@Test @MainActor func patchKeepsIdentityAndSettings() throws {
+    let harness = try Harness()
+    let folder = try makeGame("Sample", in: harness.documents)
+    harness.settle()
+    let game = try #require(harness.game("Sample"))
+    let detection = harness.location("Sample")?.detection
+    harness.settings.setDisplayName("Mine", for: game)
+
+    try write("RPC2two", to: "game/script.rpyc", in: folder)
+    try write("(7, 4, 11)", to: "game/script_version.txt", in: folder)
+    harness.settle()
+    #expect(harness.game("Sample") == game)
+    #expect(harness.settings.displayName(for: game) == "Mine")
+    #expect(harness.location("Sample")?.detection != detection)
+    #expect(harness.settings.store.fingerprints(game: game.uuid).count == 2)
+}
+
+@Test @MainActor func settledGameGetsAnIDBeforeItsFullFingerprint() throws {
+    let harness = try Harness()
+    try makeGame("Sample", in: harness.documents)
+    harness.scan()
+    harness.clock.advance(DriveScanner.quiescence + 1)
+    harness.scan()
+
+    let game = try #require(harness.game("Sample"))
+    #expect(harness.location("Sample")?.fingerprint == nil)
+    harness.settings.setDisplayName("Mine", for: game)
+    #expect(harness.settings.displayName(for: game) == "Mine")
+}
+
+@Test @MainActor func provisionalCopyMergesSilentlyUnlessItHasSettings() throws {
+    let harness = try Harness()
+    let original = try makeGame("Sample", in: harness.documents)
+    harness.settle()
+    let game = try #require(harness.game("Sample"))
+
+    let (first, firstDrive) = try harness.addDrive()
+    try FileManager.default.copyItem(at: original, to: first.appendingPathComponent("Sample"))
+    harness.settle()
+    #expect(harness.game("Sample", on: firstDrive) == game)
+
+    let (second, secondDrive) = try harness.addDrive()
+    try FileManager.default.copyItem(at: original, to: second.appendingPathComponent("Sample"))
+    harness.scan()
+    harness.clock.advance(DriveScanner.quiescence + 1)
+    harness.scan()
+    let provisional = try #require(harness.game("Sample", on: secondDrive))
+    harness.settings.setDisplayName("Mine", for: provisional)
+    while harness.library.worker.processNext() {}
+    #expect(harness.game("Sample", on: secondDrive) == provisional)
+    #expect(harness.location("Sample", on: secondDrive)?.suggestion.contains(game) == true)
+}
+
+@Test @MainActor func renamingOrMovingAGameKeepsItsID() throws {
+    let harness = try Harness()
+    let folder = try makeGame("Sample", in: harness.documents)
+    harness.settle()
+    let game = try #require(harness.game("Sample"))
+
+    let renamed = harness.documents.appendingPathComponent("Renamed")
+    try FileManager.default.moveItem(at: folder, to: renamed)
+    harness.settle()
+    #expect(harness.game("Renamed") == game)
+
+    let (url, drive) = try harness.addDrive()
+    try FileManager.default.moveItem(at: renamed, to: url.appendingPathComponent("Renamed"))
+    harness.settle()
+    #expect(harness.game("Renamed", on: drive) == game)
+}
+
+@Test @MainActor func sameGameOnTwoDrivesIsOneGame() async throws {
+    let harness = try Harness()
+    let original = try makeGame("Sample", in: harness.documents, declaredID: nil)
+    let (url, _) = try harness.addDrive()
+    try FileManager.default.copyItem(at: original, to: url.appendingPathComponent("Sample"))
+    harness.settle()
+
+    await harness.library.rescan()
+    #expect(harness.library.games.count == 1)
+    #expect(harness.library.games.first?.locations.count == 2)
+}
+
+@Test @MainActor func differentVersionIsANewGameWithASuggestion() async throws {
+    let harness = try Harness()
+    try makeGame("Sample", in: harness.documents)
+    harness.settle()
+    let game = try #require(harness.game("Sample"))
+
+    let (url, drive) = try harness.addDrive()
+    try makeGame("Sample", in: url, content: "two")
+    harness.settle()
+    let other = try #require(harness.game("Sample", on: drive))
+    #expect(other != game)
+    #expect(harness.location("Sample", on: drive)?.suggestion.contains(game) == true)
+
+    await harness.library.merge(other, into: game)
+    #expect(harness.game("Sample", on: drive) == game)
+}
+
+// MARK: Fingerprint worker
+
+@Test @MainActor func suspendedWorkerMakesNoProgressUntilResumed() throws {
+    let harness = try Harness()
+    try makeGame("Sample", in: harness.documents)
+    harness.scan()
+    harness.clock.advance(DriveScanner.quiescence + 1)
+    harness.scan()
+
+    harness.library.worker.suspend()
+    #expect(!harness.library.worker.processNext())
+    #expect(harness.location("Sample")?.fingerprint == nil)
+    harness.library.worker.resume()
+    #expect(harness.library.worker.processNext())
+    #expect(harness.location("Sample")?.fingerprint != nil)
+}
+
+@Test @MainActor func viewedLocationIsFingerprintedFirst() throws {
+    let harness = try Harness()
+    try makeGame("First", in: harness.documents, content: "one")
+    try makeGame("Second", in: harness.documents, content: "two")
+    harness.scan()
+    harness.clock.advance(DriveScanner.quiescence + 1)
+    harness.scan()
+
+    harness.library.setViewedLocation(harness.location("Second")?.id)
+    harness.library.worker.processNext()
+    #expect(harness.location("Second")?.fingerprint != nil)
+    #expect(harness.location("First")?.fingerprint == nil)
+}
+
+// MARK: Remove
+
+@Test @MainActor func removingWithDataUnsetsSettingsAndRunsCleanupOnce() async throws {
+    let harness = try Harness()
+    try makeGame("First", in: harness.documents, declaredID: "First")
+    try makeGame("Second", in: harness.documents, declaredID: "Second", content: "two")
+    harness.settle()
+    let first = try #require(harness.game("First")), second = try #require(harness.game("Second"))
+    harness.settings.setDisplayName("One", for: first)
+    harness.settings.setDisplayName("Two", for: second)
+    let cleanup = CountingCleanup()
+    harness.hooks.register(cleanup)
+
+    await harness.library.remove(game: first, deleteLocations: [], deleteData: true)
+    #expect(harness.settings.displayName(for: first) == nil)
+    #expect(harness.settings.store.fingerprints(game: first.uuid).isEmpty)
+    #expect(cleanup.calls == [first])
+    #expect(harness.settings.displayName(for: second) == "Two")
+    #expect(harness.game("Second") == second)
+}
+
+@Test @MainActor func deletingFilesRemovesOnlyTheCheckedLocations() async throws {
+    let harness = try Harness()
+    let original = try makeGame("Sample", in: harness.documents)
+    let (url, drive) = try harness.addDrive()
+    try FileManager.default.copyItem(at: original, to: url.appendingPathComponent("Sample"))
+    try makeGame("Other", in: url, declaredID: "Other", content: "two")
+    harness.settle()
+    let game = try #require(harness.game("Sample"))
+    #expect(harness.game("Sample", on: drive) == game)
+
+    let checked = try #require(harness.location("Sample")?.id)
+    await harness.library.remove(game: game, deleteLocations: [checked], deleteData: false)
+    #expect(!exists(original))
+    #expect(exists(url.appendingPathComponent("Sample")))
+    #expect(exists(url.appendingPathComponent("Other")))
+}

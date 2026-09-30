import EikonCore
import Foundation

/// Why a folder can't become a game drive. The UI maps each to a one-line reason.
public enum DriveRefusal: Error, Sendable, Equatable {
    case iCloud, network, unknownVolume
    /// The folder is a drive already, or lies inside or around one.
    case overlapsDrive
    /// The folder couldn't be bookmarked or opened.
    case unreadable
}

public enum RelinkOutcome: Sendable, Equatable {
    case relinked
    /// The folder holds none of the drive's known game folders; call again with `confirmed`.
    case needsConfirmation
    case refused(DriveRefusal)
}

/// Adds, opens, re-links and removes game drives. The built-in drive (`Documents/`) always
/// exists, can't be removed and is always available.
public final class DriveManager: @unchecked Sendable {
    public let builtInRoot: URL
    private let index: LibraryIndex
    private let access: any FolderAccess
    private let lock = NSLock()
    private var states: [UUID: DriveState] = [:]

    public init(index: LibraryIndex, access: any FolderAccess, builtInRoot: URL) {
        self.index = index
        self.access = access
        self.builtInRoot = builtInRoot
        index.update { contents in
            if !contents.drives.contains(where: { $0.kind == .builtIn }) {
                contents.drives.insert(GameDrive(id: UUID(), kind: .builtIn, label: builtInRoot.lastPathComponent), at: 0)
            }
        }
    }

    /// Accepts internal and external-local folders.
    public func add(_ url: URL) -> Result<GameDrive, DriveRefusal> {
        if let refusal = refusal(for: url, replacing: nil) { return .failure(refusal) }
        guard let bookmark = try? access.makeBookmark(for: url) else { return .failure(.unreadable) }
        let drive = GameDrive(id: UUID(), kind: .folder(bookmark: bookmark), label: url.lastPathComponent)
        index.update { $0.drives.append(drive) }
        lock.withLock { states[drive.id] = .available }
        return .success(drive)
    }

    /// Opens the drive's root for as long as the token stays open; nil when the drive isn't
    /// available. Records the state it found and persists a refreshed bookmark.
    public func open(_ drive: GameDrive) -> AccessToken? {
        let bookmark: Data
        switch drive.kind {
        case .builtIn:
            lock.withLock { states[drive.id] = .available }
            return AccessToken(url: builtInRoot) {}
        case .folder(let data):
            bookmark = data
        }
        let outcome = (try? access.open(bookmark: bookmark)) ?? .stale
        switch outcome {
        case .opened(let token, let refreshed):
            lock.withLock { states[drive.id] = .available }
            if let refreshed {
                index.update { contents in
                    if let at = contents.drives.firstIndex(where: { $0.id == drive.id }) {
                        contents.drives[at].kind = .folder(bookmark: refreshed)
                    }
                }
            }
            return token
        case .notConnected:
            lock.withLock { states[drive.id] = .notConnected }
            return nil
        case .stale:
            lock.withLock { states[drive.id] = .needsRelink }
            return nil
        }
    }

    /// Opens every drive once to refresh its state. Call at launch, on scene activation and
    /// before launching a game.
    @discardableResult
    public func reevaluate() -> [UUID: DriveState] {
        for drive in index.contents.drives {
            open(drive)?.close()
        }
        return lock.withLock { states }
    }

    /// The state found by the last open, without touching the drive. The built-in drive is
    /// always available; a drive not opened yet reads as not connected.
    public func state(of id: UUID) -> DriveState {
        if index.contents.drive(id)?.kind == .builtIn { return .available }
        return lock.withLock { states[id] } ?? .notConnected
    }

    /// Points the drive at a newly picked folder, keeping its id so its locations stay
    /// attached. A folder holding none of the drive's known game folders needs `confirmed`.
    public func relink(_ id: UUID, to url: URL, confirmed: Bool) -> RelinkOutcome {
        // The built-in drive is always `Documents/`.
        guard index.contents.drive(id)?.kind != .builtIn else { return .refused(.overlapsDrive) }
        if let refusal = refusal(for: url, replacing: id) { return .refused(refusal) }
        guard let bookmark = try? access.makeBookmark(for: url) else { return .refused(.unreadable) }
        if !confirmed {
            let known = Set(index.contents.locations.filter { $0.driveID == id }.map { NameNormalizer.normalize($0.folderName) })
            guard case .opened(let token, _)? = try? access.open(bookmark: bookmark) else { return .refused(.unreadable) }
            let found = (try? DriveScanner.gameFolders(in: token.url, builtIn: false)) ?? []
            token.close()
            if !known.isEmpty, known.isDisjoint(with: found.map { NameNormalizer.normalize($0.lastPathComponent) }) {
                return .needsConfirmation
            }
        }
        index.update { contents in
            if let at = contents.drives.firstIndex(where: { $0.id == id }) {
                contents.drives[at].kind = .folder(bookmark: bookmark)
                contents.drives[at].label = url.lastPathComponent
            }
        }
        lock.withLock { states[id] = .available }
        return .relinked
    }

    /// Forgets the drive and its locations. The files on it and the games' settings stay.
    public func remove(_ id: UUID) {
        index.update { contents in
            guard contents.drive(id)?.kind != .builtIn else { return }
            contents.drives.removeAll { $0.id == id }
            contents.locations.removeAll { $0.driveID == id }
        }
        lock.withLock { states[id] = nil }
    }

    /// Every other drive's root that can be opened now.
    func roots(excluding excluded: UUID? = nil) -> [URL] {
        index.contents.drives.filter { $0.id != excluded }.compactMap { drive in
            guard let token = open(drive) else { return nil }
            defer { token.close() }
            return token.url
        }
    }

    /// Whether one folder is the other or lies inside it, after resolving symlinks.
    static func overlap(_ a: URL, _ b: URL) -> Bool {
        let first = a.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let second = b.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let shorter = min(first.count, second.count)
        return Array(first.prefix(shorter)) == Array(second.prefix(shorter))
    }

    private func refusal(for url: URL, replacing: UUID?) -> DriveRefusal? {
        switch access.volumeKind(of: url) {
        case .internal, .externalLocal: break
        case .ubiquitous: return .iCloud
        case .network: return .network
        case .unknown: return .unknownVolume
        }
        // Two drives over the same folders would list every game twice, and deleting one
        // location's folder could delete another drive's root.
        return roots(excluding: replacing).contains { Self.overlap($0, url) } ? .overlapsDrive : nil
    }
}

import Darwin
import EikonCore
import Foundation
import UIKit

/// What to do when the drive already has a folder with the game's name.
public enum ImportNaming: Sendable, Equatable {
    /// Use the source folder's name; a clash returns `.nameClash`.
    case original
    /// Replace the existing copy, keeping its location and so its game id.
    case replaceExisting
    /// A name that must normalize differently from every folder on the drive.
    case rename(String)
}

public enum ImportOutcome: Sendable, Equatable {
    /// The location the game landed in.
    case imported(UUID)
    case noGameFound
    /// Offer "Replace existing copy" or "Import with another name…".
    case nameClash
    /// The new name clashes too, or isn't a plain folder name.
    case nameTaken
    case insufficientSpace
    case driveUnavailable
    case cancelled
    case failed
}

/// Keeps the app running in the background while work finishes.
public protocol BackgroundActivity: Sendable {
    /// Returns the call that ends the activity.
    @MainActor func begin(_ name: String) -> @MainActor @Sendable () -> Void
}

public struct LiveBackgroundActivity: BackgroundActivity {
    public init() {}

    @MainActor
    public func begin(_ name: String) -> @MainActor @Sendable () -> Void {
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { task.end() }
        }
        return { task.end() }
    }
}

@MainActor
private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Free bytes on the volume holding a URL: the "important usage" figure on internal
/// storage, the plain one elsewhere.
public enum FreeSpace {
    public static let live: @Sendable (URL) -> Int64? = { url in
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey])
        if values?.volumeIsInternal == true, let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Copies a game folder into a drive: into a hidden staging folder first, then renamed
/// into place, so a drive never shows a partial game. The source is never changed, and
/// symlinks in it are skipped, never followed.
public final class ImportCoordinator: @unchecked Sendable {
    static let stagingPrefix = ".eikon-importing-"

    private let context: LibraryContext
    private let drives: DriveManager
    private let freeSpace: @Sendable (URL) -> Int64?
    private let background: any BackgroundActivity

    public init(context: LibraryContext, drives: DriveManager, freeSpace: @escaping @Sendable (URL) -> Int64? = FreeSpace.live,
                background: any BackgroundActivity = LiveBackgroundActivity()) {
        self.context = context
        self.drives = drives
        self.freeSpace = freeSpace
        self.background = background
    }

    /// The copy's total size, for the drive picker; nil when no game is found there.
    public func size(of source: URL) -> UInt64? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard (try? GameDetector.detect(folder: source)) != nil, let items = try? Self.enumerate(source) else { return nil }
        return items.reduce(0) { $0 + $1.size }
    }

    /// `progress` is throttled; `isCancelled` is checked between files and between chunks.
    public func importGame(from source: URL, to driveID: UUID, naming: ImportNaming = .original,
                           progress: @escaping @Sendable (Double) -> Void = { _ in },
                           isCancelled: @escaping @Sendable () -> Bool = { false }) async -> ImportOutcome {
        let end = await background.begin("eikon.import")
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: perform(source, driveID, naming, progress, isCancelled))
            }
        }
        await end()
        return outcome
    }

    /// Removes every staging folder left on an available drive by an import that was
    /// interrupted (the app was suspended or killed). Call at startup, before any import.
    public func cleanStaleStaging() {
        for drive in context.index.contents.drives {
            guard let token = drives.open(drive) else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(at: token.url, includingPropertiesForKeys: nil)) ?? []
            for child in children where child.lastPathComponent.hasPrefix(Self.stagingPrefix) {
                try? FileManager.default.removeItem(at: child)
            }
            token.close()
        }
    }

    // MARK: Steps

    private func perform(_ source: URL, _ driveID: UUID, _ naming: ImportNaming,
                         _ progress: @escaping @Sendable (Double) -> Void,
                         _ isCancelled: @escaping @Sendable () -> Bool) -> ImportOutcome {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let detection = try? GameDetector.detect(folder: source) else { return .noGameFound }
        guard let drive = context.index.contents.drive(driveID), let token = drives.open(drive) else { return .driveUnavailable }
        defer { token.close() }
        let root = token.url

        // Names on the drive: folders there, and locations whose folder is missing.
        let existing = ((try? DriveScanner.gameFolders(in: root, builtIn: drive.kind == .builtIn)) ?? []).map(\.lastPathComponent)
            + context.index.contents.locations.filter { $0.driveID == driveID }.map(\.folderName)
        func clash(_ name: String) -> String? {
            existing.first { NameNormalizer.normalize($0) == NameNormalizer.normalize(name) }
        }
        var name = source.lastPathComponent
        var replacing = false
        switch naming {
        case .original:
            if clash(name) != nil { return .nameClash }
        case .replaceExisting:
            if let current = clash(name) {
                name = current
                replacing = true
            }
        case .rename(let newName):
            guard clash(newName) == nil else { return .nameTaken }
            name = newName
        }
        // A name the scanner skips would land out of sight.
        guard Self.isPlainName(name, builtIn: drive.kind == .builtIn) else { return .nameTaken }

        guard let items = try? Self.enumerate(source) else { return .failed }
        let total = items.reduce(0) { $0 + $1.size }
        let margin = max(total / 20, 64 << 20)
        guard let free = freeSpace(root), free >= 0, UInt64(free) >= total + margin else { return .insufficientSpace }

        let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        let staged = staging.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try copy(items, from: source, to: staged, total: total, progress: progress, isCancelled: isCancelled)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
        return commit(staged, name: name, replacing: replacing, root: root, driveID: driveID, detection: detection)
    }

    /// Registers the location before the folder appears, so a scan never adds a second one.
    /// The copy is complete, so its content stamp counts as settled at once.
    private func commit(_ staged: URL, name: String, replacing: Bool, root: URL, driveID: UUID,
                        detection: DetectionResult) -> ImportOutcome {
        let target = root.appendingPathComponent(name, isDirectory: true)
        let settled = LocationSeen(contentStamp: try? FingerprintBuilder.contentStamp(detection: detection, folder: staged),
                                   stampSince: context.now().addingTimeInterval(-DriveScanner.quiescence))
        let (locationID, added) = context.index.update { contents -> (UUID, Bool) in
            if let at = contents.locations.firstIndex(where: { $0.driveID == driveID && $0.folderName == name }) {
                contents.locations[at].lastSeen = settled
                contents.locations[at].detection = detection
                if contents.locations[at].identity != .fingerprinting { contents.locations[at].identity = .pending }
                return (contents.locations[at].id, false)
            }
            let location = GameLocation(driveID: driveID, folderName: name, detection: detection, lastSeen: settled)
            contents.locations.append(location)
            return (location.id, true)
        }
        do {
            if replacing, FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: target)
            }
        } catch {
            if added { context.index.update { $0.locations.removeAll { $0.id == locationID } } }
            return .failed
        }
        return .imported(locationID)
    }

    private static func isPlainName(_ name: String, builtIn: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !name.contains("/") && !name.hasPrefix(".")
            && !(builtIn && name == "Inbox")
    }

    // MARK: Copying

    private struct Item {
        var path: String
        var isDirectory: Bool
        var size: UInt64
    }

    /// Folders and regular files under `root`, parents first. Symlinks are skipped, so
    /// nothing outside the source tree is ever reached.
    private static func enumerate(_ root: URL) throws -> [Item] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var items: [Item] = []
        func walk(_ folder: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try child.resourceValues(forKeys: Set(keys))
                let path = prefix + child.lastPathComponent
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    items.append(Item(path: path, isDirectory: true, size: 0))
                    try walk(child, prefix: path + "/")
                } else if values.isRegularFile == true {
                    items.append(Item(path: path, isDirectory: false, size: UInt64(values.fileSize ?? 0)))
                }
            }
        }
        try walk(root, prefix: "")
        return items
    }

    private func copy(_ items: [Item], from source: URL, to destination: URL, total: UInt64,
                      progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        var done: UInt64 = 0
        var reported = -1.0
        func advance(_ bytes: UInt64) {
            done += bytes
            let fraction = total == 0 ? 1 : min(1, Double(done) / Double(total))
            if fraction - reported >= 0.01 || fraction == 1 {
                reported = fraction
                progress(fraction)
            }
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            if isCancelled() { throw CancellationError() }
            let to = destination.appendingPathComponent(item.path)
            if item.isDirectory {
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                continue
            }
            try Self.copyFile(source.appendingPathComponent(item.path), to: to, isCancelled: isCancelled, advance: advance)
        }
        advance(0)
    }

    /// A coordinated read (file-provider placeholders download first), then an APFS clone
    /// when source and target share a volume, else a chunked copy.
    private static func copyFile(_ from: URL, to: URL, isCancelled: () -> Bool, advance: (UInt64) -> Void) throws {
        var coordination: NSError?
        var failure: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: from, options: [], error: &coordination) { readable in
            do {
                let cloned = readable.path.withCString { src in
                    to.path.withCString { dst in
                        copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE | COPYFILE_ALL | COPYFILE_NOFOLLOW))
                    }
                }
                if cloned == 0 {
                    let size = (try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    advance(UInt64(size))
                    return
                }
                try copyChunks(readable, to: to, isCancelled: isCancelled, advance: advance)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    private static func copyChunks(_ from: URL, to: URL, isCancelled: () -> Bool, advance: (UInt64) -> Void) throws {
        // Never through a symlink swapped in after enumeration: regular files only.
        let fd = from.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadInvalidFileName) }
        guard FileManager.default.createFile(atPath: to.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        while true {
            if isCancelled() { throw CancellationError() }
            guard let chunk = try input.read(upToCount: FileHasher.chunkSize), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            advance(UInt64(chunk.count))
        }
        if let permissions = try? FileManager.default.attributesOfItem(atPath: from.path)[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: to.path)
        }
    }
}

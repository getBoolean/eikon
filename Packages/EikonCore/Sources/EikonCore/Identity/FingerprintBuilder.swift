import CryptoKit
import Foundation

/// Turns a detected game's signals into a keyed `Fingerprint`, read-only. Every signal
/// comes from the game root's contents, never the game folder's own name.
///
/// The exact signal covers every byte of the game: two folders share it only when they
/// are identical apart from saves and OS metadata. That reads the whole game, so callers
/// run it in the background with progress and cancellation.
public enum FingerprintBuilder {
    /// Folders games keep saves in, normalized. Saves change with play, not with the game,
    /// so they stay out of the exact signal at any depth.
    static let saveFolders: Set<String> = ["save", "saves", "savedata", "savegame", "savegames"]
    /// Files the OS drops into folders on browse or copy, normalized; dot-files are skipped too.
    static let systemMetadata: Set<String> = ["thumbs.db", "desktop.ini"]

    /// `progress` reports non-decreasing fractions in 0...1; `isCancelled` is checked between
    /// chunks and throws `CancellationError`. Throws `IdentityError.fileUnreadable` when a
    /// file in the game can't be read.
    public static func build(detection: DetectionResult, folder: URL, secret: LibrarySecret,
                             progress: (Double) -> Void = { _ in },
                             isCancelled: () -> Bool = { false }) throws -> Fingerprint {
        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
        let listing = try FolderListing(url: root)

        let engineID: Keyed?
        let declared = EngineDeclaredID.read(detection: detection, listing: listing, reader: FolderReader(root: root))
        if case .found(let value) = declared {
            engineID = keyed(secret, Data("\(detection.engine.rawValue):\(value)".utf8))
        } else {
            engineID = nil
        }
        let exact = try exactBytes(listing, progress: progress, isCancelled: isCancelled)
        return Fingerprint(engineID: engineID, exact: keyed(secret, exact))
    }

    private struct TreeEntry {
        let path: String
        let entry: FolderListing.Entry
        let url: URL
    }

    /// Length-prefixed entries in depth-first normalized-name order: kind and relative
    /// normalized path, plus size and full SHA-256 for files.
    private static func exactBytes(_ listing: FolderListing, progress: (Double) -> Void,
                                   isCancelled: () -> Bool) throws -> Data {
        var tree: [TreeEntry] = []
        try walk(listing, prefix: "", into: &tree)
        let total = tree.reduce(UInt64(0)) { $0 + ($1.entry.kind == .file ? $1.entry.size : 0) }

        var done: UInt64 = 0
        progress(0)
        var bytes = Data()
        for item in tree {
            switch item.entry.kind {
            case .file:
                bytes.append(UInt8(ascii: "f"))
                appendField(Data(item.path.utf8), to: &bytes)
                var size: UInt64 = 0
                let digest = try FileHasher.digest(of: item.url, isCancelled: isCancelled) { size = $0 } read: { count in
                    done += UInt64(count)
                    progress(total == 0 ? 1 : min(1, Double(done) / Double(total)))
                }
                appendInteger(size, to: &bytes)
                bytes.append(contentsOf: digest)
            case .directory:
                bytes.append(UInt8(ascii: "d"))
                appendField(Data(item.path.utf8), to: &bytes)
            case .symlink:
                bytes.append(UInt8(ascii: "l"))
                appendField(Data(item.path.utf8), to: &bytes)
            }
        }
        progress(1)
        return bytes
    }

    /// Symlinks are recorded by name and never followed.
    private static func walk(_ listing: FolderListing, prefix: String, into tree: inout [TreeEntry]) throws {
        for entry in listing.entries where !isExcluded(entry) {
            let path = prefix + entry.key
            tree.append(TreeEntry(path: path, entry: entry, url: listing.url.appendingPathComponent(entry.name)))
            if entry.kind == .directory {
                try walk(try listing.listing(of: entry), prefix: path + "/", into: &tree)
            }
        }
    }

    private static func isExcluded(_ entry: FolderListing.Entry) -> Bool {
        entry.key.hasPrefix(".") || systemMetadata.contains(entry.key)
            || (entry.kind == .directory && saveFolders.contains(entry.key))
    }

    private static func keyed(_ secret: LibrarySecret, _ message: Data) -> Keyed {
        Keyed(hex: secret.mac(message).lowercaseHex)
    }

    private static func appendField(_ field: Data, to bytes: inout Data) {
        appendInteger(UInt64(field.count), to: &bytes)
        bytes.append(field)
    }

    private static func appendInteger(_ value: UInt64, to bytes: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }
}

import Foundation

/// One directory's immediate entries, sorted by normalized name. All marker lookups go
/// through a listing, so they ignore letter case and Unicode normalization form on any
/// file system. Symlinks are listed but never opened, descended, or matched.
public struct FolderListing: Sendable {
    public enum Kind: String, Sendable {
        case file, directory, symlink
    }

    public struct Entry: Sendable, Equatable {
        /// The name as listed.
        public let name: String
        /// `NameNormalizer.normalize(name)`.
        public let key: String
        public let kind: Kind
        public let size: UInt64

        /// The normalized name without its last extension.
        public var stem: String {
            guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return key }
            return String(key[..<dot])
        }

        /// The normalized last extension, without the dot; "" when there is none.
        public var pathExtension: String {
            guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return "" }
            return String(key[key.index(after: dot)...])
        }
    }

    public let url: URL
    /// Sorted by key, then by listed name.
    public let entries: [Entry]

    /// Throws `DetectionError.folderUnreadable` when the directory can't be listed.
    public init(url: URL) throws {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw DetectionError.folderUnreadable
        }
        var entries: [Entry] = []
        for child in urls {
            guard let values = try? child.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            let kind: Kind
            if values.isSymbolicLink == true {
                kind = .symlink
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                continue
            }
            let name = child.lastPathComponent
            entries.append(Entry(name: name, key: NameNormalizer.normalize(name), kind: kind,
                                 size: UInt64(max(values.fileSize ?? 0, 0))))
        }
        self.url = url
        self.entries = entries.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.name.unicodeScalars.lexicographicallyPrecedes(rhs.name.unicodeScalars) { $0.value < $1.value }
        }
    }

    /// Case- and normalization-insensitive exact lookup of any kind except symlink.
    public func entry(named name: String) -> Entry? {
        let key = NameNormalizer.normalize(name)
        return entries.first { $0.key == key && $0.kind != .symlink }
    }

    public func file(named name: String) -> Entry? {
        file(key: NameNormalizer.normalize(name))
    }

    /// Lookup by an already-normalized key.
    public func file(key: String) -> Entry? {
        entries.first { $0.key == key && $0.kind == .file }
    }

    public func directory(named name: String) -> Entry? {
        entry(named: name).flatMap { $0.kind == .directory ? $0 : nil }
    }

    /// Regular files with this extension (no dot), in sorted order.
    public func files(withExtension ext: String) -> [Entry] {
        let ext = NameNormalizer.normalize(ext)
        return entries.filter { $0.kind == .file && $0.pathExtension == ext }
    }

    /// Entries matching the predicate, in sorted order.
    public func entries(matching predicate: (Entry) -> Bool) -> [Entry] {
        entries.filter(predicate)
    }

    /// The listing of a subdirectory entry. Throws for anything but a directory.
    public func listing(of entry: Entry) throws -> FolderListing {
        guard entry.kind == .directory else { throw DetectionError.folderUnreadable }
        return try FolderListing(url: url.appendingPathComponent(entry.name, isDirectory: true))
    }
}

/// Errors carry codes only: never a path or a name.
public enum DetectionError: Error, Sendable, Equatable {
    case folderUnreadable
}

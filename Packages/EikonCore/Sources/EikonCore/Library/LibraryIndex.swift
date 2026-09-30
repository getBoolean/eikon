import Foundation

/// Everything the library index holds.
public struct LibraryContents: Sendable, Equatable {
    public var drives: [GameDrive]
    public var locations: [GameLocation]

    public init(drives: [GameDrive] = [], locations: [GameLocation] = []) {
        self.drives = drives
        self.locations = locations
    }

    public func drive(_ id: UUID) -> GameDrive? {
        drives.first { $0.id == id }
    }

    public func location(_ id: UUID) -> GameLocation? {
        locations.first { $0.id == id }
    }
}

private struct DrivesDocument: PersistedDocument {
    static let currentFormat = 1
    var drives: TolerantList<GameDrive>
}

private struct LocationsDocument: PersistedDocument {
    static let currentFormat = 1
    var locations: TolerantList<GameLocation>
}

/// `drives.json` and `locations.json`: this device's drives and game folders. Local only,
/// never synced. Lock-guarded; every change is saved before `update` returns. A file from
/// a newer build is never rewritten; an unreadable one is set aside and started over.
public final class LibraryIndex: @unchecked Sendable {
    private let drivesFile: PersistedFile<DrivesDocument>
    private let locationsFile: PersistedFile<LocationsDocument>
    private let lock = NSLock()
    private var drives: DrivesDocument
    private var locations: LocationsDocument

    /// `directory` is `…/Application Support/Eikon` (a temp directory in tests).
    public init(directory: URL) {
        drivesFile = PersistedFile(url: directory.appendingPathComponent("drives.json"))
        locationsFile = PersistedFile(url: directory.appendingPathComponent("locations.json"))
        drives = Self.load(drivesFile) ?? DrivesDocument(drives: TolerantList())
        locations = Self.load(locationsFile) ?? LocationsDocument(locations: TolerantList())
    }

    /// A file this build can't read is set aside (drive bookmarks can't be rebuilt without
    /// the user), unless it came from a newer build, which stays in place and is never
    /// rewritten.
    private static func load<Document: PersistedDocument>(_ file: PersistedFile<Document>) -> Document? {
        do {
            return try file.load()?.document
        } catch {
            let data = try? Data(contentsOf: file.url)
            if let format = data.flatMap(Persisted.format(of:)), format > Document.currentFormat { return nil }
            let aside = file.url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: file.url, to: aside)
            return nil
        }
    }

    public var contents: LibraryContents {
        lock.withLock { LibraryContents(drives: drives.drives.elements, locations: locations.locations.elements) }
    }

    /// Applies `body` atomically and saves the files it changed.
    @discardableResult
    public func update<T>(_ body: (inout LibraryContents) throws -> T) rethrows -> T {
        try lock.withLock {
            var contents = LibraryContents(drives: drives.drives.elements, locations: locations.locations.elements)
            let result = try body(&contents)
            if contents.drives != drives.drives.elements {
                drives.drives.elements = contents.drives
                // Newer-format files refuse the save; the change still holds in memory.
                try? drivesFile.save(drives)
            }
            if contents.locations != locations.locations.elements {
                locations.locations.elements = contents.locations
                try? locationsFile.save(locations)
            }
            return result
        }
    }
}

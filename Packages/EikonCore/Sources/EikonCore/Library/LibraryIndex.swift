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
/// a newer build is never rewritten. An unreadable one is left untouched and reported
/// until the user starts over (see `UnreadableFileReporting`).
public final class LibraryIndex: UnreadableFileReporting, @unchecked Sendable {
    private let drivesFile: PersistedFile<DrivesDocument>
    private let locationsFile: PersistedFile<LocationsDocument>
    private let lock = NSLock()
    private var drives: DrivesDocument
    private var locations: LocationsDocument
    // Guarded by `lock`: files that must not be written until `startOver`.
    private var drivesUnreadable: Bool
    private var locationsUnreadable: Bool

    /// `directory` is `…/Application Support/Eikon` (a temp directory in tests).
    public init(directory: URL) {
        drivesFile = PersistedFile(url: directory.appendingPathComponent("drives.json"))
        locationsFile = PersistedFile(url: directory.appendingPathComponent("locations.json"))
        let loadedDrives = Self.load(drivesFile), loadedLocations = Self.load(locationsFile)
        drives = loadedDrives.document ?? DrivesDocument(drives: TolerantList())
        drivesUnreadable = loadedDrives.unreadable
        locations = loadedLocations.document ?? LocationsDocument(locations: TolerantList())
        locationsUnreadable = loadedLocations.unreadable
    }

    /// The document, or nil with whether the file is unreadable (as opposed to missing or
    /// from a newer build).
    private static func load<Document: PersistedDocument>(_ file: PersistedFile<Document>) -> (document: Document?, unreadable: Bool) {
        switch file.loadOutcome() {
        case .loaded(let loaded): (loaded.document, false)
        case .missing, .newerFormat: (nil, false)
        case .unreadable: (nil, true)
        }
    }

    public var contents: LibraryContents {
        lock.withLock { LibraryContents(drives: drives.drives.elements, locations: locations.locations.elements) }
    }

    public var unreadableFiles: [URL] {
        lock.withLock {
            (drivesUnreadable ? [drivesFile.url] : []) + (locationsUnreadable ? [locationsFile.url] : [])
        }
    }

    public func startOver() {
        lock.withLock {
            if drivesUnreadable, (try? drivesFile.setAside()) != nil {
                drivesUnreadable = false
                try? drivesFile.save(drives)
            }
            if locationsUnreadable, (try? locationsFile.setAside()) != nil {
                locationsUnreadable = false
                try? locationsFile.save(locations)
            }
        }
    }

    /// Applies `body` atomically and saves the files it changed.
    @discardableResult
    public func update<T>(_ body: (inout LibraryContents) throws -> T) rethrows -> T {
        try lock.withLock {
            var contents = LibraryContents(drives: drives.drives.elements, locations: locations.locations.elements)
            let result = try body(&contents)
            // Newer-format files refuse the save; unreadable ones aren't written. Either way
            // the change still holds in memory.
            if contents.drives != drives.drives.elements {
                drives.drives.elements = contents.drives
                if !drivesUnreadable { try? drivesFile.save(drives) }
            }
            if contents.locations != locations.locations.elements {
                locations.locations.elements = contents.locations
                if !locationsUnreadable { try? locationsFile.save(locations) }
            }
            return result
        }
    }
}

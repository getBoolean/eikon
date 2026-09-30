import Darwin
import Foundation

/// Rules shared by every JSON file under Library/Application Support/Eikon/: a top-level
/// integer `format`, atomic replacement, newer formats read-only, tolerant collections.
public enum Persisted {
    /// Atomic replace: temp file in the same directory, fsync, rename, fsync the directory.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644) }
        guard fd >= 0 else { throw posixError(errno) }
        do {
            defer { close(fd) }
            try writeAll(fd, data)
            guard fsync(fd) == 0 else { throw posixError(errno) }
        } catch {
            temporary.path.withCString { _ = unlink($0) }
            throw error
        }

        let renamed = temporary.path.withCString { from in url.path.withCString { to in rename(from, to) } }
        guard renamed == 0 else {
            let code = errno
            temporary.path.withCString { _ = unlink($0) }
            throw posixError(code)
        }
        syncDirectory(directory)
    }

    /// The top-level `format` integer, or nil if the data isn't a JSON object with one.
    public static func format(of data: Data) -> Int? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let number = object?["format"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    /// A JSON object whose `format` is missing, unreadable or newer than `currentFormat`:
    /// possibly written by a newer build, so never rewritten. Data that isn't a JSON object
    /// at all can only be corruption, since every build writes atomically.
    static func isReadOnly(_ data: Data, currentFormat: Int) -> Bool {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        guard let format = format(of: data) else { return true }
        return format > currentFormat
    }

    /// Also flush the directory entry, so the rename survives power loss.
    /// Best effort: process death alone never loses the file.
    private static func syncDirectory(_ directory: URL) {
        let dirFD = directory.path.withCString { open($0, O_RDONLY) }
        guard dirFD >= 0 else { return }
        _ = fsync(dirFD)
        close(dirFD)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var remaining = data[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            if written == 0 { throw POSIXError(.EIO) }
            remaining = remaining.dropFirst(written)
        }
    }
}

/// A document type stored under the persisted-file rules. It must encode as a JSON object.
/// `PersistedFile` stamps the top-level `format` over any the document encodes itself.
public protocol PersistedDocument: Codable, Sendable {
    static var currentFormat: Int { get }
}

/// A store that found one of its files unreadable. The user may have edited it by hand
/// and made a mistake, so the store never replaces it on its own: it keeps working in
/// memory, never writes that file, and reports it. The user either fixes the file and
/// relaunches, or chooses `startOver()`.
public protocol UnreadableFileReporting: AnyObject, Sendable {
    /// Files left untouched because they couldn't be read; empty when all is well.
    var unreadableFiles: [URL] { get }
    /// Keeps each unreadable file as a backup beside it (`<name>.unreadable-<time>`), then
    /// saves what is in memory in its place.
    func startOver()
}

public enum PersistedError: Error, Sendable {
    /// The file on disk has a newer format than this build knows; it is never rewritten.
    case readOnly
}

/// A file-backed document. A file with a newer format loads as read-only, and saving
/// over it never touches the disk. Callers serialize saves to one URL.
public struct PersistedFile<Document: PersistedDocument>: Sendable {
    public struct Loaded: Sendable {
        public var document: Document
        /// The file came from a newer build; callers keep working in memory or fork.
        public var isReadOnly: Bool
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// nil when the file doesn't exist.
    public func load() throws -> Loaded? {
        guard let data = try existingData() else { return nil }
        let document = try JSONDecoder().decode(Document.self, from: data)
        return Loaded(document: document, isReadOnly: Persisted.isReadOnly(data, currentFormat: Document.currentFormat))
    }

    /// Throws `PersistedError.readOnly`, without writing, when the file on disk is newer.
    public func save(_ document: Document) throws {
        if let existing = try existingData(), Persisted.isReadOnly(existing, currentFormat: Document.currentFormat) {
            throw PersistedError.readOnly
        }
        let data = try JSONEncoder().encode(Stamped(document: document, format: Document.currentFormat))
        try Persisted.writeAtomically(data, to: url)
    }

    public enum LoadOutcome: Sendable {
        case loaded(Loaded)
        case missing
        /// A newer build wrote it in a shape this one can't read: read-only, and not a problem.
        case newerFormat
        /// It exists, but this build can't read it and it isn't from a newer build.
        case unreadable
    }

    /// Like `load`, but tells an unreadable file from one a newer build wrote.
    public func loadOutcome() -> LoadOutcome {
        do {
            return try load().map(LoadOutcome.loaded) ?? .missing
        } catch {
            if let data = try? existingData(), let format = Persisted.format(of: data), format > Document.currentFormat {
                return .newerFormat
            }
            return .unreadable
        }
    }

    /// Moves the file aside as `<name>.unreadable-<time>`, kept as a backup. Nothing
    /// happens when there is no file.
    public func setAside() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(stamp)"))
    }

    private func existingData() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
}

/// Encodes the document's own keys plus the top-level `format`.
private struct Stamped<Document: Encodable>: Encodable {
    private enum Key: String, CodingKey { case format }

    let document: Document
    let format: Int

    func encode(to encoder: any Encoder) throws {
        try document.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(format, forKey: .format)
    }
}

/// Per-element tolerant array: decodes good elements, keeps undecodable ones as raw JSON,
/// and encodes both back, the raw ones unchanged after the decoded ones.
public struct TolerantList<Element: Codable & Sendable>: Codable, Sendable {
    /// The in-memory view: only the elements that decoded.
    public var elements: [Element]
    private var undecodable: [RawJSON] = []

    public init(_ elements: [Element] = []) {
        self.elements = elements
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var undecodable: [RawJSON] = []
        while !container.isAtEnd {
            // A failed decode doesn't advance the container, so the same value is read raw.
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                undecodable.append(try container.decode(RawJSON.self))
            }
        }
        self.elements = elements
        self.undecodable = undecodable
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(contentsOf: elements)
        try container.encode(contentsOf: undecodable)
    }
}

/// Any JSON value, kept verbatim for re-emission.
private indirect enum RawJSON: Codable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([RawJSON])
    case object([String: RawJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RawJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RawJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

private func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

import Foundation

/// A folder whose immediate subfolders are games: the app's own `Documents/`, or a folder
/// the user picked (on the device or a USB drive).
public struct GameDrive: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: DriveKind
    /// User-visible and device-local (the folder's name); never logged or exported.
    public var label: String

    public init(id: UUID, kind: DriveKind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }
}

public enum DriveKind: Codable, Sendable, Equatable {
    /// `Documents/`: needs no bookmark and is always available.
    case builtIn
    /// A picked folder, reached through its security-scoped bookmark.
    case folder(bookmark: Data)

    private enum Key: String, CodingKey { case type, bookmark }

    /// An unknown kind from a newer build fails to decode, so the index keeps that drive's
    /// raw form and writes it back unchanged.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .type) {
        case "builtIn": self = .builtIn
        case "folder": self = .folder(bookmark: try container.decode(Data.self, forKey: .bookmark))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown drive kind")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .builtIn:
            try container.encode("builtIn", forKey: .type)
        case .folder(let bookmark):
            try container.encode("folder", forKey: .type)
            try container.encode(bookmark, forKey: .bookmark)
        }
    }
}

public enum DriveState: Sendable, Equatable {
    case available
    /// The volume is absent (unplugged).
    case notConnected
    /// The bookmark is stale and can't be resolved: the user has to find the folder again.
    case needsRelink
}

/// Where a folder lives. Only internal and external-local volumes can be game drives:
/// evictable or network files are unsafe under an in-process emulator.
public enum VolumeKind: Sendable, Equatable {
    case `internal`, externalLocal, ubiquitous, network, unknown
}

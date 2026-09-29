import Foundation

/// One device's (one install's) identity in the settings files. Random, created once.
public struct ReplicaID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID) {
        self.uuid = uuid
    }

    public static func random() -> ReplicaID {
        ReplicaID(uuid: UUID())
    }

    public var description: String { uuid.uuidString.lowercased() }

    public static func < (lhs: ReplicaID, rhs: ReplicaID) -> Bool {
        lhs.description < rhs.description
    }

    /// Coded as the bare UUID string.
    public init(from decoder: any Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    static let fileName = "replica-id"

    /// Reads `replica-id` in `directory`; a missing or unreadable file gets a new random id.
    public static func loadOrCreate(in directory: URL) throws -> ReplicaID {
        let url = directory.appendingPathComponent(fileName)
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return ReplicaID(uuid: uuid)
        }
        let id = random()
        try store(id, in: directory)
        return id
    }

    /// Replaces the stored id, so a fork survives restarts. The file is kept out of backups:
    /// a device restored from another's backup mints its own id and reads the restored
    /// settings file as a peer, instead of two devices sharing one replica.
    static func store(_ id: ReplicaID, in directory: URL) throws {
        var url = directory.appendingPathComponent(fileName)
        try Persisted.writeAtomically(Data(id.description.utf8), to: url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

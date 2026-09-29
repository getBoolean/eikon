import Foundation

/// `settings/<replica>.json`: one replica's full merged view. Decodes tolerantly, so a
/// file from a newer build loads as far as its fields and entries decode. Undecodable
/// entries are kept raw and written back unchanged. Adding a top-level or per-entry field
/// requires a `format` bump: an older build rewrites only the fields it knows.
struct ReplicaFile: PersistedDocument {
    static let currentFormat = 1

    var replica: ReplicaID?
    var clock: HybridTimestamp?
    var entries: [String: LWWEntry]
    var forkedFrom: ReplicaID?
    /// Entries this build can't decode, re-emitted as read.
    var undecodable: [String: JSONValue] = [:]

    init(replica: ReplicaID, clock: HybridTimestamp, entries: [String: LWWEntry], forkedFrom: ReplicaID?) {
        self.replica = replica
        self.clock = clock
        self.entries = entries
        self.forkedFrom = forkedFrom
    }

    private enum CodingKeys: String, CodingKey {
        case replica, clock, entries, forkedFrom
    }

    /// Entries that fail to decode are skipped; they stay in the file on disk.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replica = try? container.decodeIfPresent(ReplicaID.self, forKey: .replica)
        clock = try? container.decodeIfPresent(HybridTimestamp.self, forKey: .clock)
        forkedFrom = try? container.decodeIfPresent(ReplicaID.self, forKey: .forkedFrom)
        let raw = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .entries)) ?? [:]
        var entries: [String: LWWEntry] = [:]
        for (key, value) in raw {
            if let entry = value.decoded(as: LWWEntry.self) { entries[key] = entry } else { undecodable[key] = value }
        }
        self.entries = entries
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(replica, forKey: .replica)
        try container.encodeIfPresent(clock, forKey: .clock)
        var all = undecodable
        for (key, entry) in entries {
            all[key] = try JSONValue(encoding: entry)
        }
        try container.encode(all, forKey: .entries)
        try container.encodeIfPresent(forkedFrom, forKey: .forkedFrom)
    }
}

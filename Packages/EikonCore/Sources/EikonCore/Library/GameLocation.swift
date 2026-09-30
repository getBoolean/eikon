import Foundation

/// One game folder on one drive. Several locations can belong to one game.
public struct GameLocation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var driveID: UUID
    /// Device-local only; a title in practice, so never logged or exported.
    public var folderName: String
    /// Cached; nil when no game was found (listed under "Not recognized").
    public var detection: DetectionResult?
    /// The latest full fingerprint; nil until one has been computed.
    public var fingerprint: Fingerprint?
    /// nil only until the first match runs.
    public var gameID: GameID?
    /// `gameID` was minted by the quick pass and the full pass hasn't confirmed it yet.
    /// Only such a game, without user data, merges silently into an exact match.
    public var isProvisional: Bool
    public var identity: IdentityState
    public var lastSeen: LocationSeen
    /// The content stamp `fingerprint` was built from.
    public var fingerprintedStamp: String?
    /// Launch-location preference.
    public var lastUsedAt: Date?
    /// Non-blocking "same game as…?" candidates.
    public var suggestion: [GameID]
    public var dismissedSuggestions: [GameID]

    public init(id: UUID = UUID(), driveID: UUID, folderName: String, detection: DetectionResult? = nil,
                fingerprint: Fingerprint? = nil, gameID: GameID? = nil, isProvisional: Bool = false,
                identity: IdentityState = .pending,
                lastSeen: LocationSeen = LocationSeen(), fingerprintedStamp: String? = nil, lastUsedAt: Date? = nil,
                suggestion: [GameID] = [], dismissedSuggestions: [GameID] = []) {
        self.id = id
        self.driveID = driveID
        self.folderName = folderName
        self.detection = detection
        self.fingerprint = fingerprint
        self.gameID = gameID
        self.isProvisional = isProvisional
        self.identity = identity
        self.lastSeen = lastSeen
        self.fingerprintedStamp = fingerprintedStamp
        self.lastUsedAt = lastUsedAt
        self.suggestion = suggestion
        self.dismissedSuggestions = dismissedSuggestions
    }
}

/// Where a location is in finding its identity.
public enum IdentityState: Codable, Sendable, Equatable {
    /// New, or waiting for the fingerprint worker.
    case pending
    /// The contents are still changing (a copy or patch in progress).
    case waitingForQuiescence
    /// The full fingerprint is being built. Persisted, it loads as `pending`.
    case fingerprinting
    case identified
    case failed(IdentityFailure)
    /// The folder vanished while its drive was available. Never deleted automatically.
    case missing

    private enum Key: String, CodingKey { case state, code }

    /// Unknown states (from a newer build) and `fingerprinting` load as `pending`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .state) {
        case "waitingForQuiescence": self = .waitingForQuiescence
        case "identified": self = .identified
        case "missing": self = .missing
        case "failed": self = .failed((try? container.decode(IdentityFailure.self, forKey: .code)) ?? .unreadable)
        default: self = .pending
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .pending: try container.encode("pending", forKey: .state)
        case .waitingForQuiescence: try container.encode("waitingForQuiescence", forKey: .state)
        case .fingerprinting: try container.encode("fingerprinting", forKey: .state)
        case .identified: try container.encode("identified", forKey: .state)
        case .missing: try container.encode("missing", forKey: .state)
        case .failed(let code):
            try container.encode("failed", forKey: .state)
            try container.encode(code, forKey: .code)
        }
    }
}

/// App-defined failure codes; never a path or name.
public enum IdentityFailure: String, Codable, Sendable, Equatable {
    /// A file in the game couldn't be read.
    case unreadable
    /// The drive couldn't be opened.
    case driveUnavailable
}

/// What the scanner saw last, to tell when to re-detect and when a copy has settled.
public struct LocationSeen: Codable, Sendable, Equatable {
    /// `FingerprintBuilder.contentStamp` of the game root.
    public var contentStamp: String?
    /// When `contentStamp` was first seen with its current value.
    public var stampSince: Date?
    /// Digest of the folder's top-level names.
    public var listingDigest: String?
    /// The folder's modification date.
    public var modifiedAt: Date?

    public init(contentStamp: String? = nil, stampSince: Date? = nil, listingDigest: String? = nil, modifiedAt: Date? = nil) {
        self.contentStamp = contentStamp
        self.stampSince = stampSince
        self.listingDigest = listingDigest
        self.modifiedAt = modifiedAt
    }
}

import CryptoKit
import Foundation

/// A game's identity: a random UUID, minted once. It never encodes anything about the game.
public struct GameID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID) {
        self.uuid = uuid
    }

    public static func random() -> GameID {
        GameID(uuid: UUID())
    }

    /// The first 8 characters of the lowercase UUID; safe in crash reports since the id is random.
    public var reportID: String {
        String(lowercased.prefix(8))
    }

    public var description: String { lowercased }

    /// Deterministic ordering by the lowercase UUID string.
    public static func < (lhs: GameID, rhs: GameID) -> Bool {
        lhs.lowercased < rhs.lowercased
    }

    private var lowercased: String { uuid.uuidString.lowercased() }

    /// Coded as the bare UUID string.
    public init(from decoder: any Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }
}

/// An HMAC-SHA256 under the library secret, as 64 lowercase hex characters.
public struct Keyed: Hashable, Codable, Sendable {
    public let hex: String

    public init(hex: String) {
        self.hex = hex
    }
}

/// A game's content fingerprint. Holds keyed values only, never plain names or ids.
public struct Fingerprint: Codable, Sendable, Equatable {
    /// Bump to change how fingerprints are computed; only equal schemes are compared.
    public static let currentScheme = 1
    /// Fingerprints kept per game: one per distinct build seen, most recent kept.
    public static let maxPerGame = 8

    public var scheme: Int
    /// The engine-declared identity, keyed.
    public var engineID: Keyed?
    /// A full content hash of the game tree (saves and OS metadata excluded), keyed.
    public var exact: Keyed

    public init(scheme: Int = Fingerprint.currentScheme, engineID: Keyed?, exact: Keyed) {
        self.scheme = scheme
        self.engineID = engineID
        self.exact = exact
    }
}

/// The per-library key for fingerprints. Never logged or exported.
public struct LibrarySecret: Sendable, CustomStringConvertible {
    public static let byteCount = 32

    private let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Reads the secret at `url`, creating it once when there is none. Creation never
    /// replaces an existing file, so concurrent creators all end up with the same secret.
    public static func loadOrCreate(at url: URL) throws -> LibrarySecret {
        if !FileManager.default.fileExists(atPath: url.path) {
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let staged = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try bytes.write(to: staged, options: .atomic)
            } catch {
                throw IdentityError.secretUnavailable
            }
            defer { try? FileManager.default.removeItem(at: staged) }
            // link() fails with EEXIST when another creator won; its secret is read below.
            guard link(staged.path, url.path) == 0 || errno == EEXIST else { throw IdentityError.secretUnavailable }
        }
        guard let bytes = try? Data(contentsOf: url), bytes.count == byteCount else {
            throw IdentityError.secretUnavailable
        }
        return LibrarySecret(bytes: bytes)
    }

    public var description: String { "LibrarySecret(redacted)" }

    func mac(_ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: bytes)))
    }
}

/// Errors carry codes only: never a path, a name or a secret.
public enum IdentityError: Error, Sendable, Equatable {
    case secretUnavailable
    case fileUnreadable
}

extension Data {
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

public enum Engine: String, Codable, Sendable, CaseIterable {
    case unity, kirikiri, renpy, gameMaker, bgi, unknown

    /// A value from another build decodes as `.unknown`.
    public init(from decoder: any Decoder) throws {
        self = Engine(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum UnityScripting: String, Codable, Sendable, CaseIterable {
    case mono, il2cpp
}

public enum KirikiriFlavor: String, Codable, Sendable, CaseIterable {
    case krkr2, krkrZ, unknown

    /// A value from another build decodes as `.unknown`.
    public init(from decoder: any Decoder) throws {
        self = KirikiriFlavor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum GameMakerBuild: String, Codable, Sendable, CaseIterable {
    case vm, yyc
}

public enum RenPyVersionKind: String, Codable, Sendable, CaseIterable {
    /// Read from a version file.
    case exact
    /// Inferred from the `lib/` layout: a range, not a version.
    case era
}

/// A Ren'Py version. Exact: `major.minor.patch?`. Era: from `major.minor` (0.0 when
/// unbounded below) to `maxMajor.maxMinor` (nil when open-ended). Formatting is the UI's job.
public struct RenPyVersion: Codable, Sendable, Equatable {
    public var major: Int
    public var minor: Int
    public var patch: Int?
    public var kind: RenPyVersionKind
    public var maxMajor: Int?
    public var maxMinor: Int?

    public init(major: Int, minor: Int, patch: Int? = nil, kind: RenPyVersionKind,
                maxMajor: Int? = nil, maxMinor: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.kind = kind
        self.maxMajor = maxMajor
        self.maxMinor = maxMinor
    }

    public static func exact(_ major: Int, _ minor: Int, _ patch: Int?) -> RenPyVersion {
        RenPyVersion(major: major, minor: minor, patch: patch, kind: .exact)
    }

    public static func era(from: (Int, Int), through: (Int, Int)?) -> RenPyVersion {
        RenPyVersion(major: from.0, minor: from.1, kind: .era, maxMajor: through?.0, maxMinor: through?.1)
    }
}

public struct EngineDetails: Codable, Sendable, Equatable {
    public var unityScripting: UnityScripting?
    /// Best effort, display only.
    public var unityVersion: String?
    public var kirikiriFlavor: KirikiriFlavor?
    /// An XP3 index entry carries TVP_XP3_FILE_PROTECTED. Not an encryption claim.
    public var xp3ProtectedFlag: Bool?
    /// The XP3 index decoded (raw or zlib) and parsed.
    public var xp3IndexReadable: Bool?
    /// `.tpm` and `plugin/*.dll` base names, sorted.
    public var pluginFileNames: [String]
    public var renpyVersion: RenPyVersion?
    /// Game-supplied native module base names, sorted.
    public var renpyNativeExtensions: [String]
    public var gameMakerBuild: GameMakerBuild?

    public init(unityScripting: UnityScripting? = nil, unityVersion: String? = nil,
                kirikiriFlavor: KirikiriFlavor? = nil, xp3ProtectedFlag: Bool? = nil,
                xp3IndexReadable: Bool? = nil, pluginFileNames: [String] = [],
                renpyVersion: RenPyVersion? = nil, renpyNativeExtensions: [String] = [],
                gameMakerBuild: GameMakerBuild? = nil) {
        self.unityScripting = unityScripting
        self.unityVersion = unityVersion
        self.kirikiriFlavor = kirikiriFlavor
        self.xp3ProtectedFlag = xp3ProtectedFlag
        self.xp3IndexReadable = xp3IndexReadable
        self.pluginFileNames = pluginFileNames
        self.renpyVersion = renpyVersion
        self.renpyNativeExtensions = renpyNativeExtensions
        self.gameMakerBuild = gameMakerBuild
    }

    /// Every field is optional on decode: an unknown enum value or a missing array
    /// reads as absent, so files from other builds still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unityScripting = try? container.decodeIfPresent(UnityScripting.self, forKey: .unityScripting)
        unityVersion = try? container.decodeIfPresent(String.self, forKey: .unityVersion)
        kirikiriFlavor = try? container.decodeIfPresent(KirikiriFlavor.self, forKey: .kirikiriFlavor)
        xp3ProtectedFlag = try? container.decodeIfPresent(Bool.self, forKey: .xp3ProtectedFlag)
        xp3IndexReadable = try? container.decodeIfPresent(Bool.self, forKey: .xp3IndexReadable)
        pluginFileNames = (try? container.decodeIfPresent([String].self, forKey: .pluginFileNames)) ?? []
        renpyVersion = try? container.decodeIfPresent(RenPyVersion.self, forKey: .renpyVersion)
        renpyNativeExtensions = (try? container.decodeIfPresent([String].self, forKey: .renpyNativeExtensions)) ?? []
        gameMakerBuild = try? container.decodeIfPresent(GameMakerBuild.self, forKey: .gameMakerBuild)
    }
}

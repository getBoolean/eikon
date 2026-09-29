import Foundation

public enum GamePlatform: String, Codable, Sendable, CaseIterable {
    case windows, linux
}

public struct ExecutableInfo: Codable, Sendable, Equatable {
    /// Relative to the game root.
    public var path: String
    public var format: BinaryFormat
    public var architecture: CPUArchitecture
    /// Raw COFF Machine or ELF e_machine.
    public var machine: UInt16
    /// PE subsystem is Windows GUI; nil for ELF.
    public var isGUI: Bool?

    public init(path: String, format: BinaryFormat, architecture: CPUArchitecture, machine: UInt16, isGUI: Bool?) {
        self.path = path
        self.format = format
        self.architecture = architecture
        self.machine = machine
        self.isGUI = isGUI
    }
}

public struct DetectionResult: Codable, Sendable, Equatable {
    public var engine: Engine
    public var details: EngineDetails
    /// "" or the name of the single wrapper subfolder holding the game.
    public var gameRoot: String
    /// The main executable per platform.
    public var executables: [GamePlatform: ExecutableInfo]
    /// Relative to `gameRoot`.
    public var keyFile: String?
    /// `GameDetector.version` when this was computed; an older one is a stale cache.
    public var detectorVersion: Int

    public init(engine: Engine, details: EngineDetails, gameRoot: String,
                executables: [GamePlatform: ExecutableInfo], keyFile: String?, detectorVersion: Int) {
        self.engine = engine
        self.details = details
        self.gameRoot = gameRoot
        self.executables = executables
        self.keyFile = keyFile
        self.detectorVersion = detectorVersion
    }

    private enum CodingKeys: String, CodingKey {
        case engine, details, gameRoot, executables, keyFile, detectorVersion
    }

    /// `executables` is a JSON object keyed by platform raw value. An entry with an unknown
    /// platform or binary format is dropped rather than failing the result.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decode(Engine.self, forKey: .engine)
        details = (try? container.decodeIfPresent(EngineDetails.self, forKey: .details)) ?? EngineDetails()
        gameRoot = try container.decode(String.self, forKey: .gameRoot)
        keyFile = try container.decodeIfPresent(String.self, forKey: .keyFile)
        detectorVersion = try container.decode(Int.self, forKey: .detectorVersion)

        var executables: [GamePlatform: ExecutableInfo] = [:]
        if container.contains(.executables) {
            let byPlatform = try container.nestedContainer(keyedBy: PlatformKey.self, forKey: .executables)
            for key in byPlatform.allKeys {
                guard let platform = GamePlatform(rawValue: key.stringValue),
                      let info = try? byPlatform.decode(ExecutableInfo.self, forKey: key) else { continue }
                executables[platform] = info
            }
        }
        self.executables = executables
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(engine, forKey: .engine)
        try container.encode(details, forKey: .details)
        try container.encode(gameRoot, forKey: .gameRoot)
        try container.encodeIfPresent(keyFile, forKey: .keyFile)
        try container.encode(detectorVersion, forKey: .detectorVersion)
        var byPlatform = container.nestedContainer(keyedBy: PlatformKey.self, forKey: .executables)
        for platform in GamePlatform.allCases {
            guard let info = executables[platform] else { continue }
            try byPlatform.encode(info, forKey: PlatformKey(stringValue: platform.rawValue))
        }
    }
}

private struct PlatformKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

import Foundation

/// One JSON document of what this launch detected. New measurements go into `gates`.
/// Adding or renaming a top-level field bumps `schemaVersion`, and the filer and schema
/// then have to accept that version.
public struct DeviceReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var app: AppInfo
    public var device: DeviceInfo
    public var os: OSInfo
    public var install: InstallInfo
    public var jit: JITStatus
    public var memory: MemoryInfo
    public var gates: [String: GateResult]
    public var notes: String?

    /// Assembles a report from facts that have already been gathered.
    public static func make(app: AppInfo, installMethod: InstallMethod, evidence: InstallEvidence,
                            jit: JITStatus, system: DeviceSystem, now: Date) -> DeviceReport {
        let seconds = now.timeIntervalSince1970.rounded(.down)
        return DeviceReport(
            schemaVersion: currentSchemaVersion,
            generatedAt: Date(timeIntervalSince1970: seconds),
            app: app,
            device: DeviceInfo(
                modelIdentifier: system.modelIdentifier,
                chip: ChipNames.displayName(forModel: system.modelIdentifier),
                cpuFamily: String(format: "0x%08x", system.cpuFamily)
            ),
            os: OSInfo(name: system.osName, version: system.osVersion, build: system.osBuild),
            install: InstallInfo(method: installMethod, evidence: evidence),
            jit: jit,
            memory: MemoryInfo(availableBytes: system.availableMemoryBytes()),
            gates: [:],
            notes: nil
        )
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DeviceReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceReport.self, from: data)
    }
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var version: String
    public var build: String
    public var commit: String
    public var packageKind: String
    public var bundleIdentifier: String

    public init(version: String, build: String, commit: String, packageKind: String, bundleIdentifier: String) {
        self.version = version
        self.build = build
        self.commit = commit
        self.packageKind = packageKind
        self.bundleIdentifier = bundleIdentifier
    }

    /// A missing Info.plist value becomes "unknown".
    public static func from(_ bundle: Bundle) -> AppInfo {
        func value(_ key: String) -> String {
            let text = bundle.object(forInfoDictionaryKey: key) as? String
            return text.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        }
        return AppInfo(
            version: value("CFBundleShortVersionString"),
            build: value("CFBundleVersion"),
            commit: value("EKGitCommit"),
            packageKind: value("EKPackageKind"),
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown"
        )
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var modelIdentifier: String
    public var chip: String
    public var cpuFamily: String

    public init(modelIdentifier: String, chip: String, cpuFamily: String) {
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.cpuFamily = cpuFamily
    }
}

public struct OSInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var build: String

    public init(name: String, version: String, build: String) {
        self.name = name
        self.version = version
        self.build = build
    }
}

public struct InstallInfo: Codable, Sendable, Equatable {
    public var method: InstallMethod
    public var evidence: InstallEvidence

    public init(method: InstallMethod, evidence: InstallEvidence) {
        self.method = method
        self.evidence = evidence
    }
}

public struct MemoryInfo: Codable, Sendable, Equatable {
    public var availableBytes: UInt64

    public init(availableBytes: UInt64) {
        self.availableBytes = availableBytes
    }
}

public struct GateResult: Codable, Sendable, Equatable {
    public var passed: Bool?
    public var detail: String
    public var measuredAt: Date

    public init(passed: Bool?, detail: String, measuredAt: Date) {
        self.passed = passed
        self.detail = detail
        self.measuredAt = measuredAt
    }
}

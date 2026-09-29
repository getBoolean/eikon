import Foundation

/// One exclusion rule: a pattern over the normalized file name. Raw values are pattern
/// codes, never file names.
public enum ExclusionRule: String, Sendable, CaseIterable {
    case unins
    case unityCrashHandler = "unitycrashhandler"
    case vcRedist = "vc_redist"
    case vcredist
    case dxsetup
    case dotnet
    case ndp
    case notificationHelper = "notification_helper"
    case crashpadHandler = "crashpad_handler"
    case crashReport = "crashreport"
    case oalinst
    case ue4PrereqSetup = "ue4prereqsetup"
    case python
    case zsync
    case renpyExe = "renpy.exe"
    case setup
    case install
    /// A PE carrying the DLL characteristic.
    case dll

    private enum Match { case prefix, stem, name, contains }

    /// Specific rules come before the generic `*setup*` and `*install*`, so each file
    /// counts against the rule that names it most precisely.
    private var match: Match? {
        switch self {
        case .unins, .unityCrashHandler, .vcRedist, .vcredist, .dotnet, .ndp, .crashReport,
             .ue4PrereqSetup, .python, .zsync: .prefix
        case .dxsetup, .notificationHelper, .crashpadHandler, .oalinst: .stem
        case .renpyExe: .name
        case .setup, .install: .contains
        case .dll: nil
        }
    }

    /// The first name rule that removes this file.
    static func nameRule(for entry: FolderListing.Entry) -> ExclusionRule? {
        allCases.first { rule in
            switch rule.match {
            case .prefix: entry.key.hasPrefix(rule.rawValue)
            case .stem: entry.stem == rule.rawValue
            case .name: entry.key == rule.rawValue
            case .contains: entry.key.contains(rule.rawValue)
            case nil: false
            }
        }
    }
}

/// How many candidate binaries each exclusion rule removed. Every folder evaluated as a
/// possible game root counts, including a root that then turns out not to be the game.
public struct ExclusionTally: Sendable, Equatable {
    public private(set) var hits: [ExclusionRule: Int] = [:]

    public init() {}

    public mutating func add(_ rule: ExclusionRule) {
        hits[rule, default: 0] += 1
    }

    public mutating func merge(_ other: ExclusionTally) {
        hits.merge(other.hits, uniquingKeysWith: +)
    }
}

enum MainExecutable {
    /// Extensions probed for the ELF magic. Anything else in the root is a data file.
    private static let linuxExtensions: Set<String> = [
        "", "x86_64", "x86", "x86_32", "x64", "amd64", "bin", "elf", "aarch64", "arm64", "arm32", "appimage", "run",
    ]

    /// The main executable per platform. An engine-chosen path wins when it is a real
    /// executable of that platform's format; otherwise GUI beats console, then the larger
    /// file, then the normalized name.
    static func select(_ listing: FolderListing, _ reader: FolderReader, preferred: [GamePlatform: String],
                       tally: inout ExclusionTally) -> [GamePlatform: ExecutableInfo] {
        var candidates: [GamePlatform: [(entry: FolderListing.Entry, binary: ParsedBinary)]] = [:]
        for entry in listing.entries where entry.kind == .file {
            let platform: GamePlatform
            if entry.pathExtension == "exe" {
                platform = .windows
            } else if linuxExtensions.contains(entry.pathExtension), BinaryInfo.hasELFMagic(reader, path: entry.name) {
                platform = .linux
            } else {
                continue
            }
            guard let binary = reader.binary(entry.name),
                  binary.format == format(of: platform) else { continue }
            if let rule = ExclusionRule.nameRule(for: entry) {
                tally.add(rule)
                continue
            }
            if binary.isDLL {
                tally.add(.dll)
                continue
            }
            candidates[platform, default: []].append((entry, binary))
        }

        var result: [GamePlatform: ExecutableInfo] = [:]
        for platform in GamePlatform.allCases {
            if let path = preferred[platform], let binary = reader.binary(path),
               binary.format == format(of: platform), !binary.isDLL {
                result[platform] = info(path: path, binary)
                continue
            }
            let best = candidates[platform]?.min { lhs, rhs in
                let lhsGUI = lhs.binary.isGUI ?? false, rhsGUI = rhs.binary.isGUI ?? false
                if lhsGUI != rhsGUI { return lhsGUI }
                if lhs.entry.size != rhs.entry.size { return lhs.entry.size > rhs.entry.size }
                return lhs.entry.key < rhs.entry.key
            }
            if let best { result[platform] = info(path: best.entry.name, best.binary) }
        }
        return result
    }

    private static func format(of platform: GamePlatform) -> BinaryFormat {
        switch platform {
        case .windows: .pe
        case .linux: .elf
        }
    }

    private static func info(path: String, _ binary: ParsedBinary) -> ExecutableInfo {
        ExecutableInfo(path: path, format: binary.format, architecture: binary.architecture,
                       machine: binary.machine, isGUI: binary.isGUI)
    }
}

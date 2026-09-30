import Foundation

/// One scanned folder's contribution. Carries no folder name.
public struct ScannedFolder: Sendable {
    /// nil when no game was found.
    public var detection: DetectionResult?
    /// The game root holds UnityPlayer.dll or UnityPlayer.so.
    public var hasUnityPlayer: Bool
    /// In memory only, for blocklist and collision counts; never printed.
    public var declaredID: EngineDeclaredID.Result?
    /// Only with --hash, under the scanner secret.
    public var fingerprint: Fingerprint?
    /// Detection failed; the folder counts only as an error.
    public var failed: Bool
    /// Detection worked but reading the declared id or fingerprinting failed.
    public var identityFailed: Bool

    public init(detection: DetectionResult?, hasUnityPlayer: Bool = false, declaredID: EngineDeclaredID.Result? = nil,
                fingerprint: Fingerprint? = nil, failed: Bool = false, identityFailed: Bool = false) {
        self.detection = detection
        self.hasUnityPlayer = hasUnityPlayer
        self.declaredID = declaredID
        self.fingerprint = fingerprint
        self.failed = failed
        self.identityFailed = identityFailed
    }
}

/// Aggregate, title-free counts over a scanned collection. Pure.
///
/// Output format: one `key: count` line per count, keys dot-separated and lowercase, for
/// example `engine.unity: 3`. Per-folder lines follow a `per-folder:` line.
public struct CollectionSummary: Sendable {
    public let folders: [ScannedFolder]
    public let exclusions: ExclusionTally

    public init(folders: [ScannedFolder], exclusions: ExclusionTally) {
        self.folders = folders
        self.exclusions = exclusions
    }

    private var games: [DetectionResult] { folders.compactMap(\.detection) }

    public var errorCount: Int { folders.filter(\.failed).count }
    public var noGameCount: Int { folders.filter { !$0.failed && $0.detection == nil }.count }

    public var engineCounts: [Engine: Int] { tally(games.map(\.engine)) }

    public func count(_ scripting: UnityScripting) -> Int {
        games.filter { $0.engine == .unity && $0.details.unityScripting == scripting }.count
    }

    public var unityPlayerCount: Int {
        folders.filter { $0.detection?.engine == .unity && $0.hasUnityPlayer }.count
    }

    /// Games whose plugin list holds each base name.
    public var pluginCounts: [String: Int] { tally(games.flatMap { Set($0.details.pluginFileNames) }) }

    public var nativeExtensionCounts: [String: Int] { tally(games.flatMap { Set($0.details.renpyNativeExtensions) }) }

    /// Main executables of every platform, by architecture.
    public var architectureCounts: [CPUArchitecture: Int] {
        tally(games.flatMap { $0.executables.values.map(\.architecture) })
    }

    /// Main executables named Game.exe (any case), by architecture.
    public var gameExeArchitectureCounts: [CPUArchitecture: Int] {
        tally(games.compactMap { game in
            game.executables[.windows].flatMap {
                NameNormalizer.normalize(($0.path as NSString).lastPathComponent) == "game.exe" ? $0.architecture : nil
            }
        })
    }

    public var exclusionCounts: [ExclusionRule: Int] { exclusions.hits }

    public var declaredIDCounts: [Engine: Int] {
        tally(folders.compactMap { folder in
            guard case .found = folder.declaredID else { return nil }
            return folder.detection?.engine
        })
    }

    public var genericDeclaredIDCount: Int { folders.filter { $0.declaredID == .generic }.count }

    /// Folders whose engine and declared id equal another folder's.
    public var sharedEngineIDCount: Int {
        sharedCount(folders.compactMap { folder in
            guard case .found(let value) = folder.declaredID, let engine = folder.detection?.engine else { return nil }
            return "\(engine.rawValue):\(value)"
        })
    }

    /// Folders whose exact fingerprint equals another folder's (only with --hash).
    public var sharedExactCount: Int { sharedCount(folders.compactMap { $0.fingerprint?.exact.hex }) }

    public func formatted(perFolder: Bool) -> String {
        var lines: [String] = []
        func line(_ key: String, _ value: Int) { lines.append("\(key): \(value)") }
        // A game can ship its own module named after itself, so a name is printed only when
        // at least two different games carry it; the rest are counted as `other`.
        func printNames(_ prefix: String, _ names: KeyPath<EngineDetails, [String]>) {
            let (shared, other) = sharedNames(names)
            for (name, count) in shared.sorted(by: { $0.key < $1.key }) { line("\(prefix).\(name)", count) }
            line("\(prefix).other", other)
        }
        func group<Key>(_ prefix: String, _ counts: [Key: Int], name: (Key) -> String) {
            for (key, value) in counts.map({ (name($0.key), $0.value) }).sorted(by: { $0.0 < $1.0 }) {
                line("\(prefix).\(key)", value)
            }
        }

        line("folders", folders.count)
        line("errors", errorCount)
        line("identity-errors", folders.filter(\.identityFailed).count)
        line("no-game", noGameCount)
        for engine in Engine.allCases { line("engine.\(engine.rawValue)", engineCounts[engine] ?? 0) }
        for scripting in UnityScripting.allCases { line("unity.\(scripting.rawValue)", count(scripting)) }
        line("unity.unityplayer", unityPlayerCount)
        line("kirikiri.tpm", games.filter { $0.engine == .kirikiri && $0.details.pluginFileNames.contains { $0.lowercased().hasSuffix(".tpm") } }.count)
        group("kirikiri.flavor", tally(games.compactMap(\.details.kirikiriFlavor))) { $0.rawValue }
        line("kirikiri.index-readable", games.filter { $0.details.xp3IndexReadable == true }.count)
        line("kirikiri.protected-flag", games.filter { $0.details.xp3ProtectedFlag == true }.count)
        group("renpy", tally(games.compactMap(\.details.renpyVersion).map(Self.describe))) { $0 }
        group("gamemaker", tally(games.compactMap(\.details.gameMakerBuild))) { $0.rawValue }
        group("arch", architectureCounts) { $0.rawValue }
        group("arch.game-exe", gameExeArchitectureCounts) { $0.rawValue }
        printNames("plugin", \.pluginFileNames)
        printNames("renpy-native", \.renpyNativeExtensions)
        for rule in ExclusionRule.allCases { line("exclusion.\(rule.rawValue)", exclusionCounts[rule] ?? 0) }
        group("identity.declared", declaredIDCounts) { $0.rawValue }
        line("identity.declared-generic", genericDeclaredIDCount)
        line("identity.engine-id-shared", sharedEngineIDCount)
        if folders.contains(where: { $0.fingerprint != nil }) { line("identity.exact-shared", sharedExactCount) }

        if perFolder {
            lines.append("per-folder:")
            // Visit order; by exact fingerprint when there are fingerprints.
            var rows = folders.map { folder -> (exact: String?, label: String) in
                let label = folder.failed ? "error" : folder.detection?.engine.rawValue ?? "none"
                return (folder.fingerprint.map { String($0.exact.hex.prefix(12)) }, label)
            }
            if rows.contains(where: { $0.exact != nil }) {
                rows = rows.enumerated().sorted { lhs, rhs in
                    (lhs.element.exact ?? "", lhs.offset) < (rhs.element.exact ?? "", rhs.offset)
                }.map(\.element)
            }
            for row in rows {
                lines.append(row.exact.map { "\($0) \(row.label)" } ?? row.label)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Occurrence counts of names found in at least two distinct games, and how many
    /// occurrences were left out. Copies of one game (the same engine and declared id) count once.
    private func sharedNames(_ names: KeyPath<EngineDetails, [String]>) -> (shared: [String: Int], other: Int) {
        var games: [String: Set<String>] = [:]
        var occurrences: [String: Int] = [:]
        for (index, folder) in folders.enumerated() {
            guard let detection = folder.detection else { continue }
            let game: String
            if case .found(let value)? = folder.declaredID {
                game = "\(detection.engine.rawValue):\(value)"
            } else {
                game = "#\(index)"
            }
            for name in Set(detection.details[keyPath: names]) {
                games[name, default: []].insert(game)
                occurrences[name, default: 0] += 1
            }
        }
        var shared: [String: Int] = [:]
        var other = 0
        for (name, count) in occurrences {
            if games[name, default: []].count >= 2 { shared[name] = count } else { other += count }
        }
        return (shared, other)
    }

    /// `version.8.1.3` or `era.7.4-open`.
    private static func describe(_ version: RenPyVersion) -> String {
        switch version.kind {
        case .exact:
            return "version.\(version.major).\(version.minor)" + (version.patch.map { ".\($0)" } ?? "")
        case .era:
            let upper = version.maxMajor.map { "\($0).\(version.maxMinor ?? 0)" } ?? "open"
            return "era.\(version.major).\(version.minor)-\(upper)"
        }
    }

    private func tally<Key: Hashable>(_ keys: some Sequence<Key>) -> [Key: Int] {
        keys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private func sharedCount(_ keys: [String]) -> Int {
        let counts = tally(keys)
        return keys.filter { counts[$0, default: 0] > 1 }.count
    }
}

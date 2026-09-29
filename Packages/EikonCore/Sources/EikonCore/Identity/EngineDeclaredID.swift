import Foundation

/// The identity a game's engine uses for its own saves: the signal most likely to survive
/// a patch. The plain value lives only in memory; fingerprints store it keyed.
public enum EngineDeclaredID {
    public enum Result: Sendable, Equatable {
        case found(String)
        /// Values were present but every one was an engine's generic default.
        case generic
        case absent
    }

    /// Engine and toolchain defaults that say nothing about the game, normalized.
    /// Scanner data extends this table.
    static let genericValues: Set<String> = Set([
        "TVP(KIRIKIRI)", "TVP(KIRIKIRI) 2", "TVP(KIRIKIRI) Z", "KIRIKIRI", "KIRIKIRI Z",
        "Unity", "Unity Technologies ApS", "DefaultCompany", "My project",
        "Ren'Py", "RenPy", "Python", "YoYo Games Ltd", "GameMaker", "Created with GameMaker Studio 2",
    ].map(NameNormalizer.normalize))

    /// The engine-specific source (Ren'Py, Unity, GameMaker) wins; otherwise the main
    /// Windows executable's CompanyName and ProductName.
    public static func read(detection: DetectionResult, folder: URL) throws -> Result {
        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
        let listing = try FolderListing(url: root)
        return read(detection: detection, listing: listing, reader: FolderReader(root: root))
    }

    static func read(detection: DetectionResult, listing: FolderListing, reader: FolderReader) -> Result {
        let engineSpecific: Result
        switch detection.engine {
        case .renpy: engineSpecific = classify([renpySaveDirectory(listing, reader)])
        case .unity: engineSpecific = classify(unityAppInfo(listing, reader, executables: detection.executables))
        case .gameMaker:
            engineSpecific = classify(GameMakerDetector.dataFile(listing, reader)
                .map { GameMakerDetector.declaredNames(reader, path: $0.name) } ?? [])
        case .kirikiri, .bgi, .unknown: engineSpecific = .absent
        }
        if case .found = engineSpecific { return engineSpecific }

        let versionInfo = detection.executables[.windows].map { exe -> Result in
            let strings = PEVersionResource.strings(reader, path: exe.path)
            return classify([strings["CompanyName"], strings["ProductName"]])
        } ?? .absent
        if case .found = versionInfo { return versionInfo }
        return engineSpecific == .generic || versionInfo == .generic ? .generic : .absent
    }

    /// Present parts minus generic ones, joined; `.generic` when only generic parts remain.
    static func classify(_ parts: [String?]) -> Result {
        let present = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !present.isEmpty else { return .absent }
        let kept = present.filter { !genericValues.contains(NameNormalizer.normalize($0)) }
        return kept.isEmpty ? .generic : .found(kept.joined(separator: "\n"))
    }

    // MARK: Sources

    private static let saveDirectoryPattern = try? NSRegularExpression(
        pattern: #"(?m)^\s*(?:define\s+)?config\.save_directory\s*=\s*[rRuU]?(["'])(.*?)\1"#)

    /// The quoted string assigned to `config.save_directory` in game/options.rpy.
    private static func renpySaveDirectory(_ listing: FolderListing, _ reader: FolderReader) -> String? {
        guard let game = listing.directory(named: "game"), let contents = try? listing.listing(of: game),
              let options = contents.file(named: "options.rpy"),
              let text = reader.text("\(game.name)/\(options.name)"), let pattern = saveDirectoryPattern,
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let value = Range(match.range(at: 2), in: text) else { return nil }
        return String(text[value])
    }

    /// Company and product: the first two lines of `<stem>_Data/app.info`.
    private static func unityAppInfo(_ listing: FolderListing, _ reader: FolderReader,
                                     executables: [GamePlatform: ExecutableInfo]) -> [String?] {
        guard let dataDir = KeyFile.unityDataDirectory(listing, executables: executables),
              let contents = try? listing.listing(of: dataDir), let appInfo = contents.file(named: "app.info"),
              let text = reader.text("\(dataDir.name)/\(appInfo.name)") else { return [] }
        return text.components(separatedBy: .newlines).prefix(2).map { $0 }
    }
}

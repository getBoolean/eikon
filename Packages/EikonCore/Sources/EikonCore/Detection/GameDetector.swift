import Foundation

/// What one engine detector recognized. Executable paths are relative to the game root.
struct EngineMatch {
    var engine: Engine
    var details: EngineDetails
    var executables: [GamePlatform: String] = [:]
}

/// Finds the game in a game folder: its engine, details and main executables. Read-only,
/// never logs, and deterministic regardless of directory listing order.
public enum GameDetector {
    /// Bump whenever detection logic changes; stored results with an older version are recomputed.
    public static let version = 2

    /// Detects the game in a game folder (an immediate child of a game drive). Checks the
    /// folder itself; if no engine markers or executable are there and the folder holds
    /// exactly one subfolder that does, that subfolder is the game root. Read-only.
    /// Returns nil when no game is found; throws only when the folder can't be listed.
    public static func detect(folder: URL) throws -> DetectionResult? {
        var tally = ExclusionTally()
        return try detect(folder: folder, tally: &tally)
    }

    /// Same, also adding exclusion-rule hits to `tally` (used by the collection scanner).
    public static func detect(folder: URL, tally: inout ExclusionTally) throws -> DetectionResult? {
        let listing = try FolderListing(url: folder)
        if let result = evaluate(listing, tally: &tally) { return result }

        let subfolders = listing.entries.filter { $0.kind == .directory && !$0.name.hasPrefix(".") }
        guard subfolders.count == 1, let inner = try? listing.listing(of: subfolders[0]),
              var result = evaluate(inner, tally: &tally) else { return nil }
        result.gameRoot = subfolders[0].name
        return result
    }

    /// Most specific layout first, so a Ren'Py or Unity game that ships an .xp3 or .arc
    /// is not misread.
    private static let detectors: [@Sendable (FolderListing, FolderReader) -> EngineMatch?] = [
        RenPyDetector.detect, UnityDetector.detect, KirikiriDetector.detect, GameMakerDetector.detect, BGIDetector.detect,
    ]

    private static func evaluate(_ listing: FolderListing, tally: inout ExclusionTally) -> DetectionResult? {
        let reader = FolderReader(root: listing.url)
        let match = detectors.lazy.compactMap { $0(listing, reader) }.first
        let executables = MainExecutable.select(listing, reader, preferred: match?.executables ?? [:], tally: &tally)
        guard match != nil || !executables.isEmpty else { return nil }

        var details = match?.details ?? EngineDetails()
        if match?.engine == .kirikiri, let exe = executables[.windows] {
            details.kirikiriFlavor = KirikiriDetector.flavor(reader, executable: exe.path)
        }
        let engine = match?.engine ?? .unknown
        return DetectionResult(engine: engine, details: details, gameRoot: "", executables: executables,
                               keyFile: KeyFile.locate(engine: engine, executables: executables, listing: listing),
                               detectorVersion: version)
    }
}

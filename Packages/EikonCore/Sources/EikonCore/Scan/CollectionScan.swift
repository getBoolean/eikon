import Foundation

public enum ScanOutcome: Sendable {
    /// The root is absent (the share isn't mounted).
    case skipped(root: String)
    /// The root exists but isn't a readable folder.
    case unreadable(root: String)
    case scanned(CollectionSummary)
}

/// Scans a collection root the way the library scans a game drive. Synchronous and
/// read-only: it never writes, sets attributes or caches anything under the root.
public enum CollectionScan {
    /// A fixed, public scanner secret, so fingerprints compare across runs. It keys
    /// scanner output only; the app never uses it, and it is never a library secret.
    public static let scannerSecret = LibrarySecret(bytes: Data("eikon-scan fixed secret, not private".utf8.prefix(32)))

    /// Each immediate, non-dot subfolder goes through GameDetector (with the wrapper rule)
    /// and EngineDeclaredID; with `hash`, also FingerprintBuilder, which reads every file.
    /// `progress` gets (folders done, folder count) and, while hashing, the folder's fraction.
    public static func run(root: URL, hash: Bool,
                           progress: ((_ done: Int, _ total: Int, _ fraction: Double) -> Void)? = nil) -> ScanOutcome {
        guard FileManager.default.fileExists(atPath: root.path) else { return .skipped(root: root.path) }
        guard let listing = try? FolderListing(url: root) else { return .unreadable(root: root.path) }

        let candidates = listing.entries.filter { $0.kind == .directory && !$0.name.hasPrefix(".") }
        var tally = ExclusionTally()
        var folders: [ScannedFolder] = []
        for (index, entry) in candidates.enumerated() {
            progress?(index, candidates.count, 0)
            folders.append(scan(root.appendingPathComponent(entry.name, isDirectory: true), hash: hash, tally: &tally) {
                progress?(index, candidates.count, $0)
            })
        }
        progress?(candidates.count, candidates.count, 1)
        return .scanned(CollectionSummary(folders: folders, exclusions: tally))
    }

    /// A detection failure makes the folder an error; a later identity failure keeps the
    /// detection and marks only the identity part failed.
    private static func scan(_ folder: URL, hash: Bool, tally: inout ExclusionTally,
                             progress: (Double) -> Void) -> ScannedFolder {
        var local = ExclusionTally()
        let detected: DetectionResult?
        do {
            detected = try GameDetector.detect(folder: folder, tally: &local)
        } catch {
            return ScannedFolder(detection: nil, failed: true)
        }
        tally.merge(local)
        guard let detection = detected else { return ScannedFolder(detection: nil) }

        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot)
        let rootListing = try? FolderListing(url: root)
        let hasPlayer = rootListing.map { $0.file(named: "UnityPlayer.dll") != nil || $0.file(named: "UnityPlayer.so") != nil }
        var result = ScannedFolder(detection: detection, hasUnityPlayer: hasPlayer ?? false)
        do {
            result.declaredID = try EngineDeclaredID.read(detection: detection, folder: folder)
            if hash {
                result.fingerprint = try FingerprintBuilder.build(detection: detection, folder: folder,
                                                                  secret: scannerSecret, progress: progress)
            }
        } catch {
            result.identityFailed = true
        }
        return result
    }
}

import Foundation

/// The game-specific file whose size and partial hash go into the exact signal: per
/// engine, the first candidate that exists. Launchers and engine players never qualify.
public enum KeyFile {
    /// A path relative to the game root, or nil when the engine's candidates are all absent.
    public static func locate(engine: Engine, executables: [GamePlatform: ExecutableInfo], root: URL) throws -> String? {
        locate(engine: engine, executables: executables, listing: try FolderListing(url: root))
    }

    static func locate(engine: Engine, executables: [GamePlatform: ExecutableInfo], listing: FolderListing) -> String? {
        let mainExe = mainExecutable(executables)
        switch engine {
        case .kirikiri:
            if let data = listing.file(named: "data.xp3") { return data.name }
            if let largest = largest(listing.files(withExtension: "xp3")) { return largest.name }
            return mainExe
        case .gameMaker:
            return (listing.file(named: "data.win") ?? listing.file(named: "game.unx"))?.name
        case .unity:
            return unity(listing, dataDir: unityDataDirectory(listing, executables: executables))
        case .renpy:
            guard let game = listing.directory(named: "game"), let contents = try? listing.listing(of: game),
                  let archive = largest(contents.files(withExtension: "rpa")) ?? largest(contents.files(withExtension: "rpyc"))
            else { return nil }
            return "\(game.name)/\(archive.name)"
        case .bgi, .unknown:
            return mainExe
        }
    }

    /// The Windows executable if present, otherwise the Linux one.
    static func mainExecutable(_ executables: [GamePlatform: ExecutableInfo]) -> String? {
        (executables[.windows] ?? executables[.linux])?.path
    }

    /// `<stem>_Data` for the main executable's stem, else the first `*_Data` folder.
    static func unityDataDirectory(_ listing: FolderListing,
                                   executables: [GamePlatform: ExecutableInfo]) -> FolderListing.Entry? {
        let stem = mainExecutable(executables).map { path in
            ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return stem.flatMap { listing.directory(named: $0 + "_Data") }
            ?? listing.entries.first { $0.kind == .directory && $0.key.hasSuffix("_data") }
    }

    private static func unity(_ listing: FolderListing, dataDir: FolderListing.Entry?) -> String? {
        for name in ["GameAssembly.dll", "GameAssembly.so"] {
            if let file = listing.file(named: name) { return file.name }
        }
        guard let dataDir, let data = try? listing.listing(of: dataDir) else { return nil }
        if let managed = data.directory(named: "Managed"), let contents = try? data.listing(of: managed),
           let assembly = contents.file(named: "Assembly-CSharp.dll") {
            return "\(dataDir.name)/\(managed.name)/\(assembly.name)"
        }
        return data.file(named: "globalgamemanagers").map { "\(dataDir.name)/\($0.name)" }
    }

    /// The largest entry; ties go to the first in sorted order.
    private static func largest(_ entries: [FolderListing.Entry]) -> FolderListing.Entry? {
        entries.reduce(nil) { best, entry in
            guard let best else { return entry }
            return entry.size > best.size ? entry : best
        }
    }
}

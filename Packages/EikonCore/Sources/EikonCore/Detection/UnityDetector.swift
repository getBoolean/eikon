import Foundation

enum UnityDetector {
    private static let dataMarkers = ["globalgamemanagers", "mainData", "data.unity3d"]

    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
        let hasPlayer = listing.file(named: "UnityPlayer.dll") != nil || listing.file(named: "UnityPlayer.so") != nil
        let dataDirs: [(entry: FolderListing.Entry, stem: String, listing: FolderListing)] = listing.entries.compactMap { entry in
            guard entry.kind == .directory, entry.key.hasSuffix("_data"),
                  let contents = try? listing.listing(of: entry) else { return nil }
            return (entry, String(entry.key.dropLast("_data".count)), contents)
        }
        let markedDirs = dataDirs.filter { dir in dataMarkers.contains { dir.listing.file(named: $0) != nil } }
        guard hasPlayer || !markedDirs.isEmpty else { return nil }

        var executables: [GamePlatform: String] = [:]
        var paired: (entry: FolderListing.Entry, stem: String, listing: FolderListing)?
        for dir in dataDirs {
            if let exe = listing.file(key: dir.stem + ".exe") {
                executables[.windows] = executables[.windows] ?? exe.name
                paired = paired ?? dir
            }
            if let elf = listing.file(key: dir.stem + ".x86_64"), BinaryInfo.hasELFMagic(reader, path: elf.name) {
                executables[.linux] = executables[.linux] ?? elf.name
                paired = paired ?? dir
            }
        }
        let data = paired ?? markedDirs.first ?? dataDirs.first

        let details = EngineDetails(unityScripting: data.flatMap { scripting(listing, data: $0.listing) },
                                    unityVersion: data.flatMap { version(reader, dataDir: $0.entry.name, listing: $0.listing) })
        return EngineMatch(engine: .unity, details: details, executables: executables)
    }

    private static func scripting(_ listing: FolderListing, data: FolderListing) -> UnityScripting? {
        if listing.file(named: "GameAssembly.dll") != nil || listing.file(named: "GameAssembly.so") != nil
            || data.directory(named: "il2cpp_data") != nil {
            return .il2cpp
        }
        if let managed = data.directory(named: "Managed"), let contents = try? data.listing(of: managed),
           contents.file(named: "Assembly-CSharp.dll") != nil {
            return .mono
        }
        return nil
    }

    /// Best effort, from a SerializedFile header or the UnityFS bundle header.
    private static func version(_ reader: FolderReader, dataDir: String, listing: FolderListing) -> String? {
        for name in ["globalgamemanagers", "mainData"] {
            guard let file = listing.file(named: name),
                  let header = try? reader.read("\(dataDir)/\(file.name)", offset: 0, length: 0x70, for: .binaryHeaders),
                  let format = header.uint32BE(at: 0x08) else { continue }
            let offset: Int
            switch format {
            case 9...21: offset = 0x14
            case 22...: offset = 0x30
            default: continue
            }
            if let version = plausible(header.nulTerminatedString(at: offset, maxLength: 32)) { return version }
        }
        if let file = listing.file(named: "data.unity3d"),
           let header = try? reader.read("\(dataDir)/\(file.name)", offset: 0, length: 0x60, for: .binaryHeaders),
           header.hasBytes(Array("UnityFS\0".utf8)),
           let player = header.nulTerminatedString(at: 12, maxLength: 32) {
            return plausible(header.nulTerminatedString(at: 12 + player.utf8.count + 1, maxLength: 32))
        }
        return nil
    }

    /// Looks like "2019.4.1f1" or "5.6.0p3": digits and dots, then a release letter.
    private static func plausible(_ version: String?) -> String? {
        guard let version, let first = version.first, first.isNumber, version.contains("."),
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else { return nil }
        return version
    }
}

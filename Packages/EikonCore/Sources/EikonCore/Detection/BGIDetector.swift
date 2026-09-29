import Foundation

enum BGIDetector {
    private static let arcMagics = ["PackFile    ", "BURIKO ARC20"].map { Array($0.utf8) }

    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
        if listing.file(named: "BGI.exe") != nil { return EngineMatch(engine: .bgi, details: EngineDetails()) }
        var archives = 0
        for arc in listing.files(withExtension: "arc") {
            guard let header = try? reader.read(arc.name, offset: 0, length: 12, for: .binaryHeaders),
                  arcMagics.contains(where: { header.hasBytes($0) }) else { continue }
            archives += 1
            if archives >= 2 { return EngineMatch(engine: .bgi, details: EngineDetails()) }
        }
        return nil
    }
}

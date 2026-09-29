import Foundation

enum GameMakerDetector {
    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
        for name in ["data.win", "game.unx"] {
            guard let file = listing.file(named: name),
                  let header = try? reader.read(file.name, offset: 0, length: 12, for: .chunkHeaders),
                  header.hasBytes(Array("FORM".utf8)), header.hasBytes(Array("GEN8".utf8), at: 8) else { continue }
            return EngineMatch(engine: .gameMaker,
                               details: EngineDetails(gameMakerBuild: hasCode(reader, path: file.name) ? .vm : .yyc))
        }
        return nil
    }

    /// Walks the 8-byte chunk headers from offset 8. A present, non-empty CODE chunk means
    /// VM; stops at the end, at a size that overruns the file, or when the budget runs out.
    private static func hasCode(_ reader: FolderReader, path: String) -> Bool {
        guard let fileSize = reader.size(of: path) else { return false }
        var offset: UInt64 = 8
        while offset + 8 <= fileSize,
              let header = try? reader.read(path, offset: offset, length: 8, for: .chunkHeaders),
              let size = header.uint32LE(at: 4) {
            if header.hasBytes(Array("CODE".utf8)) { return size > 0 }
            offset += 8 + UInt64(size)
        }
        return false
    }
}

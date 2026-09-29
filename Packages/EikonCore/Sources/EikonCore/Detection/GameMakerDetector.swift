import Foundation

enum GameMakerDetector {
    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
        guard let file = dataFile(listing, reader) else { return nil }
        let hasCode = chunk("CODE", reader, path: file.name).map { $0.size > 0 } ?? false
        return EngineMatch(engine: .gameMaker, details: EngineDetails(gameMakerBuild: hasCode ? .vm : .yyc))
    }

    /// data.win or game.unx, when it starts with FORM and a GEN8 chunk.
    static func dataFile(_ listing: FolderListing, _ reader: FolderReader) -> FolderListing.Entry? {
        for name in ["data.win", "game.unx"] {
            guard let file = listing.file(named: name),
                  let header = try? reader.read(file.name, offset: 0, length: 12, for: .chunkHeaders),
                  header.hasBytes(Array("FORM".utf8)), header.hasBytes(Array("GEN8".utf8), at: 8) else { continue }
            return file
        }
        return nil
    }

    /// Walks the 8-byte chunk headers from offset 8 to the chunk with this tag: its content
    /// offset and size. Stops at the end, at a size that overruns the file, or when the budget runs out.
    static func chunk(_ tag: String, _ reader: FolderReader, path: String) -> (offset: UInt64, size: UInt32)? {
        guard let fileSize = reader.size(of: path) else { return nil }
        var offset: UInt64 = 8
        while offset + 8 <= fileSize,
              let header = try? reader.read(path, offset: offset, length: 8, for: .chunkHeaders),
              let size = header.uint32LE(at: 4) {
            if header.hasBytes(Array(tag.utf8)) { return (offset + 8, size) }
            offset += 8 + UInt64(size)
        }
        return nil
    }

    /// GEN8's Name and DisplayName strings. Both are STRG pointers: the absolute offset of
    /// the string bytes, which follow a 32-bit length.
    static func declaredNames(_ reader: FolderReader, path: String) -> [String] {
        guard let gen8 = chunk("GEN8", reader, path: path), gen8.size >= displayNameField + 4,
              let fields = try? reader.read(path, offset: gen8.offset, length: displayNameField + 4, for: .gen8Strings)
        else { return [] }
        return [nameField, displayNameField].compactMap { field in
            fields.uint32LE(at: field).flatMap { string(reader, path: path, at: UInt64($0)) }
        }
    }

    private static let nameField = 40
    private static let displayNameField = 100
    private static let maxStringLength: UInt32 = 1024

    private static func string(_ reader: FolderReader, path: String, at offset: UInt64) -> String? {
        guard offset >= 4, let length = (try? reader.read(path, offset: offset - 4, length: 4, for: .gen8Strings))?
                .uint32LE(at: 0), length > 0, length <= maxStringLength,
              let bytes = try? reader.read(path, offset: offset, length: Int(length), for: .gen8Strings),
              bytes.count == Int(length) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

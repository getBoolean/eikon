import Foundation

/// The `StringFileInfo` strings (ProductName, FileDescription, CompanyName, …) of a PE's
/// VS_VERSIONINFO resource. Reads at most the versionResource budget; anything malformed
/// gives an empty dictionary.
public enum PEVersionResource {
    public static func strings(ofFile url: URL) -> [String: String] {
        strings(FolderReader(root: url.deletingLastPathComponent()), path: url.lastPathComponent)
    }

    /// Parsed once per reader; later calls in the same pass reuse the result.
    static func strings(_ reader: FolderReader, path: String) -> [String: String] {
        if let cached = reader.versionStrings[path] { return cached }
        var result: [String: String] = [:]
        if let binary = reader.binary(path), binary.format == .pe,
           let rsrc = binary.sections.first(where: { $0.name == ".rsrc" }),
           let blob = try? versionInfo(reader, path: path, rsrc: rsrc) {
            result = stringTable(blob)
        }
        reader.versionStrings[path] = result
        return result
    }

    // MARK: Resource directory

    private static let rtVersion: UInt32 = 16

    private struct DirectoryEntry {
        let id: UInt32
        let isNamed: Bool
        let target: UInt32
        let isDirectory: Bool
    }

    private static func versionInfo(_ reader: FolderReader, path: String, rsrc: PESection) throws -> Data? {
        func read(_ offset: UInt32, _ length: Int) throws -> Data {
            guard UInt64(offset) + UInt64(length) <= UInt64(rsrc.rawSize) else { throw ReadFailure.unreadable }
            let data = try reader.read(path, offset: UInt64(rsrc.rawPointer) + UInt64(offset), length: length,
                                       for: .versionResource)
            guard data.count == length else { throw ReadFailure.unreadable }
            return data
        }
        func entries(_ offset: UInt32) throws -> [DirectoryEntry] {
            let header = try read(offset, 16)
            let count = Int(header.uint16LE(at: 12)!) + Int(header.uint16LE(at: 14)!)
            let table = try read(offset + 16, min(count, 256) * 8)
            return (0..<(table.count / 8)).map { index in
                let name = table.uint32LE(at: index * 8)!
                let target = table.uint32LE(at: index * 8 + 4)!
                return DirectoryEntry(id: name & 0x7FFF_FFFF, isNamed: name & 0x8000_0000 != 0,
                                      target: target & 0x7FFF_FFFF, isDirectory: target & 0x8000_0000 != 0)
            }
        }

        guard let type = try entries(0).first(where: { !$0.isNamed && $0.id == rtVersion && $0.isDirectory }),
              let name = try entries(type.target).first(where: \.isDirectory),
              let language = try entries(name.target).first(where: { !$0.isDirectory }) else { return nil }
        let dataEntry = try read(language.target, 16)
        let rva = dataEntry.uint32LE(at: 0)!
        let size = dataEntry.uint32LE(at: 4)!
        guard rva >= rsrc.virtualAddress, size > 0 else { return nil }
        return try read(rva - rsrc.virtualAddress, Int(size))
    }

    // MARK: VS_VERSIONINFO

    private struct Block {
        let key: String
        let valueStart: Int
        let valueLength: Int
        let end: Int
    }

    /// wLength, wValueLength, wType, then a NUL-terminated UTF-16LE key padded to 32 bits.
    private static func block(_ data: Data, at start: Int, limit: Int) -> Block? {
        guard start + 6 <= limit, let length = data.uint16LE(at: start),
              let valueLength = data.uint16LE(at: start + 2), length >= 6, start + Int(length) <= limit else { return nil }
        let end = start + Int(length)
        var units: [UInt16] = []
        var cursor = start + 6
        while cursor + 2 <= end, let unit = data.uint16LE(at: cursor) {
            cursor += 2
            if unit == 0 { break }
            units.append(unit)
        }
        return Block(key: String(decoding: units, as: UTF16.self), valueStart: align(cursor),
                     valueLength: Int(valueLength), end: end)
    }

    private static func children(_ data: Data, of parent: Block, valueBytes: Int) -> [Block] {
        var result: [Block] = []
        var cursor = align(parent.valueStart + valueBytes)
        while cursor < parent.end, let child = block(data, at: cursor, limit: parent.end) {
            result.append(child)
            cursor = align(child.end)
        }
        return result
    }

    private static func stringTable(_ data: Data) -> [String: String] {
        guard let root = block(data, at: 0, limit: data.count), root.key == "VS_VERSION_INFO",
              let fileInfo = children(data, of: root, valueBytes: root.valueLength)
                .first(where: { $0.key == "StringFileInfo" }),
              let table = children(data, of: fileInfo, valueBytes: 0).first else { return [:] }

        var strings: [String: String] = [:]
        for string in children(data, of: table, valueBytes: 0) {
            var units: [UInt16] = []
            var cursor = string.valueStart
            while cursor + 2 <= string.end, let unit = data.uint16LE(at: cursor), unit != 0 {
                units.append(unit)
                cursor += 2
            }
            strings[string.key] = String(decoding: units, as: UTF16.self)
        }
        return strings
    }

    private static func align(_ offset: Int) -> Int {
        (offset + 3) & ~3
    }
}

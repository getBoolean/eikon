import Foundation

enum KirikiriDetector {
    static let xp3Magic: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01]
    private static let protectedBit: UInt32 = 0x8000_0000
    private static let decodedIndexLimit = 64 << 20

    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
        let archives = listing.files(withExtension: "xp3").filter { entry in
            (try? reader.read(entry.name, offset: 0, length: xp3Magic.count, for: .xp3Index))?.hasBytes(xp3Magic) ?? false
        }
        guard !archives.isEmpty else { return nil }

        let largest = archives.min { lhs, rhs in lhs.size != rhs.size ? lhs.size > rhs.size : lhs.key < rhs.key }
        guard let main = archives.first(where: { $0.key == "data.xp3" }) ?? largest else { return nil }
        let index = readIndex(reader, path: main.name)
        let details = EngineDetails(kirikiriFlavor: .unknown,
                                    xp3ProtectedFlag: index.map(hasProtectedEntry),
                                    xp3IndexReadable: index != nil,
                                    pluginFileNames: plugins(listing))
        return EngineMatch(engine: .kirikiri, details: details)
    }

    // MARK: Flavor

    private static let markers: [(text: String, flavor: KirikiriFlavor)] = [
        ("TVP(KIRIKIRI) Z", .krkrZ), ("TVP(KIRIKIRI) 2", .krkr2),
    ]

    /// From the exe's version resource, else a bounded string scan of its string data:
    /// .rdata, then .data, then .rsrc (or the file start when it has no such sections),
    /// within what is left of the versionResource budget.
    static func flavor(_ reader: FolderReader, executable path: String) -> KirikiriFlavor {
        let strings = PEVersionResource.strings(reader, path: path)
        for key in ["ProductName", "FileDescription"] {
            if let value = strings[key]?.uppercased(), let marker = markers.first(where: { value.contains($0.text) }) {
                return marker.flavor
            }
        }
        let sections = reader.binary(path)?.sections ?? []
        var ranges = [".rdata", ".data", ".rsrc"].compactMap { name in
            sections.first { $0.name == name && $0.rawSize > 0 }.map { (UInt64($0.rawPointer), Int($0.rawSize)) }
        }
        if ranges.isEmpty { ranges = [(0, Int.max)] }
        for (offset, size) in ranges {
            let length = min(size, reader.remainingBudget(path, for: .versionResource))
            guard length > 0, let bytes = try? reader.read(path, offset: offset, length: length, for: .versionResource)
            else { break }
            for marker in markers {
                let ascii = Array(marker.text.utf8)
                let utf16 = ascii.flatMap { byte -> [UInt8] in [byte, 0] }
                if bytes.range(of: Data(ascii)) != nil || bytes.range(of: Data(utf16)) != nil { return marker.flavor }
            }
        }
        return .unknown
    }

    // MARK: Plugins

    /// .tpm base names in the root and one level of subfolders, plus plugin/*.dll.
    /// One name per normalized key, the first met; sorted by key.
    private static func plugins(_ listing: FolderListing) -> [String] {
        var byKey: [String: String] = [:]
        func add(_ entries: [FolderListing.Entry]) {
            for entry in entries where byKey[entry.key] == nil { byKey[entry.key] = entry.name }
        }
        add(listing.files(withExtension: "tpm"))
        for dir in listing.entries where dir.kind == .directory {
            guard let contents = try? listing.listing(of: dir) else { continue }
            add(contents.files(withExtension: "tpm"))
            if dir.key == "plugin" { add(contents.files(withExtension: "dll")) }
        }
        return byKey.keys.sorted().map { byKey[$0]! }
    }

    // MARK: Index

    /// The decoded index, following one continuation header. nil when it can't be decoded
    /// and walked within the budget.
    private static func readIndex(_ reader: FolderReader, path: String) -> Data? {
        guard let start = try? reader.read(path, offset: 11, length: 8, for: .xp3Index),
              var offset = start.uint64LE(at: 0) else { return nil }
        for _ in 0..<2 {
            guard let header = try? reader.read(path, offset: offset, length: 17, for: .xp3Index),
                  let flag = header.uint8(at: 0) else { return nil }
            let index: Data
            let end: UInt64
            switch flag & 0x07 {
            case 0:
                guard let size = header.uint64LE(at: 1), size <= UInt64(ReadPurpose.xp3Index.budget) else { return nil }
                index = (try? reader.read(path, offset: offset + 9, length: Int(size), for: .xp3Index)) ?? Data()
                guard index.count == Int(size) else { return nil }
                end = offset + 9 + size
            case 1:
                guard let packed = header.uint64LE(at: 1), let unpacked = header.uint64LE(at: 9),
                      packed <= UInt64(ReadPurpose.xp3Index.budget), unpacked <= UInt64(decodedIndexLimit),
                      unpacked <= packed * 1032, // zlib's maximum ratio: no allocation from a bare header
                      let compressed = try? reader.read(path, offset: offset + 17, length: Int(packed), for: .xp3Index),
                      compressed.count == Int(packed),
                      let inflated = FolderReader.inflateZlib(compressed, expectedSize: Int(unpacked), limit: decodedIndexLimit)
                else { return nil }
                index = inflated
                end = offset + 17 + packed
            default:
                return nil
            }
            guard flag & 0x80 != 0 else { return walk(index) ? index : nil }
            guard let next = try? reader.read(path, offset: end, length: 8, for: .xp3Index),
                  let nextOffset = next.uint64LE(at: 0) else { return nil }
            offset = nextOffset
        }
        return nil
    }

    /// Chunks of a 4-byte tag and a UInt64 size that exactly tile `data`, visiting each.
    @discardableResult
    private static func walk(_ data: Data, _ visit: (String, Data) -> Void = { _, _ in }) -> Bool {
        var cursor = 0
        while cursor < data.count {
            guard let size = data.uint64LE(at: cursor + 4), size <= UInt64(data.count - cursor - 12) else { return false }
            let tag = String(decoding: data[(data.startIndex + cursor)..<(data.startIndex + cursor + 4)], as: UTF8.self)
            let bodyStart = data.startIndex + cursor + 12
            visit(tag, data[bodyStart..<(bodyStart + Int(size))])
            cursor += 12 + Int(size)
        }
        return true
    }

    private static func hasProtectedEntry(_ index: Data) -> Bool {
        var found = false
        walk(index) { tag, body in
            guard tag == "File" else { return }
            walk(Data(body)) { tag, body in
                if tag == "info", let flags = Data(body).uint32LE(at: 0), flags & protectedBit != 0 { found = true }
            }
        }
        return found
    }
}

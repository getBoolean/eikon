import CEikonSession
import Foundation

/// Synthesizes tiny, original fake game folders in temp directories. Byte builders make
/// headers only, plus a few padding bytes; layout builders compose them into folders.
enum Fixtures {
    static let peI386: UInt16 = 0x014C
    static let peAMD64: UInt16 = 0x8664
    static let elfAMD64: UInt16 = 62
    static let elfAArch64: UInt16 = 183

    // MARK: Files

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eikon-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `data` at `rel` under `dir`, creating intermediate folders.
    static func write(_ data: Data, to rel: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func write(_ text: String, to rel: String, in dir: URL) throws {
        try write(Data(text.utf8), to: rel, in: dir)
    }

    static func mkdir(_ rel: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(rel, isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    // MARK: Byte builders

    /// A PE with the given COFF machine, subsystem and DLL flag. With `versionStrings`, it
    /// carries a .rsrc section holding a VS_VERSIONINFO with those StringFileInfo values.
    static func pe(machine: UInt16, gui: Bool = true, dll: Bool = false, lfanew: Int = 0x80,
                   versionStrings: [String: String] = [:], padTo size: Int? = nil) -> Data {
        let optionalSize = 240
        let sectionCount = versionStrings.isEmpty ? 0 : 1
        var data = Data(count: lfanew)
        data[0] = 0x4D
        data[1] = 0x5A
        data.put32(UInt32(lfanew), at: 0x3C)

        data.append(contentsOf: [0x50, 0x45, 0, 0])
        data.append16(machine)
        data.append16(UInt16(sectionCount))
        data.append(Data(count: 12)) // timestamp, symbol table, symbol count
        data.append16(UInt16(optionalSize))
        data.append16(0x0002 | (dll ? 0x2000 : 0))

        var optional = Data(count: optionalSize)
        optional.put16(0x020B, at: 0) // PE32+
        optional.put16(gui ? 2 : 3, at: 68)
        data.append(optional)

        if !versionStrings.isEmpty {
            let headerEnd = data.count + 40
            let rawPointer = (headerEnd + 0x1FF) & ~0x1FF
            let virtualAddress: UInt32 = 0x1000
            let rsrc = resourceSection(virtualAddress: virtualAddress, strings: versionStrings)
            var header = Data(".rsrc".utf8) + Data(count: 3)
            header.append32(UInt32(rsrc.count))
            header.append32(virtualAddress)
            header.append32(UInt32(rsrc.count))
            header.append32(UInt32(rawPointer))
            header.append(Data(count: 16))
            data.append(header)
            data.append(Data(count: rawPointer - data.count))
            data.append(rsrc)
        }
        if let size, size > data.count { data.append(Data(count: size - data.count)) }
        return data
    }

    static func elf(machine: UInt16) -> Data {
        var data = Data(count: 64)
        data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
        data[4] = 2 // 64-bit
        data[5] = 1 // little-endian
        data[6] = 1
        data.put16(2, at: 0x10) // ET_EXEC
        data.put16(machine, at: 0x12)
        return data
    }

    enum XP3Index { case raw, zlib, garbage }

    /// An XP3 archive with one file entry. `continuation` adds the Kirikiri 2.3+ header
    /// whose flag byte 0x80 points on to the real index.
    static func xp3(index: XP3Index, protectedEntry: Bool = false, continuation: Bool = false) -> Data {
        let magic: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01]
        var data = Data(magic)
        let offsetField = data.count
        data.append64(0)

        if continuation {
            data.put64(UInt64(data.count + 4), at: offsetField) // 0x17
            data.append32(1)
            data.append(0x80) // raw, continue
            data.append64(0)  // empty index
            let next = data.count
            data.append64(0)
            data.append(Data("sample body".utf8))
            data.put64(UInt64(data.count), at: next)
        } else {
            data.append(Data("sample body".utf8))
            data.put64(UInt64(data.count), at: offsetField)
        }

        let entries = xp3Entries(protectedEntry: protectedEntry)
        switch index {
        case .raw:
            data.append(0)
            data.append64(UInt64(entries.count))
            data.append(entries)
        case .zlib:
            let packed = zlibCompress(entries)
            data.append(1)
            data.append64(UInt64(packed.count))
            data.append64(UInt64(entries.count))
            data.append(packed)
        case .garbage:
            let junk = Data((0..<24).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            data.append(1)
            data.append64(UInt64(junk.count))
            data.append64(64)
            data.append(junk)
        }
        return data
    }

    /// FORM, then GEN8 (or another first chunk), an optional CODE chunk and a STRG chunk.
    /// With `names`, GEN8 points its Name and DisplayName at those strings in STRG.
    static func gameMaker(hasGEN8: Bool = true, hasCode: Bool, names: (name: String, displayName: String)? = nil) -> Data {
        let gen8Size = names == nil ? 16 : 128
        let strgStart = 8 + (8 + gen8Size) + (hasCode ? 16 : 0) + 8
        var strings = Data()
        var gen8 = Data(count: gen8Size)
        if let names {
            for (field, text) in [(40, names.name), (100, names.displayName)] {
                let bytes = Data(text.utf8)
                strings.append32(UInt32(bytes.count))
                gen8.put32(UInt32(strgStart + strings.count), at: field)
                strings.append(bytes)
                strings.append(0)
            }
        }
        var chunks = Data()
        func chunk(_ tag: String, _ content: Data) {
            chunks.append(Data(tag.utf8))
            chunks.append32(UInt32(content.count))
            chunks.append(content)
        }
        chunk(hasGEN8 ? "GEN8" : "OPTN", gen8)
        if hasCode { chunk("CODE", Data(count: 8)) }
        chunk("STRG", strings.isEmpty ? Data(count: 4) : strings)
        var data = Data("FORM".utf8)
        data.append32(UInt32(chunks.count))
        return data + chunks
    }

    /// "PackFile    ", "BURIKO ARC20", or anything else.
    static func bgiArc(magic: String) -> Data {
        Data(magic.utf8) + Data(count: 8)
    }

    // MARK: Layout builders (each builds `name` under `dir` and returns its URL)

    enum RenPyEra { case scriptVersion, vcVersion, initPy, libEra }

    /// A Ren'Py game whose stem is "Game". Exact eras record `version`. With
    /// `saveDirectory`, game/options.rpy sets `config.save_directory` to it.
    static func renpy(_ era: RenPyEra, version: [Int] = [7, 4, 11], saveDirectory: String? = nil,
                      named name: String = "Sample", in dir: URL) throws -> URL {
        let root = dir.appendingPathComponent(name, isDirectory: true)
        let text = version.map(String.init)
        try write(pe(machine: peAMD64), to: "Game.exe", in: root)
        try write("# launcher\n", to: "Game.py", in: root)
        try write("#!/bin/sh\nexec lib/game\n", to: "Game.sh", in: root)
        try write(Data([0x52, 0x50, 0x43, 0x32]), to: "game/script.rpyc", in: root)
        try write("# engine\n", to: "renpy/__init__.py", in: root)
        if let saveDirectory {
            try write("## Options\ndefine config.name = _(\"Sample\")\ndefine config.save_directory = \"\(saveDirectory)\"\n",
                      to: "game/options.rpy", in: root)
        }

        let linuxDir: String
        switch era {
        case .scriptVersion:
            try write("(\(text.joined(separator: ", ")))", to: "game/script_version.txt", in: root)
            linuxDir = "lib/py2-linux-x86_64"
        case .vcVersion:
            try write("version = \"\(text.joined(separator: ".")).24010101\"\n", to: "renpy/vc_version.py", in: root)
            linuxDir = "lib/py3-linux-x86_64"
            try mkdir("lib/python3.9", in: root)
        case .initPy:
            try write("vc_version = 0\nversion_tuple = (\(text.joined(separator: ", ")), vc_version)\n",
                      to: "renpy/__init__.py", in: root)
            linuxDir = "lib/linux-x86_64"
            try mkdir("lib/pythonlib2.7", in: root)
        case .libEra:
            linuxDir = "lib/py3-linux-x86_64"
            try mkdir("lib/python3.12", in: root)
        }
        try write(elf(machine: elfAMD64), to: "\(linuxDir)/Game", in: root)
        try write("#!/bin/sh\n", to: "\(linuxDir)/Game.sh", in: root)
        return root
    }

    enum UnityLayout { case mono, il2cpp, pre2017 }

    /// A Unity game whose stem is "Game", with a larger GUI crash handler beside it. With
    /// `appInfo`, Game_Data/app.info holds that company and product.
    static func unity(_ layout: UnityLayout, linux: Bool = false, appInfo: (company: String, product: String)? = nil,
                      named name: String = "Sample", in dir: URL) throws -> URL {
        let root = dir.appendingPathComponent(name, isDirectory: true)
        try write(pe(machine: peAMD64), to: "Game.exe", in: root)
        try write(pe(machine: peAMD64, padTo: 64 << 10), to: "UnityCrashHandler64.exe", in: root)
        switch layout {
        case .mono:
            try write(pe(machine: peAMD64, dll: true), to: "UnityPlayer.dll", in: root)
            try write(Data(count: 64), to: "Game_Data/globalgamemanagers", in: root)
            try write(pe(machine: peI386, dll: true), to: "Game_Data/Managed/Assembly-CSharp.dll", in: root)
        case .il2cpp:
            try write(pe(machine: peAMD64, dll: true), to: "UnityPlayer.dll", in: root)
            try write(pe(machine: peAMD64, dll: true), to: "GameAssembly.dll", in: root)
            try write(Data(count: 64), to: "Game_Data/globalgamemanagers", in: root)
            try write(Data(count: 16), to: "Game_Data/il2cpp_data/Metadata/global-metadata.dat", in: root)
        case .pre2017:
            try write(Data(count: 64), to: "Game_Data/mainData", in: root)
            try write(pe(machine: peI386, dll: true), to: "Game_Data/Managed/Assembly-CSharp.dll", in: root)
        }
        if let appInfo {
            try write("\(appInfo.company)\n\(appInfo.product)", to: "Game_Data/app.info", in: root)
        }
        if linux {
            try write(elf(machine: elfAMD64), to: "Game.x86_64", in: root)
            try write(elf(machine: elfAMD64), to: "UnityPlayer.so", in: root)
        }
        return root
    }

    /// A Kirikiri game: Game.exe (with ProductName `flavor`, if any), data.xp3 and plugins.
    static func kirikiri(flavor: String?, tpm: [String] = [], index: XP3Index = .raw,
                         protectedEntry: Bool = false, continuation: Bool = false,
                         named name: String = "Sample", in dir: URL) throws -> URL {
        let root = dir.appendingPathComponent(name, isDirectory: true)
        let strings = flavor.map { ["ProductName": $0, "FileDescription": $0] } ?? [:]
        try write(pe(machine: peI386, versionStrings: strings), to: "Game.exe", in: root)
        try write(xp3(index: index, protectedEntry: protectedEntry, continuation: continuation),
                  to: "data.xp3", in: root)
        for plugin in tpm {
            try write(Data(count: 8), to: plugin, in: root)
        }
        return root
    }

    // MARK: Internals

    private static func xp3Entries(protectedEntry: Bool) -> Data {
        let name = Array("sample.txt".utf16)
        var info = Data()
        info.append32(protectedEntry ? 0x8000_0000 : 0)
        info.append64(11)
        info.append64(11)
        info.append16(UInt16(name.count))
        for unit in name { info.append16(unit) }

        var segment = Data()
        segment.append32(0)
        segment.append64(0x13)
        segment.append64(11)
        segment.append64(11)

        var body = Data()
        for (tag, payload) in [("info", info), ("segm", segment), ("adlr", Data(count: 4))] {
            body.append(Data(tag.utf8))
            body.append64(UInt64(payload.count))
            body.append(payload)
        }
        var file = Data("File".utf8)
        file.append64(UInt64(body.count))
        return file + body
    }

    private static func zlibCompress(_ data: Data) -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compress(out.bindMemory(to: Bytef.self).baseAddress, &length,
                         input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
            }
        }
        precondition(status == Z_OK)
        return output.prefix(Int(length))
    }

    /// Resource directory (RT_VERSION → one name → one language) and the VS_VERSIONINFO.
    private static func resourceSection(virtualAddress: UInt32, strings: [String: String]) -> Data {
        let info = versionInfo(strings)
        var data = Data()
        func directory(entryID: UInt32, target: UInt32) {
            data.append(Data(count: 12))
            data.append16(0)
            data.append16(1)
            data.append32(entryID)
            data.append32(target)
        }
        directory(entryID: 16, target: 0x8000_0000 | 0x18)
        directory(entryID: 1, target: 0x8000_0000 | 0x30)
        directory(entryID: 0x409, target: 0x48)
        data.append32(virtualAddress + 0x58)
        data.append32(UInt32(info.count))
        data.append(Data(count: 8))
        return data + info
    }

    private static func versionInfo(_ strings: [String: String]) -> Data {
        let children = strings.keys.sorted().map { key -> Data in
            let value = Array(strings[key]!.utf16) + [0]
            return block(key: key, value: Data(value.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
                         valueLength: value.count, type: 1)
        }
        let table = block(key: "040904B0", value: Data(), valueLength: 0, type: 1, children: children)
        let fileInfo = block(key: "StringFileInfo", value: Data(), valueLength: 0, type: 1, children: [table])
        var fixed = Data(count: 52)
        fixed.put32(0xFEEF_04BD, at: 0)
        return block(key: "VS_VERSION_INFO", value: fixed, valueLength: 52, type: 0, children: [fileInfo])
    }

    private static func block(key: String, value: Data, valueLength: Int, type: UInt16, children: [Data] = []) -> Data {
        var data = Data(count: 6)
        for unit in Array(key.utf16) + [0] { data.append16(unit) }
        data.padTo4()
        data.append(value)
        for child in children {
            data.padTo4()
            data.append(child)
        }
        data.put16(UInt16(data.count), at: 0)
        data.put16(UInt16(valueLength), at: 2)
        data.put16(type, at: 4)
        return data
    }
}

extension Data {
    mutating func append16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func append32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func append64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func put16(_ value: UInt16, at offset: Int) { replaceSubrange(offset..<offset + 2, with: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func put32(_ value: UInt32, at offset: Int) { for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) } }
    mutating func put64(_ value: UInt64, at offset: Int) { for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) } }
    mutating func padTo4() { while count % 4 != 0 { append(0) } }
}

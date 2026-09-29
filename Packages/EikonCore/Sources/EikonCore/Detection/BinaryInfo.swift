import Foundation

public enum BinaryFormat: String, Codable, Sendable, CaseIterable {
    case pe, elf
}

public enum CPUArchitecture: String, Codable, Sendable, CaseIterable {
    /// `arm64` covers ARM64, ARM64EC and ARM64X.
    case i386, amd64, arm64, other

    /// A value from another build decodes as `.other`.
    public init(from decoder: any Decoder) throws {
        self = CPUArchitecture(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }

    static func pe(machine: UInt16) -> CPUArchitecture {
        switch machine {
        case 0x014C: .i386
        case 0x8664: .amd64
        case 0xAA64, 0xA641, 0xA64E: .arm64
        default: .other
        }
    }

    static func elf(machine: UInt16) -> CPUArchitecture {
        switch machine {
        case 3: .i386
        case 62: .amd64
        case 183: .arm64
        default: .other
        }
    }
}

struct PESection: Sendable {
    let name: String
    let virtualAddress: UInt32
    let rawSize: UInt32
    let rawPointer: UInt32
}

struct ParsedBinary: Sendable {
    let format: BinaryFormat
    let architecture: CPUArchitecture
    let machine: UInt16
    /// PE subsystem is Windows GUI; nil for ELF.
    let isGUI: Bool?
    /// PE with the DLL characteristic: never an executable.
    let isDLL: Bool
    /// PE only.
    let sections: [PESection]
}

/// PE and ELF header parsing, within the binaryHeaders budget.
enum BinaryInfo {
    static let elfMagic: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]

    static func parse(_ reader: FolderReader, path: String) -> ParsedBinary? {
        guard let start = try? reader.read(path, offset: 0, length: 64, for: .binaryHeaders) else { return nil }
        if start.hasBytes([0x4D, 0x5A]) { return try? parsePE(reader, path: path, dosHeader: start) }
        if start.hasBytes(elfMagic) { return parseELF(start) }
        return nil
    }

    static func hasELFMagic(_ reader: FolderReader, path: String) -> Bool {
        (try? reader.read(path, offset: 0, length: 4, for: .binaryHeaders))?.hasBytes(elfMagic) ?? false
    }

    private static func parsePE(_ reader: FolderReader, path: String, dosHeader: Data) throws -> ParsedBinary? {
        guard let fileSize = reader.size(of: path), let lfanew = dosHeader.uint32LE(at: 0x3C),
              lfanew % 4 == 0, lfanew < 64 << 10, UInt64(lfanew) < fileSize else { return nil }

        let coff = try reader.read(path, offset: UInt64(lfanew), length: 24, for: .binaryHeaders)
        guard coff.hasBytes([0x50, 0x45, 0, 0]), let machine = coff.uint16LE(at: 4),
              let sectionCount = coff.uint16LE(at: 6), let optionalSize = coff.uint16LE(at: 20),
              let characteristics = coff.uint16LE(at: 22) else { return nil }

        let optionalOffset = UInt64(lfanew) + 24
        let optional = try reader.read(path, offset: optionalOffset, length: Int(min(optionalSize, 4096)),
                                       for: .binaryHeaders)
        let isGUI = optional.uint16LE(at: 68) == 2

        let count = Int(min(sectionCount, 96))
        let table = try reader.read(path, offset: optionalOffset + UInt64(optionalSize), length: count * 40,
                                    for: .binaryHeaders)
        var sections: [PESection] = []
        for index in 0..<(table.count / 40) {
            let base = index * 40
            let nameBytes = table[(table.startIndex + base)..<(table.startIndex + base + 8)].prefix { $0 != 0 }
            sections.append(PESection(name: String(decoding: nameBytes, as: UTF8.self),
                                      virtualAddress: table.uint32LE(at: base + 12) ?? 0,
                                      rawSize: table.uint32LE(at: base + 16) ?? 0,
                                      rawPointer: table.uint32LE(at: base + 20) ?? 0))
        }

        return ParsedBinary(format: .pe, architecture: .pe(machine: machine), machine: machine, isGUI: isGUI,
                            isDLL: characteristics & 0x2000 != 0, sections: sections)
    }

    private static func parseELF(_ header: Data) -> ParsedBinary? {
        // EI_DATA: 1 little-endian, 2 big-endian.
        let machine: UInt16?
        switch header.uint8(at: 5) {
        case 1: machine = header.uint16LE(at: 0x12)
        case 2: machine = header.uint16BE(at: 0x12)
        default: machine = nil
        }
        guard let machine else { return nil }
        return ParsedBinary(format: .elf, architecture: .elf(machine: machine), machine: machine, isGUI: nil,
                            isDLL: false, sections: [])
    }
}

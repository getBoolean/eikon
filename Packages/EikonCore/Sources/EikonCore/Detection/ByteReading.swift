import Foundation

/// Bounds-checked fixed-width reads. Offsets are relative to the data's start index.
extension Data {
    func uint8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    func uint16LE(at offset: Int) -> UInt16? { littleEndian(at: offset, bytes: 2).map { UInt16($0) } }
    func uint32LE(at offset: Int) -> UInt32? { littleEndian(at: offset, bytes: 4).map { UInt32($0) } }
    func uint64LE(at offset: Int) -> UInt64? { littleEndian(at: offset, bytes: 8) }

    func uint16BE(at offset: Int) -> UInt16? { bigEndian(at: offset, bytes: 2).map { UInt16($0) } }
    func uint32BE(at offset: Int) -> UInt32? { bigEndian(at: offset, bytes: 4).map { UInt32($0) } }

    /// The bytes at `offset` equal `prefix`.
    func hasBytes(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
        guard offset >= 0, offset + prefix.count <= count else { return false }
        return self[(startIndex + offset)..<(startIndex + offset + prefix.count)].elementsEqual(prefix)
    }

    /// The ASCII/UTF-8 string from `offset` up to a NUL (or `maxLength` bytes), if it ends in range.
    func nulTerminatedString(at offset: Int, maxLength: Int = 256) -> String? {
        guard offset >= 0, offset < count else { return nil }
        let end = Swift.min(count, offset + maxLength)
        let bytes = self[(startIndex + offset)..<(startIndex + end)]
        guard let nul = bytes.firstIndex(of: 0) else { return nil }
        return String(decoding: self[(startIndex + offset)..<nul], as: UTF8.self)
    }

    private func littleEndian(at offset: Int, bytes: Int) -> UInt64? {
        guard offset >= 0, offset + bytes <= count else { return nil }
        var value: UInt64 = 0
        for index in (0..<bytes).reversed() {
            value = value << 8 | UInt64(self[startIndex + offset + index])
        }
        return value
    }

    private func bigEndian(at offset: Int, bytes: Int) -> UInt64? {
        guard offset >= 0, offset + bytes <= count else { return nil }
        var value: UInt64 = 0
        for index in 0..<bytes {
            value = value << 8 | UInt64(self[startIndex + offset + index])
        }
        return value
    }
}

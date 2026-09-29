import CEikonSession
import Darwin
import Foundation

enum ReadPurpose: Sendable, Hashable {
    case binaryHeaders, versionResource, xp3Index, chunkHeaders, smallText

    /// Bytes allowed per file, per call and in total.
    var budget: Int {
        switch self {
        case .binaryHeaders: 64 << 10
        case .versionResource: 256 << 10
        case .xp3Index: (8 << 20) + (4 << 10) // the compressed index plus its small headers
        case .chunkHeaders: 8 * 512
        case .smallText: 64 << 10
        }
    }
}

/// Why a probe stopped. Callers treat every case as "no match".
enum ReadFailure: Error {
    case unreadable, budgetExceeded
}

/// Read-only, budgeted reads under one root. Opens files read-only without following a
/// final symlink, reads bounded ranges and closes at once. Never writes or sets attributes.
/// Tracks budgets, so one reader serves one detection pass on one thread.
final class FolderReader {
    let root: URL
    private var used: [Budget: Int] = [:]
    private var binaries: [String: ParsedBinary?] = [:]
    /// PEVersionResource's per-path results, so later probes in the same pass reuse them.
    var versionStrings: [String: [String: String]] = [:]

    private struct Budget: Hashable {
        let path: String
        let purpose: ReadPurpose
    }

    init(root: URL) {
        self.root = root
    }

    /// Up to `length` bytes at `offset`; fewer at the end of the file.
    func read(_ relativePath: String, offset: UInt64, length: Int, for purpose: ReadPurpose) throws -> Data {
        guard length >= 0, offset <= UInt64(Int64.max) else { throw ReadFailure.unreadable }
        let key = Budget(path: relativePath, purpose: purpose)
        let total = used[key, default: 0] + length
        guard total <= purpose.budget else { throw ReadFailure.budgetExceeded }

        let fd = url(relativePath).path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw ReadFailure.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ReadFailure.unreadable }

        var data = Data(count: length)
        var filled = 0
        while filled < length {
            let got = data.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + filled, length - filled, off_t(offset) + off_t(filled))
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw ReadFailure.unreadable
            }
            if got == 0 { break }
            filled += got
        }
        data.count = filled
        used[key, default: 0] += filled
        return data
    }

    /// The file's PE or ELF headers, parsed once per reader.
    func binary(_ relativePath: String) -> ParsedBinary? {
        if let cached = binaries[relativePath] { return cached }
        let parsed = BinaryInfo.parse(self, path: relativePath)
        binaries[relativePath] = .some(parsed)
        return parsed
    }

    /// What is left of the budget for this file and purpose.
    func remainingBudget(_ relativePath: String, for purpose: ReadPurpose) -> Int {
        purpose.budget - used[Budget(path: relativePath, purpose: purpose), default: 0]
    }

    /// The size of a regular file (not a symlink), or nil.
    func size(of relativePath: String) -> UInt64? {
        var info = stat()
        guard lstat(url(relativePath).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(info.st_size)
    }

    /// A small text file, or the smallText budget's worth of a larger one, as UTF-8 or else Latin-1.
    func text(_ relativePath: String) -> String? {
        guard let size = size(of: relativePath),
              let data = try? read(relativePath, offset: 0, length: Int(min(size, UInt64(ReadPurpose.smallText.budget))),
                                   for: .smallText) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// zlib-wrapped data through system libz, capped at `limit` output bytes. nil on any
    /// decode failure, a size mismatch, or output over the limit.
    static func inflateZlib(_ data: Data, expectedSize: Int?, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        if let expectedSize, expectedSize > 0 {
            guard expectedSize <= limit else { return nil }
            var output = Data(count: expectedSize)
            var outputLength = uLongf(expectedSize)
            let status = output.withUnsafeMutableBytes { out in
                data.withUnsafeBytes { input in
                    uncompress(out.bindMemory(to: Bytef.self).baseAddress, &outputLength,
                               input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
                }
            }
            guard status == Z_OK, outputLength == uLongf(expectedSize) else { return nil }
            return output
        }
        return streamInflate(data, limit: limit)
    }

    private static func streamInflate(_ data: Data, limit: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let chunk = 64 << 10
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        return data.withUnsafeBytes { input -> Data? in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                output.append(contentsOf: buffer[..<produced])
                if output.count > limit { return nil }
                if status == Z_STREAM_END { return output }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { return nil }
            }
        }
    }
}

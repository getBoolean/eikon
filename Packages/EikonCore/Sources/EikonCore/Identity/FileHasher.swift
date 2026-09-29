import CryptoKit
import Darwin
import Foundation

/// Streaming, read-only full-file SHA-256: the fingerprint's exact signal and the
/// diagnostics ("Verify files", the scanner's --hash).
public enum FileHasher {
    public static let chunkSize = 1 << 20

    /// Lowercase hex. Streams read-only in `chunkSize` chunks, reporting non-decreasing
    /// progress in 0...1; throws `CancellationError` once `isCancelled` is true between chunks.
    public static func sha256(of url: URL, progress: (Double) -> Void, isCancelled: () -> Bool) throws -> String {
        var total: UInt64 = 0, done: UInt64 = 0
        progress(0)
        let digest = try digest(of: url, isCancelled: isCancelled) { size in
            total = size
        } read: { count in
            done += UInt64(count)
            progress(total == 0 ? 1 : min(1, Double(done) / Double(total)))
        }
        progress(1)
        return Data(digest).lowercaseHex
    }

    /// The digest of a regular file, never through a final symlink. `opened` gets the
    /// file's size before any read, `read` each chunk's byte count.
    static func digest(of url: URL, isCancelled: () -> Bool, opened: (UInt64) -> Void = { _ in },
                       read readChunk: (Int) -> Void) throws -> SHA256.Digest {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw IdentityError.fileUnreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw IdentityError.fileUnreadable }
        opened(UInt64(info.st_size))

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            if isCancelled() { throw CancellationError() }
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, chunkSize) }
            if got < 0 {
                if errno == EINTR { continue }
                throw IdentityError.fileUnreadable
            }
            if got == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<got])) }
            readChunk(got)
        }
        return hasher.finalize()
    }
}

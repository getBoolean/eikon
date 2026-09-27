import Darwin
import Foundation

/// Makes a probe that killed the process get skipped on exactly one following launch of the same build.
public struct ProbeSentinel: Sendable {
    private let directory: URL
    private let buildNumber: String

    public init(directory: URL, buildNumber: String) {
        self.directory = directory
        self.buildNumber = buildNumber
    }

    /// Live location: Library/Caches.
    public static func live(buildNumber: String) -> ProbeSentinel {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ProbeSentinel(directory: caches, buildNumber: buildNumber)
    }

    /// Before the probe: create the sentinel and wait until the build number is on disk.
    /// If this throws, the caller must not probe.
    public func arm() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = sentinelURL.path.withCString { path in
            open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        }
        guard fd >= 0 else { throw posixError(errno) }
        defer { close(fd) }

        var remaining = Array(buildNumber.utf8)[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            if written == 0 { throw POSIXError(.EIO) }
            remaining = remaining.dropFirst(written)
        }
        guard fsync(fd) == 0 else { throw posixError(errno) }
        syncDirectory()
    }

    /// After the probe returns: delete the sentinel.
    public func disarm() {
        removeSentinel()
    }

    /// True when a sentinel holding this build number exists. Always deletes any sentinel,
    /// so exactly one launch is skipped and a sentinel from another build is dropped.
    public func consumeAtLaunch() -> Bool {
        let recorded = try? String(contentsOf: sentinelURL, encoding: .utf8)
        removeSentinel()
        return recorded == buildNumber
    }

    private var sentinelURL: URL {
        directory.appendingPathComponent("eikon-probe-sentinel")
    }

    /// Also flush the directory entry, so a new sentinel survives power loss.
    /// Best effort: process death alone never loses the file.
    private func syncDirectory() {
        let dirFD = directory.path.withCString { open($0, O_RDONLY) }
        guard dirFD >= 0 else { return }
        _ = fsync(dirFD)
        close(dirFD)
    }

    private func removeSentinel() {
        sentinelURL.path.withCString { _ = unlink($0) }
    }
}

private func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

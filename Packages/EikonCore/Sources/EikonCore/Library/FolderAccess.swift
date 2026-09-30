import Foundation

public enum AccessOutcome: Sendable {
    /// Open until the token closes. `refreshedBookmark`: the bookmark was stale but
    /// resolved, and this replaces it.
    case opened(AccessToken, refreshedBookmark: Data?)
    /// The volume is absent.
    case notConnected
    /// The bookmark can't be resolved any more.
    case stale
}

/// Reaches folders outside the container through security-scoped bookmarks.
public protocol FolderAccess: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func open(bookmark: Data) throws -> AccessOutcome
    func volumeKind(of url: URL) -> VolumeKind
}

/// Access to one folder, held until `close()`. Closing is idempotent; deinit closes as a
/// backstop.
public final class AccessToken: @unchecked Sendable {
    public let url: URL
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false

    public init(url: URL, onClose: @escaping @Sendable () -> Void) {
        self.url = url
        self.onClose = onClose
    }

    deinit {
        close()
    }

    public func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        if first { onClose() }
    }
}

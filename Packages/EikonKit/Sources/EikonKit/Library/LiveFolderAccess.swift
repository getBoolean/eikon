import EikonCore
import Foundation

/// Security-scoped bookmarks for picked folders.
public struct LiveFolderAccess: FolderAccess {
    public static let live = LiveFolderAccess()

    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData()
    }

    public func open(bookmark: Data) throws -> AccessOutcome {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return .notConnected
        } catch {
            return .stale
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let token = AccessToken(url: url) {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard (try? url.checkResourceIsReachable()) == true else {
            token.close()
            return .notConnected
        }
        return .opened(token, refreshedBookmark: isStale ? try? url.bookmarkData() : nil)
    }

    public func volumeKind(of url: URL) -> VolumeKind {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey, .isUbiquitousItemKey]),
              let isLocal = values.volumeIsLocal else { return .unknown }
        if values.isUbiquitousItem == true { return .ubiquitous }
        if !isLocal { return .network }
        guard let isInternal = values.volumeIsInternal else { return .unknown }
        return isInternal ? .internal : .externalLocal
    }
}

import Combine
import EikonCore
import Foundation

/// The UI's face of the settings store: typed reads and writes for split 02's per-game
/// keys, with a change signal so views and the library refresh.
@MainActor
public final class SettingsController: ObservableObject {
    public enum Change: Sendable, Equatable {
        case displayName(GameID)
        case routeOverride(GameID)
    }

    public let store: SettingsStore
    /// Sent after each write; `LibraryController` recomputes routes on `routeOverride`.
    public let changes = PassthroughSubject<Change, Never>()

    public init(store: SettingsStore) {
        self.store = store
    }

    /// Over `Application Support/Eikon`.
    public static func live() throws -> SettingsController {
        SettingsController(store: try SettingsStore(directory: LibraryPaths.support))
    }

    /// nil when unset: the UI falls back to the first location's folder name.
    public func displayName(for game: GameID) -> String? {
        store.value(.displayName, game: game.uuid)
    }

    /// Commit on submit, not per keystroke. Empty or nil resets it.
    public func setDisplayName(_ name: String?, for game: GameID) {
        objectWillChange.send()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            store.reset(.displayName, game: game.uuid)
        } else {
            store.set(.displayName, trimmed, game: game.uuid)
        }
        changes.send(.displayName(game))
    }

    /// nil means Automatic; an unknown stored route reads as Automatic.
    public func routeOverride(for game: GameID) -> RouteID? {
        store.value(.routeOverride, game: game.uuid).flatMap(RouteID.init(rawValue:))
    }

    public func setRouteOverride(_ route: RouteID?, for game: GameID) {
        objectWillChange.send()
        if let route {
            store.set(.routeOverride, route.rawValue, game: game.uuid)
        } else {
            store.reset(.routeOverride, game: game.uuid)
        }
        changes.send(.routeOverride(game))
    }

    /// Writes pending changes now: on scene background and before a session starts.
    public func flush() {
        store.flush()
    }

    public var replicaID: ReplicaID { store.replicaID }
    public var forkedFrom: ReplicaID? { store.forkedFrom }
}

/// The app's storage roots, resolved from `FileManager`; never stored as absolute paths.
public enum LibraryPaths {
    /// `Documents/`: the built-in game drive.
    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `Library/Application Support/Eikon/`: the library index, secret and settings.
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eikon", isDirectory: true)
    }

    /// `…/Eikon/sessions/`: the session sentinel, breadcrumbs, fault file and crash history.
    public static var sessions: URL {
        support.appendingPathComponent("sessions", isDirectory: true)
    }

    /// `…/Eikon/library-secret`: the key fingerprints are made with.
    public static var librarySecret: URL {
        support.appendingPathComponent("library-secret")
    }
}

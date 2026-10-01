import EikonCore
import EikonKit
import UIKit

/// The one way a game session starts: the Launch button (section 13) and the developer
/// test sessions (section 14). Refuses a second session while one is active.
@MainActor
final class SessionPresenter: ObservableObject {
    enum Failure: Error {
        case sessionActive, noWindow, driveNotConnected
    }

    private let library: LibraryController
    private let settings: SettingsController
    /// Developer tools disable their buttons while a session runs.
    @Published private(set) var isSessionActive = false
    private var active: GameSessionHostViewController? {
        didSet { isSessionActive = active != nil }
    }

    init(library: LibraryController, settings: SettingsController) {
        self.library = library
        self.settings = settings
    }

    /// Runs the game from `location`. The drive opens once, here, and stays open for the
    /// whole session, so the game root and the access belong to the same resolution.
    func launch(_ location: GameLocation, game: GameID, route: RouteID, runtime: any GameRuntime.Type) async throws {
        guard active == nil else { throw Failure.sessionActive }
        guard let detection = location.detection, let drive = library.context.index.contents.drive(location.driveID),
              let token = library.driveManager.open(drive) else { throw Failure.driveNotConnected }
        let folder = token.url.appendingPathComponent(location.folderName, isDirectory: true)
        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
        do {
            try await present(LaunchableGame(gameID: game, root: root, detection: detection, route: route),
                              runtime: runtime, sentinelRoute: nil) { { token.close() } }
        } catch {
            token.close()
            throw error
        }
        library.noteLaunched(location: location.id)
    }

    /// A developer session that needs no drive; the sentinel records the test route.
    func launchTest(_ game: LaunchableGame, runtime: any GameRuntime.Type) async throws {
        try await present(game, runtime: runtime, sentinelRoute: SessionRecord.testRoute) { {} }
    }

    private func present(_ game: LaunchableGame, runtime: any GameRuntime.Type, sentinelRoute: String?,
                         openAccess: @escaping @MainActor () throws -> (@MainActor () -> Void)) async throws {
        guard active == nil else { throw Failure.sessionActive }
        guard let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { throw Failure.noWindow }

        let settings = settings
        let environment = GameSessionEnvironment(flushSettings: { settings.flush() }, openAccess: openAccess,
                                                 backgroundWork: library, recorder: LiveSessionRecorder())
        let session = GameSession(game: game, runtimeType: runtime, sentinelRoute: sentinelRoute, environment: environment)
        let host = GameSessionHostViewController(session: session, events: LiveSceneEvents(scene: scene))
        host.onFinish = { [weak self] _ in self?.active = nil }
        active = host
        await SessionPresentation.present(host, from: root)
        do {
            try await host.start()
        } catch {
            // `start` returns only after the session's teardown has finished.
            active = nil
            host.dismiss(animated: true)
            throw error
        }
    }
}

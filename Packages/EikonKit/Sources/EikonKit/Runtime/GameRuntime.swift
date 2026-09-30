import EikonCore
import Foundation
import UIKit

/// One way of running games (a route), created fresh for each session. Its static members
/// are nonisolated, so the type itself can cross isolation (the registry keeps its check).
///
/// Render contract:
/// - Render threads call `host.renderGate.enter()` before encoding or committing GPU work,
///   and `leave()` after `commit()` returns. When `enter()` returns false, skip the frame.
/// - Never block the render path on the main thread between `enter` and `leave`: the host
///   may be waiting in `close(timeout:)` on the main thread.
/// - `pause()` stops game time, audio and GPU submission; `resume()` undoes it.
/// - `stop()` releases every file under the game's root.
/// - The runtime reports its own end (the game quit, or a fatal error) through
///   `host.runtimeDidEnd(error:)`.
/// - Hold the host weakly (it holds the session, which holds the runtime), and give
///   render threads `host.renderGate` itself rather than the host.
/// - A `@MainActor` runtime class marks `route` and `check` `nonisolated`.
public protocol GameRuntime: AnyObject, SendableMetatype {
    static var route: RouteID { get }
    /// Game-specific check beyond `RouteRules` (plugins, Ren'Py version, ...). Runs off the
    /// main actor, may read files, must be cheap enough to run once per (game, build).
    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck
    @MainActor init()
    @MainActor func launch(_ game: LaunchableGame, in host: GameSessionHost) async throws
    /// Stop game time, audio and GPU submission.
    @MainActor func pause()
    @MainActor func resume()
    /// Tear down and release files.
    @MainActor func stop() async
}

public struct LaunchableGame: Sendable {
    public var gameID: GameID
    /// The game root, accessible for the whole session.
    public var root: URL
    public var detection: DetectionResult
    public var route: RouteID

    public init(gameID: GameID, root: URL, detection: DetectionResult, route: RouteID) {
        self.gameID = gameID
        self.root = root
        self.detection = detection
        self.route = route
    }
}

/// The full-screen host a runtime draws into.
@MainActor
public protocol GameSessionHost: AnyObject {
    /// Full-bleed; the runtime owns its contents.
    var contentView: UIView { get }
    var renderGate: RenderGate { get }
    func runtimeDidEnd(error: (any Error)?)
}

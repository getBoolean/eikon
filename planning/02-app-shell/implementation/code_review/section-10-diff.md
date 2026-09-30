diff --git a/App/Localizable.strings b/App/Localizable.strings
index 2417039..70a2ed2 100644
--- a/App/Localizable.strings
+++ b/App/Localizable.strings
@@ -90,3 +90,9 @@
 "report.share" = "Share report";
 "report.copied" = "Copied";
 "report.error" = "Couldn't build the report.";
+
+/* Game session host */
+"session.tapToResume" = "Tap to resume";
+"session.menu" = "Game menu";
+"session.resume" = "Resume";
+"session.quit" = "Quit";
diff --git a/App/Session/SessionPresenter.swift b/App/Session/SessionPresenter.swift
new file mode 100644
index 0000000..0ca36f8
--- /dev/null
+++ b/App/Session/SessionPresenter.swift
@@ -0,0 +1,68 @@
+import EikonCore
+import EikonKit
+import UIKit
+
+/// The one way a game session starts: the Launch button (section 13) and the developer
+/// test sessions (section 14). Refuses a second session while one is active.
+@MainActor
+final class SessionPresenter {
+    enum Failure: Error {
+        case sessionActive, noWindow, driveNotConnected
+    }
+
+    private let library: LibraryController
+    private let settings: SettingsController
+    private var active: GameSessionHostViewController?
+
+    init(library: LibraryController, settings: SettingsController) {
+        self.library = library
+        self.settings = settings
+    }
+
+    var isSessionActive: Bool { active != nil }
+
+    /// Runs the game from `location`, holding its drive open for the whole session.
+    func launch(_ location: GameLocation, game: GameID, route: RouteID, runtime: any GameRuntime.Type) async throws {
+        let manager = library.driveManager
+        guard let detection = location.detection, let drive = library.context.index.contents.drive(location.driveID),
+              let probe = manager.open(drive) else { throw Failure.driveNotConnected }
+        let folder = probe.url.appendingPathComponent(location.folderName, isDirectory: true)
+        probe.close()
+        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
+        library.noteLaunched(location: location.id)
+        try await present(LaunchableGame(gameID: game, root: root, detection: detection, route: route),
+                          runtime: runtime, sentinelRoute: nil) {
+            guard let token = manager.open(drive) else { throw Failure.driveNotConnected }
+            return { token.close() }
+        }
+    }
+
+    /// A developer session that needs no drive; the sentinel records the test route.
+    func launchTest(_ game: LaunchableGame, runtime: any GameRuntime.Type) async throws {
+        try await present(game, runtime: runtime, sentinelRoute: SessionRecord.testRoute) { {} }
+    }
+
+    private func present(_ game: LaunchableGame, runtime: any GameRuntime.Type, sentinelRoute: String?,
+                         openAccess: @escaping @MainActor () throws -> (@MainActor () -> Void)) async throws {
+        guard active == nil else { throw Failure.sessionActive }
+        guard let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene })
+                .first(where: { $0.activationState == .foregroundActive }),
+              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { throw Failure.noWindow }
+
+        let settings = settings
+        let environment = GameSessionEnvironment(flushSettings: { settings.flush() }, openAccess: openAccess,
+                                                 backgroundWork: library, recorder: LiveSessionRecorder())
+        let session = GameSession(game: game, runtimeType: runtime, sentinelRoute: sentinelRoute, environment: environment)
+        let host = GameSessionHostViewController(session: session, events: LiveSceneEvents(scene: scene))
+        host.onFinish = { [weak self] _ in self?.active = nil }
+        active = host
+        SessionPresentation.present(host, from: root)
+        do {
+            try await host.start()
+        } catch {
+            active = nil
+            host.dismiss(animated: true)
+            throw error
+        }
+    }
+}
diff --git a/Packages/EikonCore/Package.swift b/Packages/EikonCore/Package.swift
index c47938d..a1db55e 100644
--- a/Packages/EikonCore/Package.swift
+++ b/Packages/EikonCore/Package.swift
@@ -6,6 +6,7 @@ let package = Package(
     platforms: [.iOS(.v15), .macOS(.v13)],
     products: [
         .library(name: "EikonCore", targets: ["EikonCore"]),
+        .library(name: "CEikonSession", targets: ["CEikonSession"]),
         .executable(name: "eikon-scan", targets: ["eikon-scan"]),
     ],
     targets: [
diff --git a/Packages/EikonKit/Package.swift b/Packages/EikonKit/Package.swift
index 920a7d9..b5b3600 100644
--- a/Packages/EikonKit/Package.swift
+++ b/Packages/EikonKit/Package.swift
@@ -12,7 +12,11 @@ let package = Package(
     ],
     targets: [
         .target(name: "CEikonJIT", linkerSettings: [.linkedFramework("Security")]),
-        .target(name: "EikonKit", dependencies: ["CEikonJIT", .product(name: "EikonCore", package: "EikonCore")]),
+        .target(name: "EikonKit", dependencies: [
+            "CEikonJIT",
+            .product(name: "EikonCore", package: "EikonCore"),
+            .product(name: "CEikonSession", package: "EikonCore"),
+        ]),
         .testTarget(name: "EikonKitTests", dependencies: ["EikonKit", "CEikonJIT"]),
     ],
     swiftLanguageModes: [.v6]
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift b/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
index 6b8b818..9fcfd9a 100644
--- a/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
+++ b/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
@@ -480,3 +480,13 @@ private final class ProgressThrottle: @unchecked Sendable {
         }
     }
 }
+
+extension LibraryController: SessionBackgroundWork {
+    public func suspendForSession() {
+        suspendBackgroundWork()
+    }
+
+    public func resumeAfterSession() {
+        resumeBackgroundWork()
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/GameRuntime.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/GameRuntime.swift
new file mode 100644
index 0000000..8b809c8
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/GameRuntime.swift
@@ -0,0 +1,53 @@
+import EikonCore
+import Foundation
+import UIKit
+
+/// One way of running games (a route), created fresh for each session. Its static members
+/// are nonisolated, so the type itself can cross isolation (the registry keeps its check).
+///
+/// Render contract:
+/// - Render threads call `host.renderGate.enter()` before encoding or committing GPU work,
+///   and `leave()` after `commit()` returns. When `enter()` returns false, skip the frame.
+/// - Never block the render path on the main thread between `enter` and `leave`: the host
+///   may be waiting in `close(timeout:)` on the main thread.
+/// - `pause()` stops game time, audio and GPU submission; `resume()` undoes it.
+/// - `stop()` releases every file under the game's root.
+/// - The runtime reports its own end (the game quit, or a fatal error) through
+///   `host.runtimeDidEnd(error:)`.
+public protocol GameRuntime: AnyObject, SendableMetatype {
+    static var route: RouteID { get }
+    /// Game-specific check beyond `RouteRules` (plugins, Ren'Py version, ...). Runs off the
+    /// main actor, may read files, must be cheap enough to run once per (game, build).
+    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck
+    @MainActor init()
+    @MainActor func launch(_ game: LaunchableGame, in host: GameSessionHost) async throws
+    /// Stop game time, audio and GPU submission.
+    @MainActor func pause()
+    @MainActor func resume()
+    /// Tear down and release files.
+    @MainActor func stop() async
+}
+
+public struct LaunchableGame: Sendable {
+    public var gameID: GameID
+    /// The game root, accessible for the whole session.
+    public var root: URL
+    public var detection: DetectionResult
+    public var route: RouteID
+
+    public init(gameID: GameID, root: URL, detection: DetectionResult, route: RouteID) {
+        self.gameID = gameID
+        self.root = root
+        self.detection = detection
+        self.route = route
+    }
+}
+
+/// The full-screen host a runtime draws into.
+@MainActor
+public protocol GameSessionHost: AnyObject {
+    /// Full-bleed; the runtime owns its contents.
+    var contentView: UIView { get }
+    var renderGate: RenderGate { get }
+    func runtimeDidEnd(error: (any Error)?)
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/GameSession.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/GameSession.swift
new file mode 100644
index 0000000..a43b56e
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/GameSession.swift
@@ -0,0 +1,167 @@
+import EikonCore
+import Foundation
+import os
+
+/// Background work (drive scans, fingerprinting) that pauses while a game runs.
+@MainActor
+public protocol SessionBackgroundWork: AnyObject {
+    func suspendForSession()
+    func resumeAfterSession()
+}
+
+/// What a session needs from the rest of the app, as seams.
+@MainActor
+public struct GameSessionEnvironment {
+    public var flushSettings: @MainActor () -> Void
+    /// Opens the drive's access for the session and returns its closer.
+    public var openAccess: @MainActor () throws -> (@MainActor () -> Void)
+    public var backgroundWork: any SessionBackgroundWork
+    public var recorder: any SessionRecorder
+    public var appBuild: String
+    public var now: () -> Date
+    public var availableMemoryMB: () -> Int
+    /// Runs `work` inside a background task; `work` calls `end` when done.
+    public var beginBackgroundTask: @MainActor (_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) -> Void
+
+    public init(flushSettings: @escaping @MainActor () -> Void,
+                openAccess: @escaping @MainActor () throws -> (@MainActor () -> Void),
+                backgroundWork: any SessionBackgroundWork, recorder: any SessionRecorder,
+                appBuild: String = AppInfo.from(.main).build, now: @escaping () -> Date = { Date() },
+                availableMemoryMB: @escaping () -> Int = { Int(os_proc_available_memory() / 1_048_576) },
+                beginBackgroundTask: @escaping @MainActor (_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) -> Void
+                    = GameSessionEnvironment.liveBackgroundTask) {
+        self.flushSettings = flushSettings
+        self.openAccess = openAccess
+        self.backgroundWork = backgroundWork
+        self.recorder = recorder
+        self.appBuild = appBuild
+        self.now = now
+        self.availableMemoryMB = availableMemoryMB
+        self.beginBackgroundTask = beginBackgroundTask
+    }
+
+    public static func liveBackgroundTask(_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) {
+        work(LiveBackgroundActivity().begin("eikon.session.background"))
+    }
+}
+
+/// One game session: the sentinel, the drive access, paused background work and memory
+/// samples around one runtime instance. Only one runs at a time.
+@MainActor
+public final class GameSession {
+    public static let memorySampleInterval: TimeInterval = 30
+    private static let log = Logger(subsystem: "com.getboolean.eikon", category: "session")
+
+    public let game: LaunchableGame
+    public private(set) var runtime: (any GameRuntime)?
+    public private(set) var hasEnded = false
+    private let runtimeType: any GameRuntime.Type
+    private let sentinelRoute: String
+    private let environment: GameSessionEnvironment
+    private var closeAccess: (@MainActor () -> Void)?
+    private var armed = false
+    private var suspendedWork = false
+    private var memoryTimer: Timer?
+
+    /// `sentinelRoute` defaults to the game's route; test sessions pass `SessionRecord.testRoute`.
+    public init(game: LaunchableGame, runtimeType: any GameRuntime.Type, sentinelRoute: String? = nil,
+                environment: GameSessionEnvironment) {
+        self.game = game
+        self.runtimeType = runtimeType
+        self.sentinelRoute = sentinelRoute ?? game.route.rawValue
+        self.environment = environment
+    }
+
+    /// Flush settings, open the drive, arm the sentinel, pause background work, then
+    /// launch. A failure unwinds what was done and is rethrown.
+    func start(host: any GameSessionHost) async throws {
+        environment.flushSettings()
+        do {
+            closeAccess = try environment.openAccess()
+            try environment.recorder.arm(SessionRecord(
+                gameID: game.gameID, engine: game.detection.engine,
+                architecture: Self.architecture(game.detection, route: game.route),
+                route: sentinelRoute, appBuild: environment.appBuild, startedAt: environment.now()))
+            armed = true
+            add(.sessionStart)
+            environment.backgroundWork.suspendForSession()
+            suspendedWork = true
+
+            let runtime = runtimeType.init()
+            self.runtime = runtime
+            host.renderGate.open()
+            startMemorySamples()
+            do {
+                try await runtime.launch(game, in: host)
+            } catch {
+                add(.runtimeError(code: Int64((error as NSError).code)))
+                throw error
+            }
+        } catch {
+            await end(runtimeReportedEnd: false)
+            throw error
+        }
+    }
+
+    /// Idempotent: quit, the runtime's own end and a failed launch all come here.
+    func end(runtimeReportedEnd: Bool) async {
+        guard !hasEnded else { return }
+        hasEnded = true
+        if let runtime, !runtimeReportedEnd {
+            await runtime.stop()
+        }
+        if armed {
+            environment.recorder.add(.sessionStop)
+            environment.recorder.disarm()
+        }
+        closeAccess?()
+        closeAccess = nil
+        if suspendedWork {
+            environment.backgroundWork.resumeAfterSession()
+        }
+        memoryTimer?.invalidate()
+        memoryTimer = nil
+    }
+
+    func add(_ event: BreadcrumbEvent) {
+        guard armed, !hasEnded else { return }
+        environment.recorder.add(event)
+    }
+
+    func setPhase(_ phase: SessionRecord.Phase) {
+        guard armed, !hasEnded else { return }
+        do {
+            try environment.recorder.setPhase(phase)
+        } catch {
+            // The sentinel vanished: a crash now would go unreported. Codes only.
+            Self.log.error("sentinel phase write failed: \((error as NSError).code, privacy: .public)")
+            assertionFailure("sentinel phase write failed")
+        }
+    }
+
+    func flushSettings() {
+        environment.flushSettings()
+    }
+
+    func inBackgroundTask(_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) {
+        environment.beginBackgroundTask(work)
+    }
+
+    func recordMemorySample() {
+        add(.memorySample(availableMB: Int64(environment.availableMemoryMB())))
+    }
+
+    private func startMemorySamples() {
+        memoryTimer = Timer.scheduledTimer(withTimeInterval: Self.memorySampleInterval, repeats: true) { [weak self] _ in
+            MainActor.assumeIsolated { self?.recordMemorySample() }
+        }
+    }
+
+    /// The main executable's architecture for the route's platform.
+    static func architecture(_ detection: DetectionResult, route: RouteID) -> CPUArchitecture? {
+        switch route {
+        case .wineFEX, .wineBox64, .nativeKirikiri, .nativeRenPy: detection.executables[.windows]?.architecture
+        case .linuxFEX: detection.executables[.linux]?.architecture
+        }
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/GameSessionHostViewController.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/GameSessionHostViewController.swift
new file mode 100644
index 0000000..b717dc2
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/GameSessionHostViewController.swift
@@ -0,0 +1,187 @@
+import EikonCore
+import UIKit
+
+/// The full-screen host of one game session: hides system UI, pauses on deactivation,
+/// and resumes only when the player taps "Tap to resume" (or Resume in the menu).
+@MainActor
+public final class GameSessionHostViewController: UIViewController, GameSessionHost {
+    public let contentView = UIView()
+    public let renderGate = RenderGate()
+    public let session: GameSession
+    /// After the session ended and the host was dismissed; the error the runtime reported, if any.
+    public var onFinish: (@MainActor ((any Error)?) -> Void)?
+
+    public private(set) var isResumeOverlayVisible = false
+    private let events: any SceneEvents
+    private var subscription: SceneEventsSubscription?
+    private var isPaused = false
+    private let overlay = UIButton(type: .system)
+    private let menuButton = UIButton(type: .system)
+
+    public init(session: GameSession, events: any SceneEvents) {
+        self.session = session
+        self.events = events
+        super.init(nibName: nil, bundle: nil)
+        modalPresentationStyle = .fullScreen
+        modalPresentationCapturesStatusBarAppearance = true
+    }
+
+    @available(*, unavailable)
+    required init?(coder: NSCoder) {
+        fatalError("init(coder:) is not supported")
+    }
+
+    /// Starts the session; a failure ends it and is rethrown.
+    public func start() async throws {
+        subscription = events.subscribe { [weak self] event in self?.handle(event) }
+        do {
+            try await session.start(host: self)
+        } catch {
+            subscription?.cancel()
+            subscription = nil
+            throw error
+        }
+    }
+
+    // MARK: System UI
+
+    override public var prefersStatusBarHidden: Bool { true }
+    override public var prefersHomeIndicatorAutoHidden: Bool { true }
+    override public var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
+
+    override public func viewDidLoad() {
+        super.viewDidLoad()
+        view.backgroundColor = .black
+        contentView.frame = view.bounds
+        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
+        view.addSubview(contentView)
+
+        overlay.setTitle(NSLocalizedString("session.tapToResume", comment: "Overlay shown while a game is paused"), for: .normal)
+        overlay.titleLabel?.font = .preferredFont(forTextStyle: .title2)
+        overlay.tintColor = .white
+        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
+        overlay.frame = view.bounds
+        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
+        overlay.addAction(UIAction { [weak self] _ in self?.resumeSession() }, for: .primaryActionTriggered)
+        overlay.isHidden = !isResumeOverlayVisible
+        view.addSubview(overlay)
+
+        menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
+        menuButton.tintColor = .white
+        menuButton.accessibilityLabel = NSLocalizedString("session.menu", comment: "Game session menu button")
+        menuButton.showsMenuAsPrimaryAction = true
+        menuButton.menu = UIMenu(children: [
+            UIAction(title: NSLocalizedString("session.resume", comment: "Resume the paused game"),
+                     image: UIImage(systemName: "play.fill")) { [weak self] _ in self?.resumeSession() },
+            UIAction(title: NSLocalizedString("session.quit", comment: "End the game session"),
+                     image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
+                Task { await self?.quit() }
+            },
+        ])
+        menuButton.translatesAutoresizingMaskIntoConstraints = false
+        view.addSubview(menuButton)
+        NSLayoutConstraint.activate([
+            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
+            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
+            menuButton.widthAnchor.constraint(equalToConstant: 44),
+            menuButton.heightAnchor.constraint(equalToConstant: 44),
+        ])
+    }
+
+    override public func viewDidAppear(_ animated: Bool) {
+        super.viewDidAppear(animated)
+        setNeedsStatusBarAppearanceUpdate()
+        setNeedsUpdateOfHomeIndicatorAutoHidden()
+        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
+        // Stays tappable, out of the game's way.
+        UIView.animate(withDuration: 0.4, delay: 3) { self.menuButton.alpha = 0.2 }
+    }
+
+    // MARK: Events
+
+    func handle(_ event: SceneEvent) {
+        guard !session.hasEnded else { return }
+        switch event {
+        case .willDeactivate:
+            pauseSession()
+        case .didEnterBackground:
+            session.inBackgroundTask { [weak self] end in
+                guard let self, !session.hasEnded else { return end() }
+                // The phase says `background` only once nothing touches the GPU.
+                pauseSession()
+                session.setPhase(.background)
+                session.flushSettings()
+                session.add(.sessionBackgrounded)
+                end()
+            }
+        case .didActivate:
+            session.setPhase(.running)
+            setOverlayVisible(true)
+        case .audioInterruptionBegan:
+            session.add(.audioInterrupted)
+            pauseSession()
+        case .audioInterruptionEnded:
+            setOverlayVisible(true)
+        case .audioOldDeviceUnavailable:
+            pauseSession()
+            setOverlayVisible(true)
+        case .memoryWarning:
+            session.add(.memoryWarning)
+            session.recordMemorySample()
+        }
+    }
+
+    /// Once per pause episode: close the gate, then pause the runtime.
+    private func pauseSession() {
+        guard !isPaused else { return }
+        isPaused = true
+        if !renderGate.close() {
+            session.add(.renderGateTimeout)
+        }
+        session.runtime?.pause()
+        session.add(.sessionPaused)
+    }
+
+    /// The overlay tap and the menu's Resume.
+    func resumeSession() {
+        guard !session.hasEnded else { return }
+        if isPaused {
+            renderGate.open()
+            session.runtime?.resume()
+            session.add(.sessionResumed)
+            isPaused = false
+        }
+        setOverlayVisible(false)
+    }
+
+    private func setOverlayVisible(_ visible: Bool) {
+        isResumeOverlayVisible = visible
+        if isViewLoaded { overlay.isHidden = !visible }
+    }
+
+    // MARK: Ending
+
+    /// The menu's Quit: stops the runtime, ends the session, dismisses.
+    func quit() async {
+        await finish(runtimeReportedEnd: false, error: nil)
+    }
+
+    public func runtimeDidEnd(error: (any Error)?) {
+        if let error {
+            session.add(.runtimeError(code: Int64((error as NSError).code)))
+        }
+        Task { await finish(runtimeReportedEnd: true, error: error) }
+    }
+
+    private func finish(runtimeReportedEnd: Bool, error: (any Error)?) async {
+        guard !session.hasEnded else { return }
+        subscription?.cancel()
+        subscription = nil
+        renderGate.close()
+        await session.end(runtimeReportedEnd: runtimeReportedEnd)
+        if presentingViewController != nil {
+            dismiss(animated: true)
+        }
+        onFinish?(error)
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/RenderGate.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/RenderGate.swift
new file mode 100644
index 0000000..3976a85
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/RenderGate.swift
@@ -0,0 +1,46 @@
+import CEikonSession
+import Darwin
+import Foundation
+
+/// Stops GPU work when the app leaves the foreground: render threads enter before a
+/// frame and leave after committing it; the host closes the gate and waits for frames in
+/// flight. Not actor-isolated, since render threads call it.
+public final class RenderGate: @unchecked Sendable {
+    private let handle: OpaquePointer
+
+    /// Starts open.
+    public init() {
+        guard let handle = eikon_render_gate_create() else { fatalError("render gate: out of memory") }
+        self.handle = handle
+    }
+
+    deinit {
+        eikon_render_gate_destroy(handle)
+    }
+
+    /// False when the gate is closed: skip the frame.
+    public func enter() -> Bool {
+        eikon_render_gate_enter(handle)
+    }
+
+    public func leave() {
+        eikon_render_gate_leave(handle)
+    }
+
+    /// Closes the gate, then waits for frames in flight to leave, never past `timeout`.
+    /// True when they all left.
+    @discardableResult
+    public func close(timeout: TimeInterval = 0.1) -> Bool {
+        eikon_render_gate_set_closed(handle, true)
+        let deadline = ProcessInfo.processInfo.systemUptime + timeout
+        while eikon_render_gate_in_flight(handle) > 0 {
+            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
+            usleep(1000)
+        }
+        return true
+    }
+
+    public func open() {
+        eikon_render_gate_set_closed(handle, false)
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/RuntimeRegistry.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/RuntimeRegistry.swift
new file mode 100644
index 0000000..2ee51b3
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/RuntimeRegistry.swift
@@ -0,0 +1,68 @@
+import EikonCore
+import Foundation
+
+/// What a runtime check result is cached under, per route: the game and its build (the
+/// location's exact fingerprint signal), so a patch re-runs the check.
+public struct RuntimeCheckKey: Hashable, Sendable {
+    public var gameID: GameID
+    public var build: Keyed
+
+    public init(gameID: GameID, build: Keyed) {
+        self.gameID = gameID
+        self.build = build
+    }
+}
+
+/// The runtimes this build has, and their cached game checks. Runtimes register in
+/// `EikonApp.init`; split 02 registers none.
+@MainActor
+public final class RuntimeRegistry: ObservableObject {
+    /// Feeds `RouteEnvironment.builtRoutes`.
+    @Published public private(set) var builtRoutes: Set<RouteID> = []
+
+    private struct CacheKey: Hashable {
+        var route: RouteID
+        var key: RuntimeCheckKey
+    }
+
+    private var types: [RouteID: any GameRuntime.Type] = [:]
+    private var checkers: [RouteID: @Sendable (DetectionResult, URL) async -> RuntimeCheck] = [:]
+    private var cache: [CacheKey: Task<RuntimeCheck, Never>] = [:]
+
+    public init() {}
+
+    /// Replaces any runtime for the same route and drops every cached check.
+    public func register<T: GameRuntime>(_ type: T.Type) {
+        types[T.route] = type
+        checkers[T.route] = { detection, root in await T.check(detection, root: root) }
+        cache.removeAll()
+        builtRoutes.insert(T.route)
+    }
+
+    public func runtimeType(for route: RouteID) -> (any GameRuntime.Type)? {
+        types[route]
+    }
+
+    /// Runs the route's check off the main actor, once per key; concurrent callers share it.
+    /// Only built routes are checked: use `checks` rather than asking for others.
+    public func check(route: RouteID, detection: DetectionResult, root: URL, cacheKey: RuntimeCheckKey) async -> RuntimeCheck {
+        guard let checker = checkers[route] else {
+            assertionFailure("no runtime registered for this route")
+            return .ok
+        }
+        let key = CacheKey(route: route, key: cacheKey)
+        if let running = cache[key] { return await running.value }
+        let task = Task.detached { await checker(detection, root) }
+        cache[key] = task
+        return await task.value
+    }
+
+    /// Every registered route's check, for `RouteEnvironment.runtimeChecks`.
+    public func checks(detection: DetectionResult, root: URL, cacheKey: RuntimeCheckKey) async -> [RouteID: RuntimeCheck] {
+        var results: [RouteID: RuntimeCheck] = [:]
+        for route in checkers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
+            results[route] = await check(route: route, detection: detection, root: root, cacheKey: cacheKey)
+        }
+        return results
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/SceneEvents.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/SceneEvents.swift
new file mode 100644
index 0000000..04168c3
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/SceneEvents.swift
@@ -0,0 +1,99 @@
+import AVFAudio
+import Foundation
+import UIKit
+
+public enum SceneEvent: Sendable, Equatable {
+    case willDeactivate, didEnterBackground, didActivate
+    case audioInterruptionBegan, audioInterruptionEnded
+    case audioOldDeviceUnavailable
+    case memoryWarning
+}
+
+/// Scene, audio and memory notifications for the session host.
+@MainActor
+public protocol SceneEvents: AnyObject {
+    /// Starts delivering events on the main actor. Delivery stops when the returned
+    /// subscription is cancelled or released.
+    func subscribe(_ handler: @escaping @MainActor (SceneEvent) -> Void) -> SceneEventsSubscription
+}
+
+public final class SceneEventsSubscription: @unchecked Sendable {
+    private let lock = NSLock()
+    private var onCancel: (@Sendable () -> Void)?
+
+    public init(onCancel: @escaping @Sendable () -> Void) {
+        self.onCancel = onCancel
+    }
+
+    deinit {
+        cancel()
+    }
+
+    public func cancel() {
+        let cancel = lock.withLock {
+            defer { onCancel = nil }
+            return onCancel
+        }
+        cancel?()
+    }
+}
+
+/// Scene notifications from the host's own scene only, so another window on iPad doesn't
+/// pause the game; audio interruptions and route changes; memory warnings.
+@MainActor
+public final class LiveSceneEvents: SceneEvents {
+    private weak var scene: UIWindowScene?
+
+    public init(scene: UIWindowScene?) {
+        self.scene = scene
+    }
+
+    public func subscribe(_ handler: @escaping @MainActor (SceneEvent) -> Void) -> SceneEventsSubscription {
+        let center = NotificationCenter.default
+        let observers = Observers()
+        func observe(_ name: Notification.Name, object: AnyObject?, _ event: @escaping @Sendable (Notification) -> SceneEvent?) {
+            observers.add(center.addObserver(forName: name, object: object, queue: .main) { notification in
+                guard let event = event(notification) else { return }
+                MainActor.assumeIsolated { handler(event) }
+            })
+        }
+
+        observe(UIScene.willDeactivateNotification, object: scene) { _ in .willDeactivate }
+        observe(UIScene.didEnterBackgroundNotification, object: scene) { _ in .didEnterBackground }
+        observe(UIScene.didActivateNotification, object: scene) { _ in .didActivate }
+        observe(AVAudioSession.interruptionNotification, object: nil) { notification in
+            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
+            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
+            case .began: return .audioInterruptionBegan
+            case .ended: return .audioInterruptionEnded
+            case nil: return nil
+            @unknown default: return nil
+            }
+        }
+        observe(AVAudioSession.routeChangeNotification, object: nil) { notification in
+            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
+            return raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
+                ? .audioOldDeviceUnavailable : nil
+        }
+        observe(UIApplication.didReceiveMemoryWarningNotification, object: nil) { _ in .memoryWarning }
+
+        return SceneEventsSubscription { observers.removeAll(from: center) }
+    }
+}
+
+private final class Observers: @unchecked Sendable {
+    private let lock = NSLock()
+    private var tokens: [any NSObjectProtocol] = []
+
+    func add(_ token: any NSObjectProtocol) {
+        lock.withLock { tokens.append(token) }
+    }
+
+    func removeAll(from center: NotificationCenter) {
+        let removed = lock.withLock {
+            defer { tokens = [] }
+            return tokens
+        }
+        removed.forEach(center.removeObserver)
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/SessionPresentation.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/SessionPresentation.swift
new file mode 100644
index 0000000..dd0ef36
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/SessionPresentation.swift
@@ -0,0 +1,18 @@
+import UIKit
+
+/// Where a session host is presented from: the end of the root's presentation chain, so
+/// a sheet that is up doesn't block it.
+@MainActor
+public enum SessionPresentation {
+    public static func topmostPresented(from root: UIViewController) -> UIViewController {
+        var controller = root
+        while let next = controller.presentedViewController {
+            controller = next
+        }
+        return controller
+    }
+
+    public static func present(_ host: GameSessionHostViewController, from root: UIViewController, animated: Bool = true) {
+        topmostPresented(from: root).present(host, animated: animated)
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/Runtime/SessionRecorder.swift b/Packages/EikonKit/Sources/EikonKit/Runtime/SessionRecorder.swift
new file mode 100644
index 0000000..655403c
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Runtime/SessionRecorder.swift
@@ -0,0 +1,53 @@
+import EikonCore
+import Foundation
+
+/// The session's evidence on disk: sentinel, breadcrumbs and fault file.
+@MainActor
+public protocol SessionRecorder: AnyObject {
+    /// Arms the sentinel, then opens the breadcrumb ring and the fault file.
+    func arm(_ record: SessionRecord) throws
+    /// Throws when the sentinel is gone, so a lost phase change is noticed.
+    func setPhase(_ phase: SessionRecord.Phase) throws
+    func add(_ event: BreadcrumbEvent)
+    /// Closes the ring and the fault file, then disarms the sentinel (removing them).
+    func disarm()
+}
+
+/// Over section 07's `SessionSentinel`, `Breadcrumbs` and `FaultRecord` in
+/// `Application Support/Eikon/sessions/`.
+@MainActor
+public final class LiveSessionRecorder: SessionRecorder {
+    public let sentinel: SessionSentinel
+
+    public init(directory: URL = LibraryPaths.support.appendingPathComponent("sessions", isDirectory: true)) {
+        sentinel = SessionSentinel(directory: directory)
+    }
+
+    /// Arming unlinks the previous ring and fault file, so both open only afterwards;
+    /// opened before, every breadcrumb would go to an unlinked file.
+    public func arm(_ record: SessionRecord) throws {
+        try FileManager.default.createDirectory(at: sentinel.directory, withIntermediateDirectories: true)
+        try sentinel.arm(record)
+        do {
+            try Breadcrumbs.open(at: sentinel.breadcrumbsURL)
+            try FaultRecord.open(at: sentinel.faultURL, sessionID: record.sessionID)
+        } catch {
+            disarm()
+            throw error
+        }
+    }
+
+    public func setPhase(_ phase: SessionRecord.Phase) throws {
+        try sentinel.setPhase(phase)
+    }
+
+    public func add(_ event: BreadcrumbEvent) {
+        Breadcrumbs.append(event)
+    }
+
+    public func disarm() {
+        Breadcrumbs.close()
+        FaultRecord.close()
+        sentinel.disarm()
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/RuntimeTests.swift b/Packages/EikonKit/Tests/EikonKitTests/RuntimeTests.swift
new file mode 100644
index 0000000..61b34f9
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/RuntimeTests.swift
@@ -0,0 +1,113 @@
+import EikonCore
+import Foundation
+import Testing
+@testable import EikonKit
+
+// MARK: Fakes
+
+private final class Counter: @unchecked Sendable {
+    private let lock = NSLock()
+    private var count = 0
+
+    var value: Int { lock.withLock { count } }
+
+    func increment() {
+        lock.withLock { count += 1 }
+    }
+}
+
+private final class CheckedRuntime: GameRuntime {
+    static let checks = Counter()
+    static var route: RouteID { .nativeRenPy }
+
+    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck {
+        checks.increment()
+        return .ok
+    }
+
+    @MainActor init() {}
+    @MainActor func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws {}
+    @MainActor func pause() {}
+    @MainActor func resume() {}
+    @MainActor func stop() async {}
+}
+
+private final class OtherRuntime: GameRuntime {
+    static var route: RouteID { .linuxFEX }
+
+    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck { .ok }
+
+    @MainActor init() {}
+    @MainActor func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws {}
+    @MainActor func pause() {}
+    @MainActor func resume() {}
+    @MainActor func stop() async {}
+}
+
+// MARK: Render gate
+
+@Test func renderGateEnterSucceedsWhileOpenAndFailsAfterClose() {
+    let gate = RenderGate()
+    #expect(gate.enter())
+    gate.leave()
+    #expect(gate.close())
+    #expect(!gate.enter())
+    gate.open()
+    #expect(gate.enter())
+    gate.leave()
+}
+
+@Test func renderGateCloseWaitsForInFlightFrameToLeave() {
+    let gate = RenderGate()
+    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
+    let returned = Counter(), drained = Counter()
+    DispatchQueue.global().async {
+        _ = gate.enter()
+        entered.signal()
+        release.wait()
+        gate.leave()
+    }
+    entered.wait()
+    DispatchQueue.global().async {
+        if gate.close(timeout: 10) { drained.increment() }
+        returned.increment()
+        closed.signal()
+    }
+    usleep(20_000)
+    #expect(returned.value == 0)
+    release.signal()
+    closed.wait()
+    #expect(drained.value == 1)
+}
+
+@Test func renderGateCloseReturnsFalseWhenFrameNeverLeaves() {
+    let gate = RenderGate()
+    #expect(gate.enter())
+    #expect(!gate.close(timeout: 0.01))
+    gate.leave()
+}
+
+// MARK: Registry
+
+@Test @MainActor func runtimeChecksAreCachedPerRouteGameAndBuildAndRequeriedAfterRegistration() async {
+    let registry = RuntimeRegistry()
+    registry.register(CheckedRuntime.self)
+    let detection = DetectionResult(engine: .renpy, details: EngineDetails(), gameRoot: "", executables: [:],
+                                    keyFile: nil, detectorVersion: GameDetector.version)
+    let root = FileManager.default.temporaryDirectory
+    let game = GameID.random()
+    let first = RuntimeCheckKey(gameID: game, build: Keyed(hex: "01"))
+
+    _ = await registry.check(route: CheckedRuntime.route, detection: detection, root: root, cacheKey: first)
+    _ = await registry.check(route: CheckedRuntime.route, detection: detection, root: root, cacheKey: first)
+    #expect(CheckedRuntime.checks.value == 1)
+
+    _ = await registry.check(route: CheckedRuntime.route, detection: detection, root: root,
+                             cacheKey: RuntimeCheckKey(gameID: game, build: Keyed(hex: "02")))
+    #expect(CheckedRuntime.checks.value == 2)
+
+    registry.register(OtherRuntime.self)
+    _ = await registry.checks(detection: detection, root: root, cacheKey: first)
+    #expect(CheckedRuntime.checks.value == 3)
+    #expect(registry.builtRoutes == [CheckedRuntime.route, OtherRuntime.route])
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/SessionHostTests.swift b/Packages/EikonKit/Tests/EikonKitTests/SessionHostTests.swift
new file mode 100644
index 0000000..b08db8e
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/SessionHostTests.swift
@@ -0,0 +1,208 @@
+import EikonCore
+import Foundation
+import Testing
+import UIKit
+@testable import EikonKit
+
+// MARK: Fakes
+
+/// One ordered log shared by the runtime, recorder and environment of a test.
+@MainActor
+private final class Log {
+    private(set) var entries: [String] = []
+
+    func add(_ entry: String) {
+        entries.append(entry)
+    }
+
+    func count(_ entry: String) -> Int {
+        entries.filter { $0 == entry }.count
+    }
+
+    func index(_ entry: String) -> Int? {
+        entries.firstIndex(of: entry)
+    }
+}
+
+private final class FakeRuntime: GameRuntime {
+    /// The runtime is created inside the session's start, so it picks up the test's log.
+    @TaskLocal static var currentLog: Log?
+
+    static var route: RouteID { .nativeRenPy }
+    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck { .ok }
+
+    private let log: Log?
+
+    @MainActor init() {
+        log = Self.currentLog
+    }
+
+    @MainActor func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws { log?.add("launch") }
+    @MainActor func pause() { log?.add("pause") }
+    @MainActor func resume() { log?.add("resume") }
+    @MainActor func stop() async { log?.add("stop") }
+}
+
+@MainActor
+private final class FakeRecorder: SessionRecorder {
+    let log: Log
+
+    init(_ log: Log) {
+        self.log = log
+    }
+
+    func arm(_ record: SessionRecord) throws { log.add("arm") }
+    func setPhase(_ phase: SessionRecord.Phase) throws { log.add("phase:\(phase.rawValue)") }
+    func add(_ event: BreadcrumbEvent) { log.add("crumb:\(event)") }
+    func disarm() { log.add("disarm") }
+}
+
+@MainActor
+private final class FakeBackgroundWork: SessionBackgroundWork {
+    let log: Log
+
+    init(_ log: Log) {
+        self.log = log
+    }
+
+    func suspendForSession() { log.add("suspendWork") }
+    func resumeAfterSession() { log.add("resumeWork") }
+}
+
+@MainActor
+private final class FakeSceneEvents: SceneEvents {
+    func subscribe(_ handler: @escaping @MainActor (SceneEvent) -> Void) -> SceneEventsSubscription {
+        SceneEventsSubscription {}
+    }
+}
+
+@MainActor
+private func startedHost(_ log: Log) async throws -> GameSessionHostViewController {
+    let environment = GameSessionEnvironment(
+        flushSettings: { log.add("flush") },
+        openAccess: {
+            log.add("open")
+            return { log.add("close") }
+        },
+        backgroundWork: FakeBackgroundWork(log), recorder: FakeRecorder(log), appBuild: "1",
+        availableMemoryMB: { 100 },
+        beginBackgroundTask: { work in work {} })
+    let detection = DetectionResult(engine: .renpy, details: EngineDetails(), gameRoot: "", executables: [:],
+                                    keyFile: nil, detectorVersion: GameDetector.version)
+    let game = LaunchableGame(gameID: .random(), root: FileManager.default.temporaryDirectory, detection: detection,
+                              route: FakeRuntime.route)
+    let host = GameSessionHostViewController(session: GameSession(game: game, runtimeType: FakeRuntime.self,
+                                                                  environment: environment),
+                                             events: FakeSceneEvents())
+    try await FakeRuntime.$currentLog.withValue(log) {
+        try await host.start()
+    }
+    return host
+}
+
+// MARK: Lifecycle
+
+@Test @MainActor func willDeactivateClosesGateAndPausesRuntime() async throws {
+    let log = Log()
+    let host = try await startedHost(log)
+    #expect(host.renderGate.enter())
+    host.renderGate.leave()
+
+    host.handle(.willDeactivate)
+    #expect(log.count("pause") == 1)
+    #expect(!host.renderGate.enter())
+}
+
+@Test @MainActor func phaseBecomesBackgroundOnlyOnDidEnterBackgroundAfterGateClosed() async throws {
+    let log = Log()
+    let host = try await startedHost(log)
+    host.handle(.willDeactivate)
+    #expect(log.index("phase:background") == nil)
+
+    host.handle(.didEnterBackground)
+    let pause = try #require(log.index("pause")), background = try #require(log.index("phase:background"))
+    #expect(pause < background)
+    #expect(!host.renderGate.enter())
+}
+
+@Test @MainActor func didActivateSetsRunningButWaitsForOverlayResume() async throws {
+    let log = Log()
+    let host = try await startedHost(log)
+    host.handle(.willDeactivate)
+    host.handle(.didEnterBackground)
+    host.handle(.didActivate)
+    #expect(log.entries.last { $0.hasPrefix("phase:") } == "phase:running")
+    #expect(log.count("resume") == 0)
+    #expect(host.isResumeOverlayVisible)
+    #expect(!host.renderGate.enter())
+
+    host.resumeSession()
+    #expect(host.renderGate.enter())
+    host.renderGate.leave()
+    #expect(log.count("resume") == 1)
+    #expect(!host.isResumeOverlayVisible)
+}
+
+@Test @MainActor func audioInterruptionPausesAndItsEndDoesNotAutoResume() async throws {
+    let log = Log()
+    let host = try await startedHost(log)
+    host.handle(.audioInterruptionBegan)
+    #expect(log.count("pause") == 1)
+
+    host.handle(.audioInterruptionEnded)
+    #expect(log.count("resume") == 0)
+    #expect(host.isResumeOverlayVisible)
+}
+
+@Test @MainActor func quitStopsRuntimeDisarmsSentinelAndClosesAccessToken() async throws {
+    let log = Log()
+    let host = try await startedHost(log)
+    await host.quit()
+
+    let stop = try #require(log.index("stop")), disarm = try #require(log.index("disarm")),
+        close = try #require(log.index("close"))
+    #expect(stop < disarm)
+    #expect(disarm < close)
+    #expect(log.count("resumeWork") == 1)
+}
+
+// MARK: Presentation
+
+@MainActor
+private final class StubController: UIViewController {
+    var stubPresented: UIViewController?
+    var presentedHere: UIViewController?
+
+    override var presentedViewController: UIViewController? { stubPresented }
+
+    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
+        presentedHere = controller
+    }
+}
+
+@Test @MainActor func presenterUsesTopmostPresentedController() async throws {
+    let root = StubController(), first = StubController(), second = StubController()
+    root.stubPresented = first
+    first.stubPresented = second
+    #expect(SessionPresentation.topmostPresented(from: root) === second)
+
+    let host = try await startedHost(Log())
+    SessionPresentation.present(host, from: root, animated: false)
+    #expect(second.presentedHere === host)
+    #expect(root.presentedHere == nil)
+}
+
+// MARK: Recorder
+
+@Test @MainActor func liveRecorderKeepsBreadcrumbsWrittenAfterArming() throws {
+    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
+    defer { try? FileManager.default.removeItem(at: directory) }
+    let recorder = LiveSessionRecorder(directory: directory)
+    try recorder.arm(SessionRecord(gameID: .random(), engine: .renpy, architecture: nil, route: SessionRecord.testRoute,
+                                   appBuild: "1", startedAt: Date()))
+    recorder.add(.memoryWarning)
+
+    let consumed = SessionSentinel(directory: directory).consumeAtLaunch()
+    recorder.disarm()
+    #expect(consumed?.breadcrumbs.contains { $0.event == .memoryWarning } == true)
+}

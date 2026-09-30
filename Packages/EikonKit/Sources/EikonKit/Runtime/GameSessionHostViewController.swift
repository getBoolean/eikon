import EikonCore
import UIKit

/// The full-screen host of one game session: hides system UI, pauses on deactivation,
/// and resumes only when the player taps "Tap to resume" (or Resume in the menu).
@MainActor
public final class GameSessionHostViewController: UIViewController, GameSessionHost {
    public let contentView = UIView()
    public let renderGate = RenderGate()
    public let session: GameSession
    /// After the session ended and the host was dismissed; the error the runtime reported, if any.
    public var onFinish: (@MainActor ((any Error)?) -> Void)?

    public private(set) var isResumeOverlayVisible = false
    private let events: any SceneEvents
    private var subscription: SceneEventsSubscription?
    private var isPaused = false
    private var endError: (any Error)?
    private let overlay = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)

    public init(session: GameSession, events: any SceneEvents) {
        self.session = session
        self.events = events
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Starts the session; a failure ends it and is rethrown.
    public func start() async throws {
        subscription = events.subscribe { [weak self] event in self?.handle(event) }
        do {
            try await session.start(host: self)
        } catch {
            subscription?.cancel()
            subscription = nil
            throw error
        }
    }

    // MARK: System UI

    override public var prefersStatusBarHidden: Bool { true }
    override public var prefersHomeIndicatorAutoHidden: Bool { true }
    override public var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        contentView.frame = view.bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentView)

        overlay.setTitle(NSLocalizedString("session.tapToResume", comment: "Overlay shown while a game is paused"), for: .normal)
        overlay.titleLabel?.font = .preferredFont(forTextStyle: .title2)
        overlay.tintColor = .white
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addAction(UIAction { [weak self] _ in self?.resumeSession() }, for: .primaryActionTriggered)
        overlay.isHidden = !isResumeOverlayVisible
        view.addSubview(overlay)

        menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menuButton.tintColor = .white
        menuButton.accessibilityLabel = NSLocalizedString("session.menu", comment: "Game session menu button")
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIAction(title: NSLocalizedString("session.resume", comment: "Resume the paused game"),
                     image: UIImage(systemName: "play.fill")) { [weak self] _ in self?.resumeSession() },
            UIAction(title: NSLocalizedString("session.quit", comment: "End the game session"),
                     image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                Task { await self?.quit() }
            },
        ])
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            menuButton.widthAnchor.constraint(equalToConstant: 44),
            menuButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        // Stays tappable, out of the game's way.
        UIView.animate(withDuration: 0.4, delay: 3) { self.menuButton.alpha = 0.2 }
    }

    // MARK: Events

    func handle(_ event: SceneEvent) {
        guard session.isLive else { return }
        switch event {
        case .willDeactivate:
            pauseSession()
        case .didEnterBackground:
            session.inBackgroundTask { [weak self] end in
                guard let self, session.isLive else { return end() }
                // The phase says `background` only once nothing touches the GPU: drain
                // again, in case the pause's wait timed out.
                pauseSession()
                if !renderGate.close() {
                    session.add(.renderGateTimeout)
                }
                session.setPhase(.background)
                session.flushSettings()
                session.add(.sessionBackgrounded)
                end()
            }
        case .didActivate:
            session.setPhase(.running)
            setOverlayVisible(true)
        case .audioInterruptionBegan:
            session.add(.audioInterrupted)
            pauseSession()
        case .audioInterruptionEnded:
            setOverlayVisible(true)
        case .audioOldDeviceUnavailable:
            pauseSession()
            setOverlayVisible(true)
        case .memoryWarning:
            session.add(.memoryWarning)
            session.recordMemorySample()
        }
    }

    /// Once per pause episode: close the gate, then pause the runtime.
    private func pauseSession() {
        guard !isPaused else { return }
        isPaused = true
        if !renderGate.close() {
            session.add(.renderGateTimeout)
        }
        session.runtime?.pause()
        session.setSamplesPaused(true)
        session.add(.sessionPaused)
    }

    /// The overlay tap and the menu's Resume.
    func resumeSession() {
        guard session.isLive else { return }
        if isPaused {
            renderGate.open()
            session.runtime?.resume()
            session.setSamplesPaused(false)
            session.add(.sessionResumed)
            isPaused = false
        }
        setOverlayVisible(false)
    }

    private func setOverlayVisible(_ visible: Bool) {
        isResumeOverlayVisible = visible
        if isViewLoaded { overlay.isHidden = !visible }
    }

    // MARK: Ending

    /// The menu's Quit: stops the runtime, ends the session, dismisses.
    func quit() async {
        await finish(runtimeReportedEnd: false, error: nil)
    }

    public func runtimeDidEnd(error: (any Error)?) {
        guard !session.runtimeEnded else { return }
        if let error {
            session.add(.runtimeError(code: Int64((error as NSError).code)))
            endError = endError ?? error
        }
        // No more pause, resume or stop calls reach the runtime from here on.
        session.markRuntimeEnded()
        Task { await finish(runtimeReportedEnd: true, error: error) }
    }

    private func finish(runtimeReportedEnd: Bool, error: (any Error)?) async {
        if let error { endError = endError ?? error }
        guard !session.hasEnded else { return }
        subscription?.cancel()
        subscription = nil
        if !renderGate.close() {
            session.add(.renderGateTimeout)
        }
        await session.end(runtimeReportedEnd: runtimeReportedEnd)
        if presentingViewController != nil {
            dismiss(animated: true)
        }
        onFinish?(endError)
    }
}

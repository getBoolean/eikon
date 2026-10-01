import CryptoKit
import Darwin
import EikonCore
import EikonKit
import Metal
import QuartzCore
import UIKit

/// The developer test session: a synthetic game that needs no drive.
enum TestSession {
    /// Fixed and derived from a constant, so it encodes nothing about any game; its first 8
    /// characters are the report id in crash issues.
    static let gameID: GameID = {
        var bytes = Array(SHA256.hash(data: Data("eikon.test-session".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return GameID(uuid: UUID(uuid: uuid))
    }()

    /// A scratch root under Caches; no game files.
    static func game() throws -> LaunchableGame {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("test-session", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let detection = DetectionResult(engine: .unknown, details: EngineDetails(), gameRoot: "", executables: [:],
                                        keyFile: nil, detectorVersion: GameDetector.version)
        return LaunchableGame(gameID: gameID, root: root, detection: detection, route: TestPatternRuntime.route)
    }
}

enum TestPatternError: Error {
    case metalUnavailable
}

/// Developer only: draws an animated pattern from its own render thread, holding the render
/// gate around every commit, and counts command-buffer errors. Any commit while the app is
/// inactive shows up as an error. Not a route: never registered, so `route` (which the
/// protocol requires) is never offered; the session records its route as "test".
@MainActor
class TestPatternRuntime: GameRuntime {
    /// A placeholder the protocol requires: never registered, and the session records its
    /// route as `SessionRecord.testRoute` (`SessionPresenter.launchTest`), so nothing reads it.
    nonisolated static var route: RouteID { .wineFEX }

    nonisolated static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck { .ok }

    /// Seconds after launch until the app aborts; nil for a normal session.
    class var crashDelay: TimeInterval? { nil }

    private let shared = RenderShared()
    private var metalView: MetalView?
    private var errorLabel: UILabel?
    private var labelTimer: Timer?
    private var renderThread: Thread?
    private var crash: DispatchWorkItem?
    private var stopped = false

    required init() {}

    func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws {
        assert(game.gameID == TestSession.gameID, "the test pattern runs only the test session")
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TestPatternError.metalUnavailable
        }
        let view = MetalView(shared: shared)
        view.frame = host.contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.metalLayer.device = device
        view.metalLayer.pixelFormat = .bgra8Unorm
        view.metalLayer.framebufferOnly = true
        host.contentView.addSubview(view)
        metalView = view

        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.contentView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: host.contentView.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        errorLabel = label
        let shared = shared
        label.text = L10n.format("developer.testPattern.errors", shared.errorCount)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak label] _ in
            MainActor.assumeIsolated {
                label?.text = L10n.format("developer.testPattern.errors", shared.errorCount)
            }
        }
        // Common modes, so the count keeps updating while the session menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer

        let target = RenderTarget(layer: view.metalLayer, queue: queue, gate: host.renderGate, shared: shared)
        let thread = Thread { target.run() }
        thread.name = "eikon.test-pattern.render"
        renderThread = thread
        thread.start()

        if let delay = Self.crashDelay {
            let crash = DispatchWorkItem { abort() }
            self.crash = crash
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: crash)
        }
    }

    func pause() {
        shared.setPaused(true)
    }

    func resume() {
        shared.setPaused(false)
    }

    /// Waits for the render thread at most about a second, never unbounded, and off the
    /// main thread. A second call returns at once. A thread still running after the wait
    /// can't commit: the host closed the gate before stopping, and the thread holds the gate
    /// strongly, so it outlives this runtime.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        // A session quit before the simulated crash must not abort the app later.
        crash?.cancel()
        crash = nil
        shared.requestStop()
        if renderThread != nil {
            let exited = shared.exited
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = exited.wait(timeout: .now() + 1)
                    continuation.resume()
                }
            }
        }
        renderThread = nil
        labelTimer?.invalidate()
        labelTimer = nil
        errorLabel?.removeFromSuperview()
        errorLabel = nil
        metalView?.removeFromSuperview()
        metalView = nil
    }
}

/// The simulated-crash session: the same pattern, then `abort()` about 5 s after launch.
final class CrashingTestPatternRuntime: TestPatternRuntime {
    override class var crashDelay: TimeInterval? { 5 }
}

/// Everything the render thread shares with the main thread, under one lock.
private final class RenderShared: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var paused = false
    private var size = CGSize.zero
    private var errors = 0
    private var clock: TimeInterval = 0
    private var lastTick: TimeInterval?
    let exited = DispatchSemaphore(value: 0)

    var isStopRequested: Bool { lock.withLock { stopRequested } }
    var drawableSize: CGSize {
        get { lock.withLock { size } }
        set { lock.withLock { size = newValue } }
    }
    var errorCount: Int { lock.withLock { errors } }

    func requestStop() { lock.withLock { stopRequested = true } }
    /// No frames run while paused (the gate is closed), so the clock restarts from the next
    /// frame instead of counting the pause.
    func setPaused(_ value: Bool) {
        lock.withLock {
            paused = value
            lastTick = nil
        }
    }
    func addError() { lock.withLock { errors += 1 } }

    /// Animation time, frozen while paused.
    func tick(now: TimeInterval) -> TimeInterval {
        lock.withLock {
            if let lastTick, !paused { clock += now - lastTick }
            lastTick = now
            return clock
        }
    }
}

/// What the render thread holds. It only takes drawables from the layer; the main thread
/// configures and sizes it.
private final class RenderTarget: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let queue: any MTLCommandQueue
    private let gate: RenderGate
    private let shared: RenderShared

    init(layer: CAMetalLayer, queue: any MTLCommandQueue, gate: RenderGate, shared: RenderShared) {
        self.layer = layer
        self.queue = queue
        self.gate = gate
        self.shared = shared
    }

    func run() {
        defer { shared.exited.signal() }
        while !shared.isStopRequested {
            autoreleasepool { frame() }
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
    }

    /// The drawable comes before the gate, so a blocking `nextDrawable` never holds the gate
    /// open while the host is closing it. Nothing here waits on the main thread.
    private func frame() {
        let size = shared.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        guard let drawable = layer.nextDrawable() else { return }
        guard gate.enter() else { return }
        defer { gate.leave() }

        let time = shared.tick(now: ProcessInfo.processInfo.systemUptime)
        // The pattern: a clear color cycling through hues.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.5 + 0.5 * sin(time), green: 0.5 + 0.5 * sin(time + 2.1),
                                                            blue: 0.5 + 0.5 * sin(time + 4.2), alpha: 1)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        encoder.endEncoding()
        let shared = shared
        buffer.addCompletedHandler { buffer in
            if buffer.status == .error || buffer.error != nil { shared.addError() }
        }
        buffer.present(drawable)
        buffer.commit()
    }
}

/// A view backed by a `CAMetalLayer`; its size goes to the render thread.
private final class MetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let shared: RenderShared
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(shared: RenderShared) {
        self.shared = shared
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scale = window?.screen.scale { contentScaleFactor = scale }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
        metalLayer.drawableSize = size
        shared.drawableSize = size
    }
}

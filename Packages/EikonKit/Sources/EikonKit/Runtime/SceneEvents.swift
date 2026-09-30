import AVFAudio
import Foundation
import UIKit

public enum SceneEvent: Sendable, Equatable {
    case willDeactivate, didEnterBackground, didActivate
    case audioInterruptionBegan, audioInterruptionEnded
    case audioOldDeviceUnavailable
    case memoryWarning
}

/// Scene, audio and memory notifications for the session host.
@MainActor
public protocol SceneEvents: AnyObject {
    /// Starts delivering events on the main actor. Delivery stops when the returned
    /// subscription is cancelled or released.
    func subscribe(_ handler: @escaping @MainActor (SceneEvent) -> Void) -> SceneEventsSubscription
}

public final class SceneEventsSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    deinit {
        cancel()
    }

    public func cancel() {
        let cancel = lock.withLock {
            defer { onCancel = nil }
            return onCancel
        }
        cancel?()
    }
}

/// Scene notifications from the host's own scene only, so another window on iPad doesn't
/// pause the game; audio interruptions and route changes; memory warnings.
@MainActor
public final class LiveSceneEvents: SceneEvents {
    private let scene: UIWindowScene

    public init(scene: UIWindowScene) {
        self.scene = scene
    }

    public func subscribe(_ handler: @escaping @MainActor (SceneEvent) -> Void) -> SceneEventsSubscription {
        let center = NotificationCenter.default
        let observers = Observers()
        func observe(_ name: Notification.Name, object: AnyObject?, _ event: @escaping @Sendable (Notification) -> SceneEvent?) {
            observers.add(center.addObserver(forName: name, object: object, queue: .main) { notification in
                guard let event = event(notification) else { return }
                MainActor.assumeIsolated { handler(event) }
            })
        }

        observe(UIScene.willDeactivateNotification, object: scene) { _ in .willDeactivate }
        observe(UIScene.didEnterBackgroundNotification, object: scene) { _ in .didEnterBackground }
        observe(UIScene.didActivateNotification, object: scene) { _ in .didActivate }
        observe(AVAudioSession.interruptionNotification, object: nil) { notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began: return .audioInterruptionBegan
            case .ended: return .audioInterruptionEnded
            case nil: return nil
            @unknown default: return nil
            }
        }
        observe(AVAudioSession.routeChangeNotification, object: nil) { notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            return raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
                ? .audioOldDeviceUnavailable : nil
        }
        observe(UIApplication.didReceiveMemoryWarningNotification, object: nil) { _ in .memoryWarning }

        return SceneEventsSubscription { observers.removeAll(from: center) }
    }
}

private final class Observers: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []

    func add(_ token: any NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    func removeAll(from center: NotificationCenter) {
        let removed = lock.withLock {
            defer { tokens = [] }
            return tokens
        }
        removed.forEach(center.removeObserver)
    }
}

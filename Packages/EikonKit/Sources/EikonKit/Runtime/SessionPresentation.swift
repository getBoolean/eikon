import UIKit

/// Where a session host is presented from: the end of the root's presentation chain, so
/// a sheet that is up doesn't block it.
@MainActor
public enum SessionPresentation {
    public static func topmostPresented(from root: UIViewController) -> UIViewController {
        var controller = root
        while let next = controller.presentedViewController {
            controller = next
        }
        return controller
    }

    /// Returns once the presentation has finished, so a session that fails to start can
    /// still dismiss its host.
    public static func present(_ host: GameSessionHostViewController, from root: UIViewController,
                               animated: Bool = true) async {
        await withCheckedContinuation { continuation in
            topmostPresented(from: root).present(host, animated: animated) { continuation.resume() }
        }
    }
}

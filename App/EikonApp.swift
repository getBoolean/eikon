import EikonKit
import SwiftUI

@main
struct EikonApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch state.services {
                case .success(let services):
                    RootView(services: services)
                case .failure(let failure):
                    StartupFailureView(failure: failure, onStartOver: state.startOverSecret)
                }
            }
            .onChange(of: scenePhase) { phase in
                state.sceneChanged(phase)
            }
        }
    }
}

/// Launch and scene phases. Order matters (plan §12.1): JIT facts first, so crash outcomes
/// and reports see them; then `AppServices` registers runtimes, creates the stores and
/// controllers (consuming the last session), cleans interrupted imports and scans.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var services: Result<AppServices, StartupFailure>

    init() {
        JITController.shared.gatherFacts()
        services = AppServices.start(jit: .shared)
    }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            JITController.shared.sceneBecameActive()
            if case .success(let services) = services { services.sceneBecameActive() }
        case .background:
            if case .success(let services) = services { services.settings.flush() }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// The user chose to start over with an unreadable library secret: keep it as a backup
    /// beside it, then open the app's data again (a new secret is made).
    func startOverSecret() {
        guard case .failure(let failure) = services, let secret = failure.unreadableSecret else { return }
        let backup = secret.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
        guard (try? FileManager.default.moveItem(at: secret, to: backup)) != nil else { return }
        services = AppServices.start(jit: .shared)
    }
}

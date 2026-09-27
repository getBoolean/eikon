import EikonKit
import SwiftUI

@main
struct EikonApp: App {
    @ObservedObject private var jit = JITController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        JITController.shared.gatherFacts()
    }

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environmentObject(jit)
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        jit.sceneBecameActive()
                    }
                }
        }
    }
}

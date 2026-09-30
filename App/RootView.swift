import EikonKit
import SwiftUI

enum RootDestination: Hashable {
    case library, drives, device, credits
}

/// A sidebar with four destinations: two columns on iPad, a stack on iPhone. Opens on
/// Library. On iOS 15 iPad the sidebar hides in portrait and selection can reset
/// (accepted; see plan §19).
struct RootView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var jit: JITController
    @State private var selection: RootDestination? = .library

    init(services: AppServices) {
        self.services = services
        jit = services.jit
    }

    var body: some View {
        NavigationView {
            List {
                link(.library, "library.title", systemImage: "books.vertical")
                link(.drives, "drives.title", systemImage: "externaldrive")
                link(.device, "status.title", systemImage: "info.circle")
                link(.credits, "credits.title", systemImage: "heart")
            }
            .listStyle(.sidebar)
            .navigationTitle(Text(verbatim: "Eikon"))

            // The detail shown before anything is picked.
            destination(.library)
        }
        .navigationViewStyle(.columns)
        .alert(Text("storage.unreadable.title"), isPresented: Binding(
            get: { !services.pendingUnreadable.isEmpty },
            set: { _ in }
        )) {
            Button("storage.unreadable.keep", role: .cancel) {
                services.keepUnreadable()
            }
            Button("storage.unreadable.startOver", role: .destructive) {
                services.startOverUnreadable()
            }
        } message: {
            Text(unreadableMessage)
        }
    }

    private var unreadableMessage: String {
        let list = L10n.format("storage.unreadable.message",
                               services.pendingUnreadable.map(appRelative).joined(separator: "\n"))
        return services.startOverFailed ? L10n.string("storage.unreadable.stillUnreadable") + "\n\n" + list : list
    }

    private func link(_ target: RootDestination, _ titleKey: LocalizedStringKey, systemImage: String) -> some View {
        NavigationLink(tag: target, selection: $selection) {
            destination(target)
        } label: {
            Label(titleKey, systemImage: systemImage)
        }
    }

    /// Sections 13–15 replace the placeholders with LibraryView, DrivesView and CreditsView.
    @ViewBuilder
    private func destination(_ target: RootDestination) -> some View {
        switch target {
        case .library: DestinationPlaceholder(titleKey: "library.title")
        case .drives: DestinationPlaceholder(titleKey: "drives.title")
        case .device: StatusView(controller: jit)
        case .credits: DestinationPlaceholder(titleKey: "credits.title")
        }
    }

}

/// Where a file lives inside the app's data folder; never a game title.
func appRelative(_ url: URL) -> String {
    let base = LibraryPaths.support.resolvingSymlinksInPath().path + "/"
    let path = url.resolvingSymlinksInPath().path
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
}

/// Stands in for a destination another section builds.
private struct DestinationPlaceholder: View {
    let titleKey: LocalizedStringKey

    var body: some View {
        List {}
            .navigationTitle(Text(titleKey))
    }
}

/// Shown instead of the app when its data can't be opened. An unreadable library secret
/// is the user's to fix or start over; nothing is replaced on its own.
struct StartupFailureView: View {
    let failure: StartupFailure
    let onStartOver: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            if let secret = failure.unreadableSecret {
                Text("storage.unreadable.title")
                    .font(.headline)
                Text(L10n.format("storage.unreadable.secretMessage", appRelative(secret)))
                    .multilineTextAlignment(.center)
                Button("storage.unreadable.startOver", role: .destructive, action: onStartOver)
                    .buttonStyle(.bordered)
            } else {
                Text("app.startupFailed.title")
                    .font(.headline)
                Text(L10n.format("app.startupFailed.message", failure.code))
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

import EikonCore
import EikonKit
import SwiftUI

/// The Library destination, where the app opens: the crash banner, every game, folders
/// still settling, and folders where no game was found.
struct LibraryView: View {
    let services: AppServices
    @ObservedObject var library: LibraryController
    @ObservedObject var crashes: CrashReportController
    @State private var importing = false

    init(services: AppServices) {
        self.services = services
        library = services.library
        crashes = services.crashes
    }

    var body: some View {
        let drives = library.drives
        LibraryContent(
            games: library.games.map { game in
                LibraryContent.Game(id: game.id, row: LibraryRowContent(
                    game: game, decision: library.decisions[game.id], drives: drives, progress: library.fingerprintProgress))
            },
            settling: library.settling.map { location in
                LibraryContent.Folder(id: location.id, row: LibraryRowContent(
                    name: location.folderName, engine: location.detection?.engine, architectures: [], badge: nil,
                    onOtherDrivesOnly: drives.first { $0.id == location.driveID }?.drive.kind != .builtIn,
                    status: location.identity == .waitingForQuiescence ? .waitingForCopy : .identifying))
            },
            unrecognized: library.unrecognized.map { LibraryContent.Folder(id: $0.id, name: $0.folderName) },
            banner: crashes.banner,
            clipboardNotice: crashes.clipboardNotice,
            onImport: { importing = true },
            onRefresh: { await library.rescan() },
            onTryAlternative: { crashes.tryAlternative($0) },
            onReport: { crashes.report($0.entry) },
            onDismissBanner: { crashes.dismiss() },
            detail: { GameDetailView(services: services, gameID: $0) })
        .sheet(isPresented: $importing) {
            ImportFlow(library: library)
        }
    }
}

/// The Library screen for one snapshot. The preview renders this directly.
struct LibraryContent<Detail: View>: View {
    struct Game: Identifiable {
        var id: GameID
        var row: LibraryRowContent
    }

    /// A folder without a game id: still settling (with a row), or not recognized (name only).
    struct Folder: Identifiable {
        var id: UUID
        var name: String
        var row: LibraryRowContent?

        init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }

        init(id: UUID, row: LibraryRowContent) {
            self.id = id
            name = row.name
            self.row = row
        }
    }

    let games: [Game]
    let settling: [Folder]
    let unrecognized: [Folder]
    let banner: CrashBanner?
    let clipboardNotice: Bool
    let onImport: () -> Void
    let onRefresh: @MainActor () async -> Void
    let onTryAlternative: (CrashBanner) -> Void
    let onReport: (CrashBanner) -> Void
    let onDismissBanner: () -> Void
    let detail: (GameID) -> Detail

    var body: some View {
        List {
            if let banner {
                Section {
                    CrashBannerView(banner: banner, clipboardNotice: clipboardNotice,
                                    onTryAlternative: { onTryAlternative(banner) },
                                    onReport: { onReport(banner) }, onDismiss: onDismissBanner)
                }
            }
            if games.isEmpty && settling.isEmpty && unrecognized.isEmpty {
                Section {
                    LibraryEmptyState()
                }
            }
            if !games.isEmpty || !settling.isEmpty {
                Section {
                    ForEach(games) { game in
                        NavigationLink(destination: detail(game.id)) {
                            LibraryRow(content: game.row)
                        }
                    }
                    ForEach(settling) { folder in
                        if let row = folder.row { LibraryRow(content: row) }
                    }
                }
            }
            if !unrecognized.isEmpty {
                Section(header: Text("library.unrecognized.title"), footer: Text("library.unrecognized.hint")) {
                    ForEach(unrecognized) { folder in
                        Label {
                            Text(verbatim: folder.name)
                        } icon: {
                            Image(systemName: "questionmark.folder")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await onRefresh() }
        .navigationTitle(Text("library.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) {
                    Label("import.button", systemImage: "plus")
                }
            }
        }
    }
}

/// No games yet: where games come from.
private struct LibraryEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("library.empty.title")
                .font(.headline)
            Text(L10n.format("library.empty.builtIn", GameStrings.builtInDriveName))
            Text("library.empty.drives")
            Text("library.empty.import")
        }
        .padding(.vertical, 8)
    }
}

#if DEBUG
struct LibraryContent_Previews: PreviewProvider {
    static func content(games: [LibraryContent<Text>.Game] = [], unrecognized: [LibraryContent<Text>.Folder] = [],
                        banner: CrashBanner? = nil) -> some View {
        NavigationView {
            LibraryContent(games: games, settling: [], unrecognized: unrecognized, banner: banner,
                           clipboardNotice: false, onImport: {}, onRefresh: {}, onTryAlternative: { _ in },
                           onReport: { _ in }, onDismissBanner: {}, detail: { _ in Text(verbatim: "Detail") })
        }
        .navigationViewStyle(.stack)
    }

    static let games = (1...3).map { index in
        LibraryContent<Text>.Game(id: .random(), row: LibraryRowContent(
            name: "Sample Game \(index)", engine: .renpy, architectures: [], badge: .planned, onOtherDrivesOnly: false,
            status: nil))
    }

    static var previews: some View {
        content()
        content(games: games)
        content(games: games, unrecognized: [.init(id: UUID(), name: "Sample Folder")])
        content(games: games, banner: CrashBannerView_Previews.banner(.likelyMemoryKill, alternative: .wineBox64))
    }
}
#endif

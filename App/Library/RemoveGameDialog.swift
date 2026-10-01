import EikonCore
import EikonKit
import SwiftUI

/// Removes a game: optionally deletes chosen folders on connected drives, and optionally
/// its settings and saves everywhere. With neither, the game's locations are forgotten.
struct RemoveGameDialog: View {
    @ObservedObject var library: LibraryController
    let game: LibraryGame
    let onRemoved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sizes: [UUID: Int64] = [:]
    @State private var removing = false

    var body: some View {
        RemoveGameContent(entries: entries, removing: removing, onConfirm: remove, onCancel: { dismiss() })
            .task { await measure() }
    }

    private var entries: [RemoveGameContent.Entry] {
        game.locations.map { location in
            let summary = library.drives.first { $0.id == location.driveID }
            let availability: RemoveGameContent.Availability =
                location.identity == .missing ? .missing : summary?.state == .available ? .deletable : .notConnected
            return RemoveGameContent.Entry(id: location.id, folder: location.folderName,
                                           drive: summary.map { GameStrings.driveLabel($0.drive) } ?? "",
                                           availability: availability, size: sizes[location.id])
        }
    }

    private func remove(_ locations: Set<UUID>, deleteData: Bool) {
        removing = true
        Task {
            await library.remove(game: game.id, deleteLocations: locations, deleteData: deleteData)
            // The detail screen pops once this sheet has gone.
            onRemoved()
            dismiss()
        }
    }

    /// Each deletable folder's size, measured off the main actor.
    private func measure() async {
        let manager = library.driveManager
        let contents = library.context.index.contents
        let targets = entries.filter { $0.availability == .deletable }.compactMap { entry -> (UUID, String, GameDrive)? in
            guard let location = contents.location(entry.id), let drive = contents.drive(location.driveID) else { return nil }
            return (entry.id, location.folderName, drive)
        }
        sizes = await Task.detached {
            var sizes: [UUID: Int64] = [:]
            for (id, folder, drive) in targets {
                guard let token = manager.open(drive) else { continue }
                defer { token.close() }
                sizes[id] = folderSize(token.url.appendingPathComponent(folder, isDirectory: true))
            }
            return sizes
        }.value
    }
}

/// Total size of the regular files under `folder`; symlinks aren't followed.
private func folderSize(_ folder: URL) -> Int64 {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
        total += Int64(values.fileSize ?? 0)
    }
    return total
}

/// The dialog for one set of locations. The preview renders this directly.
struct RemoveGameContent: View {
    enum Availability {
        case deletable, notConnected, missing
    }

    struct Entry: Identifiable {
        var id: UUID
        var folder: String
        var drive: String
        var availability: Availability
        var size: Int64?
    }

    let entries: [Entry]
    let removing: Bool
    let onConfirm: (Set<UUID>, Bool) -> Void
    let onCancel: () -> Void
    @State private var chosen: Set<UUID> = []
    @State private var deleteData = false
    @State private var confirmingDelete = false

    /// Some folder stays on a drive, so the game comes back with it.
    private var keepsFiles: Bool {
        entries.contains { $0.availability != .missing && !chosen.contains($0.id) }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("game.remove.section.files"),
                        footer: entries.contains { $0.availability == .notConnected } ? Text("game.remove.notConnected.footer") : nil) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                Section(footer: Text("game.remove.data.footer")) {
                    Toggle("game.remove.data", isOn: $deleteData)
                }
                if keepsFiles {
                    Section {
                        Text("game.remove.reappears")
                            .foregroundColor(.secondary)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        if chosen.isEmpty {
                            onConfirm(chosen, deleteData)
                        } else {
                            confirmingDelete = true
                        }
                    } label: {
                        Text("game.remove.confirm")
                    }
                    .disabled(removing)
                }
            }
            .navigationTitle(Text("game.remove.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("app.cancel", action: onCancel)
                }
            }
            .alert(Text("game.remove.deleteFiles.title"), isPresented: $confirmingDelete) {
                Button("game.remove.deleteFiles.confirm", role: .destructive) { onConfirm(chosen, deleteData) }
                Button("app.cancel", role: .cancel) {}
            } message: {
                Text(L10n.count("game.remove.deleteFiles.message", chosen.count))
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(removing)
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: entry.folder)
            Text(verbatim: ([entry.drive] + (entry.size.map { [GameStrings.bytes($0)] } ?? []))
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        switch entry.availability {
        case .deletable:
            Toggle(isOn: Binding(
                get: { chosen.contains(entry.id) },
                set: { if $0 { chosen.insert(entry.id) } else { chosen.remove(entry.id) } }
            )) { label }
        case .notConnected:
            HStack {
                label
                Spacer()
                Text("drives.state.notConnected")
                    .foregroundColor(.secondary)
            }
        case .missing:
            HStack {
                label
                Spacer()
                Text("library.status.missing")
                    .foregroundColor(.secondary)
            }
        }
    }
}

#if DEBUG
struct RemoveGameContent_Previews: PreviewProvider {
    static var previews: some View {
        RemoveGameContent(entries: [
            .init(id: UUID(), folder: "Sample Game", drive: "On My iPad/Eikon", availability: .deletable,
                  size: 1_500_000_000),
            .init(id: UUID(), folder: "Sample Game", drive: "Sample Drive", availability: .notConnected, size: nil),
            .init(id: UUID(), folder: "Sample Game", drive: "Sample Drive", availability: .missing, size: nil),
        ], removing: false, onConfirm: { _, _ in }, onCancel: {})
        RemoveGameContent(entries: [
            .init(id: UUID(), folder: "Sample Game", drive: "On My iPad/Eikon", availability: .deletable, size: 4096),
        ], removing: false, onConfirm: { _, _ in }, onCancel: {})
    }
}
#endif

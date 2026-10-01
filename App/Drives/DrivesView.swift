import EikonCore
import EikonKit
import SwiftUI
import UniformTypeIdentifiers

/// The Game drives destination: the built-in drive, the folders the user added, and
/// adding, finding again and removing them.
struct DrivesView: View {
    /// What the one folder picker is for; several `.fileImporter`s on one view misbehave
    /// on iOS 15.
    private enum Picking: Equatable {
        case add
        case relink(UUID)
    }

    @ObservedObject var library: LibraryController
    private struct PendingRelink {
        var drive: UUID
        var url: URL
    }

    /// Kept apart from `showPicker`: the picker may reset its binding before its completion.
    @State private var picking: Picking?
    @State private var showPicker = false
    @State private var refusal: DriveRefusal?
    @State private var pendingRelink: PendingRelink?
    @State private var confirmingRelink = false
    @State private var removing: DriveSummary?
    @State private var confirmingRemove = false

    var body: some View {
        DrivesContent(
            drives: library.drives,
            refusal: refusal,
            onAdd: { pick(.add) },
            onRelink: { pick(.relink($0.id)) },
            onRemove: { drive in
                removing = drive
                confirmingRemove = true
            })
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            let purpose = picking
            picking = nil
            guard case .success(let url) = result, let purpose else { return }
            switch purpose {
            case .add: add(url)
            case .relink(let id): relink(id, to: url, confirmed: false)
            }
        }
        .alert(Text("drives.relink.confirm.title"), isPresented: $confirmingRelink, presenting: pendingRelink) { pending in
            Button("drives.relink.confirm.use") { relink(pending.drive, to: pending.url, confirmed: true) }
            Button("app.cancel", role: .cancel) {}
        } message: { _ in
            Text("drives.relink.confirm.message")
        }
        .alert(Text("drives.remove.title"), isPresented: $confirmingRemove, presenting: removing) { drive in
            Button("drives.remove.confirm", role: .destructive) { library.removeDrive(drive.id) }
            Button("app.cancel", role: .cancel) {}
        } message: { _ in
            Text("drives.remove.message")
        }
    }

    private func pick(_ purpose: Picking) {
        picking = purpose
        showPicker = true
    }

    private func add(_ url: URL) {
        Task {
            if case .failure(let reason) = await library.addDrive(url) {
                refusal = reason
            } else {
                refusal = nil
            }
        }
    }

    private func relink(_ id: UUID, to url: URL, confirmed: Bool) {
        Task {
            switch await library.relinkDrive(id, to: url, confirmed: confirmed) {
            case .relinked: refusal = nil
            case .needsConfirmation:
                pendingRelink = PendingRelink(drive: id, url: url)
                confirmingRelink = true
            case .refused(let reason): refusal = reason
            }
        }
    }
}

/// The drives list for one snapshot. The preview renders this directly.
struct DrivesContent: View {
    let drives: [DriveSummary]
    /// Why the last folder picked couldn't be used.
    let refusal: DriveRefusal?
    let onAdd: () -> Void
    let onRelink: (DriveSummary) -> Void
    let onRemove: (DriveSummary) -> Void

    var body: some View {
        List {
            ForEach(drives.filter { $0.drive.kind == .builtIn }) { summary in
                Section(footer: Text("drives.builtIn.footer")) {
                    DriveRow(summary: summary)
                }
            }
            Section(header: Text("drives.section.other"), footer: Text("drives.add.footer")) {
                ForEach(drives.filter { $0.drive.kind != .builtIn }) { summary in
                    DriveRow(summary: summary)
                        .contextMenu {
                            Button { onRelink(summary) } label: { Label("drives.relink", systemImage: "folder") }
                            Button(role: .destructive) { onRemove(summary) } label: {
                                Label("drives.remove", systemImage: "minus.circle")
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { onRemove(summary) } label: { Text("drives.remove") }
                            Button { onRelink(summary) } label: { Text("drives.relink") }
                        }
                    if summary.state == .needsRelink {
                        Button("drives.relink") { onRelink(summary) }
                    }
                }
                Button(action: onAdd) {
                    Label("drives.add", systemImage: "plus")
                }
                if let refusal {
                    Text(LibraryStrings.refusalKey(refusal))
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("drives.title"))
    }
}

private struct DriveRow: View {
    let summary: DriveSummary

    var body: some View {
        HStack {
            Image(systemName: summary.drive.kind == .builtIn ? "ipad.and.iphone" : "externaldrive")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: GameStrings.driveLabel(summary.drive))
                Text(details)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if summary.drive.kind != .builtIn {
                Text(LibraryStrings.driveStateKey(summary.state))
                    .font(.caption)
                    .foregroundColor(summary.state == .available ? .secondary : .orange)
            }
        }
    }

    private var details: String {
        var parts = [L10n.count("library.count.games", summary.gameCount)]
        if summary.state == .available, let free = summary.freeBytes {
            parts.append(L10n.format("drives.free", GameStrings.bytes(free)))
        }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
struct DrivesContent_Previews: PreviewProvider {
    static let drives: [DriveSummary] = [
        DriveSummary(drive: GameDrive(id: UUID(), kind: .builtIn, label: "Documents"), state: .available,
                     freeBytes: 20_000_000_000, gameCount: 3),
        DriveSummary(drive: GameDrive(id: UUID(), kind: .folder(bookmark: Data()), label: "Sample Drive"),
                     state: .available, freeBytes: 500_000_000_000, gameCount: 1),
        DriveSummary(drive: GameDrive(id: UUID(), kind: .folder(bookmark: Data()), label: "Sample Drive 2"),
                     state: .notConnected, freeBytes: nil, gameCount: 4),
        DriveSummary(drive: GameDrive(id: UUID(), kind: .folder(bookmark: Data()), label: "Sample Drive 3"),
                     state: .needsRelink, freeBytes: nil, gameCount: 0),
    ]

    static var previews: some View {
        NavigationView {
            DrivesContent(drives: drives, refusal: nil, onAdd: {}, onRelink: { _ in }, onRemove: { _ in })
        }
        .navigationViewStyle(.stack)
        NavigationView {
            DrivesContent(drives: Array(drives.prefix(1)), refusal: .iCloud, onAdd: {}, onRelink: { _ in },
                          onRemove: { _ in })
        }
        .navigationViewStyle(.stack)
    }
}
#endif

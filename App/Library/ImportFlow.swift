import EikonCore
import EikonKit
import SwiftUI
import UniformTypeIdentifiers

/// Where the import sheet is.
enum ImportStep: Equatable {
    case choose
    /// Looking for a game in the picked folder and measuring it.
    case checking
    case noGame
    case pickDrive
    case nameClash
    /// Typing another name; `taken` after the last one was refused.
    case rename(taken: Bool)
    case insufficientSpace
    case copying
    /// Failed or cancelled; the coordinator has already removed its staging folder.
    case finished(ImportOutcome)
}

/// Pick a game folder, pick a drive, copy it there. The coordinator holds the folder's
/// access, runs detection and does the name and space checks.
struct ImportFlow: View {
    @ObservedObject var library: LibraryController
    @Environment(\.dismiss) private var dismiss
    @State private var step = ImportStep.choose
    @State private var picking = false
    @State private var source: URL?
    @State private var size: UInt64?
    @State private var driveID: UUID?
    @State private var newName = ""

    var body: some View {
        ImportContent(
            step: step,
            sourceName: source?.lastPathComponent ?? "",
            size: size,
            drives: library.drives.filter { $0.state == .available },
            driveID: $driveID,
            newName: $newName,
            progress: library.importProgress,
            onChoose: { picking = true },
            onChooseDrive: { step = .pickDrive },
            onImport: { start(.original) },
            onReplace: { start(.replaceExisting) },
            onRename: {
                newName = source?.lastPathComponent ?? ""
                step = .rename(taken: false)
            },
            onConfirmRename: { start(.rename(newName)) },
            onCancel: {
                if step == .copying {
                    library.cancelImport()
                } else {
                    dismiss()
                }
            })
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            check(url)
        }
        .interactiveDismissDisabled(step == .copying || step == .checking)
    }

    /// Detection and the copy's size, off the main actor.
    private func check(_ url: URL) {
        source = url
        step = .checking
        let importer = library.importer
        Task {
            let measured = await Task.detached { importer.size(of: url) }.value
            guard let measured else {
                step = .noGame
                return
            }
            size = measured
            let available = library.drives.filter { $0.state == .available }
            if driveID == nil || !available.contains(where: { $0.id == driveID }) {
                driveID = (available.first { $0.drive.kind == .builtIn } ?? available.first)?.id
            }
            step = .pickDrive
        }
    }

    private func start(_ naming: ImportNaming) {
        guard let source, let driveID else { return }
        step = .copying
        Task {
            let outcome = await library.importGame(from: source, to: driveID, naming: naming)
            switch outcome {
            case .imported: dismiss()
            case .nameClash: step = .nameClash
            case .nameTaken: step = .rename(taken: true)
            case .insufficientSpace: step = .insufficientSpace
            case .noGameFound: step = .noGame
            case .driveUnavailable, .cancelled, .failed: step = .finished(outcome)
            }
        }
    }
}

/// The sheet at one step. The preview renders this directly.
struct ImportContent: View {
    let step: ImportStep
    let sourceName: String
    let size: UInt64?
    let drives: [DriveSummary]
    @Binding var driveID: UUID?
    @Binding var newName: String
    let progress: Double?
    let onChoose: () -> Void
    let onChooseDrive: () -> Void
    let onImport: () -> Void
    let onReplace: () -> Void
    let onRename: () -> Void
    let onConfirmRename: () -> Void
    let onCancel: () -> Void

    private var drive: DriveSummary? {
        drives.first { $0.id == driveID }
    }

    /// A new name must differ from the original after normalization.
    private var renameValid: Bool {
        let normalized = NameNormalizer.normalize(newName)
        return !normalized.isEmpty && normalized != NameNormalizer.normalize(sourceName)
    }

    var body: some View {
        NavigationView {
            Form {
                content
            }
            .navigationTitle(Text("import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("app.cancel", action: onCancel)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .choose:
            Section(footer: Text("import.choose.footer")) {
                Button("import.choose", action: onChoose)
            }
        case .checking:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("import.checking")
                }
            }
        case .noGame:
            Section(footer: Text("library.unrecognized.hint")) {
                Text(LibraryStrings.importOutcomeKey(.noGameFound))
                Button("import.chooseAnother", action: onChoose)
            }
        case .pickDrive:
            pickDrive
        case .nameClash:
            Section(header: Text(LibraryStrings.importOutcomeKey(.nameClash)), footer: Text("import.replace.footer")) {
                Button("import.replace", action: onReplace)
                Button("import.rename", action: onRename)
            }
        case .rename(let taken):
            Section(footer: taken ? Text(LibraryStrings.importOutcomeKey(.nameTaken)) : nil) {
                TextField(L10n.string("import.rename.placeholder"), text: $newName)
                    .autocorrectionDisabled()
                    .onSubmit { if renameValid { onConfirmRename() } }
            }
            Section {
                Button("import.start", action: onConfirmRename)
                    .disabled(!renameValid)
            }
        case .insufficientSpace:
            Section {
                Text(LibraryStrings.importOutcomeKey(.insufficientSpace))
                if let size, let free = drive?.freeBytes {
                    Text(L10n.format("import.space.detail", GameStrings.bytes(Int64(clamping: size)), GameStrings.bytes(free)))
                        .foregroundColor(.secondary)
                }
                Button("import.chooseDrive", action: onChooseDrive)
            }
        case .copying:
            Section(footer: Text("import.copying.footer")) {
                ProgressView(value: progress ?? 0)
                if let size {
                    let done = Int64((Double(size) * (progress ?? 0)).rounded())
                    Text(L10n.format("import.progress", GameStrings.bytes(done), GameStrings.bytes(Int64(clamping: size))))
                        .foregroundColor(.secondary)
                }
            }
        case .finished(let outcome):
            Section {
                Text(LibraryStrings.importOutcomeKey(outcome))
                Button("import.chooseAnother", action: onChoose)
            }
        }
    }

    @ViewBuilder
    private var pickDrive: some View {
        Section(header: Text("import.drive.header")) {
            ForEach(drives) { summary in
                Button {
                    driveID = summary.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: GameStrings.driveLabel(summary.drive))
                            if let free = summary.freeBytes {
                                Text(L10n.format("drives.free", GameStrings.bytes(free)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if summary.id == driveID {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        Section {
            if let size {
                Text(L10n.format("import.size", GameStrings.bytes(Int64(clamping: size))))
            }
            if let drive {
                Text(L10n.format("import.willCopy", GameStrings.driveLabel(drive.drive)))
                    .foregroundColor(.secondary)
            }
            Button("import.start", action: onImport)
                .disabled(drive == nil)
        }
    }
}

#if DEBUG
struct ImportContent_Previews: PreviewProvider {
    static let builtIn = DriveSummary(drive: GameDrive(id: UUID(), kind: .builtIn, label: "Documents"), state: .available,
                                      freeBytes: 20_000_000_000, gameCount: 2)
    static let steps: [ImportStep] = [
        .choose, .checking, .noGame, .pickDrive, .nameClash, .rename(taken: false), .rename(taken: true),
        .insufficientSpace, .copying, .finished(.cancelled), .finished(.failed),
    ]

    static var previews: some View {
        ForEach(steps.indices, id: \.self) { index in
            ImportContent(step: steps[index], sourceName: "Sample Game", size: 3_000_000_000, drives: [builtIn],
                          driveID: .constant(builtIn.id), newName: .constant("Sample Game 2"), progress: 0.35,
                          onChoose: {}, onChooseDrive: {}, onImport: {}, onReplace: {}, onRename: {}, onConfirmRename: {}, onCancel: {})
        }
    }
}
#endif

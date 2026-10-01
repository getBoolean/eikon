diff --git a/App/Drives/DrivesView.swift b/App/Drives/DrivesView.swift
new file mode 100644
index 0000000..ab20985
--- /dev/null
+++ b/App/Drives/DrivesView.swift
@@ -0,0 +1,188 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+import UniformTypeIdentifiers
+
+/// The Game drives destination: the built-in drive, the folders the user added, and
+/// adding, finding again and removing them.
+struct DrivesView: View {
+    /// What the one folder picker is for; several `.fileImporter`s on one view misbehave
+    /// on iOS 15.
+    private enum Picking: Equatable {
+        case add
+        case relink(UUID)
+    }
+
+    @ObservedObject var library: LibraryController
+    @State private var picking: Picking?
+    @State private var refusal: DriveRefusal?
+    @State private var pendingRelink: (drive: UUID, url: URL)?
+    @State private var removing: DriveSummary?
+
+    var body: some View {
+        DrivesContent(
+            drives: library.drives,
+            refusal: refusal,
+            onAdd: { picking = .add },
+            onRelink: { picking = .relink($0.id) },
+            onRemove: { removing = $0 })
+        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
+                      allowedContentTypes: [.folder]) { result in
+            let purpose = picking
+            picking = nil
+            guard case .success(let url) = result, let purpose else { return }
+            switch purpose {
+            case .add: add(url)
+            case .relink(let id): relink(id, to: url, confirmed: false)
+            }
+        }
+        .alert(Text("drives.relink.confirm.title"), isPresented: Binding(
+            get: { pendingRelink != nil },
+            set: { if !$0 { pendingRelink = nil } }
+        )) {
+            Button("drives.relink.confirm.use") {
+                if let pending = pendingRelink { relink(pending.drive, to: pending.url, confirmed: true) }
+            }
+            Button("app.cancel", role: .cancel) {}
+        } message: {
+            Text("drives.relink.confirm.message")
+        }
+        .alert(Text("drives.remove.title"), isPresented: Binding(
+            get: { removing != nil },
+            set: { if !$0 { removing = nil } }
+        )) {
+            Button("drives.remove.confirm", role: .destructive) {
+                if let drive = removing { library.removeDrive(drive.id) }
+            }
+            Button("app.cancel", role: .cancel) {}
+        } message: {
+            Text("drives.remove.message")
+        }
+    }
+
+    private func add(_ url: URL) {
+        Task {
+            if case .failure(let reason) = await library.addDrive(url) {
+                refusal = reason
+            } else {
+                refusal = nil
+            }
+        }
+    }
+
+    private func relink(_ id: UUID, to url: URL, confirmed: Bool) {
+        Task {
+            switch await library.relinkDrive(id, to: url, confirmed: confirmed) {
+            case .relinked: refusal = nil
+            case .needsConfirmation: pendingRelink = (id, url)
+            case .refused(let reason): refusal = reason
+            }
+        }
+    }
+}
+
+/// The drives list for one snapshot. The preview renders this directly.
+struct DrivesContent: View {
+    let drives: [DriveSummary]
+    /// Why the last folder picked couldn't be used.
+    let refusal: DriveRefusal?
+    let onAdd: () -> Void
+    let onRelink: (DriveSummary) -> Void
+    let onRemove: (DriveSummary) -> Void
+
+    var body: some View {
+        List {
+            ForEach(drives.filter { $0.drive.kind == .builtIn }) { summary in
+                Section(footer: Text("drives.builtIn.footer")) {
+                    DriveRow(summary: summary)
+                }
+            }
+            Section(header: Text("drives.section.other"), footer: Text("drives.add.footer")) {
+                ForEach(drives.filter { $0.drive.kind != .builtIn }) { summary in
+                    DriveRow(summary: summary)
+                        .contextMenu {
+                            Button { onRelink(summary) } label: { Label("drives.relink", systemImage: "folder") }
+                            Button(role: .destructive) { onRemove(summary) } label: {
+                                Label("drives.remove", systemImage: "minus.circle")
+                            }
+                        }
+                        .swipeActions {
+                            Button(role: .destructive) { onRemove(summary) } label: { Text("drives.remove") }
+                            Button { onRelink(summary) } label: { Text("drives.relink") }
+                        }
+                    if summary.state == .needsRelink {
+                        Button("drives.relink") { onRelink(summary) }
+                    }
+                }
+                Button(action: onAdd) {
+                    Label("drives.add", systemImage: "plus")
+                }
+                if let refusal {
+                    Text(LibraryStrings.refusalKey(refusal))
+                        .font(.footnote)
+                        .foregroundColor(.red)
+                }
+            }
+        }
+        .listStyle(.insetGrouped)
+        .navigationTitle(Text("drives.title"))
+    }
+}
+
+private struct DriveRow: View {
+    let summary: DriveSummary
+
+    var body: some View {
+        HStack {
+            Image(systemName: summary.drive.kind == .builtIn ? "ipad.and.iphone" : "externaldrive")
+                .foregroundColor(.secondary)
+            VStack(alignment: .leading, spacing: 2) {
+                Text(verbatim: GameStrings.driveLabel(summary.drive))
+                Text(details)
+                    .font(.caption)
+                    .foregroundColor(.secondary)
+            }
+            Spacer()
+            if summary.drive.kind != .builtIn {
+                Text(LibraryStrings.driveStateKey(summary.state))
+                    .font(.caption)
+                    .foregroundColor(summary.state == .available ? .secondary : .orange)
+            }
+        }
+    }
+
+    private var details: String {
+        var parts = [L10n.count("library.count.games", summary.gameCount)]
+        if summary.state == .available, let free = summary.freeBytes {
+            parts.append(L10n.format("drives.free", GameStrings.bytes(free)))
+        }
+        return parts.joined(separator: " · ")
+    }
+}
+
+#if DEBUG
+struct DrivesContent_Previews: PreviewProvider {
+    static let drives: [DriveSummary] = [
+        DriveSummary(drive: GameDrive(id: UUID(), kind: .builtIn, label: "Documents"), state: .available,
+                     freeBytes: 20_000_000_000, gameCount: 3),
+        DriveSummary(drive: GameDrive(id: UUID(), kind: .folder(bookmark: Data()), label: "Sample Drive"),
+                     state: .available, freeBytes: 500_000_000_000, gameCount: 1),
+        DriveSummary(drive: GameDrive(id: UUID(), kind: .folder(bookmark: Data()), label: "Sample Drive 2"),
+                     state: .notConnected, freeBytes: nil, gameCount: 4),
+        DriveSummary(drive: GameDrive(id: UUID(), kind: .folder(bookmark: Data()), label: "Sample Drive 3"),
+                     state: .needsRelink, freeBytes: nil, gameCount: 0),
+    ]
+
+    static var previews: some View {
+        NavigationView {
+            DrivesContent(drives: drives, refusal: nil, onAdd: {}, onRelink: { _ in }, onRemove: { _ in })
+        }
+        .navigationViewStyle(.stack)
+        NavigationView {
+            DrivesContent(drives: Array(drives.prefix(1)), refusal: .iCloud, onAdd: {}, onRelink: { _ in },
+                          onRemove: { _ in })
+        }
+        .navigationViewStyle(.stack)
+    }
+}
+#endif
diff --git a/App/Library/CrashBanner.swift b/App/Library/CrashBanner.swift
new file mode 100644
index 0000000..833efd4
--- /dev/null
+++ b/App/Library/CrashBanner.swift
@@ -0,0 +1,77 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// The last session ended badly: what happened, and what to do about it. The game's name
+/// is shown on screen only.
+struct CrashBannerView: View {
+    let banner: CrashBanner
+    let clipboardNotice: Bool
+    let onTryAlternative: () -> Void
+    let onReport: () -> Void
+    let onDismiss: () -> Void
+
+    var body: some View {
+        VStack(alignment: .leading, spacing: 8) {
+            HStack(alignment: .firstTextBaseline) {
+                Image(systemName: "exclamationmark.octagon.fill")
+                    .foregroundColor(.red)
+                Text(CrashStrings.outcomeKey(banner.outcome))
+                    .font(.headline)
+                Spacer()
+                Button(action: onDismiss) {
+                    Image(systemName: "xmark")
+                }
+                .buttonStyle(.borderless)
+                .accessibilityLabel(Text("crash.dismiss"))
+            }
+            if let name = banner.gameName {
+                Text(verbatim: name)
+            }
+            Text(L10n.format("crash.banner.route", RouteStrings.name(recorded: banner.route),
+                             banner.startedAt.formatted(date: .abbreviated, time: .shortened)))
+                .font(.subheadline)
+                .foregroundColor(.secondary)
+            HStack {
+                if let alternative = banner.alternative {
+                    Button(L10n.format("crash.tryAlternative", RouteStrings.name(alternative)), action: onTryAlternative)
+                        .buttonStyle(.bordered)
+                }
+                Button("crash.report", action: onReport)
+                    .buttonStyle(.bordered)
+            }
+            if clipboardNotice {
+                Text("crash.clipboardNotice")
+                    .font(.footnote)
+                    .foregroundColor(.secondary)
+            }
+        }
+        .padding(.vertical, 4)
+    }
+}
+
+#if DEBUG
+struct CrashBannerView_Previews: PreviewProvider {
+    static func banner(_ outcome: SessionOutcome, alternative: RouteID?) -> CrashBanner {
+        let record = SessionRecord(gameID: .random(), engine: .unity, architecture: .amd64,
+                                   route: RouteID.wineFEX.rawValue, appBuild: "1", startedAt: Date())
+        let entry = CrashEntry(id: record.sessionID, record: record, outcome: outcome, breadcrumbs: [], fault: nil,
+                               recordedAt: Date())
+        return CrashBanner(id: entry.id, entry: entry, outcome: outcome, gameName: "Sample Game", route: record.route,
+                           startedAt: record.startedAt, alternative: alternative)
+    }
+
+    static let outcomes: [SessionOutcome] = [.crashed(signal: 11, pc: 0x1000), .likelyMemoryKill, .endedUnexpectedly]
+
+    static var previews: some View {
+        List {
+            ForEach(outcomes.indices, id: \.self) { index in
+                CrashBannerView(banner: banner(outcomes[index], alternative: .wineBox64), clipboardNotice: index == 0,
+                                onTryAlternative: {}, onReport: {}, onDismiss: {})
+                CrashBannerView(banner: banner(outcomes[index], alternative: nil), clipboardNotice: false,
+                                onTryAlternative: {}, onReport: {}, onDismiss: {})
+            }
+        }
+    }
+}
+#endif
diff --git a/App/Library/GameDetailView.swift b/App/Library/GameDetailView.swift
new file mode 100644
index 0000000..43d3742
--- /dev/null
+++ b/App/Library/GameDetailView.swift
@@ -0,0 +1,525 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// Whether the Launch button works, and why not.
+enum LaunchState: Equatable, CaseIterable {
+    case ready
+    /// A forced route that can't run: allowed after "Launch anyway?".
+    case confirmFirst
+    /// The route decision hasn't been computed yet.
+    case deciding
+    case planned
+    case noRoute
+    case driveNotConnected
+    case missing
+
+    /// The launch location needs a reachable drive and a present folder; the chosen route
+    /// must be built into this app.
+    init(location: LaunchLocation, decision: RouteDecision?, isBuilt: (RouteID) -> Bool) {
+        switch location {
+        case .driveNotConnected:
+            self = .driveNotConnected
+            return
+        case .missing:
+            self = .missing
+            return
+        case .ready:
+            break
+        }
+        guard let decision else {
+            self = .deciding
+            return
+        }
+        guard let chosen = decision.chosen else {
+            self = .noRoute
+            return
+        }
+        guard chosen.verdict != .planned, isBuilt(chosen.route) else {
+            self = .planned
+            return
+        }
+        switch chosen.verdict {
+        case .runnable, .runnableWithWarnings: self = .ready
+        case .unavailable: self = decision.isOverride ? .confirmFirst : .noRoute
+        case .planned: self = .planned
+        }
+    }
+
+    var canLaunch: Bool {
+        self == .ready || self == .confirmFirst
+    }
+}
+
+/// One game, looked up by id on every update so a merge that moves it to another id
+/// follows along. Shows a placeholder once the game is gone.
+struct GameDetailView: View {
+    private enum Sheet: Identifiable {
+        case merge, split, remove
+        var id: Self { self }
+    }
+
+    let services: AppServices
+    let gameID: GameID
+    @ObservedObject private var library: LibraryController
+    @ObservedObject private var settings: SettingsController
+    @ObservedObject private var crashes: CrashReportController
+    @ObservedObject private var jit: JITController
+    @StateObject private var verifier = FileVerifier()
+    @Environment(\.dismiss) private var dismiss
+    @FocusState private var nameFocused: Bool
+    @State private var draftName = ""
+    @State private var sheet: Sheet?
+    @State private var confirmingForced = false
+    @State private var launching = false
+    @State private var launchFailure: SessionPresenter.Failure??
+
+    init(services: AppServices, gameID: GameID) {
+        self.services = services
+        self.gameID = gameID
+        library = services.library
+        settings = services.settings
+        crashes = services.crashes
+        jit = services.jit
+    }
+
+    private var links: [GameID: GameID] { settings.store.mergeLinks() }
+
+    private var game: LibraryGame? {
+        let id = IdentityMatcher.resolve(gameID, links: links)
+        return library.games.first { $0.id == id }
+    }
+
+    var body: some View {
+        if let game {
+            detail(game)
+        } else {
+            Text("game.gone")
+                .foregroundColor(.secondary)
+                .padding()
+        }
+    }
+
+    private func detail(_ game: LibraryGame) -> some View {
+        let decision = library.decisions[game.id]
+        let state = LaunchState(location: library.launchLocation(for: game.id), decision: decision,
+                                isBuilt: { services.registry.runtimeType(for: $0) != nil })
+        let history = crashes.history(for: game.id, links: links)
+        return List {
+            if !game.suggestions.isEmpty {
+                Section {
+                    IdentitySuggestion(candidates: game.suggestions.map(choice),
+                                       onMerge: { target in Task { await library.merge(game.id, into: target) } },
+                                       onKeepSeparate: { keepSeparate(game) })
+                }
+            }
+            Section(header: Text("game.section.game")) {
+                TextField(L10n.string("game.name.placeholder"), text: $draftName)
+                    .focused($nameFocused)
+                    .submitLabel(.done)
+                    .onSubmit { settings.setDisplayName(draftName, for: game.id) }
+                if let detection = game.detection {
+                    EngineRows(detection: detection)
+                }
+            }
+            Section(header: Text("game.section.locations")) {
+                ForEach(game.locations) { location in
+                    locationRow(location)
+                }
+            }
+            Section {
+                LaunchButton(state: state, launching: launching) {
+                    if state == .confirmFirst {
+                        confirmingForced = true
+                    } else {
+                        launch(game.id)
+                    }
+                }
+            }
+            RouteSection(decision: decision, override: settings.routeOverride(for: game.id),
+                         jitReason: jit.status.reason,
+                         onSelect: { settings.setRouteOverride($0, for: game.id) })
+            if !history.isEmpty {
+                Section(header: Text("game.section.crashes"),
+                        footer: crashes.clipboardNotice ? Text("crash.clipboardNotice") : nil) {
+                    ForEach(history) { entry in
+                        CrashHistoryRow(entry: entry) { crashes.report(entry) }
+                    }
+                }
+            }
+            Section {
+                DisclosureGroup {
+                    identityRows(game)
+                } label: {
+                    Text("game.section.identity")
+                }
+            }
+            Section {
+                Button(role: .destructive) {
+                    sheet = .remove
+                } label: {
+                    Text("game.remove")
+                }
+            }
+        }
+        .listStyle(.insetGrouped)
+        .navigationTitle(Text(verbatim: game.displayName))
+        .onAppear {
+            draftName = game.displayName
+            library.setViewedLocation(game.locations.first?.id)
+        }
+        .onDisappear {
+            library.setViewedLocation(nil)
+            verifier.cancel()
+        }
+        .onChange(of: game.displayName) { name in
+            if !nameFocused { draftName = name }
+        }
+        .onChange(of: nameFocused) { focused in
+            if !focused { draftName = game.displayName }
+        }
+        .sheet(item: $sheet) { sheet in
+            switch sheet {
+            case .merge:
+                MergePicker(games: library.games.filter { $0.id != game.id }.map { GameChoice(id: $0.id, name: $0.displayName) },
+                            onPick: { target in Task { await library.merge(game.id, into: target) } })
+            case .split:
+                SplitPicker(locations: game.locations.map { location in
+                    SplitPicker.Choice(id: location.id, drive: driveName(location.driveID), folder: location.folderName)
+                }, onPick: { library.split(location: $0) })
+            case .remove:
+                RemoveGameDialog(library: library, game: game, onRemoved: { dismiss() })
+            }
+        }
+        .alert(Text("game.launch.anyway.title"), isPresented: $confirmingForced) {
+            Button("game.launch.anyway.confirm") { launch(game.id) }
+            Button("app.cancel", role: .cancel) {}
+        } message: {
+            Text((decision?.overrideWarnings ?? [])
+                .map { RouteStrings.reasonText($0, jitReason: jit.status.reason) }
+                .joined(separator: "\n"))
+        }
+        .alert(Text("game.launch.failed.title"), isPresented: Binding(
+            get: { launchFailure != nil },
+            set: { if !$0 { launchFailure = nil } }
+        )) {
+            Button("app.ok", role: .cancel) {}
+        } message: {
+            Text(GameStrings.launchFailureKey(launchFailure ?? nil))
+        }
+    }
+
+    // MARK: Rows
+
+    private func locationRow(_ location: GameLocation) -> some View {
+        HStack {
+            VStack(alignment: .leading, spacing: 2) {
+                Text(verbatim: location.folderName)
+                Text(verbatim: driveName(location.driveID))
+                    .font(.caption)
+                    .foregroundColor(.secondary)
+                if case .failed(let failure) = location.identity {
+                    Text(GameStrings.identityFailureKey(failure))
+                        .font(.caption)
+                        .foregroundColor(.secondary)
+                }
+            }
+            Spacer()
+            if location.identity == .missing {
+                Text("library.status.missing")
+                    .foregroundColor(.secondary)
+                Button("game.location.forget") { library.forget(location: location.id) }
+                    .buttonStyle(.borderless)
+            } else if let state = library.drives.first(where: { $0.id == location.driveID })?.state {
+                Text(LibraryStrings.driveStateKey(state))
+                    .font(.caption)
+                    .foregroundColor(.secondary)
+            }
+        }
+    }
+
+    @ViewBuilder
+    private func identityRows(_ game: LibraryGame) -> some View {
+        HStack {
+            Text("identity.reportID")
+            Spacer()
+            Text(verbatim: game.id.reportID)
+                .font(.body.monospaced())
+                .foregroundColor(.secondary)
+                .textSelection(.enabled)
+        }
+        Text(L10n.count("identity.count.versions", settings.store.fingerprints(game: game.id.uuid).count))
+            .foregroundColor(.secondary)
+        Button("identity.sameGameAs") { sheet = .merge }
+            .disabled(library.games.count < 2)
+        if game.locations.count > 1 {
+            Button("identity.differentGame") { sheet = .split }
+        }
+        verifyRows(game)
+        ForEach(game.locations.filter { if case .failed = $0.identity { true } else { false } }) { location in
+            Button(L10n.format("identity.retry", location.folderName)) { library.retryFingerprint(location.id) }
+        }
+    }
+
+    @ViewBuilder
+    private func verifyRows(_ game: LibraryGame) -> some View {
+        switch verifier.state {
+        case .idle:
+            Button("identity.verify") { verify(game.id) }
+        case .running(let progress):
+            HStack {
+                ProgressView(value: progress)
+                Button("app.cancel") { verifier.cancel() }
+                    .buttonStyle(.borderless)
+            }
+        case .done(let hash):
+            VStack(alignment: .leading, spacing: 4) {
+                Text("identity.verify.hash")
+                Text(verbatim: hash)
+                    .font(.caption.monospaced())
+                    .textSelection(.enabled)
+            }
+            Button("identity.verify.again") { verify(game.id) }
+        case .failed:
+            Text("identity.verify.failed")
+                .foregroundColor(.secondary)
+            Button("identity.verify") { verify(game.id) }
+        }
+    }
+
+    // MARK: Actions
+
+    private func choice(_ id: GameID) -> GameChoice {
+        GameChoice(id: id, name: library.games.first { $0.id == id }?.displayName ?? id.reportID)
+    }
+
+    /// Dismisses every pending suggestion on the game's locations.
+    private func keepSeparate(_ game: LibraryGame) {
+        for location in game.locations {
+            for suggested in location.suggestion {
+                library.dismissSuggestion(suggested, on: location.id)
+            }
+        }
+    }
+
+    private func driveName(_ id: UUID) -> String {
+        library.drives.first { $0.id == id }.map { GameStrings.driveLabel($0.drive) } ?? ""
+    }
+
+    /// Re-checks drives, then starts the session on the chosen route.
+    private func launch(_ game: GameID) {
+        launching = true
+        Task {
+            defer { launching = false }
+            await library.reevaluateDriveStates()
+            guard case .ready(let location) = library.launchLocation(for: game) else {
+                launchFailure = .driveNotConnected
+                return
+            }
+            guard let route = library.decisions[game]?.chosen?.route,
+                  let runtime = services.registry.runtimeType(for: route) else {
+                launchFailure = .some(nil)
+                return
+            }
+            do {
+                try await services.presenter.launch(location, game: game, route: route, runtime: runtime)
+            } catch {
+                launchFailure = .some(error as? SessionPresenter.Failure)
+            }
+        }
+    }
+
+    /// Hashes the launch location's key file. The hash is shown on screen only.
+    private func verify(_ game: GameID) {
+        guard case .ready(let location) = library.launchLocation(for: game), let detection = location.detection,
+              let keyFile = detection.keyFile, let drive = library.context.index.contents.drive(location.driveID) else {
+            verifier.fail()
+            return
+        }
+        let manager = library.driveManager
+        verifier.run { progress, isCancelled in
+            guard let token = manager.open(drive) else { throw CocoaError(.fileNoSuchFile) }
+            defer { token.close() }
+            var root = token.url.appendingPathComponent(location.folderName, isDirectory: true)
+            if !detection.gameRoot.isEmpty { root.appendPathComponent(detection.gameRoot, isDirectory: true) }
+            return try FileHasher.sha256(of: root.appendingPathComponent(keyFile), progress: progress,
+                                         isCancelled: isCancelled)
+        }
+    }
+}
+
+/// Runs one "Verify files" hash off the main actor, with progress and cancel.
+@MainActor
+final class FileVerifier: ObservableObject {
+    enum State: Equatable {
+        case idle, running(Double), done(String), failed
+    }
+
+    @Published private(set) var state = State.idle
+    private var cancelled: CancelSwitch?
+
+    typealias Work = @Sendable (_ progress: (Double) -> Void, _ isCancelled: () -> Bool) throws -> String
+
+    func run(_ work: @escaping Work) {
+        cancelled?.set()
+        let flag = CancelSwitch()
+        cancelled = flag
+        state = .running(0)
+        Task.detached { [weak self] in
+            var reported = -1.0
+            let hash = try? work({ progress in
+                guard progress - reported >= 0.01 || progress == 1 else { return }
+                reported = progress
+                Task { @MainActor in if !flag.isSet { self?.state = .running(progress) } }
+            }, { flag.isSet })
+            await MainActor.run {
+                guard let self, !flag.isSet else { return }
+                self.state = hash.map(State.done) ?? .failed
+                self.cancelled = nil
+            }
+        }
+    }
+
+    func cancel() {
+        cancelled?.set()
+        cancelled = nil
+        if case .running = state { state = .idle }
+    }
+
+    func fail() {
+        state = .failed
+    }
+}
+
+/// A one-way cancel switch, safe from any thread.
+final class CancelSwitch: @unchecked Sendable {
+    private let lock = NSLock()
+    private var value = false
+
+    var isSet: Bool { lock.withLock { value } }
+
+    func set() {
+        lock.withLock { value = true }
+    }
+}
+
+/// Engine details and the architecture per platform.
+struct EngineRows: View {
+    let detection: DetectionResult
+
+    var body: some View {
+        let details = detection.details
+        row("game.engine", Text(EngineStrings.name(detection.engine)))
+        if let scripting = details.unityScripting {
+            row("game.engine.unityScripting", Text(EngineStrings.key(scripting)))
+        }
+        if let version = details.unityVersion {
+            row("game.engine.version", Text(verbatim: version))
+        }
+        if let version = details.renpyVersion {
+            row("game.engine.version", Text(EngineStrings.text(version)))
+        }
+        if let flavor = details.kirikiriFlavor {
+            row("game.engine.kirikiriFlavor", Text(EngineStrings.key(flavor)))
+        }
+        if !details.pluginFileNames.isEmpty {
+            row("game.engine.plugins", Text(verbatim: details.pluginFileNames.joined(separator: ", ")))
+        }
+        if let build = details.gameMakerBuild {
+            row("game.engine.gameMakerBuild", Text(EngineStrings.key(build)))
+        }
+        ForEach(GamePlatform.allCases.filter { detection.executables[$0] != nil }, id: \.self) { platform in
+            row(EngineStrings.key(platform), Text(EngineStrings.name(detection.executables[platform]!.architecture)))
+        }
+    }
+
+    private func row(_ label: LocalizedStringKey, _ value: Text) -> some View {
+        HStack(alignment: .firstTextBaseline) {
+            Text(label)
+            Spacer()
+            value
+                .foregroundColor(.secondary)
+                .multilineTextAlignment(.trailing)
+        }
+    }
+}
+
+struct LaunchButton: View {
+    let state: LaunchState
+    let launching: Bool
+    let onLaunch: () -> Void
+
+    var body: some View {
+        VStack(alignment: .leading, spacing: 6) {
+            Button(action: onLaunch) {
+                HStack {
+                    Label("game.launch", systemImage: "play.fill")
+                    if launching {
+                        Spacer()
+                        ProgressView()
+                    }
+                }
+                .frame(maxWidth: .infinity, alignment: .leading)
+            }
+            .disabled(!state.canLaunch || launching)
+            if let caption = GameStrings.launchCaptionKey(state) {
+                Text(caption)
+                    .font(.footnote)
+                    .foregroundColor(.secondary)
+            }
+        }
+    }
+}
+
+/// One past session that ended badly, with a way to report it now.
+struct CrashHistoryRow: View {
+    let entry: CrashEntry
+    let onReport: () -> Void
+
+    var body: some View {
+        VStack(alignment: .leading, spacing: 4) {
+            Text(CrashStrings.outcomeKey(entry.outcome))
+            Text(L10n.format("crash.banner.route", RouteStrings.name(recorded: entry.record.route),
+                             entry.record.startedAt.formatted(date: .abbreviated, time: .shortened)))
+                .font(.caption)
+                .foregroundColor(.secondary)
+            Button("crash.report", action: onReport)
+                .buttonStyle(.borderless)
+        }
+    }
+}
+
+#if DEBUG
+struct GameDetailParts_Previews: PreviewProvider {
+    static let detection = DetectionResult(
+        engine: .kirikiri,
+        details: EngineDetails(unityScripting: .il2cpp, unityVersion: "2021.3", kirikiriFlavor: .krkrZ,
+                               pluginFileNames: ["plugin-a", "plugin-b"], renpyVersion: .exact(7, 4, 11),
+                               gameMakerBuild: .yyc),
+        gameRoot: "",
+        executables: [
+            .windows: ExecutableInfo(path: "game.exe", format: .pe, architecture: .i386, machine: 0x14c, isGUI: true),
+            .linux: ExecutableInfo(path: "game", format: .elf, architecture: .amd64, machine: 62, isGUI: nil),
+        ],
+        keyFile: "data.xp3", detectorVersion: 1)
+
+    static var previews: some View {
+        List {
+            Section {
+                EngineRows(detection: detection)
+            }
+            Section {
+                ForEach(LaunchState.allCases, id: \.self) { state in
+                    LaunchButton(state: state, launching: false, onLaunch: {})
+                }
+                LaunchButton(state: .ready, launching: true, onLaunch: {})
+            }
+            Section {
+                CrashHistoryRow(entry: CrashBannerView_Previews.banner(.killedInBackground, alternative: nil).entry,
+                                onReport: {})
+            }
+        }
+        .listStyle(.insetGrouped)
+    }
+}
+#endif
diff --git a/App/Library/IdentitySuggestion.swift b/App/Library/IdentitySuggestion.swift
new file mode 100644
index 0000000..5c3f470
--- /dev/null
+++ b/App/Library/IdentitySuggestion.swift
@@ -0,0 +1,137 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// Another game in the library, by its on-screen name.
+struct GameChoice: Identifiable {
+    var id: GameID
+    var name: String
+}
+
+/// The non-blocking "same game as…?" card. Never presented modally: the rest of the game
+/// screen works without an answer.
+struct IdentitySuggestion: View {
+    let candidates: [GameChoice]
+    let onMerge: (GameID) -> Void
+    let onKeepSeparate: () -> Void
+
+    var body: some View {
+        VStack(alignment: .leading, spacing: 10) {
+            Label {
+                if candidates.count == 1 {
+                    Text(LibraryStrings.suggestion(otherGame: candidates[0].name))
+                } else {
+                    Text("identity.suggestion.several")
+                }
+            } icon: {
+                Image(systemName: "questionmark.square.dashed")
+            }
+            if candidates.count == 1 {
+                Button("identity.merge") { onMerge(candidates[0].id) }
+                    .buttonStyle(.bordered)
+            } else {
+                ForEach(candidates) { candidate in
+                    HStack {
+                        Text(verbatim: candidate.name)
+                        Spacer()
+                        Button("identity.merge") { onMerge(candidate.id) }
+                            .buttonStyle(.bordered)
+                    }
+                }
+            }
+            Button("identity.keepSeparate", action: onKeepSeparate)
+                .buttonStyle(.borderless)
+        }
+        .padding(.vertical, 4)
+    }
+}
+
+/// "Same game as…": pick the game this one merges into.
+struct MergePicker: View {
+    let games: [GameChoice]
+    let onPick: (GameID) -> Void
+    @Environment(\.dismiss) private var dismiss
+
+    var body: some View {
+        NavigationView {
+            List {
+                Section(footer: Text("identity.merge.footer")) {
+                    ForEach(games) { game in
+                        Button {
+                            onPick(game.id)
+                            dismiss()
+                        } label: {
+                            Text(verbatim: game.name)
+                        }
+                    }
+                }
+            }
+            .navigationTitle(Text("identity.sameGameAs"))
+            .navigationBarTitleDisplayMode(.inline)
+            .toolbar {
+                ToolbarItem(placement: .cancellationAction) {
+                    Button("app.cancel") { dismiss() }
+                }
+            }
+        }
+        .navigationViewStyle(.stack)
+    }
+}
+
+/// "This is a different game": pick the location that becomes a game of its own.
+struct SplitPicker: View {
+    struct Choice: Identifiable {
+        var id: UUID
+        var drive: String
+        var folder: String
+    }
+
+    let locations: [Choice]
+    let onPick: (UUID) -> Void
+    @Environment(\.dismiss) private var dismiss
+
+    var body: some View {
+        NavigationView {
+            List {
+                Section(footer: Text("identity.split.footer")) {
+                    ForEach(locations) { location in
+                        Button {
+                            onPick(location.id)
+                            dismiss()
+                        } label: {
+                            VStack(alignment: .leading) {
+                                Text(verbatim: location.folder)
+                                Text(verbatim: location.drive)
+                                    .font(.caption)
+                                    .foregroundColor(.secondary)
+                            }
+                        }
+                    }
+                }
+            }
+            .navigationTitle(Text("identity.differentGame"))
+            .navigationBarTitleDisplayMode(.inline)
+            .toolbar {
+                ToolbarItem(placement: .cancellationAction) {
+                    Button("app.cancel") { dismiss() }
+                }
+            }
+        }
+        .navigationViewStyle(.stack)
+    }
+}
+
+#if DEBUG
+struct IdentitySuggestion_Previews: PreviewProvider {
+    static let games = (1...3).map { GameChoice(id: .random(), name: "Sample Game \($0)") }
+
+    static var previews: some View {
+        List {
+            IdentitySuggestion(candidates: [games[0]], onMerge: { _ in }, onKeepSeparate: {})
+            IdentitySuggestion(candidates: games, onMerge: { _ in }, onKeepSeparate: {})
+        }
+        MergePicker(games: games, onPick: { _ in })
+        SplitPicker(locations: [.init(id: UUID(), drive: "Sample Drive", folder: "Sample Game")], onPick: { _ in })
+    }
+}
+#endif
diff --git a/App/Library/ImportFlow.swift b/App/Library/ImportFlow.swift
new file mode 100644
index 0000000..25d4e75
--- /dev/null
+++ b/App/Library/ImportFlow.swift
@@ -0,0 +1,266 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+import UniformTypeIdentifiers
+
+/// Where the import sheet is.
+enum ImportStep: Equatable {
+    case choose
+    /// Looking for a game in the picked folder and measuring it.
+    case checking
+    case noGame
+    case pickDrive
+    case nameClash
+    /// Typing another name; `taken` after the last one was refused.
+    case rename(taken: Bool)
+    case insufficientSpace
+    case copying
+    /// Failed or cancelled; the coordinator has already removed its staging folder.
+    case finished(ImportOutcome)
+}
+
+/// Pick a game folder, pick a drive, copy it there. The coordinator holds the folder's
+/// access, runs detection and does the name and space checks.
+struct ImportFlow: View {
+    @ObservedObject var library: LibraryController
+    @Environment(\.dismiss) private var dismiss
+    @State private var step = ImportStep.choose
+    @State private var picking = false
+    @State private var source: URL?
+    @State private var size: UInt64?
+    @State private var driveID: UUID?
+    @State private var newName = ""
+
+    var body: some View {
+        ImportContent(
+            step: step,
+            sourceName: source?.lastPathComponent ?? "",
+            size: size,
+            drives: library.drives.filter { $0.state == .available },
+            driveID: $driveID,
+            newName: $newName,
+            progress: library.importProgress,
+            onChoose: { picking = true },
+            onChooseDrive: { step = .pickDrive },
+            onImport: { start(.original) },
+            onReplace: { start(.replaceExisting) },
+            onRename: {
+                newName = source?.lastPathComponent ?? ""
+                step = .rename(taken: false)
+            },
+            onConfirmRename: { start(.rename(newName)) },
+            onCancel: {
+                if step == .copying {
+                    library.cancelImport()
+                } else {
+                    dismiss()
+                }
+            })
+        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
+            guard case .success(let url) = result else { return }
+            check(url)
+        }
+        .interactiveDismissDisabled(step == .copying || step == .checking)
+    }
+
+    /// Detection and the copy's size, off the main actor.
+    private func check(_ url: URL) {
+        source = url
+        step = .checking
+        let importer = library.importer
+        Task {
+            let measured = await Task.detached { importer.size(of: url) }.value
+            guard let measured else {
+                step = .noGame
+                return
+            }
+            size = measured
+            let available = library.drives.filter { $0.state == .available }
+            if driveID == nil || !available.contains(where: { $0.id == driveID }) {
+                driveID = (available.first { $0.drive.kind == .builtIn } ?? available.first)?.id
+            }
+            step = .pickDrive
+        }
+    }
+
+    private func start(_ naming: ImportNaming) {
+        guard let source, let driveID else { return }
+        step = .copying
+        Task {
+            let outcome = await library.importGame(from: source, to: driveID, naming: naming)
+            switch outcome {
+            case .imported: dismiss()
+            case .nameClash: step = .nameClash
+            case .nameTaken: step = .rename(taken: true)
+            case .insufficientSpace: step = .insufficientSpace
+            case .noGameFound: step = .noGame
+            case .driveUnavailable, .cancelled, .failed: step = .finished(outcome)
+            }
+        }
+    }
+}
+
+/// The sheet at one step. The preview renders this directly.
+struct ImportContent: View {
+    let step: ImportStep
+    let sourceName: String
+    let size: UInt64?
+    let drives: [DriveSummary]
+    @Binding var driveID: UUID?
+    @Binding var newName: String
+    let progress: Double?
+    let onChoose: () -> Void
+    let onChooseDrive: () -> Void
+    let onImport: () -> Void
+    let onReplace: () -> Void
+    let onRename: () -> Void
+    let onConfirmRename: () -> Void
+    let onCancel: () -> Void
+
+    private var drive: DriveSummary? {
+        drives.first { $0.id == driveID }
+    }
+
+    /// A new name must differ from the original after normalization.
+    private var renameValid: Bool {
+        let normalized = NameNormalizer.normalize(newName)
+        return !normalized.isEmpty && normalized != NameNormalizer.normalize(sourceName)
+    }
+
+    var body: some View {
+        NavigationView {
+            Form {
+                content
+            }
+            .navigationTitle(Text("import.title"))
+            .navigationBarTitleDisplayMode(.inline)
+            .toolbar {
+                ToolbarItem(placement: .cancellationAction) {
+                    Button("app.cancel", action: onCancel)
+                }
+            }
+        }
+        .navigationViewStyle(.stack)
+    }
+
+    @ViewBuilder
+    private var content: some View {
+        switch step {
+        case .choose:
+            Section(footer: Text("import.choose.footer")) {
+                Button("import.choose", action: onChoose)
+            }
+        case .checking:
+            Section {
+                HStack(spacing: 8) {
+                    ProgressView()
+                    Text("import.checking")
+                }
+            }
+        case .noGame:
+            Section(footer: Text("library.unrecognized.hint")) {
+                Text(LibraryStrings.importOutcomeKey(.noGameFound))
+                Button("import.chooseAnother", action: onChoose)
+            }
+        case .pickDrive:
+            pickDrive
+        case .nameClash:
+            Section(header: Text(LibraryStrings.importOutcomeKey(.nameClash)), footer: Text("import.replace.footer")) {
+                Button("import.replace", action: onReplace)
+                Button("import.rename", action: onRename)
+            }
+        case .rename(let taken):
+            Section(footer: taken ? Text(LibraryStrings.importOutcomeKey(.nameTaken)) : nil) {
+                TextField(L10n.string("import.rename.placeholder"), text: $newName)
+                    .autocorrectionDisabled()
+                    .onSubmit { if renameValid { onConfirmRename() } }
+            }
+            Section {
+                Button("import.start", action: onConfirmRename)
+                    .disabled(!renameValid)
+            }
+        case .insufficientSpace:
+            Section {
+                Text(LibraryStrings.importOutcomeKey(.insufficientSpace))
+                if let size, let free = drive?.freeBytes {
+                    Text(L10n.format("import.space.detail", GameStrings.bytes(Int64(clamping: size)), GameStrings.bytes(free)))
+                        .foregroundColor(.secondary)
+                }
+                Button("import.chooseDrive", action: onChooseDrive)
+            }
+        case .copying:
+            Section(footer: Text("import.copying.footer")) {
+                ProgressView(value: progress ?? 0)
+                if let size {
+                    let done = Int64((Double(size) * (progress ?? 0)).rounded())
+                    Text(L10n.format("import.progress", GameStrings.bytes(done), GameStrings.bytes(Int64(clamping: size))))
+                        .foregroundColor(.secondary)
+                }
+            }
+        case .finished(let outcome):
+            Section {
+                Text(LibraryStrings.importOutcomeKey(outcome))
+                Button("import.chooseAnother", action: onChoose)
+            }
+        }
+    }
+
+    @ViewBuilder
+    private var pickDrive: some View {
+        Section(header: Text("import.drive.header")) {
+            ForEach(drives) { summary in
+                Button {
+                    driveID = summary.id
+                } label: {
+                    HStack {
+                        VStack(alignment: .leading, spacing: 2) {
+                            Text(verbatim: GameStrings.driveLabel(summary.drive))
+                            if let free = summary.freeBytes {
+                                Text(L10n.format("drives.free", GameStrings.bytes(free)))
+                                    .font(.caption)
+                                    .foregroundColor(.secondary)
+                            }
+                        }
+                        Spacer()
+                        if summary.id == driveID {
+                            Image(systemName: "checkmark")
+                                .foregroundColor(.accentColor)
+                        }
+                    }
+                    .contentShape(Rectangle())
+                }
+                .buttonStyle(.plain)
+            }
+        }
+        Section {
+            if let size {
+                Text(L10n.format("import.size", GameStrings.bytes(Int64(clamping: size))))
+            }
+            if let drive {
+                Text(L10n.format("import.willCopy", GameStrings.driveLabel(drive.drive)))
+                    .foregroundColor(.secondary)
+            }
+            Button("import.start", action: onImport)
+                .disabled(drive == nil)
+        }
+    }
+}
+
+#if DEBUG
+struct ImportContent_Previews: PreviewProvider {
+    static let builtIn = DriveSummary(drive: GameDrive(id: UUID(), kind: .builtIn, label: "Documents"), state: .available,
+                                      freeBytes: 20_000_000_000, gameCount: 2)
+    static let steps: [ImportStep] = [
+        .choose, .checking, .noGame, .pickDrive, .nameClash, .rename(taken: false), .rename(taken: true),
+        .insufficientSpace, .copying, .finished(.cancelled), .finished(.failed),
+    ]
+
+    static var previews: some View {
+        ForEach(steps.indices, id: \.self) { index in
+            ImportContent(step: steps[index], sourceName: "Sample Game", size: 3_000_000_000, drives: [builtIn],
+                          driveID: .constant(builtIn.id), newName: .constant("Sample Game 2"), progress: 0.35,
+                          onChoose: {}, onChooseDrive: {}, onImport: {}, onReplace: {}, onRename: {}, onConfirmRename: {}, onCancel: {})
+        }
+    }
+}
+#endif
diff --git a/App/Library/LibraryRow.swift b/App/Library/LibraryRow.swift
new file mode 100644
index 0000000..16fcc55
--- /dev/null
+++ b/App/Library/LibraryRow.swift
@@ -0,0 +1,153 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// A route decision as a row shows it: the verdict only; reasons are on the detail screen.
+enum RouteBadge: CaseIterable {
+    case runnable, warning, planned, override, unavailable
+
+    init(_ decision: RouteDecision) {
+        guard let chosen = decision.chosen else {
+            self = .unavailable
+            return
+        }
+        if decision.isOverride {
+            self = .override
+            return
+        }
+        switch chosen.verdict {
+        case .runnable: self = .runnable
+        case .runnableWithWarnings: self = .warning
+        case .planned: self = .planned
+        case .unavailable: self = .unavailable
+        }
+    }
+
+    var systemImage: String {
+        switch self {
+        case .runnable: "checkmark.circle.fill"
+        case .warning: "exclamationmark.triangle.fill"
+        case .planned: "clock"
+        case .override: "hand.point.right.fill"
+        case .unavailable: "xmark.circle"
+        }
+    }
+
+    var color: Color {
+        switch self {
+        case .runnable: .green
+        case .warning: .orange
+        case .planned, .unavailable: .secondary
+        case .override: .accentColor
+        }
+    }
+}
+
+/// What one library row shows, built from the controller's published values.
+struct LibraryRowContent {
+    var name: String
+    var engine: Engine?
+    var architectures: [CPUArchitecture]
+    /// nil while the route is still being decided.
+    var badge: RouteBadge?
+    /// Every location is on a drive other than the built-in one.
+    var onOtherDrivesOnly: Bool
+    /// nil when the game is ready.
+    var status: GameStatus?
+    /// Full-hash progress while identifying.
+    var progress: Double?
+
+    init(name: String, engine: Engine?, architectures: [CPUArchitecture], badge: RouteBadge?,
+         onOtherDrivesOnly: Bool, status: GameStatus?, progress: Double? = nil) {
+        self.name = name
+        self.engine = engine
+        self.architectures = architectures
+        self.badge = badge
+        self.onOtherDrivesOnly = onOtherDrivesOnly
+        self.status = status
+        self.progress = progress
+    }
+
+    init(game: LibraryGame, decision: RouteDecision?, drives: [DriveSummary], progress: [UUID: Double]) {
+        let builtIn = Set(drives.filter { $0.drive.kind == .builtIn }.map(\.id))
+        self.init(
+            name: game.displayName,
+            engine: game.detection?.engine,
+            architectures: GamePlatform.allCases.compactMap { game.detection?.executables[$0]?.architecture },
+            badge: decision.map(RouteBadge.init),
+            onOtherDrivesOnly: !game.locations.contains { builtIn.contains($0.driveID) },
+            status: game.status == .ready ? nil : game.status,
+            progress: game.status == .identifying ? game.locations.compactMap { progress[$0.id] }.max() : nil)
+    }
+
+    var detail: String? {
+        let parts = (engine.map { [EngineStrings.name($0)] } ?? []) + architectures.map(EngineStrings.name)
+        return parts.isEmpty ? nil : parts.joined(separator: " · ")
+    }
+}
+
+struct LibraryRow: View {
+    let content: LibraryRowContent
+
+    var body: some View {
+        VStack(alignment: .leading, spacing: 4) {
+            HStack(alignment: .firstTextBaseline) {
+                Text(verbatim: content.name)
+                    .font(.headline)
+                if content.onOtherDrivesOnly {
+                    Image(systemName: "externaldrive")
+                        .foregroundColor(.secondary)
+                        .accessibilityLabel(Text("library.otherDriveOnly"))
+                }
+                Spacer()
+                if let badge = content.badge {
+                    Label(GameStrings.badgeKey(badge), systemImage: badge.systemImage)
+                        .font(.caption)
+                        .foregroundColor(badge.color)
+                }
+            }
+            if let detail = content.detail {
+                Text(verbatim: detail)
+                    .font(.subheadline)
+                    .foregroundColor(.secondary)
+            }
+            if let status = content.status {
+                HStack(spacing: 6) {
+                    Text(LibraryStrings.statusKey(status))
+                    if let progress = content.progress {
+                        ProgressView(value: progress)
+                            .frame(maxWidth: 80)
+                    }
+                }
+                .font(.caption)
+                .foregroundColor(.secondary)
+            }
+        }
+        .padding(.vertical, 2)
+    }
+}
+
+#if DEBUG
+struct LibraryRow_Previews: PreviewProvider {
+    private static let statuses: [GameStatus?] = [
+        nil, .identifying, .waitingForCopy, .suggestion, .driveNotConnected, .missing, .fingerprintFailed,
+    ]
+
+    static var previews: some View {
+        List {
+            ForEach(statuses.indices, id: \.self) { index in
+                Section {
+                    ForEach(RouteBadge.allCases, id: \.self) { badge in
+                        LibraryRow(content: LibraryRowContent(
+                            name: "Sample Game", engine: .unity, architectures: [.amd64], badge: badge,
+                            onOtherDrivesOnly: index == 4, status: statuses[index],
+                            progress: statuses[index] == .identifying ? 0.4 : nil))
+                    }
+                }
+            }
+            LibraryRow(content: LibraryRowContent(name: "Sample Game", engine: nil, architectures: [], badge: nil,
+                                                  onOtherDrivesOnly: true, status: nil))
+        }
+    }
+}
+#endif
diff --git a/App/Library/LibraryView.swift b/App/Library/LibraryView.swift
new file mode 100644
index 0000000..1f0c4af
--- /dev/null
+++ b/App/Library/LibraryView.swift
@@ -0,0 +1,174 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// The Library destination, where the app opens: the crash banner, every game, folders
+/// still settling, and folders where no game was found.
+struct LibraryView: View {
+    let services: AppServices
+    @ObservedObject var library: LibraryController
+    @ObservedObject var crashes: CrashReportController
+    @State private var importing = false
+
+    init(services: AppServices) {
+        self.services = services
+        library = services.library
+        crashes = services.crashes
+    }
+
+    var body: some View {
+        let drives = library.drives
+        LibraryContent(
+            games: library.games.map { game in
+                LibraryContent.Game(id: game.id, row: LibraryRowContent(
+                    game: game, decision: library.decisions[game.id], drives: drives, progress: library.fingerprintProgress))
+            },
+            settling: library.settling.map { location in
+                LibraryContent.Folder(id: location.id, row: LibraryRowContent(
+                    name: location.folderName, engine: location.detection?.engine, architectures: [], badge: nil,
+                    onOtherDrivesOnly: drives.first { $0.id == location.driveID }?.drive.kind != .builtIn,
+                    status: location.identity == .waitingForQuiescence ? .waitingForCopy : .identifying))
+            },
+            unrecognized: library.unrecognized.map { LibraryContent.Folder(id: $0.id, name: $0.folderName) },
+            banner: crashes.banner,
+            clipboardNotice: crashes.clipboardNotice,
+            onImport: { importing = true },
+            onRefresh: { await library.rescan() },
+            onTryAlternative: { crashes.tryAlternative($0) },
+            onReport: { crashes.report($0.entry) },
+            onDismissBanner: { crashes.dismiss() },
+            detail: { GameDetailView(services: services, gameID: $0) })
+        .sheet(isPresented: $importing) {
+            ImportFlow(library: library)
+        }
+    }
+}
+
+/// The Library screen for one snapshot. The preview renders this directly.
+struct LibraryContent<Detail: View>: View {
+    struct Game: Identifiable {
+        var id: GameID
+        var row: LibraryRowContent
+    }
+
+    /// A folder without a game id: still settling (with a row), or not recognized (name only).
+    struct Folder: Identifiable {
+        var id: UUID
+        var name: String
+        var row: LibraryRowContent?
+
+        init(id: UUID, name: String) {
+            self.id = id
+            self.name = name
+        }
+
+        init(id: UUID, row: LibraryRowContent) {
+            self.id = id
+            name = row.name
+            self.row = row
+        }
+    }
+
+    let games: [Game]
+    let settling: [Folder]
+    let unrecognized: [Folder]
+    let banner: CrashBanner?
+    let clipboardNotice: Bool
+    let onImport: () -> Void
+    let onRefresh: @MainActor () async -> Void
+    let onTryAlternative: (CrashBanner) -> Void
+    let onReport: (CrashBanner) -> Void
+    let onDismissBanner: () -> Void
+    let detail: (GameID) -> Detail
+
+    var body: some View {
+        List {
+            if let banner {
+                Section {
+                    CrashBannerView(banner: banner, clipboardNotice: clipboardNotice,
+                                    onTryAlternative: { onTryAlternative(banner) },
+                                    onReport: { onReport(banner) }, onDismiss: onDismissBanner)
+                }
+            }
+            if games.isEmpty && settling.isEmpty && unrecognized.isEmpty {
+                Section {
+                    LibraryEmptyState()
+                }
+            }
+            if !games.isEmpty || !settling.isEmpty {
+                Section {
+                    ForEach(games) { game in
+                        NavigationLink(destination: detail(game.id)) {
+                            LibraryRow(content: game.row)
+                        }
+                    }
+                    ForEach(settling) { folder in
+                        if let row = folder.row { LibraryRow(content: row) }
+                    }
+                }
+            }
+            if !unrecognized.isEmpty {
+                Section(header: Text("library.unrecognized.title"), footer: Text("library.unrecognized.hint")) {
+                    ForEach(unrecognized) { folder in
+                        Label {
+                            Text(verbatim: folder.name)
+                        } icon: {
+                            Image(systemName: "questionmark.folder")
+                        }
+                    }
+                }
+            }
+        }
+        .listStyle(.insetGrouped)
+        .refreshable { await onRefresh() }
+        .navigationTitle(Text("library.title"))
+        .toolbar {
+            ToolbarItem(placement: .primaryAction) {
+                Button(action: onImport) {
+                    Label("import.button", systemImage: "plus")
+                }
+            }
+        }
+    }
+}
+
+/// No games yet: where games come from.
+private struct LibraryEmptyState: View {
+    var body: some View {
+        VStack(alignment: .leading, spacing: 12) {
+            Text("library.empty.title")
+                .font(.headline)
+            Text(L10n.format("library.empty.builtIn", GameStrings.builtInDriveName))
+            Text("library.empty.drives")
+            Text("library.empty.import")
+        }
+        .padding(.vertical, 8)
+    }
+}
+
+#if DEBUG
+struct LibraryContent_Previews: PreviewProvider {
+    static func content(games: [LibraryContent<Text>.Game] = [], unrecognized: [LibraryContent<Text>.Folder] = [],
+                        banner: CrashBanner? = nil) -> some View {
+        NavigationView {
+            LibraryContent(games: games, settling: [], unrecognized: unrecognized, banner: banner,
+                           clipboardNotice: false, onImport: {}, onRefresh: {}, onTryAlternative: { _ in },
+                           onReport: { _ in }, onDismissBanner: {}, detail: { _ in Text(verbatim: "Detail") })
+        }
+        .navigationViewStyle(.stack)
+    }
+
+    static let games = (1...3).map { index in
+        LibraryContent<Text>.Game(id: .random(), row: LibraryRowContent(
+            name: "Sample Game \(index)", engine: .renpy, architectures: [], badge: .planned, onOtherDrivesOnly: false,
+            status: nil))
+    }
+
+    static var previews: some View {
+        content()
+        content(games: games)
+        content(games: games, unrecognized: [.init(id: UUID(), name: "Sample Folder")])
+        content(games: games, banner: CrashBannerView_Previews.banner(.likelyMemoryKill, alternative: .wineBox64))
+    }
+}
+#endif
diff --git a/App/Library/RemoveGameDialog.swift b/App/Library/RemoveGameDialog.swift
new file mode 100644
index 0000000..71d943f
--- /dev/null
+++ b/App/Library/RemoveGameDialog.swift
@@ -0,0 +1,195 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// Removes a game: optionally deletes chosen folders on connected drives, and optionally
+/// its settings and saves everywhere. With neither, the game's locations are forgotten.
+struct RemoveGameDialog: View {
+    @ObservedObject var library: LibraryController
+    let game: LibraryGame
+    let onRemoved: () -> Void
+    @Environment(\.dismiss) private var dismiss
+    @State private var sizes: [UUID: Int64] = [:]
+    @State private var removing = false
+
+    var body: some View {
+        RemoveGameContent(entries: entries, removing: removing, onConfirm: remove, onCancel: { dismiss() })
+            .task { await measure() }
+    }
+
+    private var entries: [RemoveGameContent.Entry] {
+        game.locations.map { location in
+            let summary = library.drives.first { $0.id == location.driveID }
+            let availability: RemoveGameContent.Availability =
+                location.identity == .missing ? .missing : summary?.state == .available ? .deletable : .notConnected
+            return RemoveGameContent.Entry(id: location.id, folder: location.folderName,
+                                           drive: summary.map { GameStrings.driveLabel($0.drive) } ?? "",
+                                           availability: availability, size: sizes[location.id])
+        }
+    }
+
+    private func remove(_ locations: Set<UUID>, deleteData: Bool) {
+        removing = true
+        Task {
+            await library.remove(game: game.id, deleteLocations: locations, deleteData: deleteData)
+            dismiss()
+            onRemoved()
+        }
+    }
+
+    /// Each deletable folder's size, measured off the main actor.
+    private func measure() async {
+        let manager = library.driveManager
+        let contents = library.context.index.contents
+        let targets = entries.filter { $0.availability == .deletable }.compactMap { entry -> (UUID, String, GameDrive)? in
+            guard let location = contents.location(entry.id), let drive = contents.drive(location.driveID) else { return nil }
+            return (entry.id, location.folderName, drive)
+        }
+        sizes = await Task.detached {
+            var sizes: [UUID: Int64] = [:]
+            for (id, folder, drive) in targets {
+                guard let token = manager.open(drive) else { continue }
+                defer { token.close() }
+                sizes[id] = folderSize(token.url.appendingPathComponent(folder, isDirectory: true))
+            }
+            return sizes
+        }.value
+    }
+}
+
+/// Total size of the regular files under `folder`; symlinks aren't followed.
+private func folderSize(_ folder: URL) -> Int64 {
+    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
+    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
+    var total: Int64 = 0
+    for case let url as URL in enumerator {
+        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
+        total += Int64(values.fileSize ?? 0)
+    }
+    return total
+}
+
+/// The dialog for one set of locations. The preview renders this directly.
+struct RemoveGameContent: View {
+    enum Availability {
+        case deletable, notConnected, missing
+    }
+
+    struct Entry: Identifiable {
+        var id: UUID
+        var folder: String
+        var drive: String
+        var availability: Availability
+        var size: Int64?
+    }
+
+    let entries: [Entry]
+    let removing: Bool
+    let onConfirm: (Set<UUID>, Bool) -> Void
+    let onCancel: () -> Void
+    @State private var chosen: Set<UUID> = []
+    @State private var deleteData = false
+    @State private var confirmingDelete = false
+
+    /// Some folder stays on a drive, so the game comes back with it.
+    private var keepsFiles: Bool {
+        entries.contains { $0.availability != .missing && !chosen.contains($0.id) }
+    }
+
+    var body: some View {
+        NavigationView {
+            Form {
+                Section(header: Text("game.remove.section.files"),
+                        footer: entries.contains { $0.availability == .notConnected } ? Text("game.remove.notConnected.footer") : nil) {
+                    ForEach(entries) { entry in
+                        row(entry)
+                    }
+                }
+                Section(footer: Text("game.remove.data.footer")) {
+                    Toggle("game.remove.data", isOn: $deleteData)
+                }
+                if keepsFiles {
+                    Section {
+                        Text("game.remove.reappears")
+                            .foregroundColor(.secondary)
+                    }
+                }
+                Section {
+                    Button(role: .destructive) {
+                        if chosen.isEmpty {
+                            onConfirm(chosen, deleteData)
+                        } else {
+                            confirmingDelete = true
+                        }
+                    } label: {
+                        Text("game.remove.confirm")
+                    }
+                    .disabled(removing)
+                }
+            }
+            .navigationTitle(Text("game.remove.title"))
+            .navigationBarTitleDisplayMode(.inline)
+            .toolbar {
+                ToolbarItem(placement: .cancellationAction) {
+                    Button("app.cancel", action: onCancel)
+                }
+            }
+            .alert(Text("game.remove.deleteFiles.title"), isPresented: $confirmingDelete) {
+                Button("game.remove.deleteFiles.confirm", role: .destructive) { onConfirm(chosen, deleteData) }
+                Button("app.cancel", role: .cancel) {}
+            } message: {
+                Text(L10n.count("game.remove.deleteFiles.message", chosen.count))
+            }
+        }
+        .navigationViewStyle(.stack)
+        .interactiveDismissDisabled(removing)
+    }
+
+    @ViewBuilder
+    private func row(_ entry: Entry) -> some View {
+        let label = VStack(alignment: .leading, spacing: 2) {
+            Text(verbatim: entry.folder)
+            Text(verbatim: ([entry.drive] + (entry.size.map { [GameStrings.bytes($0)] } ?? []))
+                .filter { !$0.isEmpty }.joined(separator: " · "))
+                .font(.caption)
+                .foregroundColor(.secondary)
+        }
+        switch entry.availability {
+        case .deletable:
+            Toggle(isOn: Binding(
+                get: { chosen.contains(entry.id) },
+                set: { if $0 { chosen.insert(entry.id) } else { chosen.remove(entry.id) } }
+            )) { label }
+        case .notConnected:
+            HStack {
+                label
+                Spacer()
+                Text("drives.state.notConnected")
+                    .foregroundColor(.secondary)
+            }
+        case .missing:
+            HStack {
+                label
+                Spacer()
+                Text("library.status.missing")
+                    .foregroundColor(.secondary)
+            }
+        }
+    }
+}
+
+#if DEBUG
+struct RemoveGameContent_Previews: PreviewProvider {
+    static var previews: some View {
+        RemoveGameContent(entries: [
+            .init(id: UUID(), folder: "Sample Game", drive: "On My iPad/Eikon", availability: .deletable,
+                  size: 1_500_000_000),
+            .init(id: UUID(), folder: "Sample Game", drive: "Sample Drive", availability: .notConnected, size: nil),
+            .init(id: UUID(), folder: "Sample Game", drive: "Sample Drive", availability: .missing, size: nil),
+        ], removing: false, onConfirm: { _, _ in }, onCancel: {})
+        RemoveGameContent(entries: [
+            .init(id: UUID(), folder: "Sample Game", drive: "On My iPad/Eikon", availability: .deletable, size: 4096),
+        ], removing: false, onConfirm: { _, _ in }, onCancel: {})
+    }
+}
+#endif
diff --git a/App/Library/RouteSection.swift b/App/Library/RouteSection.swift
new file mode 100644
index 0000000..fbb7da0
--- /dev/null
+++ b/App/Library/RouteSection.swift
@@ -0,0 +1,139 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// How the game would run: the chosen route with its reasons, then every candidate in
+/// preference order. The candidate list is the override picker: Automatic, or any route,
+/// runnable or not, with its reasons inline.
+struct RouteSection: View {
+    let decision: RouteDecision?
+    /// The stored override; nil is Automatic.
+    let override: RouteID?
+    let jitReason: JITReasonCode?
+    let onSelect: (RouteID?) -> Void
+
+    var body: some View {
+        Section(header: Text("route.section.chosen")) {
+            if let decision {
+                chosen(decision)
+            } else {
+                HStack(spacing: 8) {
+                    ProgressView()
+                    Text("route.deciding")
+                }
+            }
+        }
+        if let decision {
+            Section(header: Text("route.section.candidates"), footer: Text("route.override.footer")) {
+                choice(nil, selected: override == nil) {
+                    Text("route.override.automatic")
+                }
+                ForEach(decision.candidates, id: \.route) { candidate in
+                    choice(candidate.route, selected: override == candidate.route) {
+                        CandidateView(candidate: candidate, jitReason: jitReason)
+                    }
+                }
+            }
+        }
+    }
+
+    @ViewBuilder
+    private func chosen(_ decision: RouteDecision) -> some View {
+        if let chosen = decision.chosen {
+            CandidateView(candidate: chosen, jitReason: jitReason)
+            if decision.isOverride && !decision.overrideWarnings.isEmpty {
+                VStack(alignment: .leading, spacing: 4) {
+                    Label("route.override.warning", systemImage: "exclamationmark.triangle.fill")
+                        .foregroundColor(.orange)
+                    ForEach(decision.overrideWarnings.indices, id: \.self) { index in
+                        Text(RouteStrings.reasonText(decision.overrideWarnings[index], jitReason: jitReason))
+                            .font(.footnote)
+                    }
+                }
+            }
+        } else {
+            Text("route.none")
+        }
+    }
+
+    private func choice(_ route: RouteID?, selected: Bool, @ViewBuilder label: () -> some View) -> some View {
+        Button {
+            onSelect(route)
+        } label: {
+            HStack(alignment: .firstTextBaseline) {
+                label()
+                Spacer()
+                if selected {
+                    Image(systemName: "checkmark")
+                        .foregroundColor(.accentColor)
+                }
+            }
+            .contentShape(Rectangle())
+        }
+        .buttonStyle(.plain)
+        .accessibilityAddTraits(selected ? .isSelected : [])
+    }
+}
+
+/// A route's name, verdict and every reason as a sentence.
+private struct CandidateView: View {
+    let candidate: RouteCandidate
+    let jitReason: JITReasonCode?
+
+    var body: some View {
+        VStack(alignment: .leading, spacing: 4) {
+            HStack(alignment: .firstTextBaseline) {
+                Text(RouteStrings.name(candidate.route))
+                    .font(.body.weight(.semibold))
+                Text(RouteStrings.verdictKey(candidate.verdict))
+                    .font(.caption)
+                    .foregroundColor(.secondary)
+            }
+            ForEach(candidate.reasons.indices, id: \.self) { index in
+                Text(RouteStrings.reasonText(candidate.reasons[index], jitReason: jitReason))
+                    .font(.footnote)
+                    .foregroundColor(.secondary)
+            }
+        }
+    }
+}
+
+#if DEBUG
+struct RouteSection_Previews: PreviewProvider {
+    /// Every verdict, and one of each reason across the candidates.
+    static let candidates: [RouteCandidate] = [
+        RouteCandidate(route: .nativeKirikiri, verdict: .runnable, reasons: [.nativeFirst]),
+        RouteCandidate(route: .wineFEX, verdict: .runnableWithWarnings,
+                       reasons: [.gateUnmeasured(.x18), .fexPreferredWithJIT]),
+        RouteCandidate(route: .wineBox64, verdict: .planned, reasons: [.notInThisBuild, .box64Only32Bit]),
+        RouteCandidate(route: .linuxFEX, verdict: .unavailable,
+                       reasons: [.needsLinuxBinary, .needsJIT, .gateFailed(.x18, stale: false),
+                                 .gateFailed(.guestWindow, stale: true), .gateUnmeasured(GateName(rawValue: "future"))]),
+        RouteCandidate(route: .nativeRenPy, verdict: .unavailable,
+                       reasons: [.engineNotHandled(.kirikiri), .needsWindowsBinary, .architectureUnsupported(.arm64),
+                                 .runtimeDeclined(RuntimeDeclineCode(rawValue: "sample")), .overriddenByUser]),
+    ]
+
+    static var previews: some View {
+        Group {
+            List {
+                RouteSection(decision: RouteDecision(chosen: candidates[0], candidates: candidates, isOverride: false,
+                                                     overrideWarnings: []),
+                             override: nil, jitReason: .sideloadedNoJIT, onSelect: { _ in })
+            }
+            List {
+                RouteSection(decision: RouteDecision(chosen: candidates[3], candidates: candidates, isOverride: true,
+                                                     overrideWarnings: candidates[3].reasons),
+                             override: .linuxFEX, jitReason: nil, onSelect: { _ in })
+            }
+            List {
+                RouteSection(decision: RouteDecision(chosen: nil, candidates: candidates, isOverride: false,
+                                                     overrideWarnings: []),
+                             override: nil, jitReason: nil, onSelect: { _ in })
+                RouteSection(decision: nil, override: nil, jitReason: nil, onSelect: { _ in })
+            }
+        }
+        .listStyle(.insetGrouped)
+    }
+}
+#endif
diff --git a/App/RootView.swift b/App/RootView.swift
index f5c6418..569414c 100644
--- a/App/RootView.swift
+++ b/App/RootView.swift
@@ -12,6 +12,7 @@ struct RootView: View {
     @ObservedObject var services: AppServices
     @ObservedObject var jit: JITController
     @State private var selection: RootDestination? = .library
+    @State private var showUnreadable = false
 
     init(services: AppServices) {
         self.services = services
@@ -33,15 +34,23 @@ struct RootView: View {
             destination(.library)
         }
         .navigationViewStyle(.columns)
-        .alert(Text("storage.unreadable.title"), isPresented: Binding(
-            get: { !services.pendingUnreadable.isEmpty },
-            set: { _ in }
-        )) {
+        // Only after the first frame: on iOS 15 an alert presented in the frame the sidebar
+        // link activates can be dropped.
+        .task {
+            await Task.yield()
+            showUnreadable = !services.pendingUnreadable.isEmpty
+        }
+        .alert(Text("storage.unreadable.title"), isPresented: $showUnreadable) {
             Button("storage.unreadable.keep", role: .cancel) {
                 services.keepUnreadable()
             }
             Button("storage.unreadable.startOver", role: .destructive) {
                 services.startOverUnreadable()
+                // Files that couldn't be set aside are shown again once this alert is gone.
+                Task {
+                    await Task.yield()
+                    showUnreadable = !services.pendingUnreadable.isEmpty
+                }
             }
         } message: {
             Text(unreadableMessage)
@@ -62,12 +71,12 @@ struct RootView: View {
         }
     }
 
-    /// Sections 13–15 replace the placeholders with LibraryView, DrivesView and CreditsView.
+    /// Section 15 replaces the Credits placeholder.
     @ViewBuilder
     private func destination(_ target: RootDestination) -> some View {
         switch target {
-        case .library: DestinationPlaceholder(titleKey: "library.title")
-        case .drives: DestinationPlaceholder(titleKey: "drives.title")
+        case .library: LibraryView(services: services)
+        case .drives: DrivesView(library: services.library)
         case .device: StatusView(controller: jit)
         case .credits: DestinationPlaceholder(titleKey: "credits.title")
         }
diff --git a/App/Strings/GameStrings.swift b/App/Strings/GameStrings.swift
new file mode 100644
index 0000000..efe80c6
--- /dev/null
+++ b/App/Strings/GameStrings.swift
@@ -0,0 +1,64 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+import UIKit
+
+/// The library screens' own presentation states: route badges, launch captions and drive
+/// names. Exhaustive: a new case fails the build until it has a key.
+enum GameStrings {
+    static func badgeKey(_ badge: RouteBadge) -> LocalizedStringKey {
+        switch badge {
+        case .runnable: "route.verdict.runnable"
+        case .warning: "route.verdict.runnableWithWarnings"
+        case .planned: "route.verdict.planned"
+        case .override: "route.badge.override"
+        case .unavailable: "route.badge.unavailable"
+        }
+    }
+
+    /// The line under a disabled Launch button; nil when there is nothing to explain.
+    static func launchCaptionKey(_ state: LaunchState) -> LocalizedStringKey? {
+        switch state {
+        case .ready, .deciding: nil
+        case .confirmFirst: "game.launch.forced"
+        case .planned: "game.launch.planned"
+        case .noRoute: "game.launch.noRoute"
+        case .driveNotConnected: "game.launch.driveNotConnected"
+        case .missing: "game.launch.missing"
+        }
+    }
+
+    static func launchFailureKey(_ failure: SessionPresenter.Failure?) -> LocalizedStringKey {
+        switch failure {
+        case .sessionActive: "game.launch.failed.sessionActive"
+        case .driveNotConnected: "game.launch.driveNotConnected"
+        case .noWindow, nil: "game.launch.failed"
+        }
+    }
+
+    static func identityFailureKey(_ failure: IdentityFailure) -> LocalizedStringKey {
+        switch failure {
+        case .unreadable: "identity.failure.unreadable"
+        case .driveUnavailable: "identity.failure.driveUnavailable"
+        }
+    }
+
+    /// "On My iPad/Eikon" or "On My iPhone/Eikon" for the built-in drive; the folder's
+    /// name for any other.
+    @MainActor
+    static func driveLabel(_ drive: GameDrive) -> String {
+        switch drive.kind {
+        case .builtIn: builtInDriveName
+        case .folder: drive.label
+        }
+    }
+
+    @MainActor
+    static var builtInDriveName: String {
+        L10n.string(UIDevice.current.userInterfaceIdiom == .pad ? "drives.builtIn.pad" : "drives.builtIn.phone")
+    }
+
+    static func bytes(_ count: Int64) -> String {
+        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
+    }
+}
diff --git a/App/en.lproj/Localizable.strings b/App/en.lproj/Localizable.strings
index 466154f..f2bc659 100644
--- a/App/en.lproj/Localizable.strings
+++ b/App/en.lproj/Localizable.strings
@@ -1,8 +1,8 @@
 /* Eikon's English source strings. Keys are namespaced: status.*, install.*, jit.*, device.*,
    report.* (01); library.*, drives.*, import.*, identity.*, game.*, route.*, gate.*,
    engine.*, arch.*, crash.*, credits.*, developer.*, session.* (02); app.* for app-wide
-   startup text and storage.* for the unreadable-file warning. Core code returns codes and
-   enums only; App/Strings/ maps them to these keys. */
+   startup text and buttons, and storage.* for the unreadable-file warning. Core code
+   returns codes and enums only; App/Strings/ maps them to these keys. */
 
 "status.title" = "This device";
 
@@ -214,3 +214,120 @@
 "import.outcome.driveUnavailable" = "This drive isn't connected.";
 "import.outcome.cancelled" = "Import cancelled.";
 "import.outcome.failed" = "The import failed. Nothing was changed on the drive.";
+
+/* App-wide buttons */
+"app.cancel" = "Cancel";
+"app.ok" = "OK";
+
+/* Library screen */
+"library.otherDriveOnly" = "Only on another game drive";
+"library.empty.title" = "No games yet";
+"library.empty.builtIn" = "Games live in game drives. Put a game's folder in “%@” in the Files app.";
+"library.empty.drives" = "Or add a folder on a USB drive under Game drives.";
+"library.empty.import" = "Or tap Import to copy a game into a drive.";
+"library.unrecognized.title" = "Not recognized";
+"library.unrecognized.hint" = "Games must sit directly inside a game drive (one wrapper folder is fine).";
+
+/* Game screen */
+"game.section.game" = "Game";
+"game.section.locations" = "Locations";
+"game.section.crashes" = "Recent problems";
+"game.section.identity" = "Identity";
+"game.name.placeholder" = "Name";
+"game.engine" = "Engine";
+"game.engine.unityScripting" = "Scripting backend";
+"game.engine.version" = "Version";
+"game.engine.kirikiriFlavor" = "Flavor";
+"game.engine.plugins" = "Plugins";
+"game.engine.gameMakerBuild" = "Build type";
+"game.location.forget" = "Forget";
+"game.launch" = "Launch";
+"game.launch.planned" = "Not in this build yet.";
+"game.launch.noRoute" = "No route can run this game here. The reasons are below.";
+"game.launch.forced" = "The route you chose may not work here.";
+"game.launch.driveNotConnected" = "The drive with this game isn't connected.";
+"game.launch.missing" = "The game's folder is missing.";
+"game.launch.anyway.title" = "Launch anyway?";
+"game.launch.anyway.confirm" = "Launch";
+"game.launch.failed.title" = "The game couldn't start";
+"game.launch.failed" = "Something went wrong while starting the game.";
+"game.launch.failed.sessionActive" = "Another game is still running.";
+"game.gone" = "This game is no longer in the library.";
+"game.remove" = "Remove game…";
+"game.remove.title" = "Remove game";
+"game.remove.section.files" = "Delete game files";
+"game.remove.notConnected.footer" = "Files on drives that aren't connected can't be deleted.";
+"game.remove.data" = "Delete settings and saves (on all devices)";
+"game.remove.data.footer" = "Otherwise they stay, and come back if the game is added again.";
+"game.remove.reappears" = "This game will reappear while its folder is on a game drive.";
+"game.remove.confirm" = "Remove";
+"game.remove.deleteFiles.title" = "Delete game files?";
+"game.remove.deleteFiles.confirm" = "Delete";
+
+/* Identity tools */
+"identity.suggestion.several" = "This might be the same game as one of these (a different version). Use one entry?";
+"identity.merge.footer" = "This game's settings, saves and locations join the game you pick.";
+"identity.split.footer" = "The location you pick becomes a game of its own, starting with a copy of this game's settings.";
+"identity.reportID" = "Report ID";
+"identity.verify" = "Verify files";
+"identity.verify.again" = "Verify again";
+"identity.verify.hash" = "SHA-256 of the main data file";
+"identity.verify.failed" = "The file couldn't be read.";
+"identity.retry" = "Retry identifying “%@”";
+"identity.failure.unreadable" = "A file in this game couldn't be read.";
+"identity.failure.driveUnavailable" = "The drive couldn't be opened.";
+
+/* Route section */
+"route.section.chosen" = "Route";
+"route.section.candidates" = "All routes";
+"route.deciding" = "Checking routes…";
+"route.none" = "No route can run this game here.";
+"route.override.automatic" = "Automatic";
+"route.override.footer" = "Pick a route to force it, even one that can't run. Automatic picks the best one.";
+"route.override.warning" = "You chose a route that may not work:";
+"route.badge.override" = "Your choice";
+"route.badge.unavailable" = "Unavailable";
+
+/* Crash banner and history */
+"crash.banner.route" = "%1$@ · %2$@";
+"crash.tryAlternative" = "Try %@ next time";
+"crash.report" = "Report on GitHub";
+"crash.dismiss" = "Dismiss";
+"crash.clipboardNotice" = "The device report is on the clipboard. Paste it into the issue.";
+
+/* Game drives screen */
+"drives.builtIn.pad" = "On My iPad/Eikon";
+"drives.builtIn.phone" = "On My iPhone/Eikon";
+"drives.builtIn.footer" = "This folder is visible in the Files app.";
+"drives.section.other" = "Other drives";
+"drives.free" = "%@ free";
+"drives.add" = "Add game drive…";
+"drives.add.footer" = "Pick a folder on this device or a USB drive. Games in cloud-synced folders may be moved off the device, so avoid them.";
+"drives.relink" = "Find folder…";
+"drives.relink.confirm.title" = "Use this folder?";
+"drives.relink.confirm.message" = "None of this drive's games are in this folder.";
+"drives.relink.confirm.use" = "Use folder";
+"drives.remove" = "Remove drive";
+"drives.remove.title" = "Remove drive?";
+"drives.remove.message" = "Its games leave the library. The files on the drive and the games' settings stay.";
+"drives.remove.confirm" = "Remove";
+
+/* Import sheet */
+"import.button" = "Import game";
+"import.title" = "Import game";
+"import.choose" = "Choose game folder…";
+"import.choose.footer" = "The game's files are copied into a game drive. The original folder is not changed.";
+"import.chooseAnother" = "Choose another folder…";
+"import.chooseDrive" = "Choose another drive";
+"import.checking" = "Looking for a game…";
+"import.drive.header" = "Copy to";
+"import.size" = "Size: %@";
+"import.willCopy" = "The game's files will be copied to %@. The original folder is not changed.";
+"import.start" = "Import";
+"import.replace" = "Replace existing copy";
+"import.replace.footer" = "Replacing keeps the game's settings and saves: this is how an update is installed.";
+"import.rename" = "Import with another name…";
+"import.rename.placeholder" = "Folder name";
+"import.space.detail" = "The copy needs %1$@, and the drive has %2$@ free.";
+"import.progress" = "%1$@ of %2$@";
+"import.copying.footer" = "Keep Eikon open until the copy finishes.";
diff --git a/App/en.lproj/Localizable.stringsdict b/App/en.lproj/Localizable.stringsdict
index f0adde5..0734651 100644
--- a/App/en.lproj/Localizable.stringsdict
+++ b/App/en.lproj/Localizable.stringsdict
@@ -66,5 +66,37 @@
 			<string>%d drives</string>
 		</dict>
 	</dict>
+	<key>identity.count.versions</key>
+	<dict>
+		<key>NSStringLocalizedFormatKey</key>
+		<string>%#@versions@</string>
+		<key>versions</key>
+		<dict>
+			<key>NSStringFormatSpecTypeKey</key>
+			<string>NSStringPluralRuleType</string>
+			<key>NSStringFormatValueTypeKey</key>
+			<string>d</string>
+			<key>one</key>
+			<string>%d version known</string>
+			<key>other</key>
+			<string>%d versions known</string>
+		</dict>
+	</dict>
+	<key>game.remove.deleteFiles.message</key>
+	<dict>
+		<key>NSStringLocalizedFormatKey</key>
+		<string>%#@folders@</string>
+		<key>folders</key>
+		<dict>
+			<key>NSStringFormatSpecTypeKey</key>
+			<string>NSStringPluralRuleType</string>
+			<key>NSStringFormatValueTypeKey</key>
+			<string>d</string>
+			<key>one</key>
+			<string>The game folder you checked is deleted from its drive. This can’t be undone.</string>
+			<key>other</key>
+			<string>The %d game folders you checked are deleted from their drives. This can’t be undone.</string>
+		</dict>
+	</dict>
 </dict>
 </plist>
diff --git a/Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift b/Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift
index 711d48f..28f3c42 100644
--- a/Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift
+++ b/Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift
@@ -14,6 +14,17 @@ public struct CrashBanner: Identifiable, Equatable, Sendable {
     public var startedAt: Date
     /// Offered as "Try <route> next time" only when non-nil.
     public var alternative: RouteID?
+
+    public init(id: UUID, entry: CrashEntry, outcome: SessionOutcome, gameName: String?, route: String, startedAt: Date,
+                alternative: RouteID?) {
+        self.id = id
+        self.entry = entry
+        self.outcome = outcome
+        self.gameName = gameName
+        self.route = route
+        self.startedAt = startedAt
+        self.alternative = alternative
+    }
 }
 
 /// Turns the previous launch's unfinished session into a history entry and, when the
diff --git a/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift b/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
index 9da62ab..b4357a1 100644
--- a/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
+++ b/Packages/EikonKit/Sources/EikonKit/Library/LibraryController.swift
@@ -15,6 +15,13 @@ public struct DriveSummary: Sendable, Equatable, Identifiable {
     public var freeBytes: Int64?
     public var gameCount: Int
     public var id: UUID { drive.id }
+
+    public init(drive: GameDrive, state: DriveState, freeBytes: Int64?, gameCount: Int) {
+        self.drive = drive
+        self.state = state
+        self.freeBytes = freeBytes
+        self.gameCount = gameCount
+    }
 }
 
 /// A game's overall status, from its locations.
@@ -281,6 +288,14 @@ public final class LibraryController: ObservableObject {
         refresh()
     }
 
+    /// Drops a missing location from the index. Nothing on disk is touched; the folder, if
+    /// it comes back, is found again by the next scan.
+    public func forget(location: UUID) {
+        worker.cancel([location])
+        context.index.update { $0.locations.removeAll { $0.id == location && $0.identity == .missing } }
+        refresh()
+    }
+
     /// A drive's immediate child with this name, or nil when the name could reach elsewhere.
     nonisolated private static func gameFolder(_ name: String, in root: URL) -> URL? {
         guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }

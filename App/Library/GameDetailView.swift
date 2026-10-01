import EikonCore
import EikonKit
import SwiftUI

/// Whether the Launch button works, and why not.
enum LaunchState: Equatable, CaseIterable {
    case ready
    /// A forced route that can't run: allowed after "Launch anyway?".
    case confirmFirst
    /// The route decision hasn't been computed yet.
    case deciding
    case planned
    case noRoute
    case driveNotConnected
    case missing

    /// The launch location needs a reachable drive and a present folder; the chosen route
    /// must be built into this app.
    init(location: LaunchLocation, decision: RouteDecision?, isBuilt: (RouteID) -> Bool) {
        switch location {
        case .driveNotConnected:
            self = .driveNotConnected
            return
        case .missing:
            self = .missing
            return
        case .ready:
            break
        }
        guard let decision else {
            self = .deciding
            return
        }
        guard let chosen = decision.chosen else {
            self = .noRoute
            return
        }
        guard chosen.verdict != .planned, isBuilt(chosen.route) else {
            self = .planned
            return
        }
        switch chosen.verdict {
        case .runnable, .runnableWithWarnings: self = .ready
        case .unavailable: self = decision.isOverride ? .confirmFirst : .noRoute
        case .planned: self = .planned
        }
    }

    var canLaunch: Bool {
        self == .ready || self == .confirmFirst
    }
}

/// Why a launch didn't start.
enum LaunchFailure: Equatable {
    case sessionActive, driveNotConnected, missing, other

    init(_ failure: SessionPresenter.Failure?) {
        switch failure {
        case .sessionActive: self = .sessionActive
        case .driveNotConnected: self = .driveNotConnected
        case .noWindow, nil: self = .other
        }
    }
}

/// One game, looked up by id on every update so a merge that moves it to another id
/// follows along. Shows a placeholder once the game is gone. Sheets and alerts hang off
/// the whole view, so a game that stops resolving doesn't tear them down mid-flow.
struct GameDetailView: View {
    /// Each sheet keeps the game as it was when opened.
    private enum Sheet: Identifiable {
        case merge(LibraryGame), split(LibraryGame), remove(LibraryGame)

        var id: Int {
            switch self {
            case .merge: 0
            case .split: 1
            case .remove: 2
            }
        }
    }

    let services: AppServices
    let gameID: GameID
    @ObservedObject private var library: LibraryController
    @ObservedObject private var settings: SettingsController
    @ObservedObject private var crashes: CrashReportController
    @ObservedObject private var jit: JITController
    @StateObject private var verifier = FileVerifier()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var draftName = ""
    @State private var sheet: Sheet?
    @State private var removed = false
    @State private var confirmingForced = false
    @State private var launching = false
    @State private var launchFailure: LaunchFailure?

    init(services: AppServices, gameID: GameID) {
        self.services = services
        self.gameID = gameID
        library = services.library
        settings = services.settings
        crashes = services.crashes
        jit = services.jit
    }

    private var links: [GameID: GameID] { settings.store.mergeLinks() }

    private var resolvedID: GameID { IdentityMatcher.resolve(gameID, links: links) }

    private var game: LibraryGame? {
        let id = resolvedID
        return library.games.first { $0.id == id }
    }

    var body: some View {
        let game = game
        Group {
            if let game {
                detail(game)
            } else {
                Text("game.gone")
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .navigationTitle(Text(verbatim: game?.displayName ?? ""))
        .onAppear {
            guard let game else { return }
            draftName = game.displayName
            library.setViewedLocation(game.locations.first?.id)
        }
        .onDisappear {
            library.setViewedLocation(nil)
            verifier.cancel()
        }
        .onChange(of: game?.displayName) { name in
            if !nameFocused, let name { draftName = name }
        }
        .onChange(of: nameFocused) { focused in
            if !focused { commitName() }
        }
        .sheet(item: $sheet, onDismiss: {
            if removed { dismiss() }
        }) { sheet in
            switch sheet {
            case .merge(let game):
                MergePicker(games: library.games.filter { $0.id != game.id }.map { GameChoice(id: $0.id, name: $0.displayName) },
                            onPick: { target in Task { await library.merge(game.id, into: target) } })
            case .split(let game):
                SplitPicker(locations: game.locations.map { location in
                    SplitPicker.Choice(id: location.id, drive: driveName(location.driveID), folder: location.folderName)
                }, onPick: { library.split(location: $0) })
            case .remove(let game):
                RemoveGameDialog(library: library, game: game, onRemoved: { removed = true })
            }
        }
        .alert(Text("game.launch.anyway.title"), isPresented: $confirmingForced) {
            Button("game.launch.anyway.confirm") { launch(resolvedID) }
            Button("app.cancel", role: .cancel) {}
        } message: {
            Text((library.decisions[resolvedID]?.overrideWarnings ?? [])
                .map { RouteStrings.reasonText($0, jitReason: jit.status.reason) }
                .joined(separator: "\n"))
        }
        .alert(Text("game.launch.failed.title"), isPresented: Binding(
            get: { launchFailure != nil },
            set: { if !$0 { launchFailure = nil } }
        ), presenting: launchFailure) { _ in
            Button("app.ok", role: .cancel) {}
        } message: { failure in
            Text(GameStrings.launchFailureKey(failure))
        }
    }

    private func detail(_ game: LibraryGame) -> some View {
        let decision = library.decisions[game.id]
        let launchLocation = library.launchLocation(for: game.id)
        let state = LaunchState(location: launchLocation, decision: decision,
                                isBuilt: { services.registry.runtimeType(for: $0) != nil })
        let history = crashes.history(for: game.id, links: links)
        return List {
            if !game.suggestions.isEmpty {
                Section {
                    IdentitySuggestion(candidates: game.suggestions.map(choice),
                                       onMerge: { target in Task { await library.merge(game.id, into: target) } },
                                       onKeepSeparate: { keepSeparate(game) })
                }
            }
            Section(header: Text("game.section.game")) {
                TextField(L10n.string("game.name.placeholder"), text: $draftName)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(commitName)
                if let detection = game.detection {
                    EngineRows(detection: detection)
                }
            }
            Section(header: Text("game.section.locations")) {
                ForEach(game.locations) { location in
                    locationRow(location)
                }
            }
            Section {
                LaunchButton(state: state, launching: launching) {
                    if state == .confirmFirst {
                        confirmingForced = true
                    } else {
                        launch(game.id)
                    }
                }
            }
            RouteSection(decision: decision, override: settings.routeOverride(for: game.id),
                         jitReason: jit.status.reason,
                         onSelect: { settings.setRouteOverride($0, for: game.id) })
            if !history.isEmpty {
                Section(header: Text("game.section.crashes"),
                        footer: crashes.clipboardNotice ? Text("crash.clipboardNotice") : nil) {
                    ForEach(history) { entry in
                        CrashHistoryRow(entry: entry) { crashes.report(entry) }
                    }
                }
            }
            Section {
                DisclosureGroup {
                    identityRows(game, canVerify: verifyTarget(launchLocation) != nil)
                } label: {
                    Text("game.section.identity")
                }
            }
            Section {
                Button(role: .destructive) {
                    sheet = .remove(game)
                } label: {
                    Text("game.remove")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Rows

    private func locationRow(_ location: GameLocation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: location.folderName)
                Text(verbatim: driveName(location.driveID))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if case .failed(let failure) = location.identity {
                    Text(GameStrings.identityFailureKey(failure))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if location.identity == .missing {
                Text("library.status.missing")
                    .foregroundColor(.secondary)
                Button("game.location.forget") { library.forget(location: location.id) }
                    .buttonStyle(.borderless)
            } else if let state = library.drives.first(where: { $0.id == location.driveID })?.state {
                Text(LibraryStrings.driveStateKey(state))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func identityRows(_ game: LibraryGame, canVerify: Bool) -> some View {
        HStack {
            Text("identity.reportID")
            Spacer()
            Text(verbatim: game.id.reportID)
                .font(.body.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        Text(L10n.count("identity.count.versions", settings.store.fingerprints(game: game.id.uuid).count))
            .foregroundColor(.secondary)
        Button("identity.sameGameAs") { sheet = .merge(game) }
            .disabled(library.games.count < 2)
        if game.locations.count > 1 {
            Button("identity.differentGame") { sheet = .split(game) }
        }
        verifyRows(game, canVerify: canVerify)
        ForEach(game.locations.filter { if case .failed = $0.identity { true } else { false } }) { location in
            Button(L10n.format("identity.retry", location.folderName)) { library.retryFingerprint(location.id) }
        }
    }

    @ViewBuilder
    private func verifyRows(_ game: LibraryGame, canVerify: Bool) -> some View {
        switch verifier.state {
        case .idle:
            Button("identity.verify") { verify(game.id) }
                .disabled(!canVerify)
        case .running(let progress):
            HStack {
                ProgressView(value: progress)
                Button("app.cancel") { verifier.cancel() }
                    .buttonStyle(.borderless)
            }
        case .done(let hash):
            VStack(alignment: .leading, spacing: 4) {
                Text("identity.verify.hash")
                Text(verbatim: hash)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button("identity.verify.again") { verify(game.id) }
                .disabled(!canVerify)
        case .failed:
            Text("identity.verify.failed")
                .foregroundColor(.secondary)
            Button("identity.verify") { verify(game.id) }
                .disabled(!canVerify)
        }
    }

    // MARK: Actions

    private func choice(_ id: GameID) -> GameChoice {
        GameChoice(id: id, name: library.games.first { $0.id == id }?.displayName ?? id.reportID)
    }

    /// Commits the name on Return or when the field loses focus; never per keystroke.
    private func commitName() {
        guard let game, draftName.trimmingCharacters(in: .whitespacesAndNewlines) != game.displayName else { return }
        settings.setDisplayName(draftName, for: game.id)
        draftName = self.game?.displayName ?? draftName
    }

    /// Dismisses every pending suggestion on the game's locations.
    private func keepSeparate(_ game: LibraryGame) {
        for location in game.locations {
            for suggested in location.suggestion {
                library.dismissSuggestion(suggested, on: location.id)
            }
        }
    }

    private func driveName(_ id: UUID) -> String {
        library.drives.first { $0.id == id }.map { GameStrings.driveLabel($0.drive) } ?? ""
    }

    /// Re-checks drives, then starts the session on the chosen route.
    private func launch(_ game: GameID) {
        launching = true
        Task {
            defer { launching = false }
            await library.reevaluateDriveStates()
            let location: GameLocation
            switch library.launchLocation(for: game) {
            case .ready(let ready): location = ready
            case .driveNotConnected:
                launchFailure = .driveNotConnected
                return
            case .missing:
                launchFailure = .missing
                return
            }
            guard let route = library.decisions[game]?.chosen?.route,
                  let runtime = services.registry.runtimeType(for: route) else {
                launchFailure = .other
                return
            }
            do {
                try await services.presenter.launch(location, game: game, route: route, runtime: runtime)
            } catch {
                launchFailure = LaunchFailure(error as? SessionPresenter.Failure)
            }
        }
    }

    /// The reachable location whose key file "Verify files" hashes, with its drive.
    private func verifyTarget(_ launch: LaunchLocation) -> (GameLocation, DetectionResult, String, GameDrive)? {
        guard case .ready(let location) = launch, let detection = location.detection, let keyFile = detection.keyFile,
              let drive = library.context.index.contents.drive(location.driveID) else { return nil }
        return (location, detection, keyFile, drive)
    }

    /// Hashes the launch location's key file. The hash is shown on screen only.
    private func verify(_ game: GameID) {
        guard let (location, detection, keyFile, drive) = verifyTarget(library.launchLocation(for: game)) else {
            verifier.fail()
            return
        }
        let manager = library.driveManager
        verifier.run { progress, isCancelled in
            guard let token = manager.open(drive) else { throw CocoaError(.fileNoSuchFile) }
            defer { token.close() }
            var root = token.url.appendingPathComponent(location.folderName, isDirectory: true)
            if !detection.gameRoot.isEmpty { root.appendPathComponent(detection.gameRoot, isDirectory: true) }
            return try FileHasher.sha256(of: root.appendingPathComponent(keyFile), progress: progress,
                                         isCancelled: isCancelled)
        }
    }
}

/// Runs one "Verify files" hash off the main actor, with progress and cancel.
@MainActor
final class FileVerifier: ObservableObject {
    enum State: Equatable {
        case idle, running(Double), done(String), failed
    }

    @Published private(set) var state = State.idle
    /// The running hash's switch; a finished or replaced run's late updates are ignored.
    private var current: CancelSwitch?

    typealias Work = @Sendable (_ progress: (Double) -> Void, _ isCancelled: () -> Bool) throws -> String

    func run(_ work: @escaping Work) {
        current?.set()
        let flag = CancelSwitch()
        current = flag
        state = .running(0)
        Task.detached { [weak self] in
            var reported = -1.0
            let hash = try? work({ progress in
                guard progress - reported >= 0.01 || progress == 1 else { return }
                reported = progress
                Task { @MainActor in
                    guard let self, self.current === flag else { return }
                    self.state = .running(progress)
                }
            }, { flag.isSet })
            await MainActor.run {
                guard let self, self.current === flag else { return }
                self.current = nil
                self.state = hash.map(State.done) ?? .failed
            }
        }
    }

    func cancel() {
        current?.set()
        current = nil
        if case .running = state { state = .idle }
    }

    func fail() {
        current?.set()
        current = nil
        state = .failed
    }
}

/// A one-way cancel switch, safe from any thread.
final class CancelSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Engine details and the architecture per platform.
struct EngineRows: View {
    let detection: DetectionResult

    var body: some View {
        let details = detection.details
        row("game.engine", Text(EngineStrings.name(detection.engine)))
        if let scripting = details.unityScripting {
            row("game.engine.unityScripting", Text(EngineStrings.key(scripting)))
        }
        if let version = details.unityVersion {
            row("game.engine.version", Text(verbatim: version))
        }
        if let version = details.renpyVersion {
            row("game.engine.version", Text(EngineStrings.text(version)))
        }
        if let flavor = details.kirikiriFlavor {
            row("game.engine.kirikiriFlavor", Text(EngineStrings.key(flavor)))
        }
        if !details.pluginFileNames.isEmpty {
            row("game.engine.plugins", Text(verbatim: details.pluginFileNames.joined(separator: ", ")))
        }
        if let build = details.gameMakerBuild {
            row("game.engine.gameMakerBuild", Text(EngineStrings.key(build)))
        }
        ForEach(GamePlatform.allCases.filter { detection.executables[$0] != nil }, id: \.self) { platform in
            row(EngineStrings.key(platform), Text(EngineStrings.name(detection.executables[platform]!.architecture)))
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            value
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LaunchButton: View {
    let state: LaunchState
    let launching: Bool
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onLaunch) {
                HStack {
                    Label("game.launch", systemImage: "play.fill")
                    if launching {
                        Spacer()
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!state.canLaunch || launching)
            if let caption = GameStrings.launchCaptionKey(state) {
                Text(caption)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// One past session that ended badly, with a way to report it now.
struct CrashHistoryRow: View {
    let entry: CrashEntry
    let onReport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CrashStrings.outcomeKey(entry.outcome))
            Text(L10n.format("crash.banner.route", RouteStrings.name(recorded: entry.record.route),
                             entry.record.startedAt.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption)
                .foregroundColor(.secondary)
            Button("crash.report", action: onReport)
                .buttonStyle(.borderless)
        }
    }
}

#if DEBUG
struct GameDetailParts_Previews: PreviewProvider {
    static let detection = DetectionResult(
        engine: .kirikiri,
        details: EngineDetails(unityScripting: .il2cpp, unityVersion: "2021.3", kirikiriFlavor: .krkrZ,
                               pluginFileNames: ["plugin-a", "plugin-b"], renpyVersion: .exact(7, 4, 11),
                               gameMakerBuild: .yyc),
        gameRoot: "",
        executables: [
            .windows: ExecutableInfo(path: "game.exe", format: .pe, architecture: .i386, machine: 0x14c, isGUI: true),
            .linux: ExecutableInfo(path: "game", format: .elf, architecture: .amd64, machine: 62, isGUI: nil),
        ],
        keyFile: "data.xp3", detectorVersion: 1)

    static var previews: some View {
        List {
            Section {
                EngineRows(detection: detection)
            }
            Section {
                ForEach(LaunchState.allCases, id: \.self) { state in
                    LaunchButton(state: state, launching: false, onLaunch: {})
                }
                LaunchButton(state: .ready, launching: true, onLaunch: {})
            }
            Section {
                CrashHistoryRow(entry: CrashBannerView_Previews.banner(.killedInBackground, alternative: nil).entry,
                                onReport: {})
            }
        }
        .listStyle(.insetGrouped)
    }
}
#endif

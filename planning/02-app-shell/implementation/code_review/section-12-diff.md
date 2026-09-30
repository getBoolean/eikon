diff --git a/App/AppServices.swift b/App/AppServices.swift
new file mode 100644
index 0000000..7d53d3a
--- /dev/null
+++ b/App/AppServices.swift
@@ -0,0 +1,161 @@
+import Combine
+import EikonCore
+import EikonKit
+import UIKit
+
+/// Why the app's data couldn't be opened at launch; a code only.
+struct StartupFailure: Error {
+    var code: String
+}
+
+/// The app's long-lived objects, created once in `EikonApp.init` in the plan's order.
+@MainActor
+final class AppServices {
+    let jit: JITController
+    let registry: RuntimeRegistry
+    let settings: SettingsController
+    let gates: GateStore
+    let hooks: GameDataHooks
+    let library: LibraryController
+    let crashHistory: CrashHistory
+    let crashes: CrashReportController
+    let presenter: SessionPresenter
+    private let routeEnvironment: AppRouteEnvironment
+    private var subscriptions: Set<AnyCancellable> = []
+
+    /// After `JITController.gatherFacts()`: runtimes, then the stores and controllers (the
+    /// crash controller consumes the last session's sentinel here, before anything can arm
+    /// one), then stale staging cleanup and the first scans.
+    static func start(jit: JITController) -> Result<AppServices, StartupFailure> {
+        do {
+            return .success(try AppServices(jit: jit))
+        } catch {
+            return .failure(StartupFailure(code: "\((error as NSError).domain)#\((error as NSError).code)"))
+        }
+    }
+
+    private init(jit: JITController) throws {
+        self.jit = jit
+
+        // 2. Runtimes: none in split 02 (the developer test pattern is not a route).
+        registry = RuntimeRegistry()
+
+        // 3. Stores and controllers.
+        settings = try SettingsController.live()
+        gates = GateStore.live()
+        hooks = GameDataHooks()
+        library = try LibraryController.live(settings: settings, hooks: hooks)
+        let sessions = LibraryPaths.support.appendingPathComponent("sessions", isDirectory: true)
+        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
+        crashHistory = CrashHistory(directory: sessions)
+        routeEnvironment = AppRouteEnvironment(jit: jit, gates: gates, registry: registry)
+        crashes = CrashReportController(dependencies: Self.crashDependencies(
+            sentinel: SessionSentinel(directory: sessions), history: crashHistory, jit: jit, gates: gates,
+            settings: settings, library: library))
+        presenter = SessionPresenter(library: library, settings: settings)
+
+        routeEnvironment.library = library
+        library.environmentSource = routeEnvironment
+        observeRouteInputs()
+
+        // 4–5. Clean interrupted imports, check drives, start scanning.
+        let library = library
+        Task { await library.start() }
+    }
+
+    /// Every file a store left untouched because it couldn't be read.
+    var unreadableFiles: [URL] {
+        stores.flatMap(\.unreadableFiles)
+    }
+
+    /// Keeps each unreadable file as a backup and lets its store save a fresh one.
+    func startOverUnreadable() {
+        for store in stores where !store.unreadableFiles.isEmpty {
+            store.startOver()
+        }
+        library.invalidateRoutes()
+    }
+
+    private var stores: [any UnreadableFileReporting] {
+        [settings.store, library.context.index, gates, crashHistory]
+    }
+
+    /// Route decisions follow JIT, gates and the runtime registry; the library already
+    /// watches overrides. The crash banner's offer follows the decisions.
+    private func observeRouteInputs() {
+        let library = library
+        gates.onChange = { Task { @MainActor in library.invalidateRoutes() } }
+        jit.objectWillChange
+            .receive(on: RunLoop.main)
+            .sink { library.invalidateRoutes() }
+            .store(in: &subscriptions)
+        registry.$builtRoutes
+            .dropFirst()
+            .receive(on: RunLoop.main)
+            .sink { _ in library.invalidateRoutes() }
+            .store(in: &subscriptions)
+        let crashes = crashes
+        library.$decisions
+            .dropFirst()
+            .sink { _ in crashes.refreshAlternative() }
+            .store(in: &subscriptions)
+    }
+
+    private static func crashDependencies(sentinel: SessionSentinel, history: CrashHistory, jit: JITController,
+                                          gates: GateStore, settings: SettingsController,
+                                          library: LibraryController) -> CrashReportController.Dependencies {
+        func resolved(_ game: GameID) -> GameID {
+            IdentityMatcher.resolve(game, links: settings.store.mergeLinks())
+        }
+        return CrashReportController.Dependencies(
+            sentinel: sentinel, history: history, repository: repositoryURL,
+            routeDecision: { library.decisions[resolved($0)] },
+            displayName: { game in library.games.first { $0.id == resolved(game) }?.displayName },
+            setRouteOverride: { settings.setRouteOverride($1, for: resolved($0)) },
+            deviceReport: {
+                DeviceReport.make(app: AppInfo.from(.main), installMethod: jit.installMethod, evidence: jit.evidence,
+                                  jit: jit.status, system: LiveDeviceSystem.current(), now: Date(), gates: gates.current())
+            },
+            openURL: { UIApplication.shared.open($0) },
+            copyToPasteboard: { try? ReportExport.copy($0) })
+    }
+
+    /// `EKRepositoryURL`, or the project's own repository when the key is missing or invalid.
+    private static var repositoryURL: URL {
+        (Bundle.main.object(forInfoDictionaryKey: "EKRepositoryURL") as? String).flatMap(URL.init(string:))
+            ?? URL(string: "https://github.com/getBoolean/eikon")!
+    }
+}
+
+/// What the route picker knows about this device: JIT, gates, built runtimes, and the
+/// built runtimes' checks for the game's launch location.
+@MainActor
+final class AppRouteEnvironment: RouteEnvironmentSource {
+    weak var library: LibraryController?
+    private let jit: JITController
+    private let gates: GateStore
+    private let registry: RuntimeRegistry
+
+    init(jit: JITController, gates: GateStore, registry: RuntimeRegistry) {
+        self.jit = jit
+        self.gates = gates
+        self.registry = registry
+    }
+
+    func environment(for game: GameID, detection: DetectionResult) async -> RouteEnvironment {
+        RouteEnvironment(jitUsable: jit.status.usable, gates: gates.states(), builtRoutes: registry.builtRoutes,
+                         runtimeChecks: await runtimeChecks(for: game, detection: detection))
+    }
+
+    /// Missing checks mean "ok", so a game without a full fingerprint yet (no build key) or
+    /// without a reachable location simply has none.
+    private func runtimeChecks(for game: GameID, detection: DetectionResult) async -> [RouteID: RuntimeCheck] {
+        guard !registry.builtRoutes.isEmpty, let library, case .ready(let location) = library.launchLocation(for: game),
+              let build = location.fingerprint?.exact, let drive = library.context.index.contents.drive(location.driveID),
+              let token = library.driveManager.open(drive) else { return [:] }
+        defer { token.close() }
+        let folder = token.url.appendingPathComponent(location.folderName, isDirectory: true)
+        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
+        return await registry.checks(detection: detection, root: root, cacheKey: RuntimeCheckKey(gameID: game, build: build))
+    }
+}
diff --git a/App/EikonApp.swift b/App/EikonApp.swift
index 96edb20..3a7907d 100644
--- a/App/EikonApp.swift
+++ b/App/EikonApp.swift
@@ -3,21 +3,46 @@ import SwiftUI
 
 @main
 struct EikonApp: App {
-    @ObservedObject private var jit = JITController.shared
     @Environment(\.scenePhase) private var scenePhase
+    private let services: Result<AppServices, StartupFailure>
 
+    /// Order matters (plan §12.1): JIT facts first, so crash outcomes and reports see them;
+    /// then `AppServices` registers runtimes, creates the stores and controllers (consuming
+    /// the last session), cleans interrupted imports and starts the scans.
     init() {
         JITController.shared.gatherFacts()
+        services = AppServices.start(jit: .shared)
     }
 
     var body: some Scene {
         WindowGroup {
-            StatusView(controller: jit)
-                .onChange(of: scenePhase) { phase in
-                    if phase == .active {
-                        jit.sceneBecameActive()
+            switch services {
+            case .success(let services):
+                RootView(services: services)
+                    .onChange(of: scenePhase) { phase in
+                        sceneChanged(phase, services)
                     }
-                }
+            case .failure(let failure):
+                StartupFailureView(failure: failure)
+            }
+        }
+    }
+
+    private func sceneChanged(_ phase: ScenePhase, _ services: AppServices) {
+        switch phase {
+        case .active:
+            services.jit.sceneBecameActive()
+            let library = services.library
+            Task {
+                await library.reevaluateDriveStates()
+                await library.rescan()
+            }
+        case .background:
+            services.settings.flush()
+        case .inactive:
+            break
+        @unknown default:
+            break
         }
     }
 }
diff --git a/App/Localizable.strings b/App/Localizable.strings
deleted file mode 100644
index 70a2ed2..0000000
--- a/App/Localizable.strings
+++ /dev/null
@@ -1,98 +0,0 @@
-/* Eikon status screen. English. The later localisation split moves this into en.lproj. */
-
-"status.title" = "Eikon";
-
-/* Section headers */
-"status.section.app" = "App";
-"status.section.install" = "Install";
-"status.section.jit" = "JIT";
-"status.section.device" = "Device";
-"status.section.report" = "Report";
-
-/* App section */
-"status.app.version" = "Version";
-"status.app.version.format" = "%1$@ (%2$@)";
-"status.app.commit" = "Commit";
-"status.app.packageKind" = "Package kind";
-"status.app.bundleId" = "Bundle ID";
-
-/* Shared values */
-"status.value.unknown" = "unknown";
-"status.value.yes" = "yes";
-"status.value.no" = "no";
-
-/* Install section */
-"install.method.label" = "Detected method";
-"install.method.dopamine" = "Dopamine";
-"install.method.rootlessJailbreak" = "rootless jailbreak";
-"install.method.trollStore" = "TrollStore";
-"install.method.trollStoreLite" = "TrollStore Lite";
-"install.method.sideloaded" = "sideloaded";
-"install.method.simulator" = "simulator";
-"install.method.unknown" = "unknown";
-
-/* JIT section */
-"jit.state.usable" = "Usable";
-"jit.state.notUsable" = "Not usable";
-"jit.pending" = "Waiting for TrollStore…";
-
-"jit.source.label" = "Source";
-"jit.source.none" = "none";
-"jit.source.dopamine" = "Dopamine";
-"jit.source.rootlessJailbreak" = "rootless jailbreak";
-"jit.source.trollStore" = "TrollStore";
-"jit.source.externalEnabler" = "external enabler";
-"jit.source.preexisting" = "already enabled at launch";
-"jit.source.unknown" = "unknown";
-
-"jit.csDebugged.label" = "CS_DEBUGGED";
-"jit.seen.atLaunch" = "at launch";
-"jit.seen.afterTrollStoreRequest" = "after TrollStore request";
-"jit.seen.onForeground" = "on returning to the app";
-
-"jit.probe.label" = "Probe";
-"jit.probe.notRun" = "not run";
-"jit.probe.passed" = "passed";
-"jit.probe.failed" = "failed";
-
-"jit.txm.label" = "TXM";
-"jit.txm.present" = "present";
-"jit.txm.absent" = "absent";
-"jit.txm.unknown" = "unknown";
-"jit.txm.enforced" = "enforced";
-"jit.txm.notEnforced" = "not enforced";
-
-"jit.retryJIT" = "Retry JIT";
-"jit.retryProbe" = "Retry probe";
-
-/* One cause-and-fix text per JITReasonCode */
-"jit.reason.dopamineJITOff" = "Dopamine didn't enable JIT for Eikon. Turn on “Allow JIT in Apps” in Dopamine's settings, make sure tweak injection isn't disabled for Eikon and the device isn't in safe mode, then relaunch Eikon. Dopamine 2.0 doesn't provide JIT; update to 2.1 or later.";
-"jit.reason.rootlessJailbreakNoJIT" = "This jailbreak didn't enable JIT for Eikon. Features that need JIT are unavailable; everything else still works.";
-"jit.reason.trollStoreRequestPending" = "Asking TrollStore to enable JIT…";
-"jit.reason.trollStoreTimedOut" = "TrollStore didn't enable JIT. Update TrollStore to 2.0.12 or later and make sure its URL scheme is enabled in TrollStore's settings, then tap Retry JIT.";
-"jit.reason.sideloadedNoJIT" = "JIT isn't enabled for this install. Features that need JIT are unavailable; everything else still works.";
-"jit.reason.txmEnforced" = "This device requires a debugger to approve JIT code. Enabling JIT with an enabler won't make it usable here yet. Native routes still work.";
-"jit.reason.txmUndetermined" = "Eikon couldn't confirm whether this device requires debugger approval for JIT, so JIT is treated as unavailable to be safe. Native routes still work. A device report helps fix this.";
-"jit.reason.probeSkippedAfterCrash" = "The last launch ended during the JIT check, so it was skipped this time. Tap Retry probe to run it again.";
-"jit.reason.probeFailed" = "JIT appears to be enabled, but a test of it failed (details below). Tap Retry probe, and please share a device report.";
-"jit.reason.unknownInstallNoJIT" = "Eikon couldn't tell how it was installed, and JIT isn't enabled. Features that need JIT are unavailable; everything else still works.";
-"jit.reason.simulator" = "JIT is never enabled in the simulator.";
-
-/* Device section */
-"device.model" = "Model identifier";
-"device.chip" = "Chip";
-"device.os" = "iOS";
-"device.os.format" = "%1$@ (%2$@)";
-"device.memory" = "Available memory";
-
-/* Report section */
-"report.copy" = "Copy report";
-"report.share" = "Share report";
-"report.copied" = "Copied";
-"report.error" = "Couldn't build the report.";
-
-/* Game session host */
-"session.tapToResume" = "Tap to resume";
-"session.menu" = "Game menu";
-"session.resume" = "Resume";
-"session.quit" = "Quit";
diff --git a/App/RootView.swift b/App/RootView.swift
new file mode 100644
index 0000000..750d327
--- /dev/null
+++ b/App/RootView.swift
@@ -0,0 +1,103 @@
+import EikonKit
+import SwiftUI
+
+enum RootDestination: Hashable {
+    case library, drives, device, credits
+}
+
+/// A sidebar with four destinations: two columns on iPad, a stack on iPhone. Opens on
+/// Library. On iOS 15 iPad the sidebar hides in portrait and selection can reset
+/// (accepted; see plan §19).
+struct RootView: View {
+    let services: AppServices
+    @ObservedObject var jit: JITController
+    @State private var selection: RootDestination? = .library
+    @State private var unreadable: [URL] = []
+
+    init(services: AppServices) {
+        self.services = services
+        jit = services.jit
+    }
+
+    var body: some View {
+        NavigationView {
+            List {
+                link(.library, "library.title", systemImage: "books.vertical")
+                link(.drives, "drives.title", systemImage: "externaldrive")
+                link(.device, "status.title", systemImage: "info.circle")
+                link(.credits, "credits.title", systemImage: "heart")
+            }
+            .listStyle(.sidebar)
+            .navigationTitle(Text(verbatim: "Eikon"))
+
+            // The detail shown before anything is picked.
+            destination(.library)
+        }
+        .navigationViewStyle(.columns)
+        .onAppear { unreadable = services.unreadableFiles }
+        .alert(Text("storage.unreadable.title"), isPresented: Binding(
+            get: { !unreadable.isEmpty },
+            set: { if !$0 { unreadable = [] } }
+        )) {
+            Button("storage.unreadable.keep", role: .cancel) {}
+            Button("storage.unreadable.startOver", role: .destructive) {
+                services.startOverUnreadable()
+            }
+        } message: {
+            Text(L10n.format("storage.unreadable.message", unreadable.map(Self.appRelative).joined(separator: "\n")))
+        }
+    }
+
+    private func link(_ target: RootDestination, _ titleKey: LocalizedStringKey, systemImage: String) -> some View {
+        NavigationLink(tag: target, selection: $selection) {
+            destination(target)
+        } label: {
+            Label(titleKey, systemImage: systemImage)
+        }
+    }
+
+    /// Sections 13–15 replace the placeholders with LibraryView, DrivesView and CreditsView.
+    @ViewBuilder
+    private func destination(_ target: RootDestination) -> some View {
+        switch target {
+        case .library: DestinationPlaceholder(titleKey: "library.title")
+        case .drives: DestinationPlaceholder(titleKey: "drives.title")
+        case .device: StatusView(controller: jit)
+        case .credits: DestinationPlaceholder(titleKey: "credits.title")
+        }
+    }
+
+    /// Where a file lives inside the app's data folder; never a game title.
+    private static func appRelative(_ url: URL) -> String {
+        let base = LibraryPaths.support.resolvingSymlinksInPath().path + "/"
+        let path = url.resolvingSymlinksInPath().path
+        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
+    }
+}
+
+/// Stands in for a destination another section builds.
+private struct DestinationPlaceholder: View {
+    let titleKey: LocalizedStringKey
+
+    var body: some View {
+        List {}
+            .navigationTitle(Text(titleKey))
+    }
+}
+
+/// Shown instead of the app when its data folder can't be opened.
+struct StartupFailureView: View {
+    let failure: StartupFailure
+
+    var body: some View {
+        VStack(spacing: 12) {
+            Image(systemName: "exclamationmark.triangle")
+                .font(.largeTitle)
+            Text("app.startupFailed.title")
+                .font(.headline)
+            Text(L10n.format("app.startupFailed.message", failure.code))
+                .multilineTextAlignment(.center)
+        }
+        .padding()
+    }
+}
diff --git a/App/StatusView.swift b/App/StatusView.swift
index 44a3912..ab3307a 100644
--- a/App/StatusView.swift
+++ b/App/StatusView.swift
@@ -111,19 +111,17 @@ struct StatusContent: View {
     let onCopyReport: () -> Void
     let onShareReport: () -> Void
 
+    /// No navigation view of its own: RootView's column navigation hosts it.
     var body: some View {
-        NavigationView {
-            List {
-                appSection
-                installSection
-                jitSection
-                deviceSection
-                reportSection
-            }
-            .listStyle(.insetGrouped)
-            .navigationTitle(Text("status.title"))
+        List {
+            appSection
+            installSection
+            jitSection
+            deviceSection
+            reportSection
         }
-        .navigationViewStyle(.stack)
+        .listStyle(.insetGrouped)
+        .navigationTitle(Text("status.title"))
     }
 
     private var appSection: some View {
@@ -434,10 +432,14 @@ private let sampleApp = AppInfoRows(version: "0.1.0", build: "12", commit: "0123
 private let sampleDevice = DeviceRows(model: "iPad14,5", chip: "M2", osVersion: "17.0",
                                       osBuild: "21A329", memory: "4 GB")
 
-private func sampleContent(status: JITStatus, method: InstallMethod, pending: Bool) -> StatusContent {
-    StatusContent(app: sampleApp, installMethod: method, status: status,
-                  isRequestingTrollStoreJIT: pending, device: sampleDevice, copied: false, reportError: false,
-                  onRetryJIT: {}, onRetryProbe: {}, onCopyReport: {}, onShareReport: {})
+@MainActor
+private func sampleContent(status: JITStatus, method: InstallMethod, pending: Bool) -> some View {
+    NavigationView {
+        StatusContent(app: sampleApp, installMethod: method, status: status,
+                      isRequestingTrollStoreJIT: pending, device: sampleDevice, copied: false, reportError: false,
+                      onRetryJIT: {}, onRetryProbe: {}, onCopyReport: {}, onShareReport: {})
+    }
+    .navigationViewStyle(.stack)
 }
 
 struct StatusView_Previews: PreviewProvider {
diff --git a/App/Strings/CrashStrings.swift b/App/Strings/CrashStrings.swift
new file mode 100644
index 0000000..cfc54dc
--- /dev/null
+++ b/App/Strings/CrashStrings.swift
@@ -0,0 +1,14 @@
+import EikonCore
+import SwiftUI
+
+enum CrashStrings {
+    /// The signal and pc of a crash are shown as numbers elsewhere, not in the sentence.
+    static func outcomeKey(_ outcome: SessionOutcome) -> LocalizedStringKey {
+        switch outcome {
+        case .crashed: "crash.outcome.crashed"
+        case .likelyMemoryKill: "crash.outcome.likelyMemoryKill"
+        case .endedUnexpectedly: "crash.outcome.endedUnexpectedly"
+        case .killedInBackground: "crash.outcome.killedInBackground"
+        }
+    }
+}
diff --git a/App/Strings/EngineStrings.swift b/App/Strings/EngineStrings.swift
new file mode 100644
index 0000000..8c02106
--- /dev/null
+++ b/App/Strings/EngineStrings.swift
@@ -0,0 +1,73 @@
+import EikonCore
+import SwiftUI
+
+enum EngineStrings {
+    static func key(_ engine: Engine) -> String {
+        switch engine {
+        case .unity: "engine.unity"
+        case .kirikiri: "engine.kirikiri"
+        case .renpy: "engine.renpy"
+        case .gameMaker: "engine.gameMaker"
+        case .bgi: "engine.bgi"
+        case .unknown: "engine.unknown"
+        }
+    }
+
+    static func name(_ engine: Engine) -> String {
+        L10n.string(key(engine))
+    }
+
+    static func key(_ architecture: CPUArchitecture) -> String {
+        switch architecture {
+        case .i386: "arch.i386"
+        case .amd64: "arch.amd64"
+        case .arm64: "arch.arm64"
+        case .other: "arch.other"
+        }
+    }
+
+    static func name(_ architecture: CPUArchitecture) -> String {
+        L10n.string(key(architecture))
+    }
+
+    static func key(_ platform: GamePlatform) -> LocalizedStringKey {
+        switch platform {
+        case .windows: "engine.platform.windows"
+        case .linux: "engine.platform.linux"
+        }
+    }
+
+    static func key(_ scripting: UnityScripting) -> LocalizedStringKey {
+        switch scripting {
+        case .mono: "engine.unity.mono"
+        case .il2cpp: "engine.unity.il2cpp"
+        }
+    }
+
+    static func key(_ flavor: KirikiriFlavor) -> LocalizedStringKey {
+        switch flavor {
+        case .krkr2: "engine.kirikiri.krkr2"
+        case .krkrZ: "engine.kirikiri.krkrZ"
+        case .unknown: "engine.kirikiri.unknown"
+        }
+    }
+
+    static func key(_ build: GameMakerBuild) -> LocalizedStringKey {
+        switch build {
+        case .vm: "engine.gameMaker.vm"
+        case .yyc: "engine.gameMaker.yyc"
+        }
+    }
+
+    /// "Version 7.4.11", or a range for versions inferred from the layout.
+    static func text(_ version: RenPyVersion) -> String {
+        switch version.kind {
+        case .exact:
+            let numbers = [version.major, version.minor] + (version.patch.map { [$0] } ?? [])
+            return L10n.format("engine.renpy.exact", numbers.map(String.init).joined(separator: "."))
+        case .era:
+            let upper = version.maxMajor.flatMap { major in version.maxMinor.map { "\(major).\($0)" } } ?? "…"
+            return L10n.format("engine.renpy.era", "\(version.major).\(version.minor)–\(upper)")
+        }
+    }
+}
diff --git a/App/Strings/GateStrings.swift b/App/Strings/GateStrings.swift
new file mode 100644
index 0000000..b98eafd
--- /dev/null
+++ b/App/Strings/GateStrings.swift
@@ -0,0 +1,23 @@
+import EikonCore
+import SwiftUI
+
+enum GateStrings {
+    /// Known gates by name; any other (from a later split) gets a generic sentence with
+    /// its raw name. The one intentional non-exhaustive map, since gate names are open.
+    static func name(_ gate: GateName) -> String {
+        switch gate {
+        case .x18: L10n.string("gate.name.x18")
+        case .guestWindow: L10n.string("gate.name.guestWindow")
+        default: L10n.format("gate.name.generic", gate.rawValue)
+        }
+    }
+
+    static func stateKey(_ state: GateState) -> LocalizedStringKey {
+        switch state {
+        case .passed: "gate.state.passed"
+        case .failed(stale: false): "gate.state.failed"
+        case .failed(stale: true): "gate.state.failedStale"
+        case .unmeasured: "gate.state.unmeasured"
+        }
+    }
+}
diff --git a/App/Strings/L10n.swift b/App/Strings/L10n.swift
new file mode 100644
index 0000000..2de32c0
--- /dev/null
+++ b/App/Strings/L10n.swift
@@ -0,0 +1,24 @@
+import Foundation
+
+/// Lookups for the maps in this folder. Core code returns codes; these turn keys into text.
+enum L10n {
+    static func string(_ key: String) -> String {
+        NSLocalizedString(key, comment: "")
+    }
+
+    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
+        String(format: string(key), arguments: arguments)
+    }
+
+    /// A plural from Localizable.stringsdict, e.g. `library.count.games`.
+    static func count(_ key: String, _ value: Int) -> String {
+        String.localizedStringWithFormat(string(key), value)
+    }
+
+    /// The text for `key`, or nil when no strings file has it.
+    static func existing(_ key: String) -> String? {
+        let missing = "\u{1}missing\u{1}"
+        let text = NSLocalizedString(key, value: missing, comment: "")
+        return text == missing ? nil : text
+    }
+}
diff --git a/App/Strings/LibraryStrings.swift b/App/Strings/LibraryStrings.swift
new file mode 100644
index 0000000..49643ea
--- /dev/null
+++ b/App/Strings/LibraryStrings.swift
@@ -0,0 +1,53 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+enum LibraryStrings {
+    static func statusKey(_ status: GameStatus) -> LocalizedStringKey {
+        switch status {
+        case .ready: "library.status.ready"
+        case .identifying: "library.status.identifying"
+        case .waitingForCopy: "library.status.waitingForCopy"
+        case .suggestion: "library.status.suggestion"
+        case .driveNotConnected: "library.status.driveNotConnected"
+        case .missing: "library.status.missing"
+        case .fingerprintFailed: "library.status.fingerprintFailed"
+        }
+    }
+
+    static func driveStateKey(_ state: DriveState) -> LocalizedStringKey {
+        switch state {
+        case .available: "drives.state.available"
+        case .notConnected: "drives.state.notConnected"
+        case .needsRelink: "drives.state.needsRelink"
+        }
+    }
+
+    static func refusalKey(_ refusal: DriveRefusal) -> LocalizedStringKey {
+        switch refusal {
+        case .iCloud: "drives.refusal.iCloud"
+        case .network: "drives.refusal.network"
+        case .unknownVolume: "drives.refusal.unknownVolume"
+        case .overlapsDrive: "drives.refusal.overlapsDrive"
+        case .unreadable: "drives.refusal.unreadable"
+        }
+    }
+
+    static func importOutcomeKey(_ outcome: ImportOutcome) -> LocalizedStringKey {
+        switch outcome {
+        case .imported: "import.outcome.imported"
+        case .noGameFound: "import.outcome.noGameFound"
+        case .nameClash: "import.outcome.nameClash"
+        case .nameTaken: "import.outcome.nameTaken"
+        case .insufficientSpace: "import.outcome.insufficientSpace"
+        case .driveUnavailable: "import.outcome.driveUnavailable"
+        case .cancelled: "import.outcome.cancelled"
+        case .failed: "import.outcome.failed"
+        }
+    }
+
+    /// The suggestion card; the display name appears on screen only.
+    static func suggestion(otherGame displayName: String) -> String {
+        L10n.format("identity.suggestion", displayName)
+    }
+}
diff --git a/App/Strings/RouteStrings.swift b/App/Strings/RouteStrings.swift
new file mode 100644
index 0000000..3214a45
--- /dev/null
+++ b/App/Strings/RouteStrings.swift
@@ -0,0 +1,96 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// Route names, verdicts, reasons and runtime declines. Exhaustive: a new case fails the
+/// build until it has a key.
+enum RouteStrings {
+    static func nameKey(_ route: RouteID) -> String {
+        switch route {
+        case .nativeKirikiri: "route.id.native-kirikiri"
+        case .nativeRenPy: "route.id.native-renpy"
+        case .wineFEX: "route.id.wine-fex"
+        case .wineBox64: "route.id.wine-box64"
+        case .linuxFEX: "route.id.linux-fex"
+        }
+    }
+
+    static func name(_ route: RouteID) -> String {
+        L10n.string(nameKey(route))
+    }
+
+    /// A session record's route: a `RouteID` raw value, the test route, or a route from a
+    /// newer build, shown raw.
+    static func name(recorded raw: String) -> String {
+        if raw == SessionRecord.testRoute { return L10n.string("route.id.test") }
+        return RouteID(rawValue: raw).map(name) ?? raw
+    }
+
+    static func verdictKey(_ verdict: RouteVerdict) -> LocalizedStringKey {
+        switch verdict {
+        case .runnable: "route.verdict.runnable"
+        case .runnableWithWarnings: "route.verdict.runnableWithWarnings"
+        case .planned: "route.verdict.planned"
+        case .unavailable: "route.verdict.unavailable"
+        }
+    }
+
+    /// One short sentence a non-expert can act on. `jitReason` explains `needsJIT`.
+    static func reasonText(_ reason: RouteReason, jitReason: JITReasonCode?) -> String {
+        switch reason {
+        case .engineNotHandled(let engine):
+            L10n.format("route.reason.engineNotHandled", EngineStrings.name(engine))
+        case .needsWindowsBinary:
+            L10n.string("route.reason.needsWindowsBinary")
+        case .needsLinuxBinary:
+            L10n.string("route.reason.needsLinuxBinary")
+        case .architectureUnsupported(let architecture):
+            L10n.format("route.reason.architectureUnsupported", EngineStrings.name(architecture))
+        case .needsJIT:
+            jitReason.map { L10n.format("route.reason.needsJIT", JITStrings.reasonSentence($0)) }
+                ?? L10n.string("route.reason.needsJIT.noReason")
+        case .box64Only32Bit:
+            L10n.string("route.reason.box64Only32Bit")
+        case .fexPreferredWithJIT:
+            L10n.string("route.reason.fexPreferredWithJIT")
+        case .gateFailed(let gate, let stale):
+            stale ? L10n.string("route.reason.gateFailed.stale")
+                : L10n.format("route.reason.gateFailed", GateStrings.name(gate))
+        case .gateUnmeasured(let gate):
+            L10n.format("route.reason.gateUnmeasured", GateStrings.name(gate))
+        case .notInThisBuild:
+            L10n.string("route.reason.notInThisBuild")
+        case .runtimeDeclined(let code):
+            declineText(code)
+        case .nativeFirst:
+            L10n.string("route.reason.nativeFirst")
+        case .overriddenByUser:
+            L10n.string("route.reason.overriddenByUser")
+        }
+    }
+
+    /// `route.decline.<raw>` from the owning runtime split, else a generic sentence with
+    /// the raw code: the one intentional fallback here, since decline codes are open.
+    static func declineText(_ code: RuntimeDeclineCode) -> String {
+        L10n.existing("route.decline.\(code.rawValue)") ?? L10n.format("route.decline.generic", code.rawValue)
+    }
+}
+
+/// 01's JIT reason sentences, for text that embeds them.
+enum JITStrings {
+    static func reasonSentence(_ reason: JITReasonCode) -> String {
+        switch reason {
+        case .dopamineJITOff: L10n.string("jit.reason.dopamineJITOff")
+        case .rootlessJailbreakNoJIT: L10n.string("jit.reason.rootlessJailbreakNoJIT")
+        case .trollStoreRequestPending: L10n.string("jit.reason.trollStoreRequestPending")
+        case .trollStoreTimedOut: L10n.string("jit.reason.trollStoreTimedOut")
+        case .sideloadedNoJIT: L10n.string("jit.reason.sideloadedNoJIT")
+        case .txmEnforced: L10n.string("jit.reason.txmEnforced")
+        case .txmUndetermined: L10n.string("jit.reason.txmUndetermined")
+        case .probeSkippedAfterCrash: L10n.string("jit.reason.probeSkippedAfterCrash")
+        case .probeFailed: L10n.string("jit.reason.probeFailed")
+        case .unknownInstallNoJIT: L10n.string("jit.reason.unknownInstallNoJIT")
+        case .simulator: L10n.string("jit.reason.simulator")
+        }
+    }
+}
diff --git a/App/Strings/StringsPreviews.swift b/App/Strings/StringsPreviews.swift
new file mode 100644
index 0000000..797f874
--- /dev/null
+++ b/App/Strings/StringsPreviews.swift
@@ -0,0 +1,89 @@
+#if DEBUG
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// Renders every mapped code, so a missing key shows up as a raw key in the canvas.
+/// Payload cases get one representative value each; the exhaustive switches in the maps
+/// force a new case to be added here too.
+struct StringsPreviews: View {
+    private let reasons: [RouteReason] = [
+        .engineNotHandled(.unity), .needsWindowsBinary, .needsLinuxBinary, .architectureUnsupported(.arm64),
+        .needsJIT, .box64Only32Bit, .fexPreferredWithJIT, .gateFailed(.x18, stale: false),
+        .gateFailed(.x18, stale: true), .gateUnmeasured(.guestWindow), .notInThisBuild,
+        .runtimeDeclined(RuntimeDeclineCode(rawValue: "sample")), .nativeFirst, .overriddenByUser,
+    ]
+    private let outcomes: [SessionOutcome] = [
+        .crashed(signal: 11, pc: 0x1000), .likelyMemoryKill, .endedUnexpectedly, .killedInBackground,
+    ]
+    private let gateStates: [GateState] = [.passed, .failed(stale: false), .failed(stale: true), .unmeasured]
+    private let verdicts: [RouteVerdict] = [.runnable, .runnableWithWarnings, .planned, .unavailable]
+    private let statuses: [GameStatus] = [
+        .ready, .identifying, .waitingForCopy, .suggestion, .driveNotConnected, .missing, .fingerprintFailed,
+    ]
+    private let driveStates: [DriveState] = [.available, .notConnected, .needsRelink]
+    private let refusals: [DriveRefusal] = [.iCloud, .network, .unknownVolume, .overlapsDrive, .unreadable]
+    private let imports: [ImportOutcome] = [
+        .imported(UUID()), .noGameFound, .nameClash, .nameTaken, .insufficientSpace, .driveUnavailable, .cancelled, .failed,
+    ]
+
+    var body: some View {
+        List {
+            Section(header: Text(verbatim: "Routes")) {
+                ForEach(RouteID.allCases, id: \.self) { Text(RouteStrings.name($0)) }
+                Text(RouteStrings.name(recorded: SessionRecord.testRoute))
+                ForEach(verdicts.indices, id: \.self) { Text(RouteStrings.verdictKey(verdicts[$0])) }
+            }
+            Section(header: Text(verbatim: "Reasons")) {
+                ForEach(reasons.indices, id: \.self) { index in
+                    Text(RouteStrings.reasonText(reasons[index], jitReason: .sideloadedNoJIT))
+                }
+                Text(RouteStrings.reasonText(.needsJIT, jitReason: nil))
+            }
+            Section(header: Text(verbatim: "Gates")) {
+                Text(GateStrings.name(.x18))
+                Text(GateStrings.name(.guestWindow))
+                Text(GateStrings.name(GateName(rawValue: "futureGate")))
+                ForEach(gateStates.indices, id: \.self) { Text(GateStrings.stateKey(gateStates[$0])) }
+            }
+            Section(header: Text(verbatim: "Engines")) {
+                ForEach(Engine.allCases, id: \.self) { Text(EngineStrings.name($0)) }
+                ForEach(CPUArchitecture.allCases, id: \.self) { Text(EngineStrings.name($0)) }
+                ForEach(GamePlatform.allCases, id: \.self) { Text(EngineStrings.key($0)) }
+                ForEach(UnityScripting.allCases, id: \.self) { Text(EngineStrings.key($0)) }
+                ForEach(KirikiriFlavor.allCases, id: \.self) { Text(EngineStrings.key($0)) }
+                ForEach(GameMakerBuild.allCases, id: \.self) { Text(EngineStrings.key($0)) }
+                Text(EngineStrings.text(.exact(7, 4, 11)))
+                Text(EngineStrings.text(.era(from: (8, 0), through: (8, 3))))
+            }
+            Section(header: Text(verbatim: "Crashes")) {
+                ForEach(outcomes.indices, id: \.self) { Text(CrashStrings.outcomeKey(outcomes[$0])) }
+            }
+            Section(header: Text(verbatim: "Library")) {
+                ForEach(statuses.indices, id: \.self) { Text(LibraryStrings.statusKey(statuses[$0])) }
+                Text(LibraryStrings.suggestion(otherGame: "Sample"))
+                Text("identity.merge")
+                Text("identity.keepSeparate")
+                Text("identity.sameGameAs")
+                Text("identity.differentGame")
+                Text(L10n.count("library.count.games", 1))
+                Text(L10n.count("library.count.games", 3))
+            }
+            Section(header: Text(verbatim: "Drives and import")) {
+                ForEach(driveStates.indices, id: \.self) { Text(LibraryStrings.driveStateKey(driveStates[$0])) }
+                ForEach(refusals.indices, id: \.self) { Text(LibraryStrings.refusalKey(refusals[$0])) }
+                ForEach(imports.indices, id: \.self) { Text(LibraryStrings.importOutcomeKey(imports[$0])) }
+                Text(L10n.count("drives.count.drives", 2))
+                Text(L10n.count("import.count.files", 1))
+                Text(L10n.count("import.count.bytes", 5))
+            }
+        }
+    }
+}
+
+struct StringsPreviews_Previews: PreviewProvider {
+    static var previews: some View {
+        StringsPreviews()
+    }
+}
+#endif
diff --git a/App/en.lproj/Localizable.strings b/App/en.lproj/Localizable.strings
new file mode 100644
index 0000000..6e42294
--- /dev/null
+++ b/App/en.lproj/Localizable.strings
@@ -0,0 +1,212 @@
+/* Eikon's English source strings. Keys are namespaced (status.*, library.*, drives.*, ...).
+   Core code returns codes and enums only; App/Strings/ maps them to these keys. */
+
+"status.title" = "This device";
+
+/* Section headers */
+"status.section.app" = "App";
+"status.section.install" = "Install";
+"status.section.jit" = "JIT";
+"status.section.device" = "Device";
+"status.section.report" = "Report";
+
+/* App section */
+"status.app.version" = "Version";
+"status.app.version.format" = "%1$@ (%2$@)";
+"status.app.commit" = "Commit";
+"status.app.packageKind" = "Package kind";
+"status.app.bundleId" = "Bundle ID";
+
+/* Shared values */
+"status.value.unknown" = "unknown";
+"status.value.yes" = "yes";
+"status.value.no" = "no";
+
+/* Install section */
+"install.method.label" = "Detected method";
+"install.method.dopamine" = "Dopamine";
+"install.method.rootlessJailbreak" = "rootless jailbreak";
+"install.method.trollStore" = "TrollStore";
+"install.method.trollStoreLite" = "TrollStore Lite";
+"install.method.sideloaded" = "sideloaded";
+"install.method.simulator" = "simulator";
+"install.method.unknown" = "unknown";
+
+/* JIT section */
+"jit.state.usable" = "Usable";
+"jit.state.notUsable" = "Not usable";
+"jit.pending" = "Waiting for TrollStore…";
+
+"jit.source.label" = "Source";
+"jit.source.none" = "none";
+"jit.source.dopamine" = "Dopamine";
+"jit.source.rootlessJailbreak" = "rootless jailbreak";
+"jit.source.trollStore" = "TrollStore";
+"jit.source.externalEnabler" = "external enabler";
+"jit.source.preexisting" = "already enabled at launch";
+"jit.source.unknown" = "unknown";
+
+"jit.csDebugged.label" = "CS_DEBUGGED";
+"jit.seen.atLaunch" = "at launch";
+"jit.seen.afterTrollStoreRequest" = "after TrollStore request";
+"jit.seen.onForeground" = "on returning to the app";
+
+"jit.probe.label" = "Probe";
+"jit.probe.notRun" = "not run";
+"jit.probe.passed" = "passed";
+"jit.probe.failed" = "failed";
+
+"jit.txm.label" = "TXM";
+"jit.txm.present" = "present";
+"jit.txm.absent" = "absent";
+"jit.txm.unknown" = "unknown";
+"jit.txm.enforced" = "enforced";
+"jit.txm.notEnforced" = "not enforced";
+
+"jit.retryJIT" = "Retry JIT";
+"jit.retryProbe" = "Retry probe";
+
+/* One cause-and-fix text per JITReasonCode */
+"jit.reason.dopamineJITOff" = "Dopamine didn't enable JIT for Eikon. Turn on “Allow JIT in Apps” in Dopamine's settings, make sure tweak injection isn't disabled for Eikon and the device isn't in safe mode, then relaunch Eikon. Dopamine 2.0 doesn't provide JIT; update to 2.1 or later.";
+"jit.reason.rootlessJailbreakNoJIT" = "This jailbreak didn't enable JIT for Eikon. Features that need JIT are unavailable; everything else still works.";
+"jit.reason.trollStoreRequestPending" = "Asking TrollStore to enable JIT…";
+"jit.reason.trollStoreTimedOut" = "TrollStore didn't enable JIT. Update TrollStore to 2.0.12 or later and make sure its URL scheme is enabled in TrollStore's settings, then tap Retry JIT.";
+"jit.reason.sideloadedNoJIT" = "JIT isn't enabled for this install. Features that need JIT are unavailable; everything else still works.";
+"jit.reason.txmEnforced" = "This device requires a debugger to approve JIT code. Enabling JIT with an enabler won't make it usable here yet. Native routes still work.";
+"jit.reason.txmUndetermined" = "Eikon couldn't confirm whether this device requires debugger approval for JIT, so JIT is treated as unavailable to be safe. Native routes still work. A device report helps fix this.";
+"jit.reason.probeSkippedAfterCrash" = "The last launch ended during the JIT check, so it was skipped this time. Tap Retry probe to run it again.";
+"jit.reason.probeFailed" = "JIT appears to be enabled, but a test of it failed (details below). Tap Retry probe, and please share a device report.";
+"jit.reason.unknownInstallNoJIT" = "Eikon couldn't tell how it was installed, and JIT isn't enabled. Features that need JIT are unavailable; everything else still works.";
+"jit.reason.simulator" = "JIT is never enabled in the simulator.";
+
+/* Device section */
+"device.model" = "Model identifier";
+"device.chip" = "Chip";
+"device.os" = "iOS";
+"device.os.format" = "%1$@ (%2$@)";
+"device.memory" = "Available memory";
+
+/* Report section */
+"report.copy" = "Copy report";
+"report.share" = "Share report";
+"report.copied" = "Copied";
+"report.error" = "Couldn't build the report.";
+
+/* Game session host */
+"session.tapToResume" = "Tap to resume";
+"session.menu" = "Game menu";
+"session.resume" = "Resume";
+"session.quit" = "Quit";
+
+/* Root navigation */
+"library.title" = "Library";
+"drives.title" = "Game drives";
+"credits.title" = "Credits";
+"app.startupFailed.title" = "Eikon couldn't open its data";
+"app.startupFailed.message" = "The app's data folder couldn't be opened (code %@). Restart the device and try again.";
+
+/* Files that couldn't be read */
+"storage.unreadable.title" = "Some data files couldn't be read";
+"storage.unreadable.message" = "Eikon won't change these files, so if you edited one by hand you can fix it and relaunch:\n%@\n\nOr start over: each file is kept as a backup beside it, and Eikon saves new ones in their place.";
+"storage.unreadable.keep" = "Keep files";
+"storage.unreadable.startOver" = "Start over";
+
+/* Routes */
+"route.id.native-kirikiri" = "Kirikiri (native)";
+"route.id.native-renpy" = "Ren'Py (native)";
+"route.id.wine-fex" = "Wine with FEX";
+"route.id.wine-box64" = "Wine with Box64";
+"route.id.linux-fex" = "Linux with FEX";
+"route.id.test" = "Test session";
+"route.verdict.runnable" = "Ready";
+"route.verdict.runnableWithWarnings" = "Ready, with warnings";
+"route.verdict.planned" = "Planned";
+"route.verdict.unavailable" = "Can't run";
+"route.reason.engineNotHandled" = "This route doesn't run %@ games.";
+"route.reason.needsWindowsBinary" = "Needs a Windows program, and this game has none.";
+"route.reason.needsLinuxBinary" = "Needs a Linux program, and this game has none.";
+"route.reason.architectureUnsupported" = "Can't run %@ programs.";
+"route.reason.needsJIT" = "Needs JIT, which this install doesn't have: %@.";
+"route.reason.needsJIT.noReason" = "Needs JIT, which this install doesn't have.";
+"route.reason.box64Only32Bit" = "Without JIT, only 32-bit Windows games can run.";
+"route.reason.fexPreferredWithJIT" = "Slower than Wine with FEX; used if that route can't run.";
+"route.reason.gateFailed" = "Failed on this device (%@).";
+"route.reason.gateFailed.stale" = "Failed on this device before an update. Not re-checked yet.";
+"route.reason.gateUnmeasured" = "Not yet verified on this device (%@). It may not work.";
+"route.reason.notInThisBuild" = "Planned. Not in this build yet.";
+"route.reason.runtimeDeclined" = "%@";
+"route.reason.nativeFirst" = "The native route for this engine comes first.";
+"route.reason.overriddenByUser" = "You chose this route.";
+"route.decline.generic" = "This runtime can't run this game (%@).";
+
+/* Gates */
+"gate.name.x18" = "x18 check";
+"gate.name.guestWindow" = "window check";
+"gate.name.generic" = "%@ check";
+"gate.state.passed" = "Passed";
+"gate.state.failed" = "Failed";
+"gate.state.failedStale" = "Failed before an update";
+"gate.state.unmeasured" = "Not checked yet";
+
+/* Engines and binaries */
+"engine.unity" = "Unity";
+"engine.kirikiri" = "Kirikiri";
+"engine.renpy" = "Ren'Py";
+"engine.gameMaker" = "GameMaker";
+"engine.bgi" = "BGI";
+"engine.unknown" = "Unknown engine";
+"engine.unity.mono" = "Mono";
+"engine.unity.il2cpp" = "IL2CPP";
+"engine.kirikiri.krkr2" = "Kirikiri 2";
+"engine.kirikiri.krkrZ" = "Kirikiri Z";
+"engine.kirikiri.unknown" = "Kirikiri (version unknown)";
+"engine.renpy.exact" = "Version %@";
+"engine.renpy.era" = "Version range %@";
+"engine.gameMaker.vm" = "VM";
+"engine.gameMaker.yyc" = "YYC";
+"engine.platform.windows" = "Windows";
+"engine.platform.linux" = "Linux";
+"arch.i386" = "32-bit x86";
+"arch.amd64" = "64-bit x86";
+"arch.arm64" = "ARM64";
+"arch.other" = "Other architecture";
+
+/* Crashes */
+"crash.outcome.crashed" = "The game crashed.";
+"crash.outcome.likelyMemoryKill" = "The game was probably closed for using too much memory.";
+"crash.outcome.endedUnexpectedly" = "The game ended unexpectedly.";
+"crash.outcome.killedInBackground" = "The game was closed while in the background.";
+
+/* Library */
+"library.status.ready" = "Ready";
+"library.status.identifying" = "Identifying…";
+"library.status.waitingForCopy" = "Waiting for copy to finish…";
+"library.status.suggestion" = "Same game as another?";
+"library.status.driveNotConnected" = "Drive not connected";
+"library.status.missing" = "Missing";
+"library.status.fingerprintFailed" = "Hashing failed";
+"identity.suggestion" = "This might be the same game as %@ (a different version). Use one entry?";
+"identity.merge" = "Merge";
+"identity.keepSeparate" = "Keep separate";
+"identity.sameGameAs" = "Same game as…";
+"identity.differentGame" = "This is a different game";
+
+/* Drives */
+"drives.state.available" = "Connected";
+"drives.state.notConnected" = "Not connected";
+"drives.state.needsRelink" = "Needs to be found again";
+"drives.refusal.iCloud" = "iCloud Drive folders can't be game drives: their files may be moved off the device while a game runs.";
+"drives.refusal.network" = "Network folders can't be game drives: a dropped connection would stop a running game.";
+"drives.refusal.unknownVolume" = "Eikon couldn't tell where this folder is stored, so it can't be a game drive.";
+"drives.refusal.overlapsDrive" = "This folder is already a game drive, or is inside or around one.";
+"drives.refusal.unreadable" = "Eikon couldn't open this folder.";
+
+/* Import */
+"import.outcome.imported" = "Imported.";
+"import.outcome.noGameFound" = "No game was found in this folder.";
+"import.outcome.nameClash" = "This drive already has a game folder with that name.";
+"import.outcome.nameTaken" = "That name is taken or can't be used. Choose another.";
+"import.outcome.insufficientSpace" = "There isn't enough free space on this drive.";
+"import.outcome.driveUnavailable" = "This drive isn't connected.";
+"import.outcome.cancelled" = "Import cancelled.";
+"import.outcome.failed" = "The import failed. Nothing was changed on the drive.";
diff --git a/App/en.lproj/Localizable.stringsdict b/App/en.lproj/Localizable.stringsdict
new file mode 100644
index 0000000..f0adde5
--- /dev/null
+++ b/App/en.lproj/Localizable.stringsdict
@@ -0,0 +1,70 @@
+<?xml version="1.0" encoding="UTF-8"?>
+<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
+<plist version="1.0">
+<dict>
+	<key>library.count.games</key>
+	<dict>
+		<key>NSStringLocalizedFormatKey</key>
+		<string>%#@games@</string>
+		<key>games</key>
+		<dict>
+			<key>NSStringFormatSpecTypeKey</key>
+			<string>NSStringPluralRuleType</string>
+			<key>NSStringFormatValueTypeKey</key>
+			<string>d</string>
+			<key>one</key>
+			<string>%d game</string>
+			<key>other</key>
+			<string>%d games</string>
+		</dict>
+	</dict>
+	<key>import.count.files</key>
+	<dict>
+		<key>NSStringLocalizedFormatKey</key>
+		<string>%#@files@</string>
+		<key>files</key>
+		<dict>
+			<key>NSStringFormatSpecTypeKey</key>
+			<string>NSStringPluralRuleType</string>
+			<key>NSStringFormatValueTypeKey</key>
+			<string>d</string>
+			<key>one</key>
+			<string>%d file</string>
+			<key>other</key>
+			<string>%d files</string>
+		</dict>
+	</dict>
+	<key>import.count.bytes</key>
+	<dict>
+		<key>NSStringLocalizedFormatKey</key>
+		<string>%#@bytes@</string>
+		<key>bytes</key>
+		<dict>
+			<key>NSStringFormatSpecTypeKey</key>
+			<string>NSStringPluralRuleType</string>
+			<key>NSStringFormatValueTypeKey</key>
+			<string>d</string>
+			<key>one</key>
+			<string>%d byte</string>
+			<key>other</key>
+			<string>%d bytes</string>
+		</dict>
+	</dict>
+	<key>drives.count.drives</key>
+	<dict>
+		<key>NSStringLocalizedFormatKey</key>
+		<string>%#@drives@</string>
+		<key>drives</key>
+		<dict>
+			<key>NSStringFormatSpecTypeKey</key>
+			<string>NSStringPluralRuleType</string>
+			<key>NSStringFormatValueTypeKey</key>
+			<string>d</string>
+			<key>one</key>
+			<string>%d drive</string>
+			<key>other</key>
+			<string>%d drives</string>
+		</dict>
+	</dict>
+</dict>
+</plist>

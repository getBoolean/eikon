diff --git a/App/EikonApp.swift b/App/EikonApp.swift
index 3a89252..96edb20 100644
--- a/App/EikonApp.swift
+++ b/App/EikonApp.swift
@@ -12,8 +12,7 @@ struct EikonApp: App {
 
     var body: some Scene {
         WindowGroup {
-            StatusView()
-                .environmentObject(jit)
+            StatusView(controller: jit)
                 .onChange(of: scenePhase) { phase in
                     if phase == .active {
                         jit.sceneBecameActive()
diff --git a/App/Localizable.strings b/App/Localizable.strings
new file mode 100644
index 0000000..2417039
--- /dev/null
+++ b/App/Localizable.strings
@@ -0,0 +1,92 @@
+/* Eikon status screen. English. The later localisation split moves this into en.lproj. */
+
+"status.title" = "Eikon";
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
diff --git a/App/StatusView.swift b/App/StatusView.swift
index bb59371..194917d 100644
--- a/App/StatusView.swift
+++ b/App/StatusView.swift
@@ -1,35 +1,469 @@
+import EikonKit
 import SwiftUI
 
-/// Placeholder status screen: shows the version stamps from the Info.plist so
-/// they can be checked by eye. Section 09 replaces it.
+/// Eikon's one screen. Observes the controller so JIT rows update live, and
+/// reads the static device facts once.
 struct StatusView: View {
-    private let info = Bundle.main.infoDictionary ?? [:]
+    @ObservedObject var controller: JITController
+
+    @State private var deviceSystem: LiveDeviceSystem?
+    @State private var device: DeviceRows?
+    @State private var shareURL: URL?
+    @State private var copied = false
+    @State private var reportError = false
+
+    var body: some View {
+        StatusContent(
+            app: appRows,
+            installMethod: controller.installMethod,
+            status: controller.status,
+            isRequestingTrollStoreJIT: controller.isRequestingTrollStoreJIT,
+            device: device,
+            copied: copied,
+            reportError: reportError,
+            onRetryJIT: { controller.retryTrollStoreJIT() },
+            onRetryProbe: { controller.retryProbe() },
+            onCopyReport: copyReport,
+            onShareReport: shareReport
+        )
+        .sheet(item: $shareURL) { url in
+            ActivityView(items: [url])
+        }
+        .onAppear(perform: loadDeviceFacts)
+    }
+
+    private var appRows: AppInfoRows {
+        func value(_ key: String) -> String? {
+            (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
+        }
+        return AppInfoRows(
+            version: value("CFBundleShortVersionString"),
+            build: value("CFBundleVersion"),
+            commit: value("EKGitCommit"),
+            packageKind: value("EKPackageKind"),
+            bundleId: Bundle.main.bundleIdentifier
+        )
+    }
+
+    private func loadDeviceFacts() {
+        let system = LiveDeviceSystem.current()
+        deviceSystem = system
+        let formatter = ByteCountFormatter()
+        formatter.countStyle = .memory
+        device = DeviceRows(
+            model: system.modelIdentifier,
+            chip: ChipNames.displayName(forModel: system.modelIdentifier),
+            osVersion: system.osVersion,
+            osBuild: system.osBuild,
+            memory: formatter.string(fromByteCount: Int64(bitPattern: system.availableMemoryBytes()))
+        )
+    }
+
+    private func makeReport() -> DeviceReport? {
+        guard let deviceSystem else { return nil }
+        return DeviceReport.make(
+            app: AppInfo.from(.main),
+            installMethod: controller.installMethod,
+            evidence: controller.evidence,
+            jit: controller.status,
+            system: deviceSystem,
+            now: Date()
+        )
+    }
+
+    private func copyReport() {
+        guard let report = makeReport(), (try? ReportExport.copy(report)) != nil else {
+            reportError = true
+            return
+        }
+        reportError = false
+        copied = true
+        Task {
+            try? await Task.sleep(nanoseconds: 2_000_000_000)
+            copied = false
+        }
+    }
+
+    private func shareReport() {
+        guard let report = makeReport(), let url = try? ReportExport.temporaryFile(for: report) else {
+            reportError = true
+            return
+        }
+        reportError = false
+        shareURL = url
+    }
+}
+
+/// Pure presentation of one snapshot plus actions. The preview renders this directly.
+struct StatusContent: View {
+    let app: AppInfoRows
+    let installMethod: InstallMethod
+    let status: JITStatus
+    let isRequestingTrollStoreJIT: Bool
+    let device: DeviceRows?
+    let copied: Bool
+    let reportError: Bool
+    let onRetryJIT: () -> Void
+    let onRetryProbe: () -> Void
+    let onCopyReport: () -> Void
+    let onShareReport: () -> Void
 
     var body: some View {
         NavigationView {
             List {
-                row("Version", value("CFBundleShortVersionString"))
-                row("Build", value("CFBundleVersion"))
-                row("Commit", value("EKGitCommit"))
-                row("Package kind", value("EKPackageKind"))
-                row("Bundle ID", Bundle.main.bundleIdentifier ?? "–")
+                appSection
+                installSection
+                jitSection
+                deviceSection
+                reportSection
             }
-            .navigationTitle("Eikon")
+            .listStyle(.insetGrouped)
+            .navigationTitle(Text("status.title"))
         }
         .navigationViewStyle(.stack)
     }
 
-    private func value(_ key: String) -> String {
-        (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "–"
+    private var appSection: some View {
+        Section(header: Text("status.section.app")) {
+            if let version = app.version, let build = app.build {
+                LabelRow(labelKey: "status.app.version",
+                         value: String(format: localized("status.app.version.format"), version, build))
+            } else {
+                UnknownRow(labelKey: "status.app.version")
+            }
+            valueRow("status.app.commit", app.commit, selectable: true)
+            valueRow("status.app.packageKind", app.packageKind)
+            valueRow("status.app.bundleId", app.bundleId, selectable: true)
+        }
+    }
+
+    private var installSection: some View {
+        Section(header: Text("status.section.install")) {
+            LabelRow(labelKey: "install.method.label", valueKey: installMethodKey(installMethod))
+        }
+    }
+
+    @ViewBuilder
+    private var jitSection: some View {
+        Section(header: Text("status.section.jit")) {
+            HStack(spacing: 8) {
+                Image(systemName: status.usable ? "checkmark.circle.fill" : "xmark.circle.fill")
+                    .foregroundColor(status.usable ? .green : .secondary)
+                Text(status.usable ? "jit.state.usable" : "jit.state.notUsable")
+                    .font(.title2.weight(.semibold))
+            }
+            .accessibilityElement(children: .combine)
+
+            if isRequestingTrollStoreJIT {
+                HStack(spacing: 8) {
+                    ProgressView()
+                    Text("jit.pending")
+                }
+            }
+
+            if let reason = status.reason, !(reason == .trollStoreRequestPending && isRequestingTrollStoreJIT) {
+                Text(reasonKey(reason))
+                    .font(.footnote)
+                    .foregroundColor(.secondary)
+            }
+
+            LabelRow(labelKey: "jit.source.label", valueKey: sourceKey(status.source))
+            csDebuggedRow
+            probeRow
+            txmRow
+
+            if showsRetryJIT {
+                Button(action: onRetryJIT) { Text("jit.retryJIT") }
+            }
+            if status.reason == .probeSkippedAfterCrash || status.reason == .probeFailed {
+                Button(action: onRetryProbe) { Text("jit.retryProbe") }
+            }
+        }
     }
 
-    private func row(_ label: String, _ value: String) -> some View {
+    private var csDebuggedRow: some View {
         HStack {
-            Text(label)
+            Text("jit.csDebugged.label")
             Spacer()
-            Text(value)
+            csDebuggedValue
                 .foregroundColor(.secondary)
-                .textSelection(.enabled)
+                .multilineTextAlignment(.trailing)
+        }
+    }
+
+    private var csDebuggedValue: Text {
+        let yesNo = Text(status.csDebugged ? "status.value.yes" : "status.value.no")
+        guard status.csDebugged, let seenKey = seenKey(status.csDebuggedSeen) else { return yesNo }
+        return yesNo + Text(verbatim: " ") + Text(seenKey)
+    }
+
+    @ViewBuilder
+    private var probeRow: some View {
+        LabelRow(labelKey: "jit.probe.label", valueKey: probeKey(status.probe.kind))
+        if let detail = status.probe.detail {
+            SecondaryLine(text: detail)
+        }
+    }
+
+    @ViewBuilder
+    private var txmRow: some View {
+        LabelRow(labelKey: "jit.txm.label",
+                 value: "\(localized(txmStateKey(status.txm.state))), "
+                     + localized(status.txm.enforced ? "jit.txm.enforced" : "jit.txm.notEnforced"))
+        SecondaryLine(text: status.txm.basis)
+    }
+
+    @ViewBuilder
+    private var deviceSection: some View {
+        Section(header: Text("status.section.device")) {
+            if let device {
+                valueRow("device.model", device.model, selectable: true)
+                LabelRow(labelKey: "device.chip", value: device.chip)
+                LabelRow(labelKey: "device.os",
+                         value: String(format: localized("device.os.format"), device.osVersion, device.osBuild))
+                LabelRow(labelKey: "device.memory", value: device.memory)
+            } else {
+                UnknownRow(labelKey: "device.model")
+            }
+        }
+    }
+
+    private var reportSection: some View {
+        Section(header: Text("status.section.report")) {
+            Button(action: onCopyReport) { Text("report.copy") }
+            Button(action: onShareReport) { Text("report.share") }
+            if copied {
+                Text("report.copied").font(.footnote).foregroundColor(.secondary)
+            }
+            if reportError {
+                Text("report.error").font(.footnote).foregroundColor(.secondary)
+            }
+        }
+    }
+
+    private var showsRetryJIT: Bool {
+        (installMethod == .trollStore || installMethod == .trollStoreLite)
+            && !status.usable && !isRequestingTrollStoreJIT
+    }
+
+    @ViewBuilder
+    private func valueRow(_ labelKey: LocalizedStringKey, _ value: String?, selectable: Bool = false) -> some View {
+        if let value {
+            LabelRow(labelKey: labelKey, value: value, selectable: selectable)
+        } else {
+            UnknownRow(labelKey: labelKey)
+        }
+    }
+}
+
+// MARK: - Row building blocks
+
+private struct LabelRow: View {
+    let labelKey: LocalizedStringKey
+    var value: String?
+    var valueKey: LocalizedStringKey?
+    var selectable = false
+
+    init(labelKey: LocalizedStringKey, value: String, selectable: Bool = false) {
+        self.labelKey = labelKey
+        self.value = value
+        self.selectable = selectable
+    }
+
+    init(labelKey: LocalizedStringKey, valueKey: LocalizedStringKey) {
+        self.labelKey = labelKey
+        self.valueKey = valueKey
+    }
+
+    var body: some View {
+        HStack {
+            Text(labelKey)
+            Spacer()
+            if selectable {
+                valueText
+                    .foregroundColor(.secondary)
+                    .multilineTextAlignment(.trailing)
+                    .textSelection(.enabled)
+            } else {
+                valueText
+                    .foregroundColor(.secondary)
+                    .multilineTextAlignment(.trailing)
+            }
+        }
+    }
+
+    @ViewBuilder
+    private var valueText: some View {
+        if let valueKey {
+            Text(valueKey)
+        } else {
+            Text(verbatim: value ?? "")
+        }
+    }
+}
+
+private struct UnknownRow: View {
+    let labelKey: LocalizedStringKey
+    var body: some View {
+        HStack {
+            Text(labelKey)
+            Spacer()
+            Text("status.value.unknown").foregroundColor(.secondary)
+        }
+    }
+}
+
+private struct SecondaryLine: View {
+    let text: String
+    var body: some View {
+        Text(verbatim: text)
+            .font(.footnote)
+            .foregroundColor(.secondary)
+            .textSelection(.enabled)
+    }
+}
+
+/// Display-ready values gathered once from the bundle and the device.
+struct AppInfoRows {
+    var version: String?
+    var build: String?
+    var commit: String?
+    var packageKind: String?
+    var bundleId: String?
+}
+
+struct DeviceRows {
+    var model: String
+    var chip: String
+    var osVersion: String
+    var osBuild: String
+    var memory: String
+}
+
+// A URL is Identifiable so it can drive a .sheet(item:).
+extension URL: @retroactive Identifiable {
+    public var id: String { absoluteString }
+}
+
+private func localized(_ key: String) -> String {
+    NSLocalizedString(key, comment: "")
+}
+
+// MARK: - Exhaustive enum → key mappings (no `default:`, so a new case fails the build)
+
+private func installMethodKey(_ method: InstallMethod) -> LocalizedStringKey {
+    switch method {
+    case .dopamine: return "install.method.dopamine"
+    case .rootlessJailbreak: return "install.method.rootlessJailbreak"
+    case .trollStore: return "install.method.trollStore"
+    case .trollStoreLite: return "install.method.trollStoreLite"
+    case .sideloaded: return "install.method.sideloaded"
+    case .simulator: return "install.method.simulator"
+    case .unknown: return "install.method.unknown"
+    }
+}
+
+private func sourceKey(_ source: JITSource) -> LocalizedStringKey {
+    switch source {
+    case .none: return "jit.source.none"
+    case .dopamine: return "jit.source.dopamine"
+    case .rootlessJailbreak: return "jit.source.rootlessJailbreak"
+    case .trollStore: return "jit.source.trollStore"
+    case .externalEnabler: return "jit.source.externalEnabler"
+    case .preexisting: return "jit.source.preexisting"
+    case .unknown: return "jit.source.unknown"
+    }
+}
+
+private func seenKey(_ seen: CSDebuggedSeen) -> LocalizedStringKey? {
+    switch seen {
+    case .never: return nil
+    case .atLaunch: return "jit.seen.atLaunch"
+    case .afterTrollStoreRequest: return "jit.seen.afterTrollStoreRequest"
+    case .onForeground: return "jit.seen.onForeground"
+    }
+}
+
+private func probeKey(_ kind: ProbeOutcome.Kind) -> LocalizedStringKey {
+    switch kind {
+    case .notRun: return "jit.probe.notRun"
+    case .passed: return "jit.probe.passed"
+    case .failed: return "jit.probe.failed"
+    }
+}
+
+private func txmStateKey(_ state: TXMState) -> String {
+    switch state {
+    case .present: return "jit.txm.present"
+    case .absent: return "jit.txm.absent"
+    case .unknown: return "jit.txm.unknown"
+    }
+}
+
+private func reasonKey(_ reason: JITReasonCode) -> LocalizedStringKey {
+    switch reason {
+    case .dopamineJITOff: return "jit.reason.dopamineJITOff"
+    case .rootlessJailbreakNoJIT: return "jit.reason.rootlessJailbreakNoJIT"
+    case .trollStoreRequestPending: return "jit.reason.trollStoreRequestPending"
+    case .trollStoreTimedOut: return "jit.reason.trollStoreTimedOut"
+    case .sideloadedNoJIT: return "jit.reason.sideloadedNoJIT"
+    case .txmEnforced: return "jit.reason.txmEnforced"
+    case .txmUndetermined: return "jit.reason.txmUndetermined"
+    case .probeSkippedAfterCrash: return "jit.reason.probeSkippedAfterCrash"
+    case .probeFailed: return "jit.reason.probeFailed"
+    case .unknownInstallNoJIT: return "jit.reason.unknownInstallNoJIT"
+    case .simulator: return "jit.reason.simulator"
+    }
+}
+
+#if DEBUG
+private func sampleStatus(usable: Bool, source: JITSource, reason: JITReasonCode?,
+                          probe: ProbeOutcome = ProbeOutcome(kind: .passed, detail: nil),
+                          seen: CSDebuggedSeen = .atLaunch) -> JITStatus {
+    JITStatus(csDebugged: usable, csDebuggedSeen: seen,
+              txm: TXMInfo(state: .absent, enforced: false, basis: "cpufamily heuristic"),
+              probe: probe, source: source, reason: reason)
+}
+
+private let sampleApp = AppInfoRows(version: "0.1.0", build: "12", commit: "0123abc",
+                                    packageKind: "tipa", bundleId: "com.example.sample")
+private let sampleDevice = DeviceRows(model: "iPad14,5", chip: "M2", osVersion: "17.0",
+                                      osBuild: "21A329", memory: "4 GB")
+
+private func sampleContent(status: JITStatus, method: InstallMethod, pending: Bool) -> StatusContent {
+    StatusContent(app: sampleApp, installMethod: method, status: status,
+                  isRequestingTrollStoreJIT: pending, device: sampleDevice, copied: false, reportError: false,
+                  onRetryJIT: {}, onRetryProbe: {}, onCopyReport: {}, onShareReport: {})
+}
+
+struct StatusView_Previews: PreviewProvider {
+    static var previews: some View {
+        sampleContent(status: sampleStatus(usable: true, source: .dopamine, reason: nil),
+                      method: .dopamine, pending: false)
+            .previewDisplayName("Usable")
+
+        sampleContent(status: sampleStatus(usable: false, source: .none, reason: .trollStoreRequestPending,
+                                           probe: ProbeOutcome(kind: .notRun, detail: nil)),
+                      method: .trollStore, pending: true)
+            .previewDisplayName("Pending")
+
+        sampleContent(status: sampleStatus(usable: false, source: .none, reason: .trollStoreTimedOut,
+                                           probe: ProbeOutcome(kind: .notRun, detail: nil)),
+                      method: .trollStore, pending: false)
+            .previewDisplayName("Timed out")
+
+        sampleContent(status: sampleStatus(usable: false, source: .dopamine, reason: .probeFailed,
+                                           probe: ProbeOutcome(kind: .failed, detail: "signal 11")),
+                      method: .dopamine, pending: false)
+            .previewDisplayName("Probe failed")
+
+        // Every reason code renders its text; a missing key would show as a raw key.
+        List {
+            ForEach(JITReasonCode.allCases, id: \.self) { reason in
+                Text(reasonKey(reason)).font(.footnote)
+            }
         }
+        .previewDisplayName("All reasons")
     }
 }
+#endif

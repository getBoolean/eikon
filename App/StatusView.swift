import EikonKit
import SwiftUI

/// Eikon's one screen. Observes the controller so JIT rows update live, and
/// reads the static device facts once.
struct StatusView: View {
    @ObservedObject var controller: JITController

    @State private var deviceSystem: LiveDeviceSystem?
    @State private var device: DeviceRows?
    @State private var shareItem: ShareItem?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var copied = false
    @State private var reportError = false

    var body: some View {
        StatusContent(
            app: appRows,
            installMethod: controller.installMethod,
            status: controller.status,
            isRequestingTrollStoreJIT: controller.isRequestingTrollStoreJIT,
            device: device,
            copied: copied,
            reportError: reportError,
            onRetryJIT: { controller.retryTrollStoreJIT() },
            onRetryProbe: { controller.retryProbe() },
            onCopyReport: copyReport,
            onShareReport: shareReport
        )
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .onAppear(perform: loadDeviceFacts)
    }

    private var appRows: AppInfoRows {
        func value(_ key: String) -> String? {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return AppInfoRows(
            version: value("CFBundleShortVersionString"),
            build: value("CFBundleVersion"),
            commit: value("EKGitCommit"),
            packageKind: value("EKPackageKind"),
            bundleId: Bundle.main.bundleIdentifier
        )
    }

    private func loadDeviceFacts() {
        let system = LiveDeviceSystem.current()
        deviceSystem = system
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        device = DeviceRows(
            model: system.modelIdentifier,
            chip: ChipNames.displayName(forModel: system.modelIdentifier),
            osVersion: system.osVersion,
            osBuild: system.osBuild,
            memory: formatter.string(fromByteCount: Int64(clamping: system.availableMemoryBytes()))
        )
    }

    private func makeReport() -> DeviceReport? {
        guard let deviceSystem else { return nil }
        return DeviceReport.make(
            app: AppInfo.from(.main),
            installMethod: controller.installMethod,
            evidence: controller.evidence,
            jit: controller.status,
            system: deviceSystem,
            now: Date()
        )
    }

    private func copyReport() {
        guard let report = makeReport(), (try? ReportExport.copy(report)) != nil else {
            reportError = true
            return
        }
        reportError = false
        copied = true
        // Cancel any earlier reset so rapid taps don't clear the label early.
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { copied = false }
        }
    }

    private func shareReport() {
        guard let report = makeReport(), let url = try? ReportExport.temporaryFile(for: report) else {
            reportError = true
            return
        }
        reportError = false
        shareItem = ShareItem(url: url)
    }
}

/// Pure presentation of one snapshot plus actions. The preview renders this directly.
struct StatusContent: View {
    let app: AppInfoRows
    let installMethod: InstallMethod
    let status: JITStatus
    let isRequestingTrollStoreJIT: Bool
    let device: DeviceRows?
    let copied: Bool
    let reportError: Bool
    let onRetryJIT: () -> Void
    let onRetryProbe: () -> Void
    let onCopyReport: () -> Void
    let onShareReport: () -> Void

    /// No navigation view of its own: RootView's column navigation hosts it.
    var body: some View {
        List {
            appSection
            installSection
            jitSection
            deviceSection
            reportSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("status.title"))
    }

    private var appSection: some View {
        Section(header: Text("status.section.app")) {
            if let version = app.version, let build = app.build {
                LabelRow(labelKey: "status.app.version",
                         value: String(format: localized("status.app.version.format"), version, build))
            } else {
                UnknownRow(labelKey: "status.app.version")
            }
            valueRow("status.app.commit", app.commit, selectable: true)
            valueRow("status.app.packageKind", app.packageKind)
            valueRow("status.app.bundleId", app.bundleId, selectable: true)
        }
    }

    private var installSection: some View {
        Section(header: Text("status.section.install")) {
            LabelRow(labelKey: "install.method.label", valueKey: installMethodKey(installMethod))
        }
    }

    @ViewBuilder
    private var jitSection: some View {
        Section(header: Text("status.section.jit")) {
            HStack(spacing: 8) {
                Image(systemName: status.usable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(status.usable ? .green : .secondary)
                Text(status.usable ? "jit.state.usable" : "jit.state.notUsable")
                    .font(.title2.weight(.semibold))
            }
            .accessibilityElement(children: .combine)

            if isRequestingTrollStoreJIT {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("jit.pending")
                }
            }

            if let reason = status.reason, !(reason == .trollStoreRequestPending && isRequestingTrollStoreJIT) {
                Text(reasonKey(reason))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            LabelRow(labelKey: "jit.source.label", valueKey: sourceKey(status.source))
            csDebuggedRow
            probeRow
            txmRow

            if showsRetryJIT {
                Button(action: onRetryJIT) { Text("jit.retryJIT") }
            }
            if status.reason == .probeSkippedAfterCrash || status.reason == .probeFailed {
                Button(action: onRetryProbe) { Text("jit.retryProbe") }
            }
        }
    }

    private var csDebuggedRow: some View {
        HStack {
            Text("jit.csDebugged.label")
            Spacer()
            csDebuggedValue
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var csDebuggedValue: Text {
        let yesNo = Text(status.csDebugged ? "status.value.yes" : "status.value.no")
        guard status.csDebugged, let seenKey = seenKey(status.csDebuggedSeen) else { return yesNo }
        return yesNo + Text(verbatim: " ") + Text(seenKey)
    }

    @ViewBuilder
    private var probeRow: some View {
        LabelRow(labelKey: "jit.probe.label", valueKey: probeKey(status.probe.kind))
        if let detail = status.probe.detail {
            SecondaryLine(text: detail)
        }
    }

    @ViewBuilder
    private var txmRow: some View {
        LabelRow(labelKey: "jit.txm.label",
                 value: "\(localized(txmStateKey(status.txm.state))), "
                     + localized(status.txm.enforced ? "jit.txm.enforced" : "jit.txm.notEnforced"))
        SecondaryLine(text: status.txm.basis)
    }

    @ViewBuilder
    private var deviceSection: some View {
        Section(header: Text("status.section.device")) {
            if let device {
                valueRow("device.model", device.model, selectable: true)
                LabelRow(labelKey: "device.chip", value: device.chip)
                LabelRow(labelKey: "device.os",
                         value: String(format: localized("device.os.format"), device.osVersion, device.osBuild))
                LabelRow(labelKey: "device.memory", value: device.memory)
            } else {
                UnknownRow(labelKey: "device.model")
            }
        }
    }

    private var reportSection: some View {
        Section(header: Text("status.section.report")) {
            Button(action: onCopyReport) { Text("report.copy") }
            Button(action: onShareReport) { Text("report.share") }
            if copied {
                Text("report.copied").font(.footnote).foregroundColor(.secondary)
            }
            if reportError {
                Text("report.error").font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    private var showsRetryJIT: Bool {
        (installMethod == .trollStore || installMethod == .trollStoreLite)
            && !status.usable && !isRequestingTrollStoreJIT
    }

    @ViewBuilder
    private func valueRow(_ labelKey: LocalizedStringKey, _ value: String?, selectable: Bool = false) -> some View {
        if let value {
            LabelRow(labelKey: labelKey, value: value, selectable: selectable)
        } else {
            UnknownRow(labelKey: labelKey)
        }
    }
}

// MARK: - Row building blocks

private struct LabelRow: View {
    let labelKey: LocalizedStringKey
    var value: String?
    var valueKey: LocalizedStringKey?
    var selectable = false

    init(labelKey: LocalizedStringKey, value: String, selectable: Bool = false) {
        self.labelKey = labelKey
        self.value = value
        self.selectable = selectable
    }

    init(labelKey: LocalizedStringKey, valueKey: LocalizedStringKey) {
        self.labelKey = labelKey
        self.valueKey = valueKey
    }

    var body: some View {
        HStack {
            Text(labelKey)
            Spacer()
            if selectable {
                valueText
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else {
                valueText
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if let valueKey {
            Text(valueKey)
        } else {
            Text(verbatim: value ?? "")
        }
    }
}

private struct UnknownRow: View {
    let labelKey: LocalizedStringKey
    var body: some View {
        HStack {
            Text(labelKey)
            Spacer()
            Text("status.value.unknown").foregroundColor(.secondary)
        }
    }
}

private struct SecondaryLine: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
    }
}

/// Display-ready values gathered once from the bundle and the device.
struct AppInfoRows {
    var version: String?
    var build: String?
    var commit: String?
    var packageKind: String?
    var bundleId: String?
}

struct DeviceRows {
    var model: String
    var chip: String
    var osVersion: String
    var osBuild: String
    var memory: String
}

/// Wraps a URL so it can drive a .sheet(item:) without a module-wide conformance.
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

// MARK: - Exhaustive enum → key mappings (no `default:`, so a new case fails the build)

private func installMethodKey(_ method: InstallMethod) -> LocalizedStringKey {
    switch method {
    case .dopamine: return "install.method.dopamine"
    case .rootlessJailbreak: return "install.method.rootlessJailbreak"
    case .trollStore: return "install.method.trollStore"
    case .trollStoreLite: return "install.method.trollStoreLite"
    case .sideloaded: return "install.method.sideloaded"
    case .simulator: return "install.method.simulator"
    case .unknown: return "install.method.unknown"
    }
}

private func sourceKey(_ source: JITSource) -> LocalizedStringKey {
    switch source {
    case .none: return "jit.source.none"
    case .dopamine: return "jit.source.dopamine"
    case .rootlessJailbreak: return "jit.source.rootlessJailbreak"
    case .trollStore: return "jit.source.trollStore"
    case .externalEnabler: return "jit.source.externalEnabler"
    case .preexisting: return "jit.source.preexisting"
    case .unknown: return "jit.source.unknown"
    }
}

private func seenKey(_ seen: CSDebuggedSeen) -> LocalizedStringKey? {
    switch seen {
    case .never: return nil
    case .atLaunch: return "jit.seen.atLaunch"
    case .afterTrollStoreRequest: return "jit.seen.afterTrollStoreRequest"
    case .onForeground: return "jit.seen.onForeground"
    }
}

private func probeKey(_ kind: ProbeOutcome.Kind) -> LocalizedStringKey {
    switch kind {
    case .notRun: return "jit.probe.notRun"
    case .passed: return "jit.probe.passed"
    case .failed: return "jit.probe.failed"
    }
}

private func txmStateKey(_ state: TXMState) -> String {
    switch state {
    case .present: return "jit.txm.present"
    case .absent: return "jit.txm.absent"
    case .unknown: return "jit.txm.unknown"
    }
}

private func reasonKey(_ reason: JITReasonCode) -> LocalizedStringKey {
    switch reason {
    case .dopamineJITOff: return "jit.reason.dopamineJITOff"
    case .rootlessJailbreakNoJIT: return "jit.reason.rootlessJailbreakNoJIT"
    case .trollStoreRequestPending: return "jit.reason.trollStoreRequestPending"
    case .trollStoreTimedOut: return "jit.reason.trollStoreTimedOut"
    case .sideloadedNoJIT: return "jit.reason.sideloadedNoJIT"
    case .txmEnforced: return "jit.reason.txmEnforced"
    case .txmUndetermined: return "jit.reason.txmUndetermined"
    case .probeSkippedAfterCrash: return "jit.reason.probeSkippedAfterCrash"
    case .probeFailed: return "jit.reason.probeFailed"
    case .unknownInstallNoJIT: return "jit.reason.unknownInstallNoJIT"
    case .simulator: return "jit.reason.simulator"
    }
}

#if DEBUG
private func sampleStatus(usable: Bool, source: JITSource, reason: JITReasonCode?,
                          probe: ProbeOutcome = ProbeOutcome(kind: .passed, detail: nil),
                          seen: CSDebuggedSeen = .atLaunch, csDebugged: Bool? = nil) -> JITStatus {
    JITStatus(csDebugged: csDebugged ?? usable, csDebuggedSeen: seen,
              txm: TXMInfo(state: .absent, enforced: false, basis: "cpufamily heuristic"),
              probe: probe, source: source, reason: reason)
}

private let sampleApp = AppInfoRows(version: "0.1.0", build: "12", commit: "0123abc",
                                    packageKind: "ipa", bundleId: "com.example.sample")
private let sampleDevice = DeviceRows(model: "iPad14,5", chip: "M2", osVersion: "17.0",
                                      osBuild: "21A329", memory: "4 GB")

@MainActor
private func sampleContent(status: JITStatus, method: InstallMethod, pending: Bool) -> some View {
    NavigationView {
        StatusContent(app: sampleApp, installMethod: method, status: status,
                      isRequestingTrollStoreJIT: pending, device: sampleDevice, copied: false, reportError: false,
                      onRetryJIT: {}, onRetryProbe: {}, onCopyReport: {}, onShareReport: {})
    }
    .navigationViewStyle(.stack)
}

struct StatusView_Previews: PreviewProvider {
    static var previews: some View {
        sampleContent(status: sampleStatus(usable: true, source: .dopamine, reason: nil),
                      method: .dopamine, pending: false)
            .previewDisplayName("Usable")

        sampleContent(status: sampleStatus(usable: false, source: .none, reason: .trollStoreRequestPending,
                                           probe: ProbeOutcome(kind: .notRun, detail: nil)),
                      method: .trollStore, pending: true)
            .previewDisplayName("Pending")

        sampleContent(status: sampleStatus(usable: false, source: .none, reason: .trollStoreTimedOut,
                                           probe: ProbeOutcome(kind: .notRun, detail: nil)),
                      method: .trollStore, pending: false)
            .previewDisplayName("Timed out")

        sampleContent(status: sampleStatus(usable: false, source: .dopamine, reason: .probeFailed,
                                           probe: ProbeOutcome(kind: .failed, detail: "signal 11"),
                                           csDebugged: true),
                      method: .dopamine, pending: false)
            .previewDisplayName("Probe failed")

        // Every reason code renders its text; a missing key would show as a raw key.
        List {
            ForEach(JITReasonCode.allCases, id: \.self) { reason in
                Text(reasonKey(reason)).font(.footnote)
            }
        }
        .previewDisplayName("All reasons")
    }
}
#endif

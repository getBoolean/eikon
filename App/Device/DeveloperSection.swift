import EikonCore
import EikonKit
import SwiftUI

/// One raw gate store entry, uninterpreted.
struct GateStoreEntryRow {
    var name: GateName
    var passed: Bool?
    var appBuild: String
    var osBuild: String
    var measuredAt: Date
    var detail: String

    init(_ entry: GateEntry) {
        name = entry.name
        passed = entry.result.passed
        appBuild = entry.stamp.app
        osBuild = entry.stamp.os
        measuredAt = entry.result.measuredAt
        detail = entry.result.detail
    }
}

struct DeveloperRows {
    var replicaID: String
    /// This device's settings file was from a newer build, so the store forked to a new replica.
    var settingsForked: Bool
    var gateEntries: [GateStoreEntryRow]
    /// Disables the test buttons while a session runs.
    var sessionActive: Bool
    /// The last test session couldn't start.
    var testSessionFailed: Bool
}

/// Developer tools, in every build, collapsed by default.
struct DeveloperSection: View {
    let rows: DeveloperRows
    let onRunTestSession: () -> Void
    let onSimulateCrash: () -> Void
    @State private var isExpanded: Bool

    init(rows: DeveloperRows, onRunTestSession: @escaping () -> Void, onSimulateCrash: @escaping () -> Void,
         isExpanded: Bool = false) {
        self.rows = rows
        self.onRunTestSession = onRunTestSession
        self.onSimulateCrash = onSimulateCrash
        _isExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                if rows.settingsForked {
                    Label {
                        Text("developer.settingsForked")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
                Button("developer.runTestSession", action: onRunTestSession)
                    .disabled(rows.sessionActive)
                VStack(alignment: .leading, spacing: 4) {
                    Button("developer.simulateCrash", action: onSimulateCrash)
                        .disabled(rows.sessionActive)
                    Text("developer.simulateCrash.footnote")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if rows.testSessionFailed {
                    Text("developer.testSession.failed")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("developer.replicaID")
                    Text(verbatim: rows.replicaID)
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                gateStore
            } label: {
                Text("status.section.developer")
            }
        }
    }

    @ViewBuilder
    private var gateStore: some View {
        Text("developer.gates")
        if rows.gateEntries.isEmpty {
            Text("developer.gates.empty")
                .foregroundColor(.secondary)
        } else {
            // By position: raw contents may repeat a name.
            ForEach(Array(rows.gateEntries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: entry.name.rawValue)
                            .font(.body.monospaced())
                        Spacer()
                        Text(Self.resultKey(entry.passed))
                            .foregroundColor(.secondary)
                    }
                    Group {
                        Text(L10n.format("developer.gates.stamp", entry.appBuild, entry.osBuild))
                        Text(verbatim: GateTableSection.dateFormatter.string(from: entry.measuredAt))
                        if !entry.detail.isEmpty {
                            Text(verbatim: entry.detail)
                        }
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                }
            }
        }
    }

    /// The stored result as written, not mapped through the build-expiry rules.
    private static func resultKey(_ passed: Bool?) -> LocalizedStringKey {
        switch passed {
        case true?: "developer.gates.result.passed"
        case false?: "developer.gates.result.failed"
        case nil: "developer.gates.result.unmeasured"
        }
    }
}

#if DEBUG
struct DeveloperSection_Previews: PreviewProvider {
    static let entries = [
        GateStoreEntryRow(GateEntry(name: .x18, result: GateResult(passed: true, detail: "sample detail", measuredAt: Date()),
                                    stamp: BuildStamp(app: "1.0 (1) abc1234", os: "23A341"))),
        GateStoreEntryRow(GateEntry(name: .guestWindow, result: GateResult(passed: false, detail: "", measuredAt: Date()),
                                    stamp: BuildStamp(app: "1.0 (1) abc1234", os: "23A341"))),
        GateStoreEntryRow(GateEntry(name: GateName(rawValue: "futureGate"),
                                    result: GateResult(passed: nil, detail: "", measuredAt: Date()),
                                    stamp: BuildStamp(app: "1.0 (1) abc1234", os: "23A341"))),
    ]

    static func rows(entries: [GateStoreEntryRow], forked: Bool, failed: Bool = false) -> DeveloperRows {
        DeveloperRows(replicaID: UUID().uuidString.lowercased(), settingsForked: forked, gateEntries: entries,
                      sessionActive: false, testSessionFailed: failed)
    }

    static var previews: some View {
        List {
            DeveloperSection(rows: rows(entries: [], forked: false), onRunTestSession: {}, onSimulateCrash: {},
                             isExpanded: true)
            DeveloperSection(rows: rows(entries: entries, forked: true), onRunTestSession: {}, onSimulateCrash: {},
                             isExpanded: true)
            DeveloperSection(rows: rows(entries: entries, forked: false), onRunTestSession: {}, onSimulateCrash: {},
                             isExpanded: true)
            DeveloperSection(rows: rows(entries: [], forked: true, failed: true), onRunTestSession: {},
                             onSimulateCrash: {}, isExpanded: true)
        }
        .listStyle(.insetGrouped)
    }
}
#endif

import SwiftUI

/// Placeholder status screen: shows the version stamps from the Info.plist so
/// they can be checked by eye. Section 09 replaces it.
struct StatusView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        NavigationView {
            List {
                row("Version", value("CFBundleShortVersionString"))
                row("Build", value("CFBundleVersion"))
                row("Commit", value("EKGitCommit"))
                row("Package kind", value("EKPackageKind"))
                row("Bundle ID", Bundle.main.bundleIdentifier ?? "–")
            }
            .navigationTitle("Eikon")
        }
        .navigationViewStyle(.stack)
    }

    private func value(_ key: String) -> String {
        (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "–"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}

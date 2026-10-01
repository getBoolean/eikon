import EikonKit
import SwiftUI

/// The Credits destination: Eikon first, then every third-party component, each with its
/// full license text. Reads the bundled acknowledgements once.
struct CreditsView: View {
    /// Read once per launch: the bundled file can't change, and iOS 15 builds sidebar
    /// destinations eagerly on every update.
    private static let acknowledgements = Acknowledgements.load(bundle: .main)

    var body: some View {
        CreditsContent(acknowledgements: Self.acknowledgements)
    }
}

/// The list for one load result. The preview renders this directly.
struct CreditsContent: View {
    let acknowledgements: Result<Acknowledgements, AcknowledgementsError>

    var body: some View {
        List {
            switch acknowledgements {
            case .success(let loaded):
                Section(footer: loaded.app != nil && loaded.components.isEmpty ? Text("credits.noThirdParty") : nil) {
                    if let app = loaded.app {
                        row(app)
                    }
                }
                if !loaded.components.isEmpty {
                    Section {
                        ForEach(loaded.components) { row($0) }
                    }
                }
            case .failure:
                Text("credits.loadError")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("credits.title"))
    }

    private func row(_ entry: Acknowledgement) -> some View {
        NavigationLink(destination: AcknowledgementDetail(entry: entry)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .font(.headline)
                Text(verbatim: "\(entry.license) · \(entry.revision)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// One entry with its full, selectable license text.
struct AcknowledgementDetail: View {
    let entry: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                field("credits.license", Text(verbatim: entry.license))
                field("credits.revision", Text(verbatim: entry.revision))
                if let url = URL(string: entry.url), url.scheme != nil {
                    field("credits.source", Text(verbatim: entry.url), link: url)
                } else {
                    field("credits.source", Text(verbatim: entry.url))
                }
                Divider()
                Text(verbatim: entry.licenseText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(Text(verbatim: entry.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func field(_ label: LocalizedStringKey, _ value: Text, link: URL? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            if let link {
                Link(destination: link) { value }
            } else {
                value
                    .textSelection(.enabled)
            }
        }
    }
}

#if DEBUG
struct CreditsContent_Previews: PreviewProvider {
    static let app = #"{"name": "Eikon", "url": "https://example.invalid/eikon", "revision": "sample 1.0.0", "license": "GPL-3.0-or-later", "licenseText": "Sample license text", "isApp": true}"#
    static let component = #"{"name": "Sample Library", "url": "https://example.invalid/lib", "revision": "sample release v1", "license": "MIT", "licenseText": "Sample license text", "isApp": false}"#

    static func content(_ json: String) -> some View {
        NavigationView {
            CreditsContent(acknowledgements: Result { try Acknowledgements.decode(Data(json.utf8)) }
                .mapError { _ in AcknowledgementsError.malformed })
        }
        .navigationViewStyle(.stack)
    }

    static var previews: some View {
        content("[\(app)]")
        content("[\(app), \(component)]")
        content("not json")
        if let entry = (try? Acknowledgements.decode(Data("[\(app)]".utf8)))?.app {
            NavigationView {
                AcknowledgementDetail(entry: entry)
            }
            .navigationViewStyle(.stack)
        }
    }
}
#endif

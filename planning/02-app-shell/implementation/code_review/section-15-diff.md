diff --git a/App/Credits/CreditsView.swift b/App/Credits/CreditsView.swift
new file mode 100644
index 0000000..04c0c4d
--- /dev/null
+++ b/App/Credits/CreditsView.swift
@@ -0,0 +1,119 @@
+import EikonKit
+import SwiftUI
+
+/// The Credits destination: Eikon first, then every third-party component, each with its
+/// full license text. Reads the bundled acknowledgements once.
+struct CreditsView: View {
+    @State private var acknowledgements = Acknowledgements.load(bundle: .main)
+
+    var body: some View {
+        CreditsContent(acknowledgements: acknowledgements)
+    }
+}
+
+/// The list for one load result. The preview renders this directly.
+struct CreditsContent: View {
+    let acknowledgements: Result<Acknowledgements, AcknowledgementsError>
+
+    var body: some View {
+        List {
+            switch acknowledgements {
+            case .success(let loaded):
+                Section(footer: loaded.components.isEmpty ? Text("credits.noThirdParty") : nil) {
+                    if let app = loaded.app {
+                        row(app)
+                    }
+                }
+                if !loaded.components.isEmpty {
+                    Section {
+                        ForEach(loaded.components) { row($0) }
+                    }
+                }
+            case .failure:
+                Text("credits.loadError")
+                    .foregroundColor(.secondary)
+            }
+        }
+        .listStyle(.insetGrouped)
+        .navigationTitle(Text("credits.title"))
+    }
+
+    private func row(_ entry: Acknowledgement) -> some View {
+        NavigationLink(destination: AcknowledgementDetail(entry: entry)) {
+            VStack(alignment: .leading, spacing: 2) {
+                Text(verbatim: entry.name)
+                    .font(.headline)
+                Text(verbatim: "\(entry.license) · \(entry.revision)")
+                    .font(.caption)
+                    .foregroundColor(.secondary)
+            }
+        }
+    }
+}
+
+/// One entry with its full, selectable license text.
+struct AcknowledgementDetail: View {
+    let entry: Acknowledgement
+
+    var body: some View {
+        ScrollView {
+            VStack(alignment: .leading, spacing: 12) {
+                field("credits.license", Text(verbatim: entry.license))
+                field("credits.revision", Text(verbatim: entry.revision))
+                if let url = URL(string: entry.url), url.scheme != nil {
+                    field("credits.source", Text(verbatim: entry.url), link: url)
+                } else {
+                    field("credits.source", Text(verbatim: entry.url))
+                }
+                Divider()
+                Text(verbatim: entry.licenseText)
+                    .font(.footnote.monospaced())
+                    .textSelection(.enabled)
+            }
+            .padding()
+            .frame(maxWidth: .infinity, alignment: .leading)
+        }
+        .navigationTitle(Text(verbatim: entry.name))
+        .navigationBarTitleDisplayMode(.inline)
+    }
+
+    @ViewBuilder
+    private func field(_ label: LocalizedStringKey, _ value: Text, link: URL? = nil) -> some View {
+        VStack(alignment: .leading, spacing: 2) {
+            Text(label)
+                .font(.caption)
+                .foregroundColor(.secondary)
+            if let link {
+                Link(destination: link) { value }
+            } else {
+                value
+                    .textSelection(.enabled)
+            }
+        }
+    }
+}
+
+#if DEBUG
+struct CreditsContent_Previews: PreviewProvider {
+    static let app = #"{"name": "Eikon", "url": "https://example.invalid/eikon", "revision": "sample 1.0.0", "license": "GPL-3.0-or-later", "licenseText": "Sample license text", "isApp": true}"#
+    static let component = #"{"name": "Sample Library", "url": "https://example.invalid/lib", "revision": "sample release v1", "license": "MIT", "licenseText": "Sample license text", "isApp": false}"#
+
+    static func content(_ json: String) -> some View {
+        NavigationView {
+            CreditsContent(acknowledgements: Result { try Acknowledgements.decode(Data(json.utf8)) }
+                .mapError { _ in AcknowledgementsError.malformed })
+        }
+        .navigationViewStyle(.stack)
+    }
+
+    static var previews: some View {
+        content("[\(app)]")
+        content("[\(app), \(component)]")
+        content("not json")
+        NavigationView {
+            AcknowledgementDetail(entry: try! Acknowledgements.decode(Data("[\(app)]".utf8)).entries[0])
+        }
+        .navigationViewStyle(.stack)
+    }
+}
+#endif
diff --git a/App/RootView.swift b/App/RootView.swift
index b20d127..a8b038a 100644
--- a/App/RootView.swift
+++ b/App/RootView.swift
@@ -72,7 +72,6 @@ struct RootView: View {
         }
     }
 
-    /// Section 15 replaces the Credits placeholder.
     @ViewBuilder
     private func destination(_ target: RootDestination) -> some View {
         switch target {
@@ -81,7 +80,7 @@ struct RootView: View {
         case .device:
             StatusView(controller: jit, presenter: services.presenter, gates: services.gates, settings: services.settings,
                        registry: services.registry)
-        case .credits: DestinationPlaceholder(titleKey: "credits.title")
+        case .credits: CreditsView()
         }
     }
 
@@ -94,16 +93,6 @@ func appRelative(_ url: URL) -> String {
     return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
 }
 
-/// Stands in for a destination another section builds.
-private struct DestinationPlaceholder: View {
-    let titleKey: LocalizedStringKey
-
-    var body: some View {
-        List {}
-            .navigationTitle(Text(titleKey))
-    }
-}
-
 /// Shown instead of the app when its data can't be opened. An unreadable library secret
 /// is the user's to fix or start over; nothing is replaced on its own.
 struct StartupFailureView: View {
diff --git a/App/en.lproj/Localizable.strings b/App/en.lproj/Localizable.strings
index 8bcb3f4..f11a240 100644
--- a/App/en.lproj/Localizable.strings
+++ b/App/en.lproj/Localizable.strings
@@ -354,3 +354,10 @@
 "developer.gates.result.failed" = "failed";
 "developer.gates.result.unmeasured" = "not measured";
 "developer.testPattern.errors" = "Command-buffer errors: %ld";
+
+/* Credits */
+"credits.noThirdParty" = "Eikon includes no third-party components yet.";
+"credits.loadError" = "The acknowledgements couldn't be loaded.";
+"credits.license" = "License";
+"credits.revision" = "Revision";
+"credits.source" = "Source";
diff --git a/Packages/EikonKit/Sources/EikonKit/Credits/Acknowledgements.swift b/Packages/EikonKit/Sources/EikonKit/Credits/Acknowledgements.swift
new file mode 100644
index 0000000..3ea4763
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Credits/Acknowledgements.swift
@@ -0,0 +1,58 @@
+import Foundation
+
+/// One entry of `Acknowledgements.json`, written by `scripts/credits.py app-json`.
+public struct Acknowledgement: Decodable, Identifiable, Hashable, Sendable {
+    public let name: String
+    /// Kept as written; the view links it only when it parses as a URL.
+    public let url: String
+    public let revision: String
+    /// An SPDX expression.
+    public let license: String
+    public let licenseText: String
+    /// Eikon's own entry. Absent in files from before the flag, which read as components.
+    public let isApp: Bool
+
+    public var id: String { "\(name)\u{0}\(revision)" }
+
+    private enum CodingKeys: String, CodingKey {
+        case name, url, revision, license, licenseText, isApp
+    }
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        name = try container.decode(String.self, forKey: .name)
+        url = try container.decode(String.self, forKey: .url)
+        revision = try container.decode(String.self, forKey: .revision)
+        license = try container.decode(String.self, forKey: .license)
+        licenseText = try container.decode(String.self, forKey: .licenseText)
+        isApp = try container.decodeIfPresent(Bool.self, forKey: .isApp) ?? false
+    }
+}
+
+public enum AcknowledgementsError: Error, Sendable, Equatable {
+    case missing
+    case malformed
+}
+
+/// The bundled acknowledgements: the app's own entry first, then components in file order.
+public struct Acknowledgements: Sendable {
+    public let entries: [Acknowledgement]
+
+    public var app: Acknowledgement? { entries.first { $0.isApp } }
+    public var components: [Acknowledgement] { entries.filter { !$0.isApp } }
+
+    /// Decodes the generator's format, a JSON array. Throws on malformed input.
+    public static func decode(_ data: Data) throws -> Acknowledgements {
+        let decoded = try JSONDecoder().decode([Acknowledgement].self, from: data)
+        return Acknowledgements(entries: decoded.filter(\.isApp) + decoded.filter { !$0.isApp })
+    }
+
+    /// `Acknowledgements.json` from the bundle; never traps.
+    public static func load(bundle: Bundle = .main) -> Result<Acknowledgements, AcknowledgementsError> {
+        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "json") else { return .failure(.missing) }
+        guard let data = try? Data(contentsOf: url), let acknowledgements = try? decode(data) else {
+            return .failure(.malformed)
+        }
+        return .success(acknowledgements)
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/AcknowledgementsTests.swift b/Packages/EikonKit/Tests/EikonKitTests/AcknowledgementsTests.swift
new file mode 100644
index 0000000..f33352d
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/AcknowledgementsTests.swift
@@ -0,0 +1,28 @@
+import Foundation
+import Testing
+@testable import EikonKit
+
+private func entry(_ name: String, isApp: Bool) -> [String: Any] {
+    ["name": name, "url": "https://example.invalid/\(name)", "revision": "\(name) release v1", "license": "MIT",
+     "licenseText": "\(name) license", "isApp": isApp]
+}
+
+@Test func decodedEntriesPutTheAppFirst() throws {
+    let data = try JSONSerialization.data(withJSONObject: [entry("component", isApp: false), entry("app", isApp: true)])
+    let acknowledgements = try Acknowledgements.decode(data)
+
+    #expect(acknowledgements.entries.map(\.name) == ["app", "component"])
+    #expect(acknowledgements.app?.name == "app")
+    #expect(acknowledgements.components.map(\.name) == ["component"])
+    let component = try #require(acknowledgements.components.first)
+    #expect(component.isApp == false)
+    #expect(component.url == "https://example.invalid/component")
+    #expect(component.revision == "component release v1")
+    #expect(component.license == "MIT")
+    #expect(component.licenseText == "component license")
+}
+
+@Test(arguments: ["not json", #"{"name": "an object, not an array"}"#, #"[{"name": "missing fields"}]"#])
+func malformedInputThrows(_ text: String) {
+    #expect(throws: (any Error).self) { try Acknowledgements.decode(Data(text.utf8)) }
+}
diff --git a/scripts/credits.py b/scripts/credits.py
index 5e21d0f..5ff29a5 100644
--- a/scripts/credits.py
+++ b/scripts/credits.py
@@ -7,6 +7,8 @@
 Every dependency in third_party/deps.toml needs a [[component]] entry in
 third_party/credits.toml. Its license files are committed under
 third_party/notices/<dep>/. Run from the repo root. See third_party/README.md.
+
+The in-app acknowledgements start with Eikon's own entry; every entry carries `isApp`.
 """
 
 from __future__ import annotations
@@ -24,6 +26,8 @@ NOTICES_DIR = Path("third_party") / "notices"
 NOTICES_FILE = Path("THIRD_PARTY_NOTICES.md")
 LICENSES_DIR = Path("licenses")
 EIKON_URL = "https://github.com/getBoolean/eikon"
+EIKON_LICENSE = "GPL-3.0-or-later"
+VERSION_FILE = Path("VERSION")
 
 _REQUIRED = {"name": str, "dep": str, "url": str, "license": str, "license_files": list}
 _NESTED_REQUIRED = {"path": str, "license": str, "license_files": list}
@@ -262,16 +266,47 @@ def generate_notices(repo_root: Path) -> str:
     return "\n".join(lines).rstrip("\n") + "\n"
 
 
+def _app_entry(repo_root: Path) -> tuple[dict | None, list[str]]:
+    """Eikon's own acknowledgements entry (isApp: true), or the problems that prevent it:
+    a missing or empty VERSION, or a missing licenses/GPL-3.0-or-later.txt."""
+    problems = []
+    version_path = repo_root / VERSION_FILE
+    version = version_path.read_text(encoding="utf-8").strip() if version_path.is_file() else ""
+    if not version:
+        problems.append(f"{VERSION_FILE}: missing or empty")
+    license_path = repo_root / LICENSES_DIR / f"{EIKON_LICENSE}.txt"
+    if not license_path.is_file():
+        problems.append(f"{LICENSES_DIR / (EIKON_LICENSE + '.txt')}: missing")
+    if problems:
+        return None, problems
+    return {
+        "name": "Eikon",
+        "url": EIKON_URL,
+        "revision": f"getBoolean/eikon {version}",
+        "license": EIKON_LICENSE,
+        "licenseText": _read_text(license_path),
+        "isApp": True,
+    }, []
+
+
 def generate_app_json(repo_root: Path, out: Path) -> None:
-    """Write the acknowledgements JSON: one object per component, in manifest order."""
-    components, deps = _require_clean(repo_root)
-    items = [
+    """Write the acknowledgements JSON: Eikon's own entry first, then one object per
+    component in manifest order. Every entry carries `isApp`."""
+    app, problems = _app_entry(repo_root)
+    try:
+        components, deps = _require_clean(repo_root)
+    except ValueError as err:
+        raise ValueError("\n".join(problems + [str(err)])) from None
+    if problems:
+        raise ValueError("\n".join(problems))
+    items = [app] + [
         {
             "name": c["name"],
             "url": c["url"],
             "revision": _revision(deps[c["dep"]]),
             "license": c["license"],
             "licenseText": "\n".join(f"{label}\n\n{text}" for label, text in _license_texts(repo_root, c)),
+            "isApp": False,
         }
         for c in components
     ]
diff --git a/tests/test_credits.py b/tests/test_credits.py
index 29a7c0a..5d62a7e 100644
--- a/tests/test_credits.py
+++ b/tests/test_credits.py
@@ -3,6 +3,7 @@
 from __future__ import annotations
 
 import importlib.util
+import json
 import sys
 from pathlib import Path
 
@@ -31,12 +32,15 @@ def _toml(table: str, entries: list[dict]) -> str:
 
 
 class Project:
+    version = "1.2.3"
+
     def __init__(self, repo) -> None:
         self.repo = repo
         self.root: Path = repo.path
         self.deps: list[dict] = []
         self.components: list[dict] = []
         repo.write("licenses/GPL-3.0-or-later.txt", "license text\n")
+        repo.write("VERSION", f"{self.version}\n")
         self.save()
 
     def add_dep(self, name: str) -> None:
@@ -119,3 +123,32 @@ def test_stale_notices_fail_until_regenerated(project, run_script):
 
     assert _cli(run_script, project, "notices", "--write").returncode == 0
     assert credits.check(project.root) == []
+
+
+def _app_json(project: Project) -> list[dict]:
+    out = project.root / "build" / "Acknowledgements.json"
+    credits.generate_app_json(project.root, out)
+    return json.loads(out.read_text(encoding="utf-8"))
+
+
+def test_app_json_has_only_the_app_entry_without_components(project):
+    """One entry, marked as the app, carrying the repo's GPL text."""
+    entries = _app_json(project)
+    assert len(entries) == 1
+    assert entries[0]["isApp"] is True
+    gpl = (project.root / "licenses" / "GPL-3.0-or-later.txt").read_text(encoding="utf-8")
+    assert entries[0]["licenseText"] == gpl
+    assert project.version in entries[0]["revision"]
+
+
+def test_app_json_lists_components_after_the_app_entry(project):
+    """App entry first; only it is marked as the app."""
+    project.add_dep("libalpha")
+    project.credit("libalpha")
+    project.save()
+    entries = _app_json(project)
+    assert len(entries) == 2
+    assert entries[0]["isApp"] is True
+    assert [e["isApp"] for e in entries].count(True) == 1
+    assert entries[1]["isApp"] is False
+    assert entries[1]["name"] == "libalpha"

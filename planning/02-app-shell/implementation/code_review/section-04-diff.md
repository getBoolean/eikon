diff --git a/Makefile b/Makefile
index 60d83de..4c03617 100644
--- a/Makefile
+++ b/Makefile
@@ -16,6 +16,8 @@ help:
 	@echo "         test-swift test-scripts scan-collection [ARGS=<args>] archive ipa deb"
 	@echo "         package verify all publish"
 	@echo "         fetch-deps verify-deps pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>] clean"
+	@echo "  scan-collection: read-only scan of /Volumes/Games (prints skipped when not mounted);"
+	@echo "                   ARGS=--hash also fingerprints every game (reads every file)"
 
 doctor:
 	@scripts/doctor.sh
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/EngineDeclaredID.swift b/Packages/EikonCore/Sources/EikonCore/Identity/EngineDeclaredID.swift
index 8685f99..2aec368 100644
--- a/Packages/EikonCore/Sources/EikonCore/Identity/EngineDeclaredID.swift
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/EngineDeclaredID.swift
@@ -14,6 +14,7 @@ public enum EngineDeclaredID {
     /// Scanner data extends this table.
     static let genericValues: Set<String> = Set([
         "TVP(KIRIKIRI)", "TVP(KIRIKIRI) 2", "TVP(KIRIKIRI) Z", "KIRIKIRI", "KIRIKIRI Z",
+        "TVP(KIRIKIRI) 2 core / Scripting Platform for Win32", "TVP(KIRIKIRI) Z core / Scripting Platform for Win32",
         "Unity", "Unity Technologies ApS", "DefaultCompany", "My project",
         "Ren'Py", "RenPy", "Python", "YoYo Games Ltd", "GameMaker", "Created with GameMaker Studio 2",
     ].map(NameNormalizer.normalize))
diff --git a/Packages/EikonCore/Sources/EikonCore/Scan/CollectionScan.swift b/Packages/EikonCore/Sources/EikonCore/Scan/CollectionScan.swift
new file mode 100644
index 0000000..7115758
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Scan/CollectionScan.swift
@@ -0,0 +1,57 @@
+import Foundation
+
+public enum ScanOutcome: Sendable {
+    /// The root is absent (the share isn't mounted).
+    case skipped(root: String)
+    case scanned(CollectionSummary)
+}
+
+/// Scans a collection root the way the library scans a game drive. Synchronous and
+/// read-only: it never writes, sets attributes or caches anything under the root.
+public enum CollectionScan {
+    /// A fixed, public scanner secret, so fingerprints compare across runs. It keys
+    /// scanner output only; the app never uses it, and it is never a library secret.
+    public static let scannerSecret = LibrarySecret(bytes: Data("eikon-scan fixed secret, not private".utf8.prefix(32)))
+
+    /// Each immediate, non-dot subfolder goes through GameDetector (with the wrapper rule)
+    /// and EngineDeclaredID; with `hash`, also FingerprintBuilder, which reads every file.
+    /// `progress` gets (folders done, folder count) and, while hashing, the folder's fraction.
+    public static func run(root: URL, hash: Bool,
+                           progress: ((_ done: Int, _ total: Int, _ fraction: Double) -> Void)? = nil) -> ScanOutcome {
+        var isDirectory: ObjCBool = false
+        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
+              let listing = try? FolderListing(url: root) else { return .skipped(root: root.path) }
+
+        let candidates = listing.entries.filter { $0.kind == .directory && !$0.name.hasPrefix(".") }
+        var tally = ExclusionTally()
+        var folders: [ScannedFolder] = []
+        for (index, entry) in candidates.enumerated() {
+            progress?(index, candidates.count, 0)
+            folders.append(scan(root.appendingPathComponent(entry.name, isDirectory: true), hash: hash, tally: &tally) {
+                progress?(index, candidates.count, $0)
+            })
+        }
+        progress?(candidates.count, candidates.count, 1)
+        return .scanned(CollectionSummary(folders: folders, exclusions: tally))
+    }
+
+    private static func scan(_ folder: URL, hash: Bool, tally: inout ExclusionTally,
+                             progress: (Double) -> Void) -> ScannedFolder {
+        do {
+            guard let detection = try GameDetector.detect(folder: folder, tally: &tally) else {
+                return ScannedFolder(detection: nil)
+            }
+            let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot)
+            let rootListing = try FolderListing(url: root)
+            let hasPlayer = rootListing.file(named: "UnityPlayer.dll") != nil || rootListing.file(named: "UnityPlayer.so") != nil
+            let fingerprint = hash
+                ? try FingerprintBuilder.build(detection: detection, folder: folder, secret: scannerSecret, progress: progress)
+                : nil
+            return ScannedFolder(detection: detection, hasUnityPlayer: hasPlayer,
+                                 declaredID: try EngineDeclaredID.read(detection: detection, folder: folder),
+                                 fingerprint: fingerprint)
+        } catch {
+            return ScannedFolder(detection: nil, failed: true)
+        }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Scan/CollectionSummary.swift b/Packages/EikonCore/Sources/EikonCore/Scan/CollectionSummary.swift
new file mode 100644
index 0000000..22acb16
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Scan/CollectionSummary.swift
@@ -0,0 +1,157 @@
+import Foundation
+
+/// One scanned folder's contribution. Carries no folder name.
+public struct ScannedFolder: Sendable {
+    /// nil when no game was found.
+    public var detection: DetectionResult?
+    /// The game root holds UnityPlayer.dll or UnityPlayer.so.
+    public var hasUnityPlayer: Bool
+    /// In memory only, for blocklist and collision counts; never printed.
+    public var declaredID: EngineDeclaredID.Result?
+    /// Only with --hash, under the scanner secret.
+    public var fingerprint: Fingerprint?
+    /// Detection or a read failed; the folder counts only as an error.
+    public var failed: Bool
+
+    public init(detection: DetectionResult?, hasUnityPlayer: Bool = false, declaredID: EngineDeclaredID.Result? = nil,
+                fingerprint: Fingerprint? = nil, failed: Bool = false) {
+        self.detection = detection
+        self.hasUnityPlayer = hasUnityPlayer
+        self.declaredID = declaredID
+        self.fingerprint = fingerprint
+        self.failed = failed
+    }
+}
+
+/// Aggregate, title-free counts over a scanned collection. Pure.
+///
+/// Output format: one `key: count` line per count, keys dot-separated and lowercase, for
+/// example `engine.unity: 3`. Per-folder lines follow a `per-folder:` line.
+public struct CollectionSummary: Sendable {
+    public let folders: [ScannedFolder]
+    public let exclusions: ExclusionTally
+
+    public init(folders: [ScannedFolder], exclusions: ExclusionTally) {
+        self.folders = folders
+        self.exclusions = exclusions
+    }
+
+    private var games: [DetectionResult] { folders.compactMap(\.detection) }
+
+    public var errorCount: Int { folders.filter(\.failed).count }
+    public var noGameCount: Int { folders.filter { !$0.failed && $0.detection == nil }.count }
+
+    public var engineCounts: [Engine: Int] { tally(games.map(\.engine)) }
+
+    public func count(_ scripting: UnityScripting) -> Int {
+        games.filter { $0.engine == .unity && $0.details.unityScripting == scripting }.count
+    }
+
+    public var unityPlayerCount: Int {
+        folders.filter { $0.detection?.engine == .unity && $0.hasUnityPlayer }.count
+    }
+
+    /// Games whose plugin list holds each base name.
+    public var pluginCounts: [String: Int] { tally(games.flatMap { Set($0.details.pluginFileNames) }) }
+
+    public var nativeExtensionCounts: [String: Int] { tally(games.flatMap { Set($0.details.renpyNativeExtensions) }) }
+
+    /// Main executables of every platform, by architecture.
+    public var architectureCounts: [CPUArchitecture: Int] {
+        tally(games.flatMap { $0.executables.values.map(\.architecture) })
+    }
+
+    /// Main executables named Game.exe (any case), by architecture.
+    public var gameExeArchitectureCounts: [CPUArchitecture: Int] {
+        tally(games.compactMap { game in
+            game.executables[.windows].flatMap {
+                NameNormalizer.normalize(($0.path as NSString).lastPathComponent) == "game.exe" ? $0.architecture : nil
+            }
+        })
+    }
+
+    public var exclusionCounts: [ExclusionRule: Int] { exclusions.hits }
+
+    public var declaredIDCounts: [Engine: Int] {
+        tally(folders.compactMap { folder in
+            guard case .found = folder.declaredID else { return nil }
+            return folder.detection?.engine
+        })
+    }
+
+    public var genericDeclaredIDCount: Int { folders.filter { $0.declaredID == .generic }.count }
+
+    /// Folders whose engine and declared id equal another folder's.
+    public var sharedEngineIDCount: Int {
+        sharedCount(folders.compactMap { folder in
+            guard case .found(let value) = folder.declaredID, let engine = folder.detection?.engine else { return nil }
+            return "\(engine.rawValue):\(value)"
+        })
+    }
+
+    /// Folders whose exact fingerprint equals another folder's (only with --hash).
+    public var sharedExactCount: Int { sharedCount(folders.compactMap { $0.fingerprint?.exact.hex }) }
+
+    public func formatted(perFolder: Bool) -> String {
+        var lines: [String] = []
+        func line(_ key: String, _ value: Int) { lines.append("\(key): \(value)") }
+        func group<Key>(_ prefix: String, _ counts: [Key: Int], name: (Key) -> String) {
+            for (key, value) in counts.map({ (name($0.key), $0.value) }).sorted(by: { $0.0 < $1.0 }) {
+                line("\(prefix).\(key)", value)
+            }
+        }
+
+        line("folders", folders.count)
+        line("errors", errorCount)
+        line("no-game", noGameCount)
+        for engine in Engine.allCases { line("engine.\(engine.rawValue)", engineCounts[engine] ?? 0) }
+        for scripting in UnityScripting.allCases { line("unity.\(scripting.rawValue)", count(scripting)) }
+        line("unity.unityplayer", unityPlayerCount)
+        line("kirikiri.tpm", games.filter { $0.engine == .kirikiri && $0.details.pluginFileNames.contains { $0.lowercased().hasSuffix(".tpm") } }.count)
+        group("kirikiri.flavor", tally(games.compactMap(\.details.kirikiriFlavor))) { $0.rawValue }
+        line("kirikiri.index-readable", games.filter { $0.details.xp3IndexReadable == true }.count)
+        line("kirikiri.protected-flag", games.filter { $0.details.xp3ProtectedFlag == true }.count)
+        group("renpy", tally(games.compactMap(\.details.renpyVersion).map(Self.describe))) { $0 }
+        group("gamemaker", tally(games.compactMap(\.details.gameMakerBuild))) { $0.rawValue }
+        group("arch", architectureCounts) { $0.rawValue }
+        group("arch.game-exe", gameExeArchitectureCounts) { $0.rawValue }
+        group("plugin", pluginCounts) { $0 }
+        group("renpy-native", nativeExtensionCounts) { $0 }
+        group("exclusion", exclusionCounts) { $0.rawValue }
+        group("identity.declared", declaredIDCounts) { $0.rawValue }
+        line("identity.declared-generic", genericDeclaredIDCount)
+        line("identity.engine-id-shared", sharedEngineIDCount)
+        if folders.contains(where: { $0.fingerprint != nil }) { line("identity.exact-shared", sharedExactCount) }
+
+        if perFolder {
+            lines.append("per-folder:")
+            let rows = folders.compactMap { folder -> (exact: String?, engine: String)? in
+                folder.detection.map { (folder.fingerprint.map { String($0.exact.hex.prefix(12)) }, $0.engine.rawValue) }
+            }
+            for row in rows.sorted(by: { ($0.exact ?? "") < ($1.exact ?? "") }) {
+                lines.append(row.exact.map { "\($0) \(row.engine)" } ?? row.engine)
+            }
+        }
+        return lines.joined(separator: "\n") + "\n"
+    }
+
+    /// `version.8.1.3` or `era.7.4-open`.
+    private static func describe(_ version: RenPyVersion) -> String {
+        switch version.kind {
+        case .exact:
+            return "version.\(version.major).\(version.minor)" + (version.patch.map { ".\($0)" } ?? "")
+        case .era:
+            let upper = version.maxMajor.map { "\($0).\(version.maxMinor ?? 0)" } ?? "open"
+            return "era.\(version.major).\(version.minor)-\(upper)"
+        }
+    }
+
+    private func tally<Key: Hashable>(_ keys: some Sequence<Key>) -> [Key: Int] {
+        keys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
+    }
+
+    private func sharedCount(_ keys: [String]) -> Int {
+        let counts = tally(keys)
+        return keys.filter { counts[$0, default: 0] > 1 }.count
+    }
+}
diff --git a/Packages/EikonCore/Sources/eikon-scan/main.swift b/Packages/EikonCore/Sources/eikon-scan/main.swift
index fbaaac1..302332a 100644
--- a/Packages/EikonCore/Sources/eikon-scan/main.swift
+++ b/Packages/EikonCore/Sources/eikon-scan/main.swift
@@ -1,4 +1,44 @@
+import EikonCore
 import Foundation
 
-FileHandle.standardError.write(Data("eikon-scan: not implemented yet (section 04)\n".utf8))
-exit(1)
+// eikon-scan [--root PATH] [--per-folder] [--hash]
+// Prints a title-free aggregate report of a game collection. Read-only.
+
+let usage = "usage: eikon-scan [--root PATH] [--per-folder] [--hash]\n"
+var root = "/Volumes/Games"
+var perFolder = false
+var hash = false
+
+var arguments = CommandLine.arguments.dropFirst()
+while let argument = arguments.popFirst() {
+    switch argument {
+    case "--root":
+        guard let value = arguments.popFirst() else {
+            FileHandle.standardError.write(Data(usage.utf8))
+            exit(2)
+        }
+        root = value
+    case "--per-folder":
+        perFolder = true
+    case "--hash":
+        hash = true
+    default:
+        FileHandle.standardError.write(Data(usage.utf8))
+        exit(2)
+    }
+}
+
+// Progress goes to stderr so stdout stays parseable; hashing over a network share is slow.
+let outcome = CollectionScan.run(root: URL(fileURLWithPath: root, isDirectory: true), hash: hash) { done, total, fraction in
+    guard hash else { return }
+    let percent = Int(fraction * 100)
+    FileHandle.standardError.write(Data("\rfolder \(min(done + 1, total))/\(total) \(percent)%   ".utf8))
+}
+if hash { FileHandle.standardError.write(Data("\n".utf8)) }
+
+switch outcome {
+case .skipped(let path):
+    print("skipped: \(path) not mounted")
+case .scanned(let summary):
+    print(summary.formatted(perFolder: perFolder), terminator: "")
+}
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/ScannerTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/ScannerTests.swift
new file mode 100644
index 0000000..3a79a0b
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/ScannerTests.swift
@@ -0,0 +1,108 @@
+import Foundation
+import Testing
+import EikonCore
+
+// MARK: Fakes
+
+/// One synthesized collection folder and what it was built with.
+private struct Built {
+    let name: String
+    /// Also the wrapper's name when the game sits inside one.
+    let names: [String]
+    let engine: Engine?
+    let il2cpp: Bool
+    let plugins: [String]
+    let architectures: [CPUArchitecture]
+    let gameExe: CPUArchitecture?
+    let excluded: ExclusionRule?
+}
+
+/// A small collection covering every engine, two PE architectures plus an ELF, a wrapper,
+/// a non-game folder and an excluded installer.
+private func buildCollection(in root: URL) throws -> [Built] {
+    var built: [Built] = []
+    _ = try Fixtures.unity(.mono, named: "Alpha", in: root)
+    built.append(Built(name: "Alpha", names: ["Alpha"], engine: .unity, il2cpp: false, plugins: [],
+                       architectures: [.amd64], gameExe: .amd64, excluded: nil))
+
+    let wrapper = root.appendingPathComponent("Bravo")
+    _ = try Fixtures.unity(.il2cpp, named: "BravoInner", in: wrapper)
+    built.append(Built(name: "Bravo", names: ["Bravo", "BravoInner"], engine: .unity, il2cpp: true, plugins: [],
+                       architectures: [.amd64], gameExe: .amd64, excluded: nil))
+
+    let kirikiri = try Fixtures.kirikiri(flavor: nil, tpm: ["extrans.tpm"], named: "Charlie", in: root)
+    try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "unins000.exe", in: kirikiri)
+    built.append(Built(name: "Charlie", names: ["Charlie"], engine: .kirikiri, il2cpp: false, plugins: ["extrans.tpm"],
+                       architectures: [.i386], gameExe: .i386, excluded: .unins))
+
+    _ = try Fixtures.renpy(.scriptVersion, named: "Delta", in: root)
+    built.append(Built(name: "Delta", names: ["Delta"], engine: .renpy, il2cpp: false, plugins: [],
+                       architectures: [.amd64, .amd64], gameExe: .amd64, excluded: nil))
+
+    let gameMaker = root.appendingPathComponent("Echo")
+    try Fixtures.write(Fixtures.gameMaker(hasCode: true), to: "data.win", in: gameMaker)
+    try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Runner.exe", in: gameMaker)
+    built.append(Built(name: "Echo", names: ["Echo"], engine: .gameMaker, il2cpp: false, plugins: [],
+                       architectures: [.i386], gameExe: nil, excluded: nil))
+
+    try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Foxtrot/BGI.exe", in: root)
+    built.append(Built(name: "Foxtrot", names: ["Foxtrot"], engine: .bgi, il2cpp: false, plugins: [],
+                       architectures: [.i386], gameExe: nil, excluded: nil))
+
+    try Fixtures.write("notes", to: "Golf/readme.txt", in: root)
+    built.append(Built(name: "Golf", names: ["Golf"], engine: nil, il2cpp: false, plugins: [],
+                       architectures: [], gameExe: nil, excluded: nil))
+    return built
+}
+
+private func scanned(_ root: URL, hash: Bool = false) throws -> CollectionSummary {
+    guard case .scanned(let summary) = CollectionScan.run(root: root, hash: hash) else {
+        throw ScanTestError.skipped
+    }
+    return summary
+}
+
+private enum ScanTestError: Error { case skipped }
+
+private func counts<Key: Hashable>(_ keys: [Key]) -> [Key: Int] {
+    keys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
+}
+
+// MARK: Tests
+
+@Test func summaryCountsMatchSynthesizedCollection() throws {
+    let root = try Fixtures.tempDir()
+    defer { try? FileManager.default.removeItem(at: root) }
+    let built = try buildCollection(in: root)
+    let summary = try scanned(root)
+
+    #expect(summary.folders.count == built.count)
+    #expect(summary.engineCounts == counts(built.compactMap(\.engine)))
+    #expect(summary.count(.il2cpp) == built.filter(\.il2cpp).count)
+    #expect(summary.pluginCounts == counts(built.flatMap(\.plugins)))
+    #expect(summary.architectureCounts == counts(built.flatMap(\.architectures)))
+    #expect(summary.gameExeArchitectureCounts == counts(built.compactMap(\.gameExe)))
+    #expect(summary.noGameCount == built.filter { $0.engine == nil }.count)
+    for rule in built.compactMap(\.excluded) {
+        #expect(summary.exclusionCounts[rule, default: 0] > 0)
+    }
+}
+
+@Test func formattedOutputContainsNoFolderNames() throws {
+    let root = try Fixtures.tempDir()
+    defer { try? FileManager.default.removeItem(at: root) }
+    let built = try buildCollection(in: root)
+    let output = try scanned(root, hash: true).formatted(perFolder: true)
+
+    for name in built.flatMap(\.names) {
+        #expect(!output.contains(name))
+    }
+}
+
+@Test func missingRootIsSkipped() throws {
+    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("eikon-missing-\(UUID().uuidString)")
+    guard case .skipped = CollectionScan.run(root: missing, hash: false) else {
+        Issue.record("expected the skipped outcome")
+        return
+    }
+}
diff --git a/tests/test_collection_scan.py b/tests/test_collection_scan.py
new file mode 100644
index 0000000..4404284
--- /dev/null
+++ b/tests/test_collection_scan.py
@@ -0,0 +1,62 @@
+"""Opt-in check of the collection scanner against the owner's game share.
+
+Runs only with the share mounted and EIKON_SCAN_COLLECTION=1. The expected counts
+come from the requirements table at run time; no counts or titles live here.
+"""
+
+from __future__ import annotations
+
+import os
+import re
+import subprocess
+from pathlib import Path
+
+import pytest
+
+REPO_ROOT = Path(__file__).resolve().parent.parent
+SHARE = Path("/Volumes/Games")
+
+pytestmark = pytest.mark.skipif(
+    not (SHARE.is_dir() and os.environ.get("EIKON_SCAN_COLLECTION") == "1"),
+    reason="needs /Volumes/Games mounted and EIKON_SCAN_COLLECTION=1",
+)
+
+# Requirements-table engine names to the scanner's engine keys.
+ENGINE_KEYS = {
+    "Unity": "unity",
+    "Kirikiri": "kirikiri",
+    "Ren'Py": "renpy",
+    "GameMaker": "gameMaker",
+    "BGI": "bgi",
+}
+
+
+def table_counts() -> dict[str, int]:
+    """Engine key -> folder count from the 'Games to support' table."""
+    text = (REPO_ROOT / "planning" / "requirements.md").read_text(encoding="utf-8")
+    section = text.split("## Games to support, in priority order", 1)[1]
+    counts: dict[str, int] = {}
+    for line in section.splitlines():
+        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
+        if len(cells) >= 2 and cells[0] in ENGINE_KEYS and cells[1].isdigit():
+            counts[ENGINE_KEYS[cells[0]]] = int(cells[1])
+        if line.startswith("## ") and counts:
+            break
+    return counts
+
+
+def scanner_counts() -> dict[str, int]:
+    """Engine key -> count from the scanner's `engine.<key>: <n>` lines."""
+    result = subprocess.run(
+        ["swift", "run", "--package-path", "Packages/EikonCore", "-c", "release",
+         "eikon-scan", "--root", str(SHARE)],
+        cwd=REPO_ROOT, check=True, capture_output=True, text=True,
+    )
+    return {match[1]: int(match[2]) for match in re.finditer(r"^engine\.(\w+): (\d+)$", result.stdout, re.M)}
+
+
+def test_engine_counts_match_requirements_table() -> None:
+    expected = table_counts()
+    assert expected, "no engine rows parsed from the requirements table"
+    actual = scanner_counts()
+    assert {key: actual.get(key, 0) for key in expected} == expected

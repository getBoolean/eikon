diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/FolderListing.swift b/Packages/EikonCore/Sources/EikonCore/Detection/FolderListing.swift
index 9891429..147338a 100644
--- a/Packages/EikonCore/Sources/EikonCore/Detection/FolderListing.swift
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/FolderListing.swift
@@ -11,7 +11,7 @@ public struct FolderListing: Sendable {
     public struct Entry: Sendable, Equatable {
         /// The name as listed.
         public let name: String
-        /// `FolderListing.normalize(name)`.
+        /// `NameNormalizer.normalize(name)`.
         public let key: String
         public let kind: Kind
         public let size: UInt64
@@ -57,7 +57,7 @@ public struct FolderListing: Sendable {
                 continue
             }
             let name = child.lastPathComponent
-            entries.append(Entry(name: name, key: Self.normalize(name), kind: kind,
+            entries.append(Entry(name: name, key: NameNormalizer.normalize(name), kind: kind,
                                  size: UInt64(max(values.fileSize ?? 0, 0))))
         }
         self.url = url
@@ -67,21 +67,14 @@ public struct FolderListing: Sendable {
         }
     }
 
-    /// NFC plus case folding, and nothing else. NFC again after folding, which can
-    /// decompose, so a key normalizes to itself.
-    public static func normalize(_ name: String) -> String {
-        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
-            .precomposedStringWithCanonicalMapping
-    }
-
     /// Case- and normalization-insensitive exact lookup of any kind except symlink.
     public func entry(named name: String) -> Entry? {
-        let key = Self.normalize(name)
+        let key = NameNormalizer.normalize(name)
         return entries.first { $0.key == key && $0.kind != .symlink }
     }
 
     public func file(named name: String) -> Entry? {
-        file(key: Self.normalize(name))
+        file(key: NameNormalizer.normalize(name))
     }
 
     /// Lookup by an already-normalized key.
@@ -95,7 +88,7 @@ public struct FolderListing: Sendable {
 
     /// Regular files with this extension (no dot), in sorted order.
     public func files(withExtension ext: String) -> [Entry] {
-        let ext = Self.normalize(ext)
+        let ext = NameNormalizer.normalize(ext)
         return entries.filter { $0.kind == .file && $0.pathExtension == ext }
     }
 
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/FolderReader.swift b/Packages/EikonCore/Sources/EikonCore/Detection/FolderReader.swift
index 7ea837c..0227a36 100644
--- a/Packages/EikonCore/Sources/EikonCore/Detection/FolderReader.swift
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/FolderReader.swift
@@ -3,7 +3,7 @@ import Darwin
 import Foundation
 
 enum ReadPurpose: Sendable, Hashable {
-    case binaryHeaders, versionResource, xp3Index, chunkHeaders, smallText
+    case binaryHeaders, versionResource, xp3Index, chunkHeaders, smallText, gen8Strings, keyFileSample
 
     /// Bytes allowed per file, per call and in total.
     var budget: Int {
@@ -13,6 +13,8 @@ enum ReadPurpose: Sendable, Hashable {
         case .xp3Index: (8 << 20) + (4 << 10) // the compressed index plus its small headers
         case .chunkHeaders: 8 * 512
         case .smallText: 64 << 10
+        case .gen8Strings: 4 << 10
+        case .keyFileSample: 2 << 20 // the first and the last MiB
         }
     }
 }
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift
index f4ce25d..b15eacf 100644
--- a/Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift
@@ -11,7 +11,7 @@ struct EngineMatch {
 /// never logs, and deterministic regardless of directory listing order.
 public enum GameDetector {
     /// Bump whenever detection logic changes; stored results with an older version are recomputed.
-    public static let version = 1
+    public static let version = 2
 
     /// Detects the game in a game folder (an immediate child of a game drive). Checks the
     /// folder itself; if no engine markers or executable are there and the folder holds
@@ -50,7 +50,9 @@ public enum GameDetector {
         if match?.engine == .kirikiri, let exe = executables[.windows] {
             details.kirikiriFlavor = KirikiriDetector.flavor(reader, executable: exe.path)
         }
-        return DetectionResult(engine: match?.engine ?? .unknown, details: details, gameRoot: "",
-                               executables: executables, keyFile: nil, detectorVersion: version)
+        let engine = match?.engine ?? .unknown
+        return DetectionResult(engine: engine, details: details, gameRoot: "", executables: executables,
+                               keyFile: KeyFile.locate(engine: engine, executables: executables, listing: listing),
+                               detectorVersion: version)
     }
 }
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/GameMakerDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/GameMakerDetector.swift
index e2c479c..f9ee1ac 100644
--- a/Packages/EikonCore/Sources/EikonCore/Detection/GameMakerDetector.swift
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/GameMakerDetector.swift
@@ -2,27 +2,56 @@ import Foundation
 
 enum GameMakerDetector {
     static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
+        guard let file = dataFile(listing, reader) else { return nil }
+        let hasCode = chunk("CODE", reader, path: file.name).map { $0.size > 0 } ?? false
+        return EngineMatch(engine: .gameMaker, details: EngineDetails(gameMakerBuild: hasCode ? .vm : .yyc))
+    }
+
+    /// data.win or game.unx, when it starts with FORM and a GEN8 chunk.
+    static func dataFile(_ listing: FolderListing, _ reader: FolderReader) -> FolderListing.Entry? {
         for name in ["data.win", "game.unx"] {
             guard let file = listing.file(named: name),
                   let header = try? reader.read(file.name, offset: 0, length: 12, for: .chunkHeaders),
                   header.hasBytes(Array("FORM".utf8)), header.hasBytes(Array("GEN8".utf8), at: 8) else { continue }
-            return EngineMatch(engine: .gameMaker,
-                               details: EngineDetails(gameMakerBuild: hasCode(reader, path: file.name) ? .vm : .yyc))
+            return file
         }
         return nil
     }
 
-    /// Walks the 8-byte chunk headers from offset 8. A present, non-empty CODE chunk means
-    /// VM; stops at the end, at a size that overruns the file, or when the budget runs out.
-    private static func hasCode(_ reader: FolderReader, path: String) -> Bool {
-        guard let fileSize = reader.size(of: path) else { return false }
+    /// Walks the 8-byte chunk headers from offset 8 to the chunk with this tag: its content
+    /// offset and size. Stops at the end, at a size that overruns the file, or when the budget runs out.
+    static func chunk(_ tag: String, _ reader: FolderReader, path: String) -> (offset: UInt64, size: UInt32)? {
+        guard let fileSize = reader.size(of: path) else { return nil }
         var offset: UInt64 = 8
         while offset + 8 <= fileSize,
               let header = try? reader.read(path, offset: offset, length: 8, for: .chunkHeaders),
               let size = header.uint32LE(at: 4) {
-            if header.hasBytes(Array("CODE".utf8)) { return size > 0 }
+            if header.hasBytes(Array(tag.utf8)) { return (offset + 8, size) }
             offset += 8 + UInt64(size)
         }
-        return false
+        return nil
+    }
+
+    /// GEN8's Name and DisplayName strings. Both are STRG pointers: the absolute offset of
+    /// the string bytes, which follow a 32-bit length.
+    static func declaredNames(_ reader: FolderReader, path: String) -> [String] {
+        guard let gen8 = chunk("GEN8", reader, path: path), gen8.size >= displayNameField + 4,
+              let fields = try? reader.read(path, offset: gen8.offset, length: displayNameField + 4, for: .gen8Strings)
+        else { return [] }
+        return [nameField, displayNameField].compactMap { field in
+            fields.uint32LE(at: field).flatMap { string(reader, path: path, at: UInt64($0)) }
+        }
+    }
+
+    private static let nameField = 40
+    private static let displayNameField = 100
+    private static let maxStringLength: UInt32 = 1024
+
+    private static func string(_ reader: FolderReader, path: String, at offset: UInt64) -> String? {
+        guard offset >= 4, let length = (try? reader.read(path, offset: offset - 4, length: 4, for: .gen8Strings))?
+                .uint32LE(at: 0), length > 0, length <= maxStringLength,
+              let bytes = try? reader.read(path, offset: offset, length: Int(length), for: .gen8Strings),
+              bytes.count == Int(length) else { return nil }
+        return String(data: bytes, encoding: .utf8)
     }
 }
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/EngineDeclaredID.swift b/Packages/EikonCore/Sources/EikonCore/Identity/EngineDeclaredID.swift
new file mode 100644
index 0000000..a31204d
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/EngineDeclaredID.swift
@@ -0,0 +1,80 @@
+import Foundation
+
+/// The identity a game's engine uses for its own saves: the signal most likely to survive
+/// a patch. The plain value lives only in memory; fingerprints store it keyed.
+public enum EngineDeclaredID {
+    public enum Result: Sendable, Equatable {
+        case found(String)
+        /// Values were present but every one was an engine's generic default.
+        case generic
+        case absent
+    }
+
+    /// Engine and toolchain defaults that say nothing about the game, normalized.
+    /// Scanner data extends this table.
+    static let genericValues: Set<String> = Set([
+        "TVP(KIRIKIRI)", "TVP(KIRIKIRI) 2", "TVP(KIRIKIRI) Z", "KIRIKIRI", "KIRIKIRI Z",
+        "Unity", "Unity Technologies ApS", "DefaultCompany", "My project",
+        "Ren'Py", "RenPy", "Python", "YoYo Games Ltd", "GameMaker", "Created with GameMaker Studio 2",
+    ].map(NameNormalizer.normalize))
+
+    /// The engine-specific source (Ren'Py, Unity, GameMaker) wins; otherwise the main
+    /// Windows executable's CompanyName and ProductName.
+    public static func read(detection: DetectionResult, folder: URL) throws -> Result {
+        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
+        let listing = try FolderListing(url: root)
+        return read(detection: detection, listing: listing, reader: FolderReader(root: root))
+    }
+
+    static func read(detection: DetectionResult, listing: FolderListing, reader: FolderReader) -> Result {
+        let engineSpecific: Result
+        switch detection.engine {
+        case .renpy: engineSpecific = classify([renpySaveDirectory(listing, reader)])
+        case .unity: engineSpecific = classify(unityAppInfo(listing, reader, executables: detection.executables))
+        case .gameMaker:
+            engineSpecific = classify(GameMakerDetector.dataFile(listing, reader)
+                .map { GameMakerDetector.declaredNames(reader, path: $0.name) } ?? [])
+        case .kirikiri, .bgi, .unknown: engineSpecific = .absent
+        }
+        if case .found = engineSpecific { return engineSpecific }
+
+        let versionInfo = detection.executables[.windows].map { exe -> Result in
+            let strings = PEVersionResource.strings(reader, path: exe.path)
+            return classify([strings["CompanyName"], strings["ProductName"]])
+        } ?? .absent
+        if case .found = versionInfo { return versionInfo }
+        return engineSpecific == .generic || versionInfo == .generic ? .generic : .absent
+    }
+
+    /// Present parts minus generic ones, joined; `.generic` when only generic parts remain.
+    static func classify(_ parts: [String?]) -> Result {
+        let present = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
+        guard !present.isEmpty else { return .absent }
+        let kept = present.filter { !genericValues.contains(NameNormalizer.normalize($0)) }
+        return kept.isEmpty ? .generic : .found(kept.joined(separator: "\n"))
+    }
+
+    // MARK: Sources
+
+    private static let saveDirectoryPattern = try? NSRegularExpression(
+        pattern: #"(?m)^\s*(?:define\s+)?config\.save_directory\s*=\s*[rRuU]?(["'])(.*?)\1"#)
+
+    /// The quoted string assigned to `config.save_directory` in game/options.rpy.
+    private static func renpySaveDirectory(_ listing: FolderListing, _ reader: FolderReader) -> String? {
+        guard let game = listing.directory(named: "game"), let contents = try? listing.listing(of: game),
+              let options = contents.file(named: "options.rpy"),
+              let text = reader.text("\(game.name)/\(options.name)"), let pattern = saveDirectoryPattern,
+              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
+              let value = Range(match.range(at: 2), in: text) else { return nil }
+        return String(text[value])
+    }
+
+    /// Company and product: the first two lines of `<stem>_Data/app.info`.
+    private static func unityAppInfo(_ listing: FolderListing, _ reader: FolderReader,
+                                     executables: [GamePlatform: ExecutableInfo]) -> [String?] {
+        guard let dataDir = KeyFile.unityDataDirectory(listing, executables: executables),
+              let contents = try? listing.listing(of: dataDir), let appInfo = contents.file(named: "app.info"),
+              let text = reader.text("\(dataDir.name)/\(appInfo.name)") else { return [] }
+        return text.split(whereSeparator: \.isNewline).prefix(2).map(String.init)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/FileHasher.swift b/Packages/EikonCore/Sources/EikonCore/Identity/FileHasher.swift
new file mode 100644
index 0000000..a65187b
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/FileHasher.swift
@@ -0,0 +1,38 @@
+import CryptoKit
+import Darwin
+import Foundation
+
+/// Full-file SHA-256 for diagnostics ("Verify files", the scanner's --hash). Never part of identity.
+public enum FileHasher {
+    public static let chunkSize = 1 << 20
+
+    /// Lowercase hex. Streams read-only in `chunkSize` chunks, reporting non-decreasing
+    /// progress in 0...1; throws `CancellationError` once `isCancelled` is true between chunks.
+    public static func sha256(of url: URL, progress: (Double) -> Void, isCancelled: () -> Bool) throws -> String {
+        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
+        guard fd >= 0 else { throw IdentityError.fileUnreadable }
+        defer { close(fd) }
+        var info = stat()
+        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw IdentityError.fileUnreadable }
+        let total = UInt64(info.st_size)
+
+        var hasher = SHA256()
+        var buffer = [UInt8](repeating: 0, count: chunkSize)
+        var done: UInt64 = 0
+        progress(0)
+        while true {
+            if isCancelled() { throw CancellationError() }
+            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, chunkSize) }
+            if got < 0 {
+                if errno == EINTR { continue }
+                throw IdentityError.fileUnreadable
+            }
+            if got == 0 { break }
+            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<got])) }
+            done += UInt64(got)
+            progress(total == 0 ? 1 : min(1, Double(done) / Double(total)))
+        }
+        progress(1)
+        return Data(hasher.finalize()).lowercaseHex
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/FingerprintBuilder.swift b/Packages/EikonCore/Sources/EikonCore/Identity/FingerprintBuilder.swift
new file mode 100644
index 0000000..7ad24a7
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/FingerprintBuilder.swift
@@ -0,0 +1,87 @@
+import CryptoKit
+import Foundation
+
+/// Turns a detected game's signals into a keyed `Fingerprint`. Reads a listing, a few
+/// small files and at most 2 MiB of the key file, read-only; never hashes whole files.
+/// Every signal comes from the game root's contents, never the game folder's own name.
+public enum FingerprintBuilder {
+    public static let maxNames = 256
+
+    /// Top-level names too common to say anything about a game, normalized.
+    static let genericNames: Set<String> = ["data", "save", "savedata", "plugin", "lib", "game", "renpy"]
+    static let genericLibraries: Set<String> = [
+        "unityplayer.dll", "unityplayer.so", "gameassembly.dll", "gameassembly.so", "d3dcompiler_47.dll",
+        "d3dx9_43.dll", "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcr100.dll", "msvcp100.dll",
+        "msvcr120.dll", "msvcp120.dll", "openal32.dll", "steam_api.dll", "steam_api64.dll", "python27.dll",
+        "libogg-0.dll", "libvorbis-0.dll", "sdl2.dll", "zlib1.dll", "baselib.dll", "winpixeventruntime.dll",
+    ]
+
+    private static let sampleLength = 1 << 20
+
+    public static func build(detection: DetectionResult, folder: URL, secret: LibrarySecret) throws -> Fingerprint {
+        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
+        let listing = try FolderListing(url: root)
+        let reader = FolderReader(root: root)
+
+        let engineID: Keyed?
+        if case .found(let value) = EngineDeclaredID.read(detection: detection, listing: listing, reader: reader) {
+            engineID = keyed(secret, Data("\(detection.engine.rawValue):\(value)".utf8))
+        } else {
+            engineID = nil
+        }
+        return Fingerprint(engineID: engineID,
+                           exact: keyed(secret, exactBytes(listing, reader, keyFile: detection.keyFile)),
+                           names: names(listing, secret: secret))
+    }
+
+    /// Length-prefixed entries in normalized-name order (kind, name, size for files), then
+    /// the key file's size and the SHA-256 of its first and last MiB.
+    private static func exactBytes(_ listing: FolderListing, _ reader: FolderReader, keyFile: String?) -> Data {
+        var bytes = Data()
+        for entry in listing.entries {
+            switch entry.kind {
+            case .file:
+                bytes.append(UInt8(ascii: "f"))
+                appendField(Data(entry.key.utf8), to: &bytes)
+                appendInteger(entry.size, to: &bytes)
+            case .directory:
+                bytes.append(UInt8(ascii: "d"))
+                appendField(Data(entry.key.utf8), to: &bytes)
+            case .symlink:
+                bytes.append(UInt8(ascii: "l"))
+                appendField(Data(entry.key.utf8), to: &bytes)
+            }
+        }
+        if let keyFile, let size = reader.size(of: keyFile),
+           let head = try? reader.read(keyFile, offset: 0, length: sampleLength, for: .keyFileSample),
+           let tail = try? reader.read(keyFile, offset: size - min(size, UInt64(sampleLength)),
+                                       length: sampleLength, for: .keyFileSample) {
+            bytes.append(UInt8(ascii: "k"))
+            appendInteger(size, to: &bytes)
+            bytes.append(contentsOf: SHA256.hash(data: head))
+            bytes.append(contentsOf: SHA256.hash(data: tail))
+        }
+        return bytes
+    }
+
+    private static func names(_ listing: FolderListing, secret: LibrarySecret) -> [Keyed8] {
+        let keys = Set(listing.entries.map(\.key).filter { key in
+            !genericNames.contains(key) && !genericLibraries.contains(key) && !key.hasSuffix("_data")
+        })
+        let digests = Set(keys.map { Keyed8(hex: secret.mac(Data($0.utf8)).prefix(8).lowercaseHex) })
+        return Array(digests.sorted().prefix(maxNames))
+    }
+
+    private static func keyed(_ secret: LibrarySecret, _ message: Data) -> Keyed {
+        Keyed(hex: secret.mac(message).lowercaseHex)
+    }
+
+    private static func appendField(_ field: Data, to bytes: inout Data) {
+        appendInteger(UInt64(field.count), to: &bytes)
+        bytes.append(field)
+    }
+
+    private static func appendInteger(_ value: UInt64, to bytes: inout Data) {
+        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/GameIdentity.swift b/Packages/EikonCore/Sources/EikonCore/Identity/GameIdentity.swift
new file mode 100644
index 0000000..6a68510
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/GameIdentity.swift
@@ -0,0 +1,131 @@
+import CryptoKit
+import Foundation
+
+/// A game's identity: a random UUID, minted once. It never encodes anything about the game.
+public struct GameID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
+    public let uuid: UUID
+
+    public init(uuid: UUID) {
+        self.uuid = uuid
+    }
+
+    public static func random() -> GameID {
+        GameID(uuid: UUID())
+    }
+
+    /// The first 8 characters of the lowercase UUID; safe in crash reports since the id is random.
+    public var reportID: String {
+        String(lowercased.prefix(8))
+    }
+
+    public var description: String { lowercased }
+
+    /// Deterministic ordering by the lowercase UUID string.
+    public static func < (lhs: GameID, rhs: GameID) -> Bool {
+        lhs.lowercased < rhs.lowercased
+    }
+
+    private var lowercased: String { uuid.uuidString.lowercased() }
+
+    /// Coded as the bare UUID string.
+    public init(from decoder: any Decoder) throws {
+        uuid = try decoder.singleValueContainer().decode(UUID.self)
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var container = encoder.singleValueContainer()
+        try container.encode(uuid)
+    }
+}
+
+/// An HMAC-SHA256 under the library secret, as 64 lowercase hex characters.
+public struct Keyed: Hashable, Codable, Sendable {
+    public let hex: String
+
+    public init(hex: String) {
+        self.hex = hex
+    }
+}
+
+/// An HMAC-SHA256 under the library secret truncated to 8 bytes (16 hex characters).
+public struct Keyed8: Hashable, Codable, Sendable, Comparable {
+    public let hex: String
+
+    public init(hex: String) {
+        self.hex = hex
+    }
+
+    public static func < (lhs: Keyed8, rhs: Keyed8) -> Bool { lhs.hex < rhs.hex }
+}
+
+/// A game's content fingerprint. Holds keyed values only, never plain names or ids.
+public struct Fingerprint: Codable, Sendable, Equatable {
+    /// Bump to change how fingerprints are computed; only equal schemes are compared.
+    public static let currentScheme = 1
+    /// Fingerprints kept per game: one per distinct build seen, most recent kept.
+    public static let maxPerGame = 8
+
+    public var scheme: Int
+    /// The engine-declared identity, keyed.
+    public var engineID: Keyed?
+    /// The root listing with sizes plus the key file's partial hash, keyed.
+    public var exact: Keyed
+    /// Keyed digests of the game root's non-generic top-level names, sorted.
+    public var names: [Keyed8]
+
+    public init(scheme: Int = Fingerprint.currentScheme, engineID: Keyed?, exact: Keyed, names: [Keyed8]) {
+        self.scheme = scheme
+        self.engineID = engineID
+        self.exact = exact
+        self.names = names
+    }
+}
+
+/// The per-library key for fingerprints. Never logged or exported.
+public struct LibrarySecret: Sendable, CustomStringConvertible {
+    public static let byteCount = 32
+
+    private let bytes: Data
+
+    public init(bytes: Data) {
+        self.bytes = bytes
+    }
+
+    /// Reads the secret at `url`, creating it (atomically, once) when there is none.
+    public static func loadOrCreate(at url: URL) throws -> LibrarySecret {
+        if !FileManager.default.fileExists(atPath: url.path) {
+            var bytes = Data(count: byteCount)
+            let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
+            guard status == errSecSuccess else { throw IdentityError.secretUnavailable }
+            do {
+                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
+                                                        withIntermediateDirectories: true)
+                try bytes.write(to: url, options: .atomic)
+            } catch {
+                throw IdentityError.secretUnavailable
+            }
+        }
+        guard let bytes = try? Data(contentsOf: url), bytes.count == byteCount else {
+            throw IdentityError.secretUnavailable
+        }
+        return LibrarySecret(bytes: bytes)
+    }
+
+    public var description: String { "LibrarySecret(redacted)" }
+
+    func mac(_ message: Data) -> Data {
+        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: bytes)))
+    }
+}
+
+/// Errors carry codes only: never a path, a name or a secret.
+public enum IdentityError: Error, Sendable, Equatable {
+    case secretUnavailable
+    case fileUnreadable
+}
+
+extension Data {
+    var lowercaseHex: String {
+        map { String(format: "%02x", $0) }.joined()
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/IdentityLedger.swift b/Packages/EikonCore/Sources/EikonCore/Identity/IdentityLedger.swift
new file mode 100644
index 0000000..106a18f
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/IdentityLedger.swift
@@ -0,0 +1,49 @@
+import Foundation
+
+/// Identity state in memory: what merge and split change. The library applies the same
+/// operations to the settings store; tests use it directly.
+public struct IdentityLedger<Setting: Sendable & Equatable>: Sendable, Equatable {
+    public var fingerprints: [GameID: [Fingerprint]]
+    /// Location id → game id.
+    public var locations: [UUID: GameID]
+    public var settings: [GameID: [String: Setting]]
+    /// Merged game → the game it merged into.
+    public var links: [GameID: GameID]
+
+    public init(fingerprints: [GameID: [Fingerprint]] = [:], locations: [UUID: GameID] = [:],
+                settings: [GameID: [String: Setting]] = [:], links: [GameID: GameID] = [:]) {
+        self.fingerprints = fingerprints
+        self.locations = locations
+        self.settings = settings
+        self.links = links
+    }
+
+    /// `a` becomes an alias of `b`: B keeps its own settings and gains A's others, A's
+    /// fingerprints and locations move to B.
+    public mutating func merge(_ a: GameID, into b: GameID) {
+        let target = IdentityMatcher.resolve(b, links: links)
+        guard a != target else { return }
+        links[a] = target
+        settings[target, default: [:]].merge(settings[a] ?? [:]) { own, _ in own }
+        for fingerprint in fingerprints[a] ?? [] {
+            fingerprints[target] = IdentityMatcher.adding(fingerprint, to: fingerprints[target] ?? [])
+        }
+        fingerprints[a] = []
+        for (location, game) in locations where game == a {
+            locations[location] = target
+        }
+    }
+
+    /// Gives `location` a new game holding an independent copy of its old game's settings
+    /// and the location's own fingerprint. Returns the new id.
+    public mutating func split(location: UUID, fingerprint: Fingerprint, mint: () -> GameID = GameID.random) -> GameID {
+        let id = mint()
+        if let old = locations[location] {
+            settings[id] = settings[old] ?? [:]
+            fingerprints[old]?.removeAll { $0.exact == fingerprint.exact }
+        }
+        fingerprints[id] = [fingerprint]
+        locations[location] = id
+        return id
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/IdentityMatcher.swift b/Packages/EikonCore/Sources/EikonCore/Identity/IdentityMatcher.swift
new file mode 100644
index 0000000..df801dc
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/IdentityMatcher.swift
@@ -0,0 +1,110 @@
+import Foundation
+
+/// A game the matcher may attach a new fingerprint to.
+public struct KnownGame: Sendable, Equatable {
+    public var id: GameID
+    /// Oldest to newest, at most `Fingerprint.maxPerGame`.
+    public var fingerprints: [Fingerprint]
+    /// A present (not missing) location on this device.
+    public var hasLiveLocationHere: Bool
+    /// `deletedAt` is set: never a candidate.
+    public var isDeleted: Bool
+
+    public init(id: GameID, fingerprints: [Fingerprint], hasLiveLocationHere: Bool, isDeleted: Bool = false) {
+        self.id = id
+        self.fingerprints = fingerprints
+        self.hasLiveLocationHere = hasLiveLocationHere
+        self.isDeleted = isDeleted
+    }
+}
+
+/// A game folder's place: its drive and normalized folder name.
+public struct LocationKey: Hashable, Sendable {
+    public var driveID: UUID
+    public var folderName: String
+
+    public init(driveID: UUID, folderName: String) {
+        self.driveID = driveID
+        self.folderName = NameNormalizer.normalize(folderName)
+    }
+}
+
+public enum MatchRule: String, Sendable, Equatable {
+    case exact, engineID, nameSimilarity
+}
+
+public enum MatchResult: Sendable, Equatable {
+    /// Rule 1: a known location keeps its game, whatever changed inside. Add the fingerprint.
+    case keep(GameID)
+    /// Rules 2–4: attach to this game and add the fingerprint.
+    case attach(GameID, MatchRule)
+    /// Rule 5: a new game; `suggestions` are possible same-game matches, possibly none.
+    case newGame(GameID, suggestions: [GameID])
+}
+
+/// Finds a game folder's identity. Pure: callers apply the result.
+public enum IdentityMatcher {
+    public static let nameSimilarityThreshold = 0.8
+    public static let maxLinkHops = 4
+
+    public static func match(fingerprint: Fingerprint, at location: LocationKey,
+                             knownLocations: [LocationKey: GameID], games: [KnownGame],
+                             mint: () -> GameID = GameID.random) -> MatchResult {
+        if let id = knownLocations[location], !games.contains(where: { $0.id == id && $0.isDeleted }) {
+            return .keep(id)
+        }
+        let candidates = games.filter { !$0.isDeleted }
+        func comparable(_ game: KnownGame) -> [Fingerprint] {
+            game.fingerprints.filter { $0.scheme == fingerprint.scheme }
+        }
+        func newGame(_ suggestions: [KnownGame]) -> MatchResult {
+            .newGame(mint(), suggestions: suggestions.map(\.id).sorted())
+        }
+
+        let exact = candidates.filter { comparable($0).contains { $0.exact == fingerprint.exact } }
+        if exact.count == 1 { return .attach(exact[0].id, .exact) }
+        if exact.count > 1 { return newGame(exact) }
+
+        let similar: [KnownGame]
+        let rule: MatchRule
+        if let engineID = fingerprint.engineID {
+            similar = candidates.filter { comparable($0).contains { $0.engineID == engineID } }
+            rule = .engineID
+        } else {
+            similar = candidates.filter { game in
+                comparable(game).contains { $0.engineID == nil && jaccard($0.names, fingerprint.names) >= nameSimilarityThreshold }
+            }
+            rule = .nameSimilarity
+        }
+        if similar.count == 1 {
+            return similar[0].hasLiveLocationHere ? newGame(similar) : .attach(similar[0].id, rule)
+        }
+        return newGame(similar)
+    }
+
+    /// `list` with `fingerprint` as its newest entry: an equal `exact` moves to newest
+    /// instead of repeating, and only the newest `Fingerprint.maxPerGame` stay.
+    public static func adding(_ fingerprint: Fingerprint, to list: [Fingerprint]) -> [Fingerprint] {
+        let updated = list.filter { $0.exact != fingerprint.exact } + [fingerprint]
+        return Array(updated.suffix(Fingerprint.maxPerGame))
+    }
+
+    /// Follows merge links (merged game → game it merged into) for at most `maxLinkHops`.
+    /// A cycle resolves to its lowest member, so every member resolves alike.
+    public static func resolve(_ id: GameID, links: [GameID: GameID]) -> GameID {
+        var path = [id]
+        for _ in 0..<maxLinkHops {
+            guard let next = links[path[path.count - 1]] else { break }
+            if let repeated = path.firstIndex(of: next) { return path[repeated...].min()! }
+            path.append(next)
+        }
+        return path[path.count - 1]
+    }
+
+    /// |A∩B| / |A∪B|; two empty sets share nothing.
+    static func jaccard(_ lhs: [Keyed8], _ rhs: [Keyed8]) -> Double {
+        let lhs = Set(lhs), rhs = Set(rhs)
+        let union = lhs.union(rhs).count
+        return union == 0 ? 0 : Double(lhs.intersection(rhs).count) / Double(union)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/KeyFile.swift b/Packages/EikonCore/Sources/EikonCore/Identity/KeyFile.swift
new file mode 100644
index 0000000..b85d38b
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/KeyFile.swift
@@ -0,0 +1,66 @@
+import Foundation
+
+/// The game-specific file whose size and partial hash go into the exact signal: per
+/// engine, the first candidate that exists. Launchers and engine players never qualify.
+public enum KeyFile {
+    /// A path relative to the game root, or nil when the engine's candidates are all absent.
+    public static func locate(engine: Engine, executables: [GamePlatform: ExecutableInfo], root: URL) throws -> String? {
+        locate(engine: engine, executables: executables, listing: try FolderListing(url: root))
+    }
+
+    static func locate(engine: Engine, executables: [GamePlatform: ExecutableInfo], listing: FolderListing) -> String? {
+        let mainExe = mainExecutable(executables)
+        switch engine {
+        case .kirikiri:
+            if let data = listing.file(named: "data.xp3") { return data.name }
+            if let largest = largest(listing.files(withExtension: "xp3")) { return largest.name }
+            return mainExe
+        case .gameMaker:
+            return (listing.file(named: "data.win") ?? listing.file(named: "game.unx"))?.name
+        case .unity:
+            return unity(listing, dataDir: unityDataDirectory(listing, executables: executables))
+        case .renpy:
+            guard let game = listing.directory(named: "game"), let contents = try? listing.listing(of: game),
+                  let archive = largest(contents.files(withExtension: "rpa")) ?? largest(contents.files(withExtension: "rpyc"))
+            else { return nil }
+            return "\(game.name)/\(archive.name)"
+        case .bgi, .unknown:
+            return mainExe
+        }
+    }
+
+    /// The Windows executable if present, otherwise the Linux one.
+    static func mainExecutable(_ executables: [GamePlatform: ExecutableInfo]) -> String? {
+        (executables[.windows] ?? executables[.linux])?.path
+    }
+
+    /// `<stem>_Data` for the main executable's stem, else the first `*_Data` folder.
+    static func unityDataDirectory(_ listing: FolderListing,
+                                   executables: [GamePlatform: ExecutableInfo]) -> FolderListing.Entry? {
+        let stem = mainExecutable(executables).map { path in
+            ((path as NSString).lastPathComponent as NSString).deletingPathExtension
+        }
+        return stem.flatMap { listing.directory(named: $0 + "_Data") }
+            ?? listing.entries.first { $0.kind == .directory && $0.key.hasSuffix("_data") }
+    }
+
+    private static func unity(_ listing: FolderListing, dataDir: FolderListing.Entry?) -> String? {
+        for name in ["GameAssembly.dll", "GameAssembly.so"] {
+            if let file = listing.file(named: name) { return file.name }
+        }
+        guard let dataDir, let data = try? listing.listing(of: dataDir) else { return nil }
+        if let managed = data.directory(named: "Managed"), let contents = try? data.listing(of: managed),
+           let assembly = contents.file(named: "Assembly-CSharp.dll") {
+            return "\(dataDir.name)/\(managed.name)/\(assembly.name)"
+        }
+        return data.file(named: "globalgamemanagers").map { "\(dataDir.name)/\($0.name)" }
+    }
+
+    /// The largest entry; ties go to the first in sorted order.
+    private static func largest(_ entries: [FolderListing.Entry]) -> FolderListing.Entry? {
+        entries.reduce(nil) { best, entry in
+            guard let best else { return entry }
+            return entry.size > best.size ? entry : best
+        }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Identity/NameNormalizer.swift b/Packages/EikonCore/Sources/EikonCore/Identity/NameNormalizer.swift
new file mode 100644
index 0000000..34e0056
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Identity/NameNormalizer.swift
@@ -0,0 +1,14 @@
+import Foundation
+
+/// The one normalization of file and folder names: listings, lookups, name sets and the
+/// matcher's folder-name comparison all go through it.
+public enum NameNormalizer {
+    /// NFC, trimmed, case-folded without a locale. NFC again after folding, which can
+    /// decompose, so a normalized name normalizes to itself.
+    public static func normalize(_ name: String) -> String {
+        name.precomposedStringWithCanonicalMapping
+            .trimmingCharacters(in: .whitespacesAndNewlines)
+            .folding(options: [.caseInsensitive], locale: nil)
+            .precomposedStringWithCanonicalMapping
+    }
+}
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/DetectionTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/DetectionTests.swift
index f30cde5..682c379 100644
--- a/Packages/EikonCore/Tests/EikonCoreTests/DetectionTests.swift
+++ b/Packages/EikonCore/Tests/EikonCoreTests/DetectionTests.swift
@@ -13,7 +13,7 @@ private func detect(_ url: URL) throws -> DetectionResult? {
 }
 
 private func samePath(_ lhs: String?, _ rhs: String) -> Bool {
-    lhs.map(FolderListing.normalize) == FolderListing.normalize(rhs)
+    lhs.map(NameNormalizer.normalize) == NameNormalizer.normalize(rhs)
 }
 
 // MARK: Types and entry point
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift b/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift
index 2f73b70..56e9663 100644
--- a/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift
+++ b/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift
@@ -136,16 +136,30 @@ enum Fixtures {
     }
 
     /// FORM, then GEN8 (or another first chunk), an optional CODE chunk and a STRG chunk.
-    static func gameMaker(hasGEN8: Bool = true, hasCode: Bool) -> Data {
+    /// With `names`, GEN8 points its Name and DisplayName at those strings in STRG.
+    static func gameMaker(hasGEN8: Bool = true, hasCode: Bool, names: (name: String, displayName: String)? = nil) -> Data {
+        let gen8Size = names == nil ? 16 : 128
+        let strgStart = 8 + (8 + gen8Size) + (hasCode ? 16 : 0) + 8
+        var strings = Data()
+        var gen8 = Data(count: gen8Size)
+        if let names {
+            for (field, text) in [(40, names.name), (100, names.displayName)] {
+                let bytes = Data(text.utf8)
+                strings.append32(UInt32(bytes.count))
+                gen8.put32(UInt32(strgStart + strings.count), at: field)
+                strings.append(bytes)
+                strings.append(0)
+            }
+        }
         var chunks = Data()
-        func chunk(_ tag: String, _ size: Int) {
+        func chunk(_ tag: String, _ content: Data) {
             chunks.append(Data(tag.utf8))
-            chunks.append32(UInt32(size))
-            chunks.append(Data(count: size))
+            chunks.append32(UInt32(content.count))
+            chunks.append(content)
         }
-        chunk(hasGEN8 ? "GEN8" : "OPTN", 16)
-        if hasCode { chunk("CODE", 8) }
-        chunk("STRG", 4)
+        chunk(hasGEN8 ? "GEN8" : "OPTN", gen8)
+        if hasCode { chunk("CODE", Data(count: 8)) }
+        chunk("STRG", strings.isEmpty ? Data(count: 4) : strings)
         var data = Data("FORM".utf8)
         data.append32(UInt32(chunks.count))
         return data + chunks
@@ -160,9 +174,10 @@ enum Fixtures {
 
     enum RenPyEra { case scriptVersion, vcVersion, initPy, libEra }
 
-    /// A Ren'Py game whose stem is "Game". Exact eras record `version`.
-    static func renpy(_ era: RenPyEra, version: [Int] = [7, 4, 11], named name: String = "Sample",
-                      in dir: URL) throws -> URL {
+    /// A Ren'Py game whose stem is "Game". Exact eras record `version`. With
+    /// `saveDirectory`, game/options.rpy sets `config.save_directory` to it.
+    static func renpy(_ era: RenPyEra, version: [Int] = [7, 4, 11], saveDirectory: String? = nil,
+                      named name: String = "Sample", in dir: URL) throws -> URL {
         let root = dir.appendingPathComponent(name, isDirectory: true)
         let text = version.map(String.init)
         try write(pe(machine: peAMD64), to: "Game.exe", in: root)
@@ -170,6 +185,10 @@ enum Fixtures {
         try write("#!/bin/sh\nexec lib/game\n", to: "Game.sh", in: root)
         try write(Data([0x52, 0x50, 0x43, 0x32]), to: "game/script.rpyc", in: root)
         try write("# engine\n", to: "renpy/__init__.py", in: root)
+        if let saveDirectory {
+            try write("## Options\ndefine config.name = _(\"Sample\")\ndefine config.save_directory = \"\(saveDirectory)\"\n",
+                      to: "game/options.rpy", in: root)
+        }
 
         let linuxDir: String
         switch era {
@@ -196,9 +215,10 @@ enum Fixtures {
 
     enum UnityLayout { case mono, il2cpp, pre2017 }
 
-    /// A Unity game whose stem is "Game", with a larger GUI crash handler beside it.
-    static func unity(_ layout: UnityLayout, linux: Bool = false, named name: String = "Sample",
-                      in dir: URL) throws -> URL {
+    /// A Unity game whose stem is "Game", with a larger GUI crash handler beside it. With
+    /// `appInfo`, Game_Data/app.info holds that company and product.
+    static func unity(_ layout: UnityLayout, linux: Bool = false, appInfo: (company: String, product: String)? = nil,
+                      named name: String = "Sample", in dir: URL) throws -> URL {
         let root = dir.appendingPathComponent(name, isDirectory: true)
         try write(pe(machine: peAMD64), to: "Game.exe", in: root)
         try write(pe(machine: peAMD64, padTo: 64 << 10), to: "UnityCrashHandler64.exe", in: root)
@@ -216,6 +236,9 @@ enum Fixtures {
             try write(Data(count: 64), to: "Game_Data/mainData", in: root)
             try write(pe(machine: peI386, dll: true), to: "Game_Data/Managed/Assembly-CSharp.dll", in: root)
         }
+        if let appInfo {
+            try write("\(appInfo.company)\n\(appInfo.product)", to: "Game_Data/app.info", in: root)
+        }
         if linux {
             try write(elf(machine: elfAMD64), to: "Game.x86_64", in: root)
             try write(elf(machine: elfAMD64), to: "UnityPlayer.so", in: root)
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/IdentityTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/IdentityTests.swift
new file mode 100644
index 0000000..285e43c
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/IdentityTests.swift
@@ -0,0 +1,334 @@
+import CryptoKit
+import Foundation
+import Testing
+import EikonCore
+
+// MARK: Fakes
+
+private let secret = LibrarySecret(bytes: Data(repeating: 7, count: LibrarySecret.byteCount))
+
+private func withTempDir(_ body: (URL) throws -> Void) throws {
+    let dir = try Fixtures.tempDir()
+    defer { try? FileManager.default.removeItem(at: dir) }
+    try body(dir)
+}
+
+private func fingerprint(_ folder: URL, secret: LibrarySecret = secret) throws -> Fingerprint {
+    let detection = try #require(try GameDetector.detect(folder: folder))
+    return try FingerprintBuilder.build(detection: detection, folder: folder, secret: secret)
+}
+
+private func declaredID(_ folder: URL) throws -> EngineDeclaredID.Result {
+    try EngineDeclaredID.read(detection: try #require(try GameDetector.detect(folder: folder)), folder: folder)
+}
+
+/// A fingerprint from made-up tokens; tokens are hashed so they look like real keyed values.
+private func fp(_ exact: String, engine: String? = nil, names: [String] = []) -> Fingerprint {
+    func hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
+    return Fingerprint(engineID: engine.map { Keyed(hex: hex($0)) }, exact: Keyed(hex: hex(exact)),
+                       names: names.map { Keyed8(hex: String(hex($0).prefix(16))) }.sorted())
+}
+
+/// Always mints the same id, so expectations can name it.
+private final class Minter: @unchecked Sendable {
+    let next = GameID.random()
+    func mint() -> GameID { next }
+}
+
+// MARK: Signals and fingerprints
+
+private enum DeclaredSource: CaseIterable {
+    case renpy, unity, gameMaker, exeVersion
+
+    func build(in dir: URL) throws -> URL {
+        switch self {
+        case .renpy:
+            return try Fixtures.renpy(.scriptVersion, saveDirectory: "fixture-save-1234", in: dir)
+        case .unity:
+            return try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), in: dir)
+        case .gameMaker:
+            let root = dir.appendingPathComponent("Sample")
+            try Fixtures.write(Fixtures.gameMaker(hasCode: true, names: ("fixture_project", "fixture-product")),
+                               to: "data.win", in: root)
+            try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: root)
+            return root
+        case .exeVersion:
+            let root = dir.appendingPathComponent("Sample")
+            try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, versionStrings: [
+                "CompanyName": "fixture-company", "ProductName": "fixture-product",
+            ]), to: "Game.exe", in: root)
+            return root
+        }
+    }
+
+    var plainValues: [String] {
+        switch self {
+        case .renpy: ["fixture-save-1234"]
+        case .unity, .exeVersion: ["fixture-company", "fixture-product"]
+        case .gameMaker: ["fixture_project", "fixture-product"]
+        }
+    }
+}
+
+@Test(arguments: DeclaredSource.allCases)
+private func engineDeclaredIDIsRead(source: DeclaredSource) throws {
+    try withTempDir { dir in
+        let root = try source.build(in: dir)
+        guard case .found = try declaredID(root) else { Issue.record("no declared id"); return }
+        #expect(try fingerprint(root).engineID != nil)
+    }
+}
+
+@Test func genericDeclaredValuesGiveNoEngineID() throws {
+    try withTempDir { dir in
+        let unity = try Fixtures.unity(.mono, appInfo: ("DefaultCompany", "My project"), named: "Unity", in: dir)
+        let kirikiri = try Fixtures.kirikiri(flavor: "TVP(KIRIKIRI) Z", named: "Kirikiri", in: dir)
+        for root in [unity, kirikiri] {
+            #expect(try declaredID(root) == .generic)
+            #expect(try fingerprint(root).engineID == nil)
+        }
+    }
+}
+
+@Test func renamingTheGameFolderKeepsTheFingerprint() throws {
+    try withTempDir { dir in
+        let root = try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), named: "Before", in: dir)
+        let before = try fingerprint(root)
+        let renamed = dir.appendingPathComponent("After")
+        try FileManager.default.moveItem(at: root, to: renamed)
+        #expect(try fingerprint(renamed) == before)
+    }
+}
+
+private enum ContentChange: CaseIterable {
+    case fileSize, keyFileHead, keyFileTail
+}
+
+@Test(arguments: ContentChange.allCases)
+private func contentChangeAltersExactButNotEngineID(change: ContentChange) throws {
+    try withTempDir { dir in
+        let root = try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), in: dir)
+        let detection = try #require(try GameDetector.detect(folder: root))
+        let keyFile = root.appendingPathComponent(try #require(detection.keyFile))
+        var key = Data((0..<(3 * FileHasher.chunkSize)).map { UInt8(truncatingIfNeeded: $0) })
+        try key.write(to: keyFile)
+        let before = try FingerprintBuilder.build(detection: detection, folder: root, secret: secret)
+
+        switch change {
+        case .fileSize:
+            try Fixtures.write("extra bytes", to: "notes.txt", in: root)
+        case .keyFileHead:
+            key[0] ^= 0xFF
+            try key.write(to: keyFile)
+        case .keyFileTail:
+            key[key.count - 1] ^= 0xFF
+            try key.write(to: keyFile)
+        }
+        let after = try FingerprintBuilder.build(detection: detection, folder: root, secret: secret)
+        #expect(after.exact != before.exact)
+        #expect(after.engineID == before.engineID)
+    }
+}
+
+@Test(arguments: DeclaredSource.allCases)
+private func fingerprintHoldsNoPlainText(source: DeclaredSource) throws {
+    try withTempDir { dir in
+        let root = try source.build(in: dir)
+        let json = String(decoding: try JSONEncoder().encode(try fingerprint(root)), as: UTF8.self).lowercased()
+        let listed = try FileManager.default.subpathsOfDirectory(atPath: root.path)
+            .flatMap { $0.split(separator: "/").map(String.init) }
+        for text in [root.lastPathComponent] + listed + source.plainValues {
+            #expect(!json.contains(text.lowercased()))
+        }
+    }
+}
+
+@Test func secretDecidesTheKeyedValues() throws {
+    try withTempDir { dir in
+        let root = try Fixtures.unity(.mono, appInfo: ("fixture-company", "fixture-product"), in: dir)
+        let other = LibrarySecret(bytes: Data(repeating: 9, count: LibrarySecret.byteCount))
+        #expect(try fingerprint(root) == fingerprint(root))
+        let first = try fingerprint(root), second = try fingerprint(root, secret: other)
+        #expect(first.exact != second.exact)
+        #expect(first.engineID != second.engineID)
+        #expect(Set(first.names).isDisjoint(with: second.names))
+    }
+}
+
+@Test func keyFileIsNeverALauncherOrPlayer() throws {
+    try withTempDir { dir in
+        for root in [try Fixtures.renpy(.scriptVersion, named: "RenPy", in: dir),
+                     try Fixtures.unity(.mono, named: "Unity", in: dir)] {
+            let detection = try #require(try GameDetector.detect(folder: root))
+            let keyFile = try #require(detection.keyFile).lowercased()
+            let executables = detection.executables.values.map { $0.path.lowercased() }
+            #expect(!executables.contains(keyFile))
+            #expect(!keyFile.contains("unityplayer"))
+        }
+    }
+}
+
+@Test func librarySecretIsCreatedOnceThenReadBack() throws {
+    try withTempDir { dir in
+        let url = dir.appendingPathComponent("support/library-secret")
+        let created = try LibrarySecret.loadOrCreate(at: url)
+        let loaded = try LibrarySecret.loadOrCreate(at: url)
+        let game = try Fixtures.unity(.mono, in: dir)
+        #expect(try fingerprint(game, secret: created) == fingerprint(game, secret: loaded))
+    }
+}
+
+// MARK: Matcher
+
+private let drive = UUID()
+private let here = LocationKey(driveID: drive, folderName: "Folder")
+
+private enum MatcherCase: CaseIterable {
+    case inPlacePatch, exactUnderNewName, engineIDNotLiveHere, engineIDLiveHere,
+         similarNames, dissimilarNames, twoCandidates, noMatch, deletedGame
+
+    func run() -> (result: MatchResult, expected: MatchResult) {
+        let known = GameID.random(), other = GameID.random(), minter = Minter()
+        let names = (0..<20).map { "name-\($0)" }
+        // The most extra names that keep Jaccard at or above the threshold.
+        let extra = (0...names.count).last {
+            Double(names.count) / Double(names.count + $0) >= IdentityMatcher.nameSimilarityThreshold
+        }!
+        func match(_ fingerprint: Fingerprint, _ games: [KnownGame],
+                   locations: [LocationKey: GameID] = [:]) -> MatchResult {
+            IdentityMatcher.match(fingerprint: fingerprint, at: here, knownLocations: locations, games: games,
+                                  mint: minter.mint)
+        }
+        switch self {
+        case .inPlacePatch:
+            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e1", names: ["a"])],
+                                 hasLiveLocationHere: true)
+            return (match(fp("v2", engine: "e2", names: ["b"]), [game], locations: [here: known]), .keep(known))
+        case .exactUnderNewName:
+            let game = KnownGame(id: known, fingerprints: [fp("v1")], hasLiveLocationHere: true)
+            return (match(fp("v1"), [game]), .attach(known, .exact))
+        case .engineIDNotLiveHere:
+            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e")], hasLiveLocationHere: false)
+            return (match(fp("v2", engine: "e"), [game]), .attach(known, .engineID))
+        case .engineIDLiveHere:
+            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e")], hasLiveLocationHere: true)
+            return (match(fp("v2", engine: "e"), [game]), .newGame(minter.next, suggestions: [known]))
+        case .similarNames:
+            let game = KnownGame(id: known, fingerprints: [fp("v1", names: names)], hasLiveLocationHere: false)
+            let added = (0..<extra).map { "added-\($0)" }
+            return (match(fp("v2", names: names + added), [game]), .attach(known, .nameSimilarity))
+        case .dissimilarNames:
+            let game = KnownGame(id: known, fingerprints: [fp("v1", names: names)], hasLiveLocationHere: false)
+            let added = (0...extra).map { "added-\($0)" }
+            return (match(fp("v2", names: names + added), [game]), .newGame(minter.next, suggestions: []))
+        case .twoCandidates:
+            let games = [known, other].map {
+                KnownGame(id: $0, fingerprints: [fp("v1", engine: "e")], hasLiveLocationHere: false)
+            }
+            return (match(fp("v2", engine: "e"), games),
+                    .newGame(minter.next, suggestions: [known, other].sorted()))
+        case .noMatch:
+            let game = KnownGame(id: known, fingerprints: [fp("v1", engine: "e1")], hasLiveLocationHere: false)
+            return (match(fp("v2", engine: "e2"), [game]), .newGame(minter.next, suggestions: []))
+        case .deletedGame:
+            let game = KnownGame(id: known, fingerprints: [fp("v1")], hasLiveLocationHere: false, isDeleted: true)
+            return (match(fp("v1"), [game], locations: [here: known]), .newGame(minter.next, suggestions: []))
+        }
+    }
+}
+
+@Test(arguments: MatcherCase.allCases)
+private func matcherAppliesItsRules(scenario: MatcherCase) {
+    let outcome = scenario.run()
+    #expect(outcome.result == outcome.expected)
+}
+
+@Test func unmatchedGamesGetDistinctRandomIDs() {
+    let first = IdentityMatcher.match(fingerprint: fp("a"), at: here, knownLocations: [:], games: [])
+    let second = IdentityMatcher.match(fingerprint: fp("b"), at: here, knownLocations: [:], games: [])
+    guard case .newGame(let a, _) = first, case .newGame(let b, _) = second else {
+        Issue.record("expected new games")
+        return
+    }
+    #expect(a != b)
+}
+
+@Test func fingerprintCapKeepsTheMostRecent() {
+    let all = (0..<(Fingerprint.maxPerGame + 3)).map { fp("build-\($0)") }
+    var list: [Fingerprint] = []
+    for fingerprint in all { list = IdentityMatcher.adding(fingerprint, to: list) }
+    #expect(list == Array(all.suffix(Fingerprint.maxPerGame)))
+
+    let repeated = IdentityMatcher.adding(list[0], to: list)
+    #expect(repeated.count == list.count)
+    #expect(repeated.last == list[0])
+}
+
+// MARK: Merge and split
+
+@Test func mergeMovesLocationsAndKeepsTheTargetsSettings() {
+    let a = GameID.random(), b = GameID.random(), location = UUID()
+    var ledger = IdentityLedger<String>(
+        fingerprints: [a: [fp("a")], b: [fp("b")]], locations: [location: a],
+        settings: [a: ["shared": "from-a", "only-a": "a"], b: ["shared": "from-b"]])
+    ledger.merge(a, into: b)
+
+    #expect(IdentityMatcher.resolve(a, links: ledger.links) == b)
+    #expect(ledger.locations[location] == b)
+    #expect(ledger.settings[b] == ["shared": "from-b", "only-a": "a"])
+    #expect(ledger.fingerprints[b]?.contains(fp("a")) == true)
+}
+
+@Test func mergeLinksResolveThroughChainsAndCycles() {
+    let ids = (0..<3).map { _ in GameID.random() }
+    let chain = [ids[0]: ids[1], ids[1]: ids[2]]
+    #expect(IdentityMatcher.resolve(ids[0], links: chain) == ids[2])
+
+    let cycle = [ids[0]: ids[1], ids[1]: ids[0]]
+    #expect(IdentityMatcher.resolve(ids[0], links: cycle) == IdentityMatcher.resolve(ids[1], links: cycle))
+}
+
+@Test func splitForksTheSettings() {
+    let old = GameID.random(), location = UUID(), fingerprint = fp("split")
+    var ledger = IdentityLedger<String>(fingerprints: [old: [fp("kept"), fingerprint]],
+                                        locations: [location: old], settings: [old: ["key": "value"]])
+    let new = ledger.split(location: location, fingerprint: fingerprint)
+
+    #expect(new != old)
+    #expect(ledger.locations[location] == new)
+    #expect(ledger.settings[new] == ledger.settings[old])
+    #expect(ledger.fingerprints[old]?.contains(fingerprint) == false)
+
+    ledger.settings[new]?["key"] = "changed"
+    ledger.settings[old]?["other"] = "added"
+    #expect(ledger.settings[old]?["key"] == "value")
+    #expect(ledger.settings[new]?["other"] == nil)
+}
+
+// MARK: Diagnostics hasher
+
+@Test func fileHasherMatchesSHA256AndReportsProgress() throws {
+    try withTempDir { dir in
+        let data = Data((0..<(2 * FileHasher.chunkSize + 123)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
+        let url = dir.appendingPathComponent("blob.bin")
+        try data.write(to: url)
+
+        var reported: [Double] = []
+        let hex = try FileHasher.sha256(of: url, progress: { reported.append($0) }, isCancelled: { false })
+        #expect(hex == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
+        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
+    }
+}
+
+@Test func fileHasherStopsEarlyOnCancel() throws {
+    try withTempDir { dir in
+        let url = dir.appendingPathComponent("blob.bin")
+        try Data(count: 4 * FileHasher.chunkSize).write(to: url)
+
+        var chunks = 0
+        #expect(throws: CancellationError.self) {
+            _ = try FileHasher.sha256(of: url, progress: { if $0 > 0 { chunks += 1 } }, isCancelled: { chunks >= 1 })
+        }
+        #expect(chunks == 1)
+    }
+}

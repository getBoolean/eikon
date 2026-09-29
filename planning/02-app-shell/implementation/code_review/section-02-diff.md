diff --git a/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h b/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
index 90dc075..abf6e79 100644
--- a/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
+++ b/Packages/EikonCore/Sources/CEikonSession/include/CEikonSession.h
@@ -4,6 +4,9 @@
 #include <stdbool.h>
 #include <stdint.h>
 
+/* System zlib, for Swift: detection inflates XP3 indexes; tests build zlib fixtures. */
+#include <zlib.h>
+
 /* ---- Render gate (in-flight guard) ------------------------------------------------------
    A render thread calls enter before encoding a frame and leave after committing it. The
    host closes the gate, then waits for in_flight to reach 0. enter increments before it
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/BGIDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/BGIDetector.swift
new file mode 100644
index 0000000..d19a9c9
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/BGIDetector.swift
@@ -0,0 +1,17 @@
+import Foundation
+
+enum BGIDetector {
+    private static let arcMagics = ["PackFile    ", "BURIKO ARC20"].map { Array($0.utf8) }
+
+    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
+        if listing.file(named: "BGI.exe") != nil { return EngineMatch(engine: .bgi, details: EngineDetails()) }
+        var archives = 0
+        for arc in listing.files(withExtension: "arc") {
+            guard let header = try? reader.read(arc.name, offset: 0, length: 12, for: .binaryHeaders),
+                  arcMagics.contains(where: { header.hasBytes($0) }) else { continue }
+            archives += 1
+            if archives >= 2 { return EngineMatch(engine: .bgi, details: EngineDetails()) }
+        }
+        return nil
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/BinaryInfo.swift b/Packages/EikonCore/Sources/EikonCore/Detection/BinaryInfo.swift
new file mode 100644
index 0000000..1734b9d
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/BinaryInfo.swift
@@ -0,0 +1,112 @@
+import Foundation
+
+public enum BinaryFormat: String, Codable, Sendable, CaseIterable {
+    case pe, elf
+}
+
+public enum CPUArchitecture: String, Codable, Sendable, CaseIterable {
+    /// `arm64` covers ARM64, ARM64EC and ARM64X.
+    case i386, amd64, arm64, other
+
+    /// A value from another build decodes as `.other`.
+    public init(from decoder: any Decoder) throws {
+        self = CPUArchitecture(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
+    }
+
+    static func pe(machine: UInt16) -> CPUArchitecture {
+        switch machine {
+        case 0x014C: .i386
+        case 0x8664: .amd64
+        case 0xAA64, 0xA641, 0xA64E: .arm64
+        default: .other
+        }
+    }
+
+    static func elf(machine: UInt16) -> CPUArchitecture {
+        switch machine {
+        case 3: .i386
+        case 62: .amd64
+        case 183: .arm64
+        default: .other
+        }
+    }
+}
+
+struct PESection: Sendable {
+    let name: String
+    let virtualAddress: UInt32
+    let rawSize: UInt32
+    let rawPointer: UInt32
+}
+
+struct ParsedBinary: Sendable {
+    let format: BinaryFormat
+    let architecture: CPUArchitecture
+    let machine: UInt16
+    /// PE subsystem is Windows GUI; nil for ELF.
+    let isGUI: Bool?
+    /// PE with the DLL characteristic: never an executable.
+    let isDLL: Bool
+    /// PE only.
+    let sections: [PESection]
+}
+
+/// PE and ELF header parsing, within the binaryHeaders budget.
+enum BinaryInfo {
+    static let elfMagic: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]
+
+    static func parse(_ reader: FolderReader, path: String) -> ParsedBinary? {
+        guard let start = try? reader.read(path, offset: 0, length: 64, for: .binaryHeaders) else { return nil }
+        if start.hasBytes([0x4D, 0x5A]) { return try? parsePE(reader, path: path, dosHeader: start) }
+        if start.hasBytes(elfMagic) { return parseELF(start) }
+        return nil
+    }
+
+    static func hasELFMagic(_ reader: FolderReader, path: String) -> Bool {
+        (try? reader.read(path, offset: 0, length: 4, for: .binaryHeaders))?.hasBytes(elfMagic) ?? false
+    }
+
+    private static func parsePE(_ reader: FolderReader, path: String, dosHeader: Data) throws -> ParsedBinary? {
+        guard let fileSize = reader.size(of: path), let lfanew = dosHeader.uint32LE(at: 0x3C),
+              lfanew % 4 == 0, lfanew < 64 << 10, UInt64(lfanew) < fileSize else { return nil }
+
+        let coff = try reader.read(path, offset: UInt64(lfanew), length: 24, for: .binaryHeaders)
+        guard coff.hasBytes([0x50, 0x45, 0, 0]), let machine = coff.uint16LE(at: 4),
+              let sectionCount = coff.uint16LE(at: 6), let optionalSize = coff.uint16LE(at: 20),
+              let characteristics = coff.uint16LE(at: 22) else { return nil }
+
+        let optionalOffset = UInt64(lfanew) + 24
+        let optional = try reader.read(path, offset: optionalOffset, length: Int(min(optionalSize, 4096)),
+                                       for: .binaryHeaders)
+        let isGUI = optional.uint16LE(at: 68) == 2
+
+        let count = Int(min(sectionCount, 96))
+        let table = try reader.read(path, offset: optionalOffset + UInt64(optionalSize), length: count * 40,
+                                    for: .binaryHeaders)
+        var sections: [PESection] = []
+        for index in 0..<(table.count / 40) {
+            let base = index * 40
+            let nameBytes = table[(table.startIndex + base)..<(table.startIndex + base + 8)].prefix { $0 != 0 }
+            sections.append(PESection(name: String(decoding: nameBytes, as: UTF8.self),
+                                      virtualAddress: table.uint32LE(at: base + 12) ?? 0,
+                                      rawSize: table.uint32LE(at: base + 16) ?? 0,
+                                      rawPointer: table.uint32LE(at: base + 20) ?? 0))
+        }
+
+        return ParsedBinary(format: .pe, architecture: .pe(machine: machine), machine: machine, isGUI: isGUI,
+                            isDLL: characteristics & 0x2000 != 0, sections: sections)
+    }
+
+    private static func parseELF(_ header: Data) -> ParsedBinary? {
+        // EI_DATA: 1 little-endian, 2 big-endian.
+        let machine: UInt16?
+        switch header.uint8(at: 5) {
+        case 1: machine = header.uint16LE(at: 0x12)
+        case 2: machine = header.uint16BE(at: 0x12)
+        default: machine = nil
+        }
+        guard let machine else { return nil }
+        return ParsedBinary(format: .elf, architecture: .elf(machine: machine), machine: machine, isGUI: nil,
+                            isDLL: false, sections: [])
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/ByteReading.swift b/Packages/EikonCore/Sources/EikonCore/Detection/ByteReading.swift
new file mode 100644
index 0000000..db6797a
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/ByteReading.swift
@@ -0,0 +1,49 @@
+import Foundation
+
+/// Bounds-checked fixed-width reads. Offsets are relative to the data's start index.
+extension Data {
+    func uint8(at offset: Int) -> UInt8? {
+        guard offset >= 0, offset < count else { return nil }
+        return self[startIndex + offset]
+    }
+
+    func uint16LE(at offset: Int) -> UInt16? { littleEndian(at: offset, bytes: 2).map { UInt16($0) } }
+    func uint32LE(at offset: Int) -> UInt32? { littleEndian(at: offset, bytes: 4).map { UInt32($0) } }
+    func uint64LE(at offset: Int) -> UInt64? { littleEndian(at: offset, bytes: 8) }
+
+    func uint16BE(at offset: Int) -> UInt16? { bigEndian(at: offset, bytes: 2).map { UInt16($0) } }
+    func uint32BE(at offset: Int) -> UInt32? { bigEndian(at: offset, bytes: 4).map { UInt32($0) } }
+
+    /// The bytes at `offset` equal `prefix`.
+    func hasBytes(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
+        guard offset >= 0, offset + prefix.count <= count else { return false }
+        return self[(startIndex + offset)..<(startIndex + offset + prefix.count)].elementsEqual(prefix)
+    }
+
+    /// The ASCII/UTF-8 string from `offset` up to a NUL (or `maxLength` bytes), if it ends in range.
+    func nulTerminatedString(at offset: Int, maxLength: Int = 256) -> String? {
+        guard offset >= 0, offset < count else { return nil }
+        let end = Swift.min(count, offset + maxLength)
+        let bytes = self[(startIndex + offset)..<(startIndex + end)]
+        guard let nul = bytes.firstIndex(of: 0) else { return nil }
+        return String(decoding: self[(startIndex + offset)..<nul], as: UTF8.self)
+    }
+
+    private func littleEndian(at offset: Int, bytes: Int) -> UInt64? {
+        guard offset >= 0, offset + bytes <= count else { return nil }
+        var value: UInt64 = 0
+        for index in (0..<bytes).reversed() {
+            value = value << 8 | UInt64(self[startIndex + offset + index])
+        }
+        return value
+    }
+
+    private func bigEndian(at offset: Int, bytes: Int) -> UInt64? {
+        guard offset >= 0, offset + bytes <= count else { return nil }
+        var value: UInt64 = 0
+        for index in 0..<bytes {
+            value = value << 8 | UInt64(self[startIndex + offset + index])
+        }
+        return value
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/DetectionResult.swift b/Packages/EikonCore/Sources/EikonCore/Detection/DetectionResult.swift
new file mode 100644
index 0000000..667d082
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/DetectionResult.swift
@@ -0,0 +1,93 @@
+import Foundation
+
+public enum GamePlatform: String, Codable, Sendable, CaseIterable {
+    case windows, linux
+}
+
+public struct ExecutableInfo: Codable, Sendable, Equatable {
+    /// Relative to the game root.
+    public var path: String
+    public var format: BinaryFormat
+    public var architecture: CPUArchitecture
+    /// Raw COFF Machine or ELF e_machine.
+    public var machine: UInt16
+    /// PE subsystem is Windows GUI; nil for ELF.
+    public var isGUI: Bool?
+
+    public init(path: String, format: BinaryFormat, architecture: CPUArchitecture, machine: UInt16, isGUI: Bool?) {
+        self.path = path
+        self.format = format
+        self.architecture = architecture
+        self.machine = machine
+        self.isGUI = isGUI
+    }
+}
+
+public struct DetectionResult: Codable, Sendable, Equatable {
+    public var engine: Engine
+    public var details: EngineDetails
+    /// "" or the name of the single wrapper subfolder holding the game.
+    public var gameRoot: String
+    /// The main executable per platform.
+    public var executables: [GamePlatform: ExecutableInfo]
+    /// Relative to `gameRoot`.
+    public var keyFile: String?
+    /// `GameDetector.version` when this was computed; an older one is a stale cache.
+    public var detectorVersion: Int
+
+    public init(engine: Engine, details: EngineDetails, gameRoot: String,
+                executables: [GamePlatform: ExecutableInfo], keyFile: String?, detectorVersion: Int) {
+        self.engine = engine
+        self.details = details
+        self.gameRoot = gameRoot
+        self.executables = executables
+        self.keyFile = keyFile
+        self.detectorVersion = detectorVersion
+    }
+
+    private enum CodingKeys: String, CodingKey {
+        case engine, details, gameRoot, executables, keyFile, detectorVersion
+    }
+
+    /// `executables` is a JSON object keyed by platform raw value. An entry with an unknown
+    /// platform or binary format is dropped rather than failing the result.
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        engine = try container.decode(Engine.self, forKey: .engine)
+        details = (try? container.decodeIfPresent(EngineDetails.self, forKey: .details)) ?? EngineDetails()
+        gameRoot = try container.decode(String.self, forKey: .gameRoot)
+        keyFile = try container.decodeIfPresent(String.self, forKey: .keyFile)
+        detectorVersion = try container.decode(Int.self, forKey: .detectorVersion)
+
+        var executables: [GamePlatform: ExecutableInfo] = [:]
+        if container.contains(.executables) {
+            let byPlatform = try container.nestedContainer(keyedBy: PlatformKey.self, forKey: .executables)
+            for key in byPlatform.allKeys {
+                guard let platform = GamePlatform(rawValue: key.stringValue),
+                      let info = try? byPlatform.decode(ExecutableInfo.self, forKey: key) else { continue }
+                executables[platform] = info
+            }
+        }
+        self.executables = executables
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var container = encoder.container(keyedBy: CodingKeys.self)
+        try container.encode(engine, forKey: .engine)
+        try container.encode(details, forKey: .details)
+        try container.encode(gameRoot, forKey: .gameRoot)
+        try container.encodeIfPresent(keyFile, forKey: .keyFile)
+        try container.encode(detectorVersion, forKey: .detectorVersion)
+        var byPlatform = container.nestedContainer(keyedBy: PlatformKey.self, forKey: .executables)
+        for (platform, info) in executables {
+            try byPlatform.encode(info, forKey: PlatformKey(stringValue: platform.rawValue))
+        }
+    }
+}
+
+private struct PlatformKey: CodingKey {
+    let stringValue: String
+    var intValue: Int? { nil }
+    init(stringValue: String) { self.stringValue = stringValue }
+    init?(intValue: Int) { nil }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/Engine.swift b/Packages/EikonCore/Sources/EikonCore/Detection/Engine.swift
new file mode 100644
index 0000000..ce9d80d
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/Engine.swift
@@ -0,0 +1,111 @@
+import Foundation
+
+public enum Engine: String, Codable, Sendable, CaseIterable {
+    case unity, kirikiri, renpy, gameMaker, bgi, unknown
+
+    /// A value from another build decodes as `.unknown`.
+    public init(from decoder: any Decoder) throws {
+        self = Engine(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
+    }
+}
+
+public enum UnityScripting: String, Codable, Sendable, CaseIterable {
+    case mono, il2cpp
+}
+
+public enum KirikiriFlavor: String, Codable, Sendable, CaseIterable {
+    case krkr2, krkrZ, unknown
+
+    /// A value from another build decodes as `.unknown`.
+    public init(from decoder: any Decoder) throws {
+        self = KirikiriFlavor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
+    }
+}
+
+public enum GameMakerBuild: String, Codable, Sendable, CaseIterable {
+    case vm, yyc
+}
+
+public enum RenPyVersionKind: String, Codable, Sendable, CaseIterable {
+    /// Read from a version file.
+    case exact
+    /// Inferred from the `lib/` layout: a range, not a version.
+    case era
+}
+
+/// A Ren'Py version. Exact: `major.minor.patch?`. Era: from `major.minor` (0.0 when
+/// unbounded below) to `maxMajor.maxMinor` (nil when open-ended). Formatting is the UI's job.
+public struct RenPyVersion: Codable, Sendable, Equatable {
+    public var major: Int
+    public var minor: Int
+    public var patch: Int?
+    public var kind: RenPyVersionKind
+    public var maxMajor: Int?
+    public var maxMinor: Int?
+
+    public init(major: Int, minor: Int, patch: Int? = nil, kind: RenPyVersionKind,
+                maxMajor: Int? = nil, maxMinor: Int? = nil) {
+        self.major = major
+        self.minor = minor
+        self.patch = patch
+        self.kind = kind
+        self.maxMajor = maxMajor
+        self.maxMinor = maxMinor
+    }
+
+    public static func exact(_ major: Int, _ minor: Int, _ patch: Int?) -> RenPyVersion {
+        RenPyVersion(major: major, minor: minor, patch: patch, kind: .exact)
+    }
+
+    public static func era(from: (Int, Int), through: (Int, Int)?) -> RenPyVersion {
+        RenPyVersion(major: from.0, minor: from.1, kind: .era, maxMajor: through?.0, maxMinor: through?.1)
+    }
+}
+
+public struct EngineDetails: Codable, Sendable, Equatable {
+    public var unityScripting: UnityScripting?
+    /// Best effort, display only.
+    public var unityVersion: String?
+    public var kirikiriFlavor: KirikiriFlavor?
+    /// An XP3 index entry carries TVP_XP3_FILE_PROTECTED. Not an encryption claim.
+    public var xp3ProtectedFlag: Bool?
+    /// The XP3 index decoded (raw or zlib) and parsed.
+    public var xp3IndexReadable: Bool?
+    /// `.tpm` and `plugin/*.dll` base names, sorted.
+    public var pluginFileNames: [String]
+    public var renpyVersion: RenPyVersion?
+    /// Game-supplied native module base names, sorted.
+    public var renpyNativeExtensions: [String]
+    public var gameMakerBuild: GameMakerBuild?
+
+    public init(unityScripting: UnityScripting? = nil, unityVersion: String? = nil,
+                kirikiriFlavor: KirikiriFlavor? = nil, xp3ProtectedFlag: Bool? = nil,
+                xp3IndexReadable: Bool? = nil, pluginFileNames: [String] = [],
+                renpyVersion: RenPyVersion? = nil, renpyNativeExtensions: [String] = [],
+                gameMakerBuild: GameMakerBuild? = nil) {
+        self.unityScripting = unityScripting
+        self.unityVersion = unityVersion
+        self.kirikiriFlavor = kirikiriFlavor
+        self.xp3ProtectedFlag = xp3ProtectedFlag
+        self.xp3IndexReadable = xp3IndexReadable
+        self.pluginFileNames = pluginFileNames
+        self.renpyVersion = renpyVersion
+        self.renpyNativeExtensions = renpyNativeExtensions
+        self.gameMakerBuild = gameMakerBuild
+    }
+
+    /// Every field is optional on decode: an unknown enum value or a missing array
+    /// reads as absent, so files from other builds still load.
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        unityScripting = try? container.decodeIfPresent(UnityScripting.self, forKey: .unityScripting)
+        unityVersion = try? container.decodeIfPresent(String.self, forKey: .unityVersion)
+        kirikiriFlavor = try? container.decodeIfPresent(KirikiriFlavor.self, forKey: .kirikiriFlavor)
+        xp3ProtectedFlag = try? container.decodeIfPresent(Bool.self, forKey: .xp3ProtectedFlag)
+        xp3IndexReadable = try? container.decodeIfPresent(Bool.self, forKey: .xp3IndexReadable)
+        pluginFileNames = (try? container.decodeIfPresent([String].self, forKey: .pluginFileNames)) ?? []
+        renpyVersion = try? container.decodeIfPresent(RenPyVersion.self, forKey: .renpyVersion)
+        renpyNativeExtensions = (try? container.decodeIfPresent([String].self, forKey: .renpyNativeExtensions)) ?? []
+        gameMakerBuild = try? container.decodeIfPresent(GameMakerBuild.self, forKey: .gameMakerBuild)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/FolderListing.swift b/Packages/EikonCore/Sources/EikonCore/Detection/FolderListing.swift
new file mode 100644
index 0000000..4827e72
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/FolderListing.swift
@@ -0,0 +1,110 @@
+import Foundation
+
+/// One directory's immediate entries, sorted by normalized name. All marker lookups go
+/// through a listing, so they ignore letter case and Unicode normalization form on any
+/// file system. Symlinks are listed but never opened, descended, or matched.
+public struct FolderListing: Sendable {
+    public enum Kind: String, Sendable {
+        case file, directory, symlink
+    }
+
+    public struct Entry: Sendable, Equatable {
+        /// The name as listed.
+        public let name: String
+        /// `FolderListing.normalize(name)`.
+        public let key: String
+        public let kind: Kind
+        public let size: UInt64
+
+        /// The normalized name without its last extension.
+        public var stem: String {
+            guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return key }
+            return String(key[..<dot])
+        }
+
+        /// The normalized last extension, without the dot; "" when there is none.
+        public var pathExtension: String {
+            guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return "" }
+            return String(key[key.index(after: dot)...])
+        }
+    }
+
+    public let url: URL
+    /// Sorted by key, then by listed name.
+    public let entries: [Entry]
+
+    /// Throws `DetectionError.folderUnreadable` when the directory can't be listed.
+    public init(url: URL) throws {
+        let urls: [URL]
+        do {
+            urls = try FileManager.default.contentsOfDirectory(
+                at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
+        } catch {
+            throw DetectionError.folderUnreadable
+        }
+        var entries: [Entry] = []
+        for child in urls {
+            guard let values = try? child.resourceValues(
+                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
+            let kind: Kind
+            if values.isSymbolicLink == true {
+                kind = .symlink
+            } else if values.isDirectory == true {
+                kind = .directory
+            } else if values.isRegularFile == true {
+                kind = .file
+            } else {
+                continue
+            }
+            let name = child.lastPathComponent
+            entries.append(Entry(name: name, key: Self.normalize(name), kind: kind,
+                                 size: UInt64(max(values.fileSize ?? 0, 0))))
+        }
+        self.url = url
+        self.entries = entries.sorted { lhs, rhs in
+            if lhs.key != rhs.key { return lhs.key < rhs.key }
+            return lhs.name.unicodeScalars.lexicographicallyPrecedes(rhs.name.unicodeScalars) { $0.value < $1.value }
+        }
+    }
+
+    /// NFC plus case folding, and nothing else.
+    public static func normalize(_ name: String) -> String {
+        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
+    }
+
+    /// Case- and normalization-insensitive exact lookup of any kind except symlink.
+    public func entry(named name: String) -> Entry? {
+        let key = Self.normalize(name)
+        return entries.first { $0.key == key && $0.kind != .symlink }
+    }
+
+    public func file(named name: String) -> Entry? {
+        entry(named: name).flatMap { $0.kind == .file ? $0 : nil }
+    }
+
+    public func directory(named name: String) -> Entry? {
+        entry(named: name).flatMap { $0.kind == .directory ? $0 : nil }
+    }
+
+    /// Regular files with this extension (no dot), in sorted order.
+    public func files(withExtension ext: String) -> [Entry] {
+        let ext = Self.normalize(ext)
+        return entries.filter { $0.kind == .file && $0.pathExtension == ext }
+    }
+
+    /// Entries matching the predicate, in sorted order.
+    public func entries(matching predicate: (Entry) -> Bool) -> [Entry] {
+        entries.filter(predicate)
+    }
+
+    /// The listing of a subdirectory entry. Throws for anything but a directory.
+    public func listing(of entry: Entry) throws -> FolderListing {
+        guard entry.kind == .directory else { throw DetectionError.folderUnreadable }
+        return try FolderListing(url: url.appendingPathComponent(entry.name, isDirectory: true))
+    }
+}
+
+/// Errors carry codes only: never a path or a name.
+public enum DetectionError: Error, Sendable, Equatable {
+    case folderUnreadable
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/FolderReader.swift b/Packages/EikonCore/Sources/EikonCore/Detection/FolderReader.swift
new file mode 100644
index 0000000..3e6a9d6
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/FolderReader.swift
@@ -0,0 +1,138 @@
+import CEikonSession
+import Darwin
+import Foundation
+
+enum ReadPurpose: Sendable, Hashable {
+    case binaryHeaders, versionResource, xp3Index, chunkHeaders, smallText
+
+    /// Bytes allowed per file, per call and in total.
+    var budget: Int {
+        switch self {
+        case .binaryHeaders: 64 << 10
+        case .versionResource: 256 << 10
+        case .xp3Index: (8 << 20) + (4 << 10) // the compressed index plus its small headers
+        case .chunkHeaders: 8 * 512
+        case .smallText: 64 << 10
+        }
+    }
+}
+
+/// Why a probe stopped. Callers treat every case as "no match".
+enum ReadFailure: Error {
+    case unreadable, budgetExceeded
+}
+
+/// Read-only, budgeted reads under one root. Opens files read-only without following a
+/// final symlink, reads bounded ranges and closes at once. Never writes or sets attributes.
+/// Tracks budgets, so one reader serves one detection pass on one thread.
+final class FolderReader {
+    let root: URL
+    private var used: [Budget: Int] = [:]
+
+    private struct Budget: Hashable {
+        let path: String
+        let purpose: ReadPurpose
+    }
+
+    init(root: URL) {
+        self.root = root
+    }
+
+    /// Up to `length` bytes at `offset`; fewer at the end of the file.
+    func read(_ relativePath: String, offset: UInt64, length: Int, for purpose: ReadPurpose) throws -> Data {
+        guard length >= 0, offset <= UInt64(Int64.max) else { throw ReadFailure.unreadable }
+        let key = Budget(path: relativePath, purpose: purpose)
+        let total = used[key, default: 0] + length
+        guard total <= purpose.budget else { throw ReadFailure.budgetExceeded }
+        used[key] = total
+
+        let fd = url(relativePath).path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
+        guard fd >= 0 else { throw ReadFailure.unreadable }
+        defer { close(fd) }
+
+        var data = Data(count: length)
+        var filled = 0
+        while filled < length {
+            let got = data.withUnsafeMutableBytes { buffer in
+                pread(fd, buffer.baseAddress! + filled, length - filled, off_t(offset) + off_t(filled))
+            }
+            if got < 0 {
+                if errno == EINTR { continue }
+                throw ReadFailure.unreadable
+            }
+            if got == 0 { break }
+            filled += got
+        }
+        data.count = filled
+        return data
+    }
+
+    /// What is left of the budget for this file and purpose.
+    func remainingBudget(_ relativePath: String, for purpose: ReadPurpose) -> Int {
+        purpose.budget - used[Budget(path: relativePath, purpose: purpose), default: 0]
+    }
+
+    /// The size of a regular file (not a symlink), or nil.
+    func size(of relativePath: String) -> UInt64? {
+        var info = stat()
+        guard lstat(url(relativePath).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
+        return UInt64(info.st_size)
+    }
+
+    /// A small text file (within the smallText budget), as UTF-8 or else Latin-1.
+    func text(_ relativePath: String) -> String? {
+        guard let size = size(of: relativePath), size <= UInt64(ReadPurpose.smallText.budget),
+              let data = try? read(relativePath, offset: 0, length: Int(size), for: .smallText) else { return nil }
+        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
+    }
+
+    private func url(_ relativePath: String) -> URL {
+        root.appendingPathComponent(relativePath)
+    }
+
+    /// zlib-wrapped data through system libz, capped at `limit` output bytes. nil on any
+    /// decode failure, a size mismatch, or output over the limit.
+    static func inflateZlib(_ data: Data, expectedSize: Int?, limit: Int) -> Data? {
+        guard !data.isEmpty else { return nil }
+        if let expectedSize, expectedSize > 0 {
+            guard expectedSize <= limit else { return nil }
+            var output = Data(count: expectedSize)
+            var outputLength = uLongf(expectedSize)
+            let status = output.withUnsafeMutableBytes { out in
+                data.withUnsafeBytes { input in
+                    uncompress(out.bindMemory(to: Bytef.self).baseAddress, &outputLength,
+                               input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
+                }
+            }
+            guard status == Z_OK, outputLength == uLongf(expectedSize) else { return nil }
+            return output
+        }
+        return streamInflate(data, limit: limit)
+    }
+
+    private static func streamInflate(_ data: Data, limit: Int) -> Data? {
+        var stream = z_stream()
+        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
+        defer { inflateEnd(&stream) }
+
+        let chunk = 64 << 10
+        var buffer = [UInt8](repeating: 0, count: chunk)
+        var output = Data()
+        return data.withUnsafeBytes { input -> Data? in
+            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
+            stream.avail_in = uInt(input.count)
+            while true {
+                let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
+                    stream.next_out = out.baseAddress
+                    stream.avail_out = uInt(chunk)
+                    return inflate(&stream, Z_NO_FLUSH)
+                }
+                let produced = chunk - Int(stream.avail_out)
+                output.append(contentsOf: buffer[..<produced])
+                if output.count > limit { return nil }
+                if status == Z_STREAM_END { return output }
+                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { return nil }
+            }
+        }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift
new file mode 100644
index 0000000..f4ce25d
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift
@@ -0,0 +1,56 @@
+import Foundation
+
+/// What one engine detector recognized. Executable paths are relative to the game root.
+struct EngineMatch {
+    var engine: Engine
+    var details: EngineDetails
+    var executables: [GamePlatform: String] = [:]
+}
+
+/// Finds the game in a game folder: its engine, details and main executables. Read-only,
+/// never logs, and deterministic regardless of directory listing order.
+public enum GameDetector {
+    /// Bump whenever detection logic changes; stored results with an older version are recomputed.
+    public static let version = 1
+
+    /// Detects the game in a game folder (an immediate child of a game drive). Checks the
+    /// folder itself; if no engine markers or executable are there and the folder holds
+    /// exactly one subfolder that does, that subfolder is the game root. Read-only.
+    /// Returns nil when no game is found; throws only when the folder can't be listed.
+    public static func detect(folder: URL) throws -> DetectionResult? {
+        var tally = ExclusionTally()
+        return try detect(folder: folder, tally: &tally)
+    }
+
+    /// Same, also adding exclusion-rule hits to `tally` (used by the collection scanner).
+    public static func detect(folder: URL, tally: inout ExclusionTally) throws -> DetectionResult? {
+        let listing = try FolderListing(url: folder)
+        if let result = evaluate(listing, tally: &tally) { return result }
+
+        let subfolders = listing.entries.filter { $0.kind == .directory && !$0.name.hasPrefix(".") }
+        guard subfolders.count == 1, let inner = try? listing.listing(of: subfolders[0]),
+              var result = evaluate(inner, tally: &tally) else { return nil }
+        result.gameRoot = subfolders[0].name
+        return result
+    }
+
+    /// Most specific layout first, so a Ren'Py or Unity game that ships an .xp3 or .arc
+    /// is not misread.
+    private static let detectors: [@Sendable (FolderListing, FolderReader) -> EngineMatch?] = [
+        RenPyDetector.detect, UnityDetector.detect, KirikiriDetector.detect, GameMakerDetector.detect, BGIDetector.detect,
+    ]
+
+    private static func evaluate(_ listing: FolderListing, tally: inout ExclusionTally) -> DetectionResult? {
+        let reader = FolderReader(root: listing.url)
+        let match = detectors.lazy.compactMap { $0(listing, reader) }.first
+        let executables = MainExecutable.select(listing, reader, preferred: match?.executables ?? [:], tally: &tally)
+        guard match != nil || !executables.isEmpty else { return nil }
+
+        var details = match?.details ?? EngineDetails()
+        if match?.engine == .kirikiri, let exe = executables[.windows] {
+            details.kirikiriFlavor = KirikiriDetector.flavor(reader, executable: exe.path)
+        }
+        return DetectionResult(engine: match?.engine ?? .unknown, details: details, gameRoot: "",
+                               executables: executables, keyFile: nil, detectorVersion: version)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/GameMakerDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/GameMakerDetector.swift
new file mode 100644
index 0000000..e2c479c
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/GameMakerDetector.swift
@@ -0,0 +1,28 @@
+import Foundation
+
+enum GameMakerDetector {
+    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
+        for name in ["data.win", "game.unx"] {
+            guard let file = listing.file(named: name),
+                  let header = try? reader.read(file.name, offset: 0, length: 12, for: .chunkHeaders),
+                  header.hasBytes(Array("FORM".utf8)), header.hasBytes(Array("GEN8".utf8), at: 8) else { continue }
+            return EngineMatch(engine: .gameMaker,
+                               details: EngineDetails(gameMakerBuild: hasCode(reader, path: file.name) ? .vm : .yyc))
+        }
+        return nil
+    }
+
+    /// Walks the 8-byte chunk headers from offset 8. A present, non-empty CODE chunk means
+    /// VM; stops at the end, at a size that overruns the file, or when the budget runs out.
+    private static func hasCode(_ reader: FolderReader, path: String) -> Bool {
+        guard let fileSize = reader.size(of: path) else { return false }
+        var offset: UInt64 = 8
+        while offset + 8 <= fileSize,
+              let header = try? reader.read(path, offset: offset, length: 8, for: .chunkHeaders),
+              let size = header.uint32LE(at: 4) {
+            if header.hasBytes(Array("CODE".utf8)) { return size > 0 }
+            offset += 8 + UInt64(size)
+        }
+        return false
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/KirikiriDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/KirikiriDetector.swift
new file mode 100644
index 0000000..a703819
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/KirikiriDetector.swift
@@ -0,0 +1,125 @@
+import Foundation
+
+enum KirikiriDetector {
+    static let xp3Magic: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01]
+    private static let protectedBit: UInt32 = 0x8000_0000
+    private static let decodedIndexLimit = 64 << 20
+
+    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
+        let archives = listing.files(withExtension: "xp3").filter { entry in
+            (try? reader.read(entry.name, offset: 0, length: xp3Magic.count, for: .xp3Index))?.hasBytes(xp3Magic) ?? false
+        }
+        guard !archives.isEmpty else { return nil }
+
+        let largest = archives.min { lhs, rhs in lhs.size != rhs.size ? lhs.size > rhs.size : lhs.key < rhs.key }
+        guard let main = archives.first(where: { $0.key == "data.xp3" }) ?? largest else { return nil }
+        let index = readIndex(reader, path: main.name)
+        let details = EngineDetails(kirikiriFlavor: .unknown,
+                                    xp3ProtectedFlag: index.map(hasProtectedEntry),
+                                    xp3IndexReadable: index != nil,
+                                    pluginFileNames: plugins(listing))
+        return EngineMatch(engine: .kirikiri, details: details)
+    }
+
+    // MARK: Flavor
+
+    private static let markers: [(text: String, flavor: KirikiriFlavor)] = [
+        ("TVP(KIRIKIRI) Z", .krkrZ), ("TVP(KIRIKIRI) 2", .krkr2),
+    ]
+
+    /// From the exe's version resource, else a bounded string scan of its .rsrc (or its start).
+    static func flavor(_ reader: FolderReader, executable path: String) -> KirikiriFlavor {
+        let strings = PEVersionResource.strings(reader, path: path)
+        for key in ["ProductName", "FileDescription"] {
+            if let value = strings[key]?.uppercased(), let marker = markers.first(where: { value.contains($0.text) }) {
+                return marker.flavor
+            }
+        }
+        let range = PEVersionResource.rsrcRange(reader, path: path) ?? (0, Int.max)
+        let length = min(range.length, reader.remainingBudget(path, for: .versionResource))
+        guard length > 0, let bytes = try? reader.read(path, offset: range.offset, length: length, for: .versionResource)
+        else { return .unknown }
+        for marker in markers {
+            let ascii = Array(marker.text.utf8)
+            let utf16 = ascii.flatMap { byte -> [UInt8] in [byte, 0] }
+            if bytes.range(of: Data(ascii)) != nil || bytes.range(of: Data(utf16)) != nil { return marker.flavor }
+        }
+        return .unknown
+    }
+
+    // MARK: Plugins
+
+    /// .tpm base names in the root and one level of subfolders, plus plugin/*.dll.
+    private static func plugins(_ listing: FolderListing) -> [String] {
+        var names = Set(listing.files(withExtension: "tpm").map(\.name))
+        for dir in listing.entries where dir.kind == .directory {
+            guard let contents = try? listing.listing(of: dir) else { continue }
+            names.formUnion(contents.files(withExtension: "tpm").map(\.name))
+            if dir.key == "plugin" { names.formUnion(contents.files(withExtension: "dll").map(\.name)) }
+        }
+        return names.sorted()
+    }
+
+    // MARK: Index
+
+    /// The decoded index, following one continuation header. nil when it can't be decoded
+    /// and walked within the budget.
+    private static func readIndex(_ reader: FolderReader, path: String) -> Data? {
+        guard let start = try? reader.read(path, offset: 11, length: 8, for: .xp3Index),
+              var offset = start.uint64LE(at: 0) else { return nil }
+        for _ in 0..<2 {
+            guard let header = try? reader.read(path, offset: offset, length: 17, for: .xp3Index),
+                  let flag = header.uint8(at: 0) else { return nil }
+            let index: Data
+            let end: UInt64
+            switch flag & 0x07 {
+            case 0:
+                guard let size = header.uint64LE(at: 1), size <= UInt64(ReadPurpose.xp3Index.budget) else { return nil }
+                index = (try? reader.read(path, offset: offset + 9, length: Int(size), for: .xp3Index)) ?? Data()
+                guard index.count == Int(size) else { return nil }
+                end = offset + 9 + size
+            case 1:
+                guard let packed = header.uint64LE(at: 1), let unpacked = header.uint64LE(at: 9),
+                      packed <= UInt64(ReadPurpose.xp3Index.budget), unpacked <= UInt64(decodedIndexLimit),
+                      let compressed = try? reader.read(path, offset: offset + 17, length: Int(packed), for: .xp3Index),
+                      compressed.count == Int(packed),
+                      let inflated = FolderReader.inflateZlib(compressed, expectedSize: Int(unpacked), limit: decodedIndexLimit)
+                else { return nil }
+                index = inflated
+                end = offset + 17 + packed
+            default:
+                return nil
+            }
+            guard flag & 0x80 != 0 else { return walk(index) ? index : nil }
+            guard let next = try? reader.read(path, offset: end, length: 8, for: .xp3Index),
+                  let nextOffset = next.uint64LE(at: 0) else { return nil }
+            offset = nextOffset
+        }
+        return nil
+    }
+
+    /// Chunks of a 4-byte tag and a UInt64 size that exactly tile `data`, visiting each.
+    @discardableResult
+    private static func walk(_ data: Data, _ visit: (String, Data) -> Void = { _, _ in }) -> Bool {
+        var cursor = 0
+        while cursor < data.count {
+            guard let size = data.uint64LE(at: cursor + 4), size <= UInt64(data.count - cursor - 12) else { return false }
+            let tag = String(decoding: data[(data.startIndex + cursor)..<(data.startIndex + cursor + 4)], as: UTF8.self)
+            let bodyStart = data.startIndex + cursor + 12
+            visit(tag, data[bodyStart..<(bodyStart + Int(size))])
+            cursor += 12 + Int(size)
+        }
+        return true
+    }
+
+    private static func hasProtectedEntry(_ index: Data) -> Bool {
+        var found = false
+        walk(index) { tag, body in
+            guard tag == "File" else { return }
+            walk(Data(body)) { tag, body in
+                if tag == "info", let flags = Data(body).uint32LE(at: 0), flags & protectedBit != 0 { found = true }
+            }
+        }
+        return found
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/MainExecutable.swift b/Packages/EikonCore/Sources/EikonCore/Detection/MainExecutable.swift
new file mode 100644
index 0000000..c68316c
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/MainExecutable.swift
@@ -0,0 +1,131 @@
+import Foundation
+
+/// One exclusion rule: a pattern over the normalized file name. Raw values are pattern
+/// codes, never file names.
+public enum ExclusionRule: String, Sendable, CaseIterable {
+    case unins
+    case unityCrashHandler = "unitycrashhandler"
+    case vcRedist = "vc_redist"
+    case vcredist
+    case dxsetup
+    case dotnet
+    case ndp
+    case notificationHelper = "notification_helper"
+    case crashpadHandler = "crashpad_handler"
+    case crashReport = "crashreport"
+    case oalinst
+    case ue4PrereqSetup = "ue4prereqsetup"
+    case python
+    case zsync
+    case renpyExe = "renpy.exe"
+    case setup
+    case install
+    /// A PE carrying the DLL characteristic.
+    case dll
+
+    private enum Match { case prefix, stem, name, contains }
+
+    /// Specific rules come before the generic `*setup*` and `*install*`, so each file
+    /// counts against the rule that names it most precisely.
+    private var match: Match? {
+        switch self {
+        case .unins, .unityCrashHandler, .vcRedist, .vcredist, .dotnet, .ndp, .crashReport,
+             .ue4PrereqSetup, .python, .zsync: .prefix
+        case .dxsetup, .notificationHelper, .crashpadHandler, .oalinst: .stem
+        case .renpyExe: .name
+        case .setup, .install: .contains
+        case .dll: nil
+        }
+    }
+
+    /// The first name rule that removes this file.
+    static func nameRule(for entry: FolderListing.Entry) -> ExclusionRule? {
+        allCases.first { rule in
+            switch rule.match {
+            case .prefix: entry.key.hasPrefix(rule.rawValue)
+            case .stem: entry.stem == rule.rawValue
+            case .name: entry.key == rule.rawValue
+            case .contains: entry.key.contains(rule.rawValue)
+            case nil: false
+            }
+        }
+    }
+}
+
+/// How many candidate files each exclusion rule removed.
+public struct ExclusionTally: Sendable, Equatable {
+    public private(set) var hits: [ExclusionRule: Int] = [:]
+
+    public init() {}
+
+    public mutating func add(_ rule: ExclusionRule) {
+        hits[rule, default: 0] += 1
+    }
+
+    public mutating func merge(_ other: ExclusionTally) {
+        hits.merge(other.hits, uniquingKeysWith: +)
+    }
+}
+
+enum MainExecutable {
+    /// Extensions probed for the ELF magic. Anything else in the root is a data file.
+    private static let linuxExtensions: Set<String> = ["", "x86_64", "x86", "x64", "amd64", "bin", "elf", "aarch64", "arm64"]
+
+    /// The main executable per platform. An engine-chosen path wins when it is a real
+    /// executable of that platform's format; otherwise GUI beats console, then the larger
+    /// file, then the normalized name.
+    static func select(_ listing: FolderListing, _ reader: FolderReader, preferred: [GamePlatform: String],
+                       tally: inout ExclusionTally) -> [GamePlatform: ExecutableInfo] {
+        var candidates: [GamePlatform: [(entry: FolderListing.Entry, binary: ParsedBinary)]] = [:]
+        for entry in listing.entries where entry.kind == .file {
+            let platform: GamePlatform
+            if entry.pathExtension == "exe" {
+                platform = .windows
+            } else if linuxExtensions.contains(entry.pathExtension), BinaryInfo.hasELFMagic(reader, path: entry.name) {
+                platform = .linux
+            } else {
+                continue
+            }
+            guard let binary = BinaryInfo.parse(reader, path: entry.name),
+                  binary.format == format(of: platform) else { continue }
+            if let rule = ExclusionRule.nameRule(for: entry) {
+                tally.add(rule)
+                continue
+            }
+            if binary.isDLL {
+                tally.add(.dll)
+                continue
+            }
+            candidates[platform, default: []].append((entry, binary))
+        }
+
+        var result: [GamePlatform: ExecutableInfo] = [:]
+        for platform in GamePlatform.allCases {
+            if let path = preferred[platform], let binary = BinaryInfo.parse(reader, path: path),
+               binary.format == format(of: platform), !binary.isDLL {
+                result[platform] = info(path: path, binary)
+                continue
+            }
+            let best = candidates[platform]?.min { lhs, rhs in
+                let lhsGUI = lhs.binary.isGUI ?? false, rhsGUI = rhs.binary.isGUI ?? false
+                if lhsGUI != rhsGUI { return lhsGUI }
+                if lhs.entry.size != rhs.entry.size { return lhs.entry.size > rhs.entry.size }
+                return lhs.entry.key < rhs.entry.key
+            }
+            if let best { result[platform] = info(path: best.entry.name, best.binary) }
+        }
+        return result
+    }
+
+    private static func format(of platform: GamePlatform) -> BinaryFormat {
+        switch platform {
+        case .windows: .pe
+        case .linux: .elf
+        }
+    }
+
+    private static func info(path: String, _ binary: ParsedBinary) -> ExecutableInfo {
+        ExecutableInfo(path: path, format: binary.format, architecture: binary.architecture,
+                       machine: binary.machine, isGUI: binary.isGUI)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/PEVersionResource.swift b/Packages/EikonCore/Sources/EikonCore/Detection/PEVersionResource.swift
new file mode 100644
index 0000000..9b2e28b
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/PEVersionResource.swift
@@ -0,0 +1,123 @@
+import Foundation
+
+/// The `StringFileInfo` strings (ProductName, FileDescription, CompanyName, …) of a PE's
+/// VS_VERSIONINFO resource. Reads at most the versionResource budget; anything malformed
+/// gives an empty dictionary.
+public enum PEVersionResource {
+    public static func strings(ofFile url: URL) -> [String: String] {
+        strings(FolderReader(root: url.deletingLastPathComponent()), path: url.lastPathComponent)
+    }
+
+    static func strings(_ reader: FolderReader, path: String) -> [String: String] {
+        guard let binary = BinaryInfo.parse(reader, path: path), binary.format == .pe,
+              let rsrc = binary.sections.first(where: { $0.name == ".rsrc" }),
+              let blob = try? versionInfo(reader, path: path, rsrc: rsrc) else { return [:] }
+        return stringTable(blob)
+    }
+
+    /// The .rsrc range of the file that holds the resource data, if the section has one.
+    static func rsrcRange(_ reader: FolderReader, path: String) -> (offset: UInt64, length: Int)? {
+        guard let binary = BinaryInfo.parse(reader, path: path),
+              let rsrc = binary.sections.first(where: { $0.name == ".rsrc" }), rsrc.rawSize > 0 else { return nil }
+        return (UInt64(rsrc.rawPointer), Int(rsrc.rawSize))
+    }
+
+    // MARK: Resource directory
+
+    private static let rtVersion: UInt32 = 16
+
+    private struct DirectoryEntry {
+        let id: UInt32
+        let isNamed: Bool
+        let target: UInt32
+        let isDirectory: Bool
+    }
+
+    private static func versionInfo(_ reader: FolderReader, path: String, rsrc: PESection) throws -> Data? {
+        func read(_ offset: UInt32, _ length: Int) throws -> Data {
+            guard UInt64(offset) + UInt64(length) <= UInt64(rsrc.rawSize) else { throw ReadFailure.unreadable }
+            let data = try reader.read(path, offset: UInt64(rsrc.rawPointer) + UInt64(offset), length: length,
+                                       for: .versionResource)
+            guard data.count == length else { throw ReadFailure.unreadable }
+            return data
+        }
+        func entries(_ offset: UInt32) throws -> [DirectoryEntry] {
+            let header = try read(offset, 16)
+            let count = Int(header.uint16LE(at: 12)!) + Int(header.uint16LE(at: 14)!)
+            let table = try read(offset + 16, min(count, 256) * 8)
+            return (0..<(table.count / 8)).map { index in
+                let name = table.uint32LE(at: index * 8)!
+                let target = table.uint32LE(at: index * 8 + 4)!
+                return DirectoryEntry(id: name & 0x7FFF_FFFF, isNamed: name & 0x8000_0000 != 0,
+                                      target: target & 0x7FFF_FFFF, isDirectory: target & 0x8000_0000 != 0)
+            }
+        }
+
+        guard let type = try entries(0).first(where: { !$0.isNamed && $0.id == rtVersion && $0.isDirectory }),
+              let name = try entries(type.target).first(where: \.isDirectory),
+              let language = try entries(name.target).first(where: { !$0.isDirectory }) else { return nil }
+        let dataEntry = try read(language.target, 16)
+        let rva = dataEntry.uint32LE(at: 0)!
+        let size = dataEntry.uint32LE(at: 4)!
+        guard rva >= rsrc.virtualAddress, size > 0 else { return nil }
+        return try read(rva - rsrc.virtualAddress, Int(size))
+    }
+
+    // MARK: VS_VERSIONINFO
+
+    private struct Block {
+        let key: String
+        let valueStart: Int
+        let valueLength: Int
+        let end: Int
+    }
+
+    /// wLength, wValueLength, wType, then a NUL-terminated UTF-16LE key padded to 32 bits.
+    private static func block(_ data: Data, at start: Int, limit: Int) -> Block? {
+        guard start + 6 <= limit, let length = data.uint16LE(at: start),
+              let valueLength = data.uint16LE(at: start + 2), length >= 6, start + Int(length) <= limit else { return nil }
+        let end = start + Int(length)
+        var units: [UInt16] = []
+        var cursor = start + 6
+        while cursor + 2 <= end, let unit = data.uint16LE(at: cursor) {
+            cursor += 2
+            if unit == 0 { break }
+            units.append(unit)
+        }
+        return Block(key: String(decoding: units, as: UTF16.self), valueStart: align(cursor),
+                     valueLength: Int(valueLength), end: end)
+    }
+
+    private static func children(_ data: Data, of parent: Block, valueBytes: Int) -> [Block] {
+        var result: [Block] = []
+        var cursor = align(parent.valueStart + valueBytes)
+        while cursor < parent.end, let child = block(data, at: cursor, limit: parent.end) {
+            result.append(child)
+            cursor = align(child.end)
+        }
+        return result
+    }
+
+    private static func stringTable(_ data: Data) -> [String: String] {
+        guard let root = block(data, at: 0, limit: data.count), root.key == "VS_VERSION_INFO",
+              let fileInfo = children(data, of: root, valueBytes: root.valueLength)
+                .first(where: { $0.key == "StringFileInfo" }),
+              let table = children(data, of: fileInfo, valueBytes: 0).first else { return [:] }
+
+        var strings: [String: String] = [:]
+        for string in children(data, of: table, valueBytes: 0) {
+            var units: [UInt16] = []
+            var cursor = string.valueStart
+            while cursor + 2 <= string.end, let unit = data.uint16LE(at: cursor), unit != 0 {
+                units.append(unit)
+                cursor += 2
+            }
+            strings[string.key] = String(decoding: units, as: UTF16.self)
+        }
+        return strings
+    }
+
+    private static func align(_ offset: Int) -> Int {
+        (offset + 3) & ~3
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/RenPyDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/RenPyDetector.swift
new file mode 100644
index 0000000..4263b2e
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/RenPyDetector.swift
@@ -0,0 +1,117 @@
+import Foundation
+
+enum RenPyDetector {
+    private static let nativeExtensions: Set<String> = ["pyd", "so", "dll", "dylib"]
+    private static let walkDepth = 8
+    private static let walkEntries = 20_000
+
+    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
+        guard let renpy = listing.directory(named: "renpy"), let game = listing.directory(named: "game"),
+              let renpyListing = try? listing.listing(of: renpy),
+              let gameListing = try? listing.listing(of: game) else { return nil }
+        let lib = listing.directory(named: "lib")
+        let hasInit = ["__init__.py", "__init__.pyc", "__init__.pyo"].contains { renpyListing.file(named: $0) != nil }
+        let hasScripts = !gameListing.files(withExtension: "rpyc").isEmpty || !gameListing.files(withExtension: "rpa").isEmpty
+        guard hasInit || hasScripts || lib != nil else { return nil }
+
+        let libListing = lib.flatMap { try? listing.listing(of: $0) }
+        let details = EngineDetails(
+            renpyVersion: version(reader, renpy: renpy.name, game: game.name, lib: libListing),
+            renpyNativeExtensions: nativeModules(in: gameListing))
+        return EngineMatch(engine: .renpy, details: details,
+                           executables: executables(listing, reader, lib: libListing))
+    }
+
+    // MARK: Version
+
+    private static func version(_ reader: FolderReader, renpy: String, game: String,
+                                lib: FolderListing?) -> RenPyVersion? {
+        if let text = reader.text("\(game)/script_version.txt"),
+           let numbers = integers(in: text, after: nil), numbers.count >= 2 {
+            return .exact(numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
+        }
+        if let text = reader.text("\(renpy)/vc_version.py"),
+           let numbers = integers(in: text, after: #"(?m)^\s*version\s*=\s*["']"#), numbers.count >= 2 {
+            return .exact(numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
+        }
+        if let text = reader.text("\(renpy)/__init__.py"),
+           let numbers = integers(in: text, after: #"(?m)^\s*version_tuple\s*=\s*\w*\s*\("#), numbers.count >= 2 {
+            return .exact(numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
+        }
+        return lib.flatMap(era)
+    }
+
+    /// Up to three integers separated by `.` or `,` right after the first match of `prefix`
+    /// (or at the first digit when `prefix` is nil).
+    private static func integers(in text: String, after prefix: String?) -> [Int]? {
+        let pattern = (prefix ?? #"[^0-9]*"#) + #"(\d+)\s*[.,]\s*(\d+)(?:\s*[.,]\s*(\d+))?"#
+        guard let regex = try? NSRegularExpression(pattern: pattern),
+              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
+        return (1...3).compactMap { group in
+            Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }
+        }
+    }
+
+    private static func era(_ lib: FolderListing) -> RenPyVersion? {
+        let names = lib.entries.filter { $0.kind == .directory }.map(\.key)
+        func has(_ prefix: String) -> Bool { names.contains { $0.hasPrefix(prefix) } }
+        if names.contains("python3.12") { return .era(from: (8, 4), through: nil) }
+        if has("py3-"), names.contains("python3.9") { return .era(from: (8, 0), through: (8, 3)) }
+        if has("py2-") { return .era(from: (7, 4), through: nil) }
+        if has("windows-") || has("linux-"), names.contains("pythonlib2.7") { return .era(from: (0, 0), through: (7, 3)) }
+        return nil
+    }
+
+    // MARK: Native modules
+
+    /// Base names of native modules anywhere under game/, sorted and de-duplicated.
+    private static func nativeModules(in game: FolderListing) -> [String] {
+        var found = Set<String>()
+        var budget = walkEntries
+        func walk(_ listing: FolderListing, depth: Int) {
+            for entry in listing.entries {
+                budget -= 1
+                guard budget >= 0 else { return }
+                switch entry.kind {
+                case .file where nativeExtensions.contains(entry.pathExtension):
+                    found.insert(entry.name)
+                case .directory where depth < walkDepth:
+                    if let child = try? listing.listing(of: entry) { walk(child, depth: depth + 1) }
+                case .file, .directory, .symlink:
+                    break
+                }
+            }
+        }
+        walk(game, depth: 0)
+        return found.sorted()
+    }
+
+    // MARK: Executables
+
+    /// Windows: the root .exe beside a same-stem .py. Linux: the ELF of that stem under
+    /// lib/py*-linux-x86_64/ or lib/linux-x86_64/, never the .sh launcher.
+    private static func executables(_ listing: FolderListing, _ reader: FolderReader,
+                                    lib: FolderListing?) -> [GamePlatform: String] {
+        let stems = Set(listing.files(withExtension: "py").map(\.stem))
+        var result: [GamePlatform: String] = [:]
+        if let exe = listing.files(withExtension: "exe").first(where: { stems.contains($0.stem) }) {
+            result[.windows] = exe.name
+        }
+        if let lib {
+            let linuxDirs = lib.entries.filter {
+                $0.kind == .directory && ($0.key == "linux-x86_64" || ($0.key.hasPrefix("py") && $0.key.hasSuffix("-linux-x86_64")))
+            }
+            search: for dir in linuxDirs {
+                guard let contents = try? lib.listing(of: dir) else { continue }
+                for entry in contents.entries where entry.kind == .file && stems.contains(entry.key) {
+                    let path = "\(lib.url.lastPathComponent)/\(dir.name)/\(entry.name)"
+                    if BinaryInfo.hasELFMagic(reader, path: path) {
+                        result[.linux] = path
+                        break search
+                    }
+                }
+            }
+        }
+        return result
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Detection/UnityDetector.swift b/Packages/EikonCore/Sources/EikonCore/Detection/UnityDetector.swift
new file mode 100644
index 0000000..babdf73
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Detection/UnityDetector.swift
@@ -0,0 +1,76 @@
+import Foundation
+
+enum UnityDetector {
+    private static let dataMarkers = ["globalgamemanagers", "mainData", "data.unity3d"]
+
+    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
+        let hasPlayer = listing.file(named: "UnityPlayer.dll") != nil || listing.file(named: "UnityPlayer.so") != nil
+        let dataDirs: [(entry: FolderListing.Entry, stem: String, listing: FolderListing)] = listing.entries.compactMap { entry in
+            guard entry.kind == .directory, entry.key.hasSuffix("_data"),
+                  let contents = try? listing.listing(of: entry) else { return nil }
+            return (entry, String(entry.key.dropLast("_data".count)), contents)
+        }
+        let markedDirs = dataDirs.filter { dir in dataMarkers.contains { dir.listing.file(named: $0) != nil } }
+        guard hasPlayer || !markedDirs.isEmpty else { return nil }
+
+        var executables: [GamePlatform: String] = [:]
+        var paired: (entry: FolderListing.Entry, stem: String, listing: FolderListing)?
+        for dir in dataDirs {
+            if let exe = listing.file(named: dir.stem + ".exe") {
+                executables[.windows] = executables[.windows] ?? exe.name
+                paired = paired ?? dir
+            }
+            if let elf = listing.file(named: dir.stem + ".x86_64"), BinaryInfo.hasELFMagic(reader, path: elf.name) {
+                executables[.linux] = executables[.linux] ?? elf.name
+                paired = paired ?? dir
+            }
+        }
+        let data = paired ?? markedDirs.first ?? dataDirs.first
+
+        let details = EngineDetails(unityScripting: data.flatMap { scripting(listing, data: $0.listing) },
+                                    unityVersion: data.flatMap { version(reader, dataDir: $0.entry.name, listing: $0.listing) })
+        return EngineMatch(engine: .unity, details: details, executables: executables)
+    }
+
+    private static func scripting(_ listing: FolderListing, data: FolderListing) -> UnityScripting? {
+        if listing.file(named: "GameAssembly.dll") != nil || listing.file(named: "GameAssembly.so") != nil
+            || data.directory(named: "il2cpp_data") != nil {
+            return .il2cpp
+        }
+        if let managed = data.directory(named: "Managed"), let contents = try? data.listing(of: managed),
+           contents.file(named: "Assembly-CSharp.dll") != nil {
+            return .mono
+        }
+        return nil
+    }
+
+    /// Best effort, from a SerializedFile header or the UnityFS bundle header.
+    private static func version(_ reader: FolderReader, dataDir: String, listing: FolderListing) -> String? {
+        for name in ["globalgamemanagers", "mainData"] {
+            guard let file = listing.file(named: name),
+                  let header = try? reader.read("\(dataDir)/\(file.name)", offset: 0, length: 0x70, for: .binaryHeaders),
+                  let format = header.uint32BE(at: 0x08) else { continue }
+            let offset: Int
+            switch format {
+            case 9...21: offset = 0x14
+            case 22...: offset = 0x30
+            default: continue
+            }
+            if let version = plausible(header.nulTerminatedString(at: offset, maxLength: 32)) { return version }
+        }
+        if let file = listing.file(named: "data.unity3d"),
+           let header = try? reader.read("\(dataDir)/\(file.name)", offset: 0, length: 0x60, for: .binaryHeaders),
+           header.hasBytes(Array("UnityFS\0".utf8)),
+           let player = header.nulTerminatedString(at: 12, maxLength: 32) {
+            return plausible(header.nulTerminatedString(at: 12 + player.utf8.count + 1, maxLength: 32))
+        }
+        return nil
+    }
+
+    /// Looks like "2019.4.1f1" or "5.6.0p3": digits and dots, then a release letter.
+    private static func plausible(_ version: String?) -> String? {
+        guard let version, let first = version.first, first.isNumber, version.contains("."),
+              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else { return nil }
+        return version
+    }
+}
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/DetectionTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/DetectionTests.swift
new file mode 100644
index 0000000..f30cde5
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/DetectionTests.swift
@@ -0,0 +1,330 @@
+import Foundation
+import Testing
+import EikonCore
+
+private func withTempDir(_ body: (URL) throws -> Void) throws {
+    let dir = try Fixtures.tempDir()
+    defer { try? FileManager.default.removeItem(at: dir) }
+    try body(dir)
+}
+
+private func detect(_ url: URL) throws -> DetectionResult? {
+    try GameDetector.detect(folder: url)
+}
+
+private func samePath(_ lhs: String?, _ rhs: String) -> Bool {
+    lhs.map(FolderListing.normalize) == FolderListing.normalize(rhs)
+}
+
+// MARK: Types and entry point
+
+@Test func emptyFolderIsNoGame() throws {
+    let dir = try Fixtures.tempDir()
+    defer { try? FileManager.default.removeItem(at: dir) }
+    #expect(try detect(dir) == nil)
+}
+
+@Test(arguments: [
+    (Fixtures.peI386, CPUArchitecture.i386), (Fixtures.peAMD64, .amd64), (0xAA64, .arm64),
+    (0xA641, .arm64), (0xA64E, .arm64), (0x01C4, .other),
+])
+func loneExeIsUnknownEngineWithItsArchitecture(machine: UInt16, architecture: CPUArchitecture) throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.pe(machine: machine), to: "Game.exe", in: dir)
+        let result = try #require(try detect(dir))
+        #expect(result.engine == .unknown)
+        #expect(result.executables[.windows]?.architecture == architecture)
+    }
+}
+
+@Test func singleWrapperFolderIsFollowed() throws {
+    try withTempDir { dir in
+        let inner = try Fixtures.unity(.mono, named: "Inner", in: dir)
+        try Fixtures.write("notes", to: "readme.txt", in: dir)
+        let result = try #require(try detect(dir))
+        #expect(result.engine == .unity)
+        #expect(result.gameRoot == inner.lastPathComponent)
+    }
+}
+
+@Test func wrapperHoldingTwoGamesIsNotAccepted() throws {
+    try withTempDir { dir in
+        _ = try Fixtures.unity(.mono, named: "First", in: dir)
+        _ = try Fixtures.kirikiri(flavor: nil, named: "Second", in: dir)
+        #expect(try detect(dir) == nil)
+    }
+}
+
+@Test func storedResultWithUnknownValuesDecodesToFallbacks() throws {
+    try withTempDir { dir in
+        let result = try #require(try detect(try Fixtures.unity(.mono, in: dir)))
+        var json = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
+        json = json.replacingOccurrences(of: "\"\(Engine.unity.rawValue)\"", with: "\"futureEngine\"")
+        json = json.replacingOccurrences(of: "\"\(CPUArchitecture.amd64.rawValue)\"", with: "\"futureArch\"")
+        let decoded = try JSONDecoder().decode(DetectionResult.self, from: Data(json.utf8))
+        #expect(decoded.engine == .unknown)
+        #expect(decoded.executables[.windows]?.architecture == .other)
+    }
+}
+
+@Test func resultDoesNotDependOnListingOrder() throws {
+    try withTempDir { dir in
+        let names = ["Alpha.exe", "Beta.exe", "data.xp3", "extra.tpm"]
+        func build(_ folder: String, _ order: [String]) throws -> URL {
+            let root = dir.appendingPathComponent(folder)
+            for name in order {
+                let data = name.hasSuffix(".exe") ? Fixtures.pe(machine: Fixtures.peI386)
+                    : name.hasSuffix(".xp3") ? Fixtures.xp3(index: .raw) : Data(count: 4)
+                try Fixtures.write(data, to: name, in: root)
+            }
+            return root
+        }
+        let forward = try detect(try build("One", names))
+        let backward = try detect(try build("Two", names.reversed()))
+        #expect(forward != nil)
+        #expect(forward == backward)
+    }
+}
+
+// MARK: FolderListing / FolderReader
+
+@Test func markersAreFoundInAnyLetterCase() throws {
+    try withTempDir { dir in
+        let unity = dir.appendingPathComponent("U")
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, dll: true), to: "unityplayer.DLL", in: unity)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64), to: "Game.exe", in: unity)
+        let kirikiri = dir.appendingPathComponent("K")
+        try Fixtures.write(Fixtures.xp3(index: .raw), to: "DATA.XP3", in: kirikiri)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: kirikiri)
+
+        #expect(try detect(unity)?.engine == .unity)
+        let result = try #require(try detect(kirikiri))
+        #expect(result.engine == .kirikiri)
+        #expect(result.details.xp3IndexReadable == true)
+    }
+}
+
+@Test func stemsPairAcrossUnicodeNormalizationForms() throws {
+    try withTempDir { dir in
+        let stem = "Caf\u{E9}"
+        let exe = stem.precomposedStringWithCanonicalMapping + ".exe"
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64), to: exe, in: dir)
+        try Fixtures.write(Data(count: 64),
+                           to: stem.decomposedStringWithCanonicalMapping + "_Data/globalgamemanagers", in: dir)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, padTo: 64 << 10), to: "Zeta.exe", in: dir)
+        let result = try #require(try detect(dir))
+        #expect(result.engine == .unity)
+        #expect(samePath(result.executables[.windows]?.path, exe))
+    }
+}
+
+@Test(arguments: [false, true])
+func zlibCompressedXP3IndexDecodes(continuation: Bool) throws {
+    try withTempDir { dir in
+        let root = try Fixtures.kirikiri(flavor: nil, index: .zlib, continuation: continuation, in: dir)
+        #expect(try detect(root)?.details.xp3IndexReadable == true)
+    }
+}
+
+// MARK: Ren'Py
+
+@Test(arguments: [
+    (Fixtures.RenPyEra.scriptVersion, RenPyVersionKind.exact), (.vcVersion, .exact), (.initPy, .exact), (.libEra, .era),
+])
+func renpyEraLayoutsReportTheirVersionKind(era: Fixtures.RenPyEra, kind: RenPyVersionKind) throws {
+    try withTempDir { dir in
+        let version = [6, 99, 14]
+        let result = try #require(try detect(try Fixtures.renpy(era, version: version, in: dir)))
+        #expect(result.engine == .renpy)
+        let detected = try #require(result.details.renpyVersion)
+        #expect(detected.kind == kind)
+        if kind == .exact {
+            #expect([detected.major, detected.minor, detected.patch] == version)
+        }
+    }
+}
+
+@Test func renpyListsGameNativeModulesButNotEngineFiles() throws {
+    try withTempDir { dir in
+        let root = try Fixtures.renpy(.libEra, in: dir)
+        let game = ["fastpath.so", "helper.pyd"]
+        try Fixtures.write(Data(count: 4), to: "game/python-packages/pkg/\(game[0])", in: root)
+        try Fixtures.write(Data(count: 4), to: "game/\(game[1])", in: root)
+        try Fixtures.write(Data(count: 4), to: "lib/py3-windows-x86_64/engine.dll", in: root)
+        let result = try #require(try detect(root))
+        #expect(result.details.renpyNativeExtensions == game.sorted())
+    }
+}
+
+@Test func renpyExecutablesAreThePairedLaunchers() throws {
+    try withTempDir { dir in
+        let root = try Fixtures.renpy(.vcVersion, in: dir)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, padTo: 64 << 10), to: "Other.exe", in: root)
+        let result = try #require(try detect(root))
+        #expect(samePath(result.executables[.windows]?.path, "Game.exe"))
+        let linux = try #require(result.executables[.linux])
+        #expect(linux.format == .elf)
+        #expect(samePath(linux.path, "lib/py3-linux-x86_64/Game"))
+    }
+}
+
+// MARK: Unity
+
+@Test(arguments: [(Fixtures.UnityLayout.mono, UnityScripting.mono), (.il2cpp, .il2cpp), (.pre2017, .mono)])
+func unityLayoutsAreRecognizedWithTheirBackend(layout: Fixtures.UnityLayout, scripting: UnityScripting) throws {
+    try withTempDir { dir in
+        let result = try #require(try detect(try Fixtures.unity(layout, in: dir)))
+        #expect(result.engine == .unity)
+        #expect(result.details.unityScripting == scripting)
+        #expect(samePath(result.executables[.windows]?.path, "Game.exe"))
+    }
+}
+
+@Test func unityFolderWithBothBinariesReportsBothPlatforms() throws {
+    try withTempDir { dir in
+        let result = try #require(try detect(try Fixtures.unity(.mono, linux: true, in: dir)))
+        #expect(result.executables[.windows]?.architecture == .amd64)
+        #expect(result.executables[.linux]?.architecture == .amd64)
+        #expect(samePath(result.executables[.linux]?.path, "Game.x86_64"))
+    }
+}
+
+// MARK: Kirikiri
+
+@Test func kirikiriReportsPluginBaseNames() throws {
+    try withTempDir { dir in
+        let plugins = ["extrans.tpm", "wuvorbis.tpm"]
+        let root = try Fixtures.kirikiri(flavor: nil, tpm: plugins, in: dir)
+        try Fixtures.write(Data(count: 4), to: "plugin/sample.dll", in: root)
+        let result = try #require(try detect(root))
+        #expect(result.details.pluginFileNames == (plugins + ["sample.dll"]).sorted())
+    }
+}
+
+@Test(arguments: [
+    ("TVP(KIRIKIRI) 2 core / Scripting Platform for Win32", KirikiriFlavor.krkr2),
+    ("TVP(KIRIKIRI) Z core / Scripting Platform for Win32", .krkrZ),
+])
+func kirikiriFlavorComesFromTheVersionResource(product: String, flavor: KirikiriFlavor) throws {
+    try withTempDir { dir in
+        let result = try #require(try detect(try Fixtures.kirikiri(flavor: product, in: dir)))
+        #expect(result.details.kirikiriFlavor == flavor)
+    }
+}
+
+@Test(arguments: [false, true])
+func xp3ProtectedBitIsReported(protected: Bool) throws {
+    try withTempDir { dir in
+        let result = try #require(try detect(try Fixtures.kirikiri(flavor: nil, protectedEntry: protected, in: dir)))
+        #expect(result.details.xp3ProtectedFlag == protected)
+    }
+}
+
+@Test func garbageXP3IndexIsUnreadableButStillKirikiri() throws {
+    try withTempDir { dir in
+        let result = try #require(try detect(try Fixtures.kirikiri(flavor: nil, index: .garbage, in: dir)))
+        #expect(result.engine == .kirikiri)
+        #expect(result.details.xp3IndexReadable == false)
+    }
+}
+
+// MARK: GameMaker
+
+@Test(arguments: [(true, GameMakerBuild.vm), (false, .yyc)])
+func gameMakerBuildFollowsTheCodeChunk(hasCode: Bool, build: GameMakerBuild) throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.gameMaker(hasCode: hasCode), to: "data.win", in: dir)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
+        let result = try #require(try detect(dir))
+        #expect(result.engine == .gameMaker)
+        #expect(result.details.gameMakerBuild == build)
+    }
+}
+
+@Test func formWithoutGEN8IsNotGameMaker() throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.gameMaker(hasGEN8: false, hasCode: true), to: "data.win", in: dir)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
+        #expect(try detect(dir)?.engine == .unknown)
+    }
+}
+
+// MARK: BGI
+
+@Test func bgiExecutableIsRecognized() throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "BGI.exe", in: dir)
+        #expect(try detect(dir)?.engine == .bgi)
+    }
+}
+
+@Test(arguments: ["PackFile    ", "BURIKO ARC20"])
+func twoBGIArchivesAreRecognized(magic: String) throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.bgiArc(magic: magic), to: "data01.arc", in: dir)
+        try Fixtures.write(Fixtures.bgiArc(magic: magic), to: "data02.arc", in: dir)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
+        #expect(try detect(dir)?.engine == .bgi)
+    }
+}
+
+@Test func archivesWithoutTheMagicAreNotBGI() throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.bgiArc(magic: "OtherPack000"), to: "data01.arc", in: dir)
+        try Fixtures.write(Fixtures.bgiArc(magic: "OtherPack000"), to: "data02.arc", in: dir)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
+        #expect(try detect(dir)?.engine == .unknown)
+    }
+}
+
+// MARK: PE / ELF
+
+@Test func peHeaderBeyondFourKiBParses() throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, lfanew: 0x1400), to: "Game.exe", in: dir)
+        #expect(try detect(dir)?.executables[.windows]?.architecture == .amd64)
+    }
+}
+
+@Test func dllIsNeverAnExecutable() throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, dll: true), to: "Game.exe", in: dir)
+        #expect(try detect(dir) == nil)
+    }
+}
+
+@Test(arguments: [(Fixtures.elfAMD64, CPUArchitecture.amd64), (Fixtures.elfAArch64, .arm64)])
+func elfMachineMapsToArchitecture(machine: UInt16, architecture: CPUArchitecture) throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.elf(machine: machine), to: "Game.x86_64", in: dir)
+        #expect(try detect(dir)?.executables[.linux]?.architecture == architecture)
+    }
+}
+
+@Test func shellScriptIsNotAnELF() throws {
+    try withTempDir { dir in
+        try Fixtures.write("#!/bin/sh\necho start\n", to: "Game", in: dir)
+        #expect(try detect(dir) == nil)
+    }
+}
+
+// MARK: Main executable selection
+
+@Test func installersAndRedistributablesAreNeverChosen() throws {
+    try withTempDir { dir in
+        let big = 64 << 10
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
+        for name in ["setup.exe", "unins000.exe", "vc_redist.x86.exe", "DXSETUP.exe"] {
+            try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386, padTo: big), to: name, in: dir)
+        }
+        #expect(samePath(try detect(dir)?.executables[.windows]?.path, "Game.exe"))
+    }
+}
+
+@Test func guiExecutableBeatsALargerConsoleOne() throws {
+    try withTempDir { dir in
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386, gui: true), to: "Window.exe", in: dir)
+        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386, gui: false, padTo: 64 << 10), to: "Console.exe", in: dir)
+        #expect(samePath(try detect(dir)?.executables[.windows]?.path, "Window.exe"))
+    }
+}
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift b/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift
new file mode 100644
index 0000000..2f73b70
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift
@@ -0,0 +1,339 @@
+import CEikonSession
+import Foundation
+
+/// Synthesizes tiny, original fake game folders in temp directories. Byte builders make
+/// headers only, plus a few padding bytes; layout builders compose them into folders.
+enum Fixtures {
+    static let peI386: UInt16 = 0x014C
+    static let peAMD64: UInt16 = 0x8664
+    static let elfAMD64: UInt16 = 62
+    static let elfAArch64: UInt16 = 183
+
+    // MARK: Files
+
+    static func tempDir() throws -> URL {
+        let url = FileManager.default.temporaryDirectory
+            .appendingPathComponent("eikon-fixture-\(UUID().uuidString)", isDirectory: true)
+        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
+        return url
+    }
+
+    /// Writes `data` at `rel` under `dir`, creating intermediate folders.
+    static func write(_ data: Data, to rel: String, in dir: URL) throws {
+        let url = dir.appendingPathComponent(rel)
+        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
+        try data.write(to: url)
+    }
+
+    static func write(_ text: String, to rel: String, in dir: URL) throws {
+        try write(Data(text.utf8), to: rel, in: dir)
+    }
+
+    static func mkdir(_ rel: String, in dir: URL) throws {
+        try FileManager.default.createDirectory(at: dir.appendingPathComponent(rel, isDirectory: true),
+                                                withIntermediateDirectories: true)
+    }
+
+    // MARK: Byte builders
+
+    /// A PE with the given COFF machine, subsystem and DLL flag. With `versionStrings`, it
+    /// carries a .rsrc section holding a VS_VERSIONINFO with those StringFileInfo values.
+    static func pe(machine: UInt16, gui: Bool = true, dll: Bool = false, lfanew: Int = 0x80,
+                   versionStrings: [String: String] = [:], padTo size: Int? = nil) -> Data {
+        let optionalSize = 240
+        let sectionCount = versionStrings.isEmpty ? 0 : 1
+        var data = Data(count: lfanew)
+        data[0] = 0x4D
+        data[1] = 0x5A
+        data.put32(UInt32(lfanew), at: 0x3C)
+
+        data.append(contentsOf: [0x50, 0x45, 0, 0])
+        data.append16(machine)
+        data.append16(UInt16(sectionCount))
+        data.append(Data(count: 12)) // timestamp, symbol table, symbol count
+        data.append16(UInt16(optionalSize))
+        data.append16(0x0002 | (dll ? 0x2000 : 0))
+
+        var optional = Data(count: optionalSize)
+        optional.put16(0x020B, at: 0) // PE32+
+        optional.put16(gui ? 2 : 3, at: 68)
+        data.append(optional)
+
+        if !versionStrings.isEmpty {
+            let headerEnd = data.count + 40
+            let rawPointer = (headerEnd + 0x1FF) & ~0x1FF
+            let virtualAddress: UInt32 = 0x1000
+            let rsrc = resourceSection(virtualAddress: virtualAddress, strings: versionStrings)
+            var header = Data(".rsrc".utf8) + Data(count: 3)
+            header.append32(UInt32(rsrc.count))
+            header.append32(virtualAddress)
+            header.append32(UInt32(rsrc.count))
+            header.append32(UInt32(rawPointer))
+            header.append(Data(count: 16))
+            data.append(header)
+            data.append(Data(count: rawPointer - data.count))
+            data.append(rsrc)
+        }
+        if let size, size > data.count { data.append(Data(count: size - data.count)) }
+        return data
+    }
+
+    static func elf(machine: UInt16) -> Data {
+        var data = Data(count: 64)
+        data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
+        data[4] = 2 // 64-bit
+        data[5] = 1 // little-endian
+        data[6] = 1
+        data.put16(2, at: 0x10) // ET_EXEC
+        data.put16(machine, at: 0x12)
+        return data
+    }
+
+    enum XP3Index { case raw, zlib, garbage }
+
+    /// An XP3 archive with one file entry. `continuation` adds the Kirikiri 2.3+ header
+    /// whose flag byte 0x80 points on to the real index.
+    static func xp3(index: XP3Index, protectedEntry: Bool = false, continuation: Bool = false) -> Data {
+        let magic: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01]
+        var data = Data(magic)
+        let offsetField = data.count
+        data.append64(0)
+
+        if continuation {
+            data.put64(UInt64(data.count + 4), at: offsetField) // 0x17
+            data.append32(1)
+            data.append(0x80) // raw, continue
+            data.append64(0)  // empty index
+            let next = data.count
+            data.append64(0)
+            data.append(Data("sample body".utf8))
+            data.put64(UInt64(data.count), at: next)
+        } else {
+            data.append(Data("sample body".utf8))
+            data.put64(UInt64(data.count), at: offsetField)
+        }
+
+        let entries = xp3Entries(protectedEntry: protectedEntry)
+        switch index {
+        case .raw:
+            data.append(0)
+            data.append64(UInt64(entries.count))
+            data.append(entries)
+        case .zlib:
+            let packed = zlibCompress(entries)
+            data.append(1)
+            data.append64(UInt64(packed.count))
+            data.append64(UInt64(entries.count))
+            data.append(packed)
+        case .garbage:
+            let junk = Data((0..<24).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
+            data.append(1)
+            data.append64(UInt64(junk.count))
+            data.append64(64)
+            data.append(junk)
+        }
+        return data
+    }
+
+    /// FORM, then GEN8 (or another first chunk), an optional CODE chunk and a STRG chunk.
+    static func gameMaker(hasGEN8: Bool = true, hasCode: Bool) -> Data {
+        var chunks = Data()
+        func chunk(_ tag: String, _ size: Int) {
+            chunks.append(Data(tag.utf8))
+            chunks.append32(UInt32(size))
+            chunks.append(Data(count: size))
+        }
+        chunk(hasGEN8 ? "GEN8" : "OPTN", 16)
+        if hasCode { chunk("CODE", 8) }
+        chunk("STRG", 4)
+        var data = Data("FORM".utf8)
+        data.append32(UInt32(chunks.count))
+        return data + chunks
+    }
+
+    /// "PackFile    ", "BURIKO ARC20", or anything else.
+    static func bgiArc(magic: String) -> Data {
+        Data(magic.utf8) + Data(count: 8)
+    }
+
+    // MARK: Layout builders (each builds `name` under `dir` and returns its URL)
+
+    enum RenPyEra { case scriptVersion, vcVersion, initPy, libEra }
+
+    /// A Ren'Py game whose stem is "Game". Exact eras record `version`.
+    static func renpy(_ era: RenPyEra, version: [Int] = [7, 4, 11], named name: String = "Sample",
+                      in dir: URL) throws -> URL {
+        let root = dir.appendingPathComponent(name, isDirectory: true)
+        let text = version.map(String.init)
+        try write(pe(machine: peAMD64), to: "Game.exe", in: root)
+        try write("# launcher\n", to: "Game.py", in: root)
+        try write("#!/bin/sh\nexec lib/game\n", to: "Game.sh", in: root)
+        try write(Data([0x52, 0x50, 0x43, 0x32]), to: "game/script.rpyc", in: root)
+        try write("# engine\n", to: "renpy/__init__.py", in: root)
+
+        let linuxDir: String
+        switch era {
+        case .scriptVersion:
+            try write("(\(text.joined(separator: ", ")))", to: "game/script_version.txt", in: root)
+            linuxDir = "lib/py2-linux-x86_64"
+        case .vcVersion:
+            try write("version = \"\(text.joined(separator: ".")).24010101\"\n", to: "renpy/vc_version.py", in: root)
+            linuxDir = "lib/py3-linux-x86_64"
+            try mkdir("lib/python3.9", in: root)
+        case .initPy:
+            try write("vc_version = 0\nversion_tuple = (\(text.joined(separator: ", ")), vc_version)\n",
+                      to: "renpy/__init__.py", in: root)
+            linuxDir = "lib/linux-x86_64"
+            try mkdir("lib/pythonlib2.7", in: root)
+        case .libEra:
+            linuxDir = "lib/py3-linux-x86_64"
+            try mkdir("lib/python3.12", in: root)
+        }
+        try write(elf(machine: elfAMD64), to: "\(linuxDir)/Game", in: root)
+        try write("#!/bin/sh\n", to: "\(linuxDir)/Game.sh", in: root)
+        return root
+    }
+
+    enum UnityLayout { case mono, il2cpp, pre2017 }
+
+    /// A Unity game whose stem is "Game", with a larger GUI crash handler beside it.
+    static func unity(_ layout: UnityLayout, linux: Bool = false, named name: String = "Sample",
+                      in dir: URL) throws -> URL {
+        let root = dir.appendingPathComponent(name, isDirectory: true)
+        try write(pe(machine: peAMD64), to: "Game.exe", in: root)
+        try write(pe(machine: peAMD64, padTo: 64 << 10), to: "UnityCrashHandler64.exe", in: root)
+        switch layout {
+        case .mono:
+            try write(pe(machine: peAMD64, dll: true), to: "UnityPlayer.dll", in: root)
+            try write(Data(count: 64), to: "Game_Data/globalgamemanagers", in: root)
+            try write(pe(machine: peI386, dll: true), to: "Game_Data/Managed/Assembly-CSharp.dll", in: root)
+        case .il2cpp:
+            try write(pe(machine: peAMD64, dll: true), to: "UnityPlayer.dll", in: root)
+            try write(pe(machine: peAMD64, dll: true), to: "GameAssembly.dll", in: root)
+            try write(Data(count: 64), to: "Game_Data/globalgamemanagers", in: root)
+            try write(Data(count: 16), to: "Game_Data/il2cpp_data/Metadata/global-metadata.dat", in: root)
+        case .pre2017:
+            try write(Data(count: 64), to: "Game_Data/mainData", in: root)
+            try write(pe(machine: peI386, dll: true), to: "Game_Data/Managed/Assembly-CSharp.dll", in: root)
+        }
+        if linux {
+            try write(elf(machine: elfAMD64), to: "Game.x86_64", in: root)
+            try write(elf(machine: elfAMD64), to: "UnityPlayer.so", in: root)
+        }
+        return root
+    }
+
+    /// A Kirikiri game: Game.exe (with ProductName `flavor`, if any), data.xp3 and plugins.
+    static func kirikiri(flavor: String?, tpm: [String] = [], index: XP3Index = .raw,
+                         protectedEntry: Bool = false, continuation: Bool = false,
+                         named name: String = "Sample", in dir: URL) throws -> URL {
+        let root = dir.appendingPathComponent(name, isDirectory: true)
+        let strings = flavor.map { ["ProductName": $0, "FileDescription": $0] } ?? [:]
+        try write(pe(machine: peI386, versionStrings: strings), to: "Game.exe", in: root)
+        try write(xp3(index: index, protectedEntry: protectedEntry, continuation: continuation),
+                  to: "data.xp3", in: root)
+        for plugin in tpm {
+            try write(Data(count: 8), to: plugin, in: root)
+        }
+        return root
+    }
+
+    // MARK: Internals
+
+    private static func xp3Entries(protectedEntry: Bool) -> Data {
+        let name = Array("sample.txt".utf16)
+        var info = Data()
+        info.append32(protectedEntry ? 0x8000_0000 : 0)
+        info.append64(11)
+        info.append64(11)
+        info.append16(UInt16(name.count))
+        for unit in name { info.append16(unit) }
+
+        var segment = Data()
+        segment.append32(0)
+        segment.append64(0x13)
+        segment.append64(11)
+        segment.append64(11)
+
+        var body = Data()
+        for (tag, payload) in [("info", info), ("segm", segment), ("adlr", Data(count: 4))] {
+            body.append(Data(tag.utf8))
+            body.append64(UInt64(payload.count))
+            body.append(payload)
+        }
+        var file = Data("File".utf8)
+        file.append64(UInt64(body.count))
+        return file + body
+    }
+
+    private static func zlibCompress(_ data: Data) -> Data {
+        var length = compressBound(uLong(data.count))
+        var output = Data(count: Int(length))
+        let status = output.withUnsafeMutableBytes { out in
+            data.withUnsafeBytes { input in
+                compress(out.bindMemory(to: Bytef.self).baseAddress, &length,
+                         input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
+            }
+        }
+        precondition(status == Z_OK)
+        return output.prefix(Int(length))
+    }
+
+    /// Resource directory (RT_VERSION → one name → one language) and the VS_VERSIONINFO.
+    private static func resourceSection(virtualAddress: UInt32, strings: [String: String]) -> Data {
+        let info = versionInfo(strings)
+        var data = Data()
+        func directory(entryID: UInt32, target: UInt32) {
+            data.append(Data(count: 12))
+            data.append16(0)
+            data.append16(1)
+            data.append32(entryID)
+            data.append32(target)
+        }
+        directory(entryID: 16, target: 0x8000_0000 | 0x18)
+        directory(entryID: 1, target: 0x8000_0000 | 0x30)
+        directory(entryID: 0x409, target: 0x48)
+        data.append32(virtualAddress + 0x58)
+        data.append32(UInt32(info.count))
+        data.append(Data(count: 8))
+        return data + info
+    }
+
+    private static func versionInfo(_ strings: [String: String]) -> Data {
+        let children = strings.keys.sorted().map { key -> Data in
+            let value = Array(strings[key]!.utf16) + [0]
+            return block(key: key, value: Data(value.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
+                         valueLength: value.count, type: 1)
+        }
+        let table = block(key: "040904B0", value: Data(), valueLength: 0, type: 1, children: children)
+        let fileInfo = block(key: "StringFileInfo", value: Data(), valueLength: 0, type: 1, children: [table])
+        var fixed = Data(count: 52)
+        fixed.put32(0xFEEF_04BD, at: 0)
+        return block(key: "VS_VERSION_INFO", value: fixed, valueLength: 52, type: 0, children: [fileInfo])
+    }
+
+    private static func block(key: String, value: Data, valueLength: Int, type: UInt16, children: [Data] = []) -> Data {
+        var data = Data(count: 6)
+        for unit in Array(key.utf16) + [0] { data.append16(unit) }
+        data.padTo4()
+        data.append(value)
+        for child in children {
+            data.padTo4()
+            data.append(child)
+        }
+        data.put16(UInt16(data.count), at: 0)
+        data.put16(UInt16(valueLength), at: 2)
+        data.put16(type, at: 4)
+        return data
+    }
+}
+
+extension Data {
+    mutating func append16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
+    mutating func append32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
+    mutating func append64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
+    mutating func put16(_ value: UInt16, at offset: Int) { replaceSubrange(offset..<offset + 2, with: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
+    mutating func put32(_ value: UInt32, at offset: Int) { for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) } }
+    mutating func put64(_ value: UInt64, at offset: Int) { for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) } }
+    mutating func padTo4() { while count % 4 != 0 { append(0) } }
+}

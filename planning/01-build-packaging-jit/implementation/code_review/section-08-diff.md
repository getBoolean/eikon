diff --git a/App/ReportExport.swift b/App/ReportExport.swift
new file mode 100644
index 0000000..e0a2610
--- /dev/null
+++ b/App/ReportExport.swift
@@ -0,0 +1,58 @@
+import EikonKit
+import SwiftUI
+import UIKit
+
+@MainActor
+enum ReportExport {
+    /// Puts the report JSON on the general pasteboard.
+    static func copy(_ report: DeviceReport) throws {
+        UIPasteboard.general.string = String(decoding: try report.encode(), as: UTF8.self)
+    }
+
+    /// Writes the report over any previous file of the same name and returns that URL.
+    static func temporaryFile(for report: DeviceReport) throws -> URL {
+        let data = try report.encode()
+        let day = utcDay.string(from: report.generatedAt)
+        let name = "eikon-report-\(day)-\(sanitize(report.device.modelIdentifier))-\(sanitize(report.install.method.rawValue)).json"
+        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
+        try data.write(to: url, options: .atomic)
+        return url
+    }
+
+    private static let utcDay: DateFormatter = {
+        let formatter = DateFormatter()
+        formatter.calendar = Calendar(identifier: .gregorian)
+        formatter.locale = Locale(identifier: "en_US_POSIX")
+        formatter.timeZone = TimeZone(secondsFromGMT: 0)
+        formatter.dateFormat = "yyyy-MM-dd"
+        return formatter
+    }()
+
+    private static func sanitize(_ value: String) -> String {
+        String(value.map { character in
+            guard let ascii = character.asciiValue else { return "_" }
+            switch ascii {
+            case 44, 45, 46, 48...57, 65...90, 95, 97...122:
+                return character
+            default:
+                return "_"
+            }
+        })
+    }
+}
+
+/// SwiftUI bridge for UIActivityViewController. ShareLink needs iOS 16.
+struct ActivityView: UIViewControllerRepresentable {
+    let items: [Any]
+    var onComplete: (() -> Void)?
+
+    func makeUIViewController(context: Context) -> UIActivityViewController {
+        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
+        controller.completionWithItemsHandler = { _, _, _, _ in
+            onComplete?()
+        }
+        return controller
+    }
+
+    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/ChipNames.swift b/Packages/EikonKit/Sources/EikonKit/ChipNames.swift
new file mode 100644
index 0000000..e83de3d
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/ChipNames.swift
@@ -0,0 +1,38 @@
+/// Display names for model identifiers. Missing entries are "unknown"; reports correct the table.
+/// Never used for TXM or policy decisions.
+public enum ChipNames {
+    public static func displayName(forModel identifier: String) -> String {
+        names[identifier] ?? "unknown"
+    }
+
+    /// iPhone and iPad models that run iOS 15 or later on A12 or newer, plus M-series iPads.
+    private static let names: [String: String] = [
+        "iPhone11,2": "A12", "iPhone11,4": "A12", "iPhone11,6": "A12", "iPhone11,8": "A12",
+        "iPhone12,1": "A13", "iPhone12,3": "A13", "iPhone12,5": "A13", "iPhone12,8": "A13",
+        "iPhone13,1": "A14", "iPhone13,2": "A14", "iPhone13,3": "A14", "iPhone13,4": "A14",
+        "iPhone14,2": "A15", "iPhone14,3": "A15", "iPhone14,4": "A15", "iPhone14,5": "A15",
+        "iPhone14,6": "A15", "iPhone14,7": "A15", "iPhone14,8": "A15",
+        "iPhone15,2": "A16", "iPhone15,3": "A16", "iPhone15,4": "A16", "iPhone15,5": "A16",
+        "iPhone16,1": "A17 Pro", "iPhone16,2": "A17 Pro",
+        "iPhone17,1": "A18 Pro", "iPhone17,2": "A18 Pro", "iPhone17,3": "A18", "iPhone17,4": "A18",
+        "iPhone17,5": "A18",
+        "iPad8,1": "A12X", "iPad8,2": "A12X", "iPad8,3": "A12X", "iPad8,4": "A12X",
+        "iPad8,5": "A12X", "iPad8,6": "A12X", "iPad8,7": "A12X", "iPad8,8": "A12X",
+        "iPad8,9": "A12Z", "iPad8,10": "A12Z", "iPad8,11": "A12Z", "iPad8,12": "A12Z",
+        "iPad11,1": "A12", "iPad11,2": "A12", "iPad11,3": "A12", "iPad11,4": "A12",
+        "iPad11,6": "A12", "iPad11,7": "A12",
+        "iPad12,1": "A13", "iPad12,2": "A13",
+        "iPad13,1": "A14", "iPad13,2": "A14",
+        "iPad13,4": "M1", "iPad13,5": "M1", "iPad13,6": "M1", "iPad13,7": "M1",
+        "iPad13,8": "M1", "iPad13,9": "M1", "iPad13,10": "M1", "iPad13,11": "M1",
+        "iPad13,16": "M1", "iPad13,17": "M1",
+        "iPad13,18": "A14", "iPad13,19": "A14",
+        "iPad14,1": "A15", "iPad14,2": "A15",
+        "iPad14,3": "M2", "iPad14,4": "M2", "iPad14,5": "M2", "iPad14,6": "M2",
+        "iPad14,8": "M2", "iPad14,9": "M2", "iPad14,10": "M2", "iPad14,11": "M2",
+        "iPad15,3": "M3", "iPad15,4": "M3", "iPad15,5": "M3", "iPad15,6": "M3",
+        "iPad15,7": "A16", "iPad15,8": "A16",
+        "iPad16,1": "A17 Pro", "iPad16,2": "A17 Pro",
+        "iPad16,3": "M4", "iPad16,4": "M4", "iPad16,5": "M4", "iPad16,6": "M4",
+    ]
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/DeviceReport.swift b/Packages/EikonKit/Sources/EikonKit/DeviceReport.swift
new file mode 100644
index 0000000..790489e
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/DeviceReport.swift
@@ -0,0 +1,139 @@
+import Foundation
+
+/// One JSON document of what this launch detected. New measurements go into `gates`.
+/// Adding or renaming a top-level field bumps `schemaVersion`, and the filer and schema
+/// then have to accept that version.
+public struct DeviceReport: Codable, Sendable, Equatable {
+    public static let currentSchemaVersion = 1
+
+    public var schemaVersion: Int
+    public var generatedAt: Date
+    public var app: AppInfo
+    public var device: DeviceInfo
+    public var os: OSInfo
+    public var install: InstallInfo
+    public var jit: JITStatus
+    public var memory: MemoryInfo
+    public var gates: [String: GateResult]
+    public var notes: String?
+
+    /// Assembles a report from facts that have already been gathered.
+    public static func make(app: AppInfo, installMethod: InstallMethod, evidence: InstallEvidence,
+                            jit: JITStatus, system: DeviceSystem, now: Date) -> DeviceReport {
+        let seconds = now.timeIntervalSince1970.rounded(.down)
+        return DeviceReport(
+            schemaVersion: currentSchemaVersion,
+            generatedAt: Date(timeIntervalSince1970: seconds),
+            app: app,
+            device: DeviceInfo(
+                modelIdentifier: system.modelIdentifier,
+                chip: ChipNames.displayName(forModel: system.modelIdentifier),
+                cpuFamily: String(format: "0x%08x", system.cpuFamily)
+            ),
+            os: OSInfo(name: system.osName, version: system.osVersion, build: system.osBuild),
+            install: InstallInfo(method: installMethod, evidence: evidence),
+            jit: jit,
+            memory: MemoryInfo(availableBytes: system.availableMemoryBytes()),
+            gates: [:],
+            notes: nil
+        )
+    }
+
+    public func encode() throws -> Data {
+        let encoder = JSONEncoder()
+        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
+        encoder.dateEncodingStrategy = .iso8601
+        return try encoder.encode(self)
+    }
+
+    public static func decode(_ data: Data) throws -> DeviceReport {
+        let decoder = JSONDecoder()
+        decoder.dateDecodingStrategy = .iso8601
+        return try decoder.decode(DeviceReport.self, from: data)
+    }
+}
+
+public struct AppInfo: Codable, Sendable, Equatable {
+    public var version: String
+    public var build: String
+    public var commit: String
+    public var packageKind: String
+    public var bundleIdentifier: String
+
+    public init(version: String, build: String, commit: String, packageKind: String, bundleIdentifier: String) {
+        self.version = version
+        self.build = build
+        self.commit = commit
+        self.packageKind = packageKind
+        self.bundleIdentifier = bundleIdentifier
+    }
+
+    /// A missing Info.plist value becomes "unknown".
+    public static func from(_ bundle: Bundle) -> AppInfo {
+        func value(_ key: String) -> String {
+            let text = bundle.object(forInfoDictionaryKey: key) as? String
+            return text.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
+        }
+        return AppInfo(
+            version: value("CFBundleShortVersionString"),
+            build: value("CFBundleVersion"),
+            commit: value("EKGitCommit"),
+            packageKind: value("EKPackageKind"),
+            bundleIdentifier: bundle.bundleIdentifier ?? "unknown"
+        )
+    }
+}
+
+public struct DeviceInfo: Codable, Sendable, Equatable {
+    public var modelIdentifier: String
+    public var chip: String
+    public var cpuFamily: String
+
+    public init(modelIdentifier: String, chip: String, cpuFamily: String) {
+        self.modelIdentifier = modelIdentifier
+        self.chip = chip
+        self.cpuFamily = cpuFamily
+    }
+}
+
+public struct OSInfo: Codable, Sendable, Equatable {
+    public var name: String
+    public var version: String
+    public var build: String
+
+    public init(name: String, version: String, build: String) {
+        self.name = name
+        self.version = version
+        self.build = build
+    }
+}
+
+public struct InstallInfo: Codable, Sendable, Equatable {
+    public var method: InstallMethod
+    public var evidence: InstallEvidence
+
+    public init(method: InstallMethod, evidence: InstallEvidence) {
+        self.method = method
+        self.evidence = evidence
+    }
+}
+
+public struct MemoryInfo: Codable, Sendable, Equatable {
+    public var availableBytes: UInt64
+
+    public init(availableBytes: UInt64) {
+        self.availableBytes = availableBytes
+    }
+}
+
+public struct GateResult: Codable, Sendable, Equatable {
+    public var passed: Bool?
+    public var detail: String
+    public var measuredAt: Date
+
+    public init(passed: Bool?, detail: String, measuredAt: Date) {
+        self.passed = passed
+        self.detail = detail
+        self.measuredAt = measuredAt
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/DeviceSystem.swift b/Packages/EikonKit/Sources/EikonKit/DeviceSystem.swift
new file mode 100644
index 0000000..c44e5c9
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/DeviceSystem.swift
@@ -0,0 +1,67 @@
+import Darwin
+import Foundation
+import UIKit
+import os
+
+/// Seam over sysctl and ProcessInfo so a report can be built without a device.
+public protocol DeviceSystem: Sendable {
+    var modelIdentifier: String { get }
+    var cpuFamily: UInt32 { get }
+    var osName: String { get }
+    var osVersion: String { get }
+    var osBuild: String { get }
+    func availableMemoryBytes() -> UInt64
+}
+
+/// Values captured once. `osName` comes from UIDevice, so construction is on the main actor.
+public struct LiveDeviceSystem: DeviceSystem {
+    public var modelIdentifier: String
+    public var cpuFamily: UInt32
+    public var osName: String
+    public var osVersion: String
+    public var osBuild: String
+
+    @MainActor
+    public static func current() -> LiveDeviceSystem {
+        let version = ProcessInfo.processInfo.operatingSystemVersion
+        var versionText = "\(version.majorVersion).\(version.minorVersion)"
+        if version.patchVersion != 0 {
+            versionText += ".\(version.patchVersion)"
+        }
+        return LiveDeviceSystem(
+            modelIdentifier: modelIdentifier(),
+            cpuFamily: sysctlUInt32("hw.cpufamily") ?? 0,
+            osName: UIDevice.current.systemName,
+            osVersion: versionText,
+            osBuild: sysctlString("kern.osversion") ?? "unknown"
+        )
+    }
+
+    public func availableMemoryBytes() -> UInt64 {
+        UInt64(os_proc_available_memory())
+    }
+
+    private static func modelIdentifier() -> String {
+        #if targetEnvironment(simulator)
+        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
+            return simulated
+        }
+        #endif
+        return sysctlString("hw.machine") ?? "unknown"
+    }
+}
+
+func sysctlString(_ name: String) -> String? {
+    var size = 0
+    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
+    var buffer = [CChar](repeating: 0, count: size)
+    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
+    return String(cString: buffer)
+}
+
+func sysctlUInt32(_ name: String) -> UInt32? {
+    var value: UInt32 = 0
+    var size = MemoryLayout<UInt32>.size
+    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
+    return value
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/JITTypes.swift b/Packages/EikonKit/Sources/EikonKit/JITTypes.swift
index 24bec3a..22861fe 100644
--- a/Packages/EikonKit/Sources/EikonKit/JITTypes.swift
+++ b/Packages/EikonKit/Sources/EikonKit/JITTypes.swift
@@ -122,7 +122,7 @@ public struct JITStatus: Codable, Sendable, Equatable {
         try c.encode(txm, forKey: .txm)
         try c.encode(probe, forKey: .probe)
         try c.encode(source, forKey: .source)
-        try c.encode(reason, forKey: .reason)
+        try c.encodeIfPresent(reason, forKey: .reason)
         try c.encode(usable, forKey: .usable)
     }
 }
diff --git a/Packages/EikonKit/Sources/EikonKit/SystemInfo.swift b/Packages/EikonKit/Sources/EikonKit/SystemInfo.swift
index e703803..3375baf 100644
--- a/Packages/EikonKit/Sources/EikonKit/SystemInfo.swift
+++ b/Packages/EikonKit/Sources/EikonKit/SystemInfo.swift
@@ -1,4 +1,3 @@
-import Darwin
 import Foundation
 
 /// Host facts reused by the JIT controller and, later, the device report.
@@ -9,10 +8,7 @@ public enum SystemInfo {
 
     /// `hw.cpufamily`, or 0 when the sysctl fails.
     public static var cpuFamily: UInt32 {
-        var value: UInt32 = 0
-        var size = MemoryLayout<UInt32>.size
-        guard sysctlbyname("hw.cpufamily", &value, &size, nil, 0) == 0 else { return 0 }
-        return value
+        sysctlUInt32("hw.cpufamily") ?? 0
     }
 
     public static var isSimulator: Bool {
diff --git a/Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift b/Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift
new file mode 100644
index 0000000..54751a8
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift
@@ -0,0 +1,96 @@
+import Foundation
+import Testing
+import UIKit
+@testable import EikonKit
+
+private struct FixedDeviceSystem: DeviceSystem {
+    var modelIdentifier = "iPad14,5"
+    var cpuFamily: UInt32 = 0xDA33_D83D
+    var osName = "iPadOS"
+    var osVersion = "17.0"
+    var osBuild = "21A329"
+    func availableMemoryBytes() -> UInt64 { 5_368_709_120 }
+}
+
+@Test @MainActor func roundTripAndPrivacy() throws {
+    let now = Date(timeIntervalSince1970: 1_768_470_030)
+    let report = DeviceReport.make(
+        app: AppInfo(version: "0.1.0", build: "12", commit: "0123abc", packageKind: "tipa",
+                     bundleIdentifier: "com.getboolean.eikon"),
+        installMethod: .trollStore,
+        evidence: InstallEvidence(bundlePath: "/private/var/containers/Bundle/Application/<uuid>/Eikon.app",
+                                  homeDirectory: "/var/mobile/Containers/Data/Application/<uuid>",
+                                  markers: ["_TrollStore"]),
+        jit: JITStatus(csDebugged: true, csDebuggedSeen: .afterTrollStoreRequest,
+                       txm: TXMInfo(state: .absent, enforced: false, basis: "os below 26"),
+                       probe: ProbeOutcome(kind: .passed, detail: nil),
+                       source: .trollStore, reason: nil),
+        system: FixedDeviceSystem(),
+        now: now
+    )
+    let encoded = try report.encode()
+    #expect(try DeviceReport.decode(encoded) == report)
+    try expectPrivacy(encoded)
+
+    let live = DeviceReport.make(
+        app: report.app, installMethod: .simulator, evidence: report.install.evidence,
+        jit: report.jit, system: LiveDeviceSystem.current(), now: now
+    )
+    try expectPrivacy(try live.encode())
+}
+
+@Test func fixtureContract() throws {
+    let url = try repoFile("tests/fixtures/device-report.json")
+    let fixtureData = try Data(contentsOf: url)
+    let decoded = try DeviceReport.decode(fixtureData)
+    let fixture = try jsonObject(fixtureData)
+    let encoded = try jsonObject(try decoded.encode())
+    #expect(Set(encoded.keys) == Set(fixture.keys))
+    let fixtureJIT = try #require(fixture["jit"] as? [String: Any])
+    let encodedJIT = try #require(encoded["jit"] as? [String: Any])
+    #expect(Set(encodedJIT.keys) == Set(fixtureJIT.keys))
+}
+
+@MainActor
+private func expectPrivacy(_ data: Data) throws {
+    let names = [UIDevice.current.name, ProcessInfo.processInfo.hostName].filter { !$0.isEmpty }
+    let found = stringKeysAndValues(try JSONSerialization.jsonObject(with: data))
+    for name in names {
+        #expect(!found.contains(name))
+    }
+}
+
+private func stringKeysAndValues(_ value: Any) -> Set<String> {
+    var found: Set<String> = []
+    func walk(_ value: Any) {
+        if let text = value as? String {
+            found.insert(text)
+        } else if let object = value as? [String: Any] {
+            for (key, child) in object {
+                found.insert(key)
+                walk(child)
+            }
+        } else if let list = value as? [Any] {
+            list.forEach(walk)
+        }
+    }
+    walk(value)
+    return found
+}
+
+private func jsonObject(_ data: Data) throws -> [String: Any] {
+    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
+}
+
+private func repoFile(_ relative: String) throws -> URL {
+    var url = URL(fileURLWithPath: #filePath)
+    while url.path != "/" {
+        url.deleteLastPathComponent()
+        let candidate = url.appendingPathComponent(relative)
+        if FileManager.default.fileExists(atPath: candidate.path) {
+            return candidate
+        }
+    }
+    Issue.record("missing \(relative); looked upward from \(#filePath)")
+    throw CocoaError(.fileNoSuchFile)
+}
diff --git a/device-reports/schema.json b/device-reports/schema.json
new file mode 100644
index 0000000..898b458
--- /dev/null
+++ b/device-reports/schema.json
@@ -0,0 +1,144 @@
+{
+  "$schema": "https://json-schema.org/draft/2020-12/schema",
+  "title": "Eikon device report",
+  "type": "object",
+  "additionalProperties": false,
+  "required": [
+    "schemaVersion",
+    "generatedAt",
+    "app",
+    "device",
+    "os",
+    "install",
+    "jit",
+    "memory",
+    "gates"
+  ],
+  "properties": {
+    "schemaVersion": { "type": "integer", "const": 1 },
+    "generatedAt": { "$ref": "#/$defs/Timestamp" },
+    "app": { "$ref": "#/$defs/App" },
+    "device": { "$ref": "#/$defs/Device" },
+    "os": { "$ref": "#/$defs/OS" },
+    "install": { "$ref": "#/$defs/Install" },
+    "jit": { "$ref": "#/$defs/JIT" },
+    "memory": { "$ref": "#/$defs/Memory" },
+    "gates": {
+      "type": "object",
+      "additionalProperties": { "$ref": "#/$defs/GateResult" }
+    },
+    "notes": { "type": ["string", "null"] }
+  },
+  "$defs": {
+    "Timestamp": {
+      "type": "string",
+      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z$"
+    },
+    "FilenamePart": {
+      "type": "string",
+      "pattern": "^[A-Za-z0-9,._-]+$"
+    },
+    "App": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["version", "build", "commit", "packageKind", "bundleIdentifier"],
+      "properties": {
+        "version": { "type": "string" },
+        "build": { "type": "string" },
+        "commit": { "type": "string" },
+        "packageKind": { "type": "string" },
+        "bundleIdentifier": { "type": "string" }
+      }
+    },
+    "Device": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["modelIdentifier", "chip", "cpuFamily"],
+      "properties": {
+        "modelIdentifier": { "$ref": "#/$defs/FilenamePart" },
+        "chip": { "type": "string" },
+        "cpuFamily": { "type": "string" }
+      }
+    },
+    "OS": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["name", "version", "build"],
+      "properties": {
+        "name": { "type": "string" },
+        "version": { "type": "string" },
+        "build": { "type": "string" }
+      }
+    },
+    "Install": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["method", "evidence"],
+      "properties": {
+        "method": { "$ref": "#/$defs/FilenamePart" },
+        "evidence": { "$ref": "#/$defs/Evidence" }
+      }
+    },
+    "Evidence": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["bundlePath", "homeDirectory", "markers"],
+      "properties": {
+        "bundlePath": { "type": "string" },
+        "homeDirectory": { "type": "string" },
+        "markers": { "type": "array", "items": { "type": "string" } }
+      }
+    },
+    "JIT": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["csDebugged", "csDebuggedSeen", "txm", "probe", "source", "usable"],
+      "properties": {
+        "csDebugged": { "type": "boolean" },
+        "csDebuggedSeen": { "type": "string" },
+        "txm": { "$ref": "#/$defs/TXM" },
+        "probe": { "$ref": "#/$defs/Probe" },
+        "source": { "type": "string" },
+        "reason": { "type": ["string", "null"] },
+        "usable": { "type": "boolean" }
+      }
+    },
+    "TXM": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["state", "enforced", "basis"],
+      "properties": {
+        "state": { "type": "string" },
+        "enforced": { "type": "boolean" },
+        "basis": { "type": "string" }
+      }
+    },
+    "Probe": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["kind"],
+      "properties": {
+        "kind": { "type": "string" },
+        "detail": { "type": ["string", "null"] }
+      }
+    },
+    "Memory": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["availableBytes"],
+      "properties": {
+        "availableBytes": { "type": "integer", "minimum": 0 }
+      }
+    },
+    "GateResult": {
+      "type": "object",
+      "additionalProperties": false,
+      "required": ["detail", "measuredAt"],
+      "properties": {
+        "passed": { "type": ["boolean", "null"] },
+        "detail": { "type": "string" },
+        "measuredAt": { "$ref": "#/$defs/Timestamp" }
+      }
+    }
+  }
+}
diff --git a/scripts/file_device_report.py b/scripts/file_device_report.py
new file mode 100644
index 0000000..a071cfa
--- /dev/null
+++ b/scripts/file_device_report.py
@@ -0,0 +1,203 @@
+#!/usr/bin/env python3
+"""Validate a device report and file it under a deterministic name.
+
+    uv run scripts/file_device_report.py [--out-dir DIR] [--check] <path | ->
+
+Does not commit. An unknown schema keyword is an error, so the schema cannot
+quietly depend on a check this validator does not implement.
+"""
+
+from __future__ import annotations
+
+import argparse
+import hashlib
+import json
+import os
+import re
+import sys
+import tempfile
+from datetime import datetime, timezone
+from pathlib import Path
+
+ROOT = Path(__file__).resolve().parent.parent
+SCHEMA_PATH = ROOT / "device-reports" / "schema.json"
+KNOWN_VERSIONS = {1}
+
+ALLOWED_KEYWORDS = {
+    "$defs",
+    "$id",
+    "$ref",
+    "$schema",
+    "additionalProperties",
+    "const",
+    "description",
+    "items",
+    "minimum",
+    "pattern",
+    "properties",
+    "required",
+    "title",
+    "type",
+}
+
+
+class SchemaError(Exception):
+    """The schema uses something this validator does not check."""
+
+
+def main() -> int:
+    parser = argparse.ArgumentParser(description="Validate and file an Eikon device report.")
+    parser.add_argument("path", help="Report JSON path, or - for stdin")
+    parser.add_argument("--out-dir", type=Path, default=ROOT / "device-reports")
+    parser.add_argument("--check", action="store_true", help="Validate only; print the path and write nothing")
+    args = parser.parse_args()
+
+    try:
+        raw = sys.stdin.read() if args.path == "-" else Path(args.path).read_text(encoding="utf-8")
+        report = json.loads(raw)
+    except (OSError, UnicodeError, json.JSONDecodeError) as error:
+        print(error, file=sys.stderr)
+        return 1
+
+    version = report.get("schemaVersion") if isinstance(report, dict) else None
+    if isinstance(version, bool) or not isinstance(version, int) or version not in KNOWN_VERSIONS:
+        print(f"unknown schemaVersion: {version!r}", file=sys.stderr)
+        return 1
+
+    try:
+        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
+        problems = validate(report, schema, "", schema)
+    except SchemaError as error:
+        print(error, file=sys.stderr)
+        return 1
+    if problems:
+        for problem in problems:
+            print(problem, file=sys.stderr)
+        return 1
+
+    target = args.out_dir / filename(report)
+    body = json.dumps(report, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
+    if args.check:
+        print(target)
+        return 0
+
+    args.out_dir.mkdir(parents=True, exist_ok=True)
+    if target.exists():
+        current = target.read_text(encoding="utf-8")
+        if current != body:
+            print(f"refusing to overwrite {target}", file=sys.stderr)
+            return 1
+        print(target)
+        return 0
+
+    descriptor, temporary = tempfile.mkstemp(dir=args.out_dir, suffix=".tmp")
+    try:
+        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
+            handle.write(body)
+        os.replace(temporary, target)
+    except Exception:
+        if os.path.exists(temporary):
+            os.unlink(temporary)
+        raise
+    print(target)
+    return 0
+
+
+def filename(report: dict) -> str:
+    generated = str(report["generatedAt"]).replace("Z", "+00:00")
+    day = datetime.fromisoformat(generated).astimezone(timezone.utc).date().isoformat()
+    canonical = json.dumps(report, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
+    digest = hashlib.sha256(canonical).hexdigest()[:8]
+    model = report["device"]["modelIdentifier"]
+    method = report["install"]["method"]
+    return f"{day}-{model}-{method}-{digest}.json"
+
+
+def validate(instance, schema: dict, pointer: str, root: dict) -> list[str]:
+    reject_unknown_keywords(schema)
+    if "$ref" in schema:
+        name = schema["$ref"].removeprefix("#/$defs/")
+        return validate(instance, root["$defs"][name], pointer, root)
+
+    problems: list[str] = []
+    if "type" in schema and not type_matches(instance, schema["type"]):
+        problems.append(f"{pointer or '/'}: type")
+        return problems
+    if "const" in schema and instance != schema["const"]:
+        problems.append(f"{pointer or '/'}: const")
+    if "pattern" in schema and isinstance(instance, str) and re.search(schema["pattern"], instance) is None:
+        problems.append(f"{pointer or '/'}: pattern")
+    if "minimum" in schema and isinstance(instance, (int, float)) and not isinstance(instance, bool):
+        if instance < schema["minimum"]:
+            problems.append(f"{pointer or '/'}: minimum")
+    if isinstance(instance, dict) and any(key in schema for key in ("properties", "required", "additionalProperties")):
+        problems.extend(validate_object(instance, schema, pointer, root))
+    if "items" in schema and isinstance(instance, list):
+        for index, item in enumerate(instance):
+            problems.extend(validate(item, schema["items"], f"{pointer}/{index}", root))
+    return problems
+
+
+def validate_object(instance: dict, schema: dict, pointer: str, root: dict) -> list[str]:
+    problems: list[str] = []
+    properties = schema.get("properties", {})
+    for key in schema.get("required", []):
+        if key not in instance:
+            problems.append(f"{pointer}/{escape(key)}: required")
+    additional = schema.get("additionalProperties", True)
+    for key, value in instance.items():
+        child = f"{pointer}/{escape(key)}"
+        if key in properties:
+            problems.extend(validate(value, properties[key], child, root))
+        elif additional is False:
+            problems.append(f"{child}: additional property")
+        elif isinstance(additional, dict):
+            problems.extend(validate(value, additional, child, root))
+    return problems
+
+
+def type_matches(instance, declared) -> bool:
+    names = [declared] if isinstance(declared, str) else list(declared)
+    return any(one_type(instance, name) for name in names)
+
+
+def one_type(instance, name: str) -> bool:
+    if name == "object":
+        return isinstance(instance, dict)
+    if name == "array":
+        return isinstance(instance, list)
+    if name == "string":
+        return isinstance(instance, str)
+    if name == "boolean":
+        return isinstance(instance, bool)
+    if name == "integer":
+        return isinstance(instance, int) and not isinstance(instance, bool)
+    if name == "number":
+        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
+    if name == "null":
+        return instance is None
+    raise SchemaError(f"unsupported type {name}")
+
+
+def reject_unknown_keywords(schema: dict) -> None:
+    unknown = set(schema) - ALLOWED_KEYWORDS
+    if unknown:
+        raise SchemaError(f"unsupported schema keyword: {', '.join(sorted(unknown))}")
+    for key in ("properties", "$defs"):
+        for child in schema.get(key, {}).values():
+            if isinstance(child, dict):
+                reject_unknown_keywords(child)
+    additional = schema.get("additionalProperties")
+    if isinstance(additional, dict):
+        reject_unknown_keywords(additional)
+    items = schema.get("items")
+    if isinstance(items, dict):
+        reject_unknown_keywords(items)
+
+
+def escape(key: str) -> str:
+    return key.replace("~", "~0").replace("/", "~1")
+
+
+if __name__ == "__main__":
+    sys.exit(main())
diff --git a/tests/fixtures/device-report.json b/tests/fixtures/device-report.json
new file mode 100644
index 0000000..30eb23e
--- /dev/null
+++ b/tests/fixtures/device-report.json
@@ -0,0 +1,42 @@
+{
+  "app": {
+    "build": "12",
+    "bundleIdentifier": "com.getboolean.eikon",
+    "commit": "0123abc",
+    "packageKind": "tipa",
+    "version": "0.1.0"
+  },
+  "device": {
+    "chip": "M2",
+    "cpuFamily": "0xda33d83d",
+    "modelIdentifier": "iPad14,5"
+  },
+  "gates": {
+    "fixtureGate": {
+      "detail": "fixture entry",
+      "measuredAt": "2026-01-15T10:20:30Z",
+      "passed": true
+    }
+  },
+  "generatedAt": "2026-01-15T10:20:30Z",
+  "install": {
+    "evidence": {
+      "bundlePath": "/private/var/containers/Bundle/Application/<uuid>/Eikon.app",
+      "homeDirectory": "/var/mobile/Containers/Data/Application/<uuid>",
+      "markers": ["_TrollStore"]
+    },
+    "method": "trollStore"
+  },
+  "jit": {
+    "csDebugged": true,
+    "csDebuggedSeen": "afterTrollStoreRequest",
+    "probe": { "kind": "passed" },
+    "source": "trollStore",
+    "txm": { "basis": "os below 26", "enforced": false, "state": "absent" },
+    "usable": true
+  },
+  "memory": { "availableBytes": 5368709120 },
+  "notes": "Fixture report used by the test suites.",
+  "os": { "build": "21A329", "name": "iPadOS", "version": "17.0" },
+  "schemaVersion": 1
+}
diff --git a/tests/test_file_device_report.py b/tests/test_file_device_report.py
new file mode 100644
index 0000000..2d0cc0c
--- /dev/null
+++ b/tests/test_file_device_report.py
@@ -0,0 +1,78 @@
+"""Filing a device report: schema check, a stable name, and rejection."""
+
+import json
+import subprocess
+import sys
+from datetime import datetime
+from pathlib import Path
+
+import pytest
+
+ROOT = Path(__file__).resolve().parent.parent
+FILER = ROOT / "scripts" / "file_device_report.py"
+FIXTURE = ROOT / "tests" / "fixtures" / "device-report.json"
+SCHEMA = ROOT / "device-reports" / "schema.json"
+
+
+def _report():
+    return json.loads(FIXTURE.read_text(encoding="utf-8"))
+
+
+def _date_prefix(report) -> str:
+    text = report["generatedAt"].replace("Z", "+00:00")
+    return datetime.fromisoformat(text).date().isoformat()
+
+
+def _run(*args, stdin=None):
+    return subprocess.run(
+        [sys.executable, str(FILER), *args],
+        input=stdin,
+        text=True,
+        capture_output=True,
+        cwd=ROOT,
+    )
+
+
+def test_fixture_validates_against_the_schema(tmp_path):
+    result = _run("--check", "--out-dir", str(tmp_path), str(FIXTURE))
+    assert result.returncode == 0
+    assert list(tmp_path.iterdir()) == []
+
+
+def test_filing_a_valid_report_is_idempotent(tmp_path):
+    report = _report()
+    filed = _run("--out-dir", str(tmp_path), str(FIXTURE))
+    assert filed.returncode == 0
+    written = list(tmp_path.glob("*.json"))
+    assert len(written) == 1
+    assert written[0].name.startswith(_date_prefix(report))
+    assert filed.stdout.strip() == str(written[0])
+    assert json.loads(written[0].read_text(encoding="utf-8")) == report
+
+    again = _run("--out-dir", str(tmp_path), str(FIXTURE))
+    assert again.returncode == 0
+    assert list(tmp_path.glob("*.json")) == written
+
+    from_stdin = _run("--out-dir", str(tmp_path), "-", stdin=FIXTURE.read_text(encoding="utf-8"))
+    assert from_stdin.returncode == 0
+    assert list(tmp_path.glob("*.json")) == written
+    assert from_stdin.stdout.strip() == str(written[0])
+
+
+def _rejected(kind: str):
+    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
+    report = _report()
+    if kind == "missing":
+        report.pop(schema["required"][0])
+    elif kind == "extra":
+        report["notASchemaField"] = 1
+    else:
+        report["schemaVersion"] = report["schemaVersion"] + 1000
+    return report
+
+
+@pytest.mark.parametrize("kind", ["missing", "extra", "version"])
+def test_rejections_write_nothing(tmp_path, kind):
+    result = _run("--out-dir", str(tmp_path), "-", stdin=json.dumps(_rejected(kind)))
+    assert result.returncode != 0
+    assert list(tmp_path.iterdir()) == []

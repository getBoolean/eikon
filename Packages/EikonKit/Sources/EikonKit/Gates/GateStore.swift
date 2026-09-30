import EikonCore
import Foundation

/// The build a gate result was measured under. A passed result counts only under the
/// identical stamp.
public struct BuildStamp: Codable, Sendable, Equatable {
    /// App version, build and commit: a build number alone could repeat across versions,
    /// and development builds often reuse one across binaries.
    public var app: String
    /// OS build (`kern.osversion`), e.g. "21A329".
    public var os: String

    public init(app: String, os: String) {
        self.app = app
        self.os = os
    }

    /// The running app and OS build. If either can't be read, the stamp is unique to this
    /// process, so a pass recorded now never carries over to a later, possibly different,
    /// build.
    @MainActor
    public static func live() -> BuildStamp {
        let info = AppInfo.from(.main)
        let osBuild = LiveDeviceSystem.current().osBuild
        let app = info.commit == "unknown" ? "\(info.version) (\(info.build))" : "\(info.version) (\(info.build)) \(info.commit)"
        guard info.version != "unknown", info.build != "unknown", osBuild != "unknown" else {
            return BuildStamp(app: "\(app) \(UUID().uuidString)", os: osBuild)
        }
        return BuildStamp(app: app, os: osBuild)
    }
}

/// One stored gate result and the build it was measured under.
public struct GateEntry: Sendable, Equatable {
    public var name: GateName
    public var result: GateResult
    public var stamp: BuildStamp

    public init(name: GateName, result: GateResult, stamp: BuildStamp) {
        self.name = name
        self.result = result
        self.stamp = stamp
    }
}

/// Persisted device-gate results (`gates.json`). Lock-guarded; safe from any thread.
/// A pass counts only under the build it was measured on and reads as unmeasured after an
/// app or OS update. A failure stays a failure, marked stale, until the gate is recorded
/// again. Later splits (05: x18, 07: guestWindow) call `record`; 02 writes nothing.
public final class GateStore: @unchecked Sendable {
    private let file: PersistedFile<GatesDocument>
    private let stamp: BuildStamp
    private let lock = NSLock()
    private let notifications = DispatchQueue(label: "eikon.gates.onChange")
    private var document: GatesDocument
    private var readOnly: Bool
    private var changeHandler: (@Sendable () -> Void)?

    /// `directory` is `…/Application Support/Eikon` (a temp directory in tests); `current`
    /// is the build this process runs under.
    public init(directory: URL, current: BuildStamp) {
        file = PersistedFile(url: directory.appendingPathComponent("gates.json"))
        stamp = current
        do {
            let loaded = try file.load()
            document = loaded?.document ?? GatesDocument(gates: TolerantList())
            readOnly = loaded?.isReadOnly ?? false
        } catch {
            // Unreadable: start empty and let the next `record` replace it, so gates don't
            // go unsaved for good. `PersistedFile.save` still refuses a newer-format file.
            document = GatesDocument(gates: TolerantList())
            readOnly = false
        }
    }

    /// Application Support/Eikon/gates.json, current app + OS build.
    @MainActor
    public static func live() -> GateStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return GateStore(directory: support.appendingPathComponent("Eikon"), current: .live())
    }

    /// Called after each `record`, off the caller's thread and one call at a time;
    /// LibraryController uses it to recompute route decisions. Set once during app wiring.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    /// Stores `result` for `name` with the current build stamp, replacing any earlier
    /// result for that gate, and persists it. `measuredAt` is kept to whole seconds, as
    /// the file stores it.
    public func record(_ name: GateName, _ result: GateResult) {
        var result = result
        result.measuredAt = Date(timeIntervalSince1970: result.measuredAt.timeIntervalSince1970.rounded(.down))
        let gate = StoredGate(name: name.rawValue, result: result, stamp: stamp)
        let handler = lock.withLock {
            document.gates.elements.removeAll { $0.name == gate.name }
            document.gates.elements.append(gate)
            if !readOnly { try? file.save(document) }
            return changeHandler
        }
        if let handler {
            notifications.async(execute: handler)
        }
    }

    /// Every stored gate mapped through the expiry rules. Gates never recorded are absent,
    /// and the picker treats a missing gate as unmeasured.
    public func states() -> [GateName: GateState] {
        lock.withLock {
            Dictionary(document.gates.elements.map { (GateName(rawValue: $0.name), state(of: $0)) },
                       uniquingKeysWith: Self.firstWins)
        }
    }

    /// Results still meaningful on this build, for DeviceReport.make: everything measured
    /// under the current build, plus every failure with its original date.
    public func current() -> [String: GateResult] {
        lock.withLock {
            Dictionary(document.gates.elements
                .filter { $0.result.passed == false || $0.stamp == stamp }
                .map { ($0.name, $0.result) },
                uniquingKeysWith: Self.firstWins)
        }
    }

    /// Duplicate names only come from other writers. `record` keeps one decoded entry per
    /// name, and entries this build can't decode are written after it, so the first wins.
    private static func firstWins<Value>(_ first: Value, _: Value) -> Value { first }

    /// Everything stored, with the stamp each result was measured under.
    public func entries() -> [GateEntry] {
        lock.withLock {
            document.gates.elements.map { GateEntry(name: GateName(rawValue: $0.name), result: $0.result, stamp: $0.stamp) }
        }
    }

    private func state(of gate: StoredGate) -> GateState {
        switch (gate.result.passed, gate.stamp == stamp) {
        case (true?, true): .passed
        case (true?, false): .unmeasured
        case (false?, let sameBuild): .failed(stale: !sameBuild)
        case (nil, _): .unmeasured
        }
    }
}

/// Fields outside the ones `StoredGate` reads are dropped on rewrite, so storing anything
/// new per gate bumps `currentFormat`. New gate names don't.
private struct GatesDocument: PersistedDocument {
    static let currentFormat = 1
    var gates: TolerantList<StoredGate>
}

/// A gate keyed by its raw name, so gates this build doesn't know round-trip.
/// `measuredAt` is ISO-8601, as in DeviceReport.
private struct StoredGate: Codable, Sendable {
    var name: String
    var result: GateResult
    var stamp: BuildStamp

    private enum Key: String, CodingKey { case name, result, stamp }
    private enum ResultKey: String, CodingKey { case passed, detail, measuredAt }

    init(name: String, result: GateResult, stamp: BuildStamp) {
        self.name = name
        self.result = result
        self.stamp = stamp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        name = try container.decode(String.self, forKey: .name)
        stamp = try container.decode(BuildStamp.self, forKey: .stamp)
        let nested = try container.nestedContainer(keyedBy: ResultKey.self, forKey: .result)
        let measuredAt = try nested.decode(String.self, forKey: .measuredAt)
        result = GateResult(passed: try nested.decodeIfPresent(Bool.self, forKey: .passed),
                            detail: try nested.decode(String.self, forKey: .detail),
                            measuredAt: try Date(measuredAt, strategy: .iso8601))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(name, forKey: .name)
        try container.encode(stamp, forKey: .stamp)
        var nested = container.nestedContainer(keyedBy: ResultKey.self, forKey: .result)
        try nested.encodeIfPresent(result.passed, forKey: .passed)
        try nested.encode(result.detail, forKey: .detail)
        try nested.encode(result.measuredAt.formatted(.iso8601), forKey: .measuredAt)
    }
}

import Foundation

/// Whether Apple's Trusted Execution Monitor is on this device.
public enum TXMState: String, Codable, Sendable { case present, absent, unknown }

/// When CS_DEBUGGED was first observed in this process.
public enum CSDebuggedSeen: String, Codable, Sendable { case never, atLaunch, afterTrollStoreRequest, onForeground }

/// Where JIT came from, as far as the app can tell.
public enum JITSource: String, Codable, Sendable {
    case none, dopamine, rootlessJailbreak, trollStore, externalEnabler, preexisting, unknown
}

/// Why JIT isn't usable. The raw values key the status screen's wording.
public enum JITReasonCode: String, Codable, Sendable, CaseIterable {
    case dopamineJITOff              // toggle off, tweak injection disabled, safe mode, or Dopamine 2.0
    case rootlessJailbreakNoJIT      // a non-Dopamine /var/jb jailbreak without JIT
    case trollStoreRequestPending
    case trollStoreTimedOut          // TrollStore older than 2.0.12, or its URL scheme is off; Retry offered
    case sideloadedNoJIT
    case txmEnforced                 // JIT from a debugger isn't usable on this device yet
    case txmUndetermined             // iOS 26+ and TXM couldn't be ruled out
    case probeSkippedAfterCrash      // the previous launch died during the probe; Retry probe offered
    case probeFailed                 // unexpected; the probe outcome has the detail
    case unknownInstallNoJIT
    case simulator
}

public struct ProbeOutcome: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case notRun, passed, failed }
    public var kind: Kind
    /// Why it didn't run, or which step failed.
    public var detail: String?

    public init(kind: Kind, detail: String?) {
        self.kind = kind
        self.detail = detail
    }
}

public struct TXMInfo: Codable, Sendable, Equatable {
    public var state: TXMState
    /// True only on iOS 26+ with TXM present, or undetermined (treated as present).
    public var enforced: Bool
    /// How the state was decided; informational.
    public var basis: String

    public init(state: TXMState, enforced: Bool, basis: String) {
        self.state = state
        self.enforced = enforced
        self.basis = basis
    }
}

public enum TrollStoreRequestState: String, Codable, Sendable { case none, pending, timedOut }

public struct JITStatus: Codable, Sendable, Equatable {
    public var csDebugged: Bool
    public var csDebuggedSeen: CSDebuggedSeen
    public var txm: TXMInfo
    public var probe: ProbeOutcome
    public var source: JITSource
    /// Nil exactly when `usable`.
    public var reason: JITReasonCode?
    /// Can this process run generated code now? Encoded for reports; recomputed on decode.
    public var usable: Bool { csDebugged && probe.kind == .passed }

    public init(csDebugged: Bool, csDebuggedSeen: CSDebuggedSeen, txm: TXMInfo, probe: ProbeOutcome,
                source: JITSource, reason: JITReasonCode?) {
        self.csDebugged = csDebugged
        self.csDebuggedSeen = csDebuggedSeen
        self.txm = txm
        self.probe = probe
        self.source = source
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case csDebugged, csDebuggedSeen, txm, probe, source, reason, usable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        csDebugged = try c.decode(Bool.self, forKey: .csDebugged)
        csDebuggedSeen = try c.decode(CSDebuggedSeen.self, forKey: .csDebuggedSeen)
        txm = try c.decode(TXMInfo.self, forKey: .txm)
        probe = try c.decode(ProbeOutcome.self, forKey: .probe)
        source = try c.decode(JITSource.self, forKey: .source)
        reason = try c.decodeIfPresent(JITReasonCode.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(csDebugged, forKey: .csDebugged)
        try c.encode(csDebuggedSeen, forKey: .csDebuggedSeen)
        try c.encode(txm, forKey: .txm)
        try c.encode(probe, forKey: .probe)
        try c.encode(source, forKey: .source)
        try c.encode(reason, forKey: .reason)
        try c.encode(usable, forKey: .usable)
    }
}

/// Everything the policy needs, gathered by the controller (section 07).
public struct JITFacts: Sendable, Equatable {
    public var installMethod: InstallMethod
    public var csDebugged: Bool
    public var csDebuggedSeen: CSDebuggedSeen
    public var txm: TXMInfo
    public var trollStoreRequest: TrollStoreRequestState
    public var probeBlockedBySentinel: Bool

    public init(installMethod: InstallMethod, csDebugged: Bool, csDebuggedSeen: CSDebuggedSeen, txm: TXMInfo,
                trollStoreRequest: TrollStoreRequestState, probeBlockedBySentinel: Bool) {
        self.installMethod = installMethod
        self.csDebugged = csDebugged
        self.csDebuggedSeen = csDebuggedSeen
        self.txm = txm
        self.trollStoreRequest = trollStoreRequest
        self.probeBlockedBySentinel = probeBlockedBySentinel
    }
}

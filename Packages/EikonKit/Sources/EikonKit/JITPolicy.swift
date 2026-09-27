import Foundation

/// Pure decisions about JIT: when the probe may run, what the status is, and
/// when to ask TrollStore for JIT.
public enum JITPolicy {
    /// Minimum time between automatic TrollStore requests.
    public static let trollStoreCooldown: TimeInterval = 60

    /// The probe is only a confirmation: it runs only when it can't kill the process.
    public static func mayProbe(_ facts: JITFacts) -> Bool {
        facts.csDebugged
            && facts.installMethod != .simulator
            && !facts.txm.enforced
            && facts.txm.state != .unknown
            && !facts.probeBlockedBySentinel
    }

    public static func status(_ facts: JITFacts, probe: ProbeOutcome) -> JITStatus {
        var status = JITStatus(
            csDebugged: facts.csDebugged, csDebuggedSeen: facts.csDebuggedSeen, txm: facts.txm,
            probe: probe, source: source(facts), reason: nil
        )
        status.reason = status.usable ? nil : reason(facts, probe: probe)
        return status
    }

    public static func shouldRequestTrollStoreJIT(installMethod: InstallMethod, csDebugged: Bool,
                                                  triedThisProcess: Bool, lastAttempt: Date?,
                                                  now: Date, manual: Bool) -> Bool {
        guard installMethod == .trollStore || installMethod == .trollStoreLite, !csDebugged else { return false }
        if manual { return true }
        guard !triedThisProcess else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= trollStoreCooldown
    }

    private static func source(_ facts: JITFacts) -> JITSource {
        guard facts.csDebugged else { return .none }
        // `never` with the flag set can't normally happen; treat it as `atLaunch`.
        let seen = facts.csDebuggedSeen == .never ? .atLaunch : facts.csDebuggedSeen
        switch facts.installMethod {
        case .dopamine:
            return .dopamine
        case .rootlessJailbreak:
            return .rootlessJailbreak
        case .trollStore, .trollStoreLite:
            switch seen {
            case .afterTrollStoreRequest: return .trollStore
            case .onForeground: return .externalEnabler
            case .atLaunch, .never: return .preexisting
            }
        case .sideloaded:
            switch seen {
            case .onForeground, .afterTrollStoreRequest: return .externalEnabler
            case .atLaunch, .never: return .preexisting
            }
        case .simulator, .unknown:
            return .unknown
        }
    }

    private static func reason(_ facts: JITFacts, probe: ProbeOutcome) -> JITReasonCode {
        if facts.installMethod == .simulator { return .simulator }
        // Below iOS 26 the TXM derivation never yields `unknown`.
        if facts.txm.state == .unknown { return .txmUndetermined }
        if facts.txm.enforced { return .txmEnforced }
        if facts.probeBlockedBySentinel { return .probeSkippedAfterCrash }
        if facts.csDebugged { return .probeFailed }
        switch facts.installMethod {
        case .trollStore, .trollStoreLite:
            return facts.trollStoreRequest == .timedOut ? .trollStoreTimedOut : .trollStoreRequestPending
        case .dopamine: return .dopamineJITOff
        case .rootlessJailbreak: return .rootlessJailbreakNoJIT
        case .sideloaded: return .sideloadedNoJIT
        case .unknown, .simulator: return .unknownInstallNoJIT
        }
    }
}

import CEikonJIT
import Foundation
import Testing
@testable import EikonKit

private let absentTXM = TXMInfo(state: .absent, enforced: false, basis: "test")
private let enforcedTXM = TXMInfo(state: .present, enforced: true, basis: "test")
private let unknownTXM = TXMInfo(state: .unknown, enforced: true, basis: "test")

private func facts(
    install: InstallMethod = .dopamine,
    csDebugged: Bool = true,
    seen: CSDebuggedSeen = .atLaunch,
    txm: TXMInfo = absentTXM,
    request: TrollStoreRequestState = .none,
    sentinel: Bool = false
) -> JITFacts {
    JITFacts(installMethod: install, csDebugged: csDebugged, csDebuggedSeen: seen, txm: txm,
             trollStoreRequest: request, probeBlockedBySentinel: sentinel)
}

private let passed = ProbeOutcome(kind: .passed, detail: nil)
private let failed = ProbeOutcome(kind: .failed, detail: "test")
private let notRun = ProbeOutcome(kind: .notRun, detail: "test")

@Test func reasonIsPresentExactlyWhenNotUsable() {
    for install in InstallMethod.allCases {
        for csDebugged in [false, true] {
            for txm in [absentTXM, enforcedTXM, unknownTXM] {
                for probe in [notRun, passed, failed] {
                    let status = JITPolicy.status(facts(install: install, csDebugged: csDebugged, txm: txm), probe: probe)
                    #expect((status.reason == nil) == status.usable)
                }
            }
        }
    }
}

@Test func usableNeedsAPassedProbe() {
    for probe in [notRun, failed] {
        #expect(!JITPolicy.status(facts(), probe: probe).usable)
    }
    #expect(JITPolicy.status(facts(), probe: passed).usable)
}

@Test func mayProbeRefusesWhenUnsafe() {
    #expect(!JITPolicy.mayProbe(facts(csDebugged: false)))
    #expect(!JITPolicy.mayProbe(facts(txm: enforcedTXM)))
    #expect(!JITPolicy.mayProbe(facts(txm: unknownTXM)))
    #expect(!JITPolicy.mayProbe(facts(install: .simulator)))
    #expect(!JITPolicy.mayProbe(facts(sentinel: true)))

    #expect(JITPolicy.mayProbe(facts(install: .trollStore)))
    #expect(JITPolicy.mayProbe(facts(install: .dopamine)))
}

@Test func trollStoreAttributionNeedsARequest() {
    let requested = JITPolicy.status(facts(install: .trollStore, seen: .afterTrollStoreRequest), probe: passed)
    let atLaunch = JITPolicy.status(facts(install: .trollStore, seen: .atLaunch), probe: passed)
    #expect(requested.source == .trollStore)
    #expect(atLaunch.source != .trollStore)
}

@Test func shouldRequestTrollStoreJIT() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func ask(_ install: InstallMethod = .trollStore, tried: Bool = false, last: Date? = nil, manual: Bool = false) -> Bool {
        JITPolicy.shouldRequestTrollStoreJIT(installMethod: install, csDebugged: false, triedThisProcess: tried,
                                             lastAttempt: last, now: now, manual: manual)
    }
    #expect(ask())
    #expect(!ask(.sideloaded))
    #expect(!ask(tried: true))
    #expect(!ask(last: now))
    #expect(ask(last: .distantPast))
    #expect(ask(tried: true, last: now, manual: true))
}

@Test func unknownCPUFamiliesAreConservative() {
    let unlisted: UInt32 = 0xDEAD_BEEF
    #expect(JITPolicy.txmInfo(firmware: -1, osMajor: 26, cpuFamily: unlisted).enforced)
    #expect(!JITPolicy.txmInfo(firmware: -1, osMajor: 25, cpuFamily: unlisted).enforced)
}

@Test func probeOutcomeAndStatusRoundTrip() throws {
    let status = JITPolicy.status(facts(install: .sideloaded, csDebugged: false), probe: notRun)
    let encodedStatus = try JSONEncoder().encode(status)
    #expect(try JSONDecoder().decode(JITStatus.self, from: encodedStatus) == status)
    let keys = try JSONSerialization.jsonObject(with: encodedStatus) as? [String: Any]
    #expect(keys?["usable"] != nil)

    #expect(try JSONDecoder().decode(ProbeOutcome.self, from: JSONEncoder().encode(failed)) == failed)
}

@Test func probeOutcomeMapsCResult() {
    let passedResult = ProbeOutcome(eikon_probe_result(status: EIKON_PROBE_PASSED, signal: 0, error: 0))
    #expect(passedResult.kind == .passed)

    let failures = [
        EIKON_PROBE_ALLOC_FAILED,
        EIKON_PROBE_REMAP_FAILED,
        EIKON_PROBE_PROTECT_FAILED,
        EIKON_PROBE_PROTECTION_MISMATCH,
        EIKON_PROBE_WRONG_RESULT,
        EIKON_PROBE_SIGNAL,
    ]
    for status in failures {
        let outcome = ProbeOutcome(eikon_probe_result(status: status, signal: 1, error: 1))
        #expect(outcome.kind == .failed)
        #expect(outcome.detail?.isEmpty == false)
    }
}

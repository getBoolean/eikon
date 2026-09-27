#if canImport(UIKit)
import UIKit
#endif
import Combine
import Foundation

/// Owns JIT state for the process: gathers facts, asks TrollStore once, and
/// republishes whenever usability can change.
@MainActor
public final class JITController: ObservableObject {
    public static let shared = JITController(
        environment: .live,
        system: .live,
        defaults: .standard,
        openURL: { url in
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #else
            false
            #endif
        },
        clock: LiveJITClock(),
        bundleIdentifier: Bundle.main.bundleIdentifier,
        sentinel: ProbeSentinel.live(buildNumber: SystemInfo.buildNumber),
        store: .shared
    )

    @Published public private(set) var status: JITStatus
    @Published public private(set) var installMethod: InstallMethod
    @Published public private(set) var evidence: InstallEvidence
    @Published public private(set) var isRequestingTrollStoreJIT: Bool

    private let environment: any BundleEnvironment
    private let system: any JITSystem
    private let defaults: UserDefaults
    private let openURL: @MainActor (URL) async -> Bool
    private let clock: any JITClock
    private let bundleIdentifier: String?
    private let sentinel: ProbeSentinel
    private let store: JITStatusStore

    private var facts: JITFacts
    private var lastProbe: ProbeOutcome
    private var hasActivated = false
    private var triedTrollStoreThisProcess = false
    private var requestTask: Task<Void, Never>?

    private static let lastAttemptKey = "eikon.lastTrollStoreJITAttempt"
    /// How long to wait for TrollStore to set CS_DEBUGGED.
    private static let requestDeadline: TimeInterval = 10
    /// How often to re-read CS_DEBUGGED during a request.
    private static let pollInterval: TimeInterval = 0.2
    /// Pause after CS_DEBUGGED appears, so TrollStore's tracer has detached before the probe.
    private static let gracePeriod: TimeInterval = 0.3

    public init(environment: any BundleEnvironment,
                system: any JITSystem,
                defaults: UserDefaults,
                openURL: @escaping @MainActor (URL) async -> Bool,
                clock: any JITClock,
                bundleIdentifier: String?,
                sentinel: ProbeSentinel,
                store: JITStatusStore) {
        self.environment = environment
        self.system = system
        self.defaults = defaults
        self.openURL = openURL
        self.clock = clock
        self.bundleIdentifier = bundleIdentifier
        self.sentinel = sentinel
        self.store = store

        let detected = detectInstallMethod(environment)
        installMethod = detected.0
        evidence = detected.1
        isRequestingTrollStoreJIT = false
        facts = JITFacts(
            installMethod: detected.0,
            csDebugged: false,
            csDebuggedSeen: .never,
            txm: TXMInfo(state: .unknown, enforced: true, basis: "not gathered"),
            trollStoreRequest: .none,
            probeBlockedBySentinel: false
        )
        lastProbe = ProbeOutcome(kind: .notRun, detail: "not gathered")
        status = .placeholder
        store.update(status)
    }

    /// Reads install method, CS_DEBUGGED, TXM and the crash sentinel, then probes when that is safe.
    public func gatherFacts() {
        let detected = detectInstallMethod(environment)
        installMethod = detected.0
        evidence = detected.1
        let debugged = system.csDebugged()
        facts = JITFacts(
            installMethod: detected.0,
            csDebugged: debugged,
            csDebuggedSeen: debugged ? .atLaunch : .never,
            txm: system.txm(osMajor: SystemInfo.osMajor, cpuFamily: SystemInfo.cpuFamily),
            trollStoreRequest: .none,
            probeBlockedBySentinel: sentinel.consumeAtLaunch()
        )
        lastProbe = ProbeOutcome(kind: .notRun, detail: nil)
        runProbeIfAllowed()
        publish()
    }

    /// First activation may ask TrollStore for JIT. Later ones notice JIT that appeared while backgrounded.
    public func sceneBecameActive() {
        if !hasActivated {
            hasActivated = true
            let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
            if JITPolicy.shouldRequestTrollStoreJIT(
                installMethod: facts.installMethod,
                csDebugged: facts.csDebugged,
                triedThisProcess: triedTrollStoreThisProcess,
                lastAttempt: lastAttempt,
                now: clock.now(),
                manual: false
            ) {
                startTrollStoreRequest()
                return
            }
            if isTrollStoreFamily, !facts.csDebugged {
                facts.trollStoreRequest = .timedOut
                publish()
                return
            }
        }
        recheckCSDebugged()
    }

    /// Retry JIT button. Cooldown does not apply; an in-flight request is left alone.
    public func retryTrollStoreJIT() {
        guard requestTask == nil else { return }
        let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
        guard JITPolicy.shouldRequestTrollStoreJIT(
            installMethod: facts.installMethod,
            csDebugged: facts.csDebugged,
            triedThisProcess: triedTrollStoreThisProcess,
            lastAttempt: lastAttempt,
            now: clock.now(),
            manual: true
        ) else { return }
        startTrollStoreRequest()
    }

    /// Retry probe button. Clears a crash skip and a failed probe, then probes again when allowed.
    public func retryProbe() {
        facts.probeBlockedBySentinel = false
        if lastProbe.kind != .passed {
            lastProbe = ProbeOutcome(kind: .notRun, detail: nil)
        }
        let debugged = system.csDebugged()
        if debugged {
            if !facts.csDebugged {
                facts.csDebuggedSeen = .onForeground
            }
            facts.csDebugged = true
        }
        runProbeIfAllowed()
        publish()
    }

    /// Awaits the in-flight TrollStore request, if there is one.
    func waitForPendingRequest() async {
        await requestTask?.value
    }

    private var isTrollStoreFamily: Bool {
        facts.installMethod == .trollStore || facts.installMethod == .trollStoreLite
    }

    private func publish() {
        status = JITPolicy.status(facts, probe: lastProbe)
        store.update(status)
    }

    private func runProbeIfAllowed() {
        if lastProbe.kind == .passed { return }
        guard JITPolicy.mayProbe(facts) else {
            lastProbe = ProbeOutcome(kind: .notRun, detail: probeSkipDetail())
            return
        }
        do {
            try sentinel.arm()
        } catch {
            lastProbe = ProbeOutcome(kind: .notRun, detail: "sentinel")
            return
        }
        lastProbe = system.probe()
        sentinel.disarm()
    }

    private func probeSkipDetail() -> String {
        if facts.installMethod == .simulator { return "simulator" }
        if facts.probeBlockedBySentinel { return "skipped after crash" }
        if facts.txm.enforced || facts.txm.state == .unknown { return "TXM" }
        if !facts.csDebugged { return "no CS_DEBUGGED" }
        return "not run"
    }

    private func recheckCSDebugged() {
        guard requestTask == nil else { return }
        let debugged = system.csDebugged()
        guard debugged, !facts.csDebugged else { return }
        facts.csDebugged = true
        facts.csDebuggedSeen = .onForeground
        runProbeIfAllowed()
        publish()
    }

    private func startTrollStoreRequest() {
        guard requestTask == nil else { return }
        defaults.set(clock.now(), forKey: Self.lastAttemptKey)
        defaults.synchronize()
        triedTrollStoreThisProcess = true
        isRequestingTrollStoreJIT = true
        facts.trollStoreRequest = .pending
        publish()

        guard let url = trollStoreJITURL() else {
            finishRequestTimedOut()
            return
        }

        requestTask = Task { @MainActor in
            let opened = await self.openURL(url)
            if !opened {
                self.finishRequestTimedOut()
                self.requestTask = nil
                return
            }

            let start = self.clock.now()
            var arrived = false
            while self.clock.now().timeIntervalSince(start) < Self.requestDeadline {
                try? await self.clock.sleep(seconds: Self.pollInterval)
                if self.system.csDebugged() {
                    arrived = true
                    break
                }
            }

            if arrived {
                self.facts.csDebugged = true
                self.facts.csDebuggedSeen = .afterTrollStoreRequest
                try? await self.clock.sleep(seconds: Self.gracePeriod)
                self.runProbeIfAllowed()
                self.facts.trollStoreRequest = .none
                self.isRequestingTrollStoreJIT = false
                self.publish()
            } else {
                self.finishRequestTimedOut()
            }
            self.requestTask = nil
        }
    }

    private func finishRequestTimedOut() {
        facts.trollStoreRequest = .timedOut
        isRequestingTrollStoreJIT = false
        publish()
    }

    private func trollStoreJITURL() -> URL? {
        guard let bundleIdentifier else { return nil }
        var components = URLComponents()
        components.scheme = "apple-magnifier"
        components.host = "enable-jit"
        components.queryItems = [URLQueryItem(name: "bundle-id", value: bundleIdentifier)]
        return components.url
    }
}

import CEikonJIT
import Foundation

/// Seam over the C layer and sysctl so tests inject facts without a device.
public protocol JITSystem: Sendable {
    func csDebugged() -> Bool
    func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo
    func probe() -> ProbeOutcome
}

public struct LiveJITSystem: JITSystem {
    public init() {}

    public func csDebugged() -> Bool {
        var flags: UInt32 = 0
        guard eikon_cs_flags(&flags) == 0 else { return false }
        return (flags & UInt32(EIKON_CS_DEBUGGED)) != 0
    }

    public func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo {
        #if targetEnvironment(simulator)
        return TXMInfo(state: .absent, enforced: false, basis: "simulator")
        #else
        return JITPolicy.txmInfo(
            firmware: Int32(eikon_txm_firmware_present()),
            osMajor: osMajor,
            cpuFamily: cpuFamily
        )
        #endif
    }

    public func probe() -> ProbeOutcome {
        #if targetEnvironment(simulator)
        return ProbeOutcome(kind: .notRun, detail: "simulator")
        #else
        return ProbeOutcome(eikon_jit_probe())
        #endif
    }
}

extension JITSystem where Self == LiveJITSystem {
    public static var live: LiveJITSystem { LiveJITSystem() }
}

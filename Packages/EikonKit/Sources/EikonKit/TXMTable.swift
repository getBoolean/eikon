/// First iOS major version on which TXM is enforced, per CPU family
/// (`hw.cpufamily`, the CPUFAMILY_ARM_* values), or nil for "no TXM".
/// Only confirmed families are listed; unlisted ones are treated as enforced
/// on iOS 26+. Device reports correct this table over time.
let txmFirstEnforcedMajor: [UInt32: Int?] = [
    0xDA33_D83D: 26,  // CPUFAMILY_ARM_BLIZZARD_AVALANCHE (A15): enforced on iOS 26+
]

extension JITPolicy {
    /// - Parameter firmware: 1 present, 0 absent, -1 undeterminable
    ///   (from `eikon_txm_firmware_present`).
    public static func txmInfo(firmware: Int32, osMajor: Int, cpuFamily: UInt32) -> TXMInfo {
        switch firmware {
        case 1:
            return TXMInfo(state: .present, enforced: osMajor >= 26, basis: "firmware")
        case 0:
            return TXMInfo(state: .absent, enforced: false, basis: "firmware")
        default:
            break
        }
        guard osMajor >= 26 else {
            return TXMInfo(state: .absent, enforced: false, basis: "os below 26")
        }
        switch txmFirstEnforcedMajor[cpuFamily] {
        case .some(.some(let first)):
            return TXMInfo(state: .present, enforced: osMajor >= first, basis: "cpufamily heuristic")
        case .some(.none):
            return TXMInfo(state: .absent, enforced: false, basis: "cpufamily heuristic")
        case .none:
            return TXMInfo(state: .unknown, enforced: true, basis: "cpufamily heuristic")
        }
    }
}

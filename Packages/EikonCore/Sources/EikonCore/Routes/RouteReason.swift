/// Why a route has its verdict. Codes only; the app maps them to sentences.
public enum RouteReason: Sendable, Equatable {
    case engineNotHandled(Engine)
    case needsWindowsBinary, needsLinuxBinary
    case architectureUnsupported(CPUArchitecture)
    case needsJIT
    /// Without JIT, only 32-bit Windows games can run.
    case box64Only32Bit
    /// Box64 is demoted behind FEX when JIT is usable, but still runnable.
    case fexPreferredWithJIT
    case gateFailed(GateName, stale: Bool)
    case gateUnmeasured(GateName)
    case notInThisBuild
    case runtimeDeclined(RuntimeDeclineCode)
    /// A native route for this engine comes first.
    case nativeFirst
    case overriddenByUser
}

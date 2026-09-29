/// A gate's measured result. A missing entry means `unmeasured`.
public enum GateState: Sendable, Equatable {
    case passed
    /// `stale`: it failed before an app or OS update and hasn't been re-checked since.
    case failed(stale: Bool)
    case unmeasured
}

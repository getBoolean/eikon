import EikonCore

public protocol GameDataCleanup: Sendable {
    /// Delete route-owned data (saves etc.) for a game. Called once per removal on this device.
    func removeData(for game: GameID) async
}

public protocol GameDataMerge: Sendable {
    /// Move route-owned data from one game id to another after a merge.
    func mergeData(from: GameID, into: GameID) async
}

/// The hooks save-owning routes register. Nothing registers in split 02.
@MainActor
public final class GameDataHooks {
    public private(set) var cleanups: [any GameDataCleanup] = []
    public private(set) var merges: [any GameDataMerge] = []

    public init() {}

    public func register(_ hook: any GameDataCleanup) {
        cleanups.append(hook)
    }

    public func register(_ hook: any GameDataMerge) {
        merges.append(hook)
    }
}

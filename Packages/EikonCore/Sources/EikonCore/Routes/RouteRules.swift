/// What each route needs, in one data-like place. Splits 05 and 07 may adjust it.
enum RouteRules {
    struct Rule: Sendable {
        enum Target: Sendable {
            /// A native engine runtime.
            case engine(Engine)
            /// A main executable of this platform with one of these architectures.
            case executable(GamePlatform, Set<CPUArchitecture>)
        }

        let target: Target
        let needsJIT: Bool
        /// Gates required whatever the architecture.
        var gates: [GateName] = []
        /// Further gates required by the executable's architecture.
        var gatesByArchitecture: [CPUArchitecture: [GateName]] = [:]

        func requiredGates(for architecture: CPUArchitecture?) -> [GateName] {
            gates + (architecture.flatMap { gatesByArchitecture[$0] } ?? [])
        }
    }

    /// Exhaustive, so a new route can't go unclassified.
    static func rule(for route: RouteID) -> Rule {
        switch route {
        case .nativeKirikiri:
            Rule(target: .engine(.kirikiri), needsJIT: false)
        case .nativeRenPy:
            Rule(target: .engine(.renpy), needsJIT: false)
        case .wineFEX:
            // Windows ARM64 code keeps its TEB in x18, which Darwin clears.
            Rule(target: .executable(.windows, [.i386, .amd64]), needsJIT: true, gates: [.x18],
                 gatesByArchitecture: [.i386: [.guestWindow]])
        case .wineBox64:
            // Still runs Wine's ARM64 modules, so it needs x18 too.
            Rule(target: .executable(.windows, [.i386]), needsJIT: false, gates: [.x18, .guestWindow])
        case .linuxFEX:
            Rule(target: .executable(.linux, [.amd64]), needsJIT: true)
        }
    }

    /// The engine's native route, if it has one.
    static func nativeRoute(for engine: Engine) -> RouteID? {
        switch engine {
        case .kirikiri: .nativeKirikiri
        case .renpy: .nativeRenPy
        case .unity, .gameMaker, .bgi, .unknown: nil
        }
    }
}

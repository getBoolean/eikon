import Foundation

/// What was running when a session started. Codes and ids only, never a title.
public struct SessionRecord: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case running, background

        /// An unknown phase reads as `running`: the conservative choice that still reports.
        public init(from decoder: any Decoder) throws {
            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .running
        }
    }

    /// The route recorded for developer test sessions.
    public static let testRoute = "test"

    public var sessionID: UUID
    public var gameID: GameID
    public var engine: Engine
    public var architecture: CPUArchitecture?
    /// A `RouteID` raw value, or `testRoute`; possibly a route from a newer build.
    public var route: String
    public var appBuild: String
    public var startedAt: Date
    public var phase: Phase

    public init(sessionID: UUID = UUID(), gameID: GameID, engine: Engine, architecture: CPUArchitecture?,
                route: String, appBuild: String, startedAt: Date, phase: Phase = .running) {
        self.sessionID = sessionID
        self.gameID = gameID
        self.engine = engine
        self.architecture = architecture
        self.route = route
        self.appBuild = appBuild
        self.startedAt = startedAt
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, gameID, engine, architecture, route, appBuild, startedAt, phase
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        gameID = try container.decode(GameID.self, forKey: .gameID)
        engine = (try? container.decode(Engine.self, forKey: .engine)) ?? .unknown
        architecture = try? container.decodeIfPresent(CPUArchitecture.self, forKey: .architecture)
        route = (try? container.decode(String.self, forKey: .route)) ?? ""
        appBuild = (try? container.decode(String.self, forKey: .appBuild)) ?? ""
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        phase = (try? container.decode(Phase.self, forKey: .phase)) ?? .running
    }
}

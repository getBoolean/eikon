import Foundation

/// A typed setting. Per-game keys are stored as `game/<uuid>/<name>`, global keys as
/// `<name>`; enum values are stored as their raw strings.
///
/// Reserved namespaces, owned by later splits (02 defines no keys there; the store keeps
/// them like any unknown key):
/// - `fex.*`: split 05
/// - `controls.*`: split 04
/// - `codePage`: split 09
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public enum Scope: Sendable { case game, global }

    /// A stable dotted name.
    public let name: String
    public let scope: Scope

    public init(name: String, scope: Scope) {
        self.name = name
        self.scope = scope
    }

    /// The key in the map; nil when the scope doesn't match (a game key without a game,
    /// or a global key with one), which reads as unset and writes nothing.
    func storageKey(game: UUID?) -> String? {
        switch scope {
        case .game: game.map { SettingPath.key(game: $0, name: name) }
        case .global: game == nil ? name : nil
        }
    }
}

extension SettingKey where Value == String {
    /// Unset by default: the UI falls back to the first location's folder name. A title
    /// in practice, so it never enters logs, reports or issues.
    public static var displayName: SettingKey<String> { SettingKey(name: "displayName", scope: .game) }

    /// A route's raw value; absent (or unknown) means Automatic.
    public static var routeOverride: SettingKey<String> { SettingKey(name: "route.override", scope: .game) }

    /// Global `merged/<uuid>`: the game this merged-away game now resolves to, as a UUID string.
    public static func merged(_ game: UUID) -> SettingKey<String> {
        SettingKey(name: "merged/\(game.uuidString.lowercased())", scope: .global)
    }
}

extension SettingKey where Value == Int64 {
    /// Wall-clock millis, for display only; shadowing uses the entry's timestamp.
    public static var deletedAt: SettingKey<Int64> { SettingKey(name: SettingPath.deletedAtName, scope: .game) }
}

extension SettingKey where Value == JSONValue {
    /// Fingerprint `fp/<scheme>/<digest>`, keyed by a digest of the value itself, so two
    /// devices adding different fingerprints never overwrite each other and equal ones
    /// share a key. The store keeps the newest `SettingsStore.fingerprintCap` live.
    public static func fingerprint(scheme: Int, digest: String) -> SettingKey<JSONValue> {
        SettingKey(name: "\(SettingPath.fingerprintPrefix)\(scheme)/\(digest)", scope: .game)
    }
}

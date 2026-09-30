/// How a game can run. Persist it as its raw string only (settings, session records), so a
/// route from a newer build reads as unknown instead of failing to decode.
public enum RouteID: String, Sendable, CaseIterable {
    case nativeKirikiri = "native-kirikiri", nativeRenPy = "native-renpy"
    case wineFEX = "wine-fex", wineBox64 = "wine-box64", linuxFEX = "linux-fex"
}

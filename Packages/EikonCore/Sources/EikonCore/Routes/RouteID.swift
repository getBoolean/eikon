/// How a game can run.
public enum RouteID: String, Codable, Sendable, CaseIterable {
    case nativeKirikiri = "native-kirikiri", nativeRenPy = "native-renpy"
    case wineFEX = "wine-fex", wineBox64 = "wine-box64", linuxFEX = "linux-fex"
}

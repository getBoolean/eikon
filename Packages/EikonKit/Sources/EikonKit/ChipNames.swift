/// Display names for model identifiers. Missing entries are "unknown"; reports correct the table.
/// Never used for TXM or policy decisions.
public enum ChipNames {
    public static func displayName(forModel identifier: String) -> String {
        names[identifier] ?? "unknown"
    }

    /// iPhone and iPad models that run iOS 15 or later on A12 or newer, plus M-series iPads.
    private static let names: [String: String] = [
        "iPhone11,2": "A12", "iPhone11,4": "A12", "iPhone11,6": "A12", "iPhone11,8": "A12",
        "iPhone12,1": "A13", "iPhone12,3": "A13", "iPhone12,5": "A13", "iPhone12,8": "A13",
        "iPhone13,1": "A14", "iPhone13,2": "A14", "iPhone13,3": "A14", "iPhone13,4": "A14",
        "iPhone14,2": "A15", "iPhone14,3": "A15", "iPhone14,4": "A15", "iPhone14,5": "A15",
        "iPhone14,6": "A15", "iPhone14,7": "A15", "iPhone14,8": "A15",
        "iPhone15,2": "A16", "iPhone15,3": "A16", "iPhone15,4": "A16", "iPhone15,5": "A16",
        "iPhone16,1": "A17 Pro", "iPhone16,2": "A17 Pro",
        "iPhone17,1": "A18 Pro", "iPhone17,2": "A18 Pro", "iPhone17,3": "A18", "iPhone17,4": "A18",
        "iPhone17,5": "A18",
        "iPad8,1": "A12X", "iPad8,2": "A12X", "iPad8,3": "A12X", "iPad8,4": "A12X",
        "iPad8,5": "A12X", "iPad8,6": "A12X", "iPad8,7": "A12X", "iPad8,8": "A12X",
        "iPad8,9": "A12Z", "iPad8,10": "A12Z", "iPad8,11": "A12Z", "iPad8,12": "A12Z",
        "iPad11,1": "A12", "iPad11,2": "A12", "iPad11,3": "A12", "iPad11,4": "A12",
        "iPad11,6": "A12", "iPad11,7": "A12",
        "iPad12,1": "A13", "iPad12,2": "A13",
        "iPad13,1": "A14", "iPad13,2": "A14",
        "iPad13,4": "M1", "iPad13,5": "M1", "iPad13,6": "M1", "iPad13,7": "M1",
        "iPad13,8": "M1", "iPad13,9": "M1", "iPad13,10": "M1", "iPad13,11": "M1",
        "iPad13,16": "M1", "iPad13,17": "M1",
        "iPad13,18": "A14", "iPad13,19": "A14",
        "iPad14,1": "A15", "iPad14,2": "A15",
        "iPad14,3": "M2", "iPad14,4": "M2", "iPad14,5": "M2", "iPad14,6": "M2",
        "iPad14,8": "M2", "iPad14,9": "M2", "iPad14,10": "M2", "iPad14,11": "M2",
        "iPad15,3": "M3", "iPad15,4": "M3", "iPad15,5": "M3", "iPad15,6": "M3",
        "iPad15,7": "A16", "iPad15,8": "A16",
        "iPad16,1": "A17 Pro", "iPad16,2": "A17 Pro",
        "iPad16,3": "M4", "iPad16,4": "M4", "iPad16,5": "M4", "iPad16,6": "M4",
    ]
}

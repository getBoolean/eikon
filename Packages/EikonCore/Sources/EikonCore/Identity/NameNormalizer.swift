import Foundation

/// The one normalization of file and folder names: listings, lookups, name sets and the
/// matcher's folder-name comparison all go through it.
public enum NameNormalizer {
    /// NFC, trimmed, case-folded without a locale. NFC again after folding, which can
    /// decompose, so a normalized name normalizes to itself.
    public static func normalize(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}

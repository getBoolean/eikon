import Foundation

/// Lookups for the maps in this folder. Core code returns codes; these turn keys into text.
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    /// A plural from Localizable.stringsdict, e.g. `library.count.games`.
    static func count(_ key: String, _ value: Int) -> String {
        String.localizedStringWithFormat(string(key), value)
    }

    /// The text for `key`, or nil when no strings file has it.
    static func existing(_ key: String) -> String? {
        let missing = "\u{1}missing\u{1}"
        let text = NSLocalizedString(key, value: missing, comment: "")
        return text == missing ? nil : text
    }
}

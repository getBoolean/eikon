import Foundation

/// One entry of `Acknowledgements.json`, written by `scripts/credits.py app-json`.
public struct Acknowledgement: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    /// Kept as written; the view links it only when it parses as a URL.
    public let url: String
    public let revision: String
    /// An SPDX expression.
    public let license: String
    public let licenseText: String
    /// Eikon's own entry. Absent in files from before the flag, which read as components.
    public let isApp: Bool

    public var id: String { "\(name)\u{0}\(revision)" }

    private enum CodingKeys: String, CodingKey {
        case name, url, revision, license, licenseText, isApp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        revision = try container.decode(String.self, forKey: .revision)
        license = try container.decode(String.self, forKey: .license)
        licenseText = try container.decode(String.self, forKey: .licenseText)
        isApp = try container.decodeIfPresent(Bool.self, forKey: .isApp) ?? false
    }
}

public enum AcknowledgementsError: Error, Sendable, Equatable {
    case missing
    case malformed
}

/// The bundled acknowledgements: the app's own entry first, then components in file order.
public struct Acknowledgements: Sendable {
    public let entries: [Acknowledgement]

    public var app: Acknowledgement? { entries.first { $0.isApp } }
    public var components: [Acknowledgement] { entries.filter { !$0.isApp } }

    /// Decodes the generator's format, a JSON array. Throws on malformed input.
    public static func decode(_ data: Data) throws -> Acknowledgements {
        let decoded = try JSONDecoder().decode([Acknowledgement].self, from: data)
        return Acknowledgements(entries: decoded.filter(\.isApp) + decoded.filter { !$0.isApp })
    }

    /// `Acknowledgements.json` from the bundle; never traps.
    public static func load(bundle: Bundle = .main) -> Result<Acknowledgements, AcknowledgementsError> {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "json") else { return .failure(.missing) }
        guard let data = try? Data(contentsOf: url), let acknowledgements = try? decode(data) else {
            return .failure(.malformed)
        }
        return .success(acknowledgements)
    }
}

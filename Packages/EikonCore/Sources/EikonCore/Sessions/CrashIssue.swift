import Foundation

/// Builds a prefilled GitHub issue URL. The game appears as its report id, plus its display
/// name when the caller passes one: the user reviews the issue before submitting it, so
/// sharing the name is their choice. Never a folder name, fingerprint or hash.
public enum CrashIssue {
    public static let maxURLLength = 7_500
    /// The last N breadcrumbs considered before length trimming.
    public static let maxBreadcrumbs = 20

    /// Device facts as codes, filled by the app from its device report.
    public struct Device: Sendable, Equatable {
        public var appVersion, appBuild, appCommit: String
        public var modelIdentifier, osVersion, osBuild: String
        public var installMethod: String
        public var jitUsable: Bool
        public var jitSource: String?
        public var jitReasonCode: String?

        public init(appVersion: String, appBuild: String, appCommit: String, modelIdentifier: String,
                    osVersion: String, osBuild: String, installMethod: String, jitUsable: Bool,
                    jitSource: String?, jitReasonCode: String?) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.appCommit = appCommit
            self.modelIdentifier = modelIdentifier
            self.osVersion = osVersion
            self.osBuild = osBuild
            self.installMethod = installMethod
            self.jitUsable = jitUsable
            self.jitSource = jitSource
            self.jitReasonCode = jitReasonCode
        }
    }

    public struct Built: Sendable, Equatable {
        public var url: URL
        /// Dropped to fit the length limit; above zero the caller offers the clipboard report.
        public var droppedBreadcrumbs: Int
    }

    /// The first 8 characters of the game's random UUID, lowercased.
    public static func reportID(for game: GameID) -> String {
        game.reportID
    }

    public static func url(repository: URL, entry: CrashEntry, device: Device, reportID: String,
                           gameName: String? = nil) -> Built {
        var crumbs = Array(entry.breadcrumbs.sorted { $0.seq < $1.seq }.suffix(maxBreadcrumbs))
        var dropped = 0
        while true {
            let url = build(repository: repository, entry: entry, device: device, reportID: reportID,
                            gameName: gameName, crumbs: crumbs)
            if url.absoluteString.count <= maxURLLength || crumbs.isEmpty {
                return Built(url: url, droppedBreadcrumbs: dropped)
            }
            crumbs.removeFirst()
            dropped += 1
        }
    }

    private static func build(repository: URL, entry: CrashEntry, device: Device, reportID: String,
                              gameName: String?, crumbs: [Breadcrumb]) -> URL {
        let record = entry.record
        let start = record.startedAt
        var fields: [(String, String)] = [
            ("template", "crash.yml"),
            ("labels", "crash"),
            ("title", "Crash: \(entry.outcome.code), \(record.engine.rawValue), \(record.route)"),
            ("outcome", entry.outcome.code),
            ("engine", record.engine.rawValue),
            ("arch", record.architecture?.rawValue ?? ""),
            ("route", record.route),
            ("game", reportID),
        ]
        if let gameName, !gameName.isEmpty {
            fields.append(("name", gameName))
        }
        fields += [
            ("app", "\(device.appVersion) (\(device.appBuild)) \(device.appCommit)"),
            ("device", "\(device.modelIdentifier), \(device.osVersion) (\(device.osBuild))"),
            ("install", device.installMethod),
            ("jit", "usable=\(device.jitUsable) source=\(device.jitSource ?? "-") reason=\(device.jitReasonCode ?? "-")"),
        ]
        if let fault = entry.fault {
            fields.append(("fault", "signal \(fault.signal) pc 0x\(String(fault.pc, radix: 16))"))
        }
        fields.append(("breadcrumbs", crumbs.map { crumb in
            let offset = (crumb.time.timeIntervalSince(start) * 1000).rounded()
            let millis = offset.isFinite ? Int64(max(min(offset, 1e15), -1e15)) : 0
            return "\(crumb.seq) +\(millis)ms \(crumb.code) \(crumb.a) \(crumb.b)"
        }.joined(separator: "\n")))

        var components = URLComponents(url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        return components.url!
    }

    /// RFC 3986 unreserved characters only; everything else, `+` included, is encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

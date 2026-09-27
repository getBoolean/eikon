import EikonKit
import SwiftUI
import UIKit

@MainActor
enum ReportExport {
    /// Puts the report JSON on the general pasteboard.
    static func copy(_ report: DeviceReport) throws {
        UIPasteboard.general.string = String(decoding: try report.encode(), as: UTF8.self)
    }

    /// Writes the report over any previous file of the same name and returns that URL.
    static func temporaryFile(for report: DeviceReport) throws -> URL {
        let data = try report.encode()
        let day = utcDay.string(from: report.generatedAt)
        let name = "eikon-report-\(day)-\(sanitize(report.device.modelIdentifier))-\(sanitize(report.install.method.rawValue)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static let utcDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func sanitize(_ value: String) -> String {
        String(value.map { character in
            guard let ascii = character.asciiValue else { return "_" }
            switch ascii {
            case 44, 45, 46, 48...57, 65...90, 95, 97...122:
                return character
            default:
                return "_"
            }
        })
    }
}

/// SwiftUI bridge for UIActivityViewController. ShareLink needs iOS 16.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

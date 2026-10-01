import EikonCore
import EikonKit
import SwiftUI

/// A route decision as a row shows it: the verdict only; reasons are on the detail screen.
enum RouteBadge: CaseIterable {
    case runnable, warning, planned, override, unavailable

    init(_ decision: RouteDecision) {
        guard let chosen = decision.chosen else {
            self = .unavailable
            return
        }
        if decision.isOverride {
            self = .override
            return
        }
        switch chosen.verdict {
        case .runnable: self = .runnable
        case .runnableWithWarnings: self = .warning
        case .planned: self = .planned
        case .unavailable: self = .unavailable
        }
    }

    var systemImage: String {
        switch self {
        case .runnable: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .planned: "clock"
        case .override: "hand.point.right.fill"
        case .unavailable: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .runnable: .green
        case .warning: .orange
        case .planned, .unavailable: .secondary
        case .override: .accentColor
        }
    }
}

/// What one library row shows, built from the controller's published values.
struct LibraryRowContent {
    var name: String
    var engine: Engine?
    var architectures: [CPUArchitecture]
    /// nil while the route is still being decided.
    var badge: RouteBadge?
    /// Every location is on a drive other than the built-in one.
    var onOtherDrivesOnly: Bool
    /// nil when the game is ready.
    var status: GameStatus?
    /// Full-hash progress while identifying.
    var progress: Double?

    init(name: String, engine: Engine?, architectures: [CPUArchitecture], badge: RouteBadge?,
         onOtherDrivesOnly: Bool, status: GameStatus?, progress: Double? = nil) {
        self.name = name
        self.engine = engine
        self.architectures = architectures
        self.badge = badge
        self.onOtherDrivesOnly = onOtherDrivesOnly
        self.status = status
        self.progress = progress
    }

    init(game: LibraryGame, decision: RouteDecision?, drives: [DriveSummary], progress: [UUID: Double]) {
        let builtIn = Set(drives.filter { $0.drive.kind == .builtIn }.map(\.id))
        self.init(
            name: game.displayName,
            engine: game.detection?.engine,
            architectures: GamePlatform.allCases.compactMap { game.detection?.executables[$0]?.architecture },
            badge: decision.map(RouteBadge.init),
            onOtherDrivesOnly: !game.locations.contains { builtIn.contains($0.driveID) },
            status: game.status == .ready ? nil : game.status,
            progress: game.status == .identifying ? game.locations.compactMap { progress[$0.id] }.max() : nil)
    }

    var detail: String? {
        let parts = (engine.map { [EngineStrings.name($0)] } ?? []) + architectures.map(EngineStrings.name)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct LibraryRow: View {
    let content: LibraryRowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: content.name)
                    .font(.headline)
                if content.onOtherDrivesOnly {
                    Image(systemName: "externaldrive")
                        .foregroundColor(.secondary)
                        .accessibilityLabel(Text("library.otherDriveOnly"))
                }
                Spacer()
                if let badge = content.badge {
                    Label(GameStrings.badgeKey(badge), systemImage: badge.systemImage)
                        .font(.caption)
                        .foregroundColor(badge.color)
                }
            }
            if let detail = content.detail {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let status = content.status {
                HStack(spacing: 6) {
                    Text(LibraryStrings.statusKey(status))
                    if let progress = content.progress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 80)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
struct LibraryRow_Previews: PreviewProvider {
    private static let statuses: [GameStatus?] = [
        nil, .identifying, .waitingForCopy, .suggestion, .driveNotConnected, .missing, .fingerprintFailed,
    ]

    static var previews: some View {
        List {
            ForEach(statuses.indices, id: \.self) { index in
                Section {
                    ForEach(RouteBadge.allCases, id: \.self) { badge in
                        LibraryRow(content: LibraryRowContent(
                            name: "Sample Game", engine: .unity, architectures: [.amd64], badge: badge,
                            onOtherDrivesOnly: index == 4, status: statuses[index],
                            progress: statuses[index] == .identifying ? 0.4 : nil))
                    }
                }
            }
            LibraryRow(content: LibraryRowContent(name: "Sample Game", engine: nil, architectures: [], badge: nil,
                                                  onOtherDrivesOnly: true, status: nil))
        }
    }
}
#endif

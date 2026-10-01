import EikonCore
import EikonKit
import SwiftUI

/// The last session ended badly: what happened, and what to do about it. The game's name
/// is shown on screen only.
struct CrashBannerView: View {
    let banner: CrashBanner
    let clipboardNotice: Bool
    let onTryAlternative: () -> Void
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                Text(CrashStrings.outcomeKey(banner.outcome))
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("crash.dismiss"))
            }
            if let name = banner.gameName {
                Text(verbatim: name)
            }
            Text(L10n.format("crash.banner.route", RouteStrings.name(recorded: banner.route),
                             banner.startedAt.formatted(date: .abbreviated, time: .shortened)))
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack {
                if let alternative = banner.alternative {
                    Button(L10n.format("crash.tryAlternative", RouteStrings.name(alternative)), action: onTryAlternative)
                        .buttonStyle(.bordered)
                }
                Button("crash.report", action: onReport)
                    .buttonStyle(.bordered)
            }
            if clipboardNotice {
                Text("crash.clipboardNotice")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
struct CrashBannerView_Previews: PreviewProvider {
    static func banner(_ outcome: SessionOutcome, alternative: RouteID?) -> CrashBanner {
        let record = SessionRecord(gameID: .random(), engine: .unity, architecture: .amd64,
                                   route: RouteID.wineFEX.rawValue, appBuild: "1", startedAt: Date())
        let entry = CrashEntry(id: record.sessionID, record: record, outcome: outcome, breadcrumbs: [], fault: nil,
                               recordedAt: Date())
        return CrashBanner(id: entry.id, entry: entry, outcome: outcome, gameName: "Sample Game", route: record.route,
                           startedAt: record.startedAt, alternative: alternative)
    }

    static let outcomes: [SessionOutcome] = [.crashed(signal: 11, pc: 0x1000), .likelyMemoryKill, .endedUnexpectedly]

    static var previews: some View {
        List {
            ForEach(outcomes.indices, id: \.self) { index in
                CrashBannerView(banner: banner(outcomes[index], alternative: .wineBox64), clipboardNotice: index == 0,
                                onTryAlternative: {}, onReport: {}, onDismiss: {})
                CrashBannerView(banner: banner(outcomes[index], alternative: nil), clipboardNotice: false,
                                onTryAlternative: {}, onReport: {}, onDismiss: {})
            }
        }
    }
}
#endif

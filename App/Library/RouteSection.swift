import EikonCore
import EikonKit
import SwiftUI

/// How the game would run: the chosen route with its reasons, then every candidate in
/// preference order. The candidate list is the override picker: Automatic, or any route,
/// runnable or not, with its reasons inline.
struct RouteSection: View {
    let decision: RouteDecision?
    /// The stored override; nil is Automatic.
    let override: RouteID?
    let jitReason: JITReasonCode?
    let onSelect: (RouteID?) -> Void

    var body: some View {
        Section(header: Text("route.section.chosen")) {
            if let decision {
                chosen(decision)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("route.deciding")
                }
            }
        }
        if let decision {
            Section(header: Text("route.section.candidates"), footer: Text("route.override.footer")) {
                choice(nil, selected: override == nil) {
                    Text("route.override.automatic")
                }
                ForEach(decision.candidates, id: \.route) { candidate in
                    choice(candidate.route, selected: override == candidate.route) {
                        CandidateView(candidate: candidate, jitReason: jitReason)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chosen(_ decision: RouteDecision) -> some View {
        if let chosen = decision.chosen {
            CandidateView(candidate: chosen, jitReason: jitReason)
            if decision.isOverride && !decision.overrideWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("route.override.warning", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    ForEach(decision.overrideWarnings.indices, id: \.self) { index in
                        Text(RouteStrings.reasonText(decision.overrideWarnings[index], jitReason: jitReason))
                            .font(.footnote)
                    }
                }
            }
        } else {
            Text("route.none")
        }
    }

    private func choice(_ route: RouteID?, selected: Bool, @ViewBuilder label: () -> some View) -> some View {
        Button {
            onSelect(route)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                label()
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A route's name, verdict and every reason as a sentence.
private struct CandidateView: View {
    let candidate: RouteCandidate
    let jitReason: JITReasonCode?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(RouteStrings.name(candidate.route))
                    .font(.body.weight(.semibold))
                Text(RouteStrings.verdictKey(candidate.verdict))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(candidate.reasons.indices, id: \.self) { index in
                Text(RouteStrings.reasonText(candidate.reasons[index], jitReason: jitReason))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#if DEBUG
struct RouteSection_Previews: PreviewProvider {
    /// Every verdict, and one of each reason across the candidates.
    static let candidates: [RouteCandidate] = [
        RouteCandidate(route: .nativeKirikiri, verdict: .runnable, reasons: [.nativeFirst]),
        RouteCandidate(route: .wineFEX, verdict: .runnableWithWarnings,
                       reasons: [.gateUnmeasured(.x18), .fexPreferredWithJIT]),
        RouteCandidate(route: .wineBox64, verdict: .planned, reasons: [.notInThisBuild, .box64Only32Bit]),
        RouteCandidate(route: .linuxFEX, verdict: .unavailable,
                       reasons: [.needsLinuxBinary, .needsJIT, .gateFailed(.x18, stale: false),
                                 .gateFailed(.guestWindow, stale: true), .gateUnmeasured(GateName(rawValue: "future"))]),
        RouteCandidate(route: .nativeRenPy, verdict: .unavailable,
                       reasons: [.engineNotHandled(.kirikiri), .needsWindowsBinary, .architectureUnsupported(.arm64),
                                 .runtimeDeclined(RuntimeDeclineCode(rawValue: "sample")), .overriddenByUser]),
    ]

    static var previews: some View {
        Group {
            List {
                RouteSection(decision: RouteDecision(chosen: candidates[0], candidates: candidates, isOverride: false,
                                                     overrideWarnings: []),
                             override: nil, jitReason: .sideloadedNoJIT, onSelect: { _ in })
            }
            List {
                RouteSection(decision: RouteDecision(chosen: candidates[3], candidates: candidates, isOverride: true,
                                                     overrideWarnings: candidates[3].reasons),
                             override: .linuxFEX, jitReason: nil, onSelect: { _ in })
            }
            List {
                RouteSection(decision: RouteDecision(chosen: nil, candidates: candidates, isOverride: false,
                                                     overrideWarnings: []),
                             override: nil, jitReason: nil, onSelect: { _ in })
                RouteSection(decision: nil, override: nil, jitReason: nil, onSelect: { _ in })
            }
        }
        .listStyle(.insetGrouped)
    }
}
#endif

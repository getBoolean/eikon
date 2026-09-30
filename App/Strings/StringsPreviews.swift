#if DEBUG
import EikonCore
import EikonKit
import SwiftUI

/// Renders every mapped code, so a missing key shows up as a raw key in the canvas.
/// Payload cases get one representative value each; the exhaustive switches in the maps
/// force a new case to be added here too.
struct StringsPreviews: View {
    private let reasons: [RouteReason] = [
        .engineNotHandled(.unity), .needsWindowsBinary, .needsLinuxBinary, .architectureUnsupported(.arm64),
        .needsJIT, .box64Only32Bit, .fexPreferredWithJIT, .gateFailed(.x18, stale: false),
        .gateFailed(.x18, stale: true), .gateUnmeasured(.guestWindow), .notInThisBuild,
        .runtimeDeclined(RuntimeDeclineCode(rawValue: "sample")), .nativeFirst, .overriddenByUser,
    ]
    private let outcomes: [SessionOutcome] = [
        .crashed(signal: 11, pc: 0x1000), .likelyMemoryKill, .endedUnexpectedly, .killedInBackground,
    ]
    private let gateStates: [GateState] = [.passed, .failed(stale: false), .failed(stale: true), .unmeasured]
    private let verdicts: [RouteVerdict] = [.runnable, .runnableWithWarnings, .planned, .unavailable]
    private let statuses: [GameStatus] = [
        .ready, .identifying, .waitingForCopy, .suggestion, .driveNotConnected, .missing, .fingerprintFailed,
    ]
    private let driveStates: [DriveState] = [.available, .notConnected, .needsRelink]
    private let refusals: [DriveRefusal] = [.iCloud, .network, .unknownVolume, .overlapsDrive, .unreadable]
    private let imports: [ImportOutcome] = [
        .imported(UUID()), .noGameFound, .nameClash, .nameTaken, .insufficientSpace, .driveUnavailable, .cancelled, .failed,
    ]

    var body: some View {
        List {
            Section(header: Text(verbatim: "Routes")) {
                ForEach(RouteID.allCases, id: \.self) { Text(RouteStrings.name($0)) }
                Text(RouteStrings.name(recorded: SessionRecord.testRoute))
                ForEach(verdicts.indices, id: \.self) { Text(RouteStrings.verdictKey(verdicts[$0])) }
            }
            Section(header: Text(verbatim: "Reasons")) {
                ForEach(reasons.indices, id: \.self) { index in
                    Text(RouteStrings.reasonText(reasons[index], jitReason: .sideloadedNoJIT))
                }
                Text(RouteStrings.reasonText(.needsJIT, jitReason: nil))
            }
            Section(header: Text(verbatim: "Gates")) {
                Text(GateStrings.name(.x18))
                Text(GateStrings.name(.guestWindow))
                Text(GateStrings.name(GateName(rawValue: "futureGate")))
                ForEach(gateStates.indices, id: \.self) { Text(GateStrings.stateKey(gateStates[$0])) }
            }
            Section(header: Text(verbatim: "Engines")) {
                ForEach(Engine.allCases, id: \.self) { Text(EngineStrings.name($0)) }
                ForEach(CPUArchitecture.allCases, id: \.self) { Text(EngineStrings.name($0)) }
                ForEach(GamePlatform.allCases, id: \.self) { Text(EngineStrings.key($0)) }
                ForEach(UnityScripting.allCases, id: \.self) { Text(EngineStrings.key($0)) }
                ForEach(KirikiriFlavor.allCases, id: \.self) { Text(EngineStrings.key($0)) }
                ForEach(GameMakerBuild.allCases, id: \.self) { Text(EngineStrings.key($0)) }
                Text(EngineStrings.text(.exact(7, 4, 11)))
                Text(EngineStrings.text(.era(from: (8, 0), through: (8, 3))))
            }
            Section(header: Text(verbatim: "Crashes")) {
                ForEach(outcomes.indices, id: \.self) { Text(CrashStrings.outcomeKey(outcomes[$0])) }
            }
            Section(header: Text(verbatim: "Library")) {
                ForEach(statuses.indices, id: \.self) { Text(LibraryStrings.statusKey(statuses[$0])) }
                Text(LibraryStrings.suggestion(otherGame: "Sample"))
                Text("identity.merge")
                Text("identity.keepSeparate")
                Text("identity.sameGameAs")
                Text("identity.differentGame")
                Text(L10n.count("library.count.games", 1))
                Text(L10n.count("library.count.games", 3))
            }
            Section(header: Text(verbatim: "Drives and import")) {
                ForEach(driveStates.indices, id: \.self) { Text(LibraryStrings.driveStateKey(driveStates[$0])) }
                ForEach(refusals.indices, id: \.self) { Text(LibraryStrings.refusalKey(refusals[$0])) }
                ForEach(imports.indices, id: \.self) { Text(LibraryStrings.importOutcomeKey(imports[$0])) }
                Text(L10n.count("drives.count.drives", 2))
                Text(L10n.count("import.count.files", 1))
                Text(L10n.count("import.count.bytes", 5))
            }
        }
    }
}

struct StringsPreviews_Previews: PreviewProvider {
    static var previews: some View {
        StringsPreviews()
    }
}
#endif

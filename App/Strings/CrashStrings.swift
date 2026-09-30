import EikonCore
import SwiftUI

enum CrashStrings {
    /// The signal and pc of a crash are shown as numbers elsewhere, not in the sentence.
    static func outcomeKey(_ outcome: SessionOutcome) -> LocalizedStringKey {
        switch outcome {
        case .crashed: "crash.outcome.crashed"
        case .likelyMemoryKill: "crash.outcome.likelyMemoryKill"
        case .endedUnexpectedly: "crash.outcome.endedUnexpectedly"
        case .killedInBackground: "crash.outcome.killedInBackground"
        }
    }
}

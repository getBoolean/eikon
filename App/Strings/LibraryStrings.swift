import EikonCore
import EikonKit
import SwiftUI

enum LibraryStrings {
    static func statusKey(_ status: GameStatus) -> LocalizedStringKey {
        switch status {
        case .ready: "library.status.ready"
        case .identifying: "library.status.identifying"
        case .waitingForCopy: "library.status.waitingForCopy"
        case .suggestion: "library.status.suggestion"
        case .driveNotConnected: "library.status.driveNotConnected"
        case .missing: "library.status.missing"
        case .fingerprintFailed: "library.status.fingerprintFailed"
        }
    }

    static func driveStateKey(_ state: DriveState) -> LocalizedStringKey {
        switch state {
        case .available: "drives.state.available"
        case .notConnected: "drives.state.notConnected"
        case .needsRelink: "drives.state.needsRelink"
        }
    }

    static func refusalKey(_ refusal: DriveRefusal) -> LocalizedStringKey {
        switch refusal {
        case .iCloud: "drives.refusal.iCloud"
        case .network: "drives.refusal.network"
        case .unknownVolume: "drives.refusal.unknownVolume"
        case .overlapsDrive: "drives.refusal.overlapsDrive"
        case .unreadable: "drives.refusal.unreadable"
        }
    }

    static func importOutcomeKey(_ outcome: ImportOutcome) -> LocalizedStringKey {
        switch outcome {
        case .imported: "import.outcome.imported"
        case .noGameFound: "import.outcome.noGameFound"
        case .nameClash: "import.outcome.nameClash"
        case .nameTaken: "import.outcome.nameTaken"
        case .insufficientSpace: "import.outcome.insufficientSpace"
        case .driveUnavailable: "import.outcome.driveUnavailable"
        case .cancelled: "import.outcome.cancelled"
        case .failed: "import.outcome.failed"
        }
    }

    /// The suggestion card; the display name appears on screen only.
    static func suggestion(otherGame displayName: String) -> String {
        L10n.format("identity.suggestion", displayName)
    }
}

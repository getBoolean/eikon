import EikonCore
import EikonKit
import SwiftUI
import UIKit

/// The library screens' own presentation states: route badges, launch captions and drive
/// names. Exhaustive: a new case fails the build until it has a key.
enum GameStrings {
    static func badgeKey(_ badge: RouteBadge) -> LocalizedStringKey {
        switch badge {
        case .runnable: "route.verdict.runnable"
        case .warning: "route.verdict.runnableWithWarnings"
        case .planned: "route.verdict.planned"
        case .override: "route.badge.override"
        case .unavailable: "route.badge.unavailable"
        }
    }

    /// The line under a disabled Launch button; nil when there is nothing to explain.
    static func launchCaptionKey(_ state: LaunchState) -> LocalizedStringKey? {
        switch state {
        case .ready, .deciding: nil
        case .confirmFirst: "game.launch.forced"
        case .planned: "game.launch.planned"
        case .noRoute: "game.launch.noRoute"
        case .driveNotConnected: "game.launch.driveNotConnected"
        case .missing: "game.launch.missing"
        }
    }

    static func launchFailureKey(_ failure: LaunchFailure) -> LocalizedStringKey {
        switch failure {
        case .sessionActive: "game.launch.failed.sessionActive"
        case .driveNotConnected: "game.launch.driveNotConnected"
        case .missing: "game.launch.missing"
        case .other: "game.launch.failed"
        }
    }

    static func identityFailureKey(_ failure: IdentityFailure) -> LocalizedStringKey {
        switch failure {
        case .unreadable: "identity.failure.unreadable"
        case .driveUnavailable: "identity.failure.driveUnavailable"
        }
    }

    /// "On My iPad/Eikon" or "On My iPhone/Eikon" for the built-in drive; the folder's
    /// name for any other.
    @MainActor
    static func driveLabel(_ drive: GameDrive) -> String {
        switch drive.kind {
        case .builtIn: builtInDriveName
        case .folder: drive.label
        }
    }

    @MainActor
    static var builtInDriveName: String {
        L10n.string(UIDevice.current.userInterfaceIdiom == .pad ? "drives.builtIn.pad" : "drives.builtIn.phone")
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

import EikonCore
import SwiftUI

enum EngineStrings {
    static func key(_ engine: Engine) -> String {
        switch engine {
        case .unity: "engine.unity"
        case .kirikiri: "engine.kirikiri"
        case .renpy: "engine.renpy"
        case .gameMaker: "engine.gameMaker"
        case .bgi: "engine.bgi"
        case .unknown: "engine.unknown"
        }
    }

    static func name(_ engine: Engine) -> String {
        L10n.string(key(engine))
    }

    static func key(_ architecture: CPUArchitecture) -> String {
        switch architecture {
        case .i386: "arch.i386"
        case .amd64: "arch.amd64"
        case .arm64: "arch.arm64"
        case .other: "arch.other"
        }
    }

    static func name(_ architecture: CPUArchitecture) -> String {
        L10n.string(key(architecture))
    }

    static func key(_ platform: GamePlatform) -> LocalizedStringKey {
        switch platform {
        case .windows: "engine.platform.windows"
        case .linux: "engine.platform.linux"
        }
    }

    static func key(_ scripting: UnityScripting) -> LocalizedStringKey {
        switch scripting {
        case .mono: "engine.unity.mono"
        case .il2cpp: "engine.unity.il2cpp"
        }
    }

    static func key(_ flavor: KirikiriFlavor) -> LocalizedStringKey {
        switch flavor {
        case .krkr2: "engine.kirikiri.krkr2"
        case .krkrZ: "engine.kirikiri.krkrZ"
        case .unknown: "engine.kirikiri.unknown"
        }
    }

    static func key(_ build: GameMakerBuild) -> LocalizedStringKey {
        switch build {
        case .vm: "engine.gameMaker.vm"
        case .yyc: "engine.gameMaker.yyc"
        }
    }

    /// "Version 7.4.11", or a range for versions inferred from the layout.
    static func text(_ version: RenPyVersion) -> String {
        switch version.kind {
        case .exact:
            let numbers = [version.major, version.minor] + (version.patch.map { [$0] } ?? [])
            return L10n.format("engine.renpy.exact", numbers.map(String.init).joined(separator: "."))
        case .era:
            let upper = version.maxMajor.flatMap { major in version.maxMinor.map { "\(major).\($0)" } } ?? "…"
            return L10n.format("engine.renpy.era", "\(version.major).\(version.minor)–\(upper)")
        }
    }
}

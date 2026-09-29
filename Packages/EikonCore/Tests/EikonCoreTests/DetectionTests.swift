import Foundation
import Testing
import EikonCore

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func detect(_ url: URL) throws -> DetectionResult? {
    try GameDetector.detect(folder: url)
}

private func samePath(_ lhs: String?, _ rhs: String) -> Bool {
    lhs.map(FolderListing.normalize) == FolderListing.normalize(rhs)
}

// MARK: Types and entry point

@Test func emptyFolderIsNoGame() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try detect(dir) == nil)
}

@Test(arguments: [
    (Fixtures.peI386, CPUArchitecture.i386), (Fixtures.peAMD64, .amd64), (0xAA64, .arm64),
    (0xA641, .arm64), (0xA64E, .arm64), (0x01C4, .other),
])
func loneExeIsUnknownEngineWithItsArchitecture(machine: UInt16, architecture: CPUArchitecture) throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.pe(machine: machine), to: "Game.exe", in: dir)
        let result = try #require(try detect(dir))
        #expect(result.engine == .unknown)
        #expect(result.executables[.windows]?.architecture == architecture)
    }
}

@Test func singleWrapperFolderIsFollowed() throws {
    try withTempDir { dir in
        let inner = try Fixtures.unity(.mono, named: "Inner", in: dir)
        try Fixtures.write("notes", to: "readme.txt", in: dir)
        let result = try #require(try detect(dir))
        #expect(result.engine == .unity)
        #expect(result.gameRoot == inner.lastPathComponent)
    }
}

@Test func wrapperHoldingTwoGamesIsNotAccepted() throws {
    try withTempDir { dir in
        _ = try Fixtures.unity(.mono, named: "First", in: dir)
        _ = try Fixtures.kirikiri(flavor: nil, named: "Second", in: dir)
        #expect(try detect(dir) == nil)
    }
}

@Test func storedResultWithUnknownValuesDecodesToFallbacks() throws {
    try withTempDir { dir in
        let result = try #require(try detect(try Fixtures.unity(.mono, in: dir)))
        var json = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"\(Engine.unity.rawValue)\"", with: "\"futureEngine\"")
        json = json.replacingOccurrences(of: "\"\(CPUArchitecture.amd64.rawValue)\"", with: "\"futureArch\"")
        let decoded = try JSONDecoder().decode(DetectionResult.self, from: Data(json.utf8))
        #expect(decoded.engine == .unknown)
        #expect(decoded.executables[.windows]?.architecture == .other)
    }
}

@Test func resultDoesNotDependOnListingOrder() throws {
    try withTempDir { dir in
        let names = ["Alpha.exe", "Beta.exe", "data.xp3", "extra.tpm"]
        func build(_ folder: String, _ order: [String]) throws -> URL {
            let root = dir.appendingPathComponent(folder)
            for name in order {
                let data = name.hasSuffix(".exe") ? Fixtures.pe(machine: Fixtures.peI386)
                    : name.hasSuffix(".xp3") ? Fixtures.xp3(index: .raw) : Data(count: 4)
                try Fixtures.write(data, to: name, in: root)
            }
            return root
        }
        let forward = try detect(try build("One", names))
        let backward = try detect(try build("Two", names.reversed()))
        #expect(forward != nil)
        #expect(forward == backward)
    }
}

// MARK: FolderListing / FolderReader

@Test func markersAreFoundInAnyLetterCase() throws {
    try withTempDir { dir in
        let unity = dir.appendingPathComponent("U")
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, dll: true), to: "unityplayer.DLL", in: unity)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64), to: "Game.exe", in: unity)
        let kirikiri = dir.appendingPathComponent("K")
        try Fixtures.write(Fixtures.xp3(index: .raw), to: "DATA.XP3", in: kirikiri)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: kirikiri)

        #expect(try detect(unity)?.engine == .unity)
        let result = try #require(try detect(kirikiri))
        #expect(result.engine == .kirikiri)
        #expect(result.details.xp3IndexReadable == true)
    }
}

@Test func stemsPairAcrossUnicodeNormalizationForms() throws {
    try withTempDir { dir in
        let stem = "Caf\u{E9}"
        let exe = stem.precomposedStringWithCanonicalMapping + ".exe"
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64), to: exe, in: dir)
        try Fixtures.write(Data(count: 64),
                           to: stem.decomposedStringWithCanonicalMapping + "_Data/globalgamemanagers", in: dir)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, padTo: 64 << 10), to: "Zeta.exe", in: dir)
        let result = try #require(try detect(dir))
        #expect(result.engine == .unity)
        #expect(samePath(result.executables[.windows]?.path, exe))
    }
}

@Test(arguments: [false, true])
func zlibCompressedXP3IndexDecodes(continuation: Bool) throws {
    try withTempDir { dir in
        let root = try Fixtures.kirikiri(flavor: nil, index: .zlib, continuation: continuation, in: dir)
        #expect(try detect(root)?.details.xp3IndexReadable == true)
    }
}

// MARK: Ren'Py

@Test(arguments: [
    (Fixtures.RenPyEra.scriptVersion, RenPyVersionKind.exact), (.vcVersion, .exact), (.initPy, .exact), (.libEra, .era),
])
func renpyEraLayoutsReportTheirVersionKind(era: Fixtures.RenPyEra, kind: RenPyVersionKind) throws {
    try withTempDir { dir in
        let version = [6, 99, 14]
        let result = try #require(try detect(try Fixtures.renpy(era, version: version, in: dir)))
        #expect(result.engine == .renpy)
        let detected = try #require(result.details.renpyVersion)
        #expect(detected.kind == kind)
        if kind == .exact {
            #expect([detected.major, detected.minor, detected.patch] == version)
        }
    }
}

@Test func renpyListsGameNativeModulesButNotEngineFiles() throws {
    try withTempDir { dir in
        let root = try Fixtures.renpy(.libEra, in: dir)
        let game = ["fastpath.so", "helper.pyd"]
        try Fixtures.write(Data(count: 4), to: "game/python-packages/pkg/\(game[0])", in: root)
        try Fixtures.write(Data(count: 4), to: "game/\(game[1])", in: root)
        try Fixtures.write(Data(count: 4), to: "lib/py3-windows-x86_64/engine.dll", in: root)
        let result = try #require(try detect(root))
        #expect(result.details.renpyNativeExtensions == game.sorted())
    }
}

@Test func renpyExecutablesAreThePairedLaunchers() throws {
    try withTempDir { dir in
        let root = try Fixtures.renpy(.vcVersion, in: dir)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, padTo: 64 << 10), to: "Other.exe", in: root)
        let result = try #require(try detect(root))
        #expect(samePath(result.executables[.windows]?.path, "Game.exe"))
        let linux = try #require(result.executables[.linux])
        #expect(linux.format == .elf)
        #expect(samePath(linux.path, "lib/py3-linux-x86_64/Game"))
    }
}

// MARK: Unity

@Test(arguments: [(Fixtures.UnityLayout.mono, UnityScripting.mono), (.il2cpp, .il2cpp), (.pre2017, .mono)])
func unityLayoutsAreRecognizedWithTheirBackend(layout: Fixtures.UnityLayout, scripting: UnityScripting) throws {
    try withTempDir { dir in
        let result = try #require(try detect(try Fixtures.unity(layout, in: dir)))
        #expect(result.engine == .unity)
        #expect(result.details.unityScripting == scripting)
        #expect(samePath(result.executables[.windows]?.path, "Game.exe"))
    }
}

@Test func unityFolderWithBothBinariesReportsBothPlatforms() throws {
    try withTempDir { dir in
        let result = try #require(try detect(try Fixtures.unity(.mono, linux: true, in: dir)))
        #expect(result.executables[.windows]?.architecture == .amd64)
        #expect(result.executables[.linux]?.architecture == .amd64)
        #expect(samePath(result.executables[.linux]?.path, "Game.x86_64"))
    }
}

// MARK: Kirikiri

@Test func kirikiriReportsPluginBaseNames() throws {
    try withTempDir { dir in
        let plugins = ["extrans.tpm", "wuvorbis.tpm"]
        let root = try Fixtures.kirikiri(flavor: nil, tpm: plugins, in: dir)
        try Fixtures.write(Data(count: 4), to: "plugin/sample.dll", in: root)
        let result = try #require(try detect(root))
        #expect(result.details.pluginFileNames == (plugins + ["sample.dll"]).sorted())
    }
}

@Test(arguments: [
    ("TVP(KIRIKIRI) 2 core / Scripting Platform for Win32", KirikiriFlavor.krkr2),
    ("TVP(KIRIKIRI) Z core / Scripting Platform for Win32", .krkrZ),
])
func kirikiriFlavorComesFromTheVersionResource(product: String, flavor: KirikiriFlavor) throws {
    try withTempDir { dir in
        let result = try #require(try detect(try Fixtures.kirikiri(flavor: product, in: dir)))
        #expect(result.details.kirikiriFlavor == flavor)
    }
}

@Test(arguments: [false, true])
func xp3ProtectedBitIsReported(protected: Bool) throws {
    try withTempDir { dir in
        let result = try #require(try detect(try Fixtures.kirikiri(flavor: nil, protectedEntry: protected, in: dir)))
        #expect(result.details.xp3ProtectedFlag == protected)
    }
}

@Test func garbageXP3IndexIsUnreadableButStillKirikiri() throws {
    try withTempDir { dir in
        let result = try #require(try detect(try Fixtures.kirikiri(flavor: nil, index: .garbage, in: dir)))
        #expect(result.engine == .kirikiri)
        #expect(result.details.xp3IndexReadable == false)
    }
}

// MARK: GameMaker

@Test(arguments: [(true, GameMakerBuild.vm), (false, .yyc)])
func gameMakerBuildFollowsTheCodeChunk(hasCode: Bool, build: GameMakerBuild) throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.gameMaker(hasCode: hasCode), to: "data.win", in: dir)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
        let result = try #require(try detect(dir))
        #expect(result.engine == .gameMaker)
        #expect(result.details.gameMakerBuild == build)
    }
}

@Test func formWithoutGEN8IsNotGameMaker() throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.gameMaker(hasGEN8: false, hasCode: true), to: "data.win", in: dir)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
        #expect(try detect(dir)?.engine == .unknown)
    }
}

// MARK: BGI

@Test func bgiExecutableIsRecognized() throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "BGI.exe", in: dir)
        #expect(try detect(dir)?.engine == .bgi)
    }
}

@Test(arguments: ["PackFile    ", "BURIKO ARC20"])
func twoBGIArchivesAreRecognized(magic: String) throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.bgiArc(magic: magic), to: "data01.arc", in: dir)
        try Fixtures.write(Fixtures.bgiArc(magic: magic), to: "data02.arc", in: dir)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
        #expect(try detect(dir)?.engine == .bgi)
    }
}

@Test func archivesWithoutTheMagicAreNotBGI() throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.bgiArc(magic: "OtherPack000"), to: "data01.arc", in: dir)
        try Fixtures.write(Fixtures.bgiArc(magic: "OtherPack000"), to: "data02.arc", in: dir)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
        #expect(try detect(dir)?.engine == .unknown)
    }
}

// MARK: PE / ELF

@Test func peHeaderBeyondFourKiBParses() throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, lfanew: 0x1400), to: "Game.exe", in: dir)
        #expect(try detect(dir)?.executables[.windows]?.architecture == .amd64)
    }
}

@Test func dllIsNeverAnExecutable() throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peAMD64, dll: true), to: "Game.exe", in: dir)
        #expect(try detect(dir) == nil)
    }
}

@Test(arguments: [(Fixtures.elfAMD64, CPUArchitecture.amd64), (Fixtures.elfAArch64, .arm64)])
func elfMachineMapsToArchitecture(machine: UInt16, architecture: CPUArchitecture) throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.elf(machine: machine), to: "Game.x86_64", in: dir)
        #expect(try detect(dir)?.executables[.linux]?.architecture == architecture)
    }
}

@Test func shellScriptIsNotAnELF() throws {
    try withTempDir { dir in
        try Fixtures.write("#!/bin/sh\necho start\n", to: "Game", in: dir)
        #expect(try detect(dir) == nil)
    }
}

// MARK: Main executable selection

@Test func installersAndRedistributablesAreNeverChosen() throws {
    try withTempDir { dir in
        let big = 64 << 10
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386), to: "Game.exe", in: dir)
        for name in ["setup.exe", "unins000.exe", "vc_redist.x86.exe", "DXSETUP.exe"] {
            try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386, padTo: big), to: name, in: dir)
        }
        #expect(samePath(try detect(dir)?.executables[.windows]?.path, "Game.exe"))
    }
}

@Test func guiExecutableBeatsALargerConsoleOne() throws {
    try withTempDir { dir in
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386, gui: true), to: "Window.exe", in: dir)
        try Fixtures.write(Fixtures.pe(machine: Fixtures.peI386, gui: false, padTo: 64 << 10), to: "Console.exe", in: dir)
        #expect(samePath(try detect(dir)?.executables[.windows]?.path, "Window.exe"))
    }
}

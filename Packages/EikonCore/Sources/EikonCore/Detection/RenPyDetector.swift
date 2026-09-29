import Foundation

enum RenPyDetector {
    private static let nativeExtensions: Set<String> = ["pyd", "so", "dll", "dylib"]
    private static let walkDepth = 8
    private static let walkEntries = 20_000

    static func detect(_ listing: FolderListing, _ reader: FolderReader) -> EngineMatch? {
        guard let renpy = listing.directory(named: "renpy"), let game = listing.directory(named: "game"),
              let renpyListing = try? listing.listing(of: renpy),
              let gameListing = try? listing.listing(of: game) else { return nil }
        let lib = listing.directory(named: "lib")
        let hasInit = ["__init__.py", "__init__.pyc", "__init__.pyo"].contains { renpyListing.file(named: $0) != nil }
        let hasScripts = !gameListing.files(withExtension: "rpyc").isEmpty || !gameListing.files(withExtension: "rpa").isEmpty
        guard hasInit || hasScripts || lib != nil else { return nil }

        let libListing = lib.flatMap { try? listing.listing(of: $0) }
        let details = EngineDetails(
            renpyVersion: version(reader, renpy: (renpy.name, renpyListing), game: (game.name, gameListing), lib: libListing),
            renpyNativeExtensions: nativeModules(in: gameListing))
        return EngineMatch(engine: .renpy, details: details,
                           executables: executables(listing, reader, lib: libListing))
    }

    // MARK: Version

    private static func version(_ reader: FolderReader, renpy: (name: String, listing: FolderListing),
                                game: (name: String, listing: FolderListing), lib: FolderListing?) -> RenPyVersion? {
        func text(_ folder: (name: String, listing: FolderListing), _ file: String) -> String? {
            folder.listing.file(named: file).flatMap { reader.text("\(folder.name)/\($0.name)") }
        }
        if let text = text(game, "script_version.txt"), let numbers = versions(in: text, after: #"[^0-9]*"#).first {
            return exact(numbers)
        }
        if let text = text(renpy, "vc_version.py"),
           let numbers = versions(in: text, after: #"(?m)^\s*version\s*=\s*["']"#).first {
            return exact(numbers)
        }
        // 7.5/8.0-era sources hold one version_tuple per Python major; the lib layout picks.
        if let text = text(renpy, "__init__.py") {
            let tuples = versions(in: text, after: #"(?m)^\s*version_tuple\s*=\s*\w*\s*\("#)
            let python3 = lib.map { lib in lib.entries.contains { $0.key.hasPrefix("py3-") || $0.key.hasPrefix("python3") } }
            let chosen = python3 == true ? tuples.first { $0[0] >= 8 } ?? tuples.first
                : tuples.min { $0[0] < $1[0] }
            if let chosen { return exact(chosen) }
        }
        return lib.flatMap(era)
    }

    private static func exact(_ numbers: [Int]) -> RenPyVersion {
        .exact(numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
    }

    /// For each match of `prefix`, the two or three integers separated by `.` or `,` right after it.
    private static func versions(in text: String, after prefix: String) -> [[Int]] {
        let pattern = prefix + #"(\d+)\s*[.,]\s*(\d+)(?:\s*[.,]\s*(\d+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1...3).compactMap { group in Range(match.range(at: group), in: text).flatMap { Int(text[$0]) } }
        }
    }

    private static func era(_ lib: FolderListing) -> RenPyVersion? {
        let names = lib.entries.filter { $0.kind == .directory }.map(\.key)
        func has(_ prefix: String) -> Bool { names.contains { $0.hasPrefix(prefix) } }
        if names.contains("python3.12") { return .era(from: (8, 4), through: nil) }
        if has("py3-"), names.contains("python3.9") { return .era(from: (8, 0), through: (8, 3)) }
        if has("py2-") { return .era(from: (7, 4), through: nil) }
        if has("windows-") || has("linux-"), names.contains("pythonlib2.7") { return .era(from: (0, 0), through: (7, 3)) }
        return nil
    }

    // MARK: Native modules

    /// Base names of native modules anywhere under game/: one name per normalized key,
    /// the first met in sorted walk order; sorted by key.
    private static func nativeModules(in game: FolderListing) -> [String] {
        var found: [String: String] = [:]
        var budget = walkEntries
        func walk(_ listing: FolderListing, depth: Int) {
            for entry in listing.entries {
                budget -= 1
                guard budget >= 0 else { return }
                switch entry.kind {
                case .file where nativeExtensions.contains(entry.pathExtension):
                    if found[entry.key] == nil { found[entry.key] = entry.name }
                case .directory where depth < walkDepth:
                    if let child = try? listing.listing(of: entry) { walk(child, depth: depth + 1) }
                case .file, .directory, .symlink:
                    break
                }
            }
        }
        walk(game, depth: 0)
        return found.keys.sorted().map { found[$0]! }
    }

    // MARK: Executables

    /// Windows: the root .exe beside a same-stem .py. Linux: the ELF of that stem under
    /// lib/py*-linux-x86_64/ or lib/linux-x86_64/, never the .sh launcher.
    private static func executables(_ listing: FolderListing, _ reader: FolderReader,
                                    lib: FolderListing?) -> [GamePlatform: String] {
        let stems = Set(listing.files(withExtension: "py").map(\.stem))
        var result: [GamePlatform: String] = [:]
        if let exe = listing.files(withExtension: "exe").first(where: { stems.contains($0.stem) }) {
            result[.windows] = exe.name
        }
        if let lib {
            let linuxDirs = lib.entries.filter {
                $0.kind == .directory && ($0.key == "linux-x86_64" || ($0.key.hasPrefix("py") && $0.key.hasSuffix("-linux-x86_64")))
            }
            search: for dir in linuxDirs {
                guard let contents = try? lib.listing(of: dir) else { continue }
                for entry in contents.entries where entry.kind == .file && stems.contains(entry.key) {
                    let path = "\(lib.url.lastPathComponent)/\(dir.name)/\(entry.name)"
                    if BinaryInfo.hasELFMagic(reader, path: path) {
                        result[.linux] = path
                        break search
                    }
                }
            }
        }
        return result
    }
}

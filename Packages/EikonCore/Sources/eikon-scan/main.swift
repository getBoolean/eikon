import EikonCore
import Foundation

// eikon-scan [--root PATH] [--per-folder] [--hash]
// Prints a title-free aggregate report of a game collection. Read-only.

let usage = "usage: eikon-scan [--root PATH] [--per-folder] [--hash]\n"
var root = "/Volumes/Games"
var perFolder = false
var hash = false

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--root":
        guard let value = arguments.popFirst() else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        root = value
    case "--per-folder":
        perFolder = true
    case "--hash":
        hash = true
    default:
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
}

// Progress goes to stderr so stdout stays parseable; hashing over a network share is slow.
let outcome = CollectionScan.run(root: URL(fileURLWithPath: root, isDirectory: true), hash: hash) { done, total, fraction in
    guard hash else { return }
    let percent = Int(fraction * 100)
    FileHandle.standardError.write(Data("\rfolder \(min(done + 1, total))/\(total) \(percent)%   ".utf8))
}
if hash { FileHandle.standardError.write(Data("\n".utf8)) }

switch outcome {
case .skipped(let path):
    print("skipped: \(path) not mounted")
case .unreadable:
    FileHandle.standardError.write(Data("eikon-scan: the root is not a readable folder\n".utf8))
    exit(1)
case .scanned(let summary):
    print(summary.formatted(perFolder: perFolder), terminator: "")
}

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EikonCore",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "EikonCore", targets: ["EikonCore"]),
        .library(name: "CEikonSession", targets: ["CEikonSession"]),
        .executable(name: "eikon-scan", targets: ["eikon-scan"]),
    ],
    targets: [
        .target(name: "CEikonSession"),
        .target(name: "EikonCore", dependencies: ["CEikonSession"], linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "eikon-scan", dependencies: ["EikonCore"]),
        .testTarget(name: "EikonCoreTests", dependencies: ["EikonCore", "CEikonSession"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EikonKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "EikonKit", targets: ["EikonKit"]),
    ],
    targets: [
        .target(name: "CEikonJIT"),
        .target(name: "EikonKit", dependencies: ["CEikonJIT"]),
        .testTarget(name: "EikonKitTests", dependencies: ["EikonKit", "CEikonJIT"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EikonKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "EikonKit", targets: ["EikonKit"]),
    ],
    dependencies: [
        .package(path: "../EikonCore"),
    ],
    targets: [
        .target(name: "CEikonJIT", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "EikonKit", dependencies: ["CEikonJIT", .product(name: "EikonCore", package: "EikonCore")]),
        .testTarget(name: "EikonKitTests", dependencies: ["EikonKit", "CEikonJIT"]),
    ],
    swiftLanguageModes: [.v6]
)

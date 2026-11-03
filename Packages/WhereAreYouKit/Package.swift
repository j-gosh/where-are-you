// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WhereAreYouKit",
    platforms: [
        .iOS(.v18),
        // Only so `swift test` can run on a Mac; the app is iOS-only.
        .macOS(.v15),
    ],
    products: [
        .library(name: "WAYCore", targets: ["WAYCore"]),
    ],
    targets: [
        .target(name: "WAYCore"),
        .testTarget(name: "WAYCoreTests", dependencies: ["WAYCore"]),
    ]
)

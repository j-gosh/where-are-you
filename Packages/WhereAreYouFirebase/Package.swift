// swift-tools-version: 6.0

import PackageDescription

// Firebase-backed implementations of the backend protocols in WAYCore. Kept out of
// WhereAreYouKit so `swift test` there doesn't have to build Firebase.
let package = Package(
    name: "WhereAreYouFirebase",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "WAYFirebase", targets: ["WAYFirebase"]),
    ],
    dependencies: [
        .package(path: "../WhereAreYouKit"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", .upToNextMajor(from: "12.0.0")),
    ],
    targets: [
        .target(
            name: "WAYFirebase",
            dependencies: [
                .product(name: "WAYCore", package: "WhereAreYouKit"),
                .product(name: "FirebaseAppCheck", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
            ]
        ),
    ]
)

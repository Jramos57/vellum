// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "vellum",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "vellum",
            targets: ["vellum"]
        ),
    ],
    targets: [
        .target(
            name: "vellum"
        ),
        .testTarget(
            name: "vellumTests",
            dependencies: ["vellum"]
        ),
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MediaForge",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "MediaForge",
            targets: ["MediaForge"]
        ),
    ],
    targets: [
        .target(
            name: "MediaForge"
        ),
    ]
)

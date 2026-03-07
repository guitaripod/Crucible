// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Crucible",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "Crucible",
            targets: ["Crucible"]
        ),
    ],
    targets: [
        .target(
            name: "Crucible"
        ),
    ]
)

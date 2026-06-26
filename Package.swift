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
            name: "Crucible",
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "26.2"],
                    .when(platforms: [.iOS])
                )
            ]
        ),
    ]
)

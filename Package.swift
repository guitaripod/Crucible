// swift-tools-version: 6.0

import PackageDescription

let iosStamp: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "26.2"],
        .when(platforms: [.iOS])
    )
]

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
        .library(
            name: "CrucibleWidgets",
            targets: ["CrucibleWidgets"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CrucibleActivity"
        ),
        .target(
            name: "Crucible",
            dependencies: [
                "CrucibleActivity",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            linkerSettings: iosStamp
        ),
        .target(
            name: "CrucibleWidgets",
            dependencies: ["CrucibleActivity"],
            linkerSettings: iosStamp
        ),
    ]
)

// swift-tools-version: 6.0

import Foundation
import PackageDescription

let iosStamp: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "26.2"],
        .when(platforms: [.iOS])
    )
]

let widgetKeep: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_main"], .when(platforms: [.iOS]))
]

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

let coreOnly = ProcessInfo.processInfo.environment["CRUCIBLE_CORE_ONLY"] != nil

var products: [Product] = []

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
]

var targets: [Target] = [
    .target(name: "CrucibleCore"),
    .target(name: "CrucibleStats", dependencies: ["CrucibleCore", grdb]),
]

#if os(macOS)
targets += [
    .target(name: "CrucibleDemo", dependencies: ["CrucibleCore"], resources: [.copy("Resources")]),
    .testTarget(name: "CrucibleDemoTests", dependencies: ["CrucibleDemo", "CrucibleCore"]),
]
products += [.library(name: "CrucibleDemo", targets: ["CrucibleDemo"])]
#endif

if coreOnly {
    targets.append(.testTarget(name: "CrucibleCoreTests", dependencies: ["CrucibleCore", "CrucibleStats"]))
} else {
    products += [
        .library(name: "Crucible", targets: ["Crucible"]),
        .library(name: "CrucibleWidgets", targets: ["CrucibleWidgets"]),
        .library(name: "CrucibleCore", targets: ["CrucibleCore"]),
        .library(name: "CrucibleMedia", targets: ["CrucibleMedia"]),
        .library(name: "CrucibleStats", targets: ["CrucibleStats"]),
        .library(name: "CrucibleDesign", targets: ["CrucibleDesign"]),
        .library(name: "CrucibleStatsUI", targets: ["CrucibleStatsUI"]),
        .library(name: "CrucibleActivity", targets: ["CrucibleActivity"]),
    ]
    targets += [
        .target(name: "CrucibleActivity"),
        .target(name: "CrucibleMedia", dependencies: ["CrucibleCore"]),
        .target(name: "CrucibleDesign", dependencies: ["CrucibleCore"]),
        .target(name: "CrucibleStatsUI", dependencies: ["CrucibleStats", "CrucibleDesign"]),
        .target(
            name: "Crucible",
            dependencies: [
                "CrucibleActivity",
                "CrucibleCore",
                "CrucibleMedia",
                "CrucibleStats",
                "CrucibleDesign",
                "CrucibleStatsUI",
                grdb,
            ],
            linkerSettings: iosStamp
        ),
        .target(
            name: "CrucibleWidgets",
            dependencies: ["CrucibleActivity"],
            linkerSettings: iosStamp + widgetKeep
        ),
    ]
    #if os(macOS)
    dependencies.append(.package(url: "https://github.com/RevenueCat/purchases-ios.git", from: "5.83.0"))
    products += [
        .library(name: "CrucibleTV", targets: ["CrucibleTV"]),
        .library(name: "CrucibleTopShelf", targets: ["CrucibleTopShelf"]),
        .library(name: "CrucibleStore", targets: ["CrucibleStore"]),
    ]
    targets += [
        .target(
            name: "CrucibleStore",
            dependencies: ["CrucibleCore", .product(name: "RevenueCat", package: "purchases-ios")]
        ),
        .target(
            name: "CrucibleTV",
            dependencies: ["CrucibleCore", "CrucibleMedia", "CrucibleStats", "CrucibleDesign", "CrucibleStatsUI"]
        ),
        .target(name: "CrucibleTopShelf", dependencies: ["CrucibleCore"]),
    ]
    #endif
}

let package = Package(
    name: "Crucible",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)

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
let midgarCore: Target.Dependency = .product(name: "MidgarCore", package: "MidgarKit")
let midgarCommerce: Target.Dependency = .product(name: "MidgarCommerce", package: "MidgarKit")
let linuxCrypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))

let coreOnly = ProcessInfo.processInfo.environment["CRUCIBLE_CORE_ONLY"] != nil
let benchOnly = ProcessInfo.processInfo.environment["CRUCIBLE_BENCH"] != nil

var products: [Product] = []

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    .package(url: "https://github.com/guitaripod/MidgarKit.git", exact: "4.7.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
]

var targets: [Target] = [
    .target(name: "CrucibleCore", dependencies: [midgarCore, linuxCrypto], resources: [.copy("Resources/guides.envelope.json")]),
    .target(name: "CrucibleStats", dependencies: ["CrucibleCore", grdb, midgarCore]),
]

#if os(macOS)
targets += [
    .target(name: "CrucibleDemo", dependencies: ["CrucibleCore"], resources: [.copy("Data")]),
    .testTarget(name: "CrucibleDemoTests", dependencies: ["CrucibleDemo", "CrucibleCore"]),
]
products += [.library(name: "CrucibleDemo", targets: ["CrucibleDemo"])]
#endif

if benchOnly {
    targets.append(.executableTarget(name: "CrucibleBench", dependencies: ["CrucibleCore"]))
}

/// The Linux client (docs/LINUX.md): Kiln, the design system on it, the gallery and the app, in this package so they
/// reach Core's package-level API. Their sources live under `linux/`. Building them needs the vendored libmpv and
/// libplacebo (`linux/scripts/build-mpv.sh`, then `PKG_CONFIG_PATH=linux/.build/mpv/lib/pkgconfig`).
func linuxClient() -> (products: [Product], targets: [Target]) {
    let products: [Product] = [
        .library(name: "CrucibleCore", targets: ["CrucibleCore"]),
        .library(name: "CrucibleStats", targets: ["CrucibleStats"]),
        .library(name: "Kiln", targets: ["Kiln"]),
        .library(name: "CrucibleUI", targets: ["CrucibleUI"]),
        .executable(name: "kiln-spike", targets: ["KilnSpike"]),
        .executable(name: "crucible-gallery", targets: ["CrucibleGallery"]),
        .executable(name: "crucible", targets: ["CrucibleApp"]),
    ]
    let targets: [Target] = [
        .target(name: "CKiln", path: "linux/Sources/CKiln", linkerSettings: [.linkedLibrary("wayland-client"), .linkedLibrary("xkbcommon")]),
        .systemLibrary(name: "CMPV", path: "linux/Sources/CMPV", pkgConfig: "mpv"),
        .systemLibrary(name: "CPlacebo", path: "linux/Sources/CPlacebo", pkgConfig: "libplacebo"),
        .systemLibrary(name: "CPangoCairo", path: "linux/Sources/CPangoCairo", pkgConfig: "pangocairo fontconfig"),
        .target(name: "CKilnText", dependencies: ["CPangoCairo"], path: "linux/Sources/CKilnText"),
        .systemLibrary(name: "CImageLibs", path: "linux/Sources/CImageLibs", pkgConfig: "libturbojpeg libpng libwebp librsvg-2.0"),
        .target(name: "CKilnImage", dependencies: ["CImageLibs"], path: "linux/Sources/CKilnImage"),
        .target(name: "CKilnGPU", dependencies: ["CPlacebo"], path: "linux/Sources/CKilnGPU",
                linkerSettings: [.linkedLibrary("vulkan"), .linkedLibrary("wayland-client")]),
        .target(name: "Kiln", dependencies: ["CKiln", "CKilnGPU", "CKilnText", "CKilnImage"], path: "linux/Sources/Kiln",
                resources: [.copy("Resources/Fonts"), .copy("Resources/Symbols")]),
        .executableTarget(name: "KilnSpike", dependencies: ["Kiln", "CKiln"], path: "linux/Sources/KilnSpike"),
        .target(name: "CrucibleUI", dependencies: ["Kiln"], path: "linux/Sources/CrucibleUI"),
        .executableTarget(name: "CrucibleGallery", dependencies: ["CrucibleUI", "Kiln"], path: "linux/Sources/CrucibleGallery"),
        .systemLibrary(name: "CLinuxLibs", path: "linux/Sources/CLinuxLibs", pkgConfig: "libsecret-1 libqrencode"),
        .target(name: "CLinuxServices", dependencies: ["CLinuxLibs"], path: "linux/Sources/CLinuxServices"),
        .executableTarget(name: "CrucibleApp", dependencies: ["CrucibleCore", "CrucibleUI", "Kiln", "CLinuxServices", midgarCore],
                          path: "linux/Sources/CrucibleApp", resources: [.copy("Resources/Localizable.xcstrings")]),
        .testTarget(name: "KilnTests", dependencies: ["Kiln"], path: "linux/Tests/KilnTests", exclude: ["Fixtures"]),
        .testTarget(name: "CrucibleUITests", dependencies: ["CrucibleUI", "Kiln"], path: "linux/Tests/CrucibleUITests"),
    ]
    return (products, targets)
}

if coreOnly {
    targets.append(.testTarget(name: "CrucibleCoreTests", dependencies: ["CrucibleCore", "CrucibleStats", linuxCrypto]))
} else {
    #if os(Linux)
    let client = linuxClient()
    products += client.products
    targets += client.targets
    targets.append(.testTarget(name: "CrucibleCoreTests", dependencies: ["CrucibleCore", "CrucibleStats", linuxCrypto]))
    #else
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
        .target(name: "CrucibleMedia", dependencies: ["CrucibleCore", midgarCore]),
        .target(name: "CrucibleDesign", dependencies: ["CrucibleCore"], resources: [.process("Resources")]),
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
                midgarCore,
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
    products += [
        .library(name: "CrucibleTV", targets: ["CrucibleTV"]),
        .library(name: "CrucibleTopShelf", targets: ["CrucibleTopShelf"]),
        .library(name: "CrucibleStore", targets: ["CrucibleStore"]),
    ]
    targets += [
        .target(
            name: "CrucibleStore",
            dependencies: ["CrucibleCore", midgarCore, midgarCommerce]
        ),
        .target(
            name: "CrucibleTV",
            dependencies: ["CrucibleCore", "CrucibleMedia", "CrucibleStats", "CrucibleDesign", "CrucibleStatsUI", midgarCore]
        ),
        .target(name: "CrucibleTopShelf", dependencies: ["CrucibleCore", midgarCore]),
    ]
    #endif
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

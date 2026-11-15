// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CrucibleLinux",
    products: [
        .library(name: "Kiln", targets: ["Kiln"]),
        .executable(name: "kiln-spike", targets: ["KilnSpike"]),
    ],
    targets: [
        .target(
            name: "CKiln",
            linkerSettings: [
                .linkedLibrary("wayland-client"),
            ]
        ),
        .systemLibrary(name: "CMPV", pkgConfig: "mpv"),
        .systemLibrary(name: "CPlacebo", pkgConfig: "libplacebo"),
        .systemLibrary(name: "CPangoCairo", pkgConfig: "pangocairo fontconfig"),
        .target(name: "CKilnText", dependencies: ["CPangoCairo"]),
        .target(name: "CKilnGPU", dependencies: ["CPlacebo"], linkerSettings: [.linkedLibrary("vulkan"), .linkedLibrary("wayland-client")]),
        .target(name: "Kiln", dependencies: ["CKiln", "CKilnGPU", "CKilnText"], resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "KilnSpike", dependencies: ["Kiln", "CKiln"]),
        .testTarget(name: "KilnTests", dependencies: ["Kiln"]),
    ],
    swiftLanguageModes: [.v6]
)

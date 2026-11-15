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
        .target(name: "CKilnGPU", dependencies: ["CPlacebo"], linkerSettings: [.linkedLibrary("vulkan"), .linkedLibrary("wayland-client")]),
        .target(name: "Kiln", dependencies: ["CKiln", "CKilnGPU"]),
        .executableTarget(name: "KilnSpike", dependencies: ["Kiln", "CKiln"]),
        .testTarget(name: "KilnTests", dependencies: ["Kiln"]),
    ],
    swiftLanguageModes: [.v6]
)

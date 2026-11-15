// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CrucibleLinux",
    products: [
        .library(name: "Kiln", targets: ["Kiln"]),
        .library(name: "CrucibleUI", targets: ["CrucibleUI"]),
        .executable(name: "kiln-spike", targets: ["KilnSpike"]),
        .executable(name: "crucible-gallery", targets: ["CrucibleGallery"]),
    ],
    targets: [
        .target(
            name: "CKiln",
            linkerSettings: [
                .linkedLibrary("wayland-client"),
                .linkedLibrary("xkbcommon"),
            ]
        ),
        .systemLibrary(name: "CMPV", pkgConfig: "mpv"),
        .systemLibrary(name: "CPlacebo", pkgConfig: "libplacebo"),
        .systemLibrary(name: "CPangoCairo", pkgConfig: "pangocairo fontconfig"),
        .target(name: "CKilnText", dependencies: ["CPangoCairo"]),
        .systemLibrary(name: "CImageLibs", pkgConfig: "libturbojpeg libpng libwebp librsvg-2.0"),
        .target(name: "CKilnImage", dependencies: ["CImageLibs"]),
        .target(name: "CKilnGPU", dependencies: ["CPlacebo"], linkerSettings: [.linkedLibrary("vulkan"), .linkedLibrary("wayland-client")]),
        .target(name: "Kiln", dependencies: ["CKiln", "CKilnGPU", "CKilnText", "CKilnImage"], resources: [.copy("Resources/Fonts"), .copy("Resources/Symbols")]),
        .executableTarget(name: "KilnSpike", dependencies: ["Kiln", "CKiln"]),
        .target(name: "CrucibleUI", dependencies: ["Kiln"]),
        .executableTarget(name: "CrucibleGallery", dependencies: ["CrucibleUI", "Kiln"]),
        .testTarget(name: "KilnTests", dependencies: ["Kiln"], exclude: ["Fixtures"]),
        .testTarget(name: "CrucibleUITests", dependencies: ["CrucibleUI", "Kiln"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CrucibleLinux",
    products: [
        .library(name: "Kiln", targets: ["Kiln"]),
        .executable(name: "kiln-spike", targets: ["KilnSpike"]),
        .executable(name: "kiln-video-spike", targets: ["KilnVideoSpike"]),
    ],
    targets: [
        .target(
            name: "CKiln",
            linkerSettings: [
                .linkedLibrary("wayland-client"),
                .linkedLibrary("wayland-egl"),
                .linkedLibrary("EGL"),
                .linkedLibrary("OpenGL"),
            ]
        ),
        .systemLibrary(name: "CMPV", pkgConfig: "mpv"),
        .target(name: "Kiln", dependencies: ["CKiln"]),
        .executableTarget(name: "KilnSpike", dependencies: ["Kiln", "CKiln"]),
        .executableTarget(name: "KilnVideoSpike", dependencies: ["Kiln", "CKiln", "CMPV"]),
        .testTarget(name: "KilnTests", dependencies: ["Kiln"]),
    ],
    swiftLanguageModes: [.v6]
)

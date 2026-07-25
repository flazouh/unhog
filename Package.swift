// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Unhog",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UnhogCore", targets: ["UnhogCore"]),
        .executable(name: "Unhog", targets: ["Unhog"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.4"
        )
    ],
    targets: [
        .target(name: "UnhogCore"),
        .executableTarget(
            name: "Unhog",
            dependencies: [
                "UnhogCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ],
            // Sparkle ships as a framework that `scripts/package-app.sh` copies
            // into Contents/Frameworks; without this rpath the bundled binary
            // cannot find it at launch.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "UnhogCoreTests",
            dependencies: ["UnhogCore"]
        ),
        .testTarget(
            name: "UnhogTests",
            dependencies: ["Unhog"]
        )
    ]
)

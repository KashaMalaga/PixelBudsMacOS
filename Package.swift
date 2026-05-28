// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PixelBudsMacOS",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Maestro", targets: ["Maestro"]),
        .library(name: "MaestroIOBluetooth", targets: ["MaestroIOBluetooth"]),
        .executable(name: "BudsSpike", targets: ["BudsSpike"]),
        .executable(name: "BudsRead", targets: ["BudsRead"]),
        .executable(name: "PixelBudsBar", targets: ["PixelBudsBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "Maestro",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/Maestro",
            // The SwiftProtobufPlugin reads this JSON via its own file walk
            // (and errors out if we exclude it), but SwiftPM still warns
            // "unhandled file" unless we declare it. Copying it as a resource
            // satisfies SwiftPM at the cost of a stray JSON inside the bundle.
            resources: [
                .copy("Protos/swift-protobuf-config.json"),
            ],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "MaestroIOBluetooth",
            dependencies: ["Maestro"],
            path: "Sources/MaestroIOBluetooth",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
            ]
        ),
        .testTarget(
            name: "MaestroTests",
            dependencies: ["Maestro"],
            path: "Tests/MaestroTests"
        ),
        .executableTarget(
            name: "BudsSpike",
            path: "Sources/BudsSpike",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "BudsRead",
            dependencies: ["MaestroIOBluetooth"],
            path: "Sources/BudsRead"
        ),
        .executableTarget(
            name: "PixelBudsBar",
            dependencies: [
                "MaestroIOBluetooth",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/PixelBudsBar",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)

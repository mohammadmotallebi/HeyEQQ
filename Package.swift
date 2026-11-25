// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeyEQQ",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "HeyEQQ", targets: ["HeyEQQ"]),
        .executable(name: "HeyEQQSpike", targets: ["HeyEQQSpike"]),
    ],
    targets: [
        // Audio pipeline + DSP, shared by the app and the spike.
        .target(name: "HeyEQQCore"),

        // Menu-bar app. Packaged into HeyEQQ.app by scripts/build-app.sh (Info.plist in Support/).
        .executableTarget(name: "HeyEQQ", dependencies: ["HeyEQQCore"]),

        .testTarget(name: "HeyEQQCoreTests", dependencies: ["HeyEQQCore"]),

        // Terminal spike kept for quick pipeline testing: `swift run HeyEQQSpike`.
        .executableTarget(
            name: "HeyEQQSpike",
            dependencies: ["HeyEQQCore"],
            path: "Spike/Sources/HeyEQQSpike",
            linkerSettings: [
                // Embed Info.plist (NSAudioCaptureUsageDescription) into the CLI binary.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Spike/Info.plist"])
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

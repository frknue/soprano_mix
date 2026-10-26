// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopranoMix",
    // Core Audio process taps need macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        // Mixer engine: models, settings, app grouping, route planning, DSP, CLI messages.
        // Foundation and CoreGraphics only, no AppKit, no Core Audio.
        .target(
            name: "SopranoMixCore",
            path: "Sources/SopranoMixCore"
        ),
        .executableTarget(
            name: "SopranoMix",
            dependencies: ["SopranoMixCore"],
            path: "Sources/SopranoMix",
            // AppIcon.icns is packaged by scripts/package-app.sh, not as an SPM resource.
            exclude: ["Vendored/SOPRANO_COMMIT", "Resources/AppIcon.icns"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "SopranoMixTests",
            dependencies: ["SopranoMix", "SopranoMixCore"],
            path: "Tests/SopranoMixTests",
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .linkedFramework("Testing"),
            ]
        ),
    ]
)

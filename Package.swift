// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MixerCore"),
        .executableTarget(name: "VolumeMixer", dependencies: ["MixerCore"]),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore"]),
    ],
    swiftLanguageModes: [.v5]
)

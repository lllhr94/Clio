// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TelegramRevealSpike",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "TelegramRevealSpike",
            targets: ["TelegramRevealUpstream", "ClioRevealSpike"]
        ),
    ],
    targets: [
        .target(
            name: "TelegramRevealUpstream"
        ),
        .target(
            name: "ClioRevealSpike",
            dependencies: ["TelegramRevealUpstream"]
        ),
        .testTarget(
            name: "ClioRevealSpikeTests",
            dependencies: ["TelegramRevealUpstream", "ClioRevealSpike"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)

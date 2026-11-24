// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "Prose", targets: ["Prose"]),
        .library(name: "Craft", targets: ["Craft"]),
    ],
    targets: [
        .target(name: "AgentKit"),
        .target(name: "Prose"),
        .target(
            name: "Craft",
            dependencies: ["AgentKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "ProseTests", dependencies: ["Prose"]),
        .testTarget(
            name: "CraftTests",
            dependencies: ["Craft", "AgentKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)

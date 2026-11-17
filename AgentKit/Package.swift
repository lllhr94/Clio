// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "Prose", targets: ["Prose"]),
    ],
    targets: [
        .target(name: "AgentKit"),
        .target(name: "Prose"),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "ProseTests", dependencies: ["Prose"]),
    ]
)

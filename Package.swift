// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlopOverlord",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Protocols", targets: ["Protocols"]),
        .library(name: "PluginSDK", targets: ["PluginSDK"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .executable(name: "Core", targets: ["Core"]),
        .executable(name: "Node", targets: ["Node"]),
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "0.2.0"),
        .package(url: "https://github.com/mattt/AnyLanguageModel.git", branch: "main")
    ],
    targets: [
        .target(
            name: "Protocols",
            path: "Sources/Protocols"
        ),
        .target(
            name: "PluginSDK",
            dependencies: [
                "Protocols",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel")
            ],
            path: "Sources/PluginSDK"
        ),
        .target(
            name: "AgentRuntime",
            dependencies: ["Protocols", "PluginSDK"],
            path: "Sources/AgentRuntime"
        ),
        .executableTarget(
            name: "Core",
            dependencies: [
                "AgentRuntime",
                "Protocols",
                "PluginSDK",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Configuration", package: "swift-configuration")
            ],
            path: "Sources/Core",
            resources: [
                .process("Storage/schema.sql")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Node",
            dependencies: [
                "Protocols",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/Node",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Protocols"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "ProtocolsTests",
            dependencies: ["Protocols"],
            path: "Tests/ProtocolsTests"
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "Protocols"],
            path: "Tests/AgentRuntimeTests"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "AgentRuntime", "Protocols"],
            path: "Tests/CoreTests"
        )
    ]
)

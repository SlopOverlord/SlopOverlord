// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sloppy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Protocols", targets: ["Protocols"]),
        .library(name: "PluginSDK", targets: ["PluginSDK"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "ChannelPluginSupport", targets: ["ChannelPluginSupport"]),
        .library(name: "ChannelPluginTelegram", targets: ["ChannelPluginTelegram"]),
        .library(name: "ChannelPluginDiscord", targets: ["ChannelPluginDiscord"]),
        .executable(name: "Core", targets: ["Core"]),
        .executable(name: "Node", targets: ["Node"]),
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.74.0"),
        .package(url: "https://github.com/mattt/AnyLanguageModel.git", branch: "main"),
        .package(url: "https://github.com/TeamSloppy/CodexBar.git", branch: "main")
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
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/PluginSDK"
        ),
        .target(
            name: "ChannelPluginSupport",
            path: "Sources/ChannelPluginSupport"
        ),
        .target(
            name: "AgentRuntime",
            dependencies: [
                "Protocols",
                "PluginSDK",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/AgentRuntime"
        ),
        .executableTarget(
            name: "Core",
            dependencies: [
                "AgentRuntime",
                "ChannelPluginDiscord",
                "ChannelPluginTelegram",
                "Protocols",
                "PluginSDK",
                "CSQLite3",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "CodexBarCore", package: "CodexBar")
            ],
            path: "Sources/Core",
            resources: [
                .process("Prompts"),
                .process("Storage/schema.sql")
            ]
        ),
        .executableTarget(
            name: "Node",
            dependencies: [
                "Protocols",
                "CSQLite3",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/Node"
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                "Protocols",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/App"
        ),
        .target(
            name: "ChannelPluginTelegram",
            dependencies: [
                "ChannelPluginSupport",
                "Protocols",
                "PluginSDK",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/ChannelPluginTelegram"
        ),
        .target(
            name: "ChannelPluginDiscord",
            dependencies: [
                "ChannelPluginSupport",
                "Protocols",
                "PluginSDK",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/ChannelPluginDiscord"
        ),
        .testTarget(
            name: "ProtocolsTests",
            dependencies: ["Protocols"],
            path: "Tests/ProtocolsTests"
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "Protocols", "PluginSDK"],
            path: "Tests/AgentRuntimeTests"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core",
                "AgentRuntime",
                "ChannelPluginDiscord",
                "Protocols",
                "PluginSDK",
                "CSQLite3"
            ],
            path: "Tests/CoreTests"
        ),
        .target(
            name: "CSQLite3",
            path: "Sources/CSQLite3"
        )
    ]
)

// swift-tools-version: 6.2
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
        .library(name: "SloppyNodeCore", targets: ["SloppyNodeCore"]),
        .executable(name: "sloppy", targets: ["sloppy"]),
        .executable(name: "SloppyNode", targets: ["SloppyNode"])
    ],
    dependencies: [
        .package(path: "Packages/SloppyComputerControl"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.74.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.0"),
        .package(url: "https://github.com/mattt/AnyLanguageModel.git", branch: "main"),
        .package(url: "https://github.com/TeamSloppy/CodexBar.git", branch: "main"),
        .package(path: "Packages/TauTUI"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/TeamSloppy/swift-acp", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-tools-protocols.git", branch: "main")
    ],
    targets: [
        .target(
            name: "Protocols",
            dependencies: [
                .product(name: "SloppyComputerControl", package: "SloppyComputerControl"),
                .product(name: "Logging", package: "swift-log")
            ],
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
            name: "sloppy",
            dependencies: [
                "AgentRuntime",
                "ChannelPluginSupport",
                "ChannelPluginDiscord",
                "ChannelPluginTelegram",
                "Protocols",
                "PluginSDK",
                "CSQLite3",
                .product(name: "SloppyComputerControl", package: "SloppyComputerControl"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "CodexBarCore", package: "CodexBar"),
                .product(name: "TauTUI", package: "TauTUI"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ACP", package: "swift-acp"),
                .product(name: "ACPModel", package: "swift-acp"),
                .product(name: "ACPHTTP", package: "swift-acp"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "LanguageServerProtocol", package: "swift-tools-protocols"),
                .product(name: "LanguageServerProtocolTransport", package: "swift-tools-protocols")
            ],
            path: "Sources/sloppy",
            resources: [
                .process("Resources/Prompts"),
                .process("Resources/sloppy-version.json"),
                .process("Storage/schema.sql")
            ]
        ),
        .executableTarget(
            name: "SloppyNode",
            dependencies: [
                "SloppyNodeCore",
                "Protocols",
                "CSQLite3",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/Node"
        ),
        .target(
            name: "SloppyNodeCore",
            dependencies: [
                "Protocols",
                .product(name: "SloppyComputerControl", package: "SloppyComputerControl")
            ],
            path: "Sources/NodeCore"
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
            name: "sloppyTests",
            dependencies: [
                "sloppy",
                "AgentRuntime",
                "ChannelPluginDiscord",
                "ChannelPluginTelegram",
                "ChannelPluginSupport",
                "Protocols",
                "PluginSDK",
                "CSQLite3"
            ],
            path: "Tests/sloppyTests"
        ),
        .testTarget(
            name: "SloppyNodeCoreTests",
            dependencies: [
                "SloppyNodeCore",
                "Protocols"
            ],
            path: "Tests/SloppyNodeCoreTests"
        ),
        .target(
            name: "CSQLite3",
            path: "Sources/CSQLite3"
        )
    ]
)

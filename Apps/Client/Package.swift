// swift-tools-version: 6.2
import PackageDescription
import Foundation

let adaEnginePath: String
if ProcessInfo.processInfo.environment["ADAENGINE_LOCAL"] == "1" {
    adaEnginePath = "/Users/vlad-prusakov/Developer/AdaEngine"
} else {
    adaEnginePath = "../../Vendor/AdaEngine"
}

let package = Package(
    name: "SloppyClient",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .executable(name: "SloppyClient", targets: ["SloppyClient"]),
        .library(name: "SloppyClientCore", targets: ["SloppyClientCore"]),
        .library(name: "SloppyClientUI", targets: ["SloppyClientUI"]),
        .library(name: "SloppyFeatureOverview", targets: ["SloppyFeatureOverview"]),
        .library(name: "SloppyFeatureProjects", targets: ["SloppyFeatureProjects"]),
        .library(name: "SloppyFeatureAgents", targets: ["SloppyFeatureAgents"]),
        .library(name: "SloppyFeatureSettings", targets: ["SloppyFeatureSettings"]),
        .library(name: "SloppyFeatureChat", targets: ["SloppyFeatureChat"])
    ],
    dependencies: [
        .package(name: "SloppyComputerControl", path: "../../Packages/SloppyComputerControl"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(name: "AdaEngine", path: adaEnginePath),
        .package(name: "AdaMCP", path: "../../Vendor/AdaMCP")
    ],
    targets: [
        .target(
            name: "SloppyClientCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SloppyClientCore"
        ),
        .target(
            name: "SloppyClientUI",
            dependencies: [
                .product(name: "AdaEngine", package: "AdaEngine")
            ],
            path: "Sources/SloppyClientUI",
            resources: [
                .process("Resources")
            ],
            plugins: [
                .plugin(name: "TextureAtlasBuildPlugin", package: "AdaEngine")
            ]
        ),
        .target(
            name: "SloppyFeatureOverview",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                .product(name: "AdaEngine", package: "AdaEngine")
            ],
            path: "Sources/SloppyFeatureOverview"
        ),
        .target(
            name: "SloppyFeatureProjects",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                .product(name: "AdaEngine", package: "AdaEngine")
            ],
            path: "Sources/SloppyFeatureProjects"
        ),
        .target(
            name: "SloppyFeatureAgents",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                "SloppyFeatureChat",
                .product(name: "AdaEngine", package: "AdaEngine")
            ],
            path: "Sources/SloppyFeatureAgents"
        ),
        .target(
            name: "SloppyFeatureSettings",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                .product(name: "AdaEngine", package: "AdaEngine")
            ],
            path: "Sources/SloppyFeatureSettings"
        ),
        .target(
            name: "SloppyFeatureChat",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                .product(name: "AdaEngine", package: "AdaEngine")
            ],
            path: "Sources/SloppyFeatureChat"
        ),
        .executableTarget(
            name: "SloppyClient",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                "SloppyFeatureOverview",
                "SloppyFeatureProjects",
                "SloppyFeatureAgents",
                "SloppyFeatureSettings",
                "SloppyFeatureChat",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "AdaMCPPlugin", package: "AdaMCP", condition: .when(platforms: [.macOS, .iOS, .visionOS])),
            ],
            path: "Sources/SloppyClient"
        ),
        .testTarget(
            name: "SloppyClientCoreTests",
            dependencies: ["SloppyClientCore"],
            path: "Tests/SloppyClientCoreTests"
        ),
        .testTarget(
            name: "SloppyFeatureChatTests",
            dependencies: ["SloppyClientCore", "SloppyFeatureChat"],
            path: "Tests/SloppyFeatureChatTests"
        )
    ]
)

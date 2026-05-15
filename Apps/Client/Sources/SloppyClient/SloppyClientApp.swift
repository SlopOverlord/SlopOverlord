import AdaEngine
#if canImport(AdaMCPPlugin)
import AdaMCPPlugin
#endif
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureOverview
import SloppyFeatureProjects
import SloppyFeatureAgents
import SloppyFeatureChat
import SloppyFeatureSettings

@main
struct SloppyClientApp: App {
    private var baseScene: some AppScene {
        WindowGroup {
            RootShellView()
                .theme(.sloppyDark)
//                .debugOverlay()
//                .hotReloading()
        }
        .windowMode(.windowed)
        .minimumSize(width: 1280, height: 800)
        .windowTitle("")
        .windowTitleBar(.overlay)
        .windowTrafficLightOffset(x: 6, y: 6)
    }

    #if DEBUG
    private var hotReloadPlugin: AdaUIHotReloadPlugin {
        AdaUIHotReloadPlugin(
            sourcePaths: [
                "Sources/SloppyClient",
                "Sources/SloppyClientCore",
                "Sources/SloppyClientUI",
                "Sources/SloppyFeatureOverview",
                "Sources/SloppyFeatureProjects",
                "Sources/SloppyFeatureAgents",
                "Sources/SloppyFeatureChat",
                "Sources/SloppyFeatureSettings"
            ],
            watchPaths: ["Sources"],
            reloadStrategy: .automatic
        )
    }
    #endif

    var body: some AppScene {
        #if canImport(AdaMCPPlugin)
        #if DEBUG
        baseScene.addPlugins(
            MCPPlugin(configuration: .init(
                enableHTTP: true,
                enableStdio: false,
                host: "127.0.0.1",
                port: 2510,
                endpoint: "/mcp",
                serverName: "sloppy-client",
                serverVersion: "0.1.0",
                instructions: "Inspect the live Sloppy client AdaEngine runtime.",
                traceRecorder: nil
            )),
//            AdaUIDebug3DPlugin(presentation: .separateWindow, isEnabled: false),
            hotReloadPlugin
        )
        #else
        baseScene.addPlugins(
            MCPPlugin(configuration: .init(
                enableHTTP: true,
                enableStdio: false,
                host: "127.0.0.1",
                port: 2510,
                endpoint: "/mcp",
                serverName: "sloppy-client",
                serverVersion: "0.1.0",
                instructions: "Inspect the live Sloppy client AdaEngine runtime.",
                traceRecorder: nil
            )),
            AdaUIDebug3DPlugin(presentation: .separateWindow, isEnabled: false)
        )
        #endif
        #else
        #if DEBUG
        baseScene.addPlugins(
            AdaUIDebug3DPlugin(presentation: .primaryWindowOverlay),
            hotReloadPlugin
        )
        #else
        baseScene.addPlugins(
            AdaUIDebug3DPlugin(presentation: .primaryWindowOverlay)
        )
        #endif
        #endif
    }
}

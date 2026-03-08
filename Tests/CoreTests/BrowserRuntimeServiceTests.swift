import Foundation
import Testing
@testable import Core
@testable import Protocols

private struct FakeBrowserPageDiscoverer: BrowserPageDiscovering {
    let webSocketURL: URL

    func pageWebSocketURL(debuggerBaseURL: URL) async throws -> URL {
        webSocketURL
    }
}

private actor FakeBrowserProcessController: BrowserProcessControlling {
    private(set) var terminateCallCount: Int = 0

    func terminate() async {
        terminateCallCount += 1
    }
}

private actor FakeBrowserProcessLauncher: BrowserProcessLaunching {
    private(set) var launches: [BrowserLaunchOptions] = []
    private let controller: FakeBrowserProcessController
    private let debuggerBaseURL: URL

    init(
        controller: FakeBrowserProcessController = FakeBrowserProcessController(),
        debuggerBaseURL: URL = URL(string: "http://127.0.0.1:9222")!
    ) {
        self.controller = controller
        self.debuggerBaseURL = debuggerBaseURL
    }

    func launch(options: BrowserLaunchOptions) async throws -> BrowserLaunchedProcess {
        launches.append(options)
        return BrowserLaunchedProcess(controller: controller, debuggerBaseURL: debuggerBaseURL)
    }
}

private actor FakeBrowserCDPSession: BrowserCDPSession {
    struct CallRecord: Sendable {
        let method: String
        let params: [String: JSONValue]
    }

    private let handler: @Sendable (String, [String: JSONValue]) async throws -> [String: JSONValue]
    private(set) var calls: [CallRecord] = []
    private(set) var closeCallCount: Int = 0

    init(handler: @escaping @Sendable (String, [String: JSONValue]) async throws -> [String: JSONValue]) {
        self.handler = handler
    }

    func call(method: String, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        calls.append(.init(method: method, params: params))
        return try await handler(method, params)
    }

    func close() async {
        closeCallCount += 1
    }
}

private struct FakeBrowserCDPConnector: BrowserCDPConnecting {
    let session: FakeBrowserCDPSession

    func connect(webSocketURL: URL) async throws -> any BrowserCDPSession {
        session
    }
}

@Test
func browserNavigateLaunchesConfiguredProfile() async throws {
    let workProfileDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("browser-profile-work-\(UUID().uuidString)", isDirectory: true)
        .path
    let controller = FakeBrowserProcessController()
    let launcher = FakeBrowserProcessLauncher(controller: controller)
    let cdpSession = FakeBrowserCDPSession { method, params in
        switch method {
        case "Page.enable", "Runtime.enable", "Page.navigate":
            return [:]
        case "Runtime.evaluate":
            if params["expression"]?.asString == "document.readyState" {
                return ["result": .object(["value": .string("complete")])]
            }
            return ["result": .object(["value": .null])]
        default:
            return [:]
        }
    }
    let service = BrowserRuntimeService(
        browserConfig: .init(
            browserPath: "/opt/chromium",
            headless: false,
            allowJavaScriptEvaluation: false,
            profiles: [
                .init(id: "work", title: "Work", userDataDir: workProfileDir, profileDirectory: "Profile 2")
            ]
        ),
        workspaceRootURL: FileManager.default.temporaryDirectory,
        launcher: launcher,
        pageDiscoverer: FakeBrowserPageDiscoverer(webSocketURL: URL(string: "ws://127.0.0.1:9222/devtools/page/1")!),
        cdpConnector: FakeBrowserCDPConnector(session: cdpSession)
    )

    let result = await service.invoke(
        sessionID: "session-1",
        request: ToolInvocationRequest(
            tool: "browser",
            arguments: [
                "action": .string("navigate"),
                "url": .string("https://example.com"),
                "profileId": .string("work")
            ]
        )
    )

    #expect(result.ok == true)
    #expect(result.data?.asObject?["profileId"]?.asString == "work")
    let launches = await launcher.launches
    #expect(launches.count == 1)
    #expect(launches.first?.browserPath == "/opt/chromium")
    #expect(launches.first?.headless == false)
    #expect(launches.first?.userDataDir == workProfileDir)
    #expect(launches.first?.profileDirectory == "Profile 2")
}

@Test
func browserSnapshotReturnsStableRefsAndRejectsUnknownClickTarget() async throws {
    let cdpSession = FakeBrowserCDPSession { method, params in
        switch method {
        case "Page.enable", "Runtime.enable", "Page.navigate":
            return [:]
        case "Runtime.evaluate":
            let expression = params["expression"]?.asString ?? ""
            if expression == "document.readyState" {
                return ["result": .object(["value": .string("complete")])]
            }
            if expression.contains("elementCount") {
                return [
                    "result": .object([
                        "value": .object([
                            "title": .string("Example"),
                            "url": .string("https://example.com"),
                            "elementCount": .number(1),
                            "elements": .array([
                                .object([
                                    "elementId": .string("e1"),
                                    "tagName": .string("button"),
                                    "text": .string("Submit")
                                ])
                            ])
                        ])
                    ])
                ]
            }
            if expression.contains("element.click") {
                return ["result": .object(["value": .object(["ok": .bool(true)])])]
            }
            return ["result": .object(["value": .null])]
        default:
            return [:]
        }
    }
    let service = BrowserRuntimeService(
        browserConfig: .init(),
        workspaceRootURL: FileManager.default.temporaryDirectory,
        launcher: FakeBrowserProcessLauncher(),
        pageDiscoverer: FakeBrowserPageDiscoverer(webSocketURL: URL(string: "ws://127.0.0.1:9222/devtools/page/1")!),
        cdpConnector: FakeBrowserCDPConnector(session: cdpSession)
    )

    _ = await service.invoke(
        sessionID: "session-2",
        request: ToolInvocationRequest(tool: "browser", arguments: ["action": .string("navigate"), "url": .string("https://example.com")])
    )
    let snapshot = await service.invoke(
        sessionID: "session-2",
        request: ToolInvocationRequest(tool: "browser", arguments: ["action": .string("snapshot")])
    )
    let staleClick = await service.invoke(
        sessionID: "session-2",
        request: ToolInvocationRequest(
            tool: "browser",
            arguments: ["action": .string("click"), "elementId": .string("e999")]
        )
    )

    #expect(snapshot.ok == true)
    #expect(snapshot.data?.asObject?["elements"]?.asArray?.count == 1)
    #expect(snapshot.data?.asObject?["elements"]?.asArray?.first?.asObject?["elementId"]?.asString == "e1")
    #expect(staleClick.ok == false)
    #expect(staleClick.error?.code == "stale_element")
}

@Test
func browserEvaluateRespectsJavaScriptPolicy() async throws {
    let service = BrowserRuntimeService(
        browserConfig: .init(allowJavaScriptEvaluation: false),
        workspaceRootURL: FileManager.default.temporaryDirectory,
        launcher: FakeBrowserProcessLauncher(),
        pageDiscoverer: FakeBrowserPageDiscoverer(webSocketURL: URL(string: "ws://127.0.0.1:9222/devtools/page/1")!),
        cdpConnector: FakeBrowserCDPConnector(session: FakeBrowserCDPSession { _, _ in [:] })
    )

    let result = await service.invoke(
        sessionID: "session-3",
        request: ToolInvocationRequest(
            tool: "browser",
            arguments: [
                "action": .string("evaluate"),
                "expression": .string("document.title")
            ]
        )
    )

    #expect(result.ok == false)
    #expect(result.error?.code == "javascript_evaluation_disabled")
}

@Test
func browserNavigateRequiresExplicitProfileWhenMultipleProfilesExist() async throws {
    let service = BrowserRuntimeService(
        browserConfig: .init(
            profiles: [
                .init(id: "work", title: "Work", userDataDir: "/profiles/work"),
                .init(id: "personal", title: "Personal", userDataDir: "/profiles/personal")
            ]
        ),
        workspaceRootURL: FileManager.default.temporaryDirectory,
        launcher: FakeBrowserProcessLauncher(),
        pageDiscoverer: FakeBrowserPageDiscoverer(webSocketURL: URL(string: "ws://127.0.0.1:9222/devtools/page/1")!),
        cdpConnector: FakeBrowserCDPConnector(session: FakeBrowserCDPSession { _, _ in [:] })
    )

    let result = await service.invoke(
        sessionID: "session-4",
        request: ToolInvocationRequest(
            tool: "browser",
            arguments: [
                "action": .string("navigate"),
                "url": .string("https://example.com")
            ]
        )
    )

    #expect(result.ok == false)
    #expect(result.error?.code == "profile_required")
}

@Test
func browserCleanupStopsProcessAndClosesCDPSession() async throws {
    let controller = FakeBrowserProcessController()
    let launcher = FakeBrowserProcessLauncher(controller: controller)
    let cdpSession = FakeBrowserCDPSession { method, params in
        switch method {
        case "Page.enable", "Runtime.enable", "Page.navigate":
            return [:]
        case "Runtime.evaluate":
            if params["expression"]?.asString == "document.readyState" {
                return ["result": .object(["value": .string("complete")])]
            }
            return ["result": .object(["value": .null])]
        default:
            return [:]
        }
    }
    let service = BrowserRuntimeService(
        browserConfig: .init(),
        workspaceRootURL: FileManager.default.temporaryDirectory,
        launcher: launcher,
        pageDiscoverer: FakeBrowserPageDiscoverer(webSocketURL: URL(string: "ws://127.0.0.1:9222/devtools/page/1")!),
        cdpConnector: FakeBrowserCDPConnector(session: cdpSession)
    )

    _ = await service.invoke(
        sessionID: "session-5",
        request: ToolInvocationRequest(
            tool: "browser",
            arguments: [
                "action": .string("navigate"),
                "url": .string("https://example.com")
            ]
        )
    )
    await service.cleanupSession("session-5")

    let terminateCallCount = await controller.terminateCallCount
    #expect(terminateCallCount == 1)
    let closeCallCount = await cdpSession.closeCallCount
    #expect(closeCallCount == 1)
}

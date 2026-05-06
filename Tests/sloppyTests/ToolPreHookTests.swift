import Foundation
import Testing
@testable import sloppy
@testable import Protocols

@Suite("Tool pre-hook")
struct ToolPreHookTests {
    @Test("legacy CoreConfig decodes with pre-tools hook disabled")
    func legacyCoreConfigDecodesWithPreToolsHookDisabled() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(CoreConfig.default)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "toolHooks")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CoreConfig.self, from: legacyData)

        #expect(decoded.toolHooks.preTools.enabled == false)
        #expect(decoded.toolHooks.preTools.failurePolicy == .block)
    }

    @Test("legacy tools policy decodes with inherited pre-tools hook override")
    func legacyToolsPolicyDecodesWithInheritedPreToolsHookOverride() throws {
        let json = """
        {
          "version": 1,
          "defaultPolicy": "allow",
          "tools": {},
          "approval": {"enabled": false},
          "guardrails": {}
        }
        """

        let decoded = try JSONDecoder().decode(AgentToolsPolicy.self, from: Data(json.utf8))

        #expect(decoded.preToolsHook.enabled == nil)
        #expect(decoded.preToolsHook.command == nil)
        #expect(decoded.preToolsHook.failurePolicy == nil)
    }

    @Test("pre-tools hook rewrites arguments before persistence and execution")
    func preToolsHookRewritesArgumentsBeforePersistenceAndExecution() async throws {
        var config = CoreConfig.test
        config.toolHooks.preTools = .init(
            enabled: true,
            command: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s' '{"action":"allow","arguments":{"path":"safe.txt"},"reason":"rewritten by hook"}'"#
            ]
        )
        let service = CoreService(config: config)
        let agentID = "pre-hook-rewrite-\(UUID().uuidString)"
        let sessionID = try await makeAgentSession(service: service, agentID: agentID)
        let workspace = config.resolvedWorkspaceRootURL()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("safe content".utf8).write(to: workspace.appendingPathComponent("safe.txt"))

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: sessionID,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string("secret.txt")])
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["path"]?.asString == workspace.appendingPathComponent("safe.txt").path)
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        let toolCall = try #require(detail.events.first(where: { $0.type == .toolCall })?.toolCall)
        #expect(toolCall.arguments["path"]?.asString == "safe.txt")
        #expect(toolCall.reason == "rewritten by hook")
        #expect(detail.events.contains { $0.toolCall?.arguments["path"]?.asString == "secret.txt" } == false)
    }

    @Test("pre-tools hook block prevents tool call persistence and execution")
    func preToolsHookBlockPreventsToolCallPersistenceAndExecution() async throws {
        var config = CoreConfig.test
        config.toolHooks.preTools = .init(
            enabled: true,
            command: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s' '{"action":"block","message":"private payload"}'"#
            ]
        )
        let service = CoreService(config: config)
        let agentID = "pre-hook-block-\(UUID().uuidString)"
        let sessionID = try await makeAgentSession(service: service, agentID: agentID)

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: sessionID,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string("secret.txt")])
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "tool_pre_hook_blocked")
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        #expect(detail.events.contains { $0.type == .toolCall } == false)
        #expect(detail.events.contains { $0.toolResult?.error?.code == "tool_pre_hook_blocked" } == true)
    }

    @Test("pre-tools hook failure blocks by default")
    func preToolsHookFailureBlocksByDefault() async throws {
        var config = CoreConfig.test
        config.toolHooks.preTools = .init(
            enabled: true,
            command: "/bin/sh",
            arguments: ["-c", "exit 7"]
        )
        let service = CoreService(config: config)
        let agentID = "pre-hook-failure-\(UUID().uuidString)"
        let sessionID = try await makeAgentSession(service: service, agentID: agentID)

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: sessionID,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string("secret.txt")])
        )

        #expect(result.ok == false)
        #expect(result.error?.code == "tool_pre_hook_failed")
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        #expect(detail.events.contains { $0.type == .toolCall } == false)
    }

    @Test("pre-tools hook failure can allow original request")
    func preToolsHookFailureCanAllowOriginalRequest() async throws {
        var config = CoreConfig.test
        config.toolHooks.preTools = .init(
            enabled: true,
            command: "/bin/sh",
            arguments: ["-c", "exit 7"],
            failurePolicy: .allow
        )
        let service = CoreService(config: config)
        let agentID = "pre-hook-failure-allow-\(UUID().uuidString)"
        let sessionID = try await makeAgentSession(service: service, agentID: agentID)
        let workspace = config.resolvedWorkspaceRootURL()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: workspace.appendingPathComponent("visible.txt"))

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: sessionID,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string("visible.txt")])
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "visible")
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        let toolCall = try #require(detail.events.first(where: { $0.type == .toolCall })?.toolCall)
        #expect(toolCall.arguments["path"]?.asString == "visible.txt")
    }

    @Test("per-agent pre-tools hook override can disable global hook")
    func perAgentPreToolsHookOverrideCanDisableGlobalHook() async throws {
        var config = CoreConfig.test
        config.toolHooks.preTools = .init(
            enabled: true,
            command: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s' '{"action":"block","message":"global block"}'"#
            ]
        )
        let service = CoreService(config: config)
        let agentID = "pre-hook-disable-\(UUID().uuidString)"
        let sessionID = try await makeAgentSession(service: service, agentID: agentID)
        let workspace = config.resolvedWorkspaceRootURL()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: workspace.appendingPathComponent("visible.txt"))
        _ = try await service.updateAgentToolsPolicy(
            agentID: agentID,
            request: AgentToolsUpdateRequest(preToolsHook: AgentToolPreHookOverride(enabled: false))
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: sessionID,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string("visible.txt")])
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "visible")
    }

    @Test("per-agent pre-tools hook override can replace command and timeout")
    func perAgentPreToolsHookOverrideCanReplaceCommandAndTimeout() async throws {
        var config = CoreConfig.test
        config.toolHooks.preTools = .init(
            enabled: true,
            command: "/bin/sh",
            arguments: ["-c", #"printf '%s' '{"action":"block","message":"global block"}'"#],
            timeoutMs: 1
        )
        let service = CoreService(config: config)
        let agentID = "pre-hook-override-\(UUID().uuidString)"
        let sessionID = try await makeAgentSession(service: service, agentID: agentID)
        let workspace = config.resolvedWorkspaceRootURL()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("override safe".utf8).write(to: workspace.appendingPathComponent("override-safe.txt"))
        _ = try await service.updateAgentToolsPolicy(
            agentID: agentID,
            request: AgentToolsUpdateRequest(
                preToolsHook: AgentToolPreHookOverride(
                    command: "/bin/sh",
                    arguments: [
                        "-c",
                        #"sleep 0.05; printf '%s' '{"action":"allow","arguments":{"path":"override-safe.txt"}}'"#
                    ],
                    timeoutMs: 1_000
                )
            )
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: sessionID,
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string("secret.txt")])
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "override safe")
    }

    @Test("channel runtime applies pre-tools hook rewrite")
    func channelRuntimeAppliesPreToolsHookRewrite() async throws {
        var config = CoreConfig.test
        config.toolHooks.preTools = .init(
            enabled: true,
            command: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s' '{"action":"allow","arguments":{"path":"channel-safe.txt"}}'"#
            ]
        )
        let service = CoreService(config: config)
        let agentID = "pre-hook-channel-\(UUID().uuidString)"
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Channel Hook Agent", role: "Tests pre-hook")
        )
        let workspace = config.resolvedWorkspaceRootURL()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("channel safe".utf8).write(to: workspace.appendingPathComponent("channel-safe.txt"))

        let result = await service.invokeToolFromChannelRuntime(
            agentID: agentID,
            channelID: "channel:hook",
            request: ToolInvocationRequest(tool: "files.read", arguments: ["path": .string("channel-secret.txt")])
        )

        #expect(result.ok == true)
        #expect(result.data?.asObject?["content"]?.asString == "channel safe")
    }

    private func makeAgentSession(service: CoreService, agentID: String) async throws -> String {
        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Pre Hook Agent", role: "Tests pre-tools hook")
        )
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "Pre Hook Session")
        )
        return session.id
    }
}

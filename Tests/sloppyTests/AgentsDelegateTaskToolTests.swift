import Foundation
import Logging
import Testing
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("agents.delegate_task argument validation")
struct AgentsDelegateTaskToolTests {

    private func makeContext(delegateSubagent: (@Sendable (String, String, String, String?, [String]?, String?, String?) async -> String?)?) -> ToolContext {
        let guardrails = AgentToolsGuardrails()
        let policy = AgentToolsPolicy(guardrails: guardrails)
        let tmp = FileManager.default.temporaryDirectory
        let workspace = tmp.appendingPathComponent("sloppy-delegate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return ToolContext(
            agentID: "test-agent",
            sessionID: "session-test",
            policy: policy,
            workspaceRootURL: workspace,
            runtime: RuntimeSystem(),
            memoryStore: InMemoryMemoryStore(),
            sessionStore: AgentSessionFileStore(agentsRootURL: tmp),
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: tmp),
            agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(),
            channelSessionStore: ChannelSessionFileStore(workspaceRootURL: tmp),
            store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
            searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
            mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
            logger: Logger(label: "test"),
            projectService: nil,
            configService: nil,
            skillsService: nil,
            lspManager: nil,
            applyAgentMarkdown: nil,
            delegateSubagent: delegateSubagent
        )
    }

    @Test("Rejects goal and non-empty tasks together with hint")
    func rejectsGoalAndTasksTogether() async {
        let tool = AgentsDelegateTaskTool()
        let context = makeContext(delegateSubagent: { _, _, _, _, _, _, _ in "ok" })
        let result = await tool.invoke(
            arguments: [
                "goal": .string("do a"),
                "tasks": .array([.string("do b")]),
            ],
            context: context
        )
        #expect(result.ok == false)
        #expect(result.error?.code == "invalid_arguments")
        #expect(result.error?.hint?.contains("goal") == true)
    }

    @Test("Accepts goal with empty tasks array")
    func acceptsGoalWithEmptyTasks() async {
        let tool = AgentsDelegateTaskTool()
        let context = makeContext(delegateSubagent: { _, _, _, _, _, _, _ in "done" })
        let result = await tool.invoke(
            arguments: [
                "goal": .string("single task"),
                "tasks": .array([]),
            ],
            context: context
        )
        #expect(result.ok == true)
    }

    @Test("Passes current session id to delegated subagent runner")
    func passesParentSessionIDToRunner() async throws {
        let tool = AgentsDelegateTaskTool()
        let context = makeContext(delegateSubagent: { _, _, _, _, _, _, parentSessionID in
            parentSessionID ?? "missing"
        })
        let result = await tool.invoke(
            arguments: [
                "goal": .string("single task"),
            ],
            context: context
        )

        let data = try #require(result.data?.asObject)
        let results = try #require(data["results"]?.asArray)
        let first = try #require(results.first?.asObject)
        #expect(first["summary"]?.asString == "session-test")
    }

    @Test("Finish tool accepts completed outcomes")
    func finishToolAcceptsCompletedOutcomes() async throws {
        let tool = AgentDelegateFinishTool()
        let context = makeContext(delegateSubagent: nil)
        let result = await tool.invoke(
            arguments: [
                "status": .string("done"),
                "summary": .string("Found the source file and returned snippets."),
            ],
            context: context
        )

        let data = try #require(result.data?.asObject)
        #expect(result.ok)
        #expect(data["finished"]?.asBool == true)
        #expect(data["status"]?.asString == "completed")
    }

    @Test("Finish tool requires error for failed outcomes")
    func finishToolRequiresErrorForFailedOutcomes() async {
        let tool = AgentDelegateFinishTool()
        let context = makeContext(delegateSubagent: nil)
        let result = await tool.invoke(
            arguments: [
                "status": .string("failed"),
                "summary": .string("Could not inspect the tree."),
            ],
            context: context
        )

        #expect(!result.ok)
        #expect(result.error?.code == "invalid_arguments")
    }
}

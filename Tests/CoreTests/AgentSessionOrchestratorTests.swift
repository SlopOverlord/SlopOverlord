import Foundation
import Testing
@testable import AgentRuntime
@testable import Core
@testable import PluginSDK
@testable import Protocols

private actor SessionCapturingModelProvider: ModelProviderPlugin {
    let id: String = "session-capturing"
    let models: [String]
    private(set) var requestedModels: [String] = []
    private(set) var requestedReasoningEfforts: [ReasoningEffort?] = []

    init(models: [String]) {
        self.models = models
    }

    func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) async throws -> String {
        requestedModels.append(model)
        requestedReasoningEfforts.append(reasoningEffort)
        return "Captured."
    }

    func requestedModelsSnapshot() -> [String] {
        requestedModels
    }

    func requestedReasoningEffortsSnapshot() -> [ReasoningEffort?] {
        requestedReasoningEfforts
    }
}

private func makeAgentSessionFixture(
    agentID: String,
    selectedModel: String,
    availableModels: [ProviderModelOption]
) throws -> (AgentCatalogFileStore, AgentSessionFileStore, URL) {
    let agentsRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-orchestrator-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("agents", isDirectory: true)
    let catalogStore = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let sessionStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)

    _ = try catalogStore.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Agent \(agentID)",
            role: "Test agent"
        ),
        availableModels: availableModels
    )
    _ = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            selectedModel: selectedModel,
            documents: AgentDocumentBundle(
                userMarkdown: "# User\nTest user\n",
                agentsMarkdown: "# Agent\nTest agent\n",
                soulMarkdown: "# Soul\nTest soul\n",
                identityMarkdown: "# Identity\n\(agentID)\n"
            )
        ),
        availableModels: availableModels
    )

    return (catalogStore, sessionStore, agentsRootURL)
}

@Test
func agentSessionOrchestratorUsesSelectedReasoningModelAndEffort() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:o4-mini", title: "openai:o4-mini", capabilities: ["reasoning", "tools"]),
        ProviderModelOption(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "reasoning-agent",
        selectedModel: "openai:o4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai:gpt-4.1-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "reasoning-agent", request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: "reasoning-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Please think",
            reasoningEffort: .high
        )
    )

    #expect(await provider.requestedModelsSnapshot().last == "openai:o4-mini")
    #expect(await provider.requestedReasoningEffortsSnapshot().last == .high)
}

@Test
func agentSessionOrchestratorDropsReasoningEffortForNonReasoningModels() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:o4-mini", title: "openai:o4-mini", capabilities: ["reasoning", "tools"]),
        ProviderModelOption(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "non-reasoning-agent",
        selectedModel: "openai:gpt-4.1-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai:o4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "non-reasoning-agent", request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: "non-reasoning-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Please think",
            reasoningEffort: .high
        )
    )

    #expect(await provider.requestedModelsSnapshot() == ["openai:gpt-4.1-mini"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [nil])
}

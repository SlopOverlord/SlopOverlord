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

private actor FixedOutputModelProvider: ModelProviderPlugin {
    let id: String = "fixed-output"
    let models: [String]
    let output: String

    init(models: [String], output: String) {
        self.models = models
        self.output = output
    }

    func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) async throws -> String {
        output
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

private func expectedFallbackBootstrapMessage(
    agentID: String,
    sessionID: String,
    documents: AgentDocumentBundle
) throws -> String {
    let loader = PromptTemplateLoader()
    let renderer = PromptTemplateRenderer()
    let capabilities = try renderer.render(
        template: try loader.loadPartial(named: "session_capabilities"),
        values: [:]
    )
    let runtimeRules = try renderer.render(
        template: try loader.loadPartial(named: "runtime_rules"),
        values: [:]
    )

    return """
    [agent_session_context_bootstrap_v1]
    Session context initialized.
    Agent: \(agentID)
    Session: \(sessionID)

    [Agents.md]
    \(documents.agentsMarkdown)

    [User.md]
    \(documents.userMarkdown)

    [Identity.md]
    \(documents.identityMarkdown)

    [Soul.md]
    \(documents.soulMarkdown)

    \(capabilities)

    \(runtimeRules)
    """
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

@Test
func agentSessionBootstrapIncludesInstalledSkillsSummary() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "skills-agent",
        selectedModel: "openai:gpt-4.1-mini",
        availableModels: availableModels
    )
    let skillsStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)
    _ = try skillsStore.installSkill(
        agentID: "skills-agent",
        owner: "acme",
        repo: "release-skills",
        name: "release-helper",
        description: "Guides release execution"
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: skillsStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "skills-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:skills-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Skills]"))
    #expect(bootstrapMessage.contains("`acme/release-skills`"))
    #expect(bootstrapMessage.contains("release-helper"))
    #expect(bootstrapMessage.contains("Guides release execution"))
    #expect(bootstrapMessage.contains("path: `\(agentsRootURL.appendingPathComponent("skills-agent", isDirectory: true).appendingPathComponent("skills", isDirectory: true).appendingPathComponent("acme/release-skills", isDirectory: true).path)`"))
}

@Test
func agentSessionBootstrapRendersEmptySkillsStateWhenAgentHasNoSkills() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "skills-empty-agent",
        selectedModel: "openai:gpt-4.1-mini",
        availableModels: availableModels
    )
    let skillsStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: skillsStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "skills-empty-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:skills-empty-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Skills]"))
    #expect(bootstrapMessage.contains("No additional skills installed."))
}

@Test
func agentSessionBootstrapIncludesToolCallProtocol() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "tool-protocol-agent",
        selectedModel: "openai:gpt-4.1-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "tool-protocol-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:tool-protocol-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains(#""tool":"<tool-id>""#))
    #expect(bootstrapMessage.contains("`runtime.exec`"))
    #expect(bootstrapMessage.contains("`files.write`"))
}

@Test
func agentSessionTextContainingFailedDoesNotForceInterruptedStatus() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "non-error-failed-agent",
        selectedModel: "openai:gpt-4.1-mini",
        availableModels: availableModels
    )
    let provider = FixedOutputModelProvider(
        models: availableModels.map(\.id),
        output: "Initial inspection hit a tool failure, so I need one more recovery pass before I can claim the workspace has been reviewed."
    )

    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai:gpt-4.1-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "non-error-failed-agent", request: AgentSessionCreateRequest())
    let response = try await orchestrator.postMessage(
        agentID: "non-error-failed-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "inspect the workspace"
        )
    )

    let finalStatus = response.appendedEvents.last(where: { $0.type == .runStatus })?.runStatus?.stage
    #expect(finalStatus == .done)
}

@Test
func agentSessionBootstrapFallsBackWhenPromptComposerFails() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "fallback-agent",
        selectedModel: "openai:gpt-4.1-mini",
        availableModels: availableModels
    )
    let documents = try catalogStore.readAgentDocuments(agentID: "fallback-agent")
    let failingLoader = PromptTemplateLoader(resolver: { _ in
        throw PromptTemplateLoader.LoaderError.templateNotFound("forced-failure")
    })
    let composer = AgentPromptComposer(templateLoader: failingLoader)

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: AgentSkillsFileStore(agentsRootURL: agentsRootURL),
        promptComposer: composer,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "fallback-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:fallback-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    let expected = try expectedFallbackBootstrapMessage(
        agentID: "fallback-agent",
        sessionID: session.id,
        documents: documents
    )
    #expect(bootstrapMessage == expected)
}

import AnyLanguageModel
import Foundation
import Testing
@testable import AgentRuntime
@testable import sloppy
@testable import PluginSDK
@testable import Protocols

private final class MockCallStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _models: [String] = []
    private var _reasoningEfforts: [ReasoningEffort?] = []
    private var _prompts: [String] = []

    func recordModel(_ model: String) { lock.withLock { _models.append(model) } }
    func recordEffort(_ effort: ReasoningEffort?) { lock.withLock { _reasoningEfforts.append(effort) } }
    func recordPrompt(_ prompt: Prompt) { lock.withLock { _prompts.append(prompt.description) } }
    var models: [String] { lock.withLock { _models } }
    var reasoningEfforts: [ReasoningEffort?] { lock.withLock { _reasoningEfforts } }
    var prompts: [String] { lock.withLock { _prompts } }
}

private struct FixedTextLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let text: String
    var callStore: MockCallStore? = nil

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("FixedTextLanguageModel: only String supported") }
        callStore?.recordPrompt(prompt)
        return LanguageModelSession.Response(
            content: text as! Content,
            rawContent: GeneratedContent(text),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                guard let response = try? await respond(
                    within: session, to: prompt, generating: type,
                    includeSchemaInPrompt: includeSchemaInPrompt, options: options
                ) else {
                    continuation.finish()
                    return
                }
                continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor SessionCapturingModelProvider: ModelProvider {
    let id: String = "session-capturing"
    let supportedModels: [String]
    nonisolated let callStore = MockCallStore()

    init(models: [String]) {
        self.supportedModels = models
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return FixedTextLanguageModel(text: "Captured.", callStore: callStore)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func requestedModelsSnapshot() -> [String] { callStore.models }
    func requestedReasoningEffortsSnapshot() -> [ReasoningEffort?] { callStore.reasoningEfforts }
    func requestedPromptsSnapshot() -> [String] { callStore.prompts }
}

private actor FixedOutputModelProvider: ModelProvider {
    let id: String = "fixed-output"
    let supportedModels: [String]
    private let output: String

    init(models: [String], output: String) {
        self.supportedModels = models
        self.output = output
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        FixedTextLanguageModel(text: output)
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
            role: nil,
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
    documents: AgentDocumentBundle,
    agentDirectoryPath: String? = nil
) throws -> String {
    let loader = PromptTemplateLoader()
    let renderer = PromptTemplateRenderer()
    let capabilities = try renderer.render(template: try loader.loadPartial(named: "session_capabilities"), values: [:])
    let runtimeRules = try renderer.render(template: try loader.loadPartial(named: "runtime_rules"), values: [:])
    let branchingRules = try renderer.render(template: try loader.loadPartial(named: "branching_rules"), values: [:])
    let workerRules = try renderer.render(template: try loader.loadPartial(named: "worker_rules"), values: [:])
    let toolsInstruction = try renderer.render(template: try loader.loadPartial(named: "tools_instruction"), values: [:])
    let taskPlanningRules = try renderer.render(template: try loader.loadPartial(named: "task_planning_rules"), values: [:])
    let completionReflection = try renderer.render(template: try loader.loadPartial(named: "completion_reflection"), values: [:])
    let agentDirectoryLine = agentDirectoryPath.map { "Agent directory: \($0)\n" } ?? ""

    return """
    [agent_session_context_bootstrap_v1]
    Session context initialized.
    Agent: \(agentID)
    \(agentDirectoryLine)Session: \(sessionID)

    [AGENTS.md]
    \(documents.agentsMarkdown)

    [USER.md]
    \(documents.userMarkdown)

    [IDENTITY.md]
    \(documents.identityMarkdown)

    [SOUL.md]
    \(documents.soulMarkdown)

    \(capabilities)

    \(runtimeRules)

    \(branchingRules)

    \(workerRules)

    \(toolsInstruction)

    \(taskPlanningRules)

    \(completionReflection)
    """
}

@Test
func agentSessionOrchestratorUsesSelectedReasoningModelAndEffort() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:o4-mini", title: "openai:o4-mini", capabilities: ["reasoning", "tools"]),
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "reasoning-agent",
        selectedModel: "openai:o4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai:gpt-5.4-mini")
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
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "non-reasoning-agent",
        selectedModel: "openai:gpt-5.4-mini",
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

    #expect(await provider.requestedModelsSnapshot() == ["openai:gpt-5.4-mini"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [nil])
}

@Test
func agentSessionOrchestratorAppendsFriendReminderToRuntimeUserMessage() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentID = "friend-reminder-agent"
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )
    _ = try catalogStore.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: "openai:gpt-5.4-mini",
            documents: AgentDocumentBundle(
                userMarkdown: "# User\nTest user\n",
                agentsMarkdown: "# Agent\nTest agent\n",
                soulMarkdown: "# Soul\nTest soul\n",
                identityMarkdown: "# Identity\n\(agentID)\n",
                friendReminderMarkdown: "- Do not use mcps\n- always run git pull\n"
            )
        ),
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(
            userId: "dashboard",
            content: "Да, исправь это как можно скорее",
            mode: .build
        )
    )

    let prompt = await provider.requestedPromptsSnapshot().last ?? ""
    #expect(prompt.contains("User request:\nДа, исправь это как можно скорее"))
    #expect(prompt.contains("#[FRIEND_REMINDER.md]\n- Do not use mcps\n- always run git pull"))
}

@Test
func agentSessionBootstrapIncludesInstalledSkillsSummary() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "skills-agent",
        selectedModel: "openai:gpt-5.4-mini",
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
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "skills-empty-agent",
        selectedModel: "openai:gpt-5.4-mini",
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

    #expect(!bootstrapMessage.contains("[Skills]"))
}

@Test
func agentSessionBootstrapIncludesToolCallProtocol() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "tool-protocol-agent",
        selectedModel: "openai:gpt-5.4-mini",
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

    #expect(bootstrapMessage.contains("`branches.spawn`"))
    #expect(bootstrapMessage.contains("`workers.spawn`"))
    #expect(bootstrapMessage.contains("`workers.route`"))
    #expect(bootstrapMessage.contains("[Branching rules]"))
    #expect(bootstrapMessage.contains("[Worker rules]"))
    #expect(bootstrapMessage.contains("[Tools usage rules]"))
    #expect(bootstrapMessage.contains("native function calls"))
    #expect(bootstrapMessage.contains("`cron`"))
}

@Test
func agentSessionTextContainingFailedDoesNotForceInterruptedStatus() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "non-error-failed-agent",
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = FixedOutputModelProvider(
        models: availableModels.map(\.id),
        output: "Initial inspection hit a tool failure, so I need one more recovery pass before I can claim the workspace has been reviewed."
    )

    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai:gpt-5.4-mini")
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
func agentSessionReusesPersistentSessionAcrossMessages() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "session-reuse-agent",
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )
    let provider = SessionCapturingModelProvider(models: availableModels.map(\.id))
    let runtime = RuntimeSystem(modelProvider: provider, defaultModel: "openai:gpt-5.4-mini")
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "session-reuse-agent", request: AgentSessionCreateRequest())
    _ = try await orchestrator.postMessage(
        agentID: "session-reuse-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "first message")
    )
    _ = try await orchestrator.postMessage(
        agentID: "session-reuse-agent",
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "second message")
    )

    #expect(await provider.requestedModelsSnapshot().count == 1)
}

@Test
func agentSessionBootstrapFallsBackWhenPromptComposerFails() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "fallback-agent",
        selectedModel: "openai:gpt-5.4-mini",
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
        documents: documents,
        agentDirectoryPath: agentsRootURL.appendingPathComponent("fallback-agent", isDirectory: true).path
    )
    func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
    }
    #expect(normalized(bootstrapMessage) == normalized(expected))
}

@Test
func agentSessionBootstrapIncludesSkillsRulesPartial() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "skills-rules-agent",
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "skills-rules-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:skills-rules-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Skills rules]"))
    #expect(bootstrapMessage.contains("files.read"))
    #expect(bootstrapMessage.contains("SKILL.md"))
}

@Test
func agentSessionBootstrapIncludesCompletionReflectionPartial() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "completion-reflection-agent",
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "completion-reflection-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:completion-reflection-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Completion reflection]"))
    #expect(bootstrapMessage.contains("turned into a skill or remembered"))
    #expect(bootstrapMessage.contains("Is there anything from this work"))
}

@Test
func agentSessionBootstrapIncludesTaskPlanningRulesPartial() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: "task-planning-rules-agent",
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "task-planning-rules-agent", request: AgentSessionCreateRequest())
    let snapshot = await runtime.channelState(channelId: "agent:task-planning-rules-agent:session:\(session.id)")
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Task planning rules]"))
    #expect(bootstrapMessage.contains("project.task_list"))
    #expect(bootstrapMessage.contains("project.task_update"))
    #expect(bootstrapMessage.contains("not only by exact title text"))
}

@Test
func notifySkillsChangedAppendsSystemMessageToActiveSessions() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "notify-skills-agent",
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: AgentSkillsFileStore(agentsRootURL: agentsRootURL),
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(agentID: "notify-skills-agent", request: AgentSessionCreateRequest())
    let channelID = "agent:notify-skills-agent:session:\(session.id)"
    let messageCountBefore = await runtime.channelState(channelId: channelID)?.messages.count ?? 0

    // Install the skill via a separate store instance (same filesystem root) to simulate mid-session install
    let installStore = AgentSkillsFileStore(agentsRootURL: agentsRootURL)
    _ = try installStore.installSkill(
        agentID: "notify-skills-agent",
        owner: "acme",
        repo: "test-skill",
        name: "test-skill",
        description: "A test skill"
    )

    await orchestrator.notifySkillsChanged(agentID: "notify-skills-agent")

    let messages = await runtime.channelState(channelId: channelID)?.messages ?? []
    #expect(messages.count > messageCountBefore)

    let skillsUpdateMessage = messages.last(where: {
        $0.userId == "system" && $0.content.contains("[Skills updated]")
    })
    #expect(skillsUpdateMessage != nil)
    #expect(skillsUpdateMessage?.content.contains("`acme/test-skill`") == true)
    #expect(skillsUpdateMessage?.content.contains("test-skill") == true)
}

@Test
func notifySkillsChangedDoesNothingForNonBootstrappedSessions() async throws {
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, agentsRootURL) = try makeAgentSessionFixture(
        agentID: "notify-no-bootstrap-agent",
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        agentSkillsStore: AgentSkillsFileStore(agentsRootURL: agentsRootURL),
        availableModels: availableModels
    )

    // No session created — notifySkillsChanged should be a no-op (no bootstrapped channels)
    await orchestrator.notifySkillsChanged(agentID: "notify-no-bootstrap-agent")

    let channelID = "agent:notify-no-bootstrap-agent:session:nonexistent-session"
    let snapshot = await runtime.channelState(channelId: channelID)
    #expect(snapshot == nil)
}

@Test
func agentSessionBootstrapIncludesConversationHistoryAfterRestart() async throws {
    let agentID = "restart-history-agent"
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let agentsRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-restart-history-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("agents", isDirectory: true)

    let catalogStore1 = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let sessionStore1 = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    _ = try catalogStore1.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Agent", role: "Test agent"),
        availableModels: availableModels
    )
    _ = try catalogStore1.updateAgentConfig(
        agentID: agentID,
        request: AgentConfigUpdateRequest(
            role: nil,
            selectedModel: "openai:gpt-5.4-mini",
            documents: AgentDocumentBundle(
                userMarkdown: "# User\nTest\n",
                agentsMarkdown: "# Agent\nTest\n",
                soulMarkdown: "",
                identityMarkdown: ""
            )
        ),
        availableModels: availableModels
    )

    let provider1 = FixedOutputModelProvider(
        models: availableModels.map(\.id),
        output: "Hello! I can help with that."
    )
    let runtime1 = RuntimeSystem(modelProvider: provider1, defaultModel: "openai:gpt-5.4-mini")
    let orchestrator1 = AgentSessionOrchestrator(
        runtime: runtime1,
        sessionStore: sessionStore1,
        agentCatalogStore: catalogStore1,
        availableModels: availableModels
    )

    let session = try await orchestrator1.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Restart test")
    )
    _ = try await orchestrator1.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Tell me about Swift concurrency")
    )
    _ = try await orchestrator1.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "How do actors work?")
    )

    let provider2 = FixedOutputModelProvider(
        models: availableModels.map(\.id),
        output: "Continuing the discussion."
    )
    let runtime2 = RuntimeSystem(modelProvider: provider2, defaultModel: "openai:gpt-5.4-mini")
    let sessionStore2 = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let catalogStore2 = AgentCatalogFileStore(agentsRootURL: agentsRootURL)
    let orchestrator2 = AgentSessionOrchestrator(
        runtime: runtime2,
        sessionStore: sessionStore2,
        agentCatalogStore: catalogStore2,
        availableModels: availableModels
    )

    _ = try await orchestrator2.postMessage(
        agentID: agentID,
        sessionID: session.id,
        request: AgentSessionPostMessageRequest(userId: "dashboard", content: "Continue please")
    )

    let channelID = "agent:\(agentID):session:\(session.id)"
    let snapshot = await runtime2.channelState(channelId: channelID)
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(bootstrapMessage.contains("[Previous conversation history]"))
    #expect(bootstrapMessage.contains("Tell me about Swift concurrency"))
    #expect(bootstrapMessage.contains("How do actors work?"))
    #expect(bootstrapMessage.contains("[End of previous conversation]"))
}

@Test
func agentSessionBootstrapOmitsHistoryForFreshSession() async throws {
    let agentID = "fresh-no-history-agent"
    let availableModels = [
        ProviderModelOption(id: "openai:gpt-5.4-mini", title: "openai:gpt-5.4-mini", capabilities: ["tools"])
    ]
    let (catalogStore, sessionStore, _) = try makeAgentSessionFixture(
        agentID: agentID,
        selectedModel: "openai:gpt-5.4-mini",
        availableModels: availableModels
    )

    let runtime = RuntimeSystem()
    let orchestrator = AgentSessionOrchestrator(
        runtime: runtime,
        sessionStore: sessionStore,
        agentCatalogStore: catalogStore,
        availableModels: availableModels
    )

    let session = try await orchestrator.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest()
    )

    let channelID = "agent:\(agentID):session:\(session.id)"
    let snapshot = await runtime.channelState(channelId: channelID)
    let bootstrapMessage = snapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })?.content ?? ""

    #expect(!bootstrapMessage.contains("[Previous conversation history]"))
}

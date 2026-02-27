import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AgentRuntime
import PluginSDK
import Protocols

public actor CoreService {
    public enum AgentStorageError: Error {
        case invalidID
        case invalidPayload
        case alreadyExists
        case notFound
    }

    public enum AgentSessionError: Error {
        case invalidAgentID
        case invalidSessionID
        case invalidPayload
        case agentNotFound
        case sessionNotFound
        case storageFailure
    }

    public enum AgentConfigError: Error {
        case invalidAgentID
        case invalidPayload
        case invalidModel
        case agentNotFound
        case storageFailure
    }

    private let runtime: RuntimeSystem
    private let store: any PersistenceStore
    private let sessionStore: AgentSessionFileStore
    private let configPath: String
    private let fileManager: FileManager
    private var agentsRootURL: URL
    private var currentConfig: CoreConfig
    private var eventTask: Task<Void, Never>?

    /// Creates core orchestration service with runtime and persistence backend.
    public init(config: CoreConfig, configPath: String = CoreConfig.defaultConfigPath) {
        let resolvedModels = Self.resolveModelIdentifiers(config: config)
        let modelProvider = Self.buildModelProvider(config: config, resolvedModels: resolvedModels)
        self.runtime = RuntimeSystem(
            modelProvider: modelProvider,
            defaultModel: modelProvider?.models.first ?? resolvedModels.first
        )
        let schema = Self.loadSchemaSQL()
        self.store = SQLiteStore(path: config.sqlitePath, schemaSQL: schema)
        self.configPath = configPath
        self.fileManager = FileManager.default
        self.agentsRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("agents", isDirectory: true)
        self.sessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        self.currentConfig = config
        Task {
            await self.startEventPersistence()
        }
    }

    deinit {
        eventTask?.cancel()
    }

    /// Accepts a user channel message and returns routing decision.
    public func postChannelMessage(channelId: String, request: ChannelMessageRequest) async -> ChannelRouteDecision {
        await runtime.postMessage(channelId: channelId, request: request)
    }

    /// Routes interactive message into a running worker.
    public func postChannelRoute(channelId: String, workerId: String, request: ChannelRouteRequest) async -> Bool {
        await runtime.routeMessage(channelId: channelId, workerId: workerId, message: request.message)
    }

    /// Returns current state snapshot for a channel.
    public func getChannelState(channelId: String) async -> ChannelSnapshot? {
        await runtime.channelState(channelId: channelId)
    }

    /// Returns known visor bulletins, preferring in-memory runtime state.
    public func getBulletins() async -> [MemoryBulletin] {
        let runtimeBulletins = await runtime.bulletins()
        if runtimeBulletins.isEmpty {
            return await store.listBulletins()
        }
        return runtimeBulletins
    }

    /// Creates worker instance from API request.
    public func postWorker(request: WorkerCreateRequest) async -> String {
        await runtime.createWorker(spec: request.spec)
    }

    /// Reads artifact content from runtime or persistent storage.
    public func getArtifactContent(id: String) async -> ArtifactContentResponse? {
        if let runtimeArtifact = await runtime.artifactContent(id: id) {
            await store.persistArtifact(id: id, content: runtimeArtifact)
            return ArtifactContentResponse(id: id, content: runtimeArtifact)
        }

        if let storedArtifact = await store.artifactContent(id: id) {
            return ArtifactContentResponse(id: id, content: storedArtifact)
        }

        return nil
    }

    /// Forces immediate visor bulletin generation and stores it.
    public func triggerVisorBulletin() async -> MemoryBulletin {
        let bulletin = await runtime.generateVisorBulletin()
        await store.persistBulletin(bulletin)
        return bulletin
    }

    /// Exposes worker snapshots for observability endpoints.
    public func workerSnapshots() async -> [WorkerSnapshot] {
        await runtime.workerSnapshots()
    }

    /// Returns currently active runtime config snapshot.
    public func getConfig() -> CoreConfig {
        currentConfig
    }

    /// Lists all persisted agents from workspace `/agents`.
    public func listAgents() throws -> [AgentSummary] {
        try ensureAgentsRootDirectory()

        let entries = try fileManager.contentsOfDirectory(
            at: agentsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var agents: [AgentSummary] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                continue
            }

            let agentID = entry.lastPathComponent
            if let summary = try? readAgentSummary(id: agentID) {
                agents.append(summary)
            }
        }

        agents.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return agents
    }

    /// Returns one persisted agent by id.
    public func getAgent(id: String) throws -> AgentSummary {
        guard let normalizedID = normalizedAgentID(id) else {
            throw AgentStorageError.invalidID
        }

        guard fileManager.fileExists(atPath: agentDirectoryURL(for: normalizedID).path) else {
            throw AgentStorageError.notFound
        }

        return try readAgentSummary(id: normalizedID)
    }

    /// Creates an agent and provisions `/workspace/agents/<agent_id>` directory.
    public func createAgent(_ request: AgentCreateRequest) throws -> AgentSummary {
        guard let normalizedID = normalizedAgentID(request.id) else {
            throw AgentStorageError.invalidID
        }

        let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = request.role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !role.isEmpty else {
            throw AgentStorageError.invalidPayload
        }

        try ensureAgentsRootDirectory()

        let directoryURL = agentDirectoryURL(for: normalizedID)
        if fileManager.fileExists(atPath: directoryURL.path) {
            throw AgentStorageError.alreadyExists
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let summary = AgentSummary(
            id: normalizedID,
            displayName: displayName,
            role: role,
            createdAt: Date()
        )

        do {
            try writeAgentSummary(summary)
            try writeAgentScaffoldFiles(for: summary)
            return summary
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    /// Returns agent-specific config including selected model and editable markdown docs.
    public func getAgentConfig(agentID: String) throws -> AgentConfigDetail {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentConfigError.invalidAgentID
        }

        let summary: AgentSummary
        do {
            summary = try getAgent(id: normalizedAgentID)
        } catch AgentStorageError.notFound {
            throw AgentConfigError.agentNotFound
        } catch {
            throw AgentConfigError.storageFailure
        }

        let availableModels = availableAgentModels()
        let selectedModel: String
        let documents: AgentDocumentBundle
        do {
            selectedModel = try readAgentConfigFile(for: summary, availableModels: availableModels).selectedModel ?? ""
            documents = try readAgentDocuments(agentID: normalizedAgentID)
        } catch {
            throw AgentConfigError.storageFailure
        }

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            selectedModel: selectedModel,
            availableModels: availableModels,
            documents: documents
        )
    }

    /// Updates agent-specific model and markdown docs.
    public func updateAgentConfig(agentID: String, request: AgentConfigUpdateRequest) throws -> AgentConfigDetail {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentConfigError.invalidAgentID
        }

        let summary: AgentSummary
        do {
            summary = try getAgent(id: normalizedAgentID)
        } catch AgentStorageError.notFound {
            throw AgentConfigError.agentNotFound
        } catch {
            throw AgentConfigError.storageFailure
        }

        let selectedModel = request.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else {
            throw AgentConfigError.invalidModel
        }

        let availableModels = availableAgentModels()
        let allowedModelIDs = Set(availableModels.map(\.id))
        guard allowedModelIDs.contains(selectedModel) else {
            throw AgentConfigError.invalidModel
        }

        let normalizedDocuments = AgentDocumentBundle(
            userMarkdown: normalizedDocumentText(request.documents.userMarkdown),
            agentsMarkdown: normalizedDocumentText(request.documents.agentsMarkdown),
            soulMarkdown: normalizedDocumentText(request.documents.soulMarkdown),
            identityMarkdown: normalizedDocumentText(request.documents.identityMarkdown)
        )

        guard !normalizedDocuments.userMarkdown.isEmpty,
              !normalizedDocuments.agentsMarkdown.isEmpty,
              !normalizedDocuments.soulMarkdown.isEmpty,
              !normalizedDocuments.identityMarkdown.isEmpty
        else {
            throw AgentConfigError.invalidPayload
        }

        do {
            try writeAgentConfigFile(
                AgentConfigFile(
                    id: summary.id,
                    displayName: summary.displayName,
                    role: summary.role,
                    createdAt: summary.createdAt,
                    selectedModel: selectedModel
                )
            )

            let agentDirectory = agentDirectoryURL(for: normalizedAgentID)
            try writeTextFile(contents: normalizedDocuments.agentsMarkdown, at: agentDirectory.appendingPathComponent("Agents.md"))
            try writeTextFile(contents: normalizedDocuments.userMarkdown, at: agentDirectory.appendingPathComponent("User.md"))
            try writeTextFile(contents: normalizedDocuments.soulMarkdown, at: agentDirectory.appendingPathComponent("Soul.md"))
            try writeTextFile(contents: normalizedDocuments.identityMarkdown, at: agentDirectory.appendingPathComponent("Identity.md"))

            let legacyIdentity = normalizedIdentityValue(from: normalizedDocuments.identityMarkdown, fallback: summary.id)
            try writeTextFile(contents: legacyIdentity + "\n", at: agentDirectory.appendingPathComponent("Identity.id"))
        } catch {
            throw AgentConfigError.storageFailure
        }

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            selectedModel: selectedModel,
            availableModels: availableModels,
            documents: normalizedDocuments
        )
    }

    /// Lists agent chat sessions backed by JSONL files.
    public func listAgentSessions(agentID: String) throws -> [AgentSessionSummary] {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            return try sessionStore.listSessions(agentID: normalizedAgentID)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    /// Creates a session for a given agent.
    public func createAgentSession(agentID: String, request: AgentSessionCreateRequest) throws -> AgentSessionSummary {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            return try sessionStore.createSession(agentID: normalizedAgentID, request: request)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    /// Loads one session with its full event history.
    public func getAgentSession(agentID: String, sessionID: String) throws -> AgentSessionDetail {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            return try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    /// Deletes one session and its attachment directory.
    public func deleteAgentSession(agentID: String, sessionID: String) throws {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            try sessionStore.deleteSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    /// Appends user message, run-status events and assistant reply into session JSONL.
    public func postAgentSessionMessage(
        agentID: String,
        sessionID: String,
        request: AgentSessionPostMessageRequest
    ) async throws -> AgentSessionMessageResponse {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !request.attachments.isEmpty else {
            throw AgentSessionError.invalidPayload
        }

        let attachments: [AgentAttachment]
        do {
            attachments = try sessionStore.persistAttachments(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                uploads: request.attachments
            )
        } catch {
            throw mapSessionStoreError(error)
        }

        var userSegments: [AgentMessageSegment] = []
        if !content.isEmpty {
            userSegments.append(.init(kind: .text, text: content))
        }
        userSegments += attachments.map { attachment in
            .init(kind: .attachment, attachment: attachment)
        }

        let userMessage = AgentSessionMessage(
            role: .user,
            segments: userSegments,
            userId: request.userId
        )

        let thinkingText =
            """
            Building route plan and evaluating context budget.
            - Agent: \(normalizedAgentID)
            - Session: \(normalizedSessionID)
            - Attachments: \(attachments.count)
            """

        let thinkingStatus = AgentRunStatusEvent(
            stage: .thinking,
            label: "Thinking",
            details: "Planning response strategy.",
            expandedText: thinkingText
        )

        var events: [AgentSessionEvent] = [
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .message,
                message: userMessage
            ),
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .runStatus,
                runStatus: thinkingStatus
            )
        ]

        let shouldSearch = shouldUseSearchStage(content: content, attachmentCount: attachments.count)
        if shouldSearch {
            events.append(
                AgentSessionEvent(
                    agentId: normalizedAgentID,
                    sessionId: normalizedSessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .searching,
                        label: "Searching",
                        details: "Collecting relevant context."
                    )
                )
            )
        }

        let channelID = "agent:\(normalizedAgentID):session:\(normalizedSessionID)"
        let routeDecision = await runtime.postMessage(
            channelId: channelID,
            request: ChannelMessageRequest(
                userId: request.userId,
                content: content.isEmpty ? "User attached files." : content
            )
        )

        events.append(
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .responding,
                    label: "Responding",
                    details: "Route: \(routeDecision.action.rawValue), confidence \(String(format: "%.2f", routeDecision.confidence))."
                )
            )
        )

        let snapshot = await runtime.channelState(channelId: channelID)
        let assistantText = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? "Done."
        let assistantMessage = AgentSessionMessage(
            role: .assistant,
            segments: [
                .init(
                    kind: .thinking,
                    text: "Route reason: \(routeDecision.reason). Token budget: \(routeDecision.tokenBudget)."
                ),
                .init(kind: .text, text: assistantText)
            ],
            userId: "agent"
        )

        events.append(
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .message,
                message: assistantMessage
            )
        )

        if request.spawnSubSession {
            let childSummary: AgentSessionSummary
            do {
                childSummary = try sessionStore.createSession(
                    agentID: normalizedAgentID,
                    request: AgentSessionCreateRequest(
                        title: "Sub-session \(Date().formatted(date: .omitted, time: .shortened))",
                        parentSessionId: normalizedSessionID
                    )
                )
            } catch {
                throw mapSessionStoreError(error)
            }

            events.append(
                AgentSessionEvent(
                    agentId: normalizedAgentID,
                    sessionId: normalizedSessionID,
                    type: .subSession,
                    subSession: AgentSubSessionEvent(
                        childSessionId: childSummary.id,
                        title: childSummary.title
                    )
                )
            )
        }

        events.append(
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .done,
                    label: "Done",
                    details: "Response is ready."
                )
            )
        )

        let summary: AgentSessionSummary
        do {
            summary = try sessionStore.appendEvents(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                events: events
            )
        } catch {
            throw mapSessionStoreError(error)
        }

        return AgentSessionMessageResponse(
            summary: summary,
            appendedEvents: events,
            routeDecision: routeDecision
        )
    }

    /// Appends control signal (pause/resume/interrupt) and corresponding status.
    public func controlAgentSession(
        agentID: String,
        sessionID: String,
        request: AgentSessionControlRequest
    ) throws -> AgentSessionMessageResponse {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        let statusStage: AgentRunStage
        let statusLabel: String
        switch request.action {
        case .pause:
            statusStage = .paused
            statusLabel = "Paused"
        case .resume:
            statusStage = .thinking
            statusLabel = "Resumed"
        case .interrupt:
            statusStage = .interrupted
            statusLabel = "Interrupted"
        }

        let events = [
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .runControl,
                runControl: AgentRunControlEvent(
                    action: request.action,
                    requestedBy: request.requestedBy,
                    reason: request.reason
                )
            ),
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: statusStage,
                    label: statusLabel,
                    details: request.reason
                )
            )
        ]

        let summary: AgentSessionSummary
        do {
            summary = try sessionStore.appendEvents(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                events: events
            )
        } catch {
            throw mapSessionStoreError(error)
        }

        return AgentSessionMessageResponse(summary: summary, appendedEvents: events, routeDecision: nil)
    }

    /// Returns OpenAI model catalog using API key auth or environment fallback.
    public func listOpenAIModels(request: OpenAIProviderModelsRequest) async -> OpenAIProviderModelsResponse {
        let primaryOpenAIConfig = currentConfig.models.first {
            Self.resolvedIdentifier(for: $0).hasPrefix("openai:")
        }

        let configuredURL = primaryOpenAIConfig?.apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedURL = request.apiUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = Self.parseURL(requestedURL) ?? Self.parseURL(configuredURL) ?? URL(string: "https://api.openai.com/v1")

        let configuredKey = primaryOpenAIConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var usedEnvironmentKey = false
        let resolvedKey: String? = {
            switch request.authMethod {
            case .apiKey:
                if !requestKey.isEmpty {
                    return requestKey
                }
                if !configuredKey.isEmpty {
                    return configuredKey
                }
                if !envKey.isEmpty {
                    usedEnvironmentKey = true
                    return envKey
                }
                return nil
            case .deeplink:
                if !envKey.isEmpty {
                    usedEnvironmentKey = true
                    return envKey
                }
                return nil
            }
        }()

        guard let apiKey = resolvedKey, !apiKey.isEmpty, let baseURL else {
            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "fallback",
                warning: "OpenAI API key is missing. Provide API key or set OPENAI_API_KEY.",
                models: Self.fallbackOpenAIModels
            )
        }

        do {
            let models = try await Self.fetchOpenAIModels(apiKey: apiKey, baseURL: baseURL)
            if models.isEmpty {
                return OpenAIProviderModelsResponse(
                    provider: "openai",
                    authMethod: request.authMethod,
                    usedEnvironmentKey: usedEnvironmentKey,
                    source: "fallback",
                    warning: "Provider returned empty model list.",
                    models: Self.fallbackOpenAIModels
                )
            }

            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "remote",
                warning: nil,
                models: models
            )
        } catch {
            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "fallback",
                warning: "Failed to fetch OpenAI models: \(error.localizedDescription)",
                models: Self.fallbackOpenAIModels
            )
        }
    }

    /// Persists config to file and updates in-memory snapshot.
    public func updateConfig(_ config: CoreConfig) throws -> CoreConfig {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encoded = try encoder.encode(config)
        let payload = encoded + Data("\n".utf8)
        let url = URL(fileURLWithPath: configPath)
        try payload.write(to: url, options: .atomic)

        currentConfig = config
        agentsRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("agents", isDirectory: true)
        sessionStore.updateAgentsRootURL(agentsRootURL)
        return currentConfig
    }

    /// Loads bundled SQL schema text used by SQLite store.
    private static func loadSchemaSQL() -> String {
        let fileManager = FileManager.default
        let executablePath = CommandLine.arguments.first ?? ""
        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        // Resolve schema from source checkout or alongside released binaries.
        let candidatePaths = [
            cwd.appendingPathComponent("Sources/Core/Storage/schema.sql").path,
            executableDirectory.appendingPathComponent("Sources/Core/Storage/schema.sql").path,
            cwd.appendingPathComponent("SlopOverlord_Core.resources/schema.sql").path,
            cwd.appendingPathComponent("SlopOverlord_Core.bundle/schema.sql").path,
            executableDirectory.appendingPathComponent("SlopOverlord_Core.resources/schema.sql").path,
            executableDirectory.appendingPathComponent("SlopOverlord_Core.bundle/schema.sql").path
        ]

        for candidatePath in candidatePaths where fileManager.fileExists(atPath: candidatePath) {
            if let schema = try? String(contentsOfFile: candidatePath, encoding: .utf8), !schema.isEmpty {
                return schema
            }
        }

        // Last resort fallback to embedded schema for container/runtime safety.
        return embeddedSchemaSQL
    }

    /// Builds model provider plugin for AnyLanguageModel-based agent responses.
    private static func buildModelProvider(
        config: CoreConfig,
        resolvedModels: [String]
    ) -> AnyLanguageModelProviderPlugin? {
        let supportsOpenAI = resolvedModels.contains { $0.hasPrefix("openai:") }
        let supportsOllama = resolvedModels.contains { $0.hasPrefix("ollama:") }

        let primaryOpenAIConfig = config.models.first {
            resolvedIdentifier(for: $0).hasPrefix("openai:")
        }
        let primaryOllamaConfig = config.models.first {
            resolvedIdentifier(for: $0).hasPrefix("ollama:")
        }

        var openAISettings: AnyLanguageModelProviderPlugin.OpenAISettings?
        if supportsOpenAI {
            let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
            let configuredKey = primaryOpenAIConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedKey = configuredKey.isEmpty ? apiKey : configuredKey

            if !resolvedKey.isEmpty {
                if let baseURL = parseURL(primaryOpenAIConfig?.apiUrl) {
                    openAISettings = .init(apiKey: { resolvedKey }, baseURL: baseURL)
                } else {
                    openAISettings = .init(apiKey: { resolvedKey })
                }
            }
        }

        let ollamaSettings: AnyLanguageModelProviderPlugin.OllamaSettings? = {
            guard supportsOllama else {
                return nil
            }
            if let baseURL = parseURL(primaryOllamaConfig?.apiUrl) {
                return .init(baseURL: baseURL)
            }
            return .init()
        }()

        let availableModels = resolvedModels.filter { model in
            if model.hasPrefix("openai:") {
                return openAISettings != nil
            }
            if model.hasPrefix("ollama:") {
                return ollamaSettings != nil
            }
            return openAISettings != nil || ollamaSettings != nil
        }

        guard !availableModels.isEmpty else {
            return nil
        }

        return AnyLanguageModelProviderPlugin(
            id: "any-language-model",
            models: availableModels,
            openAI: openAISettings,
            ollama: ollamaSettings,
            systemInstructions: "You are SlopOverlord core channel assistant."
        )
    }

    private static func resolveModelIdentifiers(config: CoreConfig) -> [String] {
        var identifiers = config.models.map(resolvedIdentifier(for:))
        let hasOpenAI = identifiers.contains { $0.hasPrefix("openai:") }
        let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !hasOpenAI, !environmentKey.isEmpty {
            identifiers.append("openai:gpt-4.1-mini")
        }

        return identifiers
    }

    private static func resolvedIdentifier(for model: CoreConfig.ModelConfig) -> String {
        let modelValue = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelValue.hasPrefix("openai:") || modelValue.hasPrefix("ollama:") {
            return modelValue
        }

        let provider = inferredProvider(model: model)
        if let provider {
            return "\(provider):\(modelValue)"
        }

        return modelValue
    }

    private static func inferredProvider(model: CoreConfig.ModelConfig) -> String? {
        let title = model.title.lowercased()
        let apiURL = model.apiUrl.lowercased()

        if title.contains("openai") || apiURL.contains("openai") {
            return "openai"
        }

        if title.contains("ollama") || apiURL.contains("ollama") || apiURL.contains("11434") {
            return "ollama"
        }

        return nil
    }

    private static func parseURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private func ensureAgentsRootDirectory() throws {
        try fileManager.createDirectory(at: agentsRootURL, withIntermediateDirectories: true)
    }

    private func agentDirectoryURL(for id: String) -> URL {
        agentsRootURL.appendingPathComponent(id, isDirectory: true)
    }

    private func agentMetadataURL(for id: String) -> URL {
        agentDirectoryURL(for: id).appendingPathComponent("agent.json")
    }

    private func readAgentSummary(id: String) throws -> AgentSummary {
        let metadataURL = agentMetadataURL(for: id)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw AgentStorageError.notFound
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentSummary.self, from: data)
    }

    private func writeAgentSummary(_ summary: AgentSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(summary) + Data("\n".utf8)
        try payload.write(to: agentMetadataURL(for: summary.id), options: .atomic)
    }

    private struct AgentConfigFile: Codable {
        let id: String
        let displayName: String
        let role: String
        let createdAt: Date
        let selectedModel: String?
    }

    private func writeAgentScaffoldFiles(for summary: AgentSummary) throws {
        let agentDirectory = agentDirectoryURL(for: summary.id)

        let agentsMarkdown =
            """
            # Agent

            - ID: \(summary.id)
            - Display Name: \(summary.displayName)
            - Role: \(summary.role)
            """
        try writeTextFile(
            contents: agentsMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("Agents.md")
        )

        let userMarkdown =
            """
            # User

            Describe the expected user profile, tone, and communication preferences for this agent.
            """
        try writeTextFile(
            contents: userMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("User.md")
        )

        let soulMarkdown =
            """
            # Soul

            Define the core principles, values, and behavioral constraints of this agent.
            """
        try writeTextFile(
            contents: soulMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("Soul.md")
        )

        try writeTextFile(
            contents: summary.id + "\n",
            at: agentDirectory.appendingPathComponent("Identity.id")
        )
        try writeTextFile(
            contents: summary.id + "\n",
            at: agentDirectory.appendingPathComponent("Identity.md")
        )

        try writeAgentConfigFile(
            AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableAgentModels().first?.id
            )
        )

        try fileManager.createDirectory(
            at: agentDirectory.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func agentConfigURL(for id: String) -> URL {
        agentDirectoryURL(for: id).appendingPathComponent("config.json")
    }

    private func readAgentConfigFile(for summary: AgentSummary, availableModels: [ProviderModelOption]) throws -> AgentConfigFile {
        let configURL = agentConfigURL(for: summary.id)
        if !fileManager.fileExists(atPath: configURL.path) {
            let fallback = AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableModels.first?.id
            )
            try writeAgentConfigFile(fallback)
            return fallback
        }

        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded = try decoder.decode(AgentConfigFile.self, from: data)
        let selectedModel = decoded.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableModelIDs = Set(availableModels.map(\.id))
        if selectedModel?.isEmpty ?? true || !(selectedModel.map { availableModelIDs.contains($0) } ?? false) {
            decoded = AgentConfigFile(
                id: decoded.id,
                displayName: decoded.displayName,
                role: decoded.role,
                createdAt: decoded.createdAt,
                selectedModel: availableModels.first?.id
            )
            try writeAgentConfigFile(decoded)
        }
        return decoded
    }

    private func writeAgentConfigFile(_ configFile: AgentConfigFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let configPayload = try encoder.encode(configFile) + Data("\n".utf8)
        try configPayload.write(to: agentConfigURL(for: configFile.id), options: .atomic)
    }

    private func readAgentDocuments(agentID: String) throws -> AgentDocumentBundle {
        let agentDirectory = agentDirectoryURL(for: agentID)
        let userMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("User.md"), fallback: "# User\n")
        let agentsMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("Agents.md"), fallback: "# Agent\n")
        let soulMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("Soul.md"), fallback: "# Soul\n")

        let identityMarkdownPath = agentDirectory.appendingPathComponent("Identity.md")
        let identityLegacyPath = agentDirectory.appendingPathComponent("Identity.id")
        let identityMarkdown = try readIdentityMarkdown(
            markdownURL: identityMarkdownPath,
            legacyURL: identityLegacyPath,
            fallback: agentID
        )

        return AgentDocumentBundle(
            userMarkdown: userMarkdown,
            agentsMarkdown: agentsMarkdown,
            soulMarkdown: soulMarkdown,
            identityMarkdown: identityMarkdown
        )
    }

    private func availableAgentModels() -> [ProviderModelOption] {
        var seen: Set<String> = []
        var options: [ProviderModelOption] = []

        let candidates = Self.resolveModelIdentifiers(config: currentConfig) + currentConfig.models.map(\.model)
        for raw in candidates {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }

            if seen.insert(value).inserted {
                options.append(.init(id: value, title: value))
            }
        }

        if options.isEmpty {
            options.append(.init(id: "openai:gpt-4.1-mini", title: "openai:gpt-4.1-mini"))
        }

        return options
    }

    private func readTextFile(at url: URL, fallback: String) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            return fallback
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return normalizedDocumentText(text)
    }

    private func readIdentityMarkdown(markdownURL: URL, legacyURL: URL, fallback: String) throws -> String {
        if fileManager.fileExists(atPath: markdownURL.path) {
            return try readTextFile(at: markdownURL, fallback: fallback + "\n")
        }

        if fileManager.fileExists(atPath: legacyURL.path) {
            let legacy = try readTextFile(at: legacyURL, fallback: fallback + "\n")
            return normalizedDocumentText(legacy)
        }

        return fallback + "\n"
    }

    private func writeTextFile(contents: String, at url: URL) throws {
        guard let data = contents.data(using: .utf8) else {
            throw AgentStorageError.invalidPayload
        }
        try data.write(to: url, options: .atomic)
    }

    private func normalizedDocumentText(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") {
            return normalized
        }
        return normalized + "\n"
    }

    private func normalizedIdentityValue(from markdown: String, fallback: String) -> String {
        let candidates = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        if let first = candidates.first {
            return first
        }
        return fallback
    }

    private func normalizedAgentID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }

        guard trimmed.count <= 120 else {
            return nil
        }

        return trimmed
    }

    private func normalizedSessionID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }

        guard trimmed.count <= 160 else {
            return nil
        }

        return trimmed
    }

    private func shouldUseSearchStage(content: String, attachmentCount: Int) -> Bool {
        if attachmentCount > 0 {
            return true
        }

        let lower = content.lowercased()
        let keywords = ["search", "find", "google", "lookup", "research", "найди", "поиск", "исследуй"]
        return keywords.contains(where: lower.contains)
    }

    private func mapSessionStoreError(_ error: Error) -> AgentSessionError {
        guard let storeError = error as? AgentSessionFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidAgentID:
            return .invalidAgentID
        case .invalidSessionID:
            return .invalidSessionID
        case .agentNotFound:
            return .agentNotFound
        case .sessionNotFound:
            return .sessionNotFound
        case .invalidPayload:
            return .invalidPayload
        }
    }

    private struct OpenAIModelsResponse: Decodable {
        struct ModelItem: Decodable {
            let id: String
        }

        let data: [ModelItem]
    }

    private static let fallbackOpenAIModels: [ProviderModelOption] = [
        .init(id: "gpt-4.1", title: "gpt-4.1"),
        .init(id: "gpt-4.1-mini", title: "gpt-4.1-mini"),
        .init(id: "gpt-4o", title: "gpt-4o"),
        .init(id: "gpt-4o-mini", title: "gpt-4o-mini"),
        .init(id: "o4-mini", title: "o4-mini")
    ]

    private static func fetchOpenAIModels(apiKey: String, baseURL: URL) async throws -> [ProviderModelOption] {
        let endpoint = openAIModelsURL(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted()
            .map { ProviderModelOption(id: $0, title: $0) }
    }

    private static func openAIModelsURL(baseURL: URL) -> URL {
        if baseURL.path.isEmpty || baseURL.path == "/" {
            return baseURL.appendingPathComponent("models")
        }

        let normalizedPath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        if normalizedPath.hasSuffix("/models") {
            return baseURL
        }

        return baseURL.appendingPathComponent("models")
    }

    /// Subscribes to runtime event stream and persists events in background.
    private func startEventPersistence() async {
        eventTask = Task {
            let stream = await runtime.eventBus.subscribe()
            for await event in stream {
                await store.persist(event: event)
            }
        }
    }
}

private let embeddedSchemaSQL =
    """
    CREATE TABLE IF NOT EXISTS channels (
        id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        status TEXT NOT NULL,
        title TEXT NOT NULL,
        objective TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        message_type TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        task_id TEXT,
        branch_id TEXT,
        worker_id TEXT,
        payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_events_channel_created ON events(channel_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_events_task_created ON events(task_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS artifacts (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS memory_bulletins (
        id TEXT PRIMARY KEY,
        headline TEXT NOT NULL,
        digest TEXT NOT NULL,
        items_json TEXT NOT NULL,
        created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS token_usage (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        task_id TEXT,
        prompt_tokens INTEGER NOT NULL,
        completion_tokens INTEGER NOT NULL,
        total_tokens INTEGER NOT NULL,
        created_at TEXT NOT NULL
    );
    """

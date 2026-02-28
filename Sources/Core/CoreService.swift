import Foundation
import AgentRuntime
import Protocols

public actor CoreService {
    private static let sessionContextBootstrapMarker = "[agent_session_context_bootstrap_v1]"

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
    private let openAIProviderCatalog: OpenAIProviderCatalogService
    private let agentCatalogStore: AgentCatalogFileStore
    private let sessionStore: AgentSessionFileStore
    private let configPath: String
    private var agentsRootURL: URL
    private var currentConfig: CoreConfig
    private var eventTask: Task<Void, Never>?
    private var activeSessionRunChannels: Set<String> = []
    private var interruptedSessionRunChannels: Set<String> = []
    private var streamedAssistantByChannel: [String: String] = [:]
    private var streamedAssistantLastPersistedByChannel: [String: String] = [:]
    private var streamedAssistantLastPersistedAtByChannel: [String: Date] = [:]

    /// Creates core orchestration service with runtime and persistence backend.
    public init(config: CoreConfig, configPath: String = CoreConfig.defaultConfigPath) {
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        let modelProvider = CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: resolvedModels)
        self.runtime = RuntimeSystem(
            modelProvider: modelProvider,
            defaultModel: modelProvider?.models.first ?? resolvedModels.first
        )
        let schema = Self.loadSchemaSQL()
        self.store = SQLiteStore(path: config.sqlitePath, schemaSQL: schema)
        self.openAIProviderCatalog = OpenAIProviderCatalogService()
        self.configPath = configPath
        self.agentsRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("agents", isDirectory: true)
        self.agentCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
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
        do {
            return try agentCatalogStore.listAgents()
        } catch {
            throw mapAgentStorageError(error)
        }
    }

    /// Returns one persisted agent by id.
    public func getAgent(id: String) throws -> AgentSummary {
        do {
            return try agentCatalogStore.getAgent(id: id)
        } catch {
            throw mapAgentStorageError(error)
        }
    }

    /// Creates an agent and provisions `/workspace/agents/<agent_id>` directory.
    public func createAgent(_ request: AgentCreateRequest) throws -> AgentSummary {
        do {
            return try agentCatalogStore.createAgent(request, availableModels: availableAgentModels())
        } catch {
            throw mapAgentStorageError(error)
        }
    }

    /// Returns agent-specific config including selected model and editable markdown docs.
    public func getAgentConfig(agentID: String) throws -> AgentConfigDetail {
        let availableModels = availableAgentModels()
        do {
            return try agentCatalogStore.getAgentConfig(agentID: agentID, availableModels: availableModels)
        } catch {
            throw mapAgentConfigError(error)
        }
    }

    /// Updates agent-specific model and markdown docs.
    public func updateAgentConfig(agentID: String, request: AgentConfigUpdateRequest) throws -> AgentConfigDetail {
        let availableModels = availableAgentModels()
        do {
            return try agentCatalogStore.updateAgentConfig(
                agentID: agentID,
                request: request,
                availableModels: availableModels
            )
        } catch {
            throw mapAgentConfigError(error)
        }
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
    public func createAgentSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            let summary = try sessionStore.createSession(agentID: normalizedAgentID, request: request)
            do {
                try await ensureSessionContextLoaded(agentID: normalizedAgentID, sessionID: summary.id)
            } catch {
                try? sessionStore.deleteSession(agentID: normalizedAgentID, sessionID: summary.id)
                throw AgentSessionError.storageFailure
            }
            return summary
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

        do {
            try await ensureSessionContextLoaded(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            throw AgentSessionError.storageFailure
        }

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

        var initialEvents: [AgentSessionEvent] = [
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
            initialEvents.append(
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

        initialEvents.append(
            AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: normalizedSessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .responding,
                    label: "Responding",
                    details: "Generating response..."
                )
            )
        )

        var summary: AgentSessionSummary
        do {
            summary = try sessionStore.appendEvents(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                events: initialEvents
            )
        } catch {
            throw mapSessionStoreError(error)
        }

        let channelID = sessionChannelID(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        activeSessionRunChannels.insert(channelID)
        interruptedSessionRunChannels.remove(channelID)
        streamedAssistantByChannel[channelID] = ""
        streamedAssistantLastPersistedByChannel[channelID] = ""
        streamedAssistantLastPersistedAtByChannel[channelID] = .distantPast
        defer {
            cleanupSessionRunTracking(channelID: channelID)
        }

        let messageContent = content.isEmpty ? "User attached files." : content
        let routeDecision = await runtime.postMessage(
            channelId: channelID,
            request: ChannelMessageRequest(userId: request.userId, content: messageContent),
            onResponseChunk: { [weak self] partialText in
                guard let self else {
                    return false
                }
                return await self.handleSessionResponseChunk(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    channelID: channelID,
                    partialText: partialText
                )
            }
        )

        let snapshot = await runtime.channelState(channelId: channelID)
        let streamedAssistantText = streamedAssistantByChannel[channelID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let assistantTextFromSnapshot = snapshot?.messages.reversed().first(where: {
            $0.userId == "system" && !$0.content.contains(Self.sessionContextBootstrapMarker)
        })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let assistantText = !streamedAssistantText.isEmpty
            ? streamedAssistantText
            : (!assistantTextFromSnapshot.isEmpty ? assistantTextFromSnapshot : "Done.")
        let wasInterrupted = interruptedSessionRunChannels.contains(channelID)

        var finalEvents: [AgentSessionEvent] = []
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
                try await ensureSessionContextLoaded(agentID: normalizedAgentID, sessionID: childSummary.id)
            } catch {
                if let storeError = error as? AgentSessionFileStore.StoreError {
                    throw mapSessionStoreError(storeError)
                }
                throw AgentSessionError.storageFailure
            }

            finalEvents.append(
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

        if !assistantText.isEmpty {
            finalEvents.append(
                AgentSessionEvent(
                    agentId: normalizedAgentID,
                    sessionId: normalizedSessionID,
                    type: .message,
                    message: AgentSessionMessage(
                        role: .assistant,
                        segments: [
                            .init(kind: .text, text: assistantText)
                        ],
                        userId: "agent"
                    )
                )
            )
        }

        if wasInterrupted {
            finalEvents.append(
                AgentSessionEvent(
                    agentId: normalizedAgentID,
                    sessionId: normalizedSessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .interrupted,
                        label: "Interrupted",
                        details: "Response generation stopped."
                    )
                )
            )
        } else if isAssistantErrorText(assistantText) {
            finalEvents.append(
                AgentSessionEvent(
                    agentId: normalizedAgentID,
                    sessionId: normalizedSessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .interrupted,
                        label: "Error",
                        details: assistantText
                    )
                )
            )
        } else {
            finalEvents.append(
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
        }

        if !finalEvents.isEmpty {
            do {
                summary = try sessionStore.appendEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    events: finalEvents
                )
            } catch {
                throw mapSessionStoreError(error)
            }
        }

        return AgentSessionMessageResponse(
            summary: summary,
            appendedEvents: initialEvents + finalEvents,
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
            interruptedSessionRunChannels.insert(
                sessionChannelID(agentID: normalizedAgentID, sessionID: normalizedSessionID)
            )
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
        await openAIProviderCatalog.listModels(config: currentConfig, request: request)
    }

    /// Returns OpenAI provider key availability without fetching remote model catalog.
    public func openAIProviderStatus() -> OpenAIProviderStatusResponse {
        openAIProviderCatalog.status(config: currentConfig)
    }

    /// Persists config to file and updates in-memory snapshot.
    public func updateConfig(_ config: CoreConfig) async throws -> CoreConfig {
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
        agentCatalogStore.updateAgentsRootURL(agentsRootURL)
        sessionStore.updateAgentsRootURL(agentsRootURL)
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        let modelProvider = CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: resolvedModels)
        let defaultModel = modelProvider?.models.first ?? resolvedModels.first
        await runtime.updateModelProvider(modelProvider: modelProvider, defaultModel: defaultModel)
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

    private func availableAgentModels() -> [ProviderModelOption] {
        var seen: Set<String> = []
        var options: [ProviderModelOption] = []

        let candidates = CoreModelProviderFactory.resolveModelIdentifiers(config: currentConfig) + currentConfig.models.map(\.model)
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

    private func mapAgentStorageError(_ error: Error) -> AgentStorageError {
        guard let storeError = error as? AgentCatalogFileStore.StoreError else {
            return .invalidPayload
        }

        switch storeError {
        case .invalidID:
            return .invalidID
        case .invalidPayload, .invalidModel, .storageFailure:
            return .invalidPayload
        case .alreadyExists:
            return .alreadyExists
        case .notFound:
            return .notFound
        }
    }

    private func mapAgentConfigError(_ error: Error) -> AgentConfigError {
        guard let storeError = error as? AgentCatalogFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidID:
            return .invalidAgentID
        case .invalidPayload:
            return .invalidPayload
        case .invalidModel:
            return .invalidModel
        case .notFound:
            return .agentNotFound
        case .alreadyExists, .storageFailure:
            return .storageFailure
        }
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

    private func cleanupSessionRunTracking(channelID: String) {
        activeSessionRunChannels.remove(channelID)
        interruptedSessionRunChannels.remove(channelID)
        streamedAssistantByChannel.removeValue(forKey: channelID)
        streamedAssistantLastPersistedByChannel.removeValue(forKey: channelID)
        streamedAssistantLastPersistedAtByChannel.removeValue(forKey: channelID)
    }

    private func handleSessionResponseChunk(
        agentID: String,
        sessionID: String,
        channelID: String,
        partialText: String
    ) async -> Bool {
        let normalized = partialText.replacingOccurrences(of: "\r\n", with: "\n")
        streamedAssistantByChannel[channelID] = normalized

        if interruptedSessionRunChannels.contains(channelID) {
            return false
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let lastPersistedText = streamedAssistantLastPersistedByChannel[channelID] ?? ""
        let lastPersistedAt = streamedAssistantLastPersistedAtByChannel[channelID] ?? .distantPast
        let now = Date()
        let progressed = max(0, normalized.count - lastPersistedText.count)
        let shouldPersist = lastPersistedText.isEmpty ||
            progressed >= 24 ||
            now.timeIntervalSince(lastPersistedAt) >= 0.35

        if shouldPersist {
            do {
                _ = try sessionStore.appendEvents(
                    agentID: agentID,
                    sessionID: sessionID,
                    events: [
                        AgentSessionEvent(
                            agentId: agentID,
                            sessionId: sessionID,
                            type: .runStatus,
                            runStatus: AgentRunStatusEvent(
                                stage: .responding,
                                label: "Responding",
                                details: "Generating response...",
                                expandedText: normalized
                            )
                        )
                    ]
                )
                streamedAssistantLastPersistedByChannel[channelID] = normalized
                streamedAssistantLastPersistedAtByChannel[channelID] = now
            } catch {
                return false
            }
        }

        return !interruptedSessionRunChannels.contains(channelID)
    }

    private func shouldUseSearchStage(content: String, attachmentCount: Int) -> Bool {
        if attachmentCount > 0 {
            return true
        }

        let lower = content.lowercased()
        let keywords = ["search", "find", "google", "lookup", "research", "найди", "поиск", "исследуй"]
        return keywords.contains(where: lower.contains)
    }

    private func isAssistantErrorText(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            return false
        }

        return value.hasPrefix("model provider error:") ||
            value.hasPrefix("error:") ||
            value.contains(" failed") ||
            value.contains("exception")
    }

    private func sessionChannelID(agentID: String, sessionID: String) -> String {
        "agent:\(agentID):session:\(sessionID)"
    }

    private func ensureSessionContextLoaded(agentID: String, sessionID: String) async throws {
        let channelID = sessionChannelID(agentID: agentID, sessionID: sessionID)
        if let existingSnapshot = await runtime.channelState(channelId: channelID),
           existingSnapshot.messages.contains(where: {
               $0.userId == "system" && $0.content.contains(Self.sessionContextBootstrapMarker)
           }) {
            return
        }

        let documents = try agentCatalogStore.readAgentDocuments(agentID: agentID)
        let bootstrapMessage = sessionBootstrapContextMessage(
            agentID: agentID,
            sessionID: sessionID,
            documents: documents
        )
        await runtime.appendSystemMessage(channelId: channelID, content: bootstrapMessage)
    }

    private func sessionBootstrapContextMessage(
        agentID: String,
        sessionID: String,
        documents: AgentDocumentBundle
    ) -> String {
        """
        \(Self.sessionContextBootstrapMarker)
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
        """
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

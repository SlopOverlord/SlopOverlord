import Foundation
import AgentRuntime
import Protocols

public enum AgentSessionStreamUpdateKind: String, Codable, Sendable {
    case sessionReady = "session_ready"
    case sessionEvent = "session_event"
    case heartbeat
    case sessionClosed = "session_closed"
    case sessionError = "session_error"
}

public struct AgentSessionStreamUpdate: Codable, Sendable {
    public var kind: AgentSessionStreamUpdateKind
    public var cursor: Int
    public var summary: AgentSessionSummary?
    public var event: AgentSessionEvent?
    public var message: String?
    public var createdAt: Date

    public init(
        kind: AgentSessionStreamUpdateKind,
        cursor: Int,
        summary: AgentSessionSummary? = nil,
        event: AgentSessionEvent? = nil,
        message: String? = nil,
        createdAt: Date = Date()
    ) {
        self.kind = kind
        self.cursor = cursor
        self.summary = summary
        self.event = event
        self.message = message
        self.createdAt = createdAt
    }
}

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

    public enum ProjectError: Error {
        case invalidProjectID
        case invalidChannelID
        case invalidTaskID
        case invalidPayload
        case notFound
        case conflict
    }

    private let runtime: RuntimeSystem
    private let store: any PersistenceStore
    private let openAIProviderCatalog: OpenAIProviderCatalogService
    private let agentCatalogStore: AgentCatalogFileStore
    private let sessionStore: AgentSessionFileStore
    private let sessionOrchestrator: AgentSessionOrchestrator
    private let configPath: String
    private var agentsRootURL: URL
    private var currentConfig: CoreConfig
    private var eventTask: Task<Void, Never>?

    /// Creates core orchestration service with runtime and persistence backend.
    public init(
        config: CoreConfig,
        configPath: String = CoreConfig.defaultConfigPath,
        persistenceBuilder: any CorePersistenceBuilding = DefaultCorePersistenceBuilder()
    ) {
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        let modelProvider = CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: resolvedModels)
        self.runtime = RuntimeSystem(
            modelProvider: modelProvider,
            defaultModel: modelProvider?.models.first ?? resolvedModels.first
        )
        self.store = persistenceBuilder.makeStore(config: config)
        self.openAIProviderCatalog = OpenAIProviderCatalogService()
        self.configPath = configPath
        self.agentsRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("agents", isDirectory: true)
        self.agentCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        self.sessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        let orchestratorCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        let orchestratorSessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        self.sessionOrchestrator = AgentSessionOrchestrator(
            runtime: self.runtime,
            sessionStore: orchestratorSessionStore,
            agentCatalogStore: orchestratorCatalogStore
        )
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

    /// Lists dashboard projects with channels and task board data.
    public func listProjects() async -> [ProjectRecord] {
        await store.listProjects()
    }

    /// Returns one dashboard project by identifier.
    public func getProject(id: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(id) else {
            throw ProjectError.invalidProjectID
        }
        guard let project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }
        return project
    }

    /// Creates a new dashboard project.
    public func createProject(_ request: ProjectCreateRequest) async throws -> ProjectRecord {
        let now = Date()
        let normalizedName = try normalizeProjectName(request.name)
        let normalizedDescription = normalizeProjectDescription(request.description)
        let channels = try normalizeInitialProjectChannels(request.channels, fallbackName: normalizedName)
        let project = ProjectRecord(
            id: UUID().uuidString,
            name: normalizedName,
            description: normalizedDescription,
            channels: channels,
            tasks: [],
            createdAt: now,
            updatedAt: now
        )
        await store.saveProject(project)
        return project
    }

    /// Updates dashboard project metadata.
    public func updateProject(projectID: String, request: ProjectUpdateRequest) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        if let nextName = request.name {
            project.name = try normalizeProjectName(nextName)
        }
        if let nextDescription = request.description {
            project.description = normalizeProjectDescription(nextDescription)
        }

        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    /// Deletes one dashboard project and nested board entities.
    public func deleteProject(projectID: String) async throws {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard await store.project(id: normalizedID) != nil else {
            throw ProjectError.notFound
        }
        await store.deleteProject(id: normalizedID)
    }

    /// Adds a channel to a dashboard project.
    public func createProjectChannel(
        projectID: String,
        request: ProjectChannelCreateRequest
    ) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let title = normalizeChannelTitle(request.title)
        let channelID = try normalizedChannelID(request.channelId)
        if project.channels.contains(where: { $0.channelId == channelID }) {
            throw ProjectError.conflict
        }

        project.channels.append(
            ProjectChannel(
                id: UUID().uuidString,
                title: title,
                channelId: channelID,
                createdAt: Date()
            )
        )
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    /// Removes a channel from a dashboard project.
    public func deleteProjectChannel(projectID: String, channelID: String) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedChannel = normalizedEntityID(channelID) else {
            throw ProjectError.invalidChannelID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        guard project.channels.contains(where: { $0.id == normalizedChannel }) else {
            throw ProjectError.notFound
        }
        if project.channels.count <= 1 {
            throw ProjectError.invalidPayload
        }

        project.channels.removeAll(where: { $0.id == normalizedChannel })
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    /// Creates a new task inside project board.
    public func createProjectTask(projectID: String, request: ProjectTaskCreateRequest) async throws -> ProjectRecord {
        guard let normalizedID = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard var project = await store.project(id: normalizedID) else {
            throw ProjectError.notFound
        }

        let now = Date()
        project.tasks.append(
            ProjectTask(
                id: UUID().uuidString,
                title: try normalizeTaskTitle(request.title),
                description: normalizeTaskDescription(request.description),
                priority: try normalizeTaskPriority(request.priority),
                status: try normalizeTaskStatus(request.status),
                createdAt: now,
                updatedAt: now
            )
        )
        project.updatedAt = now
        await store.saveProject(project)
        return project
    }

    /// Updates one task inside project board.
    public func updateProjectTask(
        projectID: String,
        taskID: String,
        request: ProjectTaskUpdateRequest
    ) async throws -> ProjectRecord {
        guard let normalizedProject = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedTask = normalizedEntityID(taskID) else {
            throw ProjectError.invalidTaskID
        }
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard let taskIndex = project.tasks.firstIndex(where: { $0.id == normalizedTask }) else {
            throw ProjectError.notFound
        }

        var task = project.tasks[taskIndex]
        if let title = request.title {
            task.title = try normalizeTaskTitle(title)
        }
        if let description = request.description {
            task.description = normalizeTaskDescription(description)
        }
        if let priority = request.priority {
            task.priority = try normalizeTaskPriority(priority)
        }
        if let status = request.status {
            task.status = try normalizeTaskStatus(status)
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    /// Removes one task from project board.
    public func deleteProjectTask(projectID: String, taskID: String) async throws -> ProjectRecord {
        guard let normalizedProject = normalizedProjectID(projectID) else {
            throw ProjectError.invalidProjectID
        }
        guard let normalizedTask = normalizedEntityID(taskID) else {
            throw ProjectError.invalidTaskID
        }
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard project.tasks.contains(where: { $0.id == normalizedTask }) else {
            throw ProjectError.notFound
        }

        project.tasks.removeAll(where: { $0.id == normalizedTask })
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
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
            return try await sessionOrchestrator.createSession(agentID: normalizedAgentID, request: request)
        } catch {
            throw mapSessionOrchestratorError(error)
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

    /// Streams incremental session updates over a long-lived connection.
    public func streamAgentSessionEvents(agentID: String, sessionID: String) throws -> AsyncStream<AgentSessionStreamUpdate> {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)
        _ = try getAgentSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)

        return AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let task = Task { [normalizedAgentID, normalizedSessionID] in
                var deliveredCount = 0
                var lastHeartbeatAt = Date.distantPast

                while !Task.isCancelled {
                    do {
                        let detail = try self.getAgentSession(
                            agentID: normalizedAgentID,
                            sessionID: normalizedSessionID
                        )

                        if deliveredCount == 0 {
                            deliveredCount = detail.events.count
                            continuation.yield(
                                AgentSessionStreamUpdate(
                                    kind: .sessionReady,
                                    cursor: deliveredCount,
                                    summary: detail.summary
                                )
                            )
                            lastHeartbeatAt = Date()
                        }

                        if detail.events.count > deliveredCount {
                            for index in deliveredCount..<detail.events.count {
                                continuation.yield(
                                    AgentSessionStreamUpdate(
                                        kind: .sessionEvent,
                                        cursor: index + 1,
                                        summary: detail.summary,
                                        event: detail.events[index]
                                    )
                                )
                            }
                            deliveredCount = detail.events.count
                            lastHeartbeatAt = Date()
                        } else {
                            let now = Date()
                            if now.timeIntervalSince(lastHeartbeatAt) >= 12 {
                                continuation.yield(
                                    AgentSessionStreamUpdate(
                                        kind: .heartbeat,
                                        cursor: deliveredCount,
                                        summary: detail.summary,
                                        createdAt: now
                                    )
                                )
                                lastHeartbeatAt = now
                            }
                        }
                    } catch let error as AgentSessionError {
                        switch error {
                        case .sessionNotFound:
                            continuation.yield(
                                AgentSessionStreamUpdate(
                                    kind: .sessionClosed,
                                    cursor: deliveredCount,
                                    message: "Session was deleted."
                                )
                            )
                        default:
                            continuation.yield(
                                AgentSessionStreamUpdate(
                                    kind: .sessionError,
                                    cursor: deliveredCount,
                                    message: "Failed to stream session updates."
                                )
                            )
                        }
                        continuation.finish()
                        return
                    } catch {
                        continuation.yield(
                            AgentSessionStreamUpdate(
                                kind: .sessionError,
                                cursor: deliveredCount,
                                message: "Failed to stream session updates."
                            )
                        )
                        continuation.finish()
                        return
                    }

                    try? await Task.sleep(nanoseconds: 250_000_000)
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
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
            return try await sessionOrchestrator.postMessage(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request
            )
        } catch {
            throw mapSessionOrchestratorError(error)
        }
    }

    /// Appends control signal (pause/resume/interrupt) and corresponding status.
    public func controlAgentSession(
        agentID: String,
        sessionID: String,
        request: AgentSessionControlRequest
    ) async throws -> AgentSessionMessageResponse {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            return try await sessionOrchestrator.controlSession(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request
            )
        } catch {
            throw mapSessionOrchestratorError(error)
        }
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
        await sessionOrchestrator.updateAgentsRootURL(agentsRootURL)
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        let modelProvider = CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: resolvedModels)
        let defaultModel = modelProvider?.models.first ?? resolvedModels.first
        await runtime.updateModelProvider(modelProvider: modelProvider, defaultModel: defaultModel)
        return currentConfig
    }

    private func normalizeProjectName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else {
            throw ProjectError.invalidPayload
        }
        return trimmed
    }

    private func normalizeProjectDescription(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(2_000))
    }

    private func normalizeInitialProjectChannels(
        _ channels: [ProjectChannelCreateRequest],
        fallbackName: String
    ) throws -> [ProjectChannel] {
        if channels.isEmpty {
            let slug = slugify(fallbackName)
            return [
                ProjectChannel(
                    id: UUID().uuidString,
                    title: "Main channel",
                    channelId: slug.isEmpty ? "project-main" : "\(slug)-main",
                    createdAt: Date()
                )
            ]
        }

        var normalized: [ProjectChannel] = []
        var uniqueChannelIDs: Set<String> = []
        for channel in channels {
            let title = normalizeChannelTitle(channel.title)
            let channelID = try normalizedChannelID(channel.channelId)
            guard uniqueChannelIDs.insert(channelID).inserted else {
                throw ProjectError.conflict
            }
            normalized.append(
                ProjectChannel(
                    id: UUID().uuidString,
                    title: title,
                    channelId: channelID,
                    createdAt: Date()
                )
            )
        }
        return normalized
    }

    private func normalizeTaskTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.invalidPayload
        }
        return String(trimmed.prefix(240))
    }

    private func normalizeTaskDescription(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(8_000))
    }

    private func normalizeTaskPriority(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(["low", "medium", "high"])
        guard allowed.contains(value) else {
            throw ProjectError.invalidPayload
        }
        return value
    }

    private func normalizeTaskStatus(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(["backlog", "ready", "in_progress", "done"])
        guard allowed.contains(value) else {
            throw ProjectError.invalidPayload
        }
        return value
    }

    private func normalizeChannelTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Channel"
        }
        return String(trimmed.prefix(160))
    }

    private func normalizedProjectID(_ raw: String) -> String? {
        normalizedEntityID(raw)
    }

    private func normalizedEntityID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil, trimmed.count <= 180 else {
            return nil
        }

        return trimmed
    }

    private func normalizedChannelID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
        guard !trimmed.isEmpty, trimmed.count <= 200, trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw ProjectError.invalidChannelID
        }
        return trimmed
    }

    private func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let separated = lower.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return separated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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

    private func mapSessionOrchestratorError(_ error: Error) -> AgentSessionError {
        guard let orchestratorError = error as? AgentSessionOrchestrator.OrchestratorError else {
            return .storageFailure
        }

        switch orchestratorError {
        case .invalidAgentID:
            return .invalidAgentID
        case .invalidSessionID:
            return .invalidSessionID
        case .invalidPayload:
            return .invalidPayload
        case .agentNotFound:
            return .agentNotFound
        case .sessionNotFound:
            return .sessionNotFound
        case .storageFailure:
            return .storageFailure
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

import Foundation
import AgentRuntime
import ChannelPluginTelegram
import Logging
import Protocols
import PluginSDK

public enum AgentSessionStreamUpdateKind: String, Codable, Sendable {
    case sessionReady = "session_ready"
    case sessionEvent = "session_event"
    case sessionDelta = "session_delta"
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
    private static let heartbeatSuccessToken = "SLOPPY_ACTION_OK"
    private static let agentMemoryGraphSeedLimit = 50
    private static let agentMemoryGraphNeighborLimit = 150

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

    public enum AgentToolsError: Error {
        case invalidAgentID
        case invalidPayload
        case agentNotFound
        case storageFailure
    }

    public enum ToolInvocationError: Error {
        case invalidAgentID
        case invalidSessionID
        case invalidPayload
        case agentNotFound
        case sessionNotFound
        case forbidden(ToolErrorPayload)
        case storageFailure
    }

    public enum SystemLogsError: Error {
        case storageFailure
    }

    public enum ActorBoardError: Error {
        case invalidPayload
        case actorNotFound
        case linkNotFound
        case teamNotFound
        case protectedActor
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

    public enum ChannelPluginError: Error {
        case invalidID
        case invalidPayload
        case notFound
        case conflict
    }

    public enum AgentSkillsError: Error {
        case invalidAgentID
        case invalidPayload
        case agentNotFound
        case skillNotFound
        case skillAlreadyExists
        case storageFailure
        case networkFailure
        case downloadFailure
    }

    public enum AgentCronTaskError: Error {
        case invalidAgentID
        case invalidPayload
        case notFound
        case storageFailure
    }

    private let runtime: RuntimeSystem
    private let memoryStore: any MemoryStore
    private let hybridMemoryStore: HybridMemoryStore?
    private let store: any PersistenceStore
    private let openAIProviderCatalog: OpenAIProviderCatalogService
    private let agentCatalogStore: AgentCatalogFileStore
    private let sessionStore: AgentSessionFileStore
    private let actorBoardStore: ActorBoardFileStore
    private let sessionOrchestrator: AgentSessionOrchestrator
    private let toolsAuthorization: ToolAuthorizationService
    private let toolExecution: ToolExecutionService
    private let systemLogStore: SystemLogFileStore
    private let channelDelivery: ChannelDeliveryService
    private let channelSessionStore: ChannelSessionFileStore
    private let agentSkillsStore: AgentSkillsFileStore
    private let skillsRegistryService: SkillsRegistryService
    private let skillsGitHubClient: SkillsGitHubClient
    private let swarmPlanner: SwarmPlanner
    private let logger: Logger
    private let configPath: String
    private var workspaceRootURL: URL
    private var agentsRootURL: URL
    private var currentConfig: CoreConfig
    private var eventTask: Task<Void, Never>?
    private var activeGatewayPlugins: [any GatewayPlugin] = []
    private var visorScheduler: VisorScheduler?
    private var cronRunner: CronRunner?
    private var heartbeatRunner: HeartbeatRunner?
    private var memoryOutboxIndexer: MemoryOutboxIndexer?
    private let recoveryManager: RecoveryManager
    private var liveSessionStreamContinuations: [String: [UUID: AsyncStream<AgentSessionStreamUpdate>.Continuation]] = [:]
    private var liveSessionStreamCursor: [String: Int] = [:]

    /// Creates core orchestration service with runtime and persistence backend.
    public init(
        config: CoreConfig,
        configPath: String = CoreConfig.defaultConfigPath,
        persistenceBuilder: any CorePersistenceBuilding = DefaultCorePersistenceBuilder()
    ) {
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        let modelProvider = CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: resolvedModels)
        let runtimeMemoryStore: any MemoryStore
        let hybridMemoryStore: HybridMemoryStore?
        if persistenceBuilder is InMemoryCorePersistenceBuilder {
            hybridMemoryStore = nil
            runtimeMemoryStore = InMemoryMemoryStore()
        } else {
            let store = HybridMemoryStore(config: config)
            hybridMemoryStore = store
            runtimeMemoryStore = store
        }
        let runtime = RuntimeSystem(
            modelProvider: modelProvider,
            defaultModel: modelProvider?.models.first ?? resolvedModels.first,
            memoryStore: runtimeMemoryStore
        )
        self.runtime = runtime
        self.memoryStore = runtimeMemoryStore
        self.hybridMemoryStore = hybridMemoryStore
        self.store = persistenceBuilder.makeStore(config: config)
        self.openAIProviderCatalog = OpenAIProviderCatalogService()
        self.configPath = configPath
        self.workspaceRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
        self.agentsRootURL = self.workspaceRootURL
            .appendingPathComponent("agents", isDirectory: true)
        self.agentCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        self.sessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        self.systemLogStore = SystemLogFileStore(workspaceRootURL: self.workspaceRootURL)
        self.channelDelivery = ChannelDeliveryService(store: self.store)
        self.actorBoardStore = ActorBoardFileStore(workspaceRootURL: self.workspaceRootURL)
        self.channelSessionStore = ChannelSessionFileStore(workspaceRootURL: self.workspaceRootURL)
        self.agentSkillsStore = AgentSkillsFileStore(agentsRootURL: self.agentsRootURL)
        self.skillsRegistryService = SkillsRegistryService()
        self.skillsGitHubClient = SkillsGitHubClient()
        self.swarmPlanner = SwarmPlanner { prompt, maxTokens in
            await runtime.complete(prompt: prompt, maxTokens: maxTokens)
        }
        let orchestratorCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        let orchestratorSessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        let orchestratorSkillsStore = AgentSkillsFileStore(agentsRootURL: self.agentsRootURL)
        let initialAvailableAgentModels = Self.availableAgentModels(config: config)
        self.sessionOrchestrator = AgentSessionOrchestrator(
            runtime: self.runtime,
            sessionStore: orchestratorSessionStore,
            agentCatalogStore: orchestratorCatalogStore,
            agentSkillsStore: orchestratorSkillsStore,
            availableModels: initialAvailableAgentModels
        )
        let toolsStore = AgentToolsFileStore(agentsRootURL: self.agentsRootURL)
        self.toolsAuthorization = ToolAuthorizationService(store: toolsStore)
        let processRegistry = SessionProcessRegistry()
        self.toolExecution = ToolExecutionService(
            workspaceRootURL: self.workspaceRootURL,
            runtime: self.runtime,
            memoryStore: self.memoryStore,
            sessionStore: self.sessionStore,
            agentCatalogStore: self.agentCatalogStore,
            processRegistry: processRegistry,
            channelSessionStore: self.channelSessionStore,
            store: self.store
        )
        self.logger = Logger(label: "sloppy.core.visor")
        if let hybridMemoryStore {
            self.memoryOutboxIndexer = MemoryOutboxIndexer(
                store: hybridMemoryStore,
                logger: Logger(label: "sloppy.memory.outbox")
            )
        } else {
            self.memoryOutboxIndexer = nil
        }
        self.recoveryManager = RecoveryManager(store: self.store, runtime: self.runtime, logger: self.logger)
        self.currentConfig = config
        Task { [weak self] in
            guard let self else {
                return
            }
            await self.runtime.updateWorkerExecutor(
                ToolExecutionWorkerExecutorAdapter(toolExecutionService: self.toolExecution)
            )
            await self.sessionOrchestrator.updateToolInvoker { [weak self] agentID, sessionID, request in
                guard let self else {
                    return ToolInvocationResult(
                        tool: request.tool,
                        ok: false,
                        error: ToolErrorPayload(
                            code: "tool_invoker_unavailable",
                            message: "Tool invoker is unavailable.",
                            retryable: true
                        )
                    )
                }
                return await self.invokeToolFromRuntime(agentID: agentID, sessionID: sessionID, request: request)
            }
            await self.sessionOrchestrator.updateResponseChunkObserver { [weak self] agentID, sessionID, chunk in
                guard let self else {
                    return
                }
                await self.publishLiveSessionDelta(agentID: agentID, sessionID: sessionID, chunk: chunk)
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    // MARK: - Gateway Plugin Lifecycle

    /// Creates and starts in-process gateway plugins declared in config.
    /// Must be called after `CoreService.init` from an async context (e.g. CoreMain).
    public func bootstrapChannelPlugins() async {
        if let telegramConfig = currentConfig.channels.telegram {
            let plugin = TelegramGatewayPlugin(
                botToken: telegramConfig.botToken,
                channelChatMap: telegramConfig.channelChatMap,
                allowedUserIds: telegramConfig.allowedUserIds,
                allowedChatIds: telegramConfig.allowedChatIds,
                logger: Logger(label: "sloppy.plugin.telegram")
            )
            await channelDelivery.registerPlugin(plugin)
            activeGatewayPlugins.append(plugin)

            await seedTelegramPluginRecord(plugin: plugin, config: telegramConfig)

            do {
                try await plugin.start(inboundReceiver: self)
                logger.info("Telegram gateway plugin started.")
            } catch {
                logger.error("Failed to start Telegram gateway plugin: \(error)")
            }
        }

        let pluginsDir = workspaceRootURL.appendingPathComponent("plugins", isDirectory: true)
        let loader = PluginLoader(logger: logger)
        let externalPlugins = await loader.loadGatewayPlugins(
            from: pluginsDir,
            inboundReceiver: self
        )
        for plugin in externalPlugins {
            await channelDelivery.registerPlugin(plugin)
            activeGatewayPlugins.append(plugin)
            do {
                try await plugin.start(inboundReceiver: self)
                logger.info("External gateway plugin \(plugin.id) started.")
            } catch {
                logger.error("Failed to start external gateway plugin \(plugin.id): \(error)")
            }
        }

        // Initialize and start periodic visor scheduler
        if visorScheduler == nil {
            visorScheduler = VisorScheduler(
                config: VisorSchedulerConfig.default,
                logger: logger
            ) { [weak self] in
                guard let self else { return }
                _ = await self.triggerVisorBulletin()
            }
        }
        await visorScheduler?.start()
        
        if cronRunner == nil {
            cronRunner = CronRunner(store: self.store, runtime: self.runtime, logger: self.logger)
        }
        await cronRunner?.start()

        if heartbeatRunner == nil {
            heartbeatRunner = HeartbeatRunner(
                logger: Logger(label: "sloppy.core.heartbeat")
            ) { [weak self] in
                guard let self else {
                    return []
                }
                return await self.listHeartbeatSchedules()
            } executor: { [weak self] agentID in
                guard let self else {
                    return
                }
                await self.runAgentHeartbeat(agentID: agentID)
            }
        }
        await heartbeatRunner?.start()
    }

    /// Stops all active in-process gateway plugins and visor scheduler. Called on shutdown.
    public func shutdownChannelPlugins() async {
        for plugin in activeGatewayPlugins {
            await plugin.stop()
        }
        activeGatewayPlugins.removeAll()

        await visorScheduler?.stop()
        await memoryOutboxIndexer?.stop()
        await cronRunner?.stop()
        await heartbeatRunner?.stop()
    }

    private func seedTelegramPluginRecord(
        plugin: TelegramGatewayPlugin,
        config: CoreConfig.ChannelConfig.Telegram
    ) async {
        let channelIds = Array(config.channelChatMap.keys)
        let pluginId = "telegram"
        let existing = await store.channelPlugin(id: pluginId)
        let now = Date()
        let record = ChannelPluginRecord(
            id: pluginId,
            type: "telegram",
            baseUrl: "",
            channelIds: channelIds,
            config: [:],
            enabled: true,
            deliveryMode: ChannelPluginRecord.DeliveryMode.inProcess,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        await store.saveChannelPlugin(record)
    }

    /// Accepts a user channel message and returns routing decision.
    public func postChannelMessage(channelId: String, request: ChannelMessageRequest) async -> ChannelRouteDecision {
        await waitForStartup()
        if let approvalReference = TaskApprovalCommandParser.parse(request.content) {
            return await handleTaskApprovalCommand(channelId: channelId, reference: approvalReference)
        }

        let enrichedContent = await enrichMessageWithTaskReferences(request.content)
        let nextRequest = ChannelMessageRequest(
            userId: request.userId,
            content: enrichedContent,
            topicId: request.topicId
        )
        return await runtime.postMessage(channelId: channelId, request: nextRequest)
    }

    /// Routes interactive message into a running worker.
    public func postChannelRoute(channelId: String, workerId: String, request: ChannelRouteRequest) async -> Bool {
        await waitForStartup()
        return await runtime.routeMessage(channelId: channelId, workerId: workerId, message: request.message)
    }

    /// Delivers an outbound message to the channel plugin responsible for this channelId.
    @discardableResult
    public func deliverToChannelPlugin(channelId: String, userId: String = "system", content: String) async -> Bool {
        await channelDelivery.deliver(channelId: channelId, userId: userId, content: content)
    }

    /// Returns current state snapshot for a channel.
    public func getChannelState(channelId: String) async -> ChannelSnapshot? {
        await waitForStartup()
        return await runtime.channelState(channelId: channelId)
    }

    /// Returns known visor bulletins, preferring in-memory runtime state.
    public func getBulletins() async -> [MemoryBulletin] {
        await waitForStartup()
        let runtimeBulletins = await runtime.bulletins()
        if runtimeBulletins.isEmpty {
            return await store.listBulletins()
        }
        return runtimeBulletins
    }

    /// Creates worker instance from API request.
    public func postWorker(request: WorkerCreateRequest) async -> String {
        await waitForStartup()
        return await runtime.createWorker(spec: request.spec)
    }

    /// Reads artifact content from runtime or persistent storage.
    public func getArtifactContent(id: String) async -> ArtifactContentResponse? {
        await waitForStartup()
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
        await waitForStartup()
        let taskSummary = await buildProjectTaskSummary()
        let bulletin = await runtime.generateVisorBulletin(taskSummary: taskSummary)
        await store.persistBulletin(bulletin)
        return bulletin
    }

    private func buildProjectTaskSummary() async -> String? {
        let projects = await store.listProjects()
        let activeStatuses = Set(["pending_approval", "backlog", "ready", "in_progress"])
        var lines: [String] = []
        for project in projects {
            let active = project.tasks.filter { activeStatuses.contains($0.status) }
            guard !active.isEmpty else { continue }
            let taskEntries = active.prefix(20).map { task in
                let actor = task.claimedActorId ?? task.actorId ?? ""
                let actorSuffix = actor.isEmpty ? "" : " @\(actor)"
                return "[\(task.id)] \(task.title) (\(task.status))\(actorSuffix)"
            }
            lines.append("Project \(project.name): \(taskEntries.joined(separator: ", "))")
        }
        return lines.isEmpty ? nil : "Active tasks: " + lines.joined(separator: "; ")
    }

    private func enrichMessageWithTaskReferences(_ content: String) async -> String {
        let references = extractTaskReferences(from: content)
        guard !references.isEmpty else {
            return content
        }

        var lines: [String] = [content, "", "[task_reference_context_v1]"]
        for reference in references {
            if let record = try? await getProjectTask(taskReference: reference) {
                let description = record.task.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let compactDescription = description.isEmpty ? "(no description)" : String(description.prefix(320))
                lines.append(
                    "#\(reference) -> project=\(record.projectId), title=\(record.task.title), status=\(record.task.status), priority=\(record.task.priority)"
                )
                lines.append("details: \(compactDescription)")
            } else {
                lines.append("#\(reference) -> task_not_found")
            }
        }
        lines.append("Use this task context when answering the user.")
        return lines.joined(separator: "\n")
    }

    /// Exposes worker snapshots for observability endpoints.
    public func workerSnapshots() async -> [WorkerSnapshot] {
        await waitForStartup()
        return await runtime.workerSnapshots()
    }

    /// Lists dashboard projects with channels and task board data.
    public func listProjects() async -> [ProjectRecord] {
        await store.listProjects()
    }

    /// Lists token usage records with optional filters and aggregates.
    public func listTokenUsage(
        channelId: String? = nil,
        taskId: String? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) async -> TokenUsageResponse {
        let records = await store.listTokenUsage(channelId: channelId, taskId: taskId, from: from, to: to)
        let totalPrompt = records.reduce(0) { $0 + $1.promptTokens }
        let totalCompletion = records.reduce(0) { $0 + $1.completionTokens }
        let total = records.reduce(0) { $0 + $1.totalTokens }
        return TokenUsageResponse(
            items: records,
            totalPromptTokens: totalPrompt,
            totalCompletionTokens: totalCompletion,
            totalTokens: total
        )
    }

    /// Lists runtime event timeline for a channel (newest first) with cursor pagination.
    public func listChannelEvents(
        channelId: String,
        limit: Int = 50,
        cursor: String? = nil,
        before: Date? = nil,
        after: Date? = nil
    ) async -> ChannelEventsResponse {
        let boundedLimit = min(max(limit, 1), 200)
        let parsedCursor = Self.decodeEventCursor(cursor)
        let events = await store.listChannelEvents(
            channelId: channelId,
            limit: boundedLimit,
            cursor: parsedCursor,
            before: before,
            after: after
        )
        let nextCursor = events.last.map(Self.encodeEventCursor)
        return ChannelEventsResponse(channelId: channelId, items: events, nextCursor: nextCursor)
    }

    // MARK: - Cron Tasks

    public func listAgentCronTasks(agentID: String) async throws -> [AgentCronTask] {
        guard !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCronTaskError.invalidAgentID
        }
        return await store.listCronTasks(agentId: agentID)
    }

    public func createAgentCronTask(agentID: String, request: AgentCronTaskCreateRequest) async throws -> AgentCronTask {
        guard !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCronTaskError.invalidAgentID
        }
        let task = AgentCronTask(
            id: UUID().uuidString,
            agentId: agentID,
            channelId: request.channelId,
            schedule: request.schedule,
            command: request.command,
            enabled: request.enabled ?? true
        )
        await store.saveCronTask(task)
        return task
    }

    public func updateAgentCronTask(agentID: String, cronID: String, request: AgentCronTaskUpdateRequest) async throws -> AgentCronTask {
        guard let existing = await store.cronTask(id: cronID), existing.agentId == agentID else {
            throw AgentCronTaskError.notFound
        }
        var updated = existing
        if let schedule = request.schedule { updated.schedule = schedule }
        if let command = request.command { updated.command = command }
        if let channelId = request.channelId { updated.channelId = channelId }
        if let enabled = request.enabled { updated.enabled = enabled }
        updated.updatedAt = Date()
        await store.saveCronTask(updated)
        return updated
    }

    public func deleteAgentCronTask(agentID: String, cronID: String) async throws {
        guard let existing = await store.cronTask(id: cronID), existing.agentId == agentID else {
            throw AgentCronTaskError.notFound
        }
        await store.deleteCronTask(id: cronID)
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
        let normalizedID: String
        if let requestedID = request.id, !requestedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let validID = normalizedProjectID(requestedID) else {
                throw ProjectError.invalidProjectID
            }
            guard await store.project(id: validID) == nil else {
                throw ProjectError.conflict
            }
            normalizedID = validID
        } else {
            normalizedID = UUID().uuidString
        }
        let channels = try normalizeInitialProjectChannels(request.channels, fallbackName: normalizedName)
        let project = ProjectRecord(
            id: normalizedID,
            name: normalizedName,
            description: normalizedDescription,
            channels: channels,
            tasks: [],
            createdAt: now,
            updatedAt: now
        )
        await store.saveProject(project)
        ensureProjectWorkspaceDirectory(projectID: normalizedID)
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
        let normalizedStatus = try normalizeTaskStatus(request.status)
        let task = ProjectTask(
            id: nextProjectTaskID(for: project),
            title: try normalizeTaskTitle(request.title),
            description: normalizeTaskDescription(request.description),
            priority: try normalizeTaskPriority(request.priority),
            status: normalizedStatus,
            actorId: try normalizeOptionalTaskActorID(request.actorId),
            teamId: try normalizeOptionalTaskTeamID(request.teamId),
            createdAt: now,
            updatedAt: now
        )
        project.tasks.append(task)
        project.updatedAt = now
        await store.saveProject(project)
        if normalizedStatus == "ready" {
            await handleTaskBecameReady(projectID: normalizedID, taskID: task.id)
            if let updated = await store.project(id: normalizedID) {
                return updated
            }
        }
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
        let normalizedTaskLowercased = normalizedTask.lowercased()
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard let taskIndex = project.tasks.firstIndex(where: { $0.id.lowercased() == normalizedTaskLowercased }) else {
            throw ProjectError.notFound
        }

        let previousStatus = project.tasks[taskIndex].status
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
        if request.actorId != nil {
            task.actorId = try normalizeOptionalTaskActorID(request.actorId)
            task.claimedActorId = nil
            task.claimedAgentId = nil
        }
        if request.teamId != nil {
            task.teamId = try normalizeOptionalTaskTeamID(request.teamId)
            task.claimedActorId = nil
            task.claimedAgentId = nil
        }
        if let status = request.status {
            task.status = try normalizeTaskStatus(status)
            if task.status == "backlog" {
                task.claimedActorId = nil
                task.claimedAgentId = nil
            }
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        if previousStatus != "ready", task.status == "ready" {
            await handleTaskBecameReady(projectID: normalizedProject, taskID: task.id)
            if let updated = await store.project(id: normalizedProject) {
                return updated
            }
        }
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
        let normalizedTaskLowercased = normalizedTask.lowercased()
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard project.tasks.contains(where: { $0.id.lowercased() == normalizedTaskLowercased }) else {
            throw ProjectError.notFound
        }

        project.tasks.removeAll(where: { $0.id.lowercased() == normalizedTaskLowercased })
        project.updatedAt = Date()
        await store.saveProject(project)
        return project
    }

    /// Returns one task by readable id (for example, `MOBILE-1`).
    public func getProjectTask(taskReference: String) async throws -> AgentTaskRecord {
        guard let normalizedReference = normalizeTaskReference(taskReference) else {
            throw ProjectError.invalidTaskID
        }
        let normalizedReferenceLowercased = normalizedReference.lowercased()

        let projects = await store.listProjects().sorted(by: { $0.createdAt < $1.createdAt })
        for project in projects {
            guard let task = project.tasks.first(where: { $0.id.lowercased() == normalizedReferenceLowercased }) else {
                continue
            }

            return AgentTaskRecord(
                projectId: project.id,
                projectName: project.name,
                task: task
            )
        }

        throw ProjectError.notFound
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

    /// Lists project tasks currently claimed by a specific agent.
    public func listAgentTasks(agentID: String) async throws -> [AgentTaskRecord] {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let projects = await store.listProjects()
        var records: [AgentTaskRecord] = []
        for project in projects {
            for task in project.tasks {
                guard let claimedAgentID = task.claimedAgentId else {
                    continue
                }
                if claimedAgentID.caseInsensitiveCompare(normalizedID) == .orderedSame {
                    records.append(
                        AgentTaskRecord(
                            projectId: project.id,
                            projectName: project.name,
                            task: task
                        )
                    )
                }
            }
        }

        return records.sorted { left, right in
            left.task.updatedAt > right.task.updatedAt
        }
    }

    public func listAgentMemories(
        agentID: String,
        search: String?,
        filter: AgentMemoryFilter,
        limit: Int,
        offset: Int
    ) async throws -> AgentMemoryListResponse {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let boundedLimit = max(1, min(limit, 100))
        let boundedOffset = max(0, offset)
        let entries = await matchingAgentMemoryEntries(agentID: normalizedID, search: search, filter: filter)
        let page = Array(entries.dropFirst(boundedOffset).prefix(boundedLimit))

        return AgentMemoryListResponse(
            agentId: normalizedID,
            items: page.map { makeAgentMemoryItem(from: $0) },
            total: entries.count,
            limit: boundedLimit,
            offset: boundedOffset
        )
    }

    public func agentMemoryGraph(
        agentID: String,
        search: String?,
        filter: AgentMemoryFilter
    ) async throws -> AgentMemoryGraphResponse {
        guard let normalizedID = normalizedAgentID(agentID) else {
            throw AgentStorageError.invalidID
        }
        _ = try getAgent(id: normalizedID)

        let allEntries = await allAgentMemoryEntries(agentID: normalizedID)
        let matchingEntries = filterAgentMemoryEntries(allEntries, search: search, filter: filter)
        let seedEntries = Array(matchingEntries.prefix(Self.agentMemoryGraphSeedLimit))
        let seedIDs = seedEntries.map(\.id)
        var truncated = matchingEntries.count > Self.agentMemoryGraphSeedLimit

        guard !seedIDs.isEmpty else {
            return AgentMemoryGraphResponse(
                agentId: normalizedID,
                nodes: [],
                edges: [],
                seedIds: [],
                truncated: false
            )
        }

        let edgeRecords = await memoryStore.edges(for: seedIDs)
        let entriesByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        var neighborIDs: [String] = []
        var seenNeighborIDs = Set<String>()
        let seedIDSet = Set(seedIDs)

        for edge in edgeRecords {
            for candidateID in [edge.fromMemoryId, edge.toMemoryId] {
                guard !seedIDSet.contains(candidateID),
                      entriesByID[candidateID] != nil,
                      seenNeighborIDs.insert(candidateID).inserted
                else {
                    continue
                }
                neighborIDs.append(candidateID)
            }
        }

        if neighborIDs.count > Self.agentMemoryGraphNeighborLimit {
            neighborIDs = Array(neighborIDs.prefix(Self.agentMemoryGraphNeighborLimit))
            truncated = true
        }

        let includedNodeIDs = Set(seedIDs + neighborIDs)
        let includedNodes = seedEntries + neighborIDs.compactMap { entriesByID[$0] }
        let filteredEdges = edgeRecords
            .filter { includedNodeIDs.contains($0.fromMemoryId) && includedNodeIDs.contains($0.toMemoryId) }
            .map {
                AgentMemoryEdgeRecord(
                    fromMemoryId: $0.fromMemoryId,
                    toMemoryId: $0.toMemoryId,
                    relation: $0.relation,
                    weight: $0.weight,
                    provenance: $0.provenance,
                    createdAt: $0.createdAt
                )
            }

        return AgentMemoryGraphResponse(
            agentId: normalizedID,
            nodes: includedNodes.map { makeAgentMemoryItem(from: $0) },
            edges: filteredEdges,
            seedIds: seedIDs,
            truncated: truncated
        )
    }

    /// Creates an agent and provisions `/workspace/agents/<agent_id>` directory.
    public func createAgent(_ request: AgentCreateRequest) async throws -> AgentSummary {
        do {
            let summary = try agentCatalogStore.createAgent(request, availableModels: availableAgentModels())
            // Create skills directory for the new agent
            try await ensureAgentSkillsDirectory(agentID: summary.id)
            return summary
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

    func overrideModelProviderForTests(_ modelProvider: (any ModelProviderPlugin)?, defaultModel: String?) async {
        await runtime.updateModelProvider(modelProvider: modelProvider, defaultModel: defaultModel)
    }

    func triggerHeartbeatRunnerForTests() async {
        await heartbeatRunner?.triggerImmediately()
    }

    func heartbeatRunnerRunningForTests() async -> Bool {
        await heartbeatRunner?.running() ?? false
    }

    func listHeartbeatSchedules() async -> [AgentHeartbeatSchedule] {
        do {
            let agents = try listAgents()
            var schedules: [AgentHeartbeatSchedule] = []
            schedules.reserveCapacity(agents.count)

            for agent in agents {
                let config = try getAgentConfig(agentID: agent.id)
                guard config.heartbeat.enabled else {
                    continue
                }
                schedules.append(
                    AgentHeartbeatSchedule(
                        agentId: agent.id,
                        intervalMinutes: config.heartbeat.intervalMinutes,
                        lastRunAt: config.heartbeatStatus.lastRunAt
                    )
                )
            }
            return schedules
        } catch {
            logger.warning("Failed to load heartbeat schedules: \(error)")
            return []
        }
    }

    func runAgentHeartbeat(agentID: String) async {
        await waitForStartup()

        do {
            let config = try getAgentConfig(agentID: agentID)
            guard config.heartbeat.enabled else {
                return
            }

            let now = Date()
            var status = config.heartbeatStatus
            status.lastRunAt = now
            status.lastErrorMessage = nil

            let heartbeatMarkdown = config.documents.heartbeatMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if heartbeatMarkdown.isEmpty {
                status.lastSuccessAt = now
                status.lastResult = "ok_empty"
                status.lastSessionId = nil
                try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
                return
            }

            let session = try await createAgentSession(
                agentID: agentID,
                request: AgentSessionCreateRequest(
                    title: heartbeatSessionTitle(date: now),
                    kind: .heartbeat
                )
            )
            status.lastSessionId = session.id
            try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)

            let response = try await postAgentSessionMessage(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionPostMessageRequest(
                    userId: "system_heartbeat",
                    content: heartbeatPrompt(markdown: config.documents.heartbeatMarkdown)
                )
            )

            let assistantText = latestAssistantText(from: response.appendedEvents)
            let latestRunStatus = response.appendedEvents.reversed().first(where: { $0.type == .runStatus })?.runStatus
            let trimmedAssistantText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)

            if latestRunStatus?.stage != .interrupted && trimmedAssistantText == Self.heartbeatSuccessToken {
                status.lastSuccessAt = now
                status.lastResult = "ok"
                status.lastErrorMessage = nil
                try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
                return
            }

            let failureMessage = heartbeatFailureMessage(
                assistantText: trimmedAssistantText,
                runStatus: latestRunStatus
            )
            status.lastFailureAt = now
            status.lastResult = "failed"
            status.lastErrorMessage = failureMessage
            try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
            await notifyHeartbeatFailure(agentID: agentID, message: failureMessage)
        } catch {
            let now = Date()
            let message = "Heartbeat failed: \(error)"

            do {
                var status = try agentCatalogStore.getHeartbeatStatus(agentID: agentID)
                status.lastRunAt = now
                status.lastFailureAt = now
                status.lastResult = "failed"
                status.lastErrorMessage = message
                try agentCatalogStore.updateHeartbeatStatus(agentID: agentID, status: status)
            } catch {
                logger.warning("Failed to persist heartbeat error for agent \(agentID): \(error)")
            }

            await notifyHeartbeatFailure(agentID: agentID, message: message)
        }
    }

    /// Returns available tool catalog entries.
    public func toolCatalog() -> [AgentToolCatalogEntry] {
        ToolCatalog.entries
    }

    /// Returns agent tools policy from `/agents/<agentID>/tools/tools.json`.
    public func getAgentToolsPolicy(agentID: String) async throws -> AgentToolsPolicy {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentToolsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)
        do {
            return try await toolsAuthorization.policy(agentID: normalizedAgentID)
        } catch {
            throw mapAgentToolsError(error)
        }
    }

    /// Updates agent tools policy.
    public func updateAgentToolsPolicy(agentID: String, request: AgentToolsUpdateRequest) async throws -> AgentToolsPolicy {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentToolsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)
        do {
            return try await toolsAuthorization.updatePolicy(agentID: normalizedAgentID, request: request)
        } catch {
            throw mapAgentToolsError(error)
        }
    }

    // MARK: - Skills

    /// Fetch skills from skills.sh registry
    public func fetchSkillsRegistry(search: String? = nil, sort: String = "installs", limit: Int = 20, offset: Int = 0) async throws -> SkillsRegistryResponse {
        logger.debug("[skills.registry] request: search=\(search ?? "nil"), sort=\(sort), limit=\(limit), offset=\(offset)")

        let response: SkillsRegistryResponse
        do {
            let sortOption: SkillsRegistryService.SortOption
            switch sort {
            case "trending":
                sortOption = .trending
            case "recent":
                sortOption = .recent
            default:
                sortOption = .installs
            }
            response = try await skillsRegistryService.fetchSkills(search: search, sort: sortOption, limit: limit, offset: offset)
        } catch {
            logger.warning("[skills.registry] registry fetch failed, using mock data: \(String(describing: error))")
            response = skillsRegistryService.fetchMockSkills(search: search, limit: limit, offset: offset)
        }

        if let jsonData = try? JSONEncoder().encode(response),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let preview = jsonString.count > 1500 ? String(jsonString.prefix(1500)) + "…" : jsonString
            logger.debug("[skills.registry] response: total=\(response.total), skillsCount=\(response.skills.count), json=\(preview)")
        } else {
            logger.debug("[skills.registry] response: total=\(response.total), skillsCount=\(response.skills.count)")
        }
        return response
    }

    /// List installed skills for an agent
    public func listAgentSkills(agentID: String) async throws -> AgentSkillsResponse {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSkillsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)

        do {
            let skills = try agentSkillsStore.listSkills(agentID: normalizedAgentID)
            let skillsPath = agentSkillsStore.skillsDirectoryURL(agentID: normalizedAgentID).path
            return AgentSkillsResponse(agentId: normalizedAgentID, skills: skills, skillsPath: skillsPath)
        } catch let error as AgentSkillsFileStore.StoreError {
            throw mapAgentSkillsError(error)
        } catch {
            throw AgentSkillsError.storageFailure
        }
    }

    /// Install a skill for an agent
    public func installAgentSkill(agentID: String, request: SkillInstallRequest) async throws -> InstalledSkill {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSkillsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)

        let owner = request.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = request.repo.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !owner.isEmpty, !repo.isEmpty else {
            throw AgentSkillsError.invalidPayload
        }

        do {
            // Check if skill already exists
            let existingSkills = try agentSkillsStore.listSkills(agentID: normalizedAgentID)
            let skillID = "\(owner)/\(repo)"
            if existingSkills.contains(where: { $0.id == skillID }) {
                throw AgentSkillsError.skillAlreadyExists
            }

            // Download skill from GitHub
            let skillDestination = agentSkillsStore.skillDirectoryURL(agentID: normalizedAgentID, skillID: skillID)
            let downloadedSkill = try await skillsGitHubClient.downloadSkill(
                owner: owner,
                repo: repo,
                version: request.version,
                destination: skillDestination
            )

            // Register in manifest
            let installedSkill = try agentSkillsStore.installSkill(
                agentID: normalizedAgentID,
                owner: owner,
                repo: repo,
                name: downloadedSkill.name,
                description: downloadedSkill.description
            )

            return installedSkill
        } catch let error as AgentSkillsFileStore.StoreError {
            throw mapAgentSkillsError(error)
        } catch is SkillsGitHubClient.ClientError {
            throw AgentSkillsError.downloadFailure
        } catch {
            throw AgentSkillsError.storageFailure
        }
    }

    /// Uninstall a skill from an agent
    public func uninstallAgentSkill(agentID: String, skillID: String) async throws {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSkillsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)

        do {
            try agentSkillsStore.uninstallSkill(agentID: normalizedAgentID, skillID: skillID)
        } catch let error as AgentSkillsFileStore.StoreError {
            throw mapAgentSkillsError(error)
        } catch {
            throw AgentSkillsError.storageFailure
        }
    }

    /// Get agent skills for runtime use
    public func getAgentSkillsForRuntime(agentID: String) async throws -> [InstalledSkill] {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSkillsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)

        do {
            return try agentSkillsStore.listSkills(agentID: normalizedAgentID)
        } catch {
            return []
        }
    }

    /// Ensure skills directory exists (called during agent creation)
    public func ensureAgentSkillsDirectory(agentID: String) async throws {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSkillsError.invalidAgentID
        }

        do {
            try agentSkillsStore.ensureSkillsDirectory(agentID: normalizedAgentID)
        } catch {
            throw AgentSkillsError.storageFailure
        }
    }

    private func mapAgentSkillsError(_ error: AgentSkillsFileStore.StoreError) -> AgentSkillsError {
        switch error {
        case .invalidAgentID:
            return .invalidAgentID
        case .agentNotFound:
            return .agentNotFound
        case .skillAlreadyExists:
            return .skillAlreadyExists
        case .skillNotFound:
            return .skillNotFound
        default:
            return .storageFailure
        }
    }

    private static func encodeEventCursor(_ event: EventEnvelope) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(formatter.string(from: event.ts))|\(event.messageId)"
    }

    private static func decodeEventCursor(_ rawValue: String?) -> PersistedEventCursor? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }
        let parts = rawValue.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        let timestamp = String(parts[0])
        let eventID = String(parts[1])
        guard !eventID.isEmpty else {
            return nil
        }
        guard let createdAt = decodeEventCursorDate(timestamp) else {
            return nil
        }

        return PersistedEventCursor(createdAt: createdAt, eventId: eventID)
    }

    private static func decodeEventCursorDate(_ value: String) -> Date? {
        let formatterWithFractions = ISO8601DateFormatter()
        formatterWithFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatterWithFractions.date(from: value) {
            return parsed
        }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }

    // MARK: - Channel Plugins

    public func listChannelPlugins() async -> [ChannelPluginRecord] {
        await store.listChannelPlugins()
    }

    public func getChannelPlugin(id: String) async throws -> ChannelPluginRecord {
        guard let normalized = normalizedPluginID(id) else {
            throw ChannelPluginError.invalidID
        }
        guard let plugin = await store.channelPlugin(id: normalized) else {
            throw ChannelPluginError.notFound
        }
        return plugin
    }

    public func createChannelPlugin(_ request: ChannelPluginCreateRequest) async throws -> ChannelPluginRecord {
        let id: String
        if let requestID = request.id {
            guard let normalized = normalizedPluginID(requestID) else {
                throw ChannelPluginError.invalidID
            }
            if await store.channelPlugin(id: normalized) != nil {
                throw ChannelPluginError.conflict
            }
            id = normalized
        } else {
            id = UUID().uuidString.lowercased()
        }

        let type = request.type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty else {
            throw ChannelPluginError.invalidPayload
        }

        let baseUrl = request.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseUrl.isEmpty else {
            throw ChannelPluginError.invalidPayload
        }

        let now = Date()
        let plugin = ChannelPluginRecord(
            id: id,
            type: type,
            baseUrl: baseUrl,
            channelIds: request.channelIds ?? [],
            config: request.config ?? [:],
            enabled: request.enabled ?? true,
            createdAt: now,
            updatedAt: now
        )
        await store.saveChannelPlugin(plugin)
        return plugin
    }

    public func updateChannelPlugin(id: String, request: ChannelPluginUpdateRequest) async throws -> ChannelPluginRecord {
        guard let normalized = normalizedPluginID(id) else {
            throw ChannelPluginError.invalidID
        }
        guard var plugin = await store.channelPlugin(id: normalized) else {
            throw ChannelPluginError.notFound
        }
        if let type = request.type {
            let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ChannelPluginError.invalidPayload }
            plugin.type = trimmed
        }
        if let baseUrl = request.baseUrl {
            let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ChannelPluginError.invalidPayload }
            plugin.baseUrl = trimmed
        }
        if let channelIds = request.channelIds {
            plugin.channelIds = channelIds
        }
        if let config = request.config {
            plugin.config = config
        }
        if let enabled = request.enabled {
            plugin.enabled = enabled
        }
        plugin.updatedAt = Date()
        await store.saveChannelPlugin(plugin)
        return plugin
    }

    public func deleteChannelPlugin(id: String) async throws {
        guard let normalized = normalizedPluginID(id) else {
            throw ChannelPluginError.invalidID
        }
        guard await store.channelPlugin(id: normalized) != nil else {
            throw ChannelPluginError.notFound
        }
        await store.deleteChannelPlugin(id: normalized)
    }

    /// Finds the enabled plugin responsible for a given channel ID.
    public func channelPluginForChannel(channelId: String) async -> ChannelPluginRecord? {
        let plugins = await store.listChannelPlugins()
        return plugins.first { $0.enabled && $0.channelIds.contains(channelId) }
    }

    private func normalizedPluginID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        return trimmed
    }

    /// Returns actor graph snapshot used by visual canvas board.
    public func getActorBoard() throws -> ActorBoardSnapshot {
        do {
            let agents = try listAgents()
            return try actorBoardStore.loadBoard(agents: agents)
        } catch {
            throw mapActorBoardError(error)
        }
    }

    /// Stores visual actor graph updates and re-synchronizes system actors.
    public func updateActorBoard(request: ActorBoardUpdateRequest) throws -> ActorBoardSnapshot {
        do {
            let agents = try listAgents()
            return try actorBoardStore.saveBoard(request, agents: agents)
        } catch {
            throw mapActorBoardError(error)
        }
    }

    /// Resolves which actors can receive data from the sender according to graph links.
    public func resolveActorRoute(request: ActorRouteRequest) throws -> ActorRouteResponse {
        do {
            let agents = try listAgents()
            return try actorBoardStore.resolveRoute(request, agents: agents)
        } catch {
            throw mapActorBoardError(error)
        }
    }

    /// Creates one actor node in board.
    public func createActorNode(node: ActorNode) throws -> ActorBoardSnapshot {
        guard let nodeID = normalizedActorEntityID(node.id) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard !currentBoard.nodes.contains(where: { $0.id == nodeID }) else {
            throw ActorBoardError.invalidPayload
        }

        var nextNode = node
        nextNode.id = nodeID
        nextNode.createdAt = Date()

        return try updateActorBoardSnapshot(
            nodes: currentBoard.nodes + [nextNode],
            links: currentBoard.links,
            teams: currentBoard.teams,
            agents: agents
        )
    }

    /// Updates one actor node in board.
    public func updateActorNode(actorID: String, node: ActorNode) throws -> ActorBoardSnapshot {
        guard let normalizedID = normalizedActorEntityID(actorID) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard let existingNodeIndex = currentBoard.nodes.firstIndex(where: { $0.id == normalizedID }) else {
            throw ActorBoardError.actorNotFound
        }

        let existingNode = currentBoard.nodes[existingNodeIndex]
        let nextNode: ActorNode
        if isProtectedSystemActorID(normalizedID) {
            var protectedNode = existingNode
            protectedNode.positionX = node.positionX
            protectedNode.positionY = node.positionY
            nextNode = protectedNode
        } else {
            var editableNode = node
            editableNode.id = normalizedID
            editableNode.createdAt = existingNode.createdAt
            nextNode = editableNode
        }

        var nodes = currentBoard.nodes
        nodes[existingNodeIndex] = nextNode
        return try updateActorBoardSnapshot(
            nodes: nodes,
            links: currentBoard.links,
            teams: currentBoard.teams,
            agents: agents
        )
    }

    /// Deletes one actor node in board with related links and team memberships.
    public func deleteActorNode(actorID: String) throws -> ActorBoardSnapshot {
        guard let normalizedID = normalizedActorEntityID(actorID) else {
            throw ActorBoardError.invalidPayload
        }

        if isProtectedSystemActorID(normalizedID) {
            throw ActorBoardError.protectedActor
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard currentBoard.nodes.contains(where: { $0.id == normalizedID }) else {
            throw ActorBoardError.actorNotFound
        }

        let nodes = currentBoard.nodes.filter { $0.id != normalizedID }
        let links = currentBoard.links.filter {
            $0.sourceActorId != normalizedID && $0.targetActorId != normalizedID
        }
        let teams = currentBoard.teams.map { team in
            ActorTeam(
                id: team.id,
                name: team.name,
                memberActorIds: team.memberActorIds.filter { $0 != normalizedID },
                createdAt: team.createdAt
            )
        }

        return try updateActorBoardSnapshot(nodes: nodes, links: links, teams: teams, agents: agents)
    }

    /// Creates one link between actors.
    public func createActorLink(link: ActorLink) throws -> ActorBoardSnapshot {
        guard let linkID = normalizedActorEntityID(link.id) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard !currentBoard.links.contains(where: { $0.id == linkID }) else {
            throw ActorBoardError.invalidPayload
        }

        var nextLink = link
        nextLink.id = linkID
        nextLink.createdAt = Date()

        return try updateActorBoardSnapshot(
            nodes: currentBoard.nodes,
            links: currentBoard.links + [nextLink],
            teams: currentBoard.teams,
            agents: agents
        )
    }

    /// Updates one actor link.
    public func updateActorLink(linkID: String, link: ActorLink) throws -> ActorBoardSnapshot {
        guard let normalizedID = normalizedActorEntityID(linkID) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard let existingLinkIndex = currentBoard.links.firstIndex(where: { $0.id == normalizedID }) else {
            throw ActorBoardError.linkNotFound
        }

        var nextLink = link
        nextLink.id = normalizedID
        nextLink.createdAt = currentBoard.links[existingLinkIndex].createdAt

        var links = currentBoard.links
        links[existingLinkIndex] = nextLink
        return try updateActorBoardSnapshot(
            nodes: currentBoard.nodes,
            links: links,
            teams: currentBoard.teams,
            agents: agents
        )
    }

    /// Deletes one actor link.
    public func deleteActorLink(linkID: String) throws -> ActorBoardSnapshot {
        guard let normalizedID = normalizedActorEntityID(linkID) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard currentBoard.links.contains(where: { $0.id == normalizedID }) else {
            throw ActorBoardError.linkNotFound
        }

        return try updateActorBoardSnapshot(
            nodes: currentBoard.nodes,
            links: currentBoard.links.filter { $0.id != normalizedID },
            teams: currentBoard.teams,
            agents: agents
        )
    }

    /// Creates one team.
    public func createActorTeam(team: ActorTeam) throws -> ActorBoardSnapshot {
        guard let teamID = normalizedActorEntityID(team.id) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard !currentBoard.teams.contains(where: { $0.id == teamID }) else {
            throw ActorBoardError.invalidPayload
        }

        var nextTeam = team
        nextTeam.id = teamID
        nextTeam.createdAt = Date()

        return try updateActorBoardSnapshot(
            nodes: currentBoard.nodes,
            links: currentBoard.links,
            teams: currentBoard.teams + [nextTeam],
            agents: agents
        )
    }

    /// Updates one team.
    public func updateActorTeam(teamID: String, team: ActorTeam) throws -> ActorBoardSnapshot {
        guard let normalizedID = normalizedActorEntityID(teamID) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard let existingTeamIndex = currentBoard.teams.firstIndex(where: { $0.id == normalizedID }) else {
            throw ActorBoardError.teamNotFound
        }

        var nextTeam = team
        nextTeam.id = normalizedID
        nextTeam.createdAt = currentBoard.teams[existingTeamIndex].createdAt

        var teams = currentBoard.teams
        teams[existingTeamIndex] = nextTeam
        return try updateActorBoardSnapshot(
            nodes: currentBoard.nodes,
            links: currentBoard.links,
            teams: teams,
            agents: agents
        )
    }

    /// Deletes one team.
    public func deleteActorTeam(teamID: String) throws -> ActorBoardSnapshot {
        guard let normalizedID = normalizedActorEntityID(teamID) else {
            throw ActorBoardError.invalidPayload
        }

        let agents = try listAgents()
        let currentBoard = try actorBoardStore.loadBoard(agents: agents)
        guard currentBoard.teams.contains(where: { $0.id == normalizedID }) else {
            throw ActorBoardError.teamNotFound
        }

        return try updateActorBoardSnapshot(
            nodes: currentBoard.nodes,
            links: currentBoard.links,
            teams: currentBoard.teams.filter { $0.id != normalizedID },
            agents: agents
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
    public func createAgentSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        await waitForStartup()
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
        let streamKey = sessionStreamKey(agentID: normalizedAgentID, sessionID: normalizedSessionID)

        return AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let listenerID = UUID()
            let task = Task { [normalizedAgentID, normalizedSessionID, streamKey] in
                self.registerLiveSessionStreamContinuation(
                    key: streamKey,
                    listenerID: listenerID,
                    continuation: continuation
                )

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
                Task {
                    await self.unregisterLiveSessionStreamContinuation(key: streamKey, listenerID: listenerID)
                }
            }
        }
    }

    private func publishLiveSessionDelta(agentID: String, sessionID: String, chunk: String) {
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let key = sessionStreamKey(agentID: agentID, sessionID: sessionID)
        guard let listeners = liveSessionStreamContinuations[key], !listeners.isEmpty else {
            return
        }

        let cursor = nextLiveSessionStreamCursor(for: key)
        let update = AgentSessionStreamUpdate(
            kind: .sessionDelta,
            cursor: cursor,
            message: normalized
        )

        for continuation in listeners.values {
            continuation.yield(update)
        }
    }

    private func registerLiveSessionStreamContinuation(
        key: String,
        listenerID: UUID,
        continuation: AsyncStream<AgentSessionStreamUpdate>.Continuation
    ) {
        var listeners = liveSessionStreamContinuations[key] ?? [:]
        listeners[listenerID] = continuation
        liveSessionStreamContinuations[key] = listeners
    }

    private func unregisterLiveSessionStreamContinuation(key: String, listenerID: UUID) {
        guard var listeners = liveSessionStreamContinuations[key] else {
            return
        }

        listeners.removeValue(forKey: listenerID)
        if listeners.isEmpty {
            liveSessionStreamContinuations.removeValue(forKey: key)
            liveSessionStreamCursor.removeValue(forKey: key)
        } else {
            liveSessionStreamContinuations[key] = listeners
        }
    }

    private func nextLiveSessionStreamCursor(for key: String) -> Int {
        let baseline = max(1_000_000, liveSessionStreamCursor[key] ?? 1_000_000)
        let next = baseline + 1
        liveSessionStreamCursor[key] = next
        return next
    }

    private func sessionStreamKey(agentID: String, sessionID: String) -> String {
        "\(agentID)::\(sessionID)"
    }

    /// Deletes one session and its attachment directory.
    public func deleteAgentSession(agentID: String, sessionID: String) async throws {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }

        _ = try getAgent(id: normalizedAgentID)

        do {
            try sessionStore.deleteSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
            await toolExecution.cleanupSessionProcesses(normalizedSessionID)
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
        await waitForStartup()
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
        await waitForStartup()
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

    /// Returns latest persisted system logs from `/workspace/logs/*.log`.
    public func getSystemLogs(limit: Int = 1500) throws -> SystemLogsResponse {
        do {
            return try systemLogStore.readRecentEntries(limit: limit)
        } catch {
            throw SystemLogsError.storageFailure
        }
    }

    /// Executes one tool call in session context and persists tool_call/tool_result events.
    public func invokeTool(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest
    ) async throws -> ToolInvocationResult {
        let result = await invokeToolFromRuntime(agentID: agentID, sessionID: sessionID, request: request)
        if result.ok || result.error?.code != "tool_forbidden" {
            return result
        }
        throw ToolInvocationError.forbidden(result.error ?? .init(code: "tool_forbidden", message: "Forbidden", retryable: false))
    }

    /// Internal runtime path used by auto tool-calling loop.
    public func invokeToolFromRuntime(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest
    ) async -> ToolInvocationResult {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_session_id", message: "Invalid session id.", retryable: false)
            )
        }
        guard !request.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_tool", message: "Tool id is required.", retryable: false)
            )
        }

        do {
            _ = try getAgent(id: normalizedAgentID)
            _ = try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch let error as AgentStorageError {
            if case .notFound = error {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "agent_not_found", message: "Agent not found.", retryable: false)
                )
            }
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "session_not_found", message: "Session not found.", retryable: false)
            )
        }

        let authorization: ToolAuthorizationDecision
        do {
            authorization = try await toolsAuthorization.authorize(agentID: normalizedAgentID, toolID: request.tool)
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "authorization_failed", message: "Failed to authorize tool call.", retryable: true)
            )
        }

        do {
            _ = try sessionStore.appendEvents(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                events: [
                    AgentSessionEvent(
                        agentId: normalizedAgentID,
                        sessionId: normalizedSessionID,
                        type: .toolCall,
                        toolCall: AgentToolCallEvent(
                            tool: request.tool,
                            arguments: request.arguments,
                            reason: request.reason
                        )
                    )
                ]
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "session_write_failed", message: "Failed to persist tool call event.", retryable: true)
            )
        }

        let result: ToolInvocationResult
        if authorization.allowed, let projectResult = await handleProjectTool(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            request: request
        ) {
            result = projectResult
        } else if authorization.allowed {
            result = await toolExecution.invoke(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request,
                policy: authorization.policy
            )
        } else {
            result = .init(
                tool: request.tool,
                ok: false,
                error: authorization.error ?? .init(code: "tool_forbidden", message: "Tool is forbidden.", retryable: false)
            )
        }

        do {
            _ = try sessionStore.appendEvents(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                events: [
                    AgentSessionEvent(
                        agentId: normalizedAgentID,
                        sessionId: normalizedSessionID,
                        type: .toolResult,
                        toolResult: AgentToolResultEvent(
                            tool: request.tool,
                            ok: result.ok,
                            data: result.data,
                            error: result.error,
                            durationMs: result.durationMs
                        )
                    )
                ]
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "session_write_failed", message: "Failed to persist tool result event.", retryable: true)
            )
        }

        return result
    }

    /// Persists config to file and updates in-memory snapshot.
    public func updateConfig(_ config: CoreConfig) async throws -> CoreConfig {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encoded = try encoder.encode(config)
        let payload = encoded + Data("\n".utf8)
        let url = URL(fileURLWithPath: configPath)
        try payload.write(to: url, options: .atomic)

        let previousChannels = currentConfig.channels
        currentConfig = config
        workspaceRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
        agentsRootURL = workspaceRootURL
            .appendingPathComponent("agents", isDirectory: true)
        agentCatalogStore.updateAgentsRootURL(agentsRootURL)
        sessionStore.updateAgentsRootURL(agentsRootURL)
        actorBoardStore.updateWorkspaceRootURL(workspaceRootURL)
        await sessionOrchestrator.updateAgentsRootURL(agentsRootURL)
        await toolsAuthorization.updateAgentsRootURL(agentsRootURL)
        toolExecution.updateWorkspaceRootURL(workspaceRootURL)
        systemLogStore.updateWorkspaceRootURL(workspaceRootURL)
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        let modelProvider = CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: resolvedModels)
        let defaultModel = modelProvider?.models.first ?? resolvedModels.first
        await runtime.updateModelProvider(modelProvider: modelProvider, defaultModel: defaultModel)
        await sessionOrchestrator.updateAvailableModels(Self.availableAgentModels(config: config))

        if previousChannels.telegram != config.channels.telegram {
            await reloadTelegramPlugin(newConfig: config.channels.telegram)
        }

        return currentConfig
    }

    private func reloadTelegramPlugin(newConfig: CoreConfig.ChannelConfig.Telegram?) async {
        if let existing = activeGatewayPlugins.first(where: { $0.id == "telegram" }) {
            logger.info("Telegram config changed — stopping existing plugin.")
            await existing.stop()
            await channelDelivery.unregisterPlugin(existing)
            activeGatewayPlugins.removeAll { $0.id == "telegram" }
        }

        guard let telegramConfig = newConfig, !telegramConfig.botToken.isEmpty else {
            logger.info("Telegram plugin removed (no config or empty token).")
            return
        }

        logger.info("Telegram config changed — starting new plugin.")
        let plugin = TelegramGatewayPlugin(
            botToken: telegramConfig.botToken,
            channelChatMap: telegramConfig.channelChatMap,
            allowedUserIds: telegramConfig.allowedUserIds,
            allowedChatIds: telegramConfig.allowedChatIds,
            logger: Logger(label: "sloppy.plugin.telegram")
        )
        await channelDelivery.registerPlugin(plugin)
        activeGatewayPlugins.append(plugin)
        await seedTelegramPluginRecord(plugin: plugin, config: telegramConfig)
        do {
            try await plugin.start(inboundReceiver: self)
            logger.info("Telegram plugin reloaded successfully.")
        } catch {
            logger.error("Failed to reload Telegram plugin: \(error)")
        }
    }

    private func handleTaskApprovalCommand(channelId: String, reference: TaskApprovalReference) async -> ChannelRouteDecision {
        guard let project = await projectForChannel(channelId: channelId) else {
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "project_not_found_for_channel"
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "project_not_found_for_channel",
                confidence: 1.0,
                tokenBudget: 0
            )
        }

        guard let task = resolveTask(reference: reference, in: project) else {
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "task_not_found"
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "task_not_found",
                confidence: 1.0,
                tokenBudget: 0
            )
        }

        do {
            _ = try await updateProjectTask(
                projectID: project.id,
                taskID: task.id,
                request: ProjectTaskUpdateRequest(status: "ready")
            )
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "Task \(task.id) approved and queued for execution."
            )
            logger.info(
                "visor.task.approved",
                metadata: [
                    "project_id": .string(project.id),
                    "task_id": .string(task.id),
                    "channel_id": .string(channelId),
                    "source": .string("nl_command")
                ]
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "task_approved_command",
                confidence: 1.0,
                tokenBudget: 0
            )
        } catch {
            await runtime.appendSystemMessage(
                channelId: channelId,
                content: "task_not_found"
            )
            return ChannelRouteDecision(
                action: .respond,
                reason: "task_not_found",
                confidence: 1.0,
                tokenBudget: 0
            )
        }
    }

    private func handleTaskBecameReady(projectID: String, taskID: String) async {
        guard var project = await store.project(id: projectID),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            return
        }

        var task = project.tasks[taskIndex]
        guard task.status == "ready" else {
            return
        }

        _ = await triggerVisorBulletin()
        logger.info(
            "visor.task.approved",
            metadata: [
                "project_id": .string(projectID),
                "task_id": .string(taskID),
                "source": .string("status_ready")
            ]
        )

        let workers = await runtime.workerSnapshots()
        let hasActiveWorker = workers.contains { snapshot in
            snapshot.taskId == task.id &&
            (snapshot.status == .queued || snapshot.status == .running || snapshot.status == .waitingInput)
        }
        guard !hasActiveWorker else {
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "already_running",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: workers.first(where: { $0.taskId == task.id })?.workerId,
                message: "Skipped auto-delegation because task already has an active worker."
            )
            return
        }

        let delegation: TaskDelegation?
        if task.swarmId != nil, let swarmTaskId = task.swarmTaskId, swarmTaskId != "root" {
            delegation = await resolveSwarmTaskDelegation(project: project, task: task)
        } else {
            delegation = await resolveTaskDelegation(project: project, task: task)
        }
        guard let delegation else {
            let blockedMessage = "Task \(task.id) is ready but no eligible actor route was resolved."
            if let channelID = resolveExecutionChannelID(project: project, task: task) {
                await runtime.appendSystemMessage(channelId: channelID, content: blockedMessage)
            }
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "route_blocked",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                message: blockedMessage
            )
            return
        }

        if await startSwarmIfHierarchical(projectID: project.id, taskID: task.id, delegation: delegation) {
            return
        }

        task.claimedActorId = delegation.actorID
        task.claimedAgentId = delegation.agentID
        if let actorID = delegation.actorID {
            task.actorId = actorID
        }
        let workerObjective = buildWorkerObjective(task: task, projectID: project.id)
        let workerId = await runtime.createWorker(
            spec: WorkerTaskSpec(
                taskId: task.id,
                channelId: delegation.channelID,
                title: task.title,
                objective: workerObjective,
                tools: ["shell", "file", "exec", "browser"],
                mode: .fireAndForget
            )
        )

        task.status = "in_progress"
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: "worker_spawned",
            channelID: delegation.channelID,
            workerID: workerId,
            message: "Task delegated.",
            actorID: delegation.actorID,
            agentID: delegation.agentID
        )

        logger.info(
            "visor.task.worker_spawned",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id),
                "worker_id": .string(workerId),
                "channel_id": .string(delegation.channelID),
                "agent_id": .string(delegation.agentID ?? "none")
            ]
        )
        // Build a descriptive spawn message including agent/actor details and log path.
        let delegateMessage: String
        if let agentID = delegation.agentID {
            delegateMessage = "Task \(task.id) delegated to agent \(agentID)."
        } else if let actorID = delegation.actorID {
            delegateMessage = "Task \(task.id) delegated to actor \(actorID)."
        } else {
            delegateMessage = "Task \(task.id) started in channel \(delegation.channelID)."
        }
        let logsPath = projectTaskLogFileURL(projectID: project.id, taskID: task.id).path
        let spawnMessage = "\(delegateMessage) Logs: \(logsPath)"
        await runtime.appendSystemMessage(
            channelId: delegation.channelID,
            content: spawnMessage
        )
        await deliverToChannelPlugin(
            channelId: delegation.channelID,
            content: spawnMessage
        )
    }

    private func resolveExecutionChannelID(project: ProjectRecord, task: ProjectTask) -> String? {
        if let markedChannelID = extractOriginChannelID(from: task.description),
           project.channels.contains(where: { $0.channelId == markedChannelID }) {
            return markedChannelID
        }
        return project.channels.sorted(by: { $0.createdAt < $1.createdAt }).first?.channelId
    }

    private struct TaskDelegation {
        let actorID: String?
        let agentID: String?
        let channelID: String
    }

    private func startSwarmIfHierarchical(
        projectID: String,
        taskID: String,
        delegation: TaskDelegation
    ) async -> Bool {
        guard var project = await store.project(id: projectID),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            return false
        }

        var rootTask = project.tasks[taskIndex]
        guard rootTask.status == "ready" else {
            return false
        }
        guard rootTask.swarmTaskId == nil else {
            return false
        }
        let hasExplicitAssignee = (rootTask.actorId != nil || rootTask.teamId != nil || rootTask.claimedActorId != nil)
        guard hasExplicitAssignee else {
            return false
        }

        guard let board = try? getActorBoard() else {
            return false
        }
        let rootActorID = delegation.actorID ?? rootTask.claimedActorId ?? rootTask.actorId ?? ""
        guard !rootActorID.isEmpty else {
            return false
        }

        switch SwarmCoordinator.buildHierarchy(rootActorId: rootActorID, links: board.links, logger: logger) {
        case .noHierarchy:
            return false
        case .cycle:
            await failSwarmRootWithEscalation(
                projectID: projectID,
                rootTaskID: rootTask.id,
                failedTaskID: nil,
                reason: "Swarm hierarchy cycle detected; execution was blocked.",
                executionChannelID: delegation.channelID,
                board: board
            )
            return true
        case .hierarchy(let hierarchy):
            do {
                let plannedSubtasks = try await swarmPlanner.plan(rootTask: rootTask, actorLevels: hierarchy.levels)
                if plannedSubtasks.isEmpty {
                    await failSwarmRootWithEscalation(
                        projectID: projectID,
                        rootTaskID: rootTask.id,
                        failedTaskID: nil,
                        reason: "Swarm planner returned empty subtask plan.",
                        executionChannelID: delegation.channelID,
                        board: board
                    )
                    return true
                }

                let swarmID = UUID().uuidString
                rootTask.claimedActorId = delegation.actorID
                rootTask.claimedAgentId = delegation.agentID
                if let actorID = delegation.actorID {
                    rootTask.actorId = actorID
                }
                rootTask.swarmId = swarmID
                rootTask.swarmTaskId = "root"
                rootTask.swarmParentTaskId = nil
                rootTask.swarmDependencyIds = nil
                rootTask.swarmDepth = 0
                rootTask.swarmActorPath = [rootActorID]
                rootTask.status = "in_progress"
                rootTask.updatedAt = Date()
                project.tasks[taskIndex] = rootTask

                var roundRobinByDepth: [Int: Int] = [:]
                let sortedPlanned = plannedSubtasks.sorted { lhs, rhs in
                    if lhs.depth == rhs.depth {
                        return lhs.swarmTaskId < rhs.swarmTaskId
                    }
                    return lhs.depth < rhs.depth
                }

                for planned in sortedPlanned {
                    guard !hierarchy.levels.isEmpty else { continue }
                    let levelIndex = min(max(planned.depth, 1) - 1, hierarchy.levels.count - 1)
                    let levelActors = hierarchy.levels[levelIndex]
                    guard !levelActors.isEmpty else { continue }

                    let nextIndex = roundRobinByDepth[levelIndex, default: 0]
                    let assignedActorID = levelActors[nextIndex % levelActors.count]
                    roundRobinByDepth[levelIndex] = nextIndex + 1
                    let actorPath = swarmActorPath(
                        rootActorID: hierarchy.rootActorId,
                        targetActorID: assignedActorID,
                        parentByActor: hierarchy.parentByActor
                    )

                    let now = Date()
                    project.tasks.append(
                        ProjectTask(
                            id: UUID().uuidString,
                            title: planned.title,
                            description: normalizeTaskDescription(
                                """
                                Source: swarm-planner
                                Swarm objective: \(planned.objective)
                                """
                            ),
                            priority: rootTask.priority,
                            status: "ready",
                            actorId: assignedActorID,
                            teamId: nil,
                            claimedActorId: nil,
                            claimedAgentId: nil,
                            swarmId: swarmID,
                            swarmTaskId: planned.swarmTaskId,
                            swarmParentTaskId: planned.dependencyIds.first,
                            swarmDependencyIds: planned.dependencyIds,
                            swarmDepth: planned.depth,
                            swarmActorPath: actorPath,
                            createdAt: now,
                            updatedAt: now
                        )
                    )
                }

                project.updatedAt = Date()
                await store.saveProject(project)
                appendTaskLifecycleLog(
                    projectID: project.id,
                    taskID: rootTask.id,
                    stage: "swarm_started",
                    channelID: delegation.channelID,
                    workerID: nil,
                    message: "Swarm started with \(project.tasks.filter { $0.swarmId == swarmID && $0.id != rootTask.id }.count) subtasks.",
                    actorID: delegation.actorID,
                    agentID: delegation.agentID
                )
                await runtime.appendSystemMessage(
                    channelId: delegation.channelID,
                    content: "Swarm \(swarmID) started for task \(rootTask.id)."
                )

                Task {
                    await self.executeSwarm(
                        projectID: projectID,
                        rootTaskID: rootTask.id,
                        swarmID: swarmID,
                        executionChannelID: delegation.channelID,
                        board: board
                    )
                }
                return true
            } catch {
                await failSwarmRootWithEscalation(
                    projectID: projectID,
                    rootTaskID: rootTask.id,
                    failedTaskID: nil,
                    reason: "Swarm planner failed: \(error)",
                    executionChannelID: delegation.channelID,
                    board: board
                )
                return true
            }
        }
    }

    private func executeSwarm(
        projectID: String,
        rootTaskID: String,
        swarmID: String,
        executionChannelID: String,
        board: ActorBoardSnapshot
    ) async {
        guard let project = await store.project(id: projectID) else {
            return
        }
        let swarmTasks = project.tasks
            .filter { $0.swarmId == swarmID && $0.id != rootTaskID }
            .sorted { lhs, rhs in
                if lhs.swarmDepth == rhs.swarmDepth {
                    return lhs.createdAt < rhs.createdAt
                }
                return (lhs.swarmDepth ?? .max) < (rhs.swarmDepth ?? .max)
            }

        if swarmTasks.isEmpty {
            await failSwarmRootWithEscalation(
                projectID: projectID,
                rootTaskID: rootTaskID,
                failedTaskID: nil,
                reason: "Swarm has no executable child tasks.",
                executionChannelID: executionChannelID,
                board: board
            )
            return
        }

        var completedSwarmTaskIDs: Set<String> = []
        let byDepth = Dictionary(grouping: swarmTasks, by: { $0.swarmDepth ?? 1 })
        let orderedDepths = byDepth.keys.sorted()

        for depth in orderedDepths {
            let levelTasks = (byDepth[depth] ?? []).sorted { $0.createdAt < $1.createdAt }
            var pendingTasks = levelTasks.filter { task in
                let dependencies = Set(task.swarmDependencyIds ?? [])
                return dependencies.isSubset(of: completedSwarmTaskIDs)
            }
            if pendingTasks.count != levelTasks.count {
                await failSwarmRootWithEscalation(
                    projectID: projectID,
                    rootTaskID: rootTaskID,
                    failedTaskID: nil,
                    reason: "Swarm dependencies are unresolved at level \(depth).",
                    executionChannelID: executionChannelID,
                    board: board
                )
                return
            }

            while !pendingTasks.isEmpty {
                let batch = Array(pendingTasks.prefix(3))
                pendingTasks.removeFirst(min(3, pendingTasks.count))

                for task in batch {
                    await handleTaskBecameReady(projectID: projectID, taskID: task.id)
                }

                let settled = await waitForTasksToSettle(
                    projectID: projectID,
                    taskIDs: batch.map(\.id),
                    timeoutSeconds: 240
                )
                guard settled else {
                    await failSwarmRootWithEscalation(
                        projectID: projectID,
                        rootTaskID: rootTaskID,
                        failedTaskID: batch.first?.id,
                        reason: "Swarm batch timed out while waiting for worker completion.",
                        executionChannelID: executionChannelID,
                        board: board
                    )
                    return
                }

                guard let refreshedProject = await store.project(id: projectID) else {
                    return
                }
                for task in batch {
                    guard let refreshed = refreshedProject.tasks.first(where: { $0.id == task.id }) else {
                        continue
                    }
                    if refreshed.status != "done" {
                        await failSwarmRootWithEscalation(
                            projectID: projectID,
                            rootTaskID: rootTaskID,
                            failedTaskID: refreshed.id,
                            reason: "Child task \(refreshed.id) finished with status \(refreshed.status).",
                            executionChannelID: executionChannelID,
                            board: board
                        )
                        return
                    }
                    if let swarmTaskId = refreshed.swarmTaskId {
                        completedSwarmTaskIDs.insert(swarmTaskId)
                    }
                }
            }
        }

        await completeSwarmRoot(
            projectID: projectID,
            rootTaskID: rootTaskID,
            swarmID: swarmID,
            executionChannelID: executionChannelID
        )
    }

    private func waitForTasksToSettle(
        projectID: String,
        taskIDs: [String],
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        let runningStatuses = Set(["in_progress"])
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            guard let project = await store.project(id: projectID) else {
                return false
            }

            let statuses: [String] = taskIDs.compactMap { taskID in
                project.tasks.first(where: { $0.id == taskID })?.status
            }
            guard statuses.count == taskIDs.count else {
                return false
            }
            if statuses.allSatisfy({ !runningStatuses.contains($0) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return false
    }

    private func completeSwarmRoot(
        projectID: String,
        rootTaskID: String,
        swarmID: String,
        executionChannelID: String
    ) async {
        guard var project = await store.project(id: projectID),
              let rootIndex = project.tasks.firstIndex(where: { $0.id == rootTaskID })
        else {
            return
        }

        let childTasks = project.tasks.filter { $0.swarmId == swarmID && $0.id != rootTaskID }
        let artifactRefs = childTasks.flatMap { task in
            extractArtifactRefs(from: task.description)
        }
        let summaryLine = "Swarm completed \(childTasks.count) subtasks."
        let artifactLine = artifactRefs.isEmpty ? "" : "\nArtifacts: \(artifactRefs.joined(separator: ", "))"

        var rootTask = project.tasks[rootIndex]
        rootTask.status = "done"
        rootTask.updatedAt = Date()
        if !summaryLine.isEmpty {
            if rootTask.description.isEmpty {
                rootTask.description = summaryLine + artifactLine
            } else if !rootTask.description.contains(summaryLine) {
                rootTask.description += "\n\n" + summaryLine + artifactLine
            }
        }
        project.tasks[rootIndex] = rootTask
        project.updatedAt = Date()
        await store.saveProject(project)

        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: rootTaskID,
            stage: "swarm_completed",
            channelID: executionChannelID,
            workerID: nil,
            message: summaryLine
        )
        await runtime.appendSystemMessage(
            channelId: executionChannelID,
            content: "\(summaryLine)\(artifactLine)"
        )
        await deliverToChannelPlugin(
            channelId: executionChannelID,
            content: "\(summaryLine)\(artifactLine)"
        )
    }

    private func failSwarmRootWithEscalation(
        projectID: String,
        rootTaskID: String,
        failedTaskID: String?,
        reason: String,
        executionChannelID: String,
        board: ActorBoardSnapshot
    ) async {
        guard var project = await store.project(id: projectID),
              let rootIndex = project.tasks.firstIndex(where: { $0.id == rootTaskID })
        else {
            return
        }

        var rootTask = project.tasks[rootIndex]
        rootTask.status = "blocked"
        rootTask.updatedAt = Date()
        if rootTask.description.isEmpty {
            rootTask.description = reason
        } else if !rootTask.description.contains(reason) {
            rootTask.description += "\n\n\(reason)"
        }
        project.tasks[rootIndex] = rootTask

        var blockedDownstreamTaskIDs: [String] = []
        if let swarmID = rootTask.swarmId,
           let failedTaskID,
           let failedIndex = project.tasks.firstIndex(where: { $0.id == failedTaskID }),
           let failedSwarmTaskID = project.tasks[failedIndex].swarmTaskId {
            project.tasks[failedIndex] = markSwarmTaskBlocked(
                project.tasks[failedIndex],
                reasonLine: "Swarm failed: \(reason)"
            )

            let swarmChildren = project.tasks.filter { $0.swarmId == swarmID && $0.id != rootTaskID }
            let downstreamSwarmTaskIDs = downstreamSwarmTaskIDs(
                from: failedSwarmTaskID,
                children: swarmChildren
            )
            for downstreamSwarmTaskID in downstreamSwarmTaskIDs {
                guard let index = project.tasks.firstIndex(where: {
                    $0.swarmId == swarmID && $0.swarmTaskId == downstreamSwarmTaskID
                }) else {
                    continue
                }
                var task = project.tasks[index]
                guard task.status != "done", task.status != "blocked" else {
                    continue
                }
                task = markSwarmTaskBlocked(
                    task,
                    reasonLine: "Blocked by failed dependency \(failedSwarmTaskID)."
                )
                blockedDownstreamTaskIDs.append(task.id)
                project.tasks[index] = task
            }
        }

        project.updatedAt = Date()
        await store.saveProject(project)

        let failedTask = failedTaskID.flatMap { id in
            project.tasks.first(where: { $0.id == id })
        }
        let escalationChannelID = resolveSwarmEscalationChannelID(
            failedTask: failedTask,
            board: board,
            fallbackChannelID: executionChannelID
        )
        let artifactRefs = failedTask.map { extractArtifactRefs(from: $0.description) } ?? []
        let message =
            """
            Swarm escalation required.
            Root task: \(rootTaskID)
            Failed child: \(failedTaskID ?? "n/a")
            Reason: \(reason)
            Blocked downstream: \(blockedDownstreamTaskIDs.isEmpty ? "none" : blockedDownstreamTaskIDs.joined(separator: ", "))
            Artifacts: \(artifactRefs.isEmpty ? "none" : artifactRefs.joined(separator: ", "))
            Action: Please review and unblock the task.
            """

        let logMessage: String
        if blockedDownstreamTaskIDs.isEmpty {
            logMessage = reason
        } else {
            logMessage = "\(reason) Downstream blocked: \(blockedDownstreamTaskIDs.count)."
        }

        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: rootTaskID,
            stage: "swarm_blocked",
            channelID: escalationChannelID,
            workerID: nil,
            message: logMessage,
            artifactPath: artifactRefs.first
        )
        await runtime.appendSystemMessage(channelId: escalationChannelID, content: message)
        await deliverToChannelPlugin(channelId: escalationChannelID, content: message)
    }

    private func markSwarmTaskBlocked(_ task: ProjectTask, reasonLine: String) -> ProjectTask {
        var task = task
        task.status = "blocked"
        task.updatedAt = Date()
        if task.description.isEmpty {
            task.description = reasonLine
        } else if !task.description.contains(reasonLine) {
            task.description += "\n\n\(reasonLine)"
        }
        return task
    }

    private func downstreamSwarmTaskIDs(
        from failedSwarmTaskID: String,
        children: [ProjectTask]
    ) -> Set<String> {
        var dependentsByDependency: [String: Set<String>] = [:]
        for task in children {
            guard let swarmTaskID = task.swarmTaskId else {
                continue
            }
            for dependency in task.swarmDependencyIds ?? [] {
                dependentsByDependency[dependency, default: []].insert(swarmTaskID)
            }
        }

        var queue = Array(dependentsByDependency[failedSwarmTaskID] ?? [])
        var visited: Set<String> = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current).inserted else {
                continue
            }
            queue.append(contentsOf: dependentsByDependency[current] ?? [])
        }
        return visited
    }

    private func resolveSwarmEscalationChannelID(
        failedTask: ProjectTask?,
        board: ActorBoardSnapshot,
        fallbackChannelID: String
    ) -> String {
        let nodesByID = Dictionary(uniqueKeysWithValues: board.nodes.map { ($0.id, $0) })
        if let actorPath = failedTask?.swarmActorPath {
            for actorID in actorPath.reversed() {
                guard let actor = nodesByID[actorID], actor.kind == .human else {
                    continue
                }
                let channelID = normalizeWhitespace(actor.channelId ?? "")
                if !channelID.isEmpty {
                    return channelID
                }
            }
        }

        if let admin = nodesByID["human:admin"] {
            let channelID = normalizeWhitespace(admin.channelId ?? "")
            if !channelID.isEmpty {
                return channelID
            }
        }

        return fallbackChannelID
    }

    private func swarmActorPath(
        rootActorID: String,
        targetActorID: String,
        parentByActor: [String: String]
    ) -> [String] {
        if targetActorID == rootActorID {
            return [rootActorID]
        }

        var path: [String] = [targetActorID]
        var current = targetActorID
        while let parent = parentByActor[current] {
            path.append(parent)
            if parent == rootActorID {
                break
            }
            current = parent
        }
        return path.reversed()
    }

    private func extractArtifactRefs(from description: String) -> [String] {
        description
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.lowercased().hasPrefix("artifact: ") else {
                    return nil
                }
                return String(trimmed.dropFirst("Artifact: ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func resolveTaskDelegation(project: ProjectRecord, task: ProjectTask) async -> TaskDelegation? {
        let board = try? getActorBoard()
        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let routeAllowedActorIDs = routableActorIDs(project: project, task: task, board: board)

        let preferredActors = preferredActorIDs(for: task, board: board)
        for actorID in preferredActors {
            if let routeAllowedActorIDs, !routeAllowedActorIDs.contains(actorID) {
                continue
            }
            guard let node = nodesByID[actorID] else {
                continue
            }

            let channelID = normalizeWhitespace(node.channelId ?? "")
            let resolvedChannelID: String?
            if !channelID.isEmpty {
                resolvedChannelID = channelID
            } else {
                resolvedChannelID = resolveExecutionChannelID(project: project, task: task)
            }

            guard let channel = resolvedChannelID else {
                continue
            }

            return TaskDelegation(
                actorID: actorID,
                agentID: node.linkedAgentId,
                channelID: channel
            )
        }

        if !preferredActors.isEmpty {
            return nil
        }

        if preferredActors.isEmpty,
           let routeAllowedActorIDs,
           !routeAllowedActorIDs.isEmpty {
            for actorID in routeAllowedActorIDs.sorted() {
                guard let node = nodesByID[actorID] else {
                    continue
                }
                let channelID = normalizeWhitespace(node.channelId ?? "")
                let resolvedChannelID: String?
                if !channelID.isEmpty {
                    resolvedChannelID = channelID
                } else {
                    resolvedChannelID = resolveExecutionChannelID(project: project, task: task)
                }

                guard let channel = resolvedChannelID else {
                    continue
                }

                return TaskDelegation(
                    actorID: actorID,
                    agentID: node.linkedAgentId,
                    channelID: channel
                )
            }
        }

        if let fallbackChannelID = resolveExecutionChannelID(project: project, task: task) {
            let fallbackChannelActor = nodesByID.values
                .filter { normalizeWhitespace($0.channelId ?? "") == fallbackChannelID }
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first
            return TaskDelegation(
                actorID: fallbackChannelActor?.id,
                agentID: fallbackChannelActor?.linkedAgentId,
                channelID: fallbackChannelID
            )
        }
        return nil
    }

    private func resolveSwarmTaskDelegation(project: ProjectRecord, task: ProjectTask) async -> TaskDelegation? {
        let board = try? getActorBoard()
        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let actorID = normalizeWhitespace(task.claimedActorId ?? task.actorId ?? "")
        guard !actorID.isEmpty else {
            return nil
        }

        let resolvedNode = nodesByID[actorID]
        let directChannelID = normalizeWhitespace(resolvedNode?.channelId ?? "")
        let channelID = directChannelID.isEmpty
            ? resolveExecutionChannelID(project: project, task: task)
            : directChannelID
        guard let channelID else {
            return nil
        }

        return TaskDelegation(
            actorID: actorID,
            agentID: resolvedNode?.linkedAgentId,
            channelID: channelID
        )
    }

    private func preferredActorIDs(for task: ProjectTask, board: ActorBoardSnapshot?) -> [String] {
        var actorIDs: [String] = []
        var seen: Set<String> = []

        func add(_ actorID: String?) {
            guard let actorID = actorID else {
                return
            }
            let normalized = normalizeWhitespace(actorID)
            guard !normalized.isEmpty else {
                return
            }
            if seen.insert(normalized).inserted {
                actorIDs.append(normalized)
            }
        }

        add(task.actorId)

        if let teamID = task.teamId,
           let team = board?.teams.first(where: { $0.id == teamID }) {
            add(task.claimedActorId)
            for memberActorID in team.memberActorIds {
                add(memberActorID)
            }
        }

        add(task.claimedActorId)
        return actorIDs
    }

    private func routableActorIDs(
        project: ProjectRecord,
        task: ProjectTask,
        board: ActorBoardSnapshot?
    ) -> Set<String>? {
        guard let board else {
            return nil
        }

        guard let sourceChannelID = resolveExecutionChannelID(project: project, task: task) else {
            return nil
        }

        let sourceActorIDs = board.nodes.compactMap { node -> String? in
            let nodeChannelID = normalizeWhitespace(node.channelId ?? "")
            guard nodeChannelID == sourceChannelID else {
                return nil
            }
            return node.id
        }
        guard !sourceActorIDs.isEmpty else {
            return nil
        }

        var hasTaskRoutes = false
        var allowed = Set(sourceActorIDs)
        for sourceActorID in sourceActorIDs {
            let recipients = routeRecipients(
                fromActorID: sourceActorID,
                links: board.links,
                communicationType: .task
            )
            if !recipients.isEmpty {
                hasTaskRoutes = true
            }
            allowed.formUnion(recipients)
        }

        guard hasTaskRoutes else {
            return nil
        }
        return allowed
    }

    private func routeRecipients(
        fromActorID: String,
        links: [ActorLink],
        communicationType: ActorCommunicationType
    ) -> Set<String> {
        var recipients: Set<String> = []

        for link in links {
            guard link.communicationType == communicationType else {
                continue
            }
            if link.sourceActorId == fromActorID {
                recipients.insert(link.targetActorId)
                continue
            }
            if link.direction == .twoWay, link.targetActorId == fromActorID {
                recipients.insert(link.sourceActorId)
            }
        }

        recipients.remove(fromActorID)
        return recipients
    }

    private struct TeamRetryDelegate {
        let actorID: String
        let agentID: String?
    }

    private func nextTeamRetryDelegate(project: ProjectRecord, task: ProjectTask) async -> TeamRetryDelegate? {
        guard let teamID = task.teamId else {
            return nil
        }
        let board = try? getActorBoard()
        guard let team = board?.teams.first(where: { $0.id == teamID }),
              !team.memberActorIds.isEmpty
        else {
            return nil
        }

        guard let currentActorID = task.claimedActorId,
              let currentIndex = team.memberActorIds.firstIndex(of: currentActorID)
        else {
            return nil
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let routeAllowedActorIDs = routableActorIDs(project: project, task: task, board: board)
        for nextIndex in (currentIndex + 1)..<team.memberActorIds.count {
            let nextActorID = team.memberActorIds[nextIndex]
            if let routeAllowedActorIDs, !routeAllowedActorIDs.contains(nextActorID) {
                continue
            }
            guard let node = nodesByID[nextActorID] else {
                continue
            }
            return TeamRetryDelegate(actorID: nextActorID, agentID: node.linkedAgentId)
        }

        return nil
    }

    private func nextTeamHandoffDelegate(project: ProjectRecord, task: ProjectTask) async -> TeamRetryDelegate? {
        guard let teamID = task.teamId else {
            return nil
        }
        let board = try? getActorBoard()
        guard let team = board?.teams.first(where: { $0.id == teamID }),
              !team.memberActorIds.isEmpty
        else {
            return nil
        }

        guard let currentActorID = task.claimedActorId,
              let currentIndex = team.memberActorIds.firstIndex(of: currentActorID)
        else {
            return nil
        }

        let nextIndex = currentIndex + 1
        guard nextIndex < team.memberActorIds.count else {
            return nil
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        let nextActorID = team.memberActorIds[nextIndex]
        guard let node = nodesByID[nextActorID] else {
            return nil
        }
        return TeamRetryDelegate(actorID: nextActorID, agentID: node.linkedAgentId)
    }

    private func extractOriginChannelID(from description: String) -> String? {
        let pattern = #"(?im)^Origin channel:\s*(\S+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsDescription = description as NSString
        let range = NSRange(location: 0, length: nsDescription.length)
        guard let match = regex.firstMatch(in: description, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        let capture = match.range(at: 1)
        guard capture.location != NSNotFound else {
            return nil
        }
        return nsDescription.substring(with: capture)
    }

    private func handleVisorEvent(_ event: EventEnvelope) async {
        switch event.messageType {
        case .branchSpawned:
            await handleBranchSpawned(event)
        case .workerProgress:
            await syncTaskProgressFromWorkerEvent(event: event)
        case .workerCompleted:
            await syncTaskStatusFromWorkerEvent(event: event, nextStatus: "done", failureNote: nil)
        case .workerFailed:
            let errorText = event.payload.objectValue["error"]?.stringValue
            await syncTaskStatusFromWorkerEvent(event: event, nextStatus: "backlog", failureNote: errorText)
        default:
            break
        }
    }

    private func handleBranchSpawned(_ event: EventEnvelope) async {
        var todos = event.extensions["todos"]?.stringArrayValue ?? []
        if todos.isEmpty, let prompt = event.payload.objectValue["prompt"]?.stringValue {
            todos = TodoExtractor.extractCandidates(from: prompt)
        }

        logger.info(
            "visor.todo.extracted",
            metadata: [
                "channel_id": .string(event.channelId),
                "count": .stringConvertible(todos.count)
            ]
        )

        guard !todos.isEmpty else {
            return
        }

        guard var project = await projectForChannel(channelId: event.channelId) else {
            logger.info(
                "visor.todo.extracted",
                metadata: [
                    "channel_id": .string(event.channelId),
                    "count": .string("0"),
                    "skip": .string("project_not_found_for_channel")
                ]
            )
            return
        }

        let activeStatuses = Set(["pending_approval", "backlog", "ready", "in_progress"])
        var existingTitleKeys = Set(
            project.tasks
                .filter { activeStatuses.contains($0.status) }
                .map { normalizedTaskTitleKey($0.title) }
        )
        var createdCount = 0
        var duplicateCount = 0

        for todo in todos {
            let title = summarizedTodoTitle(from: todo)
            let titleKey = normalizedTaskTitleKey(title)
            guard !titleKey.isEmpty else {
                continue
            }
            if existingTitleKeys.contains(titleKey) {
                duplicateCount += 1
                continue
            }

            let now = Date()
            project.tasks.append(
                ProjectTask(
                    id: UUID().uuidString,
                    title: title,
                    description: visorTaskDescription(todo: todo, channelId: event.channelId),
                    priority: "medium",
                    status: "pending_approval",
                    createdAt: now,
                    updatedAt: now
                )
            )
            existingTitleKeys.insert(titleKey)
            createdCount += 1

            logger.info(
                "visor.task.created",
                metadata: [
                    "project_id": .string(project.id),
                    "channel_id": .string(event.channelId),
                    "title": .string(title)
                ]
            )
        }

        guard createdCount > 0 else {
            return
        }

        project.updatedAt = Date()
        await store.saveProject(project)
        _ = await triggerVisorBulletin()
        let visorMessage = "Visor created \(createdCount) tasks pending approval."
        await runtime.appendSystemMessage(channelId: event.channelId, content: visorMessage)
        await deliverToChannelPlugin(channelId: event.channelId, content: visorMessage)

        if duplicateCount > 0 {
            logger.info(
                "visor.todo.extracted",
                metadata: [
                    "channel_id": .string(event.channelId),
                    "duplicate_skipped": .stringConvertible(duplicateCount)
                ]
            )
        }
    }

    private func syncTaskStatusFromWorkerEvent(
        event: EventEnvelope,
        nextStatus: String,
        failureNote: String?
    ) async {
        guard let taskID = event.taskId else {
            return
        }

        let projects = await store.listProjects()
        for var project in projects {
            guard let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID }) else {
                continue
            }

            var task = project.tasks[taskIndex]
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: event.messageType.rawValue,
                channelID: event.channelId,
                workerID: event.workerId,
                message: failureNote ?? "Worker event received.",
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId
            )
            if event.messageType == .workerFailed,
               let retryDelegate = await nextTeamRetryDelegate(project: project, task: task) {
                task.status = "ready"
                task.claimedActorId = retryDelegate.actorID
                task.claimedAgentId = retryDelegate.agentID
                task.actorId = retryDelegate.actorID
                task.updatedAt = Date()
                if let failureNote {
                    let timestamp = ISO8601DateFormatter().string(from: event.ts)
                    let note = "Worker failed at \(timestamp): \(failureNote)"
                    if task.description.isEmpty {
                        task.description = note
                    } else {
                        task.description += "\n\n\(note)"
                    }
                }

                project.tasks[taskIndex] = task
                project.updatedAt = Date()
                await store.saveProject(project)
                appendTaskLifecycleLog(
                    projectID: project.id,
                    taskID: task.id,
                    stage: "retry_ready",
                    channelID: event.channelId,
                    workerID: event.workerId,
                    message: "Retry scheduled with next team member.",
                    actorID: retryDelegate.actorID,
                    agentID: retryDelegate.agentID
                )

                let retryActor = retryDelegate.agentID ?? retryDelegate.actorID
                await runtime.appendSystemMessage(
                    channelId: event.channelId,
                    content: "Retrying task \(task.id) with \(retryActor)."
                )
                await handleTaskBecameReady(projectID: project.id, taskID: task.id)
                return
            }

            var resolvedStatus = nextStatus
            var completionArtifactPath: String?
            if event.messageType == .workerCompleted {
                if let claimedActorID = task.claimedActorId {
                    task.actorId = claimedActorID
                }
                completionArtifactPath = await persistWorkerArtifactForProjectTask(
                    projectID: project.id,
                    taskID: task.id,
                    event: event
                )
                if completionArtifactPath == nil {
                    resolvedStatus = "backlog"
                    let missingArtifactNote = "Worker completed but no artifact was persisted; task moved back to backlog for manual review."
                    if task.description.isEmpty {
                        task.description = missingArtifactNote
                    } else {
                        task.description += "\n\n\(missingArtifactNote)"
                    }
                } else if let completionArtifactPath {
                    let completionLine = "Artifact: \(completionArtifactPath)"
                    if !task.description.contains(completionLine) {
                        if task.description.isEmpty {
                            task.description = completionLine
                        } else {
                            task.description += "\n\n\(completionLine)"
                        }
                    }
                }

                if resolvedStatus == "done",
                   let handoffDelegate = await nextTeamHandoffDelegate(project: project, task: task) {
                    let handoffActor = task.claimedAgentId ?? task.claimedActorId ?? "worker"
                    let handoffNote = "Handoff from \(handoffActor)"
                        + (completionArtifactPath.map { ". Artifact: \($0)" } ?? "")
                    if task.description.isEmpty {
                        task.description = handoffNote
                    } else {
                        task.description += "\n\n\(handoffNote)"
                    }

                    task.status = "ready"
                    task.claimedActorId = handoffDelegate.actorID
                    task.claimedAgentId = handoffDelegate.agentID
                    task.actorId = handoffDelegate.actorID
                    task.updatedAt = Date()
                    project.tasks[taskIndex] = task
                    project.updatedAt = Date()
                    await store.saveProject(project)
                    appendTaskLifecycleLog(
                        projectID: project.id,
                        taskID: task.id,
                        stage: "handoff_ready",
                        channelID: event.channelId,
                        workerID: event.workerId,
                        message: "Handoff to next team member.",
                        actorID: handoffDelegate.actorID,
                        agentID: handoffDelegate.agentID,
                        artifactPath: completionArtifactPath
                    )

                    let nextActor = handoffDelegate.agentID ?? handoffDelegate.actorID
                    let handoffMessage = "Task \(task.id) handed off to \(nextActor)."
                    await runtime.appendSystemMessage(channelId: event.channelId, content: handoffMessage)
                    await deliverToChannelPlugin(channelId: event.channelId, content: handoffMessage)
                    await handleTaskBecameReady(projectID: project.id, taskID: task.id)
                    return
                }
            }

            task.status = resolvedStatus
            task.updatedAt = Date()
            if let failureNote {
                let timestamp = ISO8601DateFormatter().string(from: event.ts)
                let note = "Worker failed at \(timestamp): \(failureNote)"
                if task.description.isEmpty {
                    task.description = note
                } else {
                    task.description += "\n\n\(note)"
                }
            }
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "status_synced",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Task status set to \(resolvedStatus).",
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId,
                artifactPath: completionArtifactPath
            )

            if event.messageType == .workerCompleted {
                let completionActor = task.claimedAgentId ?? task.claimedActorId ?? "worker"
                let completionSuffix: String
                if let completionArtifactPath {
                    completionSuffix = " Artifact: \(completionArtifactPath)"
                } else {
                    completionSuffix = " Artifact missing; task returned to backlog."
                }
                await runtime.appendSystemMessage(
                    channelId: event.channelId,
                    content: "\(completionActor) completed task \(task.id).\(completionSuffix)"
                )
            } else if event.messageType == .workerFailed {
                let failedActor = task.claimedAgentId ?? task.claimedActorId ?? "worker"
                await runtime.appendSystemMessage(
                    channelId: event.channelId,
                    content: "\(failedActor) failed task \(task.id); moved back to backlog."
                )
            }

            let statusMessage: String
            if nextStatus == "done" {
                statusMessage = "Task \(task.id) completed."
            } else if failureNote != nil {
                statusMessage = "Task \(task.id) failed; moved back to backlog."
            } else {
                statusMessage = "Task \(task.id) status changed to \(nextStatus)."
            }
            await runtime.appendSystemMessage(channelId: event.channelId, content: statusMessage)
            await deliverToChannelPlugin(channelId: event.channelId, content: statusMessage)

            logger.info(
                "visor.task.synced_from_worker_event",
                metadata: [
                    "project_id": .string(project.id),
                    "task_id": .string(task.id),
                    "event_type": .string(event.messageType.rawValue),
                    "status": .string(resolvedStatus)
                ]
            )
            return
        }
    }

    private func syncTaskProgressFromWorkerEvent(event: EventEnvelope) async {
        guard let taskID = event.taskId else {
            return
        }
        let progress = event.payload.objectValue["progress"]?.stringValue ?? "progress"

        let projects = await store.listProjects()
        for project in projects {
            guard project.tasks.contains(where: { $0.id == taskID }) else {
                continue
            }

            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: taskID,
                stage: "worker_progress",
                channelID: event.channelId,
                workerID: event.workerId,
                message: progress
            )
            logger.info(
                "visor.task.progress",
                metadata: [
                    "project_id": .string(project.id),
                    "task_id": .string(taskID),
                    "progress": .string(progress)
                ]
            )
            return
        }
    }

    // MARK: - Project Tools

    private func handleProjectTool(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest
    ) async -> ToolInvocationResult? {
        let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        switch toolID {
        case "project.task_list":
            return await executeTaskList(request: request, sessionID: sessionID)
        case "project.task_create":
            return await executeTaskCreate(request: request, sessionID: sessionID)
        case "project.task_get":
            return await executeTaskGet(request: request, sessionID: sessionID)
        case "project.escalate_to_user":
            return await executeEscalateToUser(request: request, sessionID: sessionID)
        case "actor.discuss_with_actor":
            return await executeDiscussWithActor(request: request)
        case "actor.conclude_discussion":
            return executeConcludeDiscussion(request: request)
        default:
            return nil
        }
    }

    private func executeTaskList(request: ToolInvocationRequest, sessionID: String) async -> ToolInvocationResult {
        let channelId = request.arguments["channelId"]?.asString ?? sessionID
        let statusFilter = request.arguments["status"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let topicId = request.arguments["topicId"]?.asString

        guard let project = await projectForChannel(channelId: channelId, topicId: topicId) else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "project_not_found", message: "No project found for this channel.", retryable: false)
            )
        }

        var tasks = project.tasks
        if let statusFilter, !statusFilter.isEmpty {
            tasks = tasks.filter { $0.status == statusFilter }
        }

        let items: [JSONValue] = tasks.map { task in
            .object([
                "id": .string(task.id),
                "title": .string(task.title),
                "status": .string(task.status),
                "priority": .string(task.priority),
                "actorId": task.actorId.map { .string($0) } ?? .null,
                "teamId": task.teamId.map { .string($0) } ?? .null,
                "claimedActorId": task.claimedActorId.map { .string($0) } ?? .null
            ])
        }

        return .init(tool: request.tool, ok: true, data: .object([
            "projectId": .string(project.id),
            "projectName": .string(project.name),
            "tasks": .array(items)
        ]))
    }

    private func executeTaskCreate(request: ToolInvocationRequest, sessionID: String) async -> ToolInvocationResult {
        let channelId = request.arguments["channelId"]?.asString ?? sessionID
        let topicId = request.arguments["topicId"]?.asString
        let title = request.arguments["title"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = request.arguments["description"]?.asString
        let priority = request.arguments["priority"]?.asString ?? "medium"
        let status = request.arguments["status"]?.asString ?? "pending_approval"
        let actorId = request.arguments["actorId"]?.asString
        let teamId = request.arguments["teamId"]?.asString

        guard !title.isEmpty else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "invalid_arguments", message: "`title` is required.", retryable: false)
            )
        }

        guard let project = await projectForChannel(channelId: channelId, topicId: topicId) else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "project_not_found", message: "No project found for this channel.", retryable: false)
            )
        }

        do {
            let updated = try await createProjectTask(
                projectID: project.id,
                request: ProjectTaskCreateRequest(
                    title: title,
                    description: description,
                    priority: priority,
                    status: status,
                    actorId: actorId,
                    teamId: teamId
                )
            )
            let created = updated.tasks.last
            return .init(tool: request.tool, ok: true, data: .object([
                "projectId": .string(updated.id),
                "taskId": .string(created?.id ?? ""),
                "title": .string(created?.title ?? title),
                "status": .string(created?.status ?? status)
            ]))
        } catch {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "create_failed", message: "Failed to create task.", retryable: true)
            )
        }
    }

    private func executeTaskGet(request: ToolInvocationRequest, sessionID: String) async -> ToolInvocationResult {
        let rawReference = request.arguments["taskId"]?.asString
            ?? request.arguments["reference"]?.asString
            ?? ""
        let fallbackChannelId = request.arguments["channelId"]?.asString ?? sessionID

        guard let normalizedReference = normalizeTaskReference(rawReference) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(
                    code: "invalid_arguments",
                    message: "`taskId` (or `reference`) is required. Example: MOBILE-1",
                    retryable: false
                )
            )
        }

        do {
            let record = try await getProjectTask(taskReference: normalizedReference)
            return .init(tool: request.tool, ok: true, data: .object([
                "projectId": .string(record.projectId),
                "projectName": .string(record.projectName),
                "task": jsonValue(for: record.task),
                "taskId": .string(record.task.id)
            ]))
        } catch ProjectError.notFound {
            return .init(
                tool: request.tool,
                ok: false,
                data: .object([
                    "channelId": .string(fallbackChannelId),
                    "taskId": .string(normalizedReference)
                ]),
                error: .init(
                    code: "task_not_found",
                    message: "Task `\(normalizedReference)` was not found.",
                    retryable: false
                )
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "read_failed", message: "Failed to fetch task details.", retryable: true)
            )
        }
    }

    private func executeEscalateToUser(request: ToolInvocationRequest, sessionID: String) async -> ToolInvocationResult {
        let channelId = request.arguments["channelId"]?.asString ?? sessionID
        let reason = request.arguments["reason"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Escalation requested"
        let taskId = request.arguments["taskId"]?.asString

        let message = "Escalation: \(reason)"
        await runtime.appendSystemMessage(channelId: channelId, content: message)
        await deliverToChannelPlugin(channelId: channelId, content: message)

        if let taskId {
            let topicId = request.arguments["topicId"]?.asString
            if let project = await projectForChannel(channelId: channelId, topicId: topicId) {
                _ = try? await updateProjectTask(
                    projectID: project.id,
                    taskID: taskId,
                    request: ProjectTaskUpdateRequest(status: "blocked")
                )
            }
        }

        logger.info(
            "tool.escalate_to_user",
            metadata: [
                "channel_id": .string(channelId),
                "reason": .string(reason),
                "task_id": .string(taskId ?? "")
            ]
        )

        return .init(tool: request.tool, ok: true, data: .object([
            "escalated": .bool(true),
            "channelId": .string(channelId),
            "reason": .string(reason)
        ]))
    }

    // MARK: - LLM-to-LLM Discussion Tools

    private func executeDiscussWithActor(request: ToolInvocationRequest) async -> ToolInvocationResult {
        let targetActorId = request.arguments["actorId"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topic = request.arguments["topic"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = request.arguments["message"]?.asString ?? ""
        let taskId = request.arguments["taskId"]?.asString

        guard !targetActorId.isEmpty else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "invalid_arguments", message: "`actorId` is required.", retryable: false)
            )
        }
        guard !message.isEmpty else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "invalid_arguments", message: "`message` is required.", retryable: false)
            )
        }

        let board = try? getActorBoard()
        guard let targetNode = board?.nodes.first(where: { $0.id == targetActorId }) else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "actor_not_found", message: "Target actor '\(targetActorId)' not found on board.", retryable: false)
            )
        }

        let hasDiscussionLink = board?.links.contains(where: { link in
            link.communicationType == .discussion &&
            (link.sourceActorId == targetActorId || link.targetActorId == targetActorId ||
             (link.direction == .twoWay && (link.sourceActorId == targetActorId || link.targetActorId == targetActorId)))
        }) ?? false

        let hasChatLink = board?.links.contains(where: { link in
            (link.communicationType == .discussion || link.communicationType == .chat) &&
            (link.sourceActorId == targetActorId || link.targetActorId == targetActorId)
        }) ?? false

        guard hasDiscussionLink || hasChatLink else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "no_discussion_link", message: "No discussion or chat link to actor '\(targetActorId)'.", retryable: false)
            )
        }

        let discussionChannelId = "discussion:\(UUID().uuidString.prefix(8))"
        let prompt = """
            [actor_discussion_v1]
            You are \(targetNode.displayName) (role: \(targetNode.role ?? "unspecified")).
            Another actor wants to discuss: \(topic.isEmpty ? "(no topic)" : topic)
            \(taskId.map { "Related task: \($0)" } ?? "")

            Their message:
            \(message)

            Respond concisely. Focus on your area of expertise.
            """

        let decision = await runtime.postMessage(
            channelId: discussionChannelId,
            request: ChannelMessageRequest(userId: "actor", content: prompt)
        )

        let snapshot = await runtime.channelState(channelId: discussionChannelId)
        let response = snapshot?.messages.last(where: { $0.userId == "system" })?.content
            ?? "Discussion initiated with \(targetNode.displayName)."

        await runtime.eventBus.publish(
            EventEnvelope(
                messageType: .actorDiscussionStarted,
                channelId: discussionChannelId,
                payload: .object([
                    "targetActorId": .string(targetActorId),
                    "topic": .string(topic),
                    "message": .string(message)
                ])
            )
        )

        logger.info(
            "actor.discussion.started",
            metadata: [
                "target_actor_id": .string(targetActorId),
                "discussion_channel": .string(discussionChannelId),
                "topic": .string(topic),
                "route_action": .string(decision.action.rawValue)
            ]
        )

        return .init(tool: request.tool, ok: true, data: .object([
            "discussionChannelId": .string(discussionChannelId),
            "targetActorId": .string(targetActorId),
            "targetActorName": .string(targetNode.displayName),
            "response": .string(response)
        ]))
    }

    private func executeConcludeDiscussion(request: ToolInvocationRequest) -> ToolInvocationResult {
        let discussionChannelId = request.arguments["discussionChannelId"]?.asString ?? ""
        let summary = request.arguments["summary"]?.asString ?? "Discussion concluded."

        guard !discussionChannelId.isEmpty else {
            return .init(
                tool: request.tool, ok: false,
                error: .init(code: "invalid_arguments", message: "`discussionChannelId` is required.", retryable: false)
            )
        }

        logger.info(
            "actor.discussion.concluded",
            metadata: [
                "discussion_channel": .string(discussionChannelId),
                "summary": .string(summary)
            ]
        )

        return .init(tool: request.tool, ok: true, data: .object([
            "discussionChannelId": .string(discussionChannelId),
            "concluded": .bool(true),
            "summary": .string(summary)
        ]))
    }

    private func projectForChannel(channelId: String, topicId: String? = nil) async -> ProjectRecord? {
        let projects = await store.listProjects()
        if let topicId, !topicId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let compositeId = "\(channelId):\(topicId)"
            if let found = projects
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first(where: { project in
                    project.channels.contains(where: { $0.channelId == compositeId })
                }) {
                return found
            }
        }
        return projects
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first(where: { project in
                project.channels.contains(where: { $0.channelId == channelId })
            })
    }

    private func resolveTask(reference: TaskApprovalReference, in project: ProjectRecord) -> ProjectTask? {
        switch reference {
        case .taskID(let taskID):
            let lowercasedTaskID = taskID.lowercased()
            return project.tasks.first(where: { task in
                task.id == taskID || task.id.lowercased() == lowercasedTaskID
            })
        case .index(let oneBasedIndex):
            guard oneBasedIndex > 0 else {
                return nil
            }
            let ordered = project.tasks.sorted(by: { $0.createdAt < $1.createdAt })
            let zeroBasedIndex = oneBasedIndex - 1
            guard ordered.indices.contains(zeroBasedIndex) else {
                return nil
            }
            return ordered[zeroBasedIndex]
        }
    }

    private func summarizedTodoTitle(from todo: String) -> String {
        let normalized = normalizeWhitespace(todo)
        if normalized.isEmpty {
            return "Visor task"
        }

        let separators = CharacterSet(charactersIn: "\n.;:")
        if let splitRange = normalized.rangeOfCharacter(from: separators) {
            let prefix = normalizeWhitespace(String(normalized[..<splitRange.lowerBound]))
            if prefix.count >= 6 {
                return String(prefix.prefix(120))
            }
        }

        return String(normalized.prefix(120))
    }

    private func visorTaskDescription(todo: String, channelId: String) -> String {
        var lines: [String] = [
            "Source: visor-auto",
            "Origin channel: \(channelId)",
            "",
            "Todo: \(normalizeWhitespace(todo))"
        ]

        let subtasks = extractSubtasks(from: todo)
        if subtasks.count > 1 {
            lines.append("")
            lines.append(contentsOf: subtasks.map { "- [ ] \($0)" })
        }

        return normalizeTaskDescription(lines.joined(separator: "\n"))
    }

    private func extractSubtasks(from todo: String) -> [String] {
        var seen: Set<String> = []
        var subtasks: [String] = []

        for rawLine in todo.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let checklist = captureGroup(line, pattern: #"(?i)^[-*]\s*\[\s*\]\s*(.+)$"#) {
                let value = normalizeWhitespace(checklist)
                let key = value.lowercased()
                if value.count >= 3, seen.insert(key).inserted {
                    subtasks.append(value)
                }
            } else if let bullet = captureGroup(line, pattern: #"^[-*]\s+(.+)$"#) {
                let value = normalizeWhitespace(bullet)
                let key = value.lowercased()
                if value.count >= 3, seen.insert(key).inserted {
                    subtasks.append(value)
                }
            }
        }

        if subtasks.count > 1 {
            return subtasks
        }

        let segments = todo
            .split(separator: ";")
            .map { normalizeWhitespace(String($0)) }
            .filter { $0.count >= 3 }
        if segments.count > 1 {
            return Array(segments.prefix(8))
        }

        return []
    }

    private func normalizedTaskTitleKey(_ value: String) -> String {
        normalizeWhitespace(value).lowercased()
    }

    private func heartbeatSessionTitle(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Heartbeat \(formatter.string(from: date))"
    }

    private func heartbeatPrompt(markdown: String) -> String {
        """
        [heartbeat_v1]
        Review the HEARTBEAT.md checklist below.

        Rules:
        - If every requested item is already completed, verified, or there is nothing actionable, respond with exactly \(Self.heartbeatSuccessToken)
        - If anything is missing, failed, blocked, or cannot be verified, respond with one short plain-text problem description
        - Do not return markdown fences
        - Do not include any extra commentary when returning \(Self.heartbeatSuccessToken)

        [HEARTBEAT.md]
        \(markdown)
        """
    }

    private func latestAssistantText(from events: [AgentSessionEvent]) -> String {
        for event in events.reversed() {
            guard event.type == .message, let message = event.message, message.role == .assistant else {
                continue
            }
            return plainText(from: message)
        }
        return ""
    }

    private func plainText(from message: AgentSessionMessage) -> String {
        message.segments.compactMap { segment in
            switch segment.kind {
            case .text, .thinking:
                return segment.text
            case .attachment:
                return nil
            }
        }.joined(separator: "\n")
    }

    private func heartbeatFailureMessage(
        assistantText: String,
        runStatus: AgentRunStatusEvent?
    ) -> String {
        if let runStatus, runStatus.stage == .interrupted {
            let details = normalizeWhitespace(runStatus.details ?? "")
            if !details.isEmpty {
                return details
            }
        }

        let normalizedAssistant = normalizeWhitespace(assistantText)
        if !normalizedAssistant.isEmpty {
            return normalizedAssistant
        }

        return "Heartbeat did not return \(Self.heartbeatSuccessToken)."
    }

    private func notifyHeartbeatFailure(agentID: String, message: String) async {
        let notification = "HEARTBEAT failed for agent \(agentID): \(message)"
        if let channelID = heartbeatNotificationChannelID(agentID: agentID) {
            await runtime.appendSystemMessage(channelId: channelID, content: notification)
            await deliverToChannelPlugin(channelId: channelID, content: notification)
            return
        }

        logger.warning("\(notification)")
    }

    private func heartbeatNotificationChannelID(agentID: String) -> String? {
        guard let board = try? getActorBoard() else {
            return nil
        }

        return board.nodes
            .filter { normalizeWhitespace($0.linkedAgentId ?? "") == agentID }
            .sorted(by: { $0.createdAt < $1.createdAt })
            .compactMap { node in
                let channelID = normalizeWhitespace(node.channelId ?? "")
                return channelID.isEmpty ? nil : channelID
            }
            .first
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func captureGroup(_ source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        guard let match = regex.firstMatch(in: source, options: [], range: fullRange),
              match.numberOfRanges > 1
        else {
            return nil
        }

        let range = match.range(at: 1)
        guard range.location != NSNotFound else {
            return nil
        }
        return nsSource.substring(with: range)
    }

    private func extractTaskReferences(from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"#([A-Za-z0-9._-]+-\d+)"#) else {
            return []
        }

        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = regex.matches(in: content, options: [], range: range)
        guard !matches.isEmpty else {
            return []
        }

        var unique: Set<String> = []
        var ordered: [String] = []
        for match in matches where match.numberOfRanges > 1 {
            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound else {
                continue
            }

            let token = nsContent.substring(with: tokenRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                continue
            }

            let normalizedToken = token.uppercased()
            if unique.insert(normalizedToken).inserted {
                ordered.append(normalizedToken)
            }
        }
        return ordered
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
        let allowed = Set(["pending_approval", "backlog", "ready", "in_progress", "done", "blocked", "needs_review"])
        guard allowed.contains(value) else {
            throw ProjectError.invalidPayload
        }
        return value
    }

    private func normalizeOptionalTaskActorID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let normalized = normalizedActorEntityID(trimmed) else {
            throw ProjectError.invalidPayload
        }
        return normalized
    }

    private func normalizeOptionalTaskTeamID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let normalized = normalizedActorEntityID(trimmed) else {
            throw ProjectError.invalidPayload
        }
        return normalized
    }

    private func normalizeTaskReference(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let token = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return normalizedEntityID(token)
    }

    private func nextProjectTaskID(for project: ProjectRecord) -> String {
        let prefix = projectTaskIDPrefix(for: project)
        let taskPrefix = "\(prefix)-"
        let maxSequence = project.tasks.reduce(0) { partial, task in
            max(partial, taskSequenceNumber(taskID: task.id, prefix: taskPrefix) ?? 0)
        }
        return "\(prefix)-\(maxSequence + 1)"
    }

    private func projectTaskIDPrefix(for project: ProjectRecord) -> String {
        var candidates: [String] = []
        if !isLikelyUUID(project.id) {
            candidates.append(project.id)
        }
        candidates.append(project.name)
        if isLikelyUUID(project.id) {
            candidates.append(project.id)
        }

        for candidate in candidates {
            let normalized = normalizeTaskPrefix(candidate)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return "PROJECT"
    }

    private func taskSequenceNumber(taskID: String, prefix: String) -> Int? {
        let uppercased = taskID.uppercased()
        guard uppercased.hasPrefix(prefix) else {
            return nil
        }

        let suffix = String(uppercased.dropFirst(prefix.count))
        guard !suffix.isEmpty,
              suffix.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil
        else {
            return nil
        }
        return Int(suffix)
    }

    private func normalizeTaskPrefix(_ raw: String) -> String {
        let uppercased = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !uppercased.isEmpty else {
            return ""
        }

        let compacted = uppercased.replacingOccurrences(
            of: #"[^A-Z0-9]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = compacted.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(80))
    }

    private func isLikelyUUID(_ raw: String) -> Bool {
        raw.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private func jsonValue(for task: ProjectTask) -> JSONValue {
        .object([
            "id": .string(task.id),
            "title": .string(task.title),
            "description": .string(task.description),
            "priority": .string(task.priority),
            "status": .string(task.status),
            "actorId": task.actorId.map { .string($0) } ?? .null,
            "teamId": task.teamId.map { .string($0) } ?? .null,
            "claimedActorId": task.claimedActorId.map { .string($0) } ?? .null,
            "claimedAgentId": task.claimedAgentId.map { .string($0) } ?? .null,
            "swarmId": task.swarmId.map { .string($0) } ?? .null,
            "swarmTaskId": task.swarmTaskId.map { .string($0) } ?? .null,
            "swarmParentTaskId": task.swarmParentTaskId.map { .string($0) } ?? .null,
            "swarmDependencyIds": task.swarmDependencyIds.map { .array($0.map { .string($0) }) } ?? .null,
            "swarmDepth": task.swarmDepth.map { .number(Double($0)) } ?? .null,
            "swarmActorPath": task.swarmActorPath.map { .array($0.map { .string($0) }) } ?? .null,
            "createdAt": .string(ISO8601DateFormatter().string(from: task.createdAt)),
            "updatedAt": .string(ISO8601DateFormatter().string(from: task.updatedAt))
        ])
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

    private func projectDirectoryURL(projectID: String) -> URL {
        workspaceRootURL
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
    }

    private func projectArtifactsDirectoryURL(projectID: String) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent("artifacts", isDirectory: true)
    }

    private func projectLogsDirectoryURL(projectID: String) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent("logs", isDirectory: true)
    }

    private func projectTaskLogFileURL(projectID: String, taskID: String) -> URL {
        projectLogsDirectoryURL(projectID: projectID).appendingPathComponent("task-\(taskID).log")
    }

    private func relativePathFromWorkspace(_ url: URL) -> String {
        let workspacePath = workspaceRootURL.path
        let targetPath = url.path
        if targetPath.hasPrefix(workspacePath) {
            let suffix = targetPath.dropFirst(workspacePath.count)
            return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        }
        return targetPath
    }

    private func buildWorkerObjective(task: ProjectTask, projectID: String) -> String {
        var bodyLines: [String] = [
            "Task title: \(task.title)"
        ]
        if !task.description.isEmpty {
            bodyLines.append("")
            bodyLines.append("Task details:")
            bodyLines.append(task.description)
        }
        let artifactDirectory = projectArtifactsDirectoryURL(projectID: projectID).path
        let objective = [
            bodyLines.joined(separator: "\n"),
            "",
            "Execution policy:",
            "- Store all created files and artifacts under: \(artifactDirectory)",
            "- Keep completion output concise and reference produced artifact paths."
        ].joined(separator: "\n")
        return normalizeTaskDescription(objective)
    }

    private func appendTaskLifecycleLog(
        projectID: String,
        taskID: String,
        stage: String,
        channelID: String?,
        workerID: String?,
        message: String,
        actorID: String? = nil,
        agentID: String? = nil,
        artifactPath: String? = nil
    ) {
        ensureProjectWorkspaceDirectory(projectID: projectID)
        let logURL = projectTaskLogFileURL(projectID: projectID, taskID: taskID)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeStage = normalizeWhitespace(stage)
        let safeMessage = normalizeWhitespace(message)

        var line = "[\(timestamp)] stage=\(safeStage)"
        line += " task=\(taskID)"
        if let channelID, !channelID.isEmpty {
            line += " channel=\(channelID)"
        }
        if let workerID, !workerID.isEmpty {
            line += " worker=\(workerID)"
        }
        if let actorID, !actorID.isEmpty {
            line += " actor=\(actorID)"
        }
        if let agentID, !agentID.isEmpty {
            line += " agent=\(agentID)"
        }
        if let artifactPath, !artifactPath.isEmpty {
            line += " artifact=\(artifactPath)"
        }
        line += " message=\(safeMessage)\n"

        let payload = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                try handle.close()
                return
            } catch {
                logger.warning(
                    "visor.task.log_append_failed",
                    metadata: [
                        "project_id": .string(projectID),
                        "task_id": .string(taskID),
                        "path": .string(logURL.path)
                    ]
                )
            }
        }

        do {
            try payload.write(to: logURL, options: .atomic)
        } catch {
            logger.warning(
                "visor.task.log_write_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "task_id": .string(taskID),
                    "path": .string(logURL.path)
                ]
            )
        }
    }

    private func persistWorkerArtifactForProjectTask(
        projectID: String,
        taskID: String,
        event: EventEnvelope
    ) async -> String? {
        guard let artifactID = event.payload.objectValue["artifactId"]?.stringValue,
              !artifactID.isEmpty
        else {
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_missing_id",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Worker completed without artifactId."
            )
            return nil
        }

        let artifactContent: String?
        if let runtimeArtifact = await runtime.artifactContent(id: artifactID) {
            artifactContent = runtimeArtifact
            await store.persistArtifact(id: artifactID, content: runtimeArtifact)
        } else {
            artifactContent = await store.artifactContent(id: artifactID)
        }

        guard let artifactContent, !artifactContent.isEmpty else {
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_missing_content",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Artifact payload not found for id \(artifactID)."
            )
            return nil
        }

        if let referencedPath = extractCreatedFilePath(from: artifactContent) {
            let referencedURL = URL(fileURLWithPath: referencedPath)
            if FileManager.default.fileExists(atPath: referencedURL.path) {
                let relativePath = relativePathFromWorkspace(referencedURL)
                appendTaskLifecycleLog(
                    projectID: projectID,
                    taskID: taskID,
                    stage: "artifact_referenced",
                    channelID: event.channelId,
                    workerID: event.workerId,
                    message: "Worker reported created file \(referencedPath).",
                    artifactPath: relativePath
                )
                return relativePath
            }
        }

        ensureProjectWorkspaceDirectory(projectID: projectID)
        let artifactURL = projectArtifactsDirectoryURL(projectID: projectID)
            .appendingPathComponent("task-\(taskID)-\(artifactID).txt")
        do {
            try artifactContent.write(to: artifactURL, atomically: true, encoding: .utf8)
            let relativePath = relativePathFromWorkspace(artifactURL)
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_persisted",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Persisted worker artifact \(artifactID).",
                artifactPath: relativePath
            )
            return relativePath
        } catch {
            logger.warning(
                "visor.task.artifact_write_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "task_id": .string(taskID),
                    "artifact_id": .string(artifactID),
                    "path": .string(artifactURL.path)
                ]
            )
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_write_failed",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Failed to persist artifact \(artifactID)."
            )
            return nil
        }
    }

    private func extractCreatedFilePath(from content: String) -> String? {
        if let value = captureGroup(
            content,
            pattern: #"(?im)^Created file at\s+(.+?)\s*$"#
        ) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func ensureProjectWorkspaceDirectory(projectID: String) {
        let directories = [
            projectDirectoryURL(projectID: projectID),
            projectArtifactsDirectoryURL(projectID: projectID),
            projectLogsDirectoryURL(projectID: projectID)
        ]
        do {
            for directory in directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            logger.warning(
                "visor.project.directory_create_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "path": .string(projectDirectoryURL(projectID: projectID).path)
                ]
            )
        }
    }

    private func availableAgentModels() -> [ProviderModelOption] {
        Self.availableAgentModels(config: currentConfig)
    }

    private static func availableAgentModels(config: CoreConfig) -> [ProviderModelOption] {
        var seen: Set<String> = []
        var options: [ProviderModelOption] = []

        let candidates = CoreModelProviderFactory.resolveModelIdentifiers(config: config) + config.models.map(\.model)
        for raw in candidates {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }

            if seen.insert(value).inserted {
                options.append(Self.providerModelOption(for: value))
            }
        }

        if options.isEmpty {
            options.append(Self.providerModelOption(for: "openai:gpt-4.1-mini"))
        }

        return options
    }

    private static func providerModelOption(for identifier: String) -> ProviderModelOption {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID: String
        if let separatorIndex = trimmed.firstIndex(of: ":") {
            modelID = String(trimmed[trimmed.index(after: separatorIndex)...])
        } else {
            modelID = trimmed
        }

        let lowered = modelID.lowercased()
        var capabilities: [String] = []
        var contextWindow: String?

        if lowered.hasPrefix("gpt-4.1") {
            capabilities.append("tools")
            contextWindow = "1.0M"
        } else if lowered.hasPrefix("gpt-4o") {
            capabilities.append("tools")
            contextWindow = "128K"
        } else if lowered.hasPrefix("o4") || lowered.hasPrefix("o3") {
            capabilities.append(contentsOf: ["reasoning", "tools"])
            contextWindow = "200K"
        } else if lowered.hasPrefix("o1") {
            capabilities.append(contentsOf: ["reasoning", "tools"])
            contextWindow = "128K"
        }

        return ProviderModelOption(
            id: trimmed,
            title: trimmed,
            contextWindow: contextWindow,
            capabilities: capabilities
        )
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

    private func mapAgentToolsError(_ error: Error) -> AgentToolsError {
        guard let storeError = error as? AgentToolsFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidAgentID:
            return .invalidAgentID
        case .invalidPayload:
            return .invalidPayload
        case .agentNotFound:
            return .agentNotFound
        case .storageFailure:
            return .storageFailure
        }
    }

    private func mapActorBoardError(_ error: Error) -> ActorBoardError {
        if let actorBoardError = error as? ActorBoardError {
            return actorBoardError
        }

        guard let storeError = error as? ActorBoardFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidPayload:
            return .invalidPayload
        case .actorNotFound:
            return .actorNotFound
        case .storageFailure:
            return .storageFailure
        }
    }

    private func updateActorBoardSnapshot(
        nodes: [ActorNode],
        links: [ActorLink],
        teams: [ActorTeam],
        agents: [AgentSummary]
    ) throws -> ActorBoardSnapshot {
        do {
            return try actorBoardStore.saveBoard(
                ActorBoardUpdateRequest(nodes: nodes, links: links, teams: teams),
                agents: agents
            )
        } catch {
            throw mapActorBoardError(error)
        }
    }

    private func isProtectedSystemActorID(_ id: String) -> Bool {
        id == "human:admin" || id.hasPrefix("agent:")
    }

    private func normalizedActorEntityID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }

        guard trimmed.count <= 180 else {
            return nil
        }

        return trimmed
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

    private func allAgentMemoryEntries(agentID: String) async -> [MemoryEntry] {
        let entries = await memoryStore.entries(filter: .default)
        return entries
            .filter { belongsToAgentMemory($0, agentID: agentID) }
            .sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.id.localizedCaseInsensitiveCompare(right.id) == .orderedAscending
                }
                return left.createdAt > right.createdAt
            }
    }

    private func matchingAgentMemoryEntries(
        agentID: String,
        search: String?,
        filter: AgentMemoryFilter
    ) async -> [MemoryEntry] {
        filterAgentMemoryEntries(await allAgentMemoryEntries(agentID: agentID), search: search, filter: filter)
    }

    private func filterAgentMemoryEntries(
        _ entries: [MemoryEntry],
        search: String?,
        filter: AgentMemoryFilter
    ) -> [MemoryEntry] {
        let normalizedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        return entries.filter { entry in
            guard matchesAgentMemoryFilter(entry, filter: filter) else {
                return false
            }

            guard !normalizedSearch.isEmpty else {
                return true
            }

            return entry.id.lowercased().contains(normalizedSearch) ||
                entry.note.lowercased().contains(normalizedSearch) ||
                (entry.summary?.lowercased().contains(normalizedSearch) ?? false)
        }
    }

    private func belongsToAgentMemory(_ entry: MemoryEntry, agentID: String) -> Bool {
        if entry.scope.type == .agent, entry.scope.id.caseInsensitiveCompare(agentID) == .orderedSame {
            return true
        }

        guard entry.scope.type == .channel else {
            return false
        }

        let channelID = entry.scope.channelId ?? entry.scope.id
        return channelID.hasPrefix("agent:\(agentID):session:")
    }

    private func matchesAgentMemoryFilter(_ entry: MemoryEntry, filter: AgentMemoryFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .persistent:
            return derivedCategory(for: entry) == .persistent
        case .temporary:
            return derivedCategory(for: entry) == .temporary
        case .todo:
            return derivedCategory(for: entry) == .todo
        }
    }

    private func derivedCategory(for entry: MemoryEntry) -> AgentMemoryCategory {
        if entry.kind == .todo {
            return .todo
        }

        switch entry.memoryClass {
        case .semantic, .procedural:
            return .persistent
        case .episodic, .bulletin:
            return .temporary
        }
    }

    private func makeAgentMemoryItem(from entry: MemoryEntry) -> AgentMemoryItem {
        AgentMemoryItem(
            id: entry.id,
            note: entry.note,
            summary: entry.summary,
            kind: entry.kind,
            memoryClass: entry.memoryClass,
            scope: entry.scope,
            source: entry.source,
            importance: entry.importance,
            confidence: entry.confidence,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            expiresAt: entry.expiresAt,
            derivedCategory: derivedCategory(for: entry)
        )
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

    private func waitForStartup() async {
        await recoveryManager.recoverIfNeeded()
        await startEventPersistence()
        await memoryOutboxIndexer?.start()
    }

    /// Subscribes to runtime event stream and persists events in background.
    private func startEventPersistence() async {
        guard eventTask == nil else {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventTask = Task {
                let stream = await runtime.eventBus.subscribe()
                continuation.resume()
                for await event in stream {
                    let enrichedEvent = await eventByInjectingSwarmMetadata(event)
                    await store.persist(event: enrichedEvent)
                    await handleVisorEvent(enrichedEvent)
                    await extractAndPersistTokenUsage(from: enrichedEvent)
                }
            }
        }
    }

    private func eventByInjectingSwarmMetadata(_ event: EventEnvelope) async -> EventEnvelope {
        guard let taskID = event.taskId else {
            return event
        }

        let projects = await store.listProjects()
        var resolvedTask: ProjectTask?
        for project in projects {
            if let task = project.tasks.first(where: { $0.id == taskID }) {
                resolvedTask = task
                break
            }
        }
        guard let task = resolvedTask, let swarmId = task.swarmId else {
            return event
        }

        var envelope = event
        var swarmPayload: [String: JSONValue] = [
            "swarmId": .string(swarmId)
        ]
        if let swarmTaskId = task.swarmTaskId {
            swarmPayload["swarmTaskId"] = .string(swarmTaskId)
        }
        if let swarmParentTaskId = task.swarmParentTaskId {
            swarmPayload["swarmParentTaskId"] = .string(swarmParentTaskId)
        }
        if let dependencyIds = task.swarmDependencyIds, !dependencyIds.isEmpty {
            swarmPayload["swarmDependencyIds"] = .array(dependencyIds.map { .string($0) })
        }
        if let actorPath = task.swarmActorPath, !actorPath.isEmpty {
            swarmPayload["swarmActorPath"] = .array(actorPath.map { .string($0) })
        }

        envelope.extensions["swarm"] = .object(swarmPayload)
        return envelope
    }

    /// Extracts token usage from branch.conclusion and worker.completed events.
    private func extractAndPersistTokenUsage(from event: EventEnvelope) async {
        let tokenUsage: TokenUsage?

        switch event.messageType {
        case .branchConclusion:
            tokenUsage = extractTokenUsageFromBranchConclusion(event)
        case .workerCompleted:
            tokenUsage = extractTokenUsageFromWorkerCompleted(event)
        default:
            tokenUsage = nil
        }

        if let usage = tokenUsage {
            await store.persistTokenUsage(
                channelId: event.channelId,
                taskId: event.taskId,
                usage: usage
            )
        }
    }

    private func extractTokenUsageFromBranchConclusion(_ event: EventEnvelope) -> TokenUsage? {
        guard case .object(let obj) = event.payload else { return nil }

        // Preferred payload shape: branch conclusion itself is in event.payload.
        if let usage = tokenUsage(fromObjectField: obj["tokenUsage"]) {
            return usage
        }

        // Backward-compatible fallback for nested payloads: { "conclusion": { "tokenUsage": ... } }.
        if case .object(let conclusionObj)? = obj["conclusion"] {
            return tokenUsage(fromObjectField: conclusionObj["tokenUsage"])
        }

        return nil
    }

    private func extractTokenUsageFromWorkerCompleted(_ event: EventEnvelope) -> TokenUsage? {
        guard case .object(let obj) = event.payload else { return nil }
        guard case .object(let resultObj)? = obj["result"] else { return nil }
        return tokenUsage(fromObjectField: resultObj["tokenUsage"])
    }

    private func tokenUsage(fromObjectField field: JSONValue?) -> TokenUsage? {
        guard case .object(let tokenUsageObj)? = field else {
            return nil
        }

        guard case .number(let prompt)? = tokenUsageObj["prompt"],
              case .number(let completion)? = tokenUsageObj["completion"] else {
            return nil
        }

        return TokenUsage(prompt: Int(prompt), completion: Int(completion))
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let object) = self {
            return object
        }
        return [:]
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else {
            return nil
        }
        return values.compactMap { value in
            if case .string(let stringValue) = value {
                return stringValue
            }
            return nil
        }
    }
}

// MARK: - InboundMessageReceiver

private actor ResponseCollector {
    private var value = ""
    func set(_ text: String) { value = text }
    func get() -> String { value }
}

extension CoreService: InboundMessageReceiver {
    /// Called by in-process channel plugins when a message arrives from an external platform.
    /// Routes through the runtime, collects the response, persists to channel session,
    /// and delivers it back to the channel plugin.
    public func postMessage(channelId: String, userId: String, content: String) async -> Bool {
        // Persist user message to channel session
        do {
            try await channelSessionStore.recordUserMessage(
                channelId: channelId,
                userId: userId,
                content: content
            )
        } catch {
            logger.warning("Failed to persist user message to channel session: \(error)")
        }

        let request = ChannelMessageRequest(userId: userId, content: content)
        let collector = ResponseCollector()
        let outboundStreamID = await channelDelivery.beginStream(channelId: channelId, userId: "assistant")

        let onChunk: @Sendable (String) async -> Bool = { chunk in
            await collector.set(chunk)
            if let outboundStreamID {
                _ = await self.channelDelivery.updateStream(id: outboundStreamID, content: chunk)
            }
            return true
        }

        _ = await runtime.postMessage(
            channelId: channelId,
            request: request,
            onResponseChunk: onChunk
        )

        let reply = await collector.get().trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty {
            // Persist assistant response to channel session
            do {
                try await channelSessionStore.recordAssistantMessage(
                    channelId: channelId,
                    content: reply
                )
            } catch {
                logger.warning("Failed to persist assistant message to channel session: \(error)")
            }
        }
        if let outboundStreamID {
            _ = await channelDelivery.endStream(
                id: outboundStreamID,
                finalContent: reply.isEmpty ? nil : reply
            )
        } else if !reply.isEmpty {
            await channelDelivery.deliver(channelId: channelId, userId: "assistant", content: reply)
        }
        return true
    }
}

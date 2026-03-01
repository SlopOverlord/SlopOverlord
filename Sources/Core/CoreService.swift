import Foundation
import AgentRuntime
import Logging
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

    private let runtime: RuntimeSystem
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
    private let logger: Logger
    private let configPath: String
    private var workspaceRootURL: URL
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
        self.workspaceRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
        self.agentsRootURL = self.workspaceRootURL
            .appendingPathComponent("agents", isDirectory: true)
        self.agentCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        self.sessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        self.systemLogStore = SystemLogFileStore(workspaceRootURL: self.workspaceRootURL)
        self.channelDelivery = ChannelDeliveryService(store: self.store)
        self.actorBoardStore = ActorBoardFileStore(workspaceRootURL: self.workspaceRootURL)
        let orchestratorCatalogStore = AgentCatalogFileStore(agentsRootURL: self.agentsRootURL)
        let orchestratorSessionStore = AgentSessionFileStore(agentsRootURL: self.agentsRootURL)
        self.sessionOrchestrator = AgentSessionOrchestrator(
            runtime: self.runtime,
            sessionStore: orchestratorSessionStore,
            agentCatalogStore: orchestratorCatalogStore
        )
        let toolsStore = AgentToolsFileStore(agentsRootURL: self.agentsRootURL)
        self.toolsAuthorization = ToolAuthorizationService(store: toolsStore)
        let processRegistry = SessionProcessRegistry()
        self.toolExecution = ToolExecutionService(
            workspaceRootURL: self.workspaceRootURL,
            runtime: self.runtime,
            sessionStore: self.sessionStore,
            agentCatalogStore: self.agentCatalogStore,
            processRegistry: processRegistry
        )
        self.logger = Logger(label: "slopoverlord.core.visor")
        self.currentConfig = config
        Task { [weak self] in
            guard let self else {
                return
            }
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
        }
        Task {
            await self.startEventPersistence()
        }
    }

    deinit {
        eventTask?.cancel()
    }

    /// Accepts a user channel message and returns routing decision.
    public func postChannelMessage(channelId: String, request: ChannelMessageRequest) async -> ChannelRouteDecision {
        if let approvalReference = TaskApprovalCommandParser.parse(request.content) {
            return await handleTaskApprovalCommand(channelId: channelId, reference: approvalReference)
        }
        return await runtime.postMessage(channelId: channelId, request: request)
    }

    /// Routes interactive message into a running worker.
    public func postChannelRoute(channelId: String, workerId: String, request: ChannelRouteRequest) async -> Bool {
        await runtime.routeMessage(channelId: channelId, workerId: workerId, message: request.message)
    }

    /// Delivers an outbound message to the channel plugin responsible for this channelId.
    @discardableResult
    public func deliverToChannelPlugin(channelId: String, userId: String = "system", content: String) async -> Bool {
        await channelDelivery.deliver(channelId: channelId, userId: userId, content: content)
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
            id: UUID().uuidString,
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
        guard var project = await store.project(id: normalizedProject) else {
            throw ProjectError.notFound
        }
        guard let taskIndex = project.tasks.firstIndex(where: { $0.id == normalizedTask }) else {
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
        if authorization.allowed {
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
        return currentConfig
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

        guard let delegation = await resolveTaskDelegation(project: project, task: task) else {
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

        let activeStatuses = Set(["backlog", "ready", "in_progress"])
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
                    status: "backlog",
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
        let visorMessage = "Visor created \(createdCount) backlog tasks for approval."
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

    private func projectForChannel(channelId: String) async -> ProjectRecord? {
        let projects = await store.listProjects()
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
                await handleVisorEvent(event)
            }
        }
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

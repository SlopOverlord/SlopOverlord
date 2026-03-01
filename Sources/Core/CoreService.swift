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
        project.tasks.append(
            ProjectTask(
                id: UUID().uuidString,
                title: try normalizeTaskTitle(request.title),
                description: normalizeTaskDescription(request.description),
                priority: try normalizeTaskPriority(request.priority),
                status: normalizedStatus,
                createdAt: now,
                updatedAt: now
            )
        )
        project.updatedAt = now
        await store.saveProject(project)
        if normalizedStatus == "ready" {
            _ = await triggerVisorBulletin()
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
        if let status = request.status {
            task.status = try normalizeTaskStatus(status)
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        if previousStatus != "ready", task.status == "ready" {
            _ = await triggerVisorBulletin()
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
            }
        }
    }
}

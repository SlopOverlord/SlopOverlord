import Foundation

public struct ChannelMessageRequest: Codable, Sendable {
    public var userId: String
    public var content: String
    public var topicId: String?
    public var model: String?
    public var reasoningEffort: ReasoningEffort?

    public init(
        userId: String,
        content: String,
        topicId: String? = nil,
        model: String? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.userId = userId
        self.content = content
        self.topicId = topicId
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct ChannelModelResponse: Codable, Sendable {
    public var channelId: String
    public var selectedModel: String?
    public var availableModels: [ProviderModelOption]

    public init(channelId: String, selectedModel: String?, availableModels: [ProviderModelOption]) {
        self.channelId = channelId
        self.selectedModel = selectedModel
        self.availableModels = availableModels
    }
}

public struct ChannelModelUpdateRequest: Codable, Sendable {
    public var model: String

    public init(model: String) {
        self.model = model
    }
}

public struct ChannelControlRequest: Codable, Sendable {
    public var action: AgentRunControlAction
    public var requestedBy: String
    public var reason: String?

    public init(action: AgentRunControlAction, requestedBy: String, reason: String? = nil) {
        self.action = action
        self.requestedBy = requestedBy
        self.reason = reason
    }
}

public struct ChannelControlResponse: Codable, Sendable {
    public var channelId: String
    public var action: AgentRunControlAction
    public var cancelledWorkers: Int
    public var message: String

    public init(channelId: String, action: AgentRunControlAction, cancelledWorkers: Int, message: String) {
        self.channelId = channelId
        self.action = action
        self.cancelledWorkers = cancelledWorkers
        self.message = message
    }
}

public struct ChannelApprovalCodeRequest: Codable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

public struct ChannelRouteRequest: Codable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public struct WorkerCreateRequest: Codable, Sendable {
    public var spec: WorkerTaskSpec

    public init(spec: WorkerTaskSpec) {
        self.spec = spec
    }
}

public struct ArtifactContentResponse: Codable, Sendable {
    public var id: String
    public var content: String

    public init(id: String, content: String) {
        self.id = id
        self.content = content
    }
}

/// Response for channel runtime event feed with pagination cursor.
public struct ChannelEventsResponse: Codable, Sendable, Equatable {
    public var channelId: String
    public var items: [EventEnvelope]
    public var nextCursor: String?

    public init(channelId: String, items: [EventEnvelope], nextCursor: String? = nil) {
        self.channelId = channelId
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum SystemLogLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case trace
    case debug
    case info
    case warning
    case error
    case fatal
}

public struct SystemLogEntry: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var level: SystemLogLevel
    public var label: String
    public var message: String
    public var source: String
    public var metadata: [String: String]

    public init(
        timestamp: Date,
        level: SystemLogLevel,
        label: String,
        message: String,
        source: String = "",
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.label = label
        self.message = message
        self.source = source
        self.metadata = metadata
    }
}

public struct SystemLogsResponse: Codable, Sendable, Equatable {
    public var filePath: String
    public var entries: [SystemLogEntry]

    public init(filePath: String, entries: [SystemLogEntry]) {
        self.filePath = filePath
        self.entries = entries
    }
}

public struct IssueReportRequest: Codable, Sendable, Equatable {
    public var logLimit: Int?

    public init(logLimit: Int? = nil) {
        self.logLimit = logLimit
    }
}

public struct IssueReportResponse: Codable, Sendable, Equatable {
    public var issueUrl: String
    public var logs: String
    public var logEntryCount: Int
    public var redactionCount: Int
    public var truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case issueUrl
        case logs
        case logEntryCount
        case redactionCount
        case truncated
    }

    public init(
        issueUrl: String,
        logs: String,
        logEntryCount: Int,
        redactionCount: Int,
        truncated: Bool
    ) {
        self.issueUrl = issueUrl
        self.logs = logs
        self.logEntryCount = logEntryCount
        self.redactionCount = redactionCount
        self.truncated = truncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueUrl = try container.decode(String.self, forKey: .issueUrl)
        logs = try container.decodeIfPresent(String.self, forKey: .logs) ?? ""
        logEntryCount = try container.decode(Int.self, forKey: .logEntryCount)
        redactionCount = try container.decode(Int.self, forKey: .redactionCount)
        truncated = try container.decode(Bool.self, forKey: .truncated)
    }
}

public struct ProjectChannel: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var channelId: String
    public var createdAt: Date

    public init(id: String, title: String, channelId: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.channelId = channelId
        self.createdAt = createdAt
    }
}

public enum ProjectLoopMode: String, Codable, Sendable, Equatable {
    case human
    case agent
}

public enum ProjectTaskKind: String, Codable, Sendable, Equatable {
    case planning
    case execution
    case bugfix
}

public enum TaskOriginType: String, Codable, Sendable, Equatable {
    case dashboard
    case channel
}

public enum ProjectTaskStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pendingApproval = "pending_approval"
    case backlog
    case ready
    case inProgress = "in_progress"
    case waitingInput = "waiting_input"
    case done
    case blocked
    case needsReview = "needs_review"
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .done, .blocked, .cancelled:
            return true
        case .pendingApproval, .backlog, .ready, .inProgress, .waitingInput, .needsReview:
            return false
        }
    }
}

public enum ProjectTaskCompletionConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case done
    case blocked
    case waitingInput = "waiting_input"
    case unsure
}

public struct ProjectTaskRouteStep: Codable, Sendable, Equatable {
    public var actorId: String?
    public var agentId: String?
    public var reason: String
    public var createdAt: Date

    public init(
        actorId: String? = nil,
        agentId: String? = nil,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.actorId = actorId
        self.agentId = agentId
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct ProjectTask: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var description: String
    public var priority: String
    public var status: String
    public var kind: ProjectTaskKind?
    public var loopModeOverride: ProjectLoopMode?
    public var originType: TaskOriginType?
    public var originChannelId: String?
    public var actorId: String?
    public var teamId: String?
    public var claimedActorId: String?
    public var claimedAgentId: String?
    public var parentTaskId: String?
    public var swarmId: String?
    public var swarmTaskId: String?
    public var swarmParentTaskId: String?
    public var swarmDependencyIds: [String]?
    public var swarmDepth: Int?
    public var swarmActorPath: [String]?
    public var worktreeBranch: String?
    /// When set and present in the agent's available models, overrides the agent default model for this task's worker run.
    public var selectedModel: String?
    public var externalMetadata: TaskExternalMetadata?
    public var tags: [String]
    public var routeHistory: [ProjectTaskRouteStep]
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case priority
        case status
        case kind
        case loopModeOverride
        case originType
        case originChannelId
        case actorId
        case teamId
        case claimedActorId
        case claimedAgentId
        case parentTaskId
        case swarmId
        case swarmTaskId
        case swarmParentTaskId
        case swarmDependencyIds
        case swarmDepth
        case swarmActorPath
        case worktreeBranch
        case selectedModel
        case externalMetadata
        case tags
        case routeHistory
        case isArchived
        case createdAt
        case updatedAt
    }

    public init(
        id: String,
        title: String,
        description: String,
        priority: String,
        status: String,
        kind: ProjectTaskKind? = nil,
        loopModeOverride: ProjectLoopMode? = nil,
        originType: TaskOriginType? = nil,
        originChannelId: String? = nil,
        actorId: String? = nil,
        teamId: String? = nil,
        claimedActorId: String? = nil,
        claimedAgentId: String? = nil,
        parentTaskId: String? = nil,
        swarmId: String? = nil,
        swarmTaskId: String? = nil,
        swarmParentTaskId: String? = nil,
        swarmDependencyIds: [String]? = nil,
        swarmDepth: Int? = nil,
        swarmActorPath: [String]? = nil,
        worktreeBranch: String? = nil,
        selectedModel: String? = nil,
        externalMetadata: TaskExternalMetadata? = nil,
        tags: [String] = [],
        routeHistory: [ProjectTaskRouteStep] = [],
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.kind = kind
        self.loopModeOverride = loopModeOverride
        self.originType = originType
        self.originChannelId = originChannelId
        self.actorId = actorId
        self.teamId = teamId
        self.claimedActorId = claimedActorId
        self.claimedAgentId = claimedAgentId
        self.parentTaskId = parentTaskId
        self.swarmId = swarmId
        self.swarmTaskId = swarmTaskId
        self.swarmParentTaskId = swarmParentTaskId
        self.swarmDependencyIds = swarmDependencyIds
        self.swarmDepth = swarmDepth
        self.swarmActorPath = swarmActorPath
        self.worktreeBranch = worktreeBranch
        self.selectedModel = selectedModel
        self.externalMetadata = externalMetadata
        self.tags = tags
        self.routeHistory = routeHistory
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        priority = try container.decode(String.self, forKey: .priority)
        status = try container.decode(String.self, forKey: .status)
        kind = try container.decodeIfPresent(ProjectTaskKind.self, forKey: .kind)
        loopModeOverride = try container.decodeIfPresent(ProjectLoopMode.self, forKey: .loopModeOverride)
        originType = try container.decodeIfPresent(TaskOriginType.self, forKey: .originType)
        originChannelId = try container.decodeIfPresent(String.self, forKey: .originChannelId)
        actorId = try container.decodeIfPresent(String.self, forKey: .actorId)
        teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
        claimedActorId = try container.decodeIfPresent(String.self, forKey: .claimedActorId)
        claimedAgentId = try container.decodeIfPresent(String.self, forKey: .claimedAgentId)
        parentTaskId = try container.decodeIfPresent(String.self, forKey: .parentTaskId)
        swarmId = try container.decodeIfPresent(String.self, forKey: .swarmId)
        swarmTaskId = try container.decodeIfPresent(String.self, forKey: .swarmTaskId)
        swarmParentTaskId = try container.decodeIfPresent(String.self, forKey: .swarmParentTaskId)
        swarmDependencyIds = try container.decodeIfPresent([String].self, forKey: .swarmDependencyIds)
        swarmDepth = try container.decodeIfPresent(Int.self, forKey: .swarmDepth)
        swarmActorPath = try container.decodeIfPresent([String].self, forKey: .swarmActorPath)
        worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel)
        externalMetadata = try container.decodeIfPresent(TaskExternalMetadata.self, forKey: .externalMetadata)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        routeHistory = try container.decodeIfPresent([ProjectTaskRouteStep].self, forKey: .routeHistory) ?? []
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public extension ProjectTask {
    var statusValue: ProjectTaskStatus? {
        ProjectTaskStatus(rawValue: status)
    }
}

public struct ProjectHeartbeatSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var intervalMinutes: Int

    public init(enabled: Bool = false, intervalMinutes: Int = 5) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
    }
}

public struct KanbanEvent: Codable, Sendable {
    public enum EventType: String, Codable, Sendable {
        case taskCreated = "task_created"
        case taskUpdated = "task_updated"
        case taskDeleted = "task_deleted"
        case projectUpdated = "project_updated"
    }

    public var type: EventType
    public var projectId: String
    public var task: ProjectTask?
    public var taskId: String?

    public init(type: EventType, projectId: String, task: ProjectTask? = nil, taskId: String? = nil) {
        self.type = type
        self.projectId = projectId
        self.task = task
        self.taskId = taskId
    }
}

public struct ProjectRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var icon: String?
    public var channels: [ProjectChannel]
    public var tasks: [ProjectTask]
    public var actors: [String]
    public var teams: [String]
    public var models: [String]
    public var agentFiles: [String]
    public var heartbeat: ProjectHeartbeatSettings
    public var repoPath: String?
    public var reviewSettings: ProjectReviewSettings
    public var taskLoopMode: ProjectLoopMode
    public var taskSyncSettings: ProjectTaskSyncSettings
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, description, icon, channels, tasks, actors, teams, models
        case agentFiles, heartbeat, repoPath, reviewSettings, taskLoopMode, taskSyncSettings, isArchived, createdAt, updatedAt
    }

    public init(
        id: String,
        name: String,
        description: String,
        icon: String? = nil,
        channels: [ProjectChannel],
        tasks: [ProjectTask],
        actors: [String] = [],
        teams: [String] = [],
        models: [String] = [],
        agentFiles: [String] = [],
        heartbeat: ProjectHeartbeatSettings = ProjectHeartbeatSettings(),
        repoPath: String? = nil,
        reviewSettings: ProjectReviewSettings = ProjectReviewSettings(),
        taskLoopMode: ProjectLoopMode = .human,
        taskSyncSettings: ProjectTaskSyncSettings = ProjectTaskSyncSettings(),
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.channels = channels
        self.tasks = tasks
        self.actors = actors
        self.teams = teams
        self.models = models
        self.agentFiles = agentFiles
        self.heartbeat = heartbeat
        self.repoPath = repoPath
        self.reviewSettings = reviewSettings
        self.taskLoopMode = taskLoopMode
        self.taskSyncSettings = taskSyncSettings
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        channels = try container.decodeIfPresent([ProjectChannel].self, forKey: .channels) ?? []
        tasks = try container.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        actors = try container.decodeIfPresent([String].self, forKey: .actors) ?? []
        teams = try container.decodeIfPresent([String].self, forKey: .teams) ?? []
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        agentFiles = try container.decodeIfPresent([String].self, forKey: .agentFiles) ?? []
        heartbeat = try container.decodeIfPresent(ProjectHeartbeatSettings.self, forKey: .heartbeat) ?? ProjectHeartbeatSettings()
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath)
        reviewSettings = try container.decodeIfPresent(ProjectReviewSettings.self, forKey: .reviewSettings) ?? ProjectReviewSettings()
        taskLoopMode = try container.decodeIfPresent(ProjectLoopMode.self, forKey: .taskLoopMode) ?? .human
        taskSyncSettings = try container.decodeIfPresent(ProjectTaskSyncSettings.self, forKey: .taskSyncSettings) ?? ProjectTaskSyncSettings()
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// Payload returned when creating a project via HTTP; includes Git clone outcome when `repoUrl` was used.
public struct ProjectCreateResult: Codable, Sendable, Equatable {
    public var project: ProjectRecord
    /// When the project was created with a `repoUrl`, whether `git clone` finished successfully. `nil` when no remote clone was attempted.
    public var repoCloneSucceeded: Bool?

    public init(project: ProjectRecord, repoCloneSucceeded: Bool? = nil) {
        self.project = project
        self.repoCloneSucceeded = repoCloneSucceeded
    }
}

public enum ProjectWorkingTreeChangeKind: String, Codable, Sendable, Equatable {
    case created
    case modified
    case deleted
}

public struct ProjectWorkingTreeChange: Codable, Sendable, Equatable {
    public var path: String
    public var kind: ProjectWorkingTreeChangeKind
    public var sizeBytes: Int?
    public var modifiedAt: Date?

    public init(
        path: String,
        kind: ProjectWorkingTreeChangeKind,
        sizeBytes: Int? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct ProjectWorkingTreeChangeBatch: Codable, Sendable, Equatable {
    public var projectId: String
    public var rootPath: String
    public var changes: [ProjectWorkingTreeChange]
    public var createdAt: Date

    public init(
        projectId: String,
        rootPath: String,
        changes: [ProjectWorkingTreeChange],
        createdAt: Date = Date()
    ) {
        self.projectId = projectId
        self.rootPath = rootPath
        self.changes = changes
        self.createdAt = createdAt
    }
}

// MARK: - Project Analytics

public enum ProjectAnalyticsWindow: String, Codable, Sendable, Equatable, CaseIterable {
    case last24h = "24h"
    case last7d = "7d"
    case all = "all"
}

public struct ProjectAnalyticsQuery: Codable, Sendable, Equatable {
    public var window: ProjectAnalyticsWindow
    public var from: Date?
    public var to: Date?

    public init(window: ProjectAnalyticsWindow = .last24h, from: Date? = nil, to: Date? = nil) {
        self.window = window
        self.from = from
        self.to = to
    }
}

public struct ProjectTaskOutcomeCounts: Codable, Sendable, Equatable {
    public var total: Int
    public var success: Int
    public var failed: Int
    public var interrupted: Int

    public init(total: Int = 0, success: Int = 0, failed: Int = 0, interrupted: Int = 0) {
        self.total = total
        self.success = success
        self.failed = failed
        self.interrupted = interrupted
    }
}

public struct ProjectToolStats: Codable, Sendable, Equatable {
    public struct ToolAggregate: Codable, Sendable, Equatable {
        public var tool: String
        public var calls: Int
        public var failures: Int
        public var avgDurationMs: Int?

        public init(tool: String, calls: Int = 0, failures: Int = 0, avgDurationMs: Int? = nil) {
            self.tool = tool
            self.calls = calls
            self.failures = failures
            self.avgDurationMs = avgDurationMs
        }
    }

    public var totalCalls: Int
    public var totalFailures: Int
    public var failureRate: Double
    public var avgDurationMs: Int?
    public var p50DurationMs: Int?
    public var p95DurationMs: Int?
    public var topToolsByTime: [ToolAggregate]
    public var topFailingTools: [ToolAggregate]

    public init(
        totalCalls: Int = 0,
        totalFailures: Int = 0,
        failureRate: Double = 0,
        avgDurationMs: Int? = nil,
        p50DurationMs: Int? = nil,
        p95DurationMs: Int? = nil,
        topToolsByTime: [ToolAggregate] = [],
        topFailingTools: [ToolAggregate] = []
    ) {
        self.totalCalls = totalCalls
        self.totalFailures = totalFailures
        self.failureRate = failureRate
        self.avgDurationMs = avgDurationMs
        self.p50DurationMs = p50DurationMs
        self.p95DurationMs = p95DurationMs
        self.topToolsByTime = topToolsByTime
        self.topFailingTools = topFailingTools
    }
}

public struct ProjectTokenUsageTotals: Codable, Sendable, Equatable {
    public var totalPromptTokens: Int
    public var totalCompletionTokens: Int
    public var totalTokens: Int

    public init(totalPromptTokens: Int = 0, totalCompletionTokens: Int = 0, totalTokens: Int = 0) {
        self.totalPromptTokens = totalPromptTokens
        self.totalCompletionTokens = totalCompletionTokens
        self.totalTokens = totalTokens
    }
}

public struct ProjectAnalyticsResponse: Codable, Sendable, Equatable {
    public var projectId: String
    public var window: ProjectAnalyticsWindow
    public var from: Date?
    public var to: Date?

    /// Keys are `EventEnvelope.messageType` raw values (e.g. "channel.route.decided").
    public var runtimeEventCounts: [String: Int]

    public var taskOutcomes: ProjectTaskOutcomeCounts
    public var tools: ProjectToolStats
    public var tokenUsage: ProjectTokenUsageTotals

    public var isPartial: Bool
    public var notes: [String]

    public init(
        projectId: String,
        window: ProjectAnalyticsWindow,
        from: Date? = nil,
        to: Date? = nil,
        runtimeEventCounts: [String: Int] = [:],
        taskOutcomes: ProjectTaskOutcomeCounts = .init(),
        tools: ProjectToolStats = .init(),
        tokenUsage: ProjectTokenUsageTotals = .init(),
        isPartial: Bool = false,
        notes: [String] = []
    ) {
        self.projectId = projectId
        self.window = window
        self.from = from
        self.to = to
        self.runtimeEventCounts = runtimeEventCounts
        self.taskOutcomes = taskOutcomes
        self.tools = tools
        self.tokenUsage = tokenUsage
        self.isPartial = isPartial
        self.notes = notes
    }
}

public struct ProjectCreateRequest: Codable, Sendable {
    public var id: String?
    public var name: String
    public var description: String?
    public var channels: [ProjectChannelCreateRequest]
    public var actors: [String]?
    public var teams: [String]?
    public var repoUrl: String?
    public var repoPath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case channels
        case actors
        case teams
        case repoUrl
        case repoPath
    }

    public init(
        id: String? = nil,
        name: String,
        description: String? = nil,
        channels: [ProjectChannelCreateRequest] = [],
        actors: [String]? = nil,
        teams: [String]? = nil,
        repoUrl: String? = nil,
        repoPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.channels = channels
        self.actors = actors
        self.teams = teams
        self.repoUrl = repoUrl
        self.repoPath = repoPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        channels = try container.decodeIfPresent([ProjectChannelCreateRequest].self, forKey: .channels) ?? []
        actors = try container.decodeIfPresent([String].self, forKey: .actors)
        teams = try container.decodeIfPresent([String].self, forKey: .teams)
        repoUrl = try container.decodeIfPresent(String.self, forKey: .repoUrl)
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath)
    }
}

public struct ProjectUpdateRequest: Codable, Sendable {
    public var name: String?
    public var description: String?
    public var icon: String?
    public var actors: [String]?
    public var teams: [String]?
    public var models: [String]?
    public var agentFiles: [String]?
    public var heartbeat: ProjectHeartbeatSettings?
    public var repoPath: String?
    public var reviewSettings: ProjectReviewSettings?
    public var taskLoopMode: ProjectLoopMode?
    public var isArchived: Bool?

    public init(
        name: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        actors: [String]? = nil,
        teams: [String]? = nil,
        models: [String]? = nil,
        agentFiles: [String]? = nil,
        heartbeat: ProjectHeartbeatSettings? = nil,
        repoPath: String? = nil,
        reviewSettings: ProjectReviewSettings? = nil,
        taskLoopMode: ProjectLoopMode? = nil,
        isArchived: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.icon = icon
        self.actors = actors
        self.teams = teams
        self.models = models
        self.agentFiles = agentFiles
        self.heartbeat = heartbeat
        self.repoPath = repoPath
        self.reviewSettings = reviewSettings
        self.taskLoopMode = taskLoopMode
        self.isArchived = isArchived
    }
}

public struct ProjectContextRefreshResponse: Codable, Sendable {
    public var projectId: String
    public var repoPath: String?
    public var appliedChannelIds: [String]
    public var loadedDocPaths: [String]
    public var loadedSkillPaths: [String]
    public var totalChars: Int
    public var truncated: Bool

    public init(
        projectId: String,
        repoPath: String?,
        appliedChannelIds: [String],
        loadedDocPaths: [String],
        loadedSkillPaths: [String],
        totalChars: Int,
        truncated: Bool
    ) {
        self.projectId = projectId
        self.repoPath = repoPath
        self.appliedChannelIds = appliedChannelIds
        self.loadedDocPaths = loadedDocPaths
        self.loadedSkillPaths = loadedSkillPaths
        self.totalChars = totalChars
        self.truncated = truncated
    }
}

public struct ProjectChannelCreateRequest: Codable, Sendable {
    public var title: String
    public var channelId: String

    public init(title: String, channelId: String) {
        self.title = title
        self.channelId = channelId
    }
}

public struct ProjectChannelLinkRequest: Codable, Sendable {
    public var channelId: String
    public var title: String?
    public var ensureSession: Bool?

    public init(channelId: String, title: String? = nil, ensureSession: Bool? = nil) {
        self.channelId = channelId
        self.title = title
        self.ensureSession = ensureSession
    }
}

public struct ProjectChannelLinkSession: Codable, Sendable, Equatable {
    public var channelId: String
    public var sessionId: String
    public var status: String

    public init(channelId: String, sessionId: String, status: String) {
        self.channelId = channelId
        self.sessionId = sessionId
        self.status = status
    }
}

public struct ProjectChannelLinkResponse: Codable, Sendable, Equatable {
    public var project: ProjectRecord
    public var channel: ProjectChannel
    public var session: ProjectChannelLinkSession?
    public var status: String

    public init(
        project: ProjectRecord,
        channel: ProjectChannel,
        session: ProjectChannelLinkSession? = nil,
        status: String
    ) {
        self.project = project
        self.channel = channel
        self.session = session
        self.status = status
    }
}

public struct ProjectTaskCreateRequest: Codable, Sendable {
    public var title: String
    public var description: String?
    public var priority: String
    public var status: String?
    public var kind: ProjectTaskKind?
    public var loopModeOverride: ProjectLoopMode?
    public var originType: TaskOriginType?
    public var originChannelId: String?
    public var actorId: String?
    public var teamId: String?
    public var parentTaskId: String?
    public var selectedModel: String?

    public init(
        title: String,
        description: String? = nil,
        priority: String = "medium",
        status: String? = nil,
        kind: ProjectTaskKind? = nil,
        loopModeOverride: ProjectLoopMode? = nil,
        originType: TaskOriginType? = nil,
        originChannelId: String? = nil,
        actorId: String? = nil,
        teamId: String? = nil,
        parentTaskId: String? = nil,
        selectedModel: String? = nil
    ) {
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.kind = kind
        self.loopModeOverride = loopModeOverride
        self.originType = originType
        self.originChannelId = originChannelId
        self.actorId = actorId
        self.teamId = teamId
        self.parentTaskId = parentTaskId
        self.selectedModel = selectedModel
    }
}

public struct ProjectTaskUpdateRequest: Codable, Sendable {
    public var title: String?
    public var description: String?
    public var priority: String?
    public var status: String?
    public var completionConfidence: ProjectTaskCompletionConfidence?
    public var completionNote: String?
    public var kind: ProjectTaskKind?
    public var loopModeOverride: ProjectLoopMode?
    public var actorId: String?
    public var teamId: String?
    public var parentTaskId: String?
    public var selectedModel: String?
    public var tags: [String]?
    public var isArchived: Bool?
    public var changedBy: String?

    public init(
        title: String? = nil,
        description: String? = nil,
        priority: String? = nil,
        status: String? = nil,
        completionConfidence: ProjectTaskCompletionConfidence? = nil,
        completionNote: String? = nil,
        kind: ProjectTaskKind? = nil,
        loopModeOverride: ProjectLoopMode? = nil,
        actorId: String? = nil,
        teamId: String? = nil,
        parentTaskId: String? = nil,
        selectedModel: String? = nil,
        tags: [String]? = nil,
        isArchived: Bool? = nil,
        changedBy: String? = nil
    ) {
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.completionConfidence = completionConfidence
        self.completionNote = completionNote
        self.kind = kind
        self.loopModeOverride = loopModeOverride
        self.actorId = actorId
        self.teamId = teamId
        self.parentTaskId = parentTaskId
        self.selectedModel = selectedModel
        self.tags = tags
        self.isArchived = isArchived
        self.changedBy = changedBy
    }
}

public struct TaskRejectRequest: Codable, Sendable {
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct AgentCreateRequest: Codable, Sendable {
    public var id: String
    public var displayName: String
    public var role: String
    public var isSystem: Bool
    public var runtime: AgentRuntimeConfig?
    public var petDraftId: String?

    public init(
        id: String,
        displayName: String,
        role: String,
        isSystem: Bool = false,
        runtime: AgentRuntimeConfig? = nil,
        petDraftId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isSystem = isSystem
        self.runtime = runtime
        self.petDraftId = petDraftId
    }
}

public enum AgentRuntimeType: String, Codable, Sendable, Equatable {
    case native
    case acp
}

public struct AgentACPConfig: Codable, Sendable, Equatable {
    public var targetId: String
    public var cwd: String?

    public init(targetId: String, cwd: String? = nil) {
        self.targetId = targetId
        self.cwd = cwd
    }
}

public struct AgentRuntimeConfig: Codable, Sendable, Equatable {
    public var type: AgentRuntimeType
    public var acp: AgentACPConfig?

    public init(type: AgentRuntimeType = .native, acp: AgentACPConfig? = nil) {
        self.type = type
        self.acp = acp
    }
}

public enum AgentPetRarityTier: String, Codable, Sendable, Equatable {
    case common
    case uncommon
    case rare
    case legendary
}

public struct AgentPetParts: Codable, Sendable, Equatable {
    public var headId: String
    public var bodyId: String
    public var legsId: String
    public var faceId: String
    public var accessoryId: String

    public init(headId: String, bodyId: String, legsId: String, faceId: String = "face-default", accessoryId: String = "acc-none") {
        self.headId = headId
        self.bodyId = bodyId
        self.legsId = legsId
        self.faceId = faceId
        self.accessoryId = accessoryId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headId = try container.decode(String.self, forKey: .headId)
        bodyId = try container.decode(String.self, forKey: .bodyId)
        legsId = try container.decode(String.self, forKey: .legsId)
        faceId = try container.decodeIfPresent(String.self, forKey: .faceId) ?? "face-default"
        accessoryId = try container.decodeIfPresent(String.self, forKey: .accessoryId) ?? "acc-none"
    }
}

public struct AgentPetPartRarities: Codable, Sendable, Equatable {
    public var head: AgentPetRarityTier
    public var body: AgentPetRarityTier
    public var legs: AgentPetRarityTier
    public var face: AgentPetRarityTier
    public var accessory: AgentPetRarityTier

    public init(head: AgentPetRarityTier, body: AgentPetRarityTier, legs: AgentPetRarityTier, face: AgentPetRarityTier = .common, accessory: AgentPetRarityTier = .common) {
        self.head = head
        self.body = body
        self.legs = legs
        self.face = face
        self.accessory = accessory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        head = try container.decode(AgentPetRarityTier.self, forKey: .head)
        body = try container.decode(AgentPetRarityTier.self, forKey: .body)
        legs = try container.decode(AgentPetRarityTier.self, forKey: .legs)
        face = try container.decodeIfPresent(AgentPetRarityTier.self, forKey: .face) ?? .common
        accessory = try container.decodeIfPresent(AgentPetRarityTier.self, forKey: .accessory) ?? .common
    }
}

public struct AgentPetStats: Codable, Sendable, Equatable {
    public var wisdom: Int
    public var debugging: Int
    public var patience: Int
    public var snark: Int
    public var chaos: Int

    public init(
        wisdom: Int = 0,
        debugging: Int = 0,
        patience: Int = 0,
        snark: Int = 0,
        chaos: Int = 0
    ) {
        self.wisdom = wisdom
        self.debugging = debugging
        self.patience = patience
        self.snark = snark
        self.chaos = chaos
    }
}

public struct AgentPetTerminalFaceSet: Codable, Sendable, Equatable {
    public var idle: String
    public var happy: String
    public var sad: String
    public var sleep: String

    public init(
        idle: String,
        happy: String,
        sad: String,
        sleep: String
    ) {
        self.idle = idle
        self.happy = happy
        self.sad = sad
        self.sleep = sleep
    }
}

public enum AgentPetAnimationState: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case walk
    case happy
    case sad
    case interacted
    case sleep
    case avatar
}

public struct AgentPetFrameSize: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct AgentPetFrameRange: Codable, Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var fps: Int
    public var loop: Bool

    public init(start: Int, end: Int, fps: Int, loop: Bool) {
        self.start = start
        self.end = end
        self.fps = fps
        self.loop = loop
    }
}

public struct AgentPetStageAsset: Codable, Sendable, Equatable {
    public var stage: Int
    public var spriteSheetPath: String
    public var frameSize: AgentPetFrameSize
    public var stateFrameRanges: [String: AgentPetFrameRange]

    public init(
        stage: Int,
        spriteSheetPath: String,
        frameSize: AgentPetFrameSize = AgentPetFrameSize(width: 256, height: 256),
        stateFrameRanges: [String: AgentPetFrameRange]
    ) {
        self.stage = stage
        self.spriteSheetPath = spriteSheetPath
        self.frameSize = frameSize
        self.stateFrameRanges = stateFrameRanges
    }
}

public struct AgentPetVisualSummary: Codable, Sendable, Equatable {
    public var speciesId: String
    public var displayName: String
    public var source: String
    public var assetBaseURL: String
    public var currentStage: Int
    public var stageCount: Int
    public var terminalFaceSet: AgentPetTerminalFaceSet

    public init(
        speciesId: String,
        displayName: String,
        source: String,
        assetBaseURL: String,
        currentStage: Int,
        stageCount: Int,
        terminalFaceSet: AgentPetTerminalFaceSet
    ) {
        self.speciesId = speciesId
        self.displayName = displayName
        self.source = source
        self.assetBaseURL = assetBaseURL
        self.currentStage = currentStage
        self.stageCount = stageCount
        self.terminalFaceSet = terminalFaceSet
    }
}

public struct AgentPetEvolutionSummary: Codable, Sendable, Equatable {
    public var totalXp: Int
    public var stageXp: Int
    public var nextStageXp: Int?
    public var isMaxStage: Bool

    public init(totalXp: Int, stageXp: Int, nextStageXp: Int?, isMaxStage: Bool) {
        self.totalXp = totalXp
        self.stageXp = stageXp
        self.nextStageXp = nextStageXp
        self.isMaxStage = isMaxStage
    }
}

public struct AgentPetProgressCounters: Codable, Sendable, Equatable {
    public var directMessageCount: Int
    public var externalMessageCount: Int
    public var automatedMessageCount: Int
    public var successfulRunCount: Int
    public var failedRunCount: Int
    public var interruptedRunCount: Int
    public var toolCallCount: Int
    public var toolFailureCount: Int

    public init(
        directMessageCount: Int = 0,
        externalMessageCount: Int = 0,
        automatedMessageCount: Int = 0,
        successfulRunCount: Int = 0,
        failedRunCount: Int = 0,
        interruptedRunCount: Int = 0,
        toolCallCount: Int = 0,
        toolFailureCount: Int = 0
    ) {
        self.directMessageCount = directMessageCount
        self.externalMessageCount = externalMessageCount
        self.automatedMessageCount = automatedMessageCount
        self.successfulRunCount = successfulRunCount
        self.failedRunCount = failedRunCount
        self.interruptedRunCount = interruptedRunCount
        self.toolCallCount = toolCallCount
        self.toolFailureCount = toolFailureCount
    }
}

public struct AgentPetProgressWatermark: Codable, Sendable, Equatable {
    public var sourceKind: String?
    public var channelId: String?
    public var sessionId: String?
    public var eventKind: String?
    public var processedAt: Date?

    public init(
        sourceKind: String? = nil,
        channelId: String? = nil,
        sessionId: String? = nil,
        eventKind: String? = nil,
        processedAt: Date? = nil
    ) {
        self.sourceKind = sourceKind
        self.channelId = channelId
        self.sessionId = sessionId
        self.eventKind = eventKind
        self.processedAt = processedAt
    }
}

public struct AgentPetProgressState: Codable, Sendable, Equatable {
    public var version: Int
    public var currentStats: AgentPetStats
    public var totalXp: Int
    public var counters: AgentPetProgressCounters
    public var dailyChannelGainBuckets: [String: AgentPetStats]
    public var dailyGlobalGainBuckets: [String: AgentPetStats]
    public var processedWatermark: AgentPetProgressWatermark
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case currentStats
        case totalXp
        case counters
        case dailyChannelGainBuckets
        case dailyGlobalGainBuckets
        case processedWatermark
        case createdAt
        case updatedAt
    }

    public init(
        version: Int = 1,
        currentStats: AgentPetStats,
        totalXp: Int = 0,
        counters: AgentPetProgressCounters = .init(),
        dailyChannelGainBuckets: [String: AgentPetStats] = [:],
        dailyGlobalGainBuckets: [String: AgentPetStats] = [:],
        processedWatermark: AgentPetProgressWatermark = .init(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.currentStats = currentStats
        self.totalXp = totalXp
        self.counters = counters
        self.dailyChannelGainBuckets = dailyChannelGainBuckets
        self.dailyGlobalGainBuckets = dailyGlobalGainBuckets
        self.processedWatermark = processedWatermark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        currentStats = try container.decode(AgentPetStats.self, forKey: .currentStats)
        totalXp = try container.decodeIfPresent(Int.self, forKey: .totalXp) ?? 0
        counters = try container.decodeIfPresent(AgentPetProgressCounters.self, forKey: .counters) ?? .init()
        dailyChannelGainBuckets = try container.decodeIfPresent([String: AgentPetStats].self, forKey: .dailyChannelGainBuckets) ?? [:]
        dailyGlobalGainBuckets = try container.decodeIfPresent([String: AgentPetStats].self, forKey: .dailyGlobalGainBuckets) ?? [:]
        processedWatermark = try container.decodeIfPresent(AgentPetProgressWatermark.self, forKey: .processedWatermark) ?? .init()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct AgentPetSummary: Codable, Sendable, Equatable {
    public var petId: String
    public var genomeHex: String
    public var parts: AgentPetParts
    public var partRarities: AgentPetPartRarities
    public var rarity: AgentPetRarityTier
    public var baseStats: AgentPetStats
    public var currentStats: AgentPetStats
    public var transferable: Bool
    public var visual: AgentPetVisualSummary?
    public var evolution: AgentPetEvolutionSummary?
    public var stageAssets: [AgentPetStageAsset]

    enum CodingKeys: String, CodingKey {
        case petId
        case genomeHex
        case parts
        case partRarities
        case rarity
        case baseStats
        case currentStats
        case transferable
        case visual
        case evolution
        case stageAssets
    }

    public init(
        petId: String,
        genomeHex: String,
        parts: AgentPetParts,
        partRarities: AgentPetPartRarities,
        rarity: AgentPetRarityTier,
        baseStats: AgentPetStats,
        currentStats: AgentPetStats? = nil,
        transferable: Bool = true,
        visual: AgentPetVisualSummary? = nil,
        evolution: AgentPetEvolutionSummary? = nil,
        stageAssets: [AgentPetStageAsset] = []
    ) {
        self.petId = petId
        self.genomeHex = genomeHex
        self.parts = parts
        self.partRarities = partRarities
        self.rarity = rarity
        self.baseStats = baseStats
        self.currentStats = currentStats ?? baseStats
        self.transferable = transferable
        self.visual = visual
        self.evolution = evolution
        self.stageAssets = stageAssets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        petId = try container.decode(String.self, forKey: .petId)
        genomeHex = try container.decode(String.self, forKey: .genomeHex)
        parts = try container.decode(AgentPetParts.self, forKey: .parts)
        partRarities = try container.decode(AgentPetPartRarities.self, forKey: .partRarities)
        rarity = try container.decode(AgentPetRarityTier.self, forKey: .rarity)
        baseStats = try container.decode(AgentPetStats.self, forKey: .baseStats)
        currentStats = try container.decodeIfPresent(AgentPetStats.self, forKey: .currentStats) ?? baseStats
        transferable = try container.decodeIfPresent(Bool.self, forKey: .transferable) ?? true
        visual = try container.decodeIfPresent(AgentPetVisualSummary.self, forKey: .visual)
        evolution = try container.decodeIfPresent(AgentPetEvolutionSummary.self, forKey: .evolution)
        stageAssets = try container.decodeIfPresent([AgentPetStageAsset].self, forKey: .stageAssets) ?? []
    }
}

public enum AgentPetGenerationMode: String, Codable, Sendable, Equatable {
    case wish
    case prompt
}

public struct AgentPetGenerationRequest: Codable, Sendable {
    public var mode: AgentPetGenerationMode
    public var prompt: String?
    public var model: String?

    public init(mode: AgentPetGenerationMode, prompt: String? = nil, model: String? = nil) {
        self.mode = mode
        self.prompt = prompt
        self.model = model
    }
}

public struct AgentPetGenerationResponse: Codable, Sendable, Equatable {
    public var draftId: String
    public var visual: AgentPetVisualSummary
    public var evolution: AgentPetEvolutionSummary
    public var generatedPrompt: String
    public var assetURLs: [String]
    public var stageAssets: [AgentPetStageAsset]
    public var terminalFaceSet: AgentPetTerminalFaceSet

    public init(
        draftId: String,
        visual: AgentPetVisualSummary,
        evolution: AgentPetEvolutionSummary,
        generatedPrompt: String,
        assetURLs: [String],
        stageAssets: [AgentPetStageAsset],
        terminalFaceSet: AgentPetTerminalFaceSet
    ) {
        self.draftId = draftId
        self.visual = visual
        self.evolution = evolution
        self.generatedPrompt = generatedPrompt
        self.assetURLs = assetURLs
        self.stageAssets = stageAssets
        self.terminalFaceSet = terminalFaceSet
    }
}

public struct AgentPetImageGenerationStatusResponse: Codable, Sendable, Equatable {
    public var available: Bool
    public var providers: [String]
    public var message: String

    public init(available: Bool, providers: [String], message: String) {
        self.available = available
        self.providers = providers
        self.message = message
    }
}

public struct AgentSummary: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var role: String
    public var createdAt: Date
    public var isSystem: Bool
    public var runtime: AgentRuntimeConfig
    public var pet: AgentPetSummary?

    enum CodingKeys: String, CodingKey {
        case id, displayName, role, createdAt, isSystem, runtime, pet
    }

    public init(
        id: String,
        displayName: String,
        role: String,
        createdAt: Date = Date(),
        isSystem: Bool = false,
        runtime: AgentRuntimeConfig = AgentRuntimeConfig(),
        pet: AgentPetSummary? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.createdAt = createdAt
        self.isSystem = isSystem
        self.runtime = runtime
        self.pet = pet
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        role = try container.decode(String.self, forKey: .role)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isSystem = try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        runtime = try container.decodeIfPresent(AgentRuntimeConfig.self, forKey: .runtime) ?? .init()
        pet = try container.decodeIfPresent(AgentPetSummary.self, forKey: .pet)
    }
}

public struct AgentTaskRecord: Codable, Sendable, Equatable {
    public var projectId: String
    public var projectName: String
    public var task: ProjectTask

    public init(projectId: String, projectName: String, task: ProjectTask) {
        self.projectId = projectId
        self.projectName = projectName
        self.task = task
    }
}

public enum AgentMemoryFilter: String, Codable, Sendable, CaseIterable {
    case all
    case persistent
    case temporary
    case todo
}

public enum AgentMemoryCategory: String, Codable, Sendable, CaseIterable {
    case persistent
    case temporary
    case todo
}

public struct AgentMemoryItem: Codable, Sendable, Equatable {
    public var id: String
    public var note: String
    public var summary: String?
    public var kind: MemoryKind
    public var memoryClass: MemoryClass
    public var scope: MemoryScope
    public var source: MemorySource?
    public var importance: Double
    public var confidence: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date?
    public var derivedCategory: AgentMemoryCategory

    public init(
        id: String,
        note: String,
        summary: String? = nil,
        kind: MemoryKind,
        memoryClass: MemoryClass,
        scope: MemoryScope,
        source: MemorySource? = nil,
        importance: Double,
        confidence: Double,
        createdAt: Date,
        updatedAt: Date,
        expiresAt: Date? = nil,
        derivedCategory: AgentMemoryCategory
    ) {
        self.id = id
        self.note = note
        self.summary = summary
        self.kind = kind
        self.memoryClass = memoryClass
        self.scope = scope
        self.source = source
        self.importance = importance
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.derivedCategory = derivedCategory
    }
}

public struct AgentMemoryListResponse: Codable, Sendable, Equatable {
    public var agentId: String
    public var items: [AgentMemoryItem]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(agentId: String, items: [AgentMemoryItem], total: Int, limit: Int, offset: Int) {
        self.agentId = agentId
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}

public struct AgentMemoryEdgeRecord: Codable, Sendable, Equatable {
    public var fromMemoryId: String
    public var toMemoryId: String
    public var relation: MemoryEdgeRelation
    public var weight: Double
    public var provenance: String?
    public var createdAt: Date

    public init(
        fromMemoryId: String,
        toMemoryId: String,
        relation: MemoryEdgeRelation,
        weight: Double = 1.0,
        provenance: String? = nil,
        createdAt: Date = Date()
    ) {
        self.fromMemoryId = fromMemoryId
        self.toMemoryId = toMemoryId
        self.relation = relation
        self.weight = weight
        self.provenance = provenance
        self.createdAt = createdAt
    }
}

public struct AgentMemoryGraphResponse: Codable, Sendable, Equatable {
    public var agentId: String
    public var nodes: [AgentMemoryItem]
    public var edges: [AgentMemoryEdgeRecord]
    public var seedIds: [String]
    public var truncated: Bool

    public init(
        agentId: String,
        nodes: [AgentMemoryItem],
        edges: [AgentMemoryEdgeRecord],
        seedIds: [String],
        truncated: Bool
    ) {
        self.agentId = agentId
        self.nodes = nodes
        self.edges = edges
        self.seedIds = seedIds
        self.truncated = truncated
    }
}

public struct ProjectMemoryListResponse: Codable, Sendable, Equatable {
    public var projectId: String
    public var items: [AgentMemoryItem]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(projectId: String, items: [AgentMemoryItem], total: Int, limit: Int, offset: Int) {
        self.projectId = projectId
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}

public struct ProjectMemoryGraphResponse: Codable, Sendable, Equatable {
    public var projectId: String
    public var nodes: [AgentMemoryItem]
    public var edges: [AgentMemoryEdgeRecord]
    public var seedIds: [String]
    public var truncated: Bool

    public init(
        projectId: String,
        nodes: [AgentMemoryItem],
        edges: [AgentMemoryEdgeRecord],
        seedIds: [String],
        truncated: Bool
    ) {
        self.projectId = projectId
        self.nodes = nodes
        self.edges = edges
        self.seedIds = seedIds
        self.truncated = truncated
    }
}

public struct AgentMemoryUpdateRequest: Codable, Sendable, Equatable {
    public var note: String?
    public var summary: String?
    public var kind: MemoryKind?
    public var importance: Double?
    public var confidence: Double?

    public init(
        note: String? = nil,
        summary: String? = nil,
        kind: MemoryKind? = nil,
        importance: Double? = nil,
        confidence: Double? = nil
    ) {
        self.note = note
        self.summary = summary
        self.kind = kind
        self.importance = importance
        self.confidence = confidence
    }
}

public struct AgentDocumentBundle: Codable, Sendable, Equatable {
    public var userMarkdown: String
    public var agentsMarkdown: String
    public var soulMarkdown: String
    public var identityMarkdown: String
    public var heartbeatMarkdown: String
    public var friendReminderMarkdown: String
    public var memoryMarkdown: String

    public init(
        userMarkdown: String,
        agentsMarkdown: String,
        soulMarkdown: String,
        identityMarkdown: String,
        heartbeatMarkdown: String = "",
        friendReminderMarkdown: String = "",
        memoryMarkdown: String = ""
    ) {
        self.userMarkdown = userMarkdown
        self.agentsMarkdown = agentsMarkdown
        self.soulMarkdown = soulMarkdown
        self.identityMarkdown = identityMarkdown
        self.heartbeatMarkdown = heartbeatMarkdown
        self.friendReminderMarkdown = friendReminderMarkdown
        self.memoryMarkdown = memoryMarkdown
    }

    enum CodingKeys: String, CodingKey {
        case userMarkdown
        case agentsMarkdown
        case soulMarkdown
        case identityMarkdown
        case heartbeatMarkdown
        case friendReminderMarkdown
        case memoryMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userMarkdown = try container.decode(String.self, forKey: .userMarkdown)
        agentsMarkdown = try container.decode(String.self, forKey: .agentsMarkdown)
        soulMarkdown = try container.decode(String.self, forKey: .soulMarkdown)
        identityMarkdown = try container.decode(String.self, forKey: .identityMarkdown)
        heartbeatMarkdown = try container.decodeIfPresent(String.self, forKey: .heartbeatMarkdown) ?? ""
        friendReminderMarkdown = try container.decodeIfPresent(String.self, forKey: .friendReminderMarkdown) ?? ""
        memoryMarkdown = try container.decodeIfPresent(String.self, forKey: .memoryMarkdown) ?? ""
    }
}

public struct AgentHeartbeatSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var intervalMinutes: Int

    public init(enabled: Bool = false, intervalMinutes: Int = 5) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
    }
}

public struct AgentHeartbeatStatus: Codable, Sendable, Equatable {
    public var lastRunAt: Date?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var lastResult: String?
    public var lastErrorMessage: String?
    public var lastSessionId: String?

    public init(
        lastRunAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        lastResult: String? = nil,
        lastErrorMessage: String? = nil,
        lastSessionId: String? = nil
    ) {
        self.lastRunAt = lastRunAt
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastResult = lastResult
        self.lastErrorMessage = lastErrorMessage
        self.lastSessionId = lastSessionId
    }
}

/// When an agent should react to inbound gateway traffic (Telegram / Discord groups).
public enum ChannelInboundActivation: String, Codable, Sendable, Equatable {
    /// Forward every non-empty message to the agent (default).
    case allMessages = "all"
    /// Only when the bot is @mentioned or the user replies to the bot's message. Slash commands still always apply.
    case mentionOrReply = "mention_or_reply"
}

public struct AgentChannelSessionSettings: Codable, Sendable, Equatable {
    public var autoCloseEnabled: Bool
    public var autoCloseAfterMinutes: Int
    public var inboundActivation: ChannelInboundActivation
    public var allowedChannelIds: [String]
    public var excludedChannelIds: [String]

    public init(
        autoCloseEnabled: Bool = false,
        autoCloseAfterMinutes: Int = 30,
        inboundActivation: ChannelInboundActivation = .allMessages,
        allowedChannelIds: [String] = [],
        excludedChannelIds: [String] = []
    ) {
        self.autoCloseEnabled = autoCloseEnabled
        self.autoCloseAfterMinutes = autoCloseAfterMinutes
        self.inboundActivation = inboundActivation
        self.allowedChannelIds = Self.normalizedChannelIds(allowedChannelIds)
        self.excludedChannelIds = Self.normalizedChannelIds(excludedChannelIds)
    }

    enum CodingKeys: String, CodingKey {
        case autoCloseEnabled
        case autoCloseAfterMinutes
        case inboundActivation
        case allowedChannelIds
        case excludedChannelIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoCloseEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoCloseEnabled) ?? false
        autoCloseAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .autoCloseAfterMinutes) ?? 30
        inboundActivation = try c.decodeIfPresent(ChannelInboundActivation.self, forKey: .inboundActivation) ?? .allMessages
        allowedChannelIds = Self.normalizedChannelIds(try c.decodeIfPresent([String].self, forKey: .allowedChannelIds) ?? [])
        excludedChannelIds = Self.normalizedChannelIds(try c.decodeIfPresent([String].self, forKey: .excludedChannelIds) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(autoCloseEnabled, forKey: .autoCloseEnabled)
        try c.encode(autoCloseAfterMinutes, forKey: .autoCloseAfterMinutes)
        try c.encode(inboundActivation, forKey: .inboundActivation)
        try c.encode(allowedChannelIds, forKey: .allowedChannelIds)
        try c.encode(excludedChannelIds, forKey: .excludedChannelIds)
    }

    private static func normalizedChannelIds(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }
}

public struct AgentConfigDetail: Codable, Sendable, Equatable {
    public var agentId: String
    public var role: String
    public var selectedModel: String?
    public var availableModels: [ProviderModelOption]
    public var documents: AgentDocumentBundle
    public var heartbeat: AgentHeartbeatSettings
    public var channelSessions: AgentChannelSessionSettings
    public var heartbeatStatus: AgentHeartbeatStatus
    public var runtime: AgentRuntimeConfig

    public init(
        agentId: String,
        role: String,
        selectedModel: String?,
        availableModels: [ProviderModelOption],
        documents: AgentDocumentBundle,
        heartbeat: AgentHeartbeatSettings = AgentHeartbeatSettings(),
        channelSessions: AgentChannelSessionSettings = AgentChannelSessionSettings(),
        heartbeatStatus: AgentHeartbeatStatus = AgentHeartbeatStatus(),
        runtime: AgentRuntimeConfig = AgentRuntimeConfig()
    ) {
        self.agentId = agentId
        self.role = role
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.documents = documents
        self.heartbeat = heartbeat
        self.channelSessions = channelSessions
        self.heartbeatStatus = heartbeatStatus
        self.runtime = runtime
    }

    enum CodingKeys: String, CodingKey {
        case agentId, role, selectedModel, availableModels, documents, heartbeat, channelSessions, heartbeatStatus, runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel)
        availableModels = try container.decode([ProviderModelOption].self, forKey: .availableModels)
        documents = try container.decode(AgentDocumentBundle.self, forKey: .documents)
        heartbeat = try container.decodeIfPresent(AgentHeartbeatSettings.self, forKey: .heartbeat) ?? AgentHeartbeatSettings()
        channelSessions = try container.decodeIfPresent(AgentChannelSessionSettings.self, forKey: .channelSessions) ?? AgentChannelSessionSettings()
        heartbeatStatus = try container.decodeIfPresent(AgentHeartbeatStatus.self, forKey: .heartbeatStatus) ?? AgentHeartbeatStatus()
        runtime = try container.decodeIfPresent(AgentRuntimeConfig.self, forKey: .runtime) ?? .init()
    }
}

public struct AgentConfigUpdateRequest: Codable, Sendable {
    public var role: String?
    public var selectedModel: String?
    public var documents: AgentDocumentBundle
    public var heartbeat: AgentHeartbeatSettings
    public var channelSessions: AgentChannelSessionSettings
    public var runtime: AgentRuntimeConfig

    public init(
        role: String?,
        selectedModel: String?,
        documents: AgentDocumentBundle,
        heartbeat: AgentHeartbeatSettings = AgentHeartbeatSettings(),
        channelSessions: AgentChannelSessionSettings = AgentChannelSessionSettings(),
        runtime: AgentRuntimeConfig = AgentRuntimeConfig()
    ) {
        self.role = role
        self.selectedModel = selectedModel
        self.documents = documents
        self.heartbeat = heartbeat
        self.channelSessions = channelSessions
        self.runtime = runtime
    }

    enum CodingKeys: String, CodingKey {
        case role, selectedModel, documents, heartbeat, channelSessions, runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel)
        documents = try container.decode(AgentDocumentBundle.self, forKey: .documents)
        heartbeat = try container.decodeIfPresent(AgentHeartbeatSettings.self, forKey: .heartbeat) ?? AgentHeartbeatSettings()
        channelSessions = try container.decodeIfPresent(AgentChannelSessionSettings.self, forKey: .channelSessions) ?? AgentChannelSessionSettings()
        runtime = try container.decodeIfPresent(AgentRuntimeConfig.self, forKey: .runtime) ?? .init()
    }
}

public struct ACPTargetProbeRequest: Codable, Sendable {
    public var target: ACPProbeTarget

    public init(target: ACPProbeTarget) {
        self.target = target
    }
}

public struct ACPProbeTarget: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var transport: String
    public var command: String?
    public var arguments: [String]
    public var host: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var strictHostKeyChecking: Bool
    public var remoteCommand: String?
    public var url: String?
    public var headers: [String: String]
    public var cwd: String?
    public var environment: [String: String]
    public var timeoutMs: Int
    public var enabled: Bool
    public var permissionMode: String

    public init(
        id: String,
        title: String,
        transport: String = "stdio",
        command: String? = nil,
        arguments: [String] = [],
        host: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        strictHostKeyChecking: Bool = true,
        remoteCommand: String? = nil,
        url: String? = nil,
        headers: [String: String] = [:],
        cwd: String? = nil,
        environment: [String: String] = [:],
        timeoutMs: Int = 30_000,
        enabled: Bool = true,
        permissionMode: String = "allow_once"
    ) {
        self.id = id
        self.title = title
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.strictHostKeyChecking = strictHostKeyChecking
        self.remoteCommand = remoteCommand
        self.url = url
        self.headers = headers
        self.cwd = cwd
        self.environment = environment
        self.timeoutMs = timeoutMs
        self.enabled = enabled
        self.permissionMode = permissionMode
    }
}

public struct ACPTargetProbeResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var targetId: String
    public var targetTitle: String
    public var agentName: String?
    public var agentVersion: String?
    public var supportsSessionList: Bool
    public var supportsLoadSession: Bool
    public var supportsPromptImage: Bool
    public var supportsMCPHTTP: Bool
    public var supportsMCPSSE: Bool
    public var message: String

    public init(
        ok: Bool,
        targetId: String,
        targetTitle: String,
        agentName: String? = nil,
        agentVersion: String? = nil,
        supportsSessionList: Bool = false,
        supportsLoadSession: Bool = false,
        supportsPromptImage: Bool = false,
        supportsMCPHTTP: Bool = false,
        supportsMCPSSE: Bool = false,
        message: String
    ) {
        self.ok = ok
        self.targetId = targetId
        self.targetTitle = targetTitle
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.supportsSessionList = supportsSessionList
        self.supportsLoadSession = supportsLoadSession
        self.supportsPromptImage = supportsPromptImage
        self.supportsMCPHTTP = supportsMCPHTTP
        self.supportsMCPSSE = supportsMCPSSE
        self.message = message
    }
}

public struct AgentTokenUsageResponse: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int
    public var totalCostUSD: Double

    public init(inputTokens: Int, outputTokens: Int, cachedTokens: Int, totalCostUSD: Double) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.totalCostUSD = totalCostUSD
    }
}

// MARK: - Channel Plugins

public struct ChannelPluginRecord: Codable, Sendable, Equatable {
    /// Delivery mode constants.
    public enum DeliveryMode {
        public static let http = "http"
        public static let inProcess = "in-process"
    }

    public var id: String
    public var type: String
    /// HTTP base URL for out-of-process plugins. Empty for in-process plugins.
    public var baseUrl: String
    public var channelIds: [String]
    public var config: [String: String]
    public var enabled: Bool
    /// `"http"` (default) or `"in-process"`. Determines how sloppy delivers messages.
    public var deliveryMode: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        type: String,
        baseUrl: String,
        channelIds: [String] = [],
        config: [String: String] = [:],
        enabled: Bool = true,
        deliveryMode: String = DeliveryMode.http,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.baseUrl = baseUrl
        self.channelIds = channelIds
        self.config = config
        self.enabled = enabled
        self.deliveryMode = deliveryMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One slash command for channel bots; mirrors ``ChannelCommandHandler.commands`` (Telegram/Discord).
public struct ChannelSlashCommandItem: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var argument: String?

    public init(name: String, description: String, argument: String? = nil) {
        self.name = name
        self.description = description
        self.argument = argument
    }
}

public struct ChannelSlashCommandsResponse: Codable, Sendable, Equatable {
    public var commands: [ChannelSlashCommandItem]

    public init(commands: [ChannelSlashCommandItem]) {
        self.commands = commands
    }
}

/// Slash menu entries for agent chat (channel builtins + per-agent skills).
public struct AgentChatSlashCommandItem: Codable, Sendable, Equatable {
    /// `"channel"` (shared plugin commands) or `"skill"`.
    public var source: String
    public var name: String
    public var description: String
    public var argument: String?
    /// Set when `source == "skill"` (original `owner/repo` id).
    public var skillId: String?

    public init(source: String, name: String, description: String, argument: String? = nil, skillId: String? = nil) {
        self.source = source
        self.name = name
        self.description = description
        self.argument = argument
        self.skillId = skillId
    }
}

public struct AgentChatSlashCommandsResponse: Codable, Sendable, Equatable {
    public var commands: [AgentChatSlashCommandItem]

    public init(commands: [AgentChatSlashCommandItem]) {
        self.commands = commands
    }
}

public struct ChannelPluginCreateRequest: Codable, Sendable {
    public var id: String?
    public var type: String
    public var baseUrl: String
    public var channelIds: [String]?
    public var config: [String: String]?
    public var enabled: Bool?

    public init(
        id: String? = nil,
        type: String,
        baseUrl: String,
        channelIds: [String]? = nil,
        config: [String: String]? = nil,
        enabled: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.baseUrl = baseUrl
        self.channelIds = channelIds
        self.config = config
        self.enabled = enabled
    }
}

public struct ChannelPluginUpdateRequest: Codable, Sendable {
    public var type: String?
    public var baseUrl: String?
    public var channelIds: [String]?
    public var config: [String: String]?
    public var enabled: Bool?

    public init(
        type: String? = nil,
        baseUrl: String? = nil,
        channelIds: [String]? = nil,
        config: [String: String]? = nil,
        enabled: Bool? = nil
    ) {
        self.type = type
        self.baseUrl = baseUrl
        self.channelIds = channelIds
        self.config = config
        self.enabled = enabled
    }
}

public struct ChannelPluginInstallRequest: Codable, Sendable {
    public var sourceUrl: String
    public var ref: String?
    public var force: Bool?
    public var enabled: Bool?

    public init(
        sourceUrl: String,
        ref: String? = nil,
        force: Bool? = nil,
        enabled: Bool? = nil
    ) {
        self.sourceUrl = sourceUrl
        self.ref = ref
        self.force = force
        self.enabled = enabled
    }
}

public struct ChannelPluginInstallResponse: Codable, Sendable {
    public var plugin: ChannelPluginRecord
    public var sourcePath: String
    public var binaryPath: String
    public var rebuilt: Bool

    public init(
        plugin: ChannelPluginRecord,
        sourcePath: String,
        binaryPath: String,
        rebuilt: Bool
    ) {
        self.plugin = plugin
        self.sourcePath = sourcePath
        self.binaryPath = binaryPath
        self.rebuilt = rebuilt
    }
}

public struct ChannelPluginDeliverRequest: Codable, Sendable {
    public var channelId: String
    public var userId: String
    public var content: String

    public init(channelId: String, userId: String, content: String) {
        self.channelId = channelId
        self.userId = userId
        self.content = content
    }
}

public struct ChannelPluginStreamStartRequest: Codable, Sendable {
    public var channelId: String
    public var userId: String

    public init(channelId: String, userId: String) {
        self.channelId = channelId
        self.userId = userId
    }
}

public struct ChannelPluginStreamStartResponse: Codable, Sendable {
    public var ok: Bool
    public var streamId: String?

    public init(ok: Bool, streamId: String? = nil) {
        self.ok = ok
        self.streamId = streamId
    }
}

public struct ChannelPluginStreamChunkRequest: Codable, Sendable {
    public var streamId: String
    public var channelId: String
    public var content: String

    public init(streamId: String, channelId: String, content: String) {
        self.streamId = streamId
        self.channelId = channelId
        self.content = content
    }
}

public struct ChannelPluginStreamEndRequest: Codable, Sendable {
    public var streamId: String
    public var channelId: String
    public var userId: String
    public var content: String?

    public init(streamId: String, channelId: String, userId: String, content: String? = nil) {
        self.streamId = streamId
        self.channelId = channelId
        self.userId = userId
        self.content = content
    }
}

public enum AgentPolicyDefault: String, Codable, Sendable {
    case allow
    case deny
}

public struct AgentToolsGuardrails: Codable, Sendable, Equatable {
    public var maxReadBytes: Int
    public var maxWriteBytes: Int
    public var execTimeoutMs: Int
    public var maxExecTimeoutMs: Int
    public var maxExecOutputBytes: Int
    public var maxProcessesPerSession: Int
    public var maxToolCallsPerMinute: Int
    public var toolLoopWindowSeconds: Int
    public var maxConsecutiveIdenticalToolCalls: Int
    public var maxIdenticalToolCallsPerWindow: Int
    public var maxRepeatedNonRetryableFailures: Int
    public var deniedCommandPrefixes: [String]
    public var allowedWriteRoots: [String]
    public var allowedExecRoots: [String]
    public var webTimeoutMs: Int
    public var webMaxBytes: Int
    public var webBlockPrivateNetworks: Bool

    public init(
        maxReadBytes: Int = 512 * 1024,
        maxWriteBytes: Int = 512 * 1024,
        execTimeoutMs: Int = 15_000,
        maxExecTimeoutMs: Int = 120_000,
        maxExecOutputBytes: Int = 256 * 1024,
        maxProcessesPerSession: Int = 2,
        maxToolCallsPerMinute: Int = 60,
        toolLoopWindowSeconds: Int = 60,
        maxConsecutiveIdenticalToolCalls: Int = 3,
        maxIdenticalToolCallsPerWindow: Int = 6,
        maxRepeatedNonRetryableFailures: Int = 2,
        deniedCommandPrefixes: [String] = ["rm", "shutdown", "reboot", "mkfs", "dd", "killall", "launchctl"],
        allowedWriteRoots: [String] = [],
        allowedExecRoots: [String] = [],
        webTimeoutMs: Int = 10_000,
        webMaxBytes: Int = 512 * 1024,
        webBlockPrivateNetworks: Bool = true
    ) {
        self.maxReadBytes = maxReadBytes
        self.maxWriteBytes = maxWriteBytes
        self.execTimeoutMs = execTimeoutMs
        self.maxExecTimeoutMs = maxExecTimeoutMs
        self.maxExecOutputBytes = maxExecOutputBytes
        self.maxProcessesPerSession = maxProcessesPerSession
        self.maxToolCallsPerMinute = maxToolCallsPerMinute
        self.toolLoopWindowSeconds = toolLoopWindowSeconds
        self.maxConsecutiveIdenticalToolCalls = maxConsecutiveIdenticalToolCalls
        self.maxIdenticalToolCallsPerWindow = maxIdenticalToolCallsPerWindow
        self.maxRepeatedNonRetryableFailures = maxRepeatedNonRetryableFailures
        self.deniedCommandPrefixes = deniedCommandPrefixes
        self.allowedWriteRoots = allowedWriteRoots
        self.allowedExecRoots = allowedExecRoots
        self.webTimeoutMs = webTimeoutMs
        self.webMaxBytes = webMaxBytes
        self.webBlockPrivateNetworks = webBlockPrivateNetworks
    }

    private enum CodingKeys: String, CodingKey {
        case maxReadBytes
        case maxWriteBytes
        case execTimeoutMs
        case maxExecTimeoutMs
        case maxExecOutputBytes
        case maxProcessesPerSession
        case maxToolCallsPerMinute
        case toolLoopWindowSeconds
        case maxConsecutiveIdenticalToolCalls
        case maxIdenticalToolCallsPerWindow
        case maxRepeatedNonRetryableFailures
        case deniedCommandPrefixes
        case allowedWriteRoots
        case allowedExecRoots
        case webTimeoutMs
        case webMaxBytes
        case webBlockPrivateNetworks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentToolsGuardrails()
        self.init(
            maxReadBytes: try container.decodeIfPresent(Int.self, forKey: .maxReadBytes) ?? defaults.maxReadBytes,
            maxWriteBytes: try container.decodeIfPresent(Int.self, forKey: .maxWriteBytes) ?? defaults.maxWriteBytes,
            execTimeoutMs: try container.decodeIfPresent(Int.self, forKey: .execTimeoutMs) ?? defaults.execTimeoutMs,
            maxExecTimeoutMs: try container.decodeIfPresent(Int.self, forKey: .maxExecTimeoutMs) ?? defaults.maxExecTimeoutMs,
            maxExecOutputBytes: try container.decodeIfPresent(Int.self, forKey: .maxExecOutputBytes) ?? defaults.maxExecOutputBytes,
            maxProcessesPerSession: try container.decodeIfPresent(Int.self, forKey: .maxProcessesPerSession) ?? defaults.maxProcessesPerSession,
            maxToolCallsPerMinute: try container.decodeIfPresent(Int.self, forKey: .maxToolCallsPerMinute) ?? defaults.maxToolCallsPerMinute,
            toolLoopWindowSeconds: try container.decodeIfPresent(Int.self, forKey: .toolLoopWindowSeconds) ?? defaults.toolLoopWindowSeconds,
            maxConsecutiveIdenticalToolCalls: try container.decodeIfPresent(Int.self, forKey: .maxConsecutiveIdenticalToolCalls) ?? defaults.maxConsecutiveIdenticalToolCalls,
            maxIdenticalToolCallsPerWindow: try container.decodeIfPresent(Int.self, forKey: .maxIdenticalToolCallsPerWindow) ?? defaults.maxIdenticalToolCallsPerWindow,
            maxRepeatedNonRetryableFailures: try container.decodeIfPresent(Int.self, forKey: .maxRepeatedNonRetryableFailures) ?? defaults.maxRepeatedNonRetryableFailures,
            deniedCommandPrefixes: try container.decodeIfPresent([String].self, forKey: .deniedCommandPrefixes) ?? defaults.deniedCommandPrefixes,
            allowedWriteRoots: try container.decodeIfPresent([String].self, forKey: .allowedWriteRoots) ?? defaults.allowedWriteRoots,
            allowedExecRoots: try container.decodeIfPresent([String].self, forKey: .allowedExecRoots) ?? defaults.allowedExecRoots,
            webTimeoutMs: try container.decodeIfPresent(Int.self, forKey: .webTimeoutMs) ?? defaults.webTimeoutMs,
            webMaxBytes: try container.decodeIfPresent(Int.self, forKey: .webMaxBytes) ?? defaults.webMaxBytes,
            webBlockPrivateNetworks: try container.decodeIfPresent(Bool.self, forKey: .webBlockPrivateNetworks) ?? defaults.webBlockPrivateNetworks
        )
    }
}

public struct AgentToolsPolicy: Codable, Sendable, Equatable {
    public var version: Int
    public var defaultPolicy: AgentPolicyDefault
    public var tools: [String: Bool]
    public var approval: AgentToolApprovalSettings
    public var preToolsHook: AgentToolPreHookOverride
    public var guardrails: AgentToolsGuardrails

    public init(
        version: Int = 1,
        defaultPolicy: AgentPolicyDefault = .allow,
        tools: [String: Bool] = [:],
        approval: AgentToolApprovalSettings = .init(),
        preToolsHook: AgentToolPreHookOverride = .init(),
        guardrails: AgentToolsGuardrails = .init()
    ) {
        self.version = version
        self.defaultPolicy = defaultPolicy
        self.tools = tools
        self.approval = approval
        self.preToolsHook = preToolsHook
        self.guardrails = guardrails
    }

    enum CodingKeys: String, CodingKey {
        case version
        case defaultPolicy
        case tools
        case approval
        case preToolsHook
        case guardrails
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.defaultPolicy = try container.decodeIfPresent(AgentPolicyDefault.self, forKey: .defaultPolicy) ?? .allow
        self.tools = try container.decodeIfPresent([String: Bool].self, forKey: .tools) ?? [:]
        self.approval = try container.decodeIfPresent(AgentToolApprovalSettings.self, forKey: .approval) ?? .init()
        self.preToolsHook = try container.decodeIfPresent(AgentToolPreHookOverride.self, forKey: .preToolsHook) ?? .init()
        self.guardrails = try container.decodeIfPresent(AgentToolsGuardrails.self, forKey: .guardrails) ?? .init()
    }
}

public struct AgentToolApprovalSettings: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

public enum ToolHookFailurePolicy: String, Codable, Sendable, Equatable {
    case allow
    case block
}

public struct AgentToolPreHookOverride: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var command: String?
    public var arguments: [String]?
    public var timeoutMs: Int?
    public var maxOutputBytes: Int?
    public var failurePolicy: ToolHookFailurePolicy?

    public init(
        enabled: Bool? = nil,
        command: String? = nil,
        arguments: [String]? = nil,
        timeoutMs: Int? = nil,
        maxOutputBytes: Int? = nil,
        failurePolicy: ToolHookFailurePolicy? = nil
    ) {
        self.enabled = enabled
        self.command = command
        self.arguments = arguments
        self.timeoutMs = timeoutMs
        self.maxOutputBytes = maxOutputBytes
        self.failurePolicy = failurePolicy
    }
}

public struct AgentToolsUpdateRequest: Codable, Sendable {
    public var version: Int?
    public var defaultPolicy: AgentPolicyDefault
    public var tools: [String: Bool]
    public var approval: AgentToolApprovalSettings
    public var preToolsHook: AgentToolPreHookOverride
    public var guardrails: AgentToolsGuardrails

    public init(
        version: Int? = nil,
        defaultPolicy: AgentPolicyDefault = .allow,
        tools: [String: Bool] = [:],
        approval: AgentToolApprovalSettings = .init(),
        preToolsHook: AgentToolPreHookOverride = .init(),
        guardrails: AgentToolsGuardrails = .init()
    ) {
        self.version = version
        self.defaultPolicy = defaultPolicy
        self.tools = tools
        self.approval = approval
        self.preToolsHook = preToolsHook
        self.guardrails = guardrails
    }

    enum CodingKeys: String, CodingKey {
        case version
        case defaultPolicy
        case tools
        case approval
        case preToolsHook
        case guardrails
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.defaultPolicy = try container.decodeIfPresent(AgentPolicyDefault.self, forKey: .defaultPolicy) ?? .allow
        self.tools = try container.decodeIfPresent([String: Bool].self, forKey: .tools) ?? [:]
        self.approval = try container.decodeIfPresent(AgentToolApprovalSettings.self, forKey: .approval) ?? .init()
        self.preToolsHook = try container.decodeIfPresent(AgentToolPreHookOverride.self, forKey: .preToolsHook) ?? .init()
        self.guardrails = try container.decodeIfPresent(AgentToolsGuardrails.self, forKey: .guardrails) ?? .init()
    }
}

public struct AgentToolCatalogEntry: Codable, Sendable, Equatable {
    public var id: String
    public var domain: String
    public var title: String
    public var status: String
    public var description: String

    public init(id: String, domain: String, title: String, status: String, description: String) {
        self.id = id
        self.domain = domain
        self.title = title
        self.status = status
        self.description = description
    }
}

public struct ToolInvocationRequest: Codable, Sendable {
    public var tool: String
    public var arguments: [String: JSONValue]
    public var reason: String?

    public init(tool: String, arguments: [String: JSONValue] = [:], reason: String? = nil) {
        self.tool = tool
        self.arguments = arguments
        self.reason = reason
    }
}

public enum ToolApprovalStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case approved
    case rejected
    case timedOut = "timed_out"
}

public struct ToolApprovalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: ToolApprovalStatus
    public var agentId: String
    public var sessionId: String?
    public var channelId: String?
    public var topicId: String?
    public var tool: String
    public var arguments: [String: JSONValue]
    public var reason: String?
    public var requestedBy: String?
    public var decidedBy: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date

    public init(
        id: String = UUID().uuidString,
        status: ToolApprovalStatus = .pending,
        agentId: String,
        sessionId: String? = nil,
        channelId: String? = nil,
        topicId: String? = nil,
        tool: String,
        arguments: [String: JSONValue] = [:],
        reason: String? = nil,
        requestedBy: String? = nil,
        decidedBy: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.status = status
        self.agentId = agentId
        self.sessionId = sessionId
        self.channelId = channelId
        self.topicId = topicId
        self.tool = tool
        self.arguments = arguments
        self.reason = reason
        self.requestedBy = requestedBy
        self.decidedBy = decidedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

public struct ToolApprovalDecisionRequest: Codable, Sendable, Equatable {
    public var decidedBy: String?
    public var scope: ToolApprovalDecisionScope

    public init(decidedBy: String? = nil, scope: ToolApprovalDecisionScope = .once) {
        self.decidedBy = decidedBy
        self.scope = scope
    }
}

public enum ToolApprovalDecisionScope: String, Codable, Sendable, Equatable, CaseIterable {
    case once
    case session
}

extension ToolApprovalDecisionRequest {
    enum CodingKeys: String, CodingKey {
        case decidedBy
        case scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.decidedBy = try container.decodeIfPresent(String.self, forKey: .decidedBy)
        self.scope = try container.decodeIfPresent(ToolApprovalDecisionScope.self, forKey: .scope) ?? .once
    }
}

public struct ToolErrorPayload: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool
    /// Optional guidance for the caller (e.g. how to fix path or permissions).
    public var hint: String?

    public init(code: String, message: String, retryable: Bool, hint: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.hint = hint
    }
}

public struct ToolInvocationResult: Codable, Sendable, Equatable {
    public var tool: String
    public var ok: Bool
    public var data: JSONValue?
    public var error: ToolErrorPayload?
    public var durationMs: Int

    public init(
        tool: String,
        ok: Bool,
        data: JSONValue? = nil,
        error: ToolErrorPayload? = nil,
        durationMs: Int = 0
    ) {
        self.tool = tool
        self.ok = ok
        self.data = data
        self.error = error
        self.durationMs = durationMs
    }
}

public struct SessionStatusResponse: Codable, Sendable, Equatable {
    public var sessionId: String
    public var status: String
    public var messageCount: Int
    public var updatedAt: Date
    public var activeProcessCount: Int

    public init(
        sessionId: String,
        status: String,
        messageCount: Int,
        updatedAt: Date,
        activeProcessCount: Int
    ) {
        self.sessionId = sessionId
        self.status = status
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.activeProcessCount = activeProcessCount
    }
}

public enum AgentSessionKind: String, Codable, Sendable, Equatable {
    case chat
    case heartbeat
}

public struct AgentSessionCreateRequest: Codable, Sendable {
    public var title: String?
    public var parentSessionId: String?
    public var kind: AgentSessionKind
    /// When set, runs a memory checkpoint on this session before creating the new one (e.g. `/new`).
    public var checkpointSessionId: String?
    /// When set, project repo/docs context is merged into the agent session bootstrap (Dashboard project chats).
    public var projectId: String?

    public init(
        title: String? = nil,
        parentSessionId: String? = nil,
        kind: AgentSessionKind = .chat,
        checkpointSessionId: String? = nil,
        projectId: String? = nil
    ) {
        self.title = title
        self.parentSessionId = parentSessionId
        self.kind = kind
        self.checkpointSessionId = checkpointSessionId
        self.projectId = projectId
    }

    enum CodingKeys: String, CodingKey {
        case title
        case parentSessionId
        case kind
        case checkpointSessionId
        case projectId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        kind = try container.decodeIfPresent(AgentSessionKind.self, forKey: .kind) ?? .chat
        checkpointSessionId = try container.decodeIfPresent(String.self, forKey: .checkpointSessionId)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
    }
}

public struct AgentMemoryCheckpointRequest: Codable, Sendable {
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct AgentMemoryCheckpointResponse: Codable, Sendable {
    public var ok: Bool
    public var reason: String?

    public init(ok: Bool, reason: String? = nil) {
        self.ok = ok
        self.reason = reason
    }
}

public struct AgentSessionSummary: Codable, Sendable, Equatable {
    public var id: String
    public var agentId: String
    public var title: String
    public var parentSessionId: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var lastMessagePreview: String?
    public var kind: AgentSessionKind
    /// User-authored turns since last memory checkpoint (persisted in session sidecar).
    public var userTurnCount: Int
    /// Optional project scope (Dashboard project chats).
    public var projectId: String?

    public init(
        id: String,
        agentId: String,
        title: String,
        parentSessionId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messageCount: Int = 0,
        lastMessagePreview: String? = nil,
        kind: AgentSessionKind = .chat,
        userTurnCount: Int = 0,
        projectId: String? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.parentSessionId = parentSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.lastMessagePreview = lastMessagePreview
        self.kind = kind
        self.userTurnCount = userTurnCount
        self.projectId = projectId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case agentId
        case title
        case parentSessionId
        case createdAt
        case updatedAt
        case messageCount
        case lastMessagePreview
        case kind
        case userTurnCount
        case projectId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentId = try container.decode(String.self, forKey: .agentId)
        title = try container.decode(String.self, forKey: .title)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        kind = try container.decodeIfPresent(AgentSessionKind.self, forKey: .kind) ?? .chat
        userTurnCount = try container.decodeIfPresent(Int.self, forKey: .userTurnCount) ?? 0
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(agentId, forKey: .agentId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(parentSessionId, forKey: .parentSessionId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encodeIfPresent(lastMessagePreview, forKey: .lastMessagePreview)
        try container.encode(kind, forKey: .kind)
        try container.encode(userTurnCount, forKey: .userTurnCount)
        try container.encodeIfPresent(projectId, forKey: .projectId)
    }
}

public enum AgentSessionEventType: String, Codable, Sendable {
    case sessionCreated = "session_created"
    case message
    case runStatus = "run_status"
    case buildProgress = "build_progress"
    case subSession = "sub_session"
    case runControl = "run_control"
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case inputRequest = "input_request"
    case inputResponse = "input_response"
}

public enum AgentMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public enum AgentMessageSegmentKind: String, Codable, Sendable {
    case text
    case thinking
    case attachment
}

public struct AgentAttachment: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var relativePath: String?

    public init(
        id: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        relativePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.relativePath = relativePath
    }
}

public struct AgentMessageSegment: Codable, Sendable, Equatable {
    public var kind: AgentMessageSegmentKind
    public var text: String?
    public var attachment: AgentAttachment?

    public init(kind: AgentMessageSegmentKind, text: String? = nil, attachment: AgentAttachment? = nil) {
        self.kind = kind
        self.text = text
        self.attachment = attachment
    }
}

public struct AgentSessionMessage: Codable, Sendable, Equatable {
    public var id: String
    public var role: AgentMessageRole
    public var segments: [AgentMessageSegment]
    public var createdAt: Date
    public var userId: String?

    public init(
        id: String = UUID().uuidString,
        role: AgentMessageRole,
        segments: [AgentMessageSegment],
        createdAt: Date = Date(),
        userId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.segments = segments
        self.createdAt = createdAt
        self.userId = userId
    }
}

public enum AgentRunStage: String, Codable, Sendable {
    case thinking
    case searching
    case responding
    case paused
    case done
    case interrupted
}

public struct AgentRunStatusEvent: Codable, Sendable, Equatable {
    public var id: String
    public var stage: AgentRunStage
    public var label: String
    public var details: String?
    public var expandedText: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        stage: AgentRunStage,
        label: String,
        details: String? = nil,
        expandedText: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.label = label
        self.details = details
        self.expandedText = expandedText
        self.createdAt = createdAt
    }
}

public enum AgentBuildProgressStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case done
    case blocked
    case skipped
}

public struct AgentBuildProgressItem: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: AgentBuildProgressStatus
    public var definitionOfDone: String
    public var details: String?

    public init(
        id: String,
        title: String,
        status: AgentBuildProgressStatus,
        definitionOfDone: String,
        details: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.definitionOfDone = definitionOfDone
        self.details = details
    }
}

public struct AgentBuildProgressEvent: Codable, Sendable, Equatable {
    public var title: String
    public var items: [AgentBuildProgressItem]
    public var createdAt: Date

    public init(
        title: String,
        items: [AgentBuildProgressItem],
        createdAt: Date = Date()
    ) {
        self.title = title
        self.items = items
        self.createdAt = createdAt
    }
}

public struct AgentSubSessionEvent: Codable, Sendable, Equatable {
    public var childSessionId: String
    public var title: String

    public init(childSessionId: String, title: String) {
        self.childSessionId = childSessionId
        self.title = title
    }
}

public enum AgentRunControlAction: String, Codable, Sendable {
    case pause
    case resume
    case interrupt
    case interruptTree
}

public struct AgentRunControlEvent: Codable, Sendable, Equatable {
    public var action: AgentRunControlAction
    public var requestedBy: String
    public var reason: String?

    public init(action: AgentRunControlAction, requestedBy: String, reason: String? = nil) {
        self.action = action
        self.requestedBy = requestedBy
        self.reason = reason
    }
}

public struct AgentToolCallEvent: Codable, Sendable, Equatable {
    public var tool: String
    public var arguments: [String: JSONValue]
    public var reason: String?

    public init(tool: String, arguments: [String: JSONValue], reason: String? = nil) {
        self.tool = tool
        self.arguments = arguments
        self.reason = reason
    }
}

public struct AgentToolResultEvent: Codable, Sendable, Equatable {
    public var tool: String
    public var ok: Bool
    public var data: JSONValue?
    public var error: ToolErrorPayload?
    public var durationMs: Int?

    public init(
        tool: String,
        ok: Bool,
        data: JSONValue? = nil,
        error: ToolErrorPayload? = nil,
        durationMs: Int? = nil
    ) {
        self.tool = tool
        self.ok = ok
        self.data = data
        self.error = error
        self.durationMs = durationMs
    }
}

public struct PlanInputOption: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct PlanInputQuestion: Codable, Sendable, Equatable {
    public var id: String
    public var header: String?
    public var question: String
    public var options: [PlanInputOption]
    public var allowCustomAnswer: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case header
        case question
        case options
        case allowCustomAnswer
    }

    public init(
        id: String,
        header: String? = nil,
        question: String,
        options: [PlanInputOption],
        allowCustomAnswer: Bool = true
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowCustomAnswer = allowCustomAnswer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        question = try container.decode(String.self, forKey: .question)
        options = try container.decode([PlanInputOption].self, forKey: .options)
        allowCustomAnswer = try container.decodeIfPresent(Bool.self, forKey: .allowCustomAnswer) ?? true
    }
}

public struct PlanInputRequest: Codable, Sendable, Equatable {
    public var id: String
    public var mode: String
    public var title: String?
    public var questions: [PlanInputQuestion]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        mode: String = "plan",
        title: String? = nil,
        questions: [PlanInputQuestion],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mode = mode
        self.title = title
        self.questions = questions
        self.createdAt = createdAt
    }
}

public enum PlanInputResponseStatus: String, Codable, Sendable, Equatable {
    case answered
    case cancelled
}

public struct PlanInputAnswer: Codable, Sendable, Equatable {
    public var questionId: String
    public var selectedOptionId: String?
    public var customAnswer: String?

    public init(questionId: String, selectedOptionId: String? = nil, customAnswer: String? = nil) {
        self.questionId = questionId
        self.selectedOptionId = selectedOptionId
        self.customAnswer = customAnswer
    }
}

public struct PlanInputResponse: Codable, Sendable, Equatable {
    public var requestId: String
    public var status: PlanInputResponseStatus
    public var answers: [PlanInputAnswer]
    public var userId: String
    public var createdAt: Date

    public init(
        requestId: String,
        status: PlanInputResponseStatus,
        answers: [PlanInputAnswer],
        userId: String,
        createdAt: Date = Date()
    ) {
        self.requestId = requestId
        self.status = status
        self.answers = answers
        self.userId = userId
        self.createdAt = createdAt
    }
}

public struct AgentSessionMetadataEvent: Codable, Sendable, Equatable {
    public var title: String
    public var parentSessionId: String?
    public var kind: AgentSessionKind
    public var projectId: String?

    public init(
        title: String,
        parentSessionId: String? = nil,
        kind: AgentSessionKind = .chat,
        projectId: String? = nil
    ) {
        self.title = title
        self.parentSessionId = parentSessionId
        self.kind = kind
        self.projectId = projectId
    }

    enum CodingKeys: String, CodingKey {
        case title
        case parentSessionId
        case kind
        case projectId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        kind = try container.decodeIfPresent(AgentSessionKind.self, forKey: .kind) ?? .chat
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
    }
}

public struct AgentSessionEvent: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var agentId: String
    public var sessionId: String
    public var type: AgentSessionEventType
    public var createdAt: Date
    public var metadata: AgentSessionMetadataEvent?
    public var message: AgentSessionMessage?
    public var runStatus: AgentRunStatusEvent?
    public var buildProgress: AgentBuildProgressEvent?
    public var subSession: AgentSubSessionEvent?
    public var runControl: AgentRunControlEvent?
    public var toolCall: AgentToolCallEvent?
    public var toolResult: AgentToolResultEvent?
    public var inputRequest: PlanInputRequest?
    public var inputResponse: PlanInputResponse?

    public init(
        id: String = UUID().uuidString,
        version: Int = 1,
        agentId: String,
        sessionId: String,
        type: AgentSessionEventType,
        createdAt: Date = Date(),
        metadata: AgentSessionMetadataEvent? = nil,
        message: AgentSessionMessage? = nil,
        runStatus: AgentRunStatusEvent? = nil,
        buildProgress: AgentBuildProgressEvent? = nil,
        subSession: AgentSubSessionEvent? = nil,
        runControl: AgentRunControlEvent? = nil,
        toolCall: AgentToolCallEvent? = nil,
        toolResult: AgentToolResultEvent? = nil,
        inputRequest: PlanInputRequest? = nil,
        inputResponse: PlanInputResponse? = nil
    ) {
        self.id = id
        self.version = version
        self.agentId = agentId
        self.sessionId = sessionId
        self.type = type
        self.createdAt = createdAt
        self.metadata = metadata
        self.message = message
        self.runStatus = runStatus
        self.buildProgress = buildProgress
        self.subSession = subSession
        self.runControl = runControl
        self.toolCall = toolCall
        self.toolResult = toolResult
        self.inputRequest = inputRequest
        self.inputResponse = inputResponse
    }
}

public struct PlanInputAnswerRequest: Codable, Sendable, Equatable {
    public var status: PlanInputResponseStatus
    public var answers: [PlanInputAnswer]
    public var userId: String

    public init(status: PlanInputResponseStatus = .answered, answers: [PlanInputAnswer], userId: String) {
        self.status = status
        self.answers = answers
        self.userId = userId
    }
}

public struct AgentSessionDetail: Codable, Sendable, Equatable {
    public var summary: AgentSessionSummary
    public var events: [AgentSessionEvent]

    public init(summary: AgentSessionSummary, events: [AgentSessionEvent]) {
        self.summary = summary
        self.events = events
    }
}

public struct AgentAttachmentUpload: Codable, Sendable {
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var contentBase64: String?

    public init(
        name: String,
        mimeType: String,
        sizeBytes: Int,
        contentBase64: String? = nil
    ) {
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentBase64 = contentBase64
    }
}

public enum ReasoningEffort: String, Codable, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high
}

public enum AgentChatMode: String, Codable, Sendable, Equatable, CaseIterable {
    case ask
    case build
    case plan
    case debug

    public static let defaultMode: AgentChatMode = .build
}

public struct AgentSessionPostMessageRequest: Codable, Sendable {
    public var userId: String
    public var content: String
    public var attachments: [AgentAttachmentUpload]
    public var spawnSubSession: Bool
    public var reasoningEffort: ReasoningEffort?
    /// When set and allowed for the agent, overrides catalog `selectedModel` for this turn only.
    public var selectedModel: String?
    public var mode: AgentChatMode?

    public init(
        userId: String,
        content: String,
        attachments: [AgentAttachmentUpload] = [],
        spawnSubSession: Bool = false,
        reasoningEffort: ReasoningEffort? = nil,
        selectedModel: String? = nil,
        mode: AgentChatMode? = nil
    ) {
        self.userId = userId
        self.content = content
        self.attachments = attachments
        self.spawnSubSession = spawnSubSession
        self.reasoningEffort = reasoningEffort
        self.selectedModel = selectedModel
        self.mode = mode
    }
}

public struct AgentSessionControlRequest: Codable, Sendable {
    public var action: AgentRunControlAction
    public var requestedBy: String
    public var reason: String?

    public init(action: AgentRunControlAction, requestedBy: String, reason: String? = nil) {
        self.action = action
        self.requestedBy = requestedBy
        self.reason = reason
    }
}

public struct AgentSessionDirectoryRequest: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct AgentSessionDirectoryResponse: Codable, Sendable, Equatable {
    public var path: String
    public var workingDirectory: String?
    public var directories: [String]

    public init(path: String, workingDirectory: String? = nil, directories: [String]) {
        self.path = path
        self.workingDirectory = workingDirectory
        self.directories = directories
    }
}

public struct AgentSessionAppendEventsRequest: Codable, Sendable {
    public var events: [AgentSessionEvent]

    public init(events: [AgentSessionEvent]) {
        self.events = events
    }
}

public struct AgentSessionMessageResponse: Codable, Sendable {
    public var summary: AgentSessionSummary
    public var appendedEvents: [AgentSessionEvent]
    public var routeDecision: ChannelRouteDecision?

    public init(summary: AgentSessionSummary, appendedEvents: [AgentSessionEvent], routeDecision: ChannelRouteDecision?) {
        self.summary = summary
        self.appendedEvents = appendedEvents
        self.routeDecision = routeDecision
    }
}

public enum ProviderAuthMethod: String, Codable, Sendable {
    case apiKey = "api_key"
    case deeplink
}

public enum ProviderProbeID: String, Codable, Sendable {
    case openAIAPI = "openai-api"
    case openAIOAuth = "openai-oauth"
    case openRouter = "openrouter"
    case ollama
    case gemini
    case anthropic
    case anthropicOAuth = "anthropic-oauth"
}

public struct ProviderProbeRequest: Codable, Sendable {
    public var providerId: ProviderProbeID
    public var apiKey: String?
    public var apiUrl: String?

    public init(providerId: ProviderProbeID, apiKey: String? = nil, apiUrl: String? = nil) {
        self.providerId = providerId
        self.apiKey = apiKey
        self.apiUrl = apiUrl
    }
}

public struct OpenAIProviderModelsRequest: Codable, Sendable {
    public var authMethod: ProviderAuthMethod
    public var apiKey: String?
    public var apiUrl: String?

    public init(authMethod: ProviderAuthMethod, apiKey: String? = nil, apiUrl: String? = nil) {
        self.authMethod = authMethod
        self.apiKey = apiKey
        self.apiUrl = apiUrl
    }
}

public struct ProviderModelOption: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var contextWindow: String?
    public var capabilities: [String]

    public init(
        id: String,
        title: String,
        contextWindow: String? = nil,
        capabilities: [String] = []
    ) {
        self.id = id
        self.title = title
        self.contextWindow = contextWindow
        self.capabilities = capabilities
    }
}

public struct OpenAIProviderModelsResponse: Codable, Sendable {
    public var provider: String
    public var authMethod: ProviderAuthMethod
    public var usedEnvironmentKey: Bool
    public var source: String
    public var warning: String?
    public var models: [ProviderModelOption]

    public init(
        provider: String,
        authMethod: ProviderAuthMethod,
        usedEnvironmentKey: Bool,
        source: String,
        warning: String?,
        models: [ProviderModelOption]
    ) {
        self.provider = provider
        self.authMethod = authMethod
        self.usedEnvironmentKey = usedEnvironmentKey
        self.source = source
        self.warning = warning
        self.models = models
    }
}

public struct OpenAIProviderStatusResponse: Codable, Sendable {
    public var provider: String
    public var hasEnvironmentKey: Bool
    public var hasConfiguredKey: Bool
    public var hasAnyKey: Bool
    public var hasOAuthCredentials: Bool
    public var oauthAccountId: String?
    public var oauthPlanType: String?
    public var oauthExpiresAt: String?

    public init(
        provider: String,
        hasEnvironmentKey: Bool,
        hasConfiguredKey: Bool,
        hasAnyKey: Bool,
        hasOAuthCredentials: Bool = false,
        oauthAccountId: String? = nil,
        oauthPlanType: String? = nil,
        oauthExpiresAt: String? = nil
    ) {
        self.provider = provider
        self.hasEnvironmentKey = hasEnvironmentKey
        self.hasConfiguredKey = hasConfiguredKey
        self.hasAnyKey = hasAnyKey
        self.hasOAuthCredentials = hasOAuthCredentials
        self.oauthAccountId = oauthAccountId
        self.oauthPlanType = oauthPlanType
        self.oauthExpiresAt = oauthExpiresAt
    }
}

public struct AnthropicProviderStatusResponse: Codable, Sendable {
    public var provider: String
    public var hasEnvironmentKey: Bool
    public var hasConfiguredKey: Bool
    public var hasAnyKey: Bool
    public var hasOAuthCredentials: Bool
    public var oauthSource: String?
    public var oauthExpiresAt: String?
    public var oauthRefreshable: Bool

    public init(
        provider: String,
        hasEnvironmentKey: Bool,
        hasConfiguredKey: Bool,
        hasAnyKey: Bool,
        hasOAuthCredentials: Bool = false,
        oauthSource: String? = nil,
        oauthExpiresAt: String? = nil,
        oauthRefreshable: Bool = false
    ) {
        self.provider = provider
        self.hasEnvironmentKey = hasEnvironmentKey
        self.hasConfiguredKey = hasConfiguredKey
        self.hasAnyKey = hasAnyKey
        self.hasOAuthCredentials = hasOAuthCredentials
        self.oauthSource = oauthSource
        self.oauthExpiresAt = oauthExpiresAt
        self.oauthRefreshable = oauthRefreshable
    }
}

public struct OpenAIOAuthStartRequest: Codable, Sendable {
    public var redirectURI: String

    public init(redirectURI: String) {
        self.redirectURI = redirectURI
    }
}

public struct OpenAIOAuthStartResponse: Codable, Sendable {
    public var authorizationURL: String
    public var redirectURI: String
    public var state: String

    public init(authorizationURL: String, redirectURI: String, state: String) {
        self.authorizationURL = authorizationURL
        self.redirectURI = redirectURI
        self.state = state
    }
}

public struct OpenAIOAuthCompleteRequest: Codable, Sendable {
    public var callbackURL: String?
    public var code: String?
    public var state: String?

    public init(callbackURL: String? = nil, code: String? = nil, state: String? = nil) {
        self.callbackURL = callbackURL
        self.code = code
        self.state = state
    }
}

public struct OpenAIOAuthCompleteResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var accountId: String?
    public var planType: String?

    public init(ok: Bool, message: String, accountId: String? = nil, planType: String? = nil) {
        self.ok = ok
        self.message = message
        self.accountId = accountId
        self.planType = planType
    }
}

public struct OpenAIOAuthImportCodexResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var accountId: String?
    public var planType: String?

    public init(ok: Bool, message: String, accountId: String? = nil, planType: String? = nil) {
        self.ok = ok
        self.message = message
        self.accountId = accountId
        self.planType = planType
    }
}

public struct AnthropicOAuthStartRequest: Codable, Sendable {
    public var redirectURI: String

    public init(redirectURI: String) {
        self.redirectURI = redirectURI
    }
}

public struct AnthropicOAuthStartResponse: Codable, Sendable {
    public var authorizationURL: String
    public var redirectURI: String
    public var state: String

    public init(authorizationURL: String, redirectURI: String, state: String) {
        self.authorizationURL = authorizationURL
        self.redirectURI = redirectURI
        self.state = state
    }
}

public struct AnthropicOAuthCompleteRequest: Codable, Sendable {
    public var callbackURL: String?
    public var code: String?
    public var state: String?

    public init(callbackURL: String? = nil, code: String? = nil, state: String? = nil) {
        self.callbackURL = callbackURL
        self.code = code
        self.state = state
    }
}

public struct AnthropicOAuthCompleteResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var source: String?
    public var expiresAt: String?
    public var refreshable: Bool

    public init(
        ok: Bool,
        message: String,
        source: String? = nil,
        expiresAt: String? = nil,
        refreshable: Bool = false
    ) {
        self.ok = ok
        self.message = message
        self.source = source
        self.expiresAt = expiresAt
        self.refreshable = refreshable
    }
}

public struct AnthropicOAuthImportClaudeResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var source: String?
    public var expiresAt: String?
    public var refreshable: Bool

    public init(
        ok: Bool,
        message: String,
        source: String? = nil,
        expiresAt: String? = nil,
        refreshable: Bool = false
    ) {
        self.ok = ok
        self.message = message
        self.source = source
        self.expiresAt = expiresAt
        self.refreshable = refreshable
    }
}

public struct OpenAIDeviceCodeStartResponse: Codable, Sendable {
    public var deviceAuthId: String
    public var userCode: String
    public var verificationURL: String
    public var interval: Int
    public var expiresIn: Int

    public init(
        deviceAuthId: String,
        userCode: String,
        verificationURL: String,
        interval: Int = 5,
        expiresIn: Int = 600
    ) {
        self.deviceAuthId = deviceAuthId
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

public struct OpenAIDeviceCodePollRequest: Codable, Sendable {
    public var deviceAuthId: String
    public var userCode: String

    public init(deviceAuthId: String, userCode: String) {
        self.deviceAuthId = deviceAuthId
        self.userCode = userCode
    }
}

public struct OpenAIDeviceCodePollResponse: Codable, Sendable {
    public var status: String
    public var ok: Bool
    public var message: String
    public var accountId: String?
    public var planType: String?

    public init(
        status: String,
        ok: Bool,
        message: String,
        accountId: String? = nil,
        planType: String? = nil
    ) {
        self.status = status
        self.ok = ok
        self.message = message
        self.accountId = accountId
        self.planType = planType
    }
}

public struct GitHubConnectRequest: Codable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public struct GitHubConnectResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var username: String?

    public init(ok: Bool, message: String, username: String? = nil) {
        self.ok = ok
        self.message = message
        self.username = username
    }
}

public struct GitHubAuthStatusResponse: Codable, Sendable {
    public var connected: Bool
    public var username: String?
    public var connectedAt: String?

    public init(connected: Bool, username: String? = nil, connectedAt: String? = nil) {
        self.connected = connected
        self.username = username
        self.connectedAt = connectedAt
    }
}

public struct WorkspaceGitSyncResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var branch: String
    public var commit: String?
    public var filesChanged: Int

    public init(
        ok: Bool,
        message: String,
        branch: String,
        commit: String? = nil,
        filesChanged: Int = 0
    ) {
        self.ok = ok
        self.message = message
        self.branch = branch
        self.commit = commit
        self.filesChanged = filesChanged
    }
}

public struct ProviderProbeResponse: Codable, Sendable {
    public var providerId: ProviderProbeID
    public var ok: Bool
    public var usedEnvironmentKey: Bool
    public var message: String
    public var models: [ProviderModelOption]

    public init(
        providerId: ProviderProbeID,
        ok: Bool,
        usedEnvironmentKey: Bool,
        message: String,
        models: [ProviderModelOption]
    ) {
        self.providerId = providerId
        self.ok = ok
        self.usedEnvironmentKey = usedEnvironmentKey
        self.message = message
        self.models = models
    }
}

public struct SearchProviderStatusResponse: Codable, Sendable {
    public var provider: String
    public var hasEnvironmentKey: Bool
    public var hasConfiguredKey: Bool
    public var hasAnyKey: Bool

    public init(
        provider: String,
        hasEnvironmentKey: Bool,
        hasConfiguredKey: Bool,
        hasAnyKey: Bool
    ) {
        self.provider = provider
        self.hasEnvironmentKey = hasEnvironmentKey
        self.hasConfiguredKey = hasConfiguredKey
        self.hasAnyKey = hasAnyKey
    }
}

public struct SearchToolsStatusResponse: Codable, Sendable {
    public var activeProvider: String
    public var brave: SearchProviderStatusResponse
    public var perplexity: SearchProviderStatusResponse

    public init(
        activeProvider: String,
        brave: SearchProviderStatusResponse,
        perplexity: SearchProviderStatusResponse
    ) {
        self.activeProvider = activeProvider
        self.brave = brave
        self.perplexity = perplexity
    }
}

public enum ActorKind: String, Codable, Sendable {
    case agent
    case human
    case action
}

public enum ActorLinkDirection: String, Codable, Sendable {
    case oneWay = "one_way"
    case twoWay = "two_way"
}

public enum ActorRelationshipType: String, Codable, Sendable {
    case hierarchical
    case peer
}

public enum ActorCommunicationType: String, Codable, Sendable {
    case chat
    case task
    case event
    case discussion
}

public enum ActorSocketPosition: String, Codable, Sendable {
    case top
    case right
    case bottom
    case left
}

public enum ActorSystemRole: String, Codable, Sendable {
    case manager
    case developer
    case qa
    case reviewer
    case custom
}

public struct ActorNode: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var kind: ActorKind
    public var linkedAgentId: String?
    public var channelId: String?
    public var role: String?
    public var systemRole: ActorSystemRole?
    public var positionX: Double
    public var positionY: Double
    public var createdAt: Date

    public init(
        id: String,
        displayName: String,
        kind: ActorKind,
        linkedAgentId: String? = nil,
        channelId: String? = nil,
        role: String? = nil,
        systemRole: ActorSystemRole? = nil,
        positionX: Double = 0,
        positionY: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.linkedAgentId = linkedAgentId
        self.channelId = channelId
        self.role = role
        self.systemRole = systemRole
        self.positionX = positionX
        self.positionY = positionY
        self.createdAt = createdAt
    }
}

public enum ReviewApprovalMode: String, Codable, Sendable {
    case auto
    case human
    case agent
}

public enum ProjectAutonomousMode: String, Codable, Sendable {
    case off
    case sequential
    case parallel
}

public struct ProjectReviewSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var approvalMode: ReviewApprovalMode
    public var autonomousMode: ProjectAutonomousMode
    public var maxAutonomousRouteSteps: Int

    public init(
        enabled: Bool = true,
        approvalMode: ReviewApprovalMode = .human,
        autonomousMode: ProjectAutonomousMode = .off,
        maxAutonomousRouteSteps: Int = 6
    ) {
        self.enabled = enabled
        self.approvalMode = approvalMode
        self.autonomousMode = autonomousMode
        self.maxAutonomousRouteSteps = max(1, maxAutonomousRouteSteps)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case approvalMode
        case autonomousMode
        case maxAutonomousRouteSteps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        approvalMode = try container.decodeIfPresent(ReviewApprovalMode.self, forKey: .approvalMode) ?? .human
        autonomousMode = try container.decodeIfPresent(ProjectAutonomousMode.self, forKey: .autonomousMode) ?? .off
        maxAutonomousRouteSteps = max(1, try container.decodeIfPresent(Int.self, forKey: .maxAutonomousRouteSteps) ?? 6)
    }
}

public struct ActorLink: Codable, Sendable, Equatable {
    public var id: String
    public var sourceActorId: String
    public var targetActorId: String
    public var direction: ActorLinkDirection
    public var relationship: ActorRelationshipType?
    public var communicationType: ActorCommunicationType
    public var sourceSocket: ActorSocketPosition?
    public var targetSocket: ActorSocketPosition?
    public var createdAt: Date

    public init(
        id: String,
        sourceActorId: String,
        targetActorId: String,
        direction: ActorLinkDirection,
        relationship: ActorRelationshipType? = nil,
        communicationType: ActorCommunicationType,
        sourceSocket: ActorSocketPosition? = nil,
        targetSocket: ActorSocketPosition? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceActorId = sourceActorId
        self.targetActorId = targetActorId
        self.direction = direction
        self.relationship = relationship
        self.communicationType = communicationType
        self.sourceSocket = sourceSocket
        self.targetSocket = targetSocket
        self.createdAt = createdAt
    }
}

public struct ActorTeam: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var memberActorIds: [String]
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        memberActorIds: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.memberActorIds = memberActorIds
        self.createdAt = createdAt
    }
}

public struct ActorBoardSnapshot: Codable, Sendable, Equatable {
    public var nodes: [ActorNode]
    public var links: [ActorLink]
    public var teams: [ActorTeam]
    public var updatedAt: Date

    public init(
        nodes: [ActorNode],
        links: [ActorLink],
        teams: [ActorTeam],
        updatedAt: Date = Date()
    ) {
        self.nodes = nodes
        self.links = links
        self.teams = teams
        self.updatedAt = updatedAt
    }
}

public struct ActorBoardUpdateRequest: Codable, Sendable {
    public var nodes: [ActorNode]
    public var links: [ActorLink]
    public var teams: [ActorTeam]

    public init(nodes: [ActorNode], links: [ActorLink], teams: [ActorTeam]) {
        self.nodes = nodes
        self.links = links
        self.teams = teams
    }
}

public struct ActorRouteRequest: Codable, Sendable {
    public var fromActorId: String
    public var communicationType: ActorCommunicationType?

    public init(fromActorId: String, communicationType: ActorCommunicationType? = nil) {
        self.fromActorId = fromActorId
        self.communicationType = communicationType
    }
}

public struct ActorRouteResponse: Codable, Sendable, Equatable {
    public var fromActorId: String
    public var recipientActorIds: [String]
    public var resolvedAt: Date

    public init(
        fromActorId: String,
        recipientActorIds: [String],
        resolvedAt: Date = Date()
    ) {
        self.fromActorId = fromActorId
        self.recipientActorIds = recipientActorIds
        self.resolvedAt = resolvedAt
    }
}

// MARK: - Skills Models

/// Skill information from skills.sh registry
public struct SkillInfo: Codable, Sendable, Equatable {
    public var id: String
    public var owner: String
    public var repo: String
    public var name: String
    public var description: String?
    public var installs: Int
    public var githubUrl: String

    public init(
        id: String,
        owner: String,
        repo: String,
        name: String,
        description: String? = nil,
        installs: Int = 0,
        githubUrl: String
    ) {
        self.id = id
        self.owner = owner
        self.repo = repo
        self.name = name
        self.description = description
        self.installs = installs
        self.githubUrl = githubUrl
    }
}

/// Response from skills.sh registry API
public struct SkillsRegistryResponse: Codable, Sendable {
    public var skills: [SkillInfo]
    public var total: Int

    public init(skills: [SkillInfo], total: Int) {
        self.skills = skills
        self.total = total
    }
}

public enum SkillContext: String, Codable, Sendable, Equatable {
    case fork
}

/// Installed skill metadata stored locally
public struct InstalledSkill: Codable, Sendable, Equatable {
    public var id: String
    public var owner: String
    public var repo: String
    public var name: String
    public var description: String?
    public var installedAt: Date
    public var version: String?
    public var localPath: String
    public var userInvocable: Bool
    public var allowedTools: [String]
    public var context: SkillContext?
    public var agent: String?

    public init(
        id: String,
        owner: String,
        repo: String,
        name: String,
        description: String? = nil,
        installedAt: Date = Date(),
        version: String? = nil,
        localPath: String,
        userInvocable: Bool = true,
        allowedTools: [String] = [],
        context: SkillContext? = nil,
        agent: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.repo = repo
        self.name = name
        self.description = description
        self.installedAt = installedAt
        self.version = version
        self.localPath = localPath
        self.userInvocable = userInvocable
        self.allowedTools = allowedTools
        self.context = context
        self.agent = agent
    }

    enum CodingKeys: String, CodingKey {
        case id, owner, repo, name, description, installedAt, version, localPath
        case userInvocable, allowedTools, context, agent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        owner = try container.decode(String.self, forKey: .owner)
        repo = try container.decode(String.self, forKey: .repo)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        localPath = try container.decode(String.self, forKey: .localPath)
        userInvocable = try container.decodeIfPresent(Bool.self, forKey: .userInvocable) ?? true
        allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        context = try container.decodeIfPresent(SkillContext.self, forKey: .context)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
    }
}

/// Request to install a skill from GitHub
public struct SkillInstallRequest: Codable, Sendable {
    public var owner: String
    public var repo: String
    public var version: String?
    public var userInvocable: Bool?
    public var allowedTools: [String]?
    public var context: SkillContext?
    public var agent: String?

    public init(
        owner: String,
        repo: String,
        version: String? = nil,
        userInvocable: Bool? = nil,
        allowedTools: [String]? = nil,
        context: SkillContext? = nil,
        agent: String? = nil
    ) {
        self.owner = owner
        self.repo = repo
        self.version = version
        self.userInvocable = userInvocable
        self.allowedTools = allowedTools
        self.context = context
        self.agent = agent
    }
}

/// Manifest file format for skills.json in agent's skills directory
public struct AgentSkillsManifest: Codable, Sendable {
    public var version: Int
    public var installedSkills: [InstalledSkill]

    public init(version: Int = 1, installedSkills: [InstalledSkill] = []) {
        self.version = version
        self.installedSkills = installedSkills
    }
}

/// Response for listing agent skills
public struct AgentSkillsResponse: Codable, Sendable {
    public var agentId: String
    public var skills: [InstalledSkill]
    public var skillsPath: String

    public init(agentId: String, skills: [InstalledSkill], skillsPath: String) {
        self.agentId = agentId
        self.skills = skills
        self.skillsPath = skillsPath
    }
}

// MARK: - Token Usage Models

/// Represents a persisted token usage record.
public struct TokenUsageRecord: Codable, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var taskId: String?
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var createdAt: Date

    public init(
        id: String,
        channelId: String,
        taskId: String? = nil,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.channelId = channelId
        self.taskId = taskId
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.createdAt = createdAt
    }
}

/// Response for token usage list endpoint with aggregates.
public struct TokenUsageResponse: Codable, Sendable {
    public var items: [TokenUsageRecord]
    public var totalPromptTokens: Int
    public var totalCompletionTokens: Int
    public var totalTokens: Int

    public init(
        items: [TokenUsageRecord],
        totalPromptTokens: Int = 0,
        totalCompletionTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.items = items
        self.totalPromptTokens = totalPromptTokens
        self.totalCompletionTokens = totalCompletionTokens
        self.totalTokens = totalTokens
    }
}

public struct VisorReadyResponse: Codable, Sendable {
    public var ready: Bool

    public init(ready: Bool) {
        self.ready = ready
    }
}

public struct VisorChatRequest: Codable, Sendable {
    public var question: String

    public init(question: String) {
        self.question = question
    }
}

public struct VisorChatResponse: Codable, Sendable {
    public var answer: String

    public init(answer: String) {
        self.answer = answer
    }
}

// MARK: - Task Review

public struct ProjectFileEntry: Codable, Sendable {
    public enum EntryType: String, Codable, Sendable {
        case file
        case directory
    }

    public var name: String
    public var type: EntryType
    public var size: Int?

    public init(name: String, type: EntryType, size: Int? = nil) {
        self.name = name
        self.type = type
        self.size = size
    }
}

/// A file or directory path under the project workspace (used by `/files/search`).
public struct ProjectFileSearchEntry: Codable, Sendable {
    public var path: String
    public var type: ProjectFileEntry.EntryType

    public init(path: String, type: ProjectFileEntry.EntryType) {
        self.path = path
        self.type = type
    }
}

public struct ProjectFileContentResponse: Codable, Sendable {
    public var path: String
    public var content: String
    public var sizeBytes: Int

    public init(path: String, content: String, sizeBytes: Int) {
        self.path = path
        self.content = content
        self.sizeBytes = sizeBytes
    }
}

public struct TaskDiffResponse: Codable, Sendable {
    public var diff: String
    public var branchName: String
    public var baseBranch: String
    public var hasChanges: Bool

    public init(diff: String, branchName: String, baseBranch: String, hasChanges: Bool) {
        self.diff = diff
        self.branchName = branchName
        self.baseBranch = baseBranch
        self.hasChanges = hasChanges
    }
}

/// Working-tree diff vs `HEAD` (or all uncommitted changes when there is no commit yet).
public struct ProjectWorkingTreeGitResponse: Codable, Sendable {
    public var isGitRepository: Bool
    public var branch: String?
    public var linesAdded: Int
    public var linesDeleted: Int
    public var diff: String
    public var diffTruncated: Bool
    /// Set when `isGitRepository` is false or git could not be read.
    public var message: String?

    public init(
        isGitRepository: Bool,
        branch: String? = nil,
        linesAdded: Int = 0,
        linesDeleted: Int = 0,
        diff: String = "",
        diffTruncated: Bool = false,
        message: String? = nil
    ) {
        self.isGitRepository = isGitRepository
        self.branch = branch
        self.linesAdded = linesAdded
        self.linesDeleted = linesDeleted
        self.diff = diff
        self.diffTruncated = diffTruncated
        self.message = message
    }
}

public struct ProjectGitRestoreRequest: Codable, Sendable {
    /// Project-relative path (POSIX, no `..` segments).
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct ProjectGitRestoreResponse: Codable, Sendable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}

public struct ReviewComment: Codable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var filePath: String
    public var lineNumber: Int?
    public var side: String?
    public var content: String
    public var author: String
    public var resolved: Bool
    public var createdAt: Date

    public init(
        id: String,
        taskId: String,
        filePath: String,
        lineNumber: Int? = nil,
        side: String? = nil,
        content: String,
        author: String,
        resolved: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.side = side
        self.content = content
        self.author = author
        self.resolved = resolved
        self.createdAt = createdAt
    }
}

public struct ReviewCommentCreateRequest: Codable, Sendable {
    public var filePath: String
    public var lineNumber: Int?
    public var side: String?
    public var content: String
    public var author: String

    public init(filePath: String, lineNumber: Int? = nil, side: String? = nil, content: String, author: String) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.side = side
        self.content = content
        self.author = author
    }
}

public struct ReviewCommentUpdateRequest: Codable, Sendable {
    public var resolved: Bool?
    public var content: String?

    public init(resolved: Bool? = nil, content: String? = nil) {
        self.resolved = resolved
        self.content = content
    }
}

public struct TaskComment: Codable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var content: String
    public var authorActorId: String
    public var mentionedActorId: String?
    public var isAgentReply: Bool
    public var externalMetadata: TaskExternalMetadata?
    public var sourceAuthor: String?
    public var createdAt: Date

    public init(
        id: String,
        taskId: String,
        content: String,
        authorActorId: String,
        mentionedActorId: String? = nil,
        isAgentReply: Bool = false,
        externalMetadata: TaskExternalMetadata? = nil,
        sourceAuthor: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.content = content
        self.authorActorId = authorActorId
        self.mentionedActorId = mentionedActorId
        self.isAgentReply = isAgentReply
        self.externalMetadata = externalMetadata
        self.sourceAuthor = sourceAuthor
        self.createdAt = createdAt
    }
}

public struct TaskCommentCreateRequest: Codable, Sendable {
    public var content: String
    public var authorActorId: String
    public var mentionedActorId: String?

    public init(content: String, authorActorId: String, mentionedActorId: String? = nil) {
        self.content = content
        self.authorActorId = authorActorId
        self.mentionedActorId = mentionedActorId
    }
}

// MARK: - Task Activity

public enum TaskActivityField: String, Codable, Sendable {
    case status
    case priority
    case assignee
    case title
    case description
    case selectedModel
}

public struct TaskActivity: Codable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var field: TaskActivityField
    public var oldValue: String?
    public var newValue: String?
    public var actorId: String
    public var createdAt: Date

    public init(
        id: String,
        taskId: String,
        field: TaskActivityField,
        oldValue: String? = nil,
        newValue: String? = nil,
        actorId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.actorId = actorId
        self.createdAt = createdAt
    }
}

// MARK: - Task Clarification

public enum ClarificationStatus: String, Codable, Sendable, Equatable {
    case pending
    case answered
    case cancelled
}

public enum ClarificationTargetType: String, Codable, Sendable, Equatable {
    case human
    case actor
    case channel
}

public struct ClarificationOption: Codable, Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct TaskClarificationRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectId: String
    public var taskId: String
    public var status: ClarificationStatus
    public var targetType: ClarificationTargetType
    public var targetActorId: String?
    public var targetChannelId: String?
    public var questionText: String
    public var options: [ClarificationOption]
    public var allowNote: Bool
    public var createdByAgentId: String?
    public var selectedOptionIds: [String]
    public var note: String?
    public var createdAt: Date
    public var answeredAt: Date?

    public init(
        id: String,
        projectId: String,
        taskId: String,
        status: ClarificationStatus = .pending,
        targetType: ClarificationTargetType,
        targetActorId: String? = nil,
        targetChannelId: String? = nil,
        questionText: String,
        options: [ClarificationOption] = [],
        allowNote: Bool = true,
        createdByAgentId: String? = nil,
        selectedOptionIds: [String] = [],
        note: String? = nil,
        createdAt: Date = Date(),
        answeredAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.taskId = taskId
        self.status = status
        self.targetType = targetType
        self.targetActorId = targetActorId
        self.targetChannelId = targetChannelId
        self.questionText = questionText
        self.options = options
        self.allowNote = allowNote
        self.createdByAgentId = createdByAgentId
        self.selectedOptionIds = selectedOptionIds
        self.note = note
        self.createdAt = createdAt
        self.answeredAt = answeredAt
    }
}

public struct TaskClarificationCreateRequest: Codable, Sendable {
    public var questionText: String
    public var options: [ClarificationOption]
    public var allowNote: Bool?
    public var createdByAgentId: String?

    public init(
        questionText: String,
        options: [ClarificationOption] = [],
        allowNote: Bool? = nil,
        createdByAgentId: String? = nil
    ) {
        self.questionText = questionText
        self.options = options
        self.allowNote = allowNote
        self.createdByAgentId = createdByAgentId
    }
}

public struct TaskClarificationAnswerRequest: Codable, Sendable {
    public var selectedOptionIds: [String]
    public var note: String?

    public init(selectedOptionIds: [String] = [], note: String? = nil) {
        self.selectedOptionIds = selectedOptionIds
        self.note = note
    }
}

public struct GenerateTextRequest: Codable, Sendable {
    public var model: String
    public var prompt: String

    public init(model: String, prompt: String) {
        self.model = model
        self.prompt = prompt
    }
}

public struct GenerateTextResponse: Codable, Sendable {
    public var text: String
    public var model: String

    public init(text: String, model: String) {
        self.text = text
        self.model = model
    }
}

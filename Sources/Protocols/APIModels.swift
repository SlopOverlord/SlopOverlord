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

public struct ProjectTask: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var description: String
    public var priority: String
    public var status: String
    public var actorId: String?
    public var teamId: String?
    public var claimedActorId: String?
    public var claimedAgentId: String?
    public var swarmId: String?
    public var swarmTaskId: String?
    public var swarmParentTaskId: String?
    public var swarmDependencyIds: [String]?
    public var swarmDepth: Int?
    public var swarmActorPath: [String]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        description: String,
        priority: String,
        status: String,
        actorId: String? = nil,
        teamId: String? = nil,
        claimedActorId: String? = nil,
        claimedAgentId: String? = nil,
        swarmId: String? = nil,
        swarmTaskId: String? = nil,
        swarmParentTaskId: String? = nil,
        swarmDependencyIds: [String]? = nil,
        swarmDepth: Int? = nil,
        swarmActorPath: [String]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.actorId = actorId
        self.teamId = teamId
        self.claimedActorId = claimedActorId
        self.claimedAgentId = claimedAgentId
        self.swarmId = swarmId
        self.swarmTaskId = swarmTaskId
        self.swarmParentTaskId = swarmParentTaskId
        self.swarmDependencyIds = swarmDependencyIds
        self.swarmDepth = swarmDepth
        self.swarmActorPath = swarmActorPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProjectRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var channels: [ProjectChannel]
    public var tasks: [ProjectTask]
    public var actors: [String]
    public var teams: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        description: String,
        channels: [ProjectChannel],
        tasks: [ProjectTask],
        actors: [String] = [],
        teams: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.channels = channels
        self.tasks = tasks
        self.actors = actors
        self.teams = teams
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProjectCreateRequest: Codable, Sendable {
    public var id: String?
    public var name: String
    public var description: String?
    public var channels: [ProjectChannelCreateRequest]
    public var actors: [String]?
    public var teams: [String]?

    public init(id: String? = nil, name: String, description: String? = nil, channels: [ProjectChannelCreateRequest] = [], actors: [String]? = nil, teams: [String]? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.channels = channels
        self.actors = actors
        self.teams = teams
    }
}

public struct ProjectUpdateRequest: Codable, Sendable {
    public var name: String?
    public var description: String?
    public var actors: [String]?
    public var teams: [String]?

    public init(name: String? = nil, description: String? = nil, actors: [String]? = nil, teams: [String]? = nil) {
        self.name = name
        self.description = description
        self.actors = actors
        self.teams = teams
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

public struct ProjectTaskCreateRequest: Codable, Sendable {
    public var title: String
    public var description: String?
    public var priority: String
    public var status: String
    public var actorId: String?
    public var teamId: String?

    public init(
        title: String,
        description: String? = nil,
        priority: String,
        status: String,
        actorId: String? = nil,
        teamId: String? = nil
    ) {
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.actorId = actorId
        self.teamId = teamId
    }
}

public struct ProjectTaskUpdateRequest: Codable, Sendable {
    public var title: String?
    public var description: String?
    public var priority: String?
    public var status: String?
    public var actorId: String?
    public var teamId: String?

    public init(
        title: String? = nil,
        description: String? = nil,
        priority: String? = nil,
        status: String? = nil,
        actorId: String? = nil,
        teamId: String? = nil
    ) {
        self.title = title
        self.description = description
        self.priority = priority
        self.status = status
        self.actorId = actorId
        self.teamId = teamId
    }
}

public struct AgentCreateRequest: Codable, Sendable {
    public var id: String
    public var displayName: String
    public var role: String

    public init(id: String, displayName: String, role: String) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

public struct AgentSummary: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var role: String
    public var createdAt: Date

    public init(id: String, displayName: String, role: String, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.createdAt = createdAt
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

public struct AgentDocumentBundle: Codable, Sendable, Equatable {
    public var userMarkdown: String
    public var agentsMarkdown: String
    public var soulMarkdown: String
    public var identityMarkdown: String
    public var heartbeatMarkdown: String

    public init(
        userMarkdown: String,
        agentsMarkdown: String,
        soulMarkdown: String,
        identityMarkdown: String,
        heartbeatMarkdown: String = ""
    ) {
        self.userMarkdown = userMarkdown
        self.agentsMarkdown = agentsMarkdown
        self.soulMarkdown = soulMarkdown
        self.identityMarkdown = identityMarkdown
        self.heartbeatMarkdown = heartbeatMarkdown
    }

    enum CodingKeys: String, CodingKey {
        case userMarkdown
        case agentsMarkdown
        case soulMarkdown
        case identityMarkdown
        case heartbeatMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userMarkdown = try container.decode(String.self, forKey: .userMarkdown)
        agentsMarkdown = try container.decode(String.self, forKey: .agentsMarkdown)
        soulMarkdown = try container.decode(String.self, forKey: .soulMarkdown)
        identityMarkdown = try container.decode(String.self, forKey: .identityMarkdown)
        heartbeatMarkdown = try container.decodeIfPresent(String.self, forKey: .heartbeatMarkdown) ?? ""
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

public struct AgentConfigDetail: Codable, Sendable, Equatable {
    public var agentId: String
    public var selectedModel: String
    public var availableModels: [ProviderModelOption]
    public var documents: AgentDocumentBundle
    public var heartbeat: AgentHeartbeatSettings
    public var heartbeatStatus: AgentHeartbeatStatus

    public init(
        agentId: String,
        selectedModel: String,
        availableModels: [ProviderModelOption],
        documents: AgentDocumentBundle,
        heartbeat: AgentHeartbeatSettings = AgentHeartbeatSettings(),
        heartbeatStatus: AgentHeartbeatStatus = AgentHeartbeatStatus()
    ) {
        self.agentId = agentId
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.documents = documents
        self.heartbeat = heartbeat
        self.heartbeatStatus = heartbeatStatus
    }

    enum CodingKeys: String, CodingKey {
        case agentId
        case selectedModel
        case availableModels
        case documents
        case heartbeat
        case heartbeatStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        selectedModel = try container.decode(String.self, forKey: .selectedModel)
        availableModels = try container.decode([ProviderModelOption].self, forKey: .availableModels)
        documents = try container.decode(AgentDocumentBundle.self, forKey: .documents)
        heartbeat = try container.decodeIfPresent(AgentHeartbeatSettings.self, forKey: .heartbeat) ?? AgentHeartbeatSettings()
        heartbeatStatus = try container.decodeIfPresent(AgentHeartbeatStatus.self, forKey: .heartbeatStatus) ?? AgentHeartbeatStatus()
    }
}

public struct AgentConfigUpdateRequest: Codable, Sendable {
    public var selectedModel: String
    public var documents: AgentDocumentBundle
    public var heartbeat: AgentHeartbeatSettings

    public init(
        selectedModel: String,
        documents: AgentDocumentBundle,
        heartbeat: AgentHeartbeatSettings = AgentHeartbeatSettings()
    ) {
        self.selectedModel = selectedModel
        self.documents = documents
        self.heartbeat = heartbeat
    }

    enum CodingKeys: String, CodingKey {
        case selectedModel
        case documents
        case heartbeat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedModel = try container.decode(String.self, forKey: .selectedModel)
        documents = try container.decode(AgentDocumentBundle.self, forKey: .documents)
        heartbeat = try container.decodeIfPresent(AgentHeartbeatSettings.self, forKey: .heartbeat) ?? AgentHeartbeatSettings()
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
    /// `"http"` (default) or `"in-process"`. Determines how Core delivers messages.
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
    public var maxExecOutputBytes: Int
    public var maxProcessesPerSession: Int
    public var maxToolCallsPerMinute: Int
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
        maxExecOutputBytes: Int = 256 * 1024,
        maxProcessesPerSession: Int = 3,
        maxToolCallsPerMinute: Int = 120,
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
        self.maxExecOutputBytes = maxExecOutputBytes
        self.maxProcessesPerSession = maxProcessesPerSession
        self.maxToolCallsPerMinute = maxToolCallsPerMinute
        self.deniedCommandPrefixes = deniedCommandPrefixes
        self.allowedWriteRoots = allowedWriteRoots
        self.allowedExecRoots = allowedExecRoots
        self.webTimeoutMs = webTimeoutMs
        self.webMaxBytes = webMaxBytes
        self.webBlockPrivateNetworks = webBlockPrivateNetworks
    }
}

public struct AgentToolsPolicy: Codable, Sendable, Equatable {
    public var version: Int
    public var defaultPolicy: AgentPolicyDefault
    public var tools: [String: Bool]
    public var guardrails: AgentToolsGuardrails

    public init(
        version: Int = 1,
        defaultPolicy: AgentPolicyDefault = .allow,
        tools: [String: Bool] = [:],
        guardrails: AgentToolsGuardrails = .init()
    ) {
        self.version = version
        self.defaultPolicy = defaultPolicy
        self.tools = tools
        self.guardrails = guardrails
    }
}

public struct AgentToolsUpdateRequest: Codable, Sendable {
    public var version: Int?
    public var defaultPolicy: AgentPolicyDefault
    public var tools: [String: Bool]
    public var guardrails: AgentToolsGuardrails

    public init(
        version: Int? = nil,
        defaultPolicy: AgentPolicyDefault = .allow,
        tools: [String: Bool] = [:],
        guardrails: AgentToolsGuardrails = .init()
    ) {
        self.version = version
        self.defaultPolicy = defaultPolicy
        self.tools = tools
        self.guardrails = guardrails
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

public struct ToolErrorPayload: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
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

    public init(
        title: String? = nil,
        parentSessionId: String? = nil,
        kind: AgentSessionKind = .chat
    ) {
        self.title = title
        self.parentSessionId = parentSessionId
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case title
        case parentSessionId
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        kind = try container.decodeIfPresent(AgentSessionKind.self, forKey: .kind) ?? .chat
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

    public init(
        id: String,
        agentId: String,
        title: String,
        parentSessionId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messageCount: Int = 0,
        lastMessagePreview: String? = nil,
        kind: AgentSessionKind = .chat
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
    }
}

public enum AgentSessionEventType: String, Codable, Sendable {
    case sessionCreated = "session_created"
    case message
    case runStatus = "run_status"
    case subSession = "sub_session"
    case runControl = "run_control"
    case toolCall = "tool_call"
    case toolResult = "tool_result"
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

public struct AgentSessionMetadataEvent: Codable, Sendable, Equatable {
    public var title: String
    public var parentSessionId: String?
    public var kind: AgentSessionKind

    public init(
        title: String,
        parentSessionId: String? = nil,
        kind: AgentSessionKind = .chat
    ) {
        self.title = title
        self.parentSessionId = parentSessionId
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case title
        case parentSessionId
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        kind = try container.decodeIfPresent(AgentSessionKind.self, forKey: .kind) ?? .chat
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
    public var subSession: AgentSubSessionEvent?
    public var runControl: AgentRunControlEvent?
    public var toolCall: AgentToolCallEvent?
    public var toolResult: AgentToolResultEvent?

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
        subSession: AgentSubSessionEvent? = nil,
        runControl: AgentRunControlEvent? = nil,
        toolCall: AgentToolCallEvent? = nil,
        toolResult: AgentToolResultEvent? = nil
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
        self.subSession = subSession
        self.runControl = runControl
        self.toolCall = toolCall
        self.toolResult = toolResult
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

public struct AgentSessionPostMessageRequest: Codable, Sendable {
    public var userId: String
    public var content: String
    public var attachments: [AgentAttachmentUpload]
    public var spawnSubSession: Bool
    public var reasoningEffort: ReasoningEffort?

    public init(
        userId: String,
        content: String,
        attachments: [AgentAttachmentUpload] = [],
        spawnSubSession: Bool = false,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.userId = userId
        self.content = content
        self.attachments = attachments
        self.spawnSubSession = spawnSubSession
        self.reasoningEffort = reasoningEffort
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

public struct ActorNode: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var kind: ActorKind
    public var linkedAgentId: String?
    public var channelId: String?
    public var role: String?
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
        self.positionX = positionX
        self.positionY = positionY
        self.createdAt = createdAt
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

    public init(
        id: String,
        owner: String,
        repo: String,
        name: String,
        description: String? = nil,
        installedAt: Date = Date(),
        version: String? = nil,
        localPath: String
    ) {
        self.id = id
        self.owner = owner
        self.repo = repo
        self.name = name
        self.description = description
        self.installedAt = installedAt
        self.version = version
        self.localPath = localPath
    }
}

/// Request to install a skill from GitHub
public struct SkillInstallRequest: Codable, Sendable {
    public var owner: String
    public var repo: String
    public var version: String?

    public init(owner: String, repo: String, version: String? = nil) {
        self.owner = owner
        self.repo = repo
        self.version = version
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

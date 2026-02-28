import Foundation

public struct ChannelMessageRequest: Codable, Sendable {
    public var userId: String
    public var content: String

    public init(userId: String, content: String) {
        self.userId = userId
        self.content = content
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

public struct AgentDocumentBundle: Codable, Sendable, Equatable {
    public var userMarkdown: String
    public var agentsMarkdown: String
    public var soulMarkdown: String
    public var identityMarkdown: String

    public init(
        userMarkdown: String,
        agentsMarkdown: String,
        soulMarkdown: String,
        identityMarkdown: String
    ) {
        self.userMarkdown = userMarkdown
        self.agentsMarkdown = agentsMarkdown
        self.soulMarkdown = soulMarkdown
        self.identityMarkdown = identityMarkdown
    }
}

public struct AgentConfigDetail: Codable, Sendable, Equatable {
    public var agentId: String
    public var selectedModel: String
    public var availableModels: [ProviderModelOption]
    public var documents: AgentDocumentBundle

    public init(
        agentId: String,
        selectedModel: String,
        availableModels: [ProviderModelOption],
        documents: AgentDocumentBundle
    ) {
        self.agentId = agentId
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.documents = documents
    }
}

public struct AgentConfigUpdateRequest: Codable, Sendable {
    public var selectedModel: String
    public var documents: AgentDocumentBundle

    public init(selectedModel: String, documents: AgentDocumentBundle) {
        self.selectedModel = selectedModel
        self.documents = documents
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

public struct AgentSessionCreateRequest: Codable, Sendable {
    public var title: String?
    public var parentSessionId: String?

    public init(title: String? = nil, parentSessionId: String? = nil) {
        self.title = title
        self.parentSessionId = parentSessionId
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

    public init(
        id: String,
        agentId: String,
        title: String,
        parentSessionId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messageCount: Int = 0,
        lastMessagePreview: String? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.parentSessionId = parentSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.lastMessagePreview = lastMessagePreview
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

    public init(title: String, parentSessionId: String? = nil) {
        self.title = title
        self.parentSessionId = parentSessionId
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

public struct AgentSessionPostMessageRequest: Codable, Sendable {
    public var userId: String
    public var content: String
    public var attachments: [AgentAttachmentUpload]
    public var spawnSubSession: Bool

    public init(
        userId: String,
        content: String,
        attachments: [AgentAttachmentUpload] = [],
        spawnSubSession: Bool = false
    ) {
        self.userId = userId
        self.content = content
        self.attachments = attachments
        self.spawnSubSession = spawnSubSession
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

public enum ActorCommunicationType: String, Codable, Sendable {
    case chat
    case task
    case event
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
    public var communicationType: ActorCommunicationType
    public var sourceSocket: ActorSocketPosition?
    public var targetSocket: ActorSocketPosition?
    public var createdAt: Date

    public init(
        id: String,
        sourceActorId: String,
        targetActorId: String,
        direction: ActorLinkDirection,
        communicationType: ActorCommunicationType,
        sourceSocket: ActorSocketPosition? = nil,
        targetSocket: ActorSocketPosition? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceActorId = sourceActorId
        self.targetActorId = targetActorId
        self.direction = direction
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

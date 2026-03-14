import Foundation
import Protocols

public struct PersistedChannelRecord: Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersistedTaskRecord: Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var status: String
    public var title: String
    public var objective: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        channelId: String,
        status: String,
        title: String,
        objective: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.channelId = channelId
        self.status = status
        self.title = title
        self.objective = objective
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersistedArtifactRecord: Sendable, Equatable {
    public var id: String
    public var content: String
    public var createdAt: Date

    public init(id: String, content: String, createdAt: Date) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }
}

public struct PersistedEventCursor: Sendable, Equatable {
    public var createdAt: Date
    public var eventId: String

    public init(createdAt: Date, eventId: String) {
        self.createdAt = createdAt
        self.eventId = eventId
    }
}

public struct ChannelAccessUser: Codable, Sendable, Equatable {
    public var id: String
    public var platform: String
    public var platformUserId: String
    public var displayName: String
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        platform: String,
        platformUserId: String,
        displayName: String,
        status: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.platform = platform
        self.platformUserId = platformUserId
        self.displayName = displayName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol PersistenceStore: Sendable {
    /// Persists protocol-level event envelopes emitted by the runtime.
    func persist(event: EventEnvelope) async

    /// Persists token accounting for a channel/task execution slice.
    func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async

    /// Lists token usage records with optional filters.
    func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> [TokenUsageRecord]

    /// Persists a generated memory bulletin.
    func persistBulletin(_ bulletin: MemoryBulletin) async

    /// Lists persisted events in replay-safe order (oldest first).
    func listPersistedEvents() async -> [EventEnvelope]

    /// Lists persisted events for one channel ordered by newest first.
    func listChannelEvents(
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) async -> [EventEnvelope]

    /// Lists persisted channels in creation order.
    func listPersistedChannels() async -> [PersistedChannelRecord]

    /// Lists persisted worker/task records in creation order.
    func listPersistedTasks() async -> [PersistedTaskRecord]

    /// Lists persisted artifacts in creation order.
    func listPersistedArtifacts() async -> [PersistedArtifactRecord]

    /// Persists an artifact payload by artifact identifier.
    func persistArtifact(id: String, content: String) async

    /// Returns artifact content by identifier when available.
    func artifactContent(id: String) async -> String?

    /// Lists recent memory bulletins from persistence.
    func listBulletins() async -> [MemoryBulletin]

    /// Lists dashboard projects with embedded channels and tasks.
    func listProjects() async -> [ProjectRecord]

    /// Returns one dashboard project by identifier.
    func project(id: String) async -> ProjectRecord?

    /// Creates or replaces one dashboard project.
    func saveProject(_ project: ProjectRecord) async

    /// Deletes one dashboard project and all nested records.
    func deleteProject(id: String) async

    /// Lists all channel plugin records.
    func listChannelPlugins() async -> [ChannelPluginRecord]

    /// Returns one channel plugin by identifier.
    func channelPlugin(id: String) async -> ChannelPluginRecord?

    /// Creates or replaces one channel plugin record.
    func saveChannelPlugin(_ plugin: ChannelPluginRecord) async

    /// Deletes one channel plugin record.
    func deleteChannelPlugin(id: String) async

    /// Lists cron tasks for an agent.
    func listCronTasks(agentId: String) async -> [AgentCronTask]

    /// Lists all cron tasks across all agents.
    func listAllCronTasks() async -> [AgentCronTask]

    /// Returns one cron task by identifier.
    func cronTask(id: String) async -> AgentCronTask?

    /// Creates or replaces one cron task record.
    func saveCronTask(_ task: AgentCronTask) async

    /// Deletes one cron task record.
    func deleteCronTask(id: String) async

    /// Lists all channel access user records, optionally filtered by platform.
    func listChannelAccessUsers(platform: String?) async -> [ChannelAccessUser]

    /// Returns one channel access user record by platform + platformUserId.
    func channelAccessUser(platform: String, platformUserId: String) async -> ChannelAccessUser?

    /// Creates or replaces one channel access user record.
    func saveChannelAccessUser(_ user: ChannelAccessUser) async

    /// Deletes one channel access user record.
    func deleteChannelAccessUser(id: String) async
}

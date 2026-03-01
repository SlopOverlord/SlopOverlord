import Foundation

public enum ProtocolConstants {
    public static let version = "1.0"
}

public struct EventEnvelope: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var messageId: String
    public var messageType: MessageType
    public var ts: Date
    public var traceId: String
    public var channelId: String
    public var taskId: String?
    public var branchId: String?
    public var workerId: String?
    public var payload: JSONValue
    public var extensions: [String: JSONValue]

    public init(
        protocolVersion: String = ProtocolConstants.version,
        messageId: String = UUID().uuidString,
        messageType: MessageType,
        ts: Date = Date(),
        traceId: String = UUID().uuidString,
        channelId: String,
        taskId: String? = nil,
        branchId: String? = nil,
        workerId: String? = nil,
        payload: JSONValue,
        extensions: [String: JSONValue] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.messageId = messageId
        self.messageType = messageType
        self.ts = ts
        self.traceId = traceId
        self.channelId = channelId
        self.taskId = taskId
        self.branchId = branchId
        self.workerId = workerId
        self.payload = payload
        self.extensions = extensions
    }
}

public enum MessageType: String, Codable, Sendable, CaseIterable {
    case channelMessageReceived = "channel.message.received"
    case channelRouteDecided = "channel.route.decided"
    case branchSpawned = "branch.spawned"
    case branchConclusion = "branch.conclusion"
    case workerSpawned = "worker.spawned"
    case workerProgress = "worker.progress"
    case workerCompleted = "worker.completed"
    case workerFailed = "worker.failed"
    case compactorThresholdHit = "compactor.threshold.hit"
    case compactorSummaryApplied = "compactor.summary.applied"
    case visorBulletinGenerated = "visor.bulletin.generated"
    case actorDiscussionStarted = "actor.discussion.started"
    case actorDiscussionConcluded = "actor.discussion.concluded"
}

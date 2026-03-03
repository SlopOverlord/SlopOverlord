import Foundation

public enum ProtocolConstants {
    public static let version = "1.0"
}

/// Token economy limits for runtime event payloads.
/// These values are enforced by regression tests to prevent token budget regression.
public enum EventPayloadLimits {
    /// Maximum payload size in bytes for a single runtime event.
    /// This limit is designed to keep context windows manageable and token costs predictable.
    /// - Note: This is a soft limit for the payload field only. Full envelope may be slightly larger.
    public static let maxBytesPerEventPayload: Int = 16_384  // 16 KB

    /// Warning threshold at 80% of the max limit.
    public static let warningThresholdBytes: Int = Int(Double(maxBytesPerEventPayload) * 0.8)
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

    /// Returns the size of the payload field in bytes when encoded as JSON.
    /// Use this to validate token economy constraints.
    public func payloadSizeInBytes() -> Int {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(payload)
            return data.count
        } catch {
            // Fallback: return 0 if encoding fails (should not happen for valid JSONValue)
            return 0
        }
    }

    /// Returns the size of the extensions field in bytes when encoded as JSON.
    public func extensionsSizeInBytes() -> Int {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(extensions)
            return data.count
        } catch {
            return 0
        }
    }

    /// Returns the total size of payload + extensions in bytes.
    public func totalContentSizeInBytes() -> Int {
        payloadSizeInBytes() + extensionsSizeInBytes()
    }

    /// Returns true if the payload exceeds the configured limit.
    public func isPayloadOversized() -> Bool {
        payloadSizeInBytes() > EventPayloadLimits.maxBytesPerEventPayload
    }

    /// Returns true if the payload exceeds the warning threshold (80% of limit).
    public func isPayloadNearLimit() -> Bool {
        payloadSizeInBytes() > EventPayloadLimits.warningThresholdBytes
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

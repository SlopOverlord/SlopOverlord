import Foundation
import Protocols

public struct DashboardNotification: Codable, Sendable {
    public enum NotificationType: String, Codable, Sendable {
        case confirmation
        case agentError = "agent_error"
        case systemError = "system_error"
        case pendingApproval = "pending_approval"
    }

    public var id: String
    public var type: NotificationType
    public var title: String
    public var message: String
    public var timestamp: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        type: NotificationType,
        title: String,
        message: String,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

public actor NotificationService {
    private var subscribers: [UUID: AsyncStream<DashboardNotification>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<DashboardNotification> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [id] _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    public func push(_ notification: DashboardNotification) {
        for continuation in subscribers.values {
            continuation.yield(notification)
        }
    }

    public func pushAgentError(title: String, message: String, agentId: String? = nil, taskId: String? = nil) {
        var metadata: [String: String] = [:]
        if let agentId { metadata["agentId"] = agentId }
        if let taskId { metadata["taskId"] = taskId }
        push(DashboardNotification(type: .agentError, title: title, message: message, metadata: metadata))
    }

    public func pushSystemError(title: String, message: String) {
        push(DashboardNotification(type: .systemError, title: title, message: message))
    }

    public func pushPendingApproval(
        title: String,
        message: String,
        approvalId: String,
        platform: String,
        userId: String,
        channelId: String?
    ) {
        var metadata: [String: String] = [
            "approvalId": approvalId,
            "platform": platform,
            "userId": userId
        ]
        if let channelId { metadata["channelId"] = channelId }
        push(DashboardNotification(type: .pendingApproval, title: title, message: message, metadata: metadata))
    }

    public func pushConfirmation(title: String, message: String, taskId: String? = nil) {
        var metadata: [String: String] = [:]
        if let taskId { metadata["taskId"] = taskId }
        push(DashboardNotification(type: .confirmation, title: title, message: message, metadata: metadata))
    }

    private func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

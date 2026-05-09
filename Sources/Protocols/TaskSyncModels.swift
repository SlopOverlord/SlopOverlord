import Foundation

public enum TaskSyncTokenMode: String, Codable, Sendable, Equatable {
    case inherit
    case override
}

public struct ProjectTaskSyncWebhookState: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var webhookURL: String?
    public var secretMasked: Bool
    public var manualSetupRequired: Bool
    public var lastDeliveryId: String?
    public var lastReceivedAt: Date?

    public init(
        enabled: Bool = false,
        webhookURL: String? = nil,
        secretMasked: Bool = false,
        manualSetupRequired: Bool = false,
        lastDeliveryId: String? = nil,
        lastReceivedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.webhookURL = webhookURL
        self.secretMasked = secretMasked
        self.manualSetupRequired = manualSetupRequired
        self.lastDeliveryId = lastDeliveryId
        self.lastReceivedAt = lastReceivedAt
    }
}

public struct ProjectTaskSyncHealth: Codable, Sendable, Equatable {
    public var status: String
    public var message: String?
    public var checkedAt: Date?

    public init(status: String = "unknown", message: String? = nil, checkedAt: Date? = nil) {
        self.status = status
        self.message = message
        self.checkedAt = checkedAt
    }
}

public struct ProjectTaskSyncSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var providerId: String?
    public var projectURL: String?
    public var projectNodeId: String?
    public var defaultRepo: String?
    public var tokenMode: TaskSyncTokenMode
    public var statusMappings: [String: String]
    public var webhook: ProjectTaskSyncWebhookState
    public var health: ProjectTaskSyncHealth

    public init(
        enabled: Bool = false,
        providerId: String? = nil,
        projectURL: String? = nil,
        projectNodeId: String? = nil,
        defaultRepo: String? = nil,
        tokenMode: TaskSyncTokenMode = .inherit,
        statusMappings: [String: String] = [:],
        webhook: ProjectTaskSyncWebhookState = .init(),
        health: ProjectTaskSyncHealth = .init()
    ) {
        self.enabled = enabled
        self.providerId = providerId
        self.projectURL = projectURL
        self.projectNodeId = projectNodeId
        self.defaultRepo = defaultRepo
        self.tokenMode = tokenMode
        self.statusMappings = statusMappings
        self.webhook = webhook
        self.health = health
    }
}

public struct TaskExternalMetadata: Codable, Sendable, Equatable {
    public var providerId: String?
    public var externalProjectId: String?
    public var externalItemId: String?
    public var externalIssueId: String?
    public var externalIssueNumber: Int?
    public var externalIssueURL: String?
    public var externalCommentId: String?
    public var origin: String?
    public var syncState: String?
    public var lastSyncedAt: Date?

    public init(
        providerId: String? = nil,
        externalProjectId: String? = nil,
        externalItemId: String? = nil,
        externalIssueId: String? = nil,
        externalIssueNumber: Int? = nil,
        externalIssueURL: String? = nil,
        externalCommentId: String? = nil,
        origin: String? = nil,
        syncState: String? = nil,
        lastSyncedAt: Date? = nil
    ) {
        self.providerId = providerId
        self.externalProjectId = externalProjectId
        self.externalItemId = externalItemId
        self.externalIssueId = externalIssueId
        self.externalIssueNumber = externalIssueNumber
        self.externalIssueURL = externalIssueURL
        self.externalCommentId = externalCommentId
        self.origin = origin
        self.syncState = syncState
        self.lastSyncedAt = lastSyncedAt
    }
}

public struct ProjectTaskSyncSettingsUpdateRequest: Codable, Sendable {
    public var enabled: Bool?
    public var providerId: String?
    public var projectURL: String?
    public var projectNodeId: String?
    public var defaultRepo: String?
    public var tokenMode: TaskSyncTokenMode?
    public var statusMappings: [String: String]?

    public init(
        enabled: Bool? = nil,
        providerId: String? = nil,
        projectURL: String? = nil,
        projectNodeId: String? = nil,
        defaultRepo: String? = nil,
        tokenMode: TaskSyncTokenMode? = nil,
        statusMappings: [String: String]? = nil
    ) {
        self.enabled = enabled
        self.providerId = providerId
        self.projectURL = projectURL
        self.projectNodeId = projectNodeId
        self.defaultRepo = defaultRepo
        self.tokenMode = tokenMode
        self.statusMappings = statusMappings
    }
}

public struct ProjectTaskSyncLinkRequest: Codable, Sendable {
    public var providerId: String
    public var projectURL: String
    public var defaultRepo: String?
    public var tokenMode: TaskSyncTokenMode?
    public var statusMappings: [String: String]?

    public init(
        providerId: String = "github",
        projectURL: String,
        defaultRepo: String? = nil,
        tokenMode: TaskSyncTokenMode? = nil,
        statusMappings: [String: String]? = nil
    ) {
        self.providerId = providerId
        self.projectURL = projectURL
        self.defaultRepo = defaultRepo
        self.tokenMode = tokenMode
        self.statusMappings = statusMappings
    }
}

public struct ProjectTaskSyncTokenRequest: Codable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public struct ProjectTaskSyncTokenStatusResponse: Codable, Sendable, Equatable {
    public var tokenMode: TaskSyncTokenMode
    public var hasOverrideToken: Bool
    public var maskedToken: String?

    public init(tokenMode: TaskSyncTokenMode, hasOverrideToken: Bool, maskedToken: String? = nil) {
        self.tokenMode = tokenMode
        self.hasOverrideToken = hasOverrideToken
        self.maskedToken = maskedToken
    }
}

public struct ProjectTaskSyncResponse: Codable, Sendable, Equatable {
    public var project: ProjectRecord
    public var settings: ProjectTaskSyncSettings

    public init(project: ProjectRecord, settings: ProjectTaskSyncSettings) {
        self.project = project
        self.settings = settings
    }
}

public struct ProjectTaskSyncNowResponse: Codable, Sendable, Equatable {
    public var imported: Int
    public var updated: Int
    public var skipped: Int
    public var message: String?

    public init(imported: Int = 0, updated: Int = 0, skipped: Int = 0, message: String? = nil) {
        self.imported = imported
        self.updated = updated
        self.skipped = skipped
        self.message = message
    }
}

public struct TaskSyncWebhookResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var duplicate: Bool
    public var message: String?

    public init(ok: Bool, duplicate: Bool = false, message: String? = nil) {
        self.ok = ok
        self.duplicate = duplicate
        self.message = message
    }
}

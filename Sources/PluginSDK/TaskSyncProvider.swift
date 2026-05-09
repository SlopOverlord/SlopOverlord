import Foundation
import Protocols

public struct TaskSyncProjectDescriptor: Sendable, Equatable {
    public var providerId: String
    public var projectURL: String
    public var projectNodeId: String?
    public var defaultRepo: String?
    public var statusOptions: [String]

    public init(
        providerId: String,
        projectURL: String,
        projectNodeId: String? = nil,
        defaultRepo: String? = nil,
        statusOptions: [String] = []
    ) {
        self.providerId = providerId
        self.projectURL = projectURL
        self.projectNodeId = projectNodeId
        self.defaultRepo = defaultRepo
        self.statusOptions = statusOptions
    }
}

public struct TaskSyncExternalTask: Sendable, Equatable {
    public var title: String
    public var description: String
    public var status: String?
    public var metadata: TaskExternalMetadata
    public var tags: [String]

    public init(
        title: String,
        description: String = "",
        status: String? = nil,
        metadata: TaskExternalMetadata,
        tags: [String] = []
    ) {
        self.title = title
        self.description = description
        self.status = status
        self.metadata = metadata
        self.tags = tags
    }
}

public struct TaskSyncExternalComment: Sendable, Equatable {
    public var body: String
    public var author: String
    public var metadata: TaskExternalMetadata

    public init(body: String, author: String, metadata: TaskExternalMetadata) {
        self.body = body
        self.author = author
        self.metadata = metadata
    }
}

public protocol TaskSyncProvider: Sendable {
    var id: String { get }

    func parseProjectURL(_ rawURL: String) throws -> TaskSyncProjectDescriptor
    func resolveProject(
        url: String,
        token: String?,
        defaultRepo: String?
    ) async throws -> TaskSyncProjectDescriptor
    func importTasks(
        settings: ProjectTaskSyncSettings,
        token: String?
    ) async throws -> [TaskSyncExternalTask]
    func createOrUpdateTask(
        _ task: ProjectTask,
        settings: ProjectTaskSyncSettings,
        token: String?
    ) async throws -> TaskExternalMetadata
    func mirrorComment(
        _ comment: TaskComment,
        task: ProjectTask,
        settings: ProjectTaskSyncSettings,
        token: String?
    ) async throws -> TaskExternalMetadata
}

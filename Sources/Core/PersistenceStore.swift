import Foundation
import Protocols

public protocol PersistenceStore: Sendable {
    /// Persists protocol-level event envelopes emitted by the runtime.
    func persist(event: EventEnvelope) async

    /// Persists token accounting for a channel/task execution slice.
    func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async

    /// Persists a generated memory bulletin.
    func persistBulletin(_ bulletin: MemoryBulletin) async

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
}

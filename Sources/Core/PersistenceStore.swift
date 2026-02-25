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
}

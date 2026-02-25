import Foundation
import Protocols

public struct MemoryEntry: Codable, Sendable, Equatable {
    public var id: String
    public var note: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, note: String, createdAt: Date = Date()) {
        self.id = id
        self.note = note
        self.createdAt = createdAt
    }
}

public protocol MemoryStore: Sendable {
    /// Retrieves matching memory references for a query.
    func recall(query: String, limit: Int) async -> [MemoryRef]
    /// Stores memory note and returns reference.
    func save(note: String) async -> MemoryRef
    /// Returns all stored memory entries.
    func entries() async -> [MemoryEntry]
}

public actor InMemoryMemoryStore: MemoryStore {
    private var storage: [MemoryEntry] = []

    public init() {}

    /// Performs in-memory relevance scoring and returns top matches.
    public func recall(query: String, limit: Int) async -> [MemoryRef] {
        let normalized = query.lowercased()
        let scored = storage.map { entry -> (MemoryEntry, Double) in
            let hay = entry.note.lowercased()
            let score = hay.contains(normalized) ? 0.95 : 0.45
            return (entry, score)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { MemoryRef(id: $0.0.id, score: $0.1) }
    }

    /// Appends note into in-memory store.
    public func save(note: String) async -> MemoryRef {
        let entry = MemoryEntry(note: note)
        storage.append(entry)
        return MemoryRef(id: entry.id, score: 1.0)
    }

    /// Lists all in-memory entries.
    public func entries() async -> [MemoryEntry] {
        storage
    }
}

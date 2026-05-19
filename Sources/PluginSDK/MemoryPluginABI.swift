import Foundation
import Protocols

/// Wraps a memory plugin implementation for return through `sloppy_memory_create`.
public final class AnyMemoryPluginBox: MemoryPlugin, @unchecked Sendable {
    public let id: String

    private let _recall: @Sendable (String, Int) async throws -> [MemoryRef]
    private let _save: @Sendable (String) async throws -> MemoryRef

    public init(
        id: String,
        recall: @escaping @Sendable (String, Int) async throws -> [MemoryRef],
        save: @escaping @Sendable (String) async throws -> MemoryRef
    ) {
        self.id = id
        self._recall = recall
        self._save = save
    }

    public func recall(query: String, limit: Int) async throws -> [MemoryRef] {
        try await _recall(query, limit)
    }

    public func save(note: String) async throws -> MemoryRef {
        try await _save(note)
    }
}

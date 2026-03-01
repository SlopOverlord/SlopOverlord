import Foundation
import Protocols

private struct BranchState: Sendable {
    var channelId: String
    var prompt: String
    var recalledMemory: [MemoryRef]
    var workerId: String?
}

public actor BranchRuntime {
    private let eventBus: EventBus
    private let memoryStore: MemoryStore
    private var branches: [String: BranchState] = [:]

    public init(eventBus: EventBus, memoryStore: MemoryStore) {
        self.eventBus = eventBus
        self.memoryStore = memoryStore
    }

    /// Creates branch context fork and emits spawn event.
    public func spawn(channelId: String, prompt: String) async -> String {
        let branchId = UUID().uuidString
        let recalled = await memoryStore.recall(query: prompt, limit: 5)
        let todos = TodoExtractor.extractCandidates(from: prompt)
        for todo in todos {
            _ = await memoryStore.save(note: "[todo] \(todo)")
        }
        branches[branchId] = BranchState(
            channelId: channelId,
            prompt: prompt,
            recalledMemory: recalled,
            workerId: nil
        )

        await eventBus.publish(
            EventEnvelope(
                messageType: .branchSpawned,
                channelId: channelId,
                branchId: branchId,
                payload: .object([
                    "prompt": .string(prompt),
                    "memoryRefs": .array(recalled.map { .string($0.id) })
                ]),
                extensions: todos.isEmpty ? [:] : [
                    "todos": .array(todos.map { .string($0) })
                ]
            )
        )

        return branchId
    }

    /// Associates worker with branch context.
    public func attachWorker(branchId: String, workerId: String) {
        guard var state = branches[branchId] else { return }
        state.workerId = workerId
        branches[branchId] = state
    }

    /// Finalizes branch, writes memory summary, and emits conclusion event.
    public func conclude(
        branchId: String,
        summary: String,
        artifactRefs: [ArtifactRef],
        tokenUsage: TokenUsage
    ) async -> BranchConclusion? {
        guard let state = branches.removeValue(forKey: branchId) else { return nil }

        let saved = await memoryStore.save(note: summary)
        let memoryRefs = state.recalledMemory + [saved]
        let conclusion = BranchConclusion(
            summary: summary,
            artifactRefs: artifactRefs,
            memoryRefs: memoryRefs,
            tokenUsage: tokenUsage
        )

        if let payload = try? JSONValueCoder.encode(conclusion) {
            await eventBus.publish(
                EventEnvelope(
                    messageType: .branchConclusion,
                    channelId: state.channelId,
                    branchId: branchId,
                    payload: payload
                )
            )
        }

        return conclusion
    }

    /// Returns currently active branch count.
    public func activeBranchesCount() -> Int {
        branches.count
    }
}

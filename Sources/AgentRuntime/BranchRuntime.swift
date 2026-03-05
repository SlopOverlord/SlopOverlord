import Foundation
import Protocols

private struct BranchState: Sendable {
    var channelId: String
    var prompt: String
    var scope: MemoryScope
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
        let scope = MemoryScope.channel(channelId)
        let recalled = await memoryStore.recall(
            request: MemoryRecallRequest(
                query: prompt,
                limit: 8,
                scope: scope
            )
        ).map(\.ref)
        let todos = TodoExtractor.extractCandidates(from: prompt)
        for todo in todos {
            _ = await memoryStore.save(
                entry: MemoryWriteRequest(
                    note: "[todo] \(todo)",
                    kind: .todo,
                    memoryClass: .procedural,
                    scope: scope,
                    source: MemorySource(type: "branch.spawned", id: branchId)
                )
            )
        }
        branches[branchId] = BranchState(
            channelId: channelId,
            prompt: prompt,
            scope: scope,
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

        let preSaveConclusion = BranchConclusion(
            summary: summary,
            artifactRefs: artifactRefs,
            memoryRefs: state.recalledMemory,
            tokenUsage: tokenUsage
        )
        do {
            try preSaveConclusion.validate()
        } catch {
            await publishInvalidConclusion(state: state, branchId: branchId, error: error)
            return nil
        }

        let saved = await memoryStore.save(
            entry: MemoryWriteRequest(
                note: summary,
                summary: "Branch conclusion summary",
                kind: .decision,
                memoryClass: .procedural,
                scope: state.scope,
                source: MemorySource(type: "branch.conclusion", id: branchId),
                importance: 0.8,
                confidence: 0.8
            )
        )
        for recalled in state.recalledMemory {
            _ = await memoryStore.link(
                MemoryEdgeWriteRequest(
                    fromMemoryId: saved.id,
                    toMemoryId: recalled.id,
                    relation: .derivedFrom,
                    provenance: "branch.conclusion"
                )
            )
        }
        let memoryRefs = state.recalledMemory + [saved]
        let conclusion = BranchConclusion(
            summary: summary,
            artifactRefs: artifactRefs,
            memoryRefs: memoryRefs,
            tokenUsage: tokenUsage
        )
        do {
            try conclusion.validate()
        } catch {
            await publishInvalidConclusion(state: state, branchId: branchId, error: error)
            return nil
        }

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

    private func publishInvalidConclusion(state: BranchState, branchId: String, error: Error) async {
        let validationError = error as? BranchConclusion.ValidationError
        let code = validationError?.code ?? "invalid_branch_conclusion"
        let message = validationError?.message ?? "Branch conclusion failed validation."

        await eventBus.publish(
            EventEnvelope(
                messageType: .workerFailed,
                channelId: state.channelId,
                branchId: branchId,
                workerId: state.workerId,
                payload: .object([
                    "error": .string(message),
                    "code": .string(code),
                    "reason": .string("invalid_branch_conclusion")
                ])
            )
        )
    }
}

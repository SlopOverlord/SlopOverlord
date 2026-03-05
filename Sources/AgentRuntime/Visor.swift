import Foundation
import Protocols

public actor Visor {
    private let eventBus: EventBus
    private let memoryStore: MemoryStore
    private var bulletins: [MemoryBulletin] = []

    public init(eventBus: EventBus, memoryStore: MemoryStore) {
        self.eventBus = eventBus
        self.memoryStore = memoryStore
    }

    /// Builds periodic runtime bulletin and publishes digest event.
    public func generateBulletin(channels: [ChannelSnapshot], workers: [WorkerSnapshot], taskSummary: String? = nil) async -> MemoryBulletin {
        let scope: MemoryScope = channels.count == 1 ? .channel(channels[0].channelId) : .default
        let headline = "Runtime bulletin: \(channels.count) channels, \(workers.count) workers"
        let activeWorkers = workers.filter { $0.status == .running || $0.status == .waitingInput }.count
        var items = [
            "Active channels: \(channels.count)",
            "Workers in progress: \(activeWorkers)",
            "Total workers known: \(workers.count)"
        ]
        if let taskSummary, !taskSummary.isEmpty {
            items.append(taskSummary)
        }
        let digest = items.joined(separator: " | ")
        let recalled = await memoryStore.recall(
            request: MemoryRecallRequest(
                query: digest,
                limit: 12,
                scope: scope
            )
        )
        let memoryRefs = recalled.map(\.ref)
        let bulletin = MemoryBulletin(
            headline: headline,
            digest: digest,
            items: items,
            memoryRefs: memoryRefs,
            scope: scope
        )

        let saved = await memoryStore.save(
            entry: MemoryWriteRequest(
                note: "[bulletin] \(digest)",
                summary: headline,
                kind: .event,
                memoryClass: .bulletin,
                scope: scope,
                source: MemorySource(type: "visor.bulletin.generated", id: bulletin.id),
                importance: 0.7,
                confidence: 0.9
            )
        )
        for ref in memoryRefs {
            _ = await memoryStore.link(
                MemoryEdgeWriteRequest(
                    fromMemoryId: saved.id,
                    toMemoryId: ref.id,
                    relation: .about,
                    provenance: "visor.bulletin"
                )
            )
        }
        bulletins.append(bulletin)

        if let payload = try? JSONValueCoder.encode(bulletin) {
            await eventBus.publish(
                EventEnvelope(
                    messageType: .visorBulletinGenerated,
                    channelId: "broadcast",
                    payload: payload
                )
            )
        }

        return bulletin
    }

    /// Lists bulletins generated since runtime startup.
    public func listBulletins() -> [MemoryBulletin] {
        bulletins
    }
}

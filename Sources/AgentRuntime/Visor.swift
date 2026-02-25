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
    public func generateBulletin(channels: [ChannelSnapshot], workers: [WorkerSnapshot]) async -> MemoryBulletin {
        let headline = "Runtime bulletin: \(channels.count) channels, \(workers.count) workers"
        let activeWorkers = workers.filter { $0.status == .running || $0.status == .waitingInput }.count
        let items = [
            "Active channels: \(channels.count)",
            "Workers in progress: \(activeWorkers)",
            "Total workers known: \(workers.count)"
        ]
        let digest = items.joined(separator: " | ")
        let bulletin = MemoryBulletin(headline: headline, digest: digest, items: items)

        _ = await memoryStore.save(note: "[bulletin] \(digest)")
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

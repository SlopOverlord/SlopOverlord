import AgentRuntime
import Foundation
import Logging

actor RecoveryManager {
    private var store: any PersistenceStore
    private let runtime: RuntimeSystem
    private let logger: Logger
    private var hasRecovered = false

    init(store: any PersistenceStore, runtime: RuntimeSystem, logger: Logger) {
        self.store = store
        self.runtime = runtime
        self.logger = logger
    }

    func updateStore(_ store: any PersistenceStore) {
        self.store = store
        self.hasRecovered = false
    }

    func recoverIfNeeded() async {
        guard !hasRecovered else {
            return
        }
        hasRecovered = true

        let channels = await store.listPersistedChannels()
        let tasks = await store.listPersistedTasks()
        let events = await store.listPersistedEvents()
        let artifacts = await store.listPersistedArtifacts()

        let runtimeChannels = channels.map {
            RecoveryChannelState(
                id: $0.id,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        let runtimeTasks = tasks.map {
            RecoveryTaskState(
                id: $0.id,
                channelId: $0.channelId,
                status: $0.status,
                title: $0.title,
                objective: $0.objective,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        let runtimeArtifacts = artifacts.map {
            RecoveryArtifactState(
                id: $0.id,
                content: $0.content,
                createdAt: $0.createdAt
            )
        }

        await runtime.recover(
            channels: runtimeChannels,
            tasks: runtimeTasks,
            events: events,
            artifacts: runtimeArtifacts
        )

        logger.info(
            "runtime.recovery.completed",
            metadata: [
                "channels": .stringConvertible(runtimeChannels.count),
                "tasks": .stringConvertible(runtimeTasks.count),
                "events": .stringConvertible(events.count),
                "artifacts": .stringConvertible(runtimeArtifacts.count)
            ]
        )
    }
}

import Foundation
import Protocols

public actor Compactor {
    private let eventBus: EventBus
    private var lastLevelByChannel: [String: CompactionLevel] = [:]

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Evaluates channel context utilization and schedules compaction job when needed.
    public func evaluate(channelId: String, utilization: Double) async -> CompactionJob? {
        let level: CompactionLevel?
        let threshold: Double

        if utilization > 0.95 {
            level = .emergency
            threshold = 0.95
        } else if utilization > 0.85 {
            level = .aggressive
            threshold = 0.85
        } else if utilization > 0.80 {
            level = .soft
            threshold = 0.80
        } else {
            level = nil
            threshold = 0
        }

        guard let level else {
            lastLevelByChannel[channelId] = nil
            return nil
        }

        if lastLevelByChannel[channelId] == level {
            return nil
        }

        lastLevelByChannel[channelId] = level
        let job = CompactionJob(channelId: channelId, level: level, threshold: threshold)

        if let payload = try? JSONValueCoder.encode(job) {
            await eventBus.publish(
                EventEnvelope(
                    messageType: .compactorThresholdHit,
                    channelId: channelId,
                    payload: payload
                )
            )
        }

        return job
    }

    /// Applies compaction by spawning summary worker and emitting completion event.
    public func apply(job: CompactionJob, workers: WorkerRuntime) async {
        let spec = WorkerTaskSpec(
            taskId: "compaction-\(job.id)",
            channelId: job.channelId,
            title: "Compaction \(job.level.rawValue)",
            objective: "Summarize channel context at \(Int(job.threshold * 100))% threshold",
            tools: ["file"],
            mode: .fireAndForget
        )

        let workerId = await workers.spawn(spec: spec, autoStart: false)
        _ = await workers.completeNow(
            workerId: workerId,
            summary: "Compaction \(job.level.rawValue) summary applied"
        )

        await eventBus.publish(
            EventEnvelope(
                messageType: .compactorSummaryApplied,
                channelId: job.channelId,
                workerId: workerId,
                payload: .object([
                    "jobId": .string(job.id),
                    "level": .string(job.level.rawValue)
                ])
            )
        )
    }
}

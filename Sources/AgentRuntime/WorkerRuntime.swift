import Foundation
import Protocols

public enum WorkerStatus: String, Codable, Sendable {
    case queued
    case running
    case waitingInput
    case completed
    case failed
}

public struct WorkerSnapshot: Codable, Sendable, Equatable {
    public var workerId: String
    public var channelId: String
    public var taskId: String
    public var status: WorkerStatus
    public var mode: WorkerMode
    public var tools: [String]
    public var latestReport: String?

    public init(
        workerId: String,
        channelId: String,
        taskId: String,
        status: WorkerStatus,
        mode: WorkerMode,
        tools: [String],
        latestReport: String?
    ) {
        self.workerId = workerId
        self.channelId = channelId
        self.taskId = taskId
        self.status = status
        self.mode = mode
        self.tools = tools
        self.latestReport = latestReport
    }
}

public struct WorkerRouteResult: Sendable, Equatable {
    public var accepted: Bool
    public var completed: Bool
    public var artifactRef: ArtifactRef?

    public init(accepted: Bool, completed: Bool, artifactRef: ArtifactRef?) {
        self.accepted = accepted
        self.completed = completed
        self.artifactRef = artifactRef
    }
}

private struct WorkerState: Sendable {
    var spec: WorkerTaskSpec
    var status: WorkerStatus
    var latestReport: String?
    var routeInbox: [String]
    var artifactId: String?
}

public actor WorkerRuntime {
    private let eventBus: EventBus
    private var workers: [String: WorkerState] = [:]
    private var artifacts: [String: String] = [:]

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Creates worker state and optionally starts execution.
    public func spawn(spec: WorkerTaskSpec, autoStart: Bool = true) async -> String {
        let workerId = UUID().uuidString
        workers[workerId] = WorkerState(spec: spec, status: .queued, latestReport: nil, routeInbox: [], artifactId: nil)

        await publish(
            channelId: spec.channelId,
            taskId: spec.taskId,
            workerId: workerId,
            messageType: .workerSpawned,
            payload: [
                "mode": .string(spec.mode.rawValue),
                "title": .string(spec.title)
            ]
        )

        if autoStart {
            Task {
                await self.execute(workerId: workerId)
            }
        }

        return workerId
    }

    /// Executes worker logic according to configured mode.
    public func execute(workerId: String) async {
        guard var state = workers[workerId] else { return }
        state.status = .running
        workers[workerId] = state

        await publish(
            channelId: state.spec.channelId,
            taskId: state.spec.taskId,
            workerId: workerId,
            messageType: .workerProgress,
            payload: ["progress": .string("worker_started")]
        )

        switch state.spec.mode {
        case .fireAndForget:
            let summary = "Completed objective: \(state.spec.objective)"
            _ = await completeNow(workerId: workerId, summary: summary)
        case .interactive:
            state.status = .waitingInput
            state.latestReport = "waiting_for_route"
            workers[workerId] = state
            await publish(
                channelId: state.spec.channelId,
                taskId: state.spec.taskId,
                workerId: workerId,
                messageType: .workerProgress,
                payload: ["progress": .string("waiting_for_route")]
            )
        }
    }

    /// Completes worker immediately with summary artifact.
    public func completeNow(workerId: String, summary: String) async -> ArtifactRef? {
        guard var state = workers[workerId] else { return nil }

        state.status = .completed
        state.latestReport = summary
        let artifactId = UUID().uuidString
        state.artifactId = artifactId
        workers[workerId] = state

        artifacts[artifactId] = summary
        let ref = ArtifactRef(id: artifactId, kind: "text", preview: String(summary.prefix(120)))

        await publish(
            channelId: state.spec.channelId,
            taskId: state.spec.taskId,
            workerId: workerId,
            messageType: .workerCompleted,
            payload: [
                "summary": .string(summary),
                "artifactId": .string(artifactId)
            ]
        )

        return ref
    }

    /// Marks worker as failed and emits failure event.
    public func fail(workerId: String, error: String) async {
        guard var state = workers[workerId] else { return }
        state.status = .failed
        state.latestReport = error
        workers[workerId] = state

        await publish(
            channelId: state.spec.channelId,
            taskId: state.spec.taskId,
            workerId: workerId,
            messageType: .workerFailed,
            payload: ["error": .string(error)]
        )
    }

    /// Routes interactive message into worker execution loop.
    public func route(workerId: String, message: String) async -> WorkerRouteResult {
        guard var state = workers[workerId] else {
            return WorkerRouteResult(accepted: false, completed: false, artifactRef: nil)
        }

        guard state.spec.mode == .interactive, state.status == .waitingInput || state.status == .running else {
            return WorkerRouteResult(accepted: false, completed: false, artifactRef: nil)
        }

        state.routeInbox.append(message)
        state.status = .running
        state.latestReport = "routed: \(message)"
        workers[workerId] = state

        await publish(
            channelId: state.spec.channelId,
            taskId: state.spec.taskId,
            workerId: workerId,
            messageType: .workerProgress,
            payload: ["progress": .string("received_route")]
        )

        if message.lowercased().contains("done") || message.lowercased().contains("готово") {
            let artifact = await completeNow(workerId: workerId, summary: "Interactive worker completed after route command")
            return WorkerRouteResult(accepted: true, completed: true, artifactRef: artifact)
        }

        state.status = .waitingInput
        workers[workerId] = state
        return WorkerRouteResult(accepted: true, completed: false, artifactRef: nil)
    }

    /// Returns snapshot for a specific worker.
    public func snapshot(workerId: String) -> WorkerSnapshot? {
        guard let state = workers[workerId] else { return nil }
        return WorkerSnapshot(
            workerId: workerId,
            channelId: state.spec.channelId,
            taskId: state.spec.taskId,
            status: state.status,
            mode: state.spec.mode,
            tools: state.spec.tools,
            latestReport: state.latestReport
        )
    }

    /// Returns snapshots for all workers.
    public func snapshots() -> [WorkerSnapshot] {
        workers.map { workerId, state in
            WorkerSnapshot(
                workerId: workerId,
                channelId: state.spec.channelId,
                taskId: state.spec.taskId,
                status: state.status,
                mode: state.spec.mode,
                tools: state.spec.tools,
                latestReport: state.latestReport
            )
        }
    }

    /// Returns stored artifact content by identifier.
    public func artifactContent(id: String) -> String? {
        artifacts[id]
    }

    private func publish(
        channelId: String,
        taskId: String,
        workerId: String,
        messageType: MessageType,
        payload: [String: JSONValue]
    ) async {
        let envelope = EventEnvelope(
            messageType: messageType,
            channelId: channelId,
            taskId: taskId,
            workerId: workerId,
            payload: .object(payload)
        )
        await eventBus.publish(envelope)
    }
}

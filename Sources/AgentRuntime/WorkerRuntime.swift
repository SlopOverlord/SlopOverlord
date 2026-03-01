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
            let executionResult = executeFireAndForgetObjective(spec: state.spec)
            switch executionResult {
            case .success(let summary):
                _ = await completeNow(workerId: workerId, summary: summary)
            case .failure(let error):
                await fail(workerId: workerId, error: "Fire-and-forget execution failed: \(error.localizedDescription)")
            }
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

        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMessage == "fail" || normalizedMessage == "ошибка" {
            await fail(workerId: workerId, error: "Interactive worker marked as failed by route command")
            return WorkerRouteResult(accepted: true, completed: true, artifactRef: nil)
        }

        if normalizedMessage.contains("done") || normalizedMessage.contains("готово") {
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

    private func executeFireAndForgetObjective(spec: WorkerTaskSpec) -> Result<String, Error> {
        if let summary = executeCreateFileObjective(spec: spec) {
            return .success(summary)
        }
        return .success("Completed objective: \(spec.objective)")
    }

    private func executeCreateFileObjective(spec: WorkerTaskSpec) -> String? {
        let objective = spec.objective
        guard let text = extractFileText(from: objective),
              let artifactsDirectory = extractArtifactsDirectory(from: objective)
        else {
            return nil
        }

        let filename = extractRequestedFilename(from: objective) ?? "artifact-\(UUID().uuidString.prefix(8)).txt"
        let sanitizedFilename = sanitizeFilename(String(filename))
        let directoryURL = URL(fileURLWithPath: artifactsDirectory, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(sanitizedFilename)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Created file at \(fileURL.path)\nContent preview: \(String(text.prefix(200)))"
        } catch {
            return "Completed objective: \(objective)\nFile write failed at \(fileURL.path): \(error.localizedDescription)"
        }
    }

    private func extractArtifactsDirectory(from objective: String) -> String? {
        if let value = captureGroup(
            source: objective,
            pattern: #"(?im)^-\s*Store all created files and artifacts under:\s*(.+?)\s*$"#
        ) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fallback = captureGroup(source: objective, pattern: #"(/[^ \n\t]+/artifacts)\b"#) {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractFileText(from objective: String) -> String? {
        let patterns = [
            #"(?is)create\s+file(?:\s+named\s+[A-Za-z0-9._-]+)?\s+with\s+text\s*["“](.+?)["”]"#,
            #"(?is)create\s+file\s*["“](.+?)["”]"#,
            #"(?is)создай(?:те)?\s+файл(?:\s+с\s+именем\s+[A-Za-z0-9._-]+)?\s+с\s+текстом\s*["«](.+?)["»]"#
        ]
        for pattern in patterns {
            if let value = captureGroup(source: objective, pattern: pattern) {
                return value
            }
        }
        return nil
    }

    private func extractRequestedFilename(from objective: String) -> String? {
        let patterns = [
            #"(?is)create\s+file\s+named\s+([A-Za-z0-9._-]+)"#,
            #"(?is)создай(?:те)?\s+файл\s+с\s+именем\s+([A-Za-z0-9._-]+)"#
        ]
        for pattern in patterns {
            if let value = captureGroup(source: objective, pattern: pattern) {
                return value
            }
        }
        return nil
    }

    private func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let sanitizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(sanitizedScalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if sanitized.isEmpty {
            return "artifact-\(UUID().uuidString.prefix(8)).txt"
        }
        return sanitized
    }

    private func captureGroup(source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        let groupRange = match.range(at: 1)
        guard groupRange.location != NSNotFound else {
            return nil
        }
        return nsSource.substring(with: groupRange)
    }
}

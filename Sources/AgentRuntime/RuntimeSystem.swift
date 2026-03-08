import Foundation
import PluginSDK
import Protocols

public struct RecoveryChannelState: Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RecoveryTaskState: Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var status: String
    public var title: String
    public var objective: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        channelId: String,
        status: String,
        title: String,
        objective: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.channelId = channelId
        self.status = status
        self.title = title
        self.objective = objective
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RecoveryArtifactState: Sendable, Equatable {
    public var id: String
    public var content: String
    public var createdAt: Date

    public init(id: String, content: String, createdAt: Date) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }
}

public actor RuntimeSystem {
    public nonisolated let eventBus: EventBus

    private let memoryStore: any MemoryStore
    private let channels: ChannelRuntime
    private let workers: WorkerRuntime
    private let branches: BranchRuntime
    private let compactor: Compactor
    private let visor: Visor
    private var modelProvider: (any ModelProviderPlugin)?
    private var defaultModel: String?

    public init(
        modelProvider: (any ModelProviderPlugin)? = nil,
        defaultModel: String? = nil,
        workerExecutor: (any WorkerExecutor)? = nil,
        memoryStore: (any MemoryStore)? = nil
    ) {
        let bus = EventBus()
        let memory = memoryStore ?? InMemoryMemoryStore()
        self.eventBus = bus
        self.memoryStore = memory
        self.channels = ChannelRuntime(eventBus: bus)
        self.workers = WorkerRuntime(
            eventBus: bus,
            executor: workerExecutor ?? DefaultWorkerExecutor()
        )
        self.branches = BranchRuntime(eventBus: bus, memoryStore: memory)
        self.compactor = Compactor(eventBus: bus)
        self.visor = Visor(eventBus: bus, memoryStore: memory)
        self.modelProvider = modelProvider
        self.defaultModel = defaultModel ?? modelProvider?.models.first
    }

    /// Hot-swaps worker executor backend for subsequent worker operations.
    public func updateWorkerExecutor(_ executor: any WorkerExecutor) async {
        await workers.updateExecutor(executor)
    }

    /// Hot-swaps model provider and default model for subsequent direct responses.
    public func updateModelProvider(modelProvider: (any ModelProviderPlugin)?, defaultModel: String?) {
        self.modelProvider = modelProvider

        guard let modelProvider else {
            self.defaultModel = nil
            return
        }

        let normalizedDefault = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDefault, !normalizedDefault.isEmpty, modelProvider.models.contains(normalizedDefault) {
            self.defaultModel = normalizedDefault
            return
        }

        self.defaultModel = modelProvider.models.first
    }

    /// Posts channel message and executes route-specific orchestration flow.
    public func postMessage(
        channelId: String,
        request: ChannelMessageRequest,
        onResponseChunk: (@Sendable (String) async -> Bool)? = nil,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)? = nil
    ) async -> ChannelRouteDecision {
        let ingest = await channels.ingest(channelId: channelId, request: request)

        switch ingest.decision.action {
        case .respond:
            await respondInline(
                channelId: channelId,
                userMessage: request.content,
                model: request.model,
                reasoningEffort: request.reasoningEffort,
                onResponseChunk: onResponseChunk,
                toolInvoker: toolInvoker
            )

        case .spawnBranch:
            let branchId = await branches.spawn(channelId: channelId, prompt: request.content)
            let spec = WorkerTaskSpec(
                taskId: "branch-\(branchId)",
                channelId: channelId,
                title: "Branch analysis",
                objective: request.content,
                tools: ["shell", "file", "exec"],
                mode: .fireAndForget
            )
            let workerId = await workers.spawn(spec: spec, autoStart: false)
            await branches.attachWorker(branchId: branchId, workerId: workerId)
            await channels.attachWorker(channelId: channelId, workerId: workerId)

            let artifact = await workers.completeNow(workerId: workerId, summary: "Branch worker completed objective")
            await channels.detachWorker(channelId: channelId, workerId: workerId)

            let conclusion = await branches.conclude(
                branchId: branchId,
                summary: "Branch finished with focused conclusion",
                artifactRefs: artifact.map { [$0] } ?? [],
                tokenUsage: TokenUsage(prompt: 300, completion: 120)
            )
            if let conclusion {
                await channels.applyBranchConclusion(channelId: channelId, conclusion: conclusion)
            }

        case .spawnWorker:
            let spec = WorkerTaskSpec(
                taskId: UUID().uuidString,
                channelId: channelId,
                title: "Channel worker",
                objective: request.content,
                tools: ["shell", "file", "exec", "browser"],
                mode: .interactive
            )
            let workerId = await workers.spawn(spec: spec, autoStart: true)
            await channels.attachWorker(channelId: channelId, workerId: workerId)
        }

        if let job = await compactor.evaluate(channelId: channelId, utilization: ingest.contextUtilization) {
            await compactor.apply(job: job, workers: workers)
            await channels.appendSystemMessage(channelId: channelId, content: "Compactor scheduled \(job.level.rawValue) policy")
        }

        return ingest.decision
    }

    /// Uses configured model provider for direct responses or falls back to static response.
    private func respondInline(
        channelId: String,
        userMessage: String,
        model: String?,
        reasoningEffort: ReasoningEffort?,
        onResponseChunk: (@Sendable (String) async -> Bool)?,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?
    ) async {
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeModel = (normalizedModel?.isEmpty == false ? normalizedModel : nil) ?? defaultModel

        guard let modelProvider, let activeModel else {
            let fallback = "Responded inline"
            if let onResponseChunk {
                _ = await onResponseChunk(fallback)
            }
            await channels.appendSystemMessage(channelId: channelId, content: fallback)
            return
        }

        do {
            let contextualPrompt = await buildContextualPrompt(
                channelId: channelId,
                fallbackUserMessage: userMessage
            )

            if let toolInvoker {
                let basePrompt = contextualPrompt
                var currentPrompt = basePrompt
                let maxToolSteps = 8

                for _ in 0..<maxToolSteps {
                    var latest = ""
                    let stream = modelProvider.stream(
                        model: activeModel,
                        prompt: currentPrompt,
                        maxTokens: 1024,
                        reasoningEffort: reasoningEffort
                    )
                    for try await partial in stream {
                        latest = partial
                        if let onResponseChunk {
                            let shouldContinue = await onResponseChunk(latest)
                            if !shouldContinue {
                                if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    await channels.appendSystemMessage(channelId: channelId, content: latest)
                                }
                                return
                            }
                        }
                    }

                    if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        latest = try await modelProvider.complete(
                            model: activeModel,
                            prompt: currentPrompt,
                            maxTokens: 1024,
                            reasoningEffort: reasoningEffort
                        )
                        if let onResponseChunk {
                            let shouldContinue = await onResponseChunk(latest)
                            if !shouldContinue {
                                if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    await channels.appendSystemMessage(channelId: channelId, content: latest)
                                }
                                return
                            }
                        }
                    }

                    let trimmed = latest.trimmingCharacters(in: .whitespacesAndNewlines)

                    if let call = parseToolCall(from: trimmed) {
                        let result = await toolInvoker(call)
                        let resultJSON = encodedToolResult(result)
                        currentPrompt =
                            """
                            \(basePrompt)

                            [tool_loop_v1]
                            Previous tool call:
                            \(trimmed)

                            Tool result:
                            \(resultJSON)

                            If you need another tool call, return strict JSON object:
                            {"tool":"<tool-id>","arguments":{},"reason":"<short reason>"}
                            Otherwise return final answer in plain text.
                            """
                        if let onResponseChunk {
                            _ = await onResponseChunk("")
                        }
                        continue
                    }

                    await channels.appendSystemMessage(channelId: channelId, content: latest)
                    return
                }

                let limitMessage = "Tool call limit reached. Provide final answer without new tool calls."
                if let onResponseChunk {
                    _ = await onResponseChunk(limitMessage)
                }
                await channels.appendSystemMessage(channelId: channelId, content: limitMessage)
                return
            }

            var latest = ""
            let stream = modelProvider.stream(
                model: activeModel,
                prompt: contextualPrompt,
                maxTokens: 1024,
                reasoningEffort: reasoningEffort
            )
            for try await partial in stream {
                latest = partial
                if let onResponseChunk {
                    let shouldContinue = await onResponseChunk(latest)
                    if !shouldContinue {
                        if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await channels.appendSystemMessage(channelId: channelId, content: latest)
                        }
                        return
                    }
                }
            }

            if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latest = try await modelProvider.complete(
                    model: activeModel,
                    prompt: contextualPrompt,
                    maxTokens: 1024,
                    reasoningEffort: reasoningEffort
                )
                if let onResponseChunk {
                    _ = await onResponseChunk(latest)
                }
            }

            await channels.appendSystemMessage(channelId: channelId, content: latest)
        } catch {
            let text = "Model provider error: \(error)"
            if let onResponseChunk {
                _ = await onResponseChunk(text)
            }
            await channels.appendSystemMessage(
                channelId: channelId,
                content: text
            )
        }
    }

    private func buildContextualPrompt(channelId: String, fallbackUserMessage: String) async -> String {
        guard let snapshot = await channels.snapshot(channelId: channelId), !snapshot.messages.isEmpty else {
            return fallbackUserMessage
        }

        var lines: [String] = [
            "[channel_context_v1]",
            "Use the conversation context below to answer the latest user request.",
            ""
        ]

        for message in snapshot.messages.suffix(80) {
            let role: String
            if message.userId == "system" {
                role = "system"
            } else if message.userId == "agent" || message.userId == "assistant" {
                role = "assistant"
            } else {
                role = "user"
            }

            lines.append("[\(role)]")
            lines.append(message.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func parseToolCall(from raw: String) -> ToolInvocationRequest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let fenced = extractJSONFence(from: trimmed) {
            return decodeToolCall(fenced)
        }
        if let decoded = decodeToolCall(trimmed) {
            return decoded
        }
        return extractInlineJSONObject(from: trimmed)
    }

    private func decodeToolCall(_ raw: String) -> ToolInvocationRequest? {
        guard let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ToolInvocationRequest.self, from: data)
    }

    private func extractJSONFence(from text: String) -> String? {
        guard text.hasPrefix("```") else {
            return nil
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let prefix = "```json\n"
        let content: String
        if normalized.hasPrefix(prefix) {
            content = String(normalized.dropFirst(prefix.count))
        } else if normalized.hasPrefix("```\n") {
            content = String(normalized.dropFirst("```\n".count))
        } else {
            return nil
        }

        guard let fenceRange = content.range(of: "\n```") else {
            return nil
        }
        return String(content[..<fenceRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractInlineJSONObject(from text: String) -> ToolInvocationRequest? {
        let characters = Array(text)
        var startIndex: Int?
        var depth = 0
        var inString = false
        var isEscaped = false

        for (index, character) in characters.enumerated() {
            if inString {
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if character == "\\" {
                    isEscaped = true
                    continue
                }
                if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
                continue
            }

            if character == "}" {
                guard depth > 0 else {
                    continue
                }
                depth -= 1
                if depth == 0, let startIndex {
                    let candidate = String(characters[startIndex...index])
                    if let decoded = decodeToolCall(candidate) {
                        return decoded
                    }
                }
            }
        }

        return nil
    }

    private func encodedToolResult(_ result: ToolInvocationResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{\"tool\":\"\(result.tool)\",\"ok\":\(result.ok ? "true" : "false")}"
    }

    /// Routes interactive payload to worker bound to the channel.
    public func routeMessage(channelId: String, workerId: String, message: String) async -> Bool {
        let result = await workers.route(workerId: workerId, message: message)
        guard result.accepted else {
            return false
        }

        if result.completed {
            await channels.detachWorker(channelId: channelId, workerId: workerId)
            if let artifact = result.artifactRef {
                await channels.appendSystemMessage(
                    channelId: channelId,
                    content: "Worker \(workerId) completed with artifact \(artifact.id)"
                )
            }
        }

        return true
    }

    /// Performs one-shot completion with currently configured model provider.
    /// Returns nil when no provider/model is configured or completion fails.
    public func complete(prompt: String, maxTokens: Int = 1024) async -> String? {
        guard let modelProvider, let defaultModel else {
            return nil
        }
        return try? await modelProvider.complete(
            model: defaultModel,
            prompt: prompt,
            maxTokens: maxTokens,
            reasoningEffort: nil
        )
    }

    /// Creates worker and attaches it to channel tracking.
    public func createWorker(spec: WorkerTaskSpec) async -> String {
        let workerId = await workers.spawn(spec: spec, autoStart: true)
        await channels.attachWorker(channelId: spec.channelId, workerId: workerId)
        return workerId
    }

    /// Rebuilds in-memory runtime state from persisted channels/tasks/events/artifacts.
    public func recover(
        channels channelStates: [RecoveryChannelState],
        tasks taskStates: [RecoveryTaskState],
        events: [EventEnvelope],
        artifacts: [RecoveryArtifactState]
    ) async {
        await channels.resetForRecovery()
        await workers.resetForRecovery()

        for channel in channelStates.sorted(by: { $0.createdAt < $1.createdAt }) {
            await channels.ensureChannel(channelId: channel.id)
        }

        for artifact in artifacts.sorted(by: { $0.createdAt < $1.createdAt }) {
            await workers.restoreArtifact(id: artifact.id, content: artifact.content)
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: taskStates.map { ($0.id, $0) })
        let orderedEvents = events.sorted { left, right in
            if left.ts == right.ts {
                return left.messageId < right.messageId
            }
            return left.ts < right.ts
        }

        for event in orderedEvents {
            await replayRecoveredEvent(event, tasksByID: tasksByID)
        }

        let eventCountsByChannel = Dictionary(grouping: orderedEvents, by: { $0.channelId })
        for (channelID, eventsForChannel) in eventCountsByChannel where !eventsForChannel.isEmpty {
            if let snapshot = await channels.snapshot(channelId: channelID), snapshot.messages.isEmpty {
                await channels.appendSystemMessage(
                    channelId: channelID,
                    content: "Recovered \(eventsForChannel.count) persisted events."
                )
            }
        }

        for task in taskStates {
            let hasTask = await workers.hasTask(taskId: task.id)
            if hasTask {
                continue
            }
            let spec = WorkerTaskSpec(
                taskId: task.id,
                channelId: task.channelId,
                title: task.title,
                objective: task.objective,
                tools: [],
                mode: .interactive
            )
            let workerID = "recovered-\(task.id)"
            await workers.restoreWorker(
                workerId: workerID,
                spec: spec,
                status: workerStatus(from: task.status),
                latestReport: nil,
                artifactId: nil
            )
            if workerStatus(from: task.status) == .queued ||
                workerStatus(from: task.status) == .running ||
                workerStatus(from: task.status) == .waitingInput {
                await channels.attachWorker(channelId: task.channelId, workerId: workerID)
            }
        }
    }

    private func replayRecoveredEvent(
        _ event: EventEnvelope,
        tasksByID: [String: RecoveryTaskState]
    ) async {
        await channels.ensureChannel(channelId: event.channelId)

        switch event.messageType {
        case .channelMessageReceived:
            guard let userId = event.payload.objectValue["userId"]?.stringValue,
                  let message = event.payload.objectValue["message"]?.stringValue
            else {
                return
            }
            await channels.restoreMessage(
                channelId: event.channelId,
                message: ChannelMessageEntry(
                    id: event.messageId,
                    userId: userId,
                    content: message,
                    createdAt: event.ts
                )
            )

        case .channelRouteDecided:
            guard let decision = try? JSONValueCoder.decode(ChannelRouteDecision.self, from: event.payload) else {
                return
            }
            await channels.restoreDecision(channelId: event.channelId, decision: decision)

        case .branchConclusion:
            guard let conclusion = try? JSONValueCoder.decode(BranchConclusion.self, from: event.payload) else {
                return
            }
            await channels.applyBranchConclusion(channelId: event.channelId, conclusion: conclusion)

        case .workerSpawned:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let spec = recoveredWorkerSpec(
                event: event,
                workerId: workerID,
                taskId: taskID,
                tasksByID: tasksByID
            )
            await workers.restoreWorker(
                workerId: workerID,
                spec: spec,
                status: .queued,
                latestReport: nil,
                artifactId: nil
            )
            await channels.attachWorker(channelId: event.channelId, workerId: workerID)

        case .workerProgress:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let progress = event.payload.objectValue["progress"]?.stringValue
            let status: WorkerStatus = (progress == "waiting_for_route") ? .waitingInput : .running
            let updated = await workers.updateRecoveredWorker(
                workerId: workerID,
                status: status,
                latestReport: progress,
                artifactId: nil
            )
            if !updated {
                let spec = recoveredWorkerSpec(
                    event: event,
                    workerId: workerID,
                    taskId: taskID,
                    tasksByID: tasksByID
                )
                await workers.restoreWorker(
                    workerId: workerID,
                    spec: spec,
                    status: status,
                    latestReport: progress,
                    artifactId: nil
                )
            }
            await channels.attachWorker(channelId: event.channelId, workerId: workerID)

        case .workerCompleted:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let summary = event.payload.objectValue["summary"]?.stringValue
            let artifactID = event.payload.objectValue["artifactId"]?.stringValue
            let updated = await workers.updateRecoveredWorker(
                workerId: workerID,
                status: .completed,
                latestReport: summary,
                artifactId: artifactID
            )
            if !updated {
                let spec = recoveredWorkerSpec(
                    event: event,
                    workerId: workerID,
                    taskId: taskID,
                    tasksByID: tasksByID
                )
                await workers.restoreWorker(
                    workerId: workerID,
                    spec: spec,
                    status: .completed,
                    latestReport: summary,
                    artifactId: artifactID
                )
            }
            await channels.detachWorker(channelId: event.channelId, workerId: workerID)

        case .workerFailed:
            guard let workerID = event.workerId,
                  let taskID = event.taskId
            else {
                return
            }
            let error = event.payload.objectValue["error"]?.stringValue
            let updated = await workers.updateRecoveredWorker(
                workerId: workerID,
                status: .failed,
                latestReport: error,
                artifactId: nil
            )
            if !updated {
                let spec = recoveredWorkerSpec(
                    event: event,
                    workerId: workerID,
                    taskId: taskID,
                    tasksByID: tasksByID
                )
                await workers.restoreWorker(
                    workerId: workerID,
                    spec: spec,
                    status: .failed,
                    latestReport: error,
                    artifactId: nil
                )
            }
            await channels.detachWorker(channelId: event.channelId, workerId: workerID)

        default:
            break
        }
    }

    private func recoveredWorkerSpec(
        event: EventEnvelope,
        workerId: String,
        taskId: String,
        tasksByID: [String: RecoveryTaskState]
    ) -> WorkerTaskSpec {
        let taskState = tasksByID[taskId]
        let modeText = event.payload.objectValue["mode"]?.stringValue
        let mode = modeText.flatMap(WorkerMode.init(rawValue:)) ?? .interactive
        let title = event.payload.objectValue["title"]?.stringValue ?? taskState?.title ?? "Recovered worker \(workerId)"
        let objective = taskState?.objective ?? event.payload.objectValue["objective"]?.stringValue ?? ""

        return WorkerTaskSpec(
            taskId: taskId,
            channelId: event.channelId,
            title: title,
            objective: objective,
            tools: [],
            mode: mode
        )
    }

    private func workerStatus(from raw: String) -> WorkerStatus {
        switch raw.lowercased() {
        case "queued", "ready", "pending_approval", "backlog":
            .queued
        case "running", "in_progress":
            .running
        case "waiting_input", "waitinginput":
            .waitingInput
        case "completed", "done":
            .completed
        case "failed":
            .failed
        default:
            .queued
        }
    }

    /// Returns channel snapshot by identifier.
    public func channelState(channelId: String) async -> ChannelSnapshot? {
        await channels.snapshot(channelId: channelId)
    }

    /// Appends one synthetic system message into channel context.
    public func appendSystemMessage(channelId: String, content: String) async {
        await channels.appendSystemMessage(channelId: channelId, content: content)
    }

    /// Returns artifact content by identifier.
    public func artifactContent(id: String) async -> String? {
        await workers.artifactContent(id: id)
    }

    /// Generates visor bulletin and applies digest into channel histories.
    public func generateVisorBulletin(taskSummary: String? = nil) async -> MemoryBulletin {
        let channelSnapshots = await channels.snapshots()
        let workerSnapshots = await workers.snapshots()
        let bulletin = await visor.generateBulletin(
            channels: channelSnapshots,
            workers: workerSnapshots,
            taskSummary: taskSummary
        )
        await channels.applyBulletinDigest(bulletin.digest)
        return bulletin
    }

    /// Returns collected bulletins.
    public func bulletins() async -> [MemoryBulletin] {
        await visor.listBulletins()
    }

    /// Returns current worker snapshots.
    public func workerSnapshots() async -> [WorkerSnapshot] {
        await workers.snapshots()
    }

    /// Returns memory entries tracked by runtime memory store.
    public func memoryEntries() async -> [MemoryEntry] {
        await memoryStore.entries()
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let object) = self {
            return object
        }
        return [:]
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

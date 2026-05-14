import AnyLanguageModel
import Foundation
import Logging
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

public enum RuntimeResponseObservation: Sendable {
    case thinking(String)
    case toolCall(ToolInvocationRequest)
    case toolResult(ToolInvocationResult)
    case usage(TokenUsage)
}

public struct BranchExecutionResult: Sendable, Equatable {
    public var branchId: String
    public var workerId: String
    public var conclusion: BranchConclusion

    public init(branchId: String, workerId: String, conclusion: BranchConclusion) {
        self.branchId = branchId
        self.workerId = workerId
        self.conclusion = conclusion
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
    private let logger: Logger
    private let preResponseMemoryLimit: Int
    private var modelProvider: (any ModelProvider)?
    private var defaultModel: String?

    private struct CachedLanguageModelSession {
        var model: String
        var session: LanguageModelSession
    }

    private struct ActiveResponseTask {
        var id: UUID
        var task: Task<Void, Never>
    }

    /// Persistent LLM sessions keyed by channel ID. Each session accumulates full
    /// transcript (prompts, tool calls, tool outputs, responses) so the model sees
    /// complete history without rebuilding context on every turn.
    private var sessionsByChannel: [String: CachedLanguageModelSession] = [:]

    /// Active inline model responses keyed by channel ID. Interrupts cancel these
    /// tasks directly instead of waiting for the next cooperative stream chunk.
    private var activeResponseTasks: [String: ActiveResponseTask] = [:]

    /// Bootstrap system prompt content per channel, kept to recreate sessions after
    /// context overflow or model hot-swap.
    private var bootstrapByChannel: [String: String] = [:]

    /// When set, only these tool names (matching `Tool.name`) are passed to `LanguageModelSession` for the channel.
    private var channelToolAllowList: [String: Set<String>] = [:]

    public init(
        modelProvider: (any ModelProvider)? = nil,
        defaultModel: String? = nil,
        workerExecutor: (any WorkerExecutor)? = nil,
        memoryStore: (any MemoryStore)? = nil,
        visorCompletionProvider: (@Sendable (String, Int) async -> String?)? = nil,
        visorStreamingProvider: (@Sendable (String, Int) -> AsyncStream<String>)? = nil,
        visorBulletinMaxWords: Int = 300,
        preResponseMemoryLimit: Int = 8
    ) {
        let bus = EventBus()
        let memory = memoryStore ?? InMemoryMemoryStore()
        self.eventBus = bus
        self.memoryStore = memory
        self.preResponseMemoryLimit = max(0, preResponseMemoryLimit)
        self.channels = ChannelRuntime(eventBus: bus)
        self.workers = WorkerRuntime(
            eventBus: bus,
            executor: workerExecutor ?? DefaultWorkerExecutor()
        )
        self.branches = BranchRuntime(eventBus: bus, memoryStore: memory)
        self.compactor = Compactor(eventBus: bus)
        self.visor = Visor(
            eventBus: bus,
            memoryStore: memory,
            completionProvider: visorCompletionProvider,
            streamingProvider: visorStreamingProvider,
            bulletinMaxWords: visorBulletinMaxWords
        )
        self.logger = Logger(label: "sloppy.runtime.model")
        self.modelProvider = modelProvider
        self.defaultModel = defaultModel ?? modelProvider?.supportedModels.first
    }

    /// Hot-swaps worker executor backend for subsequent worker operations.
    public func updateWorkerExecutor(_ executor: any WorkerExecutor) async {
        await workers.updateExecutor(executor)
    }

    /// Hot-swaps model provider and default model for subsequent direct responses.
    /// Invalidates all cached LLM sessions so next request creates fresh ones with
    /// the new provider.
    public func updateModelProvider(modelProvider: (any ModelProvider)?, defaultModel: String?) {
        self.modelProvider = modelProvider
        sessionsByChannel.removeAll()
        channelToolAllowList.removeAll()

        guard let modelProvider else {
            self.defaultModel = nil
            return
        }

        let normalizedDefault = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDefault, !normalizedDefault.isEmpty, modelProvider.supports(modelName: normalizedDefault) {
            self.defaultModel = normalizedDefault
            return
        }

        self.defaultModel = modelProvider.supportedModels.first
    }

    /// Restricts tools exposed to the model for this channel. Pass `nil` or an empty set to clear filtering.
    public func setChannelToolAllowList(channelId: String, toolIDs: Set<String>?) {
        guard let toolIDs, !toolIDs.isEmpty else {
            channelToolAllowList.removeValue(forKey: channelId)
            return
        }
        channelToolAllowList[channelId] = toolIDs
    }

    public func clearChannelToolAllowList(channelId: String) {
        channelToolAllowList.removeValue(forKey: channelId)
    }

    /// Removes a cached `LanguageModelSession` so the next turn builds a fresh session (e.g. after tool allowlist changes).
    public func invalidateChannelSession(channelId: String) {
        sessionsByChannel.removeValue(forKey: channelId)
    }

    /// Posts channel message and executes route-specific orchestration flow.
    public func postMessage(
        channelId: String,
        request: ChannelMessageRequest,
        onResponseChunk: (@Sendable (String) async -> Bool)? = nil,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)? = nil,
        observationHandler: (@Sendable (RuntimeResponseObservation) async -> Void)? = nil
    ) async -> ChannelRouteDecision {
        let ingest = await channels.ingest(channelId: channelId, request: request)

        switch ingest.decision.action {
        case .respond:
            let taskID = UUID()
            let responseTask = Task { [weak self] in
                guard let self else { return }
                await self.respondInline(
                    channelId: channelId,
                    userMessage: request.content,
                    model: request.model,
                    reasoningEffort: request.reasoningEffort,
                    onResponseChunk: onResponseChunk,
                    toolInvoker: toolInvoker,
                    observationHandler: observationHandler
                )
            }
            activeResponseTasks[channelId] = ActiveResponseTask(id: taskID, task: responseTask)
            await withTaskCancellationHandler {
                await responseTask.value
            } onCancel: {
                responseTask.cancel()
            }
            if activeResponseTasks[channelId]?.id == taskID {
                activeResponseTasks.removeValue(forKey: channelId)
            }

        case .spawnBranch:
            _ = await executeBranch(
                channelId: channelId,
                prompt: request.content
            )

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

    public func executeBranch(
        channelId: String,
        prompt: String,
        title: String = "Branch analysis"
    ) async -> BranchExecutionResult? {
        let branchId = await branches.spawn(channelId: channelId, prompt: prompt)
        let spec = WorkerTaskSpec(
            taskId: "branch-\(branchId)",
            channelId: channelId,
            title: title,
            objective: prompt,
            tools: ["shell", "file", "exec"],
            mode: .fireAndForget
        )
        let workerId = await workers.spawn(spec: spec, autoStart: false)
        await branches.attachWorker(branchId: branchId, workerId: workerId)
        await channels.attachWorker(channelId: channelId, workerId: workerId)

        let artifact = await workers.completeNow(workerId: workerId, summary: "Branch worker completed objective")
        await channels.detachWorker(channelId: channelId, workerId: workerId)

        guard let conclusion = await branches.conclude(
            branchId: branchId,
            summary: "Branch finished with focused conclusion",
            artifactRefs: artifact.map { [$0] } ?? [],
            tokenUsage: TokenUsage(prompt: 300, completion: 120)
        ) else {
            return nil
        }

        await channels.applyBranchConclusion(channelId: channelId, conclusion: conclusion)
        return BranchExecutionResult(
            branchId: branchId,
            workerId: workerId,
            conclusion: conclusion
        )
    }

    /// Uses configured model provider for direct responses or falls back to static response.
    /// Reuses a persistent `LanguageModelSession` per channel so the full transcript
    /// (tool calls, tool outputs, previous responses) is preserved across turns.
    private func respondInline(
        channelId: String,
        userMessage: String,
        model: String?,
        reasoningEffort: ReasoningEffort?,
        onResponseChunk: (@Sendable (String) async -> Bool)?,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?,
        observationHandler: (@Sendable (RuntimeResponseObservation) async -> Void)?,
        streamRetries: Int = 2
    ) async {
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeModel = (normalizedModel?.isEmpty == false ? normalizedModel : nil) ?? defaultModel

        guard let modelProvider, let activeModel else {
            let fallback = "Responded inline"
            if let observationHandler {
                await observationHandler(.thinking("Using fallback inline response because no model provider is configured."))
            }
            if let onResponseChunk {
                _ = await onResponseChunk(fallback)
            }
            await channels.appendSystemMessage(channelId: channelId, content: fallback)
            return
        }

        let tracker = StreamActivityTracker()

        do {
            try Task.checkCancellation()

            let session = try await getOrCreateSession(
                channelId: channelId,
                activeModel: activeModel,
                modelProvider: modelProvider,
                includeTools: toolInvoker != nil
            )

            if let invoker = toolInvoker {
                let observingHandler: @Sendable (ToolInvocationRequest) async -> ToolInvocationResult = { request in
                    await tracker.toolStarted()
                    if let observationHandler {
                        await observationHandler(.toolCall(request))
                    }
                    let result = await invoker(request)
                    if let observationHandler {
                        await observationHandler(.toolResult(result))
                    }
                    await tracker.toolFinished(result: result)
                    return result
                }
                session.toolExecutionDelegate = makeToolExecutionDelegate(
                    for: session,
                    toolCallHandler: observingHandler
                )
            }

            let options = modelProvider.generationOptions(for: activeModel, maxTokens: 1024, reasoningEffort: reasoningEffort)
            let transcriptSize = session.transcript.count
            let streamMode = toolInvoker != nil ? "native_tool_stream" : "respond_stream"
            let modelUserMessage = await userMessageWithAutoRecalledMemory(
                channelId: channelId,
                userMessage: userMessage
            )

            logger.info(
                "Model stream started",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: modelUserMessage.count,
                    mode: streamMode,
                    transcriptEntries: transcriptSize
                )
            )

            let streamStartedAt = Date()
            let streamIdleTimeoutSeconds: Int = 120

            let responseStream = session.streamResponse(to: modelUserMessage, options: options)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(10))
                            if await tracker.shouldTriggerIdleTimeout(thresholdSeconds: streamIdleTimeoutSeconds) {
                                throw StreamIdleTimeoutError()
                            }
                        }
                    }
                    group.addTask { @Sendable [tracker] in
                        for try await snapshot in responseStream {
                            await tracker.touchChunk()
                            await tracker.update(content: snapshot.content)
                            if let onResponseChunk {
                                let shouldContinue = await onResponseChunk(snapshot.content)
                                if !shouldContinue {
                                    await tracker.markCancelledByConsumer()
                                    return
                                }
                            }
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch is StreamIdleTimeoutError {
                let chunks = await tracker.chunks
                let content = await tracker.latestContent
                logger.warning(
                    "Model stream timed out (idle), retrying",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: content.count,
                        streamChunks: chunks,
                        error: "No data received for \(streamIdleTimeoutSeconds)s"
                    )
                )
                if streamRetries > 0 {
                    sessionsByChannel.removeValue(forKey: channelId)
                    await respondInline(
                        channelId: channelId,
                        userMessage: userMessage,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        onResponseChunk: onResponseChunk,
                        toolInvoker: toolInvoker,
                        observationHandler: observationHandler,
                        streamRetries: streamRetries - 1
                    )
                    return
                }
                logger.warning(
                    "All stream retries exhausted, trying non-streaming completion",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: "non_streaming_fallback"
                    )
                )
                sessionsByChannel.removeValue(forKey: channelId)
                do {
                    let freshSession = try await getOrCreateSession(
                        channelId: channelId,
                        activeModel: activeModel,
                        modelProvider: modelProvider,
                        includeTools: toolInvoker != nil
                    )
                    if let invoker = toolInvoker {
                        let observingHandler: @Sendable (ToolInvocationRequest) async -> ToolInvocationResult = { request in
                            await tracker.toolStarted()
                            if let observationHandler {
                                await observationHandler(.toolCall(request))
                            }
                            let result = await invoker(request)
                            if let observationHandler {
                                await observationHandler(.toolResult(result))
                            }
                            await tracker.toolFinished(result: result)
                            return result
                        }
                        freshSession.toolExecutionDelegate = makeToolExecutionDelegate(
                            for: freshSession,
                            toolCallHandler: observingHandler
                        )
                    }
                    let fallbackResponse = try await freshSession.respond(to: modelUserMessage, options: options)
                    var fallbackContent = fallbackResponse.content
                    logger.info(
                        "Non-streaming fallback succeeded",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "non_streaming_fallback",
                            durationMs: elapsedMilliseconds(since: streamStartedAt),
                            outputChars: fallbackContent.count
                        )
                    )
                    if fallbackContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if await tracker.sawToolTimeout {
                            fallbackContent = "Tool execution timed out before the model produced a final response. Please review the timed-out tool result and retry when ready."
                            logger.warning(
                                "Non-streaming fallback returned empty response after tool timeout",
                                metadata: modelCallMetadata(
                                    channelId: channelId,
                                    model: activeModel,
                                    reasoningEffort: reasoningEffort,
                                    promptChars: modelUserMessage.count,
                                    mode: "non_streaming_fallback_empty_tool_timeout",
                                    outputChars: fallbackContent.count
                                )
                            )
                        } else if let repaired = await attemptEmptyResponseRepair(
                            channelId: channelId,
                            activeModel: activeModel,
                            modelProvider: modelProvider,
                            reasoningEffort: reasoningEffort,
                            originalUserMessage: modelUserMessage,
                            transcript: freshSession.transcript,
                            onResponseChunk: nil
                        ) {
                            fallbackContent = repaired
                        } else {
                            fallbackContent = "Model returned an empty response. Please try rephrasing or try again."
                            logger.warning(
                                "Non-streaming fallback returned empty response after repair",
                                metadata: modelCallMetadata(
                                    channelId: channelId,
                                    model: activeModel,
                                    reasoningEffort: reasoningEffort,
                                    promptChars: modelUserMessage.count,
                                    mode: "non_streaming_fallback_empty"
                                )
                            )
                        }
                    }
                    if let onResponseChunk {
                        _ = await onResponseChunk(fallbackContent)
                    }
                    await channels.appendSystemMessage(channelId: channelId, content: fallbackContent)
                    return
                } catch {
                    logger.warning(
                        "Non-streaming fallback also failed",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "non_streaming_fallback",
                            error: String(describing: error)
                        )
                    )
                    throw StreamIdleTimeoutError()
                }
            } catch let error as LanguageModelSession.GenerationError {
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                if case .exceededContextWindowSize = error {
                    logger.warning(
                        "Context window exceeded, recreating session with summary",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: streamMode,
                            error: String(describing: error)
                        )
                    )
                    let recovered = await respondAfterContextReset(
                        channelId: channelId,
                        userMessage: modelUserMessage,
                        activeModel: activeModel,
                        modelProvider: modelProvider,
                        reasoningEffort: reasoningEffort,
                        onResponseChunk: onResponseChunk,
                        toolInvoker: toolInvoker,
                        observationHandler: observationHandler
                    )
                    if let recovered {
                        await channels.appendSystemMessage(channelId: channelId, content: recovered)
                    }
                    return
                }
                logger.warning(
                    "Model stream failed",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks,
                        error: String(describing: error)
                    )
                )
                throw error
            } catch {
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                logger.warning(
                    "Model stream failed",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks,
                        error: String(describing: error)
                    )
                )
                throw error
            }

            if Task.isCancelled {
                sessionsByChannel.removeValue(forKey: channelId)
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                logger.info(
                    "Model stream task cancelled",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks
                    )
                )
                return
            }

            let cancelledByConsumer = await tracker.wasCancelledByConsumer
            if cancelledByConsumer {
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                logger.info(
                    "Model stream cancelled by response consumer",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks
                    )
                )
                if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await channels.appendSystemMessage(channelId: channelId, content: latest)
                }
                return
            }

            var latest = await tracker.latestContent
            let streamChunks = await tracker.chunks
            logger.info(
                "Model stream finished",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: modelUserMessage.count,
                    mode: streamMode,
                    durationMs: elapsedMilliseconds(since: streamStartedAt),
                    outputChars: latest.count,
                    streamChunks: streamChunks
                )
            )

            if let observationHandler {
                let reasoningText = modelProvider.reasoningCapture(for: activeModel)?.consume() ?? ""
                if !reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await observationHandler(.thinking(reasoningText))
                }

                if let captured = modelProvider.tokenUsageCapture(for: activeModel)?.consume() {
                    await observationHandler(.usage(TokenUsage(prompt: captured.prompt, completion: captured.completion)))
                }
            }

            if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let completionStartedAt = Date()
                logger.info(
                    "Model completion started",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: "respond_complete"
                    )
                )
                do {
                    let response = try await session.respond(to: modelUserMessage, options: options)
                    latest = response.content
                } catch {
                    logger.warning(
                        "Model completion failed",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "respond_complete",
                            durationMs: elapsedMilliseconds(since: completionStartedAt),
                            error: String(describing: error)
                        )
                    )
                    throw error
                }
                logger.info(
                    "Model completion finished",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: "respond_complete",
                        durationMs: elapsedMilliseconds(since: completionStartedAt),
                        outputChars: latest.count
                    )
                )
                if let onResponseChunk {
                    _ = await onResponseChunk(latest)
                }
            }

            if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if await tracker.sawToolTimeout {
                    latest = "Tool execution timed out before the model produced a final response. Please review the timed-out tool result and retry when ready."
                    logger.warning(
                        "Model returned empty response after tool timeout",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "respond_empty_tool_timeout",
                            outputChars: latest.count
                        )
                    )
                    if let onResponseChunk {
                        _ = await onResponseChunk(latest)
                    }
                } else if let repaired = await attemptEmptyResponseRepair(
                    channelId: channelId,
                    activeModel: activeModel,
                    modelProvider: modelProvider,
                    reasoningEffort: reasoningEffort,
                    originalUserMessage: modelUserMessage,
                    transcript: session.transcript,
                    onResponseChunk: onResponseChunk
                ) {
                    latest = repaired
                } else {
                    latest = "Model returned an empty response. Please try rephrasing or try again."
                    logger.warning(
                        "Model returned empty response after stream + completion + repair",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "respond_empty_fallback"
                        )
                    )
                    if let onResponseChunk {
                        _ = await onResponseChunk(latest)
                    }
                }
            }

            await channels.appendSystemMessage(channelId: channelId, content: latest)
        } catch is CancellationError {
            sessionsByChannel.removeValue(forKey: channelId)
            logger.info(
                "Model response cancelled",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: userMessage.count,
                    mode: "cancelled"
                )
            )
        } catch {
            sessionsByChannel.removeValue(forKey: channelId)
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

    private func attemptEmptyResponseRepair(
        channelId: String,
        activeModel: String,
        modelProvider: any ModelProvider,
        reasoningEffort: ReasoningEffort?,
        originalUserMessage: String,
        transcript: Transcript,
        onResponseChunk: (@Sendable (String) async -> Bool)?
    ) async -> String? {
        let startedAt = Date()
        let repairPrompt = await emptyResponseRepairPrompt(
            channelId: channelId,
            originalUserMessage: originalUserMessage,
            transcript: transcript
        )
        let options = modelProvider.generationOptions(for: activeModel, maxTokens: 1024, reasoningEffort: reasoningEffort)

        do {
            let languageModel = try await modelProvider.createLanguageModel(for: activeModel)
            let repairSession: LanguageModelSession
            if let instructions = sessionInstructions(channelId: channelId, modelProvider: modelProvider) {
                repairSession = LanguageModelSession(model: languageModel, tools: [], instructions: instructions)
            } else {
                repairSession = LanguageModelSession(model: languageModel, tools: [])
            }

            let response = try await repairSession.respond(to: repairPrompt, options: options)
            let repaired = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = !repaired.isEmpty
            logger.info(
                succeeded ? "Empty model response repair succeeded" : "Empty model response repair returned empty output",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: repairPrompt.count,
                    mode: "respond_empty_repair",
                    durationMs: elapsedMilliseconds(since: startedAt),
                    outputChars: response.content.count,
                    repairSucceeded: succeeded
                )
            )

            guard succeeded else {
                return nil
            }
            if let onResponseChunk {
                _ = await onResponseChunk(repaired)
            }
            return repaired
        } catch {
            logger.warning(
                "Empty model response repair failed",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: repairPrompt.count,
                    mode: "respond_empty_repair",
                    durationMs: elapsedMilliseconds(since: startedAt),
                    repairSucceeded: false,
                    error: String(describing: error)
                )
            )
            return nil
        }
    }

    private func emptyResponseRepairPrompt(
        channelId: String,
        originalUserMessage: String,
        transcript: Transcript
    ) async -> String {
        let channelMessages = await formatChannelMessagesForRepair(channelId: channelId)
        let modelTranscript = formatModelTranscriptForRepair(transcript)
        return """
        The previous model turn completed but produced no user-visible final answer.

        Write the final concise response for the user now. Use only the visible transcript, completed tool results, and progress shown below. Do not call tools. Do not claim to run new commands. Do not repeat completed work; summarize the solution or current outcome.

        [Current user message]
        \(originalUserMessage)

        [Visible channel transcript]
        \(channelMessages)

        [Model transcript and completed tool context]
        \(modelTranscript)

        [Final answer]
        """
    }

    private func formatChannelMessagesForRepair(channelId: String, maxCharacters: Int = 6_000) async -> String {
        let messages = await channels.snapshot(channelId: channelId)?.messages ?? []
        let lines = messages.suffix(20).map { message in
            "\(message.userId): \(message.content)"
        }
        return limitedRepairContext(lines.joined(separator: "\n"), maxCharacters: maxCharacters)
    }

    private func formatModelTranscriptForRepair(_ transcript: Transcript, maxCharacters: Int = 12_000) -> String {
        let lines = transcript.suffix(50).map { entry -> String in
            switch entry {
            case .instructions:
                return "instructions: [omitted]"
            case .prompt(let prompt):
                return "user: \(Self.textContent(from: prompt.segments))"
            case .response(let response):
                return "assistant: \(Self.textContent(from: response.segments))"
            case .toolCalls(let calls):
                let names = calls.map(\.toolName).joined(separator: ", ")
                return "tool calls: \(names)"
            case .toolOutput(let output):
                let text = Self.textContent(from: output.segments)
                return "tool result \(output.toolName): \(text)"
            }
        }
        return limitedRepairContext(lines.joined(separator: "\n"), maxCharacters: maxCharacters)
    }

    private nonisolated static func textContent(from segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text):
                return text.content
            case .structure(let structure):
                return structure.content.jsonString
            case .image:
                return "[image]"
            }
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func limitedRepairContext(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "(empty)"
        }
        guard trimmed.count > maxCharacters else {
            return trimmed
        }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -maxCharacters)
        return "[truncated]\n" + String(trimmed[start...])
    }

    private func userMessageWithAutoRecalledMemory(channelId: String, userMessage: String) async -> String {
        guard preResponseMemoryLimit > 0,
              Self.isAgentSessionChannel(channelId),
              !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return userMessage
        }

        let hits = await memoryStore.recall(
            request: MemoryRecallRequest(
                query: userMessage,
                limit: preResponseMemoryLimit,
                scope: .channel(channelId)
            )
        )
        guard !hits.isEmpty else {
            return userMessage
        }

        let maxBlockCharacters = 6_000
        var lines = [
            "[Recalled scoped memory]",
            "Relevant memories from this agent session. Use them as background context; ignore anything irrelevant.",
        ]

        for hit in hits.prefix(preResponseMemoryLimit) {
            let score = String(format: "%.2f", hit.ref.score)
            let kind = hit.ref.kind?.rawValue ?? "unknown"
            let memoryClass = hit.ref.memoryClass?.rawValue ?? "unknown"
            let content = compactMemoryContent(summary: hit.summary, note: hit.note, maxCharacters: 500)
            let line = "- id: \(hit.ref.id) | score: \(score) | kind: \(kind) | class: \(memoryClass) | \(content)"
            let candidateLength = lines.joined(separator: "\n").count + line.count + 1
            guard candidateLength <= maxBlockCharacters else {
                break
            }
            lines.append(line)
        }

        guard lines.count > 2 else {
            return userMessage
        }

        return """
        \(lines.joined(separator: "\n"))

        [Current user message]
        \(userMessage)
        """
    }

    private static func isAgentSessionChannel(_ channelId: String) -> Bool {
        channelId.hasPrefix("agent:") && channelId.contains(":session:")
    }

    private func compactMemoryContent(summary: String?, note: String, maxCharacters: Int) -> String {
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = trimmedSummary.isEmpty ? note : trimmedSummary
        let normalized = source
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else {
            return normalized
        }
        let index = normalized.index(normalized.startIndex, offsetBy: maxCharacters)
        return String(normalized[..<index]) + "..."
    }

    private func filteredModelTools(
        channelId: String,
        modelProvider: any ModelProvider,
        includeTools: Bool
    ) -> [any Tool] {
        guard includeTools else { return [] }
        let full = modelProvider.tools
        guard let allow = channelToolAllowList[channelId], !allow.isEmpty else {
            return full
        }
        return full.filter { allow.contains($0.name) }
    }

    private func sanitizedModelTools(
        channelId: String,
        modelProvider: any ModelProvider,
        includeTools: Bool
    ) -> [any Tool] {
        ModelToolNameSanitizer.sanitizeTools(
            filteredModelTools(channelId: channelId, modelProvider: modelProvider, includeTools: includeTools)
        ).tools
    }

    private func makeToolExecutionDelegate(
        for session: LanguageModelSession,
        toolCallHandler: @escaping @Sendable (ToolInvocationRequest) async -> ToolInvocationResult
    ) -> SloppyToolExecutionDelegate {
        var nameMap: [String: String] = [:]
        for tool in session.tools {
            if let sanitized = tool as? SanitizedLanguageModelTool {
                nameMap[sanitized.name] = sanitized.originalName
            } else {
                nameMap[tool.name] = tool.name
            }
        }
        return SloppyToolExecutionDelegate(toolNameMap: nameMap, toolCallHandler: toolCallHandler)
    }

    /// Returns cached session for channel, or creates a new one seeded with the bootstrap
    /// system message if present.
    private func getOrCreateSession(
        channelId: String,
        activeModel: String,
        modelProvider: any ModelProvider,
        includeTools: Bool = true
    ) async throws -> LanguageModelSession {
        if let existing = sessionsByChannel[channelId] {
            if existing.model == activeModel {
                return existing.session
            }
            sessionsByChannel.removeValue(forKey: channelId)
        }

        let languageModel = try await modelProvider.createLanguageModel(for: activeModel)
        let tools = sanitizedModelTools(channelId: channelId, modelProvider: modelProvider, includeTools: includeTools)
        let session: LanguageModelSession
        if let instructions = sessionInstructions(channelId: channelId, modelProvider: modelProvider) {
            session = LanguageModelSession(model: languageModel, tools: tools, instructions: instructions)
        } else {
            session = LanguageModelSession(model: languageModel, tools: tools)
        }

        sessionsByChannel[channelId] = CachedLanguageModelSession(model: activeModel, session: session)
        logger.info(
            "LLM session created",
            metadata: [
                "channel_id": .string(channelId),
                "model": .string(activeModel),
                "has_bootstrap": .string(bootstrapByChannel[channelId] != nil ? "true" : "false")
            ]
        )
        return session
    }

    /// Creates a fresh session with only the bootstrap prompt and retries the user message.
    /// Called when the previous session hit the context window limit.
    private func respondAfterContextReset(
        channelId: String,
        userMessage: String,
        activeModel: String,
        modelProvider: any ModelProvider,
        reasoningEffort: ReasoningEffort?,
        onResponseChunk: (@Sendable (String) async -> Bool)?,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?,
        observationHandler: (@Sendable (RuntimeResponseObservation) async -> Void)?
    ) async -> String? {
        sessionsByChannel.removeValue(forKey: channelId)

        let languageModel: any LanguageModel
        do {
            languageModel = try await modelProvider.createLanguageModel(for: activeModel)
        } catch {
            return "Model provider error: \(error)"
        }

        let tools = sanitizedModelTools(
            channelId: channelId,
            modelProvider: modelProvider,
            includeTools: toolInvoker != nil
        )
        let freshSession: LanguageModelSession
        if let instructions = sessionInstructions(channelId: channelId, modelProvider: modelProvider) {
            freshSession = LanguageModelSession(model: languageModel, tools: tools, instructions: instructions)
        } else {
            freshSession = LanguageModelSession(model: languageModel, tools: tools)
        }

        sessionsByChannel[channelId] = CachedLanguageModelSession(model: activeModel, session: freshSession)

        if let invoker = toolInvoker {
            let observingHandler: @Sendable (ToolInvocationRequest) async -> ToolInvocationResult = { request in
                if let observationHandler {
                    await observationHandler(.toolCall(request))
                }
                let result = await invoker(request)
                if let observationHandler {
                    await observationHandler(.toolResult(result))
                }
                return result
            }
            freshSession.toolExecutionDelegate = makeToolExecutionDelegate(
                for: freshSession,
                toolCallHandler: observingHandler
            )
        }

        let options = modelProvider.generationOptions(for: activeModel, maxTokens: 1024, reasoningEffort: reasoningEffort)
        var latest = ""
        let responseStream = freshSession.streamResponse(to: userMessage, options: options)
        do {
            for try await snapshot in responseStream {
                latest = snapshot.content
                if let onResponseChunk {
                    let shouldContinue = await onResponseChunk(latest)
                    if !shouldContinue { break }
                }
            }
        } catch {
            return "Model provider error: \(error)"
        }

        if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let response = try? await freshSession.respond(to: userMessage, options: options)
            latest = response?.content ?? ""
            if let onResponseChunk, !latest.isEmpty {
                _ = await onResponseChunk(latest)
            }
        }

        return latest.isEmpty ? nil : latest
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        let elapsed = Date().timeIntervalSince(start)
        return Int((elapsed * 1000).rounded())
    }

    private func sessionInstructions(channelId: String, modelProvider: any ModelProvider) -> String? {
        let parts = [
            modelProvider.systemInstructions,
            bootstrapByChannel[channelId]
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func modelCallMetadata(
        channelId: String,
        model: String,
        reasoningEffort: ReasoningEffort?,
        promptChars: Int,
        mode: String,
        toolStep: Int? = nil,
        durationMs: Int? = nil,
        outputChars: Int? = nil,
        streamChunks: Int? = nil,
        toolId: String? = nil,
        toolResultOK: Bool? = nil,
        transcriptEntries: Int? = nil,
        repairSucceeded: Bool? = nil,
        error: String? = nil
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "channel_id": .string(channelId),
            "model": .string(model),
            "reasoning_effort": .string(reasoningEffort?.rawValue ?? "none"),
            "prompt_chars": .stringConvertible(promptChars),
            "mode": .string(mode)
        ]

        if let toolStep {
            metadata["tool_step"] = .stringConvertible(toolStep)
        }
        if let durationMs {
            metadata["duration_ms"] = .stringConvertible(durationMs)
        }
        if let outputChars {
            metadata["output_chars"] = .stringConvertible(outputChars)
        }
        if let streamChunks {
            metadata["stream_chunks"] = .stringConvertible(streamChunks)
        }
        if let toolId {
            metadata["tool_id"] = .string(toolId)
        }
        if let toolResultOK {
            metadata["tool_ok"] = .string(toolResultOK ? "true" : "false")
        }
        if let transcriptEntries {
            metadata["transcript_entries"] = .stringConvertible(transcriptEntries)
        }
        if let repairSucceeded {
            metadata["repair_succeeded"] = .string(repairSucceeded ? "true" : "false")
        }
        if let error {
            metadata["error"] = .string(error)
        }

        return metadata
    }

    /// Registers bootstrap system prompt content for a channel. Called by the orchestrator
    /// after composing the agent's identity/rules/capabilities prompt. The content is used
    /// to seed new LLM sessions (on first creation and after context overflow).
    public func setChannelBootstrap(channelId: String, content: String) async {
        bootstrapByChannel[channelId] = content
    }

    /// Clears cached LLM session and bootstrap for an ephemeral channel (memory checkpoints).
    public func discardEphemeralCheckpointChannel(channelId: String) async {
        sessionsByChannel.removeValue(forKey: channelId)
        bootstrapByChannel.removeValue(forKey: channelId)
        await channels.removeChannel(channelId: channelId)
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
    public func complete(prompt: some PromptRepresentable, maxTokens: Int = 1024) async -> String? {
        guard let modelProvider, let defaultModel else {
            return nil
        }
        guard let languageModel = try? await modelProvider.createLanguageModel(for: defaultModel) else {
            return nil
        }
        let session: LanguageModelSession
        let tools = ModelToolNameSanitizer.sanitizeTools(modelProvider.tools).tools
        if let instructions = modelProvider.systemInstructions {
            session = LanguageModelSession(model: languageModel, tools: tools, instructions: instructions)
        } else {
            session = LanguageModelSession(model: languageModel, tools: tools)
        }
        let options = modelProvider.generationOptions(for: defaultModel, maxTokens: maxTokens, reasoningEffort: nil)
        return try? await session.respond(to: prompt.promptRepresentation, options: options).content
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

    /// Generates visor bulletin for runtime health monitoring.
    public func generateVisorBulletin(taskSummary: String? = nil) async -> MemoryBulletin {
        let channelSnapshots = await channels.snapshots()
        let workerSnapshots = await workers.snapshots()
        return await visor.generateBulletin(
            channels: channelSnapshots,
            workers: workerSnapshots,
            taskSummary: taskSummary
        )
    }

    /// Returns collected bulletins.
    public func bulletins() async -> [MemoryBulletin] {
        await visor.listBulletins()
    }

    /// Returns current worker snapshots.
    public func workerSnapshots() async -> [WorkerSnapshot] {
        await workers.snapshots()
    }

    /// Returns active branch snapshots.
    public func activeBranchSnapshots() async -> [BranchSnapshot] {
        await branches.activeBranches()
    }

    /// Starts the Visor supervision tick loop with config-driven parameters.
    public func startVisorSupervision(
        tickIntervalSeconds: Int,
        workerTimeoutSeconds: Int,
        branchTimeoutSeconds: Int,
        maintenanceIntervalSeconds: Int,
        decayRatePerDay: Double,
        pruneImportanceThreshold: Double,
        pruneMinAgeDays: Int,
        channelDegradedFailureCount: Int = 3,
        channelDegradedWindowSeconds: Int = 600,
        idleThresholdSeconds: Int = 1800,
        mergeEnabled: Bool = false,
        mergeSimilarityThreshold: Double = 0.80,
        mergeMaxPerRun: Int = 10
    ) async {
        await visor.startSupervision(
            tickInterval: .seconds(max(1, tickIntervalSeconds)),
            workerTimeoutSeconds: workerTimeoutSeconds,
            branchTimeoutSeconds: branchTimeoutSeconds,
            maintenanceIntervalSeconds: maintenanceIntervalSeconds,
            decayRatePerDay: decayRatePerDay,
            pruneImportanceThreshold: pruneImportanceThreshold,
            pruneMinAgeDays: pruneMinAgeDays,
            channelDegradedFailureCount: channelDegradedFailureCount,
            channelDegradedWindowSeconds: channelDegradedWindowSeconds,
            idleThresholdSeconds: idleThresholdSeconds,
            mergeEnabled: mergeEnabled,
            mergeSimilarityThreshold: mergeSimilarityThreshold,
            mergeMaxPerRun: mergeMaxPerRun,
            snapshotProvider: { [weak self] in
                guard let self else { return ([], []) }
                return await (self.channels.snapshots(), self.workers.snapshots())
            },
            branchProvider: { [weak self] in
                guard let self else { return [] }
                return await self.branches.activeBranches()
            },
            branchForceTimeout: { [weak self] branchId in
                await self?.branches.forceTimeout(branchId: branchId)
            }
        )
    }

    /// Stops the Visor supervision tick loop.
    public func stopVisorSupervision() async {
        await visor.stopSupervision()
    }

    /// Returns true after Visor has completed its first supervision tick.
    public func isVisorReady() async -> Bool {
        await visor.isReady
    }

    /// Asks Visor a question and returns an LLM-synthesized answer from current context.
    public func askVisor(question: String) async -> String {
        let channels = await channels.snapshots()
        let workers = await workers.snapshots()
        return await visor.answer(question: question, channels: channels, workers: workers)
    }

    /// Asks Visor a question and streams the answer as text delta chunks.
    public func streamVisorAnswer(question: String) async -> AsyncStream<String> {
        let channels = await channels.snapshots()
        let workers = await workers.snapshots()
        return await visor.streamAnswer(question: question, channels: channels, workers: workers)
    }

    /// Cancels all active workers on a channel and emits abort event.
    public func abortChannel(channelId: String, reason: String? = nil) async -> Int {
        guard let snapshot = await channels.snapshot(channelId: channelId) else {
            return 0
        }
        var cancelledResponses = 0
        if let activeResponse = activeResponseTasks.removeValue(forKey: channelId) {
            activeResponse.task.cancel()
            sessionsByChannel.removeValue(forKey: channelId)
            cancelledResponses = 1
        }

        var cancelledWorkers = 0
        for workerId in snapshot.activeWorkerIds {
            let ok = await workers.cancel(workerId: workerId, reason: reason)
            if ok {
                await channels.detachWorker(channelId: channelId, workerId: workerId)
                cancelledWorkers += 1
            }
        }
        if cancelledWorkers > 0 {
            await channels.appendSystemMessage(
                channelId: channelId,
                content: "Channel processing aborted. \(cancelledWorkers) worker(s) cancelled."
            )
        }
        return cancelledResponses + cancelledWorkers
    }

    /// Returns memory entries tracked by runtime memory store.
    public func memoryEntries() async -> [MemoryEntry] {
        await memoryStore.entries()
    }

    /// Returns bootstrap prompt content for the given channel, if available.
    public func channelBootstrapContent(channelId: String) async -> String? {
        bootstrapByChannel[channelId]
    }

    /// Returns snapshots for all channels currently tracked by the runtime.
    public func activeChannelSnapshots() async -> [ChannelSnapshot] {
        await channels.snapshots()
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

struct StreamIdleTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "Model stream idle timeout" }
}

actor StreamActivityTracker {
    private var lastActivityAt: Date = Date()
    private var activeToolCalls: Int = 0
    private(set) var latestContent: String = ""
    private(set) var chunks: Int = 0
    private(set) var wasCancelledByConsumer: Bool = false
    private(set) var sawToolTimeout: Bool = false

    func touch() {
        lastActivityAt = Date()
    }

    func touchChunk() {
        lastActivityAt = Date()
        chunks += 1
    }

    func update(content: String) {
        latestContent = content
    }

    func markCancelledByConsumer() {
        wasCancelledByConsumer = true
    }

    func toolStarted() {
        activeToolCalls += 1
        lastActivityAt = Date()
    }

    func toolFinished(result: ToolInvocationResult) {
        if Self.isToolTimeout(result) {
            sawToolTimeout = true
        }
        activeToolCalls = max(0, activeToolCalls - 1)
        lastActivityAt = Date()
    }

    func toolFinished() {
        activeToolCalls = max(0, activeToolCalls - 1)
        lastActivityAt = Date()
    }

    private nonisolated static func isToolTimeout(_ result: ToolInvocationResult) -> Bool {
        guard let error = result.error else {
            return false
        }
        let code = error.code.lowercased()
        let message = error.message.lowercased()
        return code.contains("timeout") || message.contains("timed out")
    }

    var hasActiveTools: Bool {
        activeToolCalls > 0
    }

    func isIdle(thresholdSeconds: Int) -> Bool {
        Date().timeIntervalSince(lastActivityAt) >= Double(thresholdSeconds)
    }

    func shouldTriggerIdleTimeout(thresholdSeconds: Int) -> Bool {
        activeToolCalls == 0 && Date().timeIntervalSince(lastActivityAt) >= Double(thresholdSeconds)
    }
}

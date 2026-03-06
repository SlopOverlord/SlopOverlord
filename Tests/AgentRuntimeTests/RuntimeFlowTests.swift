import Foundation
import Testing
@testable import AgentRuntime
@testable import PluginSDK
@testable import Protocols

@Test
func routingDecisionForWorkerIntent() async {
    let system = RuntimeSystem()

    let decision = await system.postMessage(
        channelId: "general",
        request: ChannelMessageRequest(userId: "u1", content: "please implement and run tests")
    )

    #expect(decision.action == .spawnWorker)
}

@Test
func interactiveWorkerRouteCompletion() async {
    let system = RuntimeSystem()
    let spec = WorkerTaskSpec(
        taskId: "task-route",
        channelId: "general",
        title: "Interactive",
        objective: "wait for route",
        tools: ["shell"],
        mode: .interactive
    )

    let workerId = await system.createWorker(spec: spec)
    let accepted = await system.routeMessage(channelId: "general", workerId: workerId, message: "done")
    #expect(accepted)
}

@Test
func compactorThresholdsProduceEvents() async {
    let bus = EventBus()
    let compactor = Compactor(eventBus: bus)

    let job1 = await compactor.evaluate(channelId: "c1", utilization: 0.81)
    #expect(job1?.level == .soft)

    let job2 = await compactor.evaluate(channelId: "c1", utilization: 0.90)
    #expect(job2?.level == .aggressive)

    let job3 = await compactor.evaluate(channelId: "c1", utilization: 0.97)
    #expect(job3?.level == .emergency)
}

@Test
func compactorDeduplicatesInFlightJobsByChannelAndLevel() async {
    let bus = EventBus()
    let workers = WorkerRuntime(eventBus: bus)
    let applier = BlockingCompactionApplier()
    let compactor = Compactor(
        eventBus: bus,
        applier: { job, _ in
            await applier.execute(job: job)
        },
        sleepOperation: { _ in }
    )

    let job = CompactionJob(channelId: "c1", level: .aggressive, threshold: 0.85)
    await compactor.apply(job: job, workers: workers)
    await applier.waitUntilFirstAttemptIsBlocked()

    await compactor.apply(job: job, workers: workers)
    await applier.releaseFirstAttempt()

    let summaryEvent = await firstEvent(
        matching: .compactorSummaryApplied,
        in: await bus.subscribe()
    )

    #expect(summaryEvent != nil)
    #expect(await applier.attempts(for: .aggressive) == 1)
}

@Test
func compactorRetriesWithBackoffUntilSuccess() async {
    let bus = EventBus()
    let workers = WorkerRuntime(eventBus: bus)
    let applier = FlakyCompactionApplier(failuresBeforeSuccess: 2)
    let sleepRecorder = SleepRecorder()
    let retryPolicy = CompactorRetryPolicy(
        maxAttempts: 3,
        initialBackoffNanoseconds: 10_000,
        multiplier: 2.0,
        maxBackoffNanoseconds: 20_000
    )
    let compactor = Compactor(
        eventBus: bus,
        retryPolicy: retryPolicy,
        applier: { job, _ in
            await applier.execute(job: job)
        },
        sleepOperation: { duration in
            await sleepRecorder.record(duration)
        }
    )

    await compactor.apply(
        job: CompactionJob(channelId: "c1", level: .emergency, threshold: 0.95),
        workers: workers
    )

    let summaryEvent = await firstEvent(
        matching: .compactorSummaryApplied,
        in: await bus.subscribe()
    )

    #expect(summaryEvent != nil)
    #expect(await applier.attemptCount() == 3)
    #expect(await sleepRecorder.values() == [10_000, 20_000])
}

@Test
func branchIsEphemeralAfterConclusion() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)

    let branchId = await branchRuntime.spawn(channelId: "general", prompt: "research topic")
    let countBefore = await branchRuntime.activeBranchesCount()
    #expect(countBefore == 1)

    _ = await branchRuntime.conclude(
        branchId: branchId,
        summary: "final summary",
        artifactRefs: [],
        tokenUsage: TokenUsage(prompt: 20, completion: 10)
    )

    let countAfter = await branchRuntime.activeBranchesCount()
    #expect(countAfter == 0)
}

@Test
func validBranchConclusionPublishesConclusionEvent() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)
    let stream = await bus.subscribe()

    let branchId = await branchRuntime.spawn(channelId: "general", prompt: "research topic")
    let expectedSummary = "final summary"
    let expectedUsage = TokenUsage(prompt: 20, completion: 10)
    let conclusion = await branchRuntime.conclude(
        branchId: branchId,
        summary: expectedSummary,
        artifactRefs: [ArtifactRef(id: "art-1", kind: "text", preview: "artifact preview")],
        tokenUsage: expectedUsage
    )

    #expect(conclusion != nil)
    let event = await firstEvent(matching: .branchConclusion, in: stream)
    #expect(event?.branchId == branchId)
    let decoded = event.flatMap { try? JSONValueCoder.decode(BranchConclusion.self, from: $0.payload) }
    #expect(decoded?.summary == expectedSummary)
    #expect(decoded?.tokenUsage == expectedUsage)
}

@Test
func invalidBranchConclusionEmitsFailureEvent() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)
    let stream = await bus.subscribe()

    let branchId = await branchRuntime.spawn(channelId: "general", prompt: "research topic")
    let conclusion = await branchRuntime.conclude(
        branchId: branchId,
        summary: "   ",
        artifactRefs: [ArtifactRef(id: "art-dup", kind: "text", preview: "a"), ArtifactRef(id: "art-dup", kind: "text", preview: "b")],
        tokenUsage: TokenUsage(prompt: -1, completion: 10)
    )

    #expect(conclusion == nil)

    let events = await collectEvents(in: stream)
    let failure = events.first(where: { $0.messageType == .workerFailed && $0.branchId == branchId })
    #expect(failure != nil)
    #expect(failure?.payload.objectValue["code"]?.stringValue == "empty_summary")
    #expect(!events.contains(where: { $0.messageType == .branchConclusion && $0.branchId == branchId }))
}

@Test
func visorCreatesBulletin() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let bulletin = await visor.generateBulletin(channels: [], workers: [])
    #expect(!bulletin.digest.isEmpty)

    let entries = await memory.entries()
    #expect(entries.count == 1)
}

private actor ToolInvocationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor SequencedModelProvider: ModelProviderPlugin {
    let id: String = "sequenced"
    let models: [String] = ["mock-model"]
    private var queue: [String]
    private(set) var requestedModels: [String] = []
    private(set) var requestedReasoningEfforts: [ReasoningEffort?] = []

    init(outputs: [String]) {
        self.queue = outputs
    }

    func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) async throws -> String {
        requestedModels.append(model)
        requestedReasoningEfforts.append(reasoningEffort)
        if queue.isEmpty {
            return "No output."
        }
        return queue.removeFirst()
    }

    func requestedModelsSnapshot() -> [String] {
        requestedModels
    }

    func requestedReasoningEffortsSnapshot() -> [ReasoningEffort?] {
        requestedReasoningEfforts
    }
}

private actor PromptCapturingStore {
    private(set) var prompts: [String] = []
    private(set) var requestedModels: [String] = []
    private(set) var requestedReasoningEfforts: [ReasoningEffort?] = []

    func record(model: String, prompt: String, reasoningEffort: ReasoningEffort?) {
        prompts.append(prompt)
        requestedModels.append(model)
        requestedReasoningEfforts.append(reasoningEffort)
    }

    func lastPrompt() -> String? {
        prompts.last
    }

    func requestedModelsSnapshot() -> [String] {
        requestedModels
    }

    func requestedReasoningEffortsSnapshot() -> [ReasoningEffort?] {
        requestedReasoningEfforts
    }
}

private final class PromptCapturingModelProvider: ModelProviderPlugin, @unchecked Sendable {
    let id: String = "prompt-capturing"
    let models: [String]
    private let streamOutput: String?
    private let store = PromptCapturingStore()

    init(models: [String] = ["mock-model"], streamOutput: String? = nil) {
        self.models = models
        self.streamOutput = streamOutput
    }

    func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) async throws -> String {
        await store.record(model: model, prompt: prompt, reasoningEffort: reasoningEffort)
        return "Captured."
    }

    func stream(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) -> AsyncThrowingStream<String, any Error> {
        let streamOutput = self.streamOutput
        return AsyncThrowingStream { continuation in
            let task = Task {
                await store.record(model: model, prompt: prompt, reasoningEffort: reasoningEffort)
                if let streamOutput {
                    continuation.yield(streamOutput)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func lastPrompt() async -> String? {
        await store.lastPrompt()
    }

    func requestedModelsSnapshot() async -> [String] {
        await store.requestedModelsSnapshot()
    }

    func requestedReasoningEffortsSnapshot() async -> [ReasoningEffort?] {
        await store.requestedReasoningEffortsSnapshot()
    }
}

@Test
func respondInlineAutoToolCallingLoop() async {
    let provider = SequencedModelProvider(
        outputs: [
            "{\"tool\":\"agents.list\",\"arguments\":{},\"reason\":\"need agents\"}",
            "Final answer after tool execution."
        ]
    )
    let invocationCounter = ToolInvocationCounter()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    let decision = await system.postMessage(
        channelId: "tool-loop",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        toolInvoker: { request in
            await invocationCounter.increment()
            #expect(request.tool == "agents.list")
            return ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .array([])
            )
        }
    )

    #expect(decision.action == .respond)
    let snapshot = await system.channelState(channelId: "tool-loop")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Final answer after tool execution.")
    #expect(await invocationCounter.value() == 1)
    #expect(await provider.requestedModelsSnapshot() == ["mock-model", "mock-model"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [nil, nil])
}

@Test
func respondInlineIncludesBootstrapContextInPrompt() async {
    let provider = PromptCapturingModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let channelId = "session-bootstrap"

    await system.appendSystemMessage(
        channelId: channelId,
        content: """
        [agent_session_context_bootstrap_v1]
        [Identity.md]
        Тебя зовут Серега
        """
    )

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "привет, как тебя зовут?")
    )

    let prompt = await provider.lastPrompt() ?? ""
    #expect(prompt.contains("[agent_session_context_bootstrap_v1]"))
    #expect(prompt.contains("Тебя зовут Серега"))
    #expect(prompt.contains("привет, как тебя зовут?"))
}

@Test
func respondInlineUsesRequestModelInsteadOfDefaultModel() async {
    let provider = PromptCapturingModelProvider(models: ["default-model", "reasoning-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "default-model")

    _ = await system.postMessage(
        channelId: "request-model",
        request: ChannelMessageRequest(
            userId: "dashboard",
            content: "use the request model",
            model: "reasoning-model"
        )
    )

    #expect(await provider.requestedModelsSnapshot().last == "reasoning-model")
}

@Test
func respondInlineForwardsReasoningEffortToStreamingRequests() async {
    let provider = PromptCapturingModelProvider(models: ["reasoning-model"], streamOutput: "Streamed.")
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "reasoning-model")

    _ = await system.postMessage(
        channelId: "stream-reasoning",
        request: ChannelMessageRequest(
            userId: "dashboard",
            content: "stream with effort",
            model: "reasoning-model",
            reasoningEffort: .high
        )
    )

    #expect(await provider.requestedReasoningEffortsSnapshot().last == .high)
}

@Test
func respondInlineForwardsReasoningEffortToFallbackCompletion() async {
    let provider = PromptCapturingModelProvider(models: ["reasoning-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "reasoning-model")

    _ = await system.postMessage(
        channelId: "fallback-reasoning",
        request: ChannelMessageRequest(
            userId: "dashboard",
            content: "fallback with effort",
            model: "reasoning-model",
            reasoningEffort: .low
        )
    )

    #expect(await provider.requestedReasoningEffortsSnapshot().last == .low)
}

@Test
func respondInlineReusesRequestModelAndReasoningEffortAcrossToolLoop() async {
    let provider = SequencedModelProvider(
        outputs: [
            "{\"tool\":\"agents.list\",\"arguments\":{},\"reason\":\"need agents\"}",
            "Final answer after tool execution."
        ]
    )
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "fallback-model")

    _ = await system.postMessage(
        channelId: "tool-loop-request-model",
        request: ChannelMessageRequest(
            userId: "u1",
            content: "hello",
            model: "mock-model",
            reasoningEffort: .medium
        ),
        toolInvoker: { request in
            ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .array([])
            )
        }
    )

    #expect(await provider.requestedModelsSnapshot() == ["mock-model", "mock-model"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [.medium, .medium])
}

@Test
func appendSystemMessagePublishesChannelMessageEvent() async {
    let system = RuntimeSystem()
    let stream = await system.eventBus.subscribe()

    await system.appendSystemMessage(
        channelId: "recovery-channel",
        content: "Recovered bootstrap context"
    )

    let event = await firstEvent(matching: .channelMessageReceived, in: stream)
    #expect(event?.channelId == "recovery-channel")
    #expect(event?.payload.objectValue["userId"]?.stringValue == "system")
    #expect(event?.payload.objectValue["message"]?.stringValue == "Recovered bootstrap context")
}

private actor BlockingCompactionApplier {
    private var attemptsByLevel: [String: Int] = [:]
    private var isFirstAttemptBlocked = false
    private var firstAttemptReadyContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func execute(job: CompactionJob) async -> CompactionJobExecutionResult {
        attemptsByLevel[job.level.rawValue, default: 0] += 1

        if !isFirstAttemptBlocked {
            isFirstAttemptBlocked = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                firstAttemptReadyContinuation?.resume()
                firstAttemptReadyContinuation = nil
            }
        }

        return CompactionJobExecutionResult(success: true, workerId: "compaction-worker-blocking")
    }

    func waitUntilFirstAttemptIsBlocked() async {
        if isFirstAttemptBlocked, releaseContinuation != nil {
            return
        }

        await withCheckedContinuation { continuation in
            firstAttemptReadyContinuation = continuation
        }
    }

    func releaseFirstAttempt() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func attempts(for level: CompactionLevel) -> Int {
        attemptsByLevel[level.rawValue, default: 0]
    }
}

private actor FlakyCompactionApplier {
    private var failuresBeforeSuccess: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func execute(job _: CompactionJob) -> CompactionJobExecutionResult {
        attempts += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            return CompactionJobExecutionResult(success: false, workerId: "compaction-worker-flaky")
        }

        return CompactionJobExecutionResult(success: true, workerId: "compaction-worker-flaky")
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor SleepRecorder {
    private var recorded: [UInt64] = []

    func record(_ nanoseconds: UInt64) {
        recorded.append(nanoseconds)
    }

    func values() -> [UInt64] {
        recorded
    }
}

private actor EventCollector {
    private var events: [EventEnvelope] = []

    func append(_ event: EventEnvelope) {
        events.append(event)
    }

    func all() -> [EventEnvelope] {
        events
    }
}

private func firstEvent(
    matching type: MessageType,
    in stream: AsyncStream<EventEnvelope>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> EventEnvelope? {
    await withTaskGroup(of: EventEnvelope?.self) { group in
        group.addTask {
            for await event in stream {
                if event.messageType == type {
                    return event
                }
            }
            return nil
        }

        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return nil
        }

        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}

private func collectEvents(
    in stream: AsyncStream<EventEnvelope>,
    timeoutNanoseconds: UInt64 = 250_000_000
) async -> [EventEnvelope] {
    let collector = EventCollector()
    let task = Task {
        for await event in stream {
            await collector.append(event)
        }
    }

    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
    task.cancel()
    return await collector.all()
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

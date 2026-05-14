import AnyLanguageModel
import Foundation
import Testing
@testable import AgentRuntime
@testable import PluginSDK
@testable import Protocols

@Test
func routingDoesNotUseKeywordHeuristicsForBranchingOrWorkers() async {
    let system = RuntimeSystem()

    let decision = await system.postMessage(
        channelId: "general",
        request: ChannelMessageRequest(
            userId: "u1",
            content: "please implement and run tests, oppure analizza l'architettura"
        )
    )

    #expect(decision.action == .respond)
}

@Test
func interactiveWorkerRouteRequiresStructuredCommand() async throws {
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

    let waitingSnapshots = await system.workerSnapshots()
    let waitingSnapshot = waitingSnapshots.first(where: { $0.workerId == workerId })
    #expect(waitingSnapshot?.status == .waitingInput)

    let completion = WorkerRouteCommand(command: .complete, summary: "Worker finished", error: nil, report: nil)
    let completionMessage = String(decoding: try JSONEncoder().encode(completion), as: UTF8.self)
    let completed = await system.routeMessage(channelId: "general", workerId: workerId, message: completionMessage)
    #expect(completed)

    let completedSnapshots = await system.workerSnapshots()
    let completedSnapshot = completedSnapshots.first(where: { $0.workerId == workerId })
    #expect(completedSnapshot?.status == .completed)
    #expect(completedSnapshot?.latestReport == "Worker finished")
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
    #expect(entries.isEmpty)
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

// MARK: - Shared mock infrastructure

private final class MockCallStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _models: [String] = []
    private var _reasoningEfforts: [ReasoningEffort?] = []
    private var _prompts: [String] = []
    private var _instructions: [String] = []

    func recordModel(_ model: String) { lock.withLock { _models.append(model) } }
    func recordEffort(_ effort: ReasoningEffort?) { lock.withLock { _reasoningEfforts.append(effort) } }
    func recordPrompt(_ prompt: String) { lock.withLock { _prompts.append(prompt) } }
    func recordInstructions(_ instructions: String?) { lock.withLock { _instructions.append(instructions ?? "") } }

    var models: [String] { lock.withLock { _models } }
    var reasoningEfforts: [ReasoningEffort?] { lock.withLock { _reasoningEfforts } }
    var lastPrompt: String? { lock.withLock { _prompts.last } }
    var allPrompts: [String] { lock.withLock { _prompts } }
    var allInstructions: [String] { lock.withLock { _instructions } }
}

private func extractPromptText(from prompt: Prompt) -> String {
    prompt.description
}

private func extractToolName(from text: String) -> String? {
    func tryParse(_ candidate: String) -> String? {
        guard let data = candidate.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = json["tool"] as? String
        else { return nil }
        return tool
    }

    if let tool = tryParse(text) { return tool }

    var depth = 0
    var start: String.Index?
    for i in text.indices {
        switch text[i] {
        case "{":
            if depth == 0 { start = i }
            depth += 1
        case "}":
            depth -= 1
            if depth == 0, let s = start {
                if let tool = tryParse(String(text[s...i])) { return tool }
                start = nil
            }
        default: break
        }
    }
    return nil
}

// MARK: - SequencedModelProvider

private struct SequencedMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let provider: SequencedModelProvider

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("SequencedMockLanguageModel: only String supported") }

        let firstOutput = await provider.dequeue()
        var entries: [Transcript.Entry] = []

        if let toolName = extractToolName(from: firstOutput), let delegate = session.toolExecutionDelegate {
            let toolCall = Transcript.ToolCall(id: UUID().uuidString, toolName: toolName, arguments: GeneratedContent(""))
            await delegate.didGenerateToolCalls([toolCall], in: session)
            let decision = await delegate.toolCallDecision(for: toolCall, in: session)
            if case .provideOutput(let segments) = decision {
                let output = Transcript.ToolOutput(id: toolCall.id, toolName: toolCall.toolName, segments: segments)
                await delegate.didExecuteToolCall(toolCall, output: output, in: session)
                entries.append(.toolCalls(Transcript.ToolCalls([toolCall])))
                entries.append(.toolOutput(output))
            }
            let finalOutput = await provider.dequeue()
            return LanguageModelSession.Response(
                content: finalOutput as! Content,
                rawContent: GeneratedContent(finalOutput),
                transcriptEntries: ArraySlice(entries)
            )
        }

        return LanguageModelSession.Response(
            content: firstOutput as! Content,
            rawContent: GeneratedContent(firstOutput),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                do {
                    let response = try await respond(
                        within: session, to: prompt, generating: type,
                        includeSchemaInPrompt: includeSchemaInPrompt, options: options
                    )
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor SequencedModelProvider: ModelProvider {
    let id: String = "sequenced"
    nonisolated var supportedModels: [String] { ["mock-model"] }
    nonisolated let callStore = MockCallStore()
    private var queue: [String]

    init(outputs: [String]) {
        self.queue = outputs
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return SequencedMockLanguageModel(provider: self)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func dequeue() -> String {
        queue.isEmpty ? "No output." : queue.removeFirst()
    }

    func requestedModelsSnapshot() -> [String] { callStore.models }
    func requestedReasoningEffortsSnapshot() -> [ReasoningEffort?] { callStore.reasoningEfforts }
}

// MARK: - FailingModelProvider

private enum FailingModelError: Error, CustomStringConvertible {
    case providerUnavailable

    var description: String {
        "provider unavailable"
    }
}

private struct FailingMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        throw FailingModelError.providerUnavailable
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        LanguageModelSession.ResponseStream(stream: AsyncThrowingStream { continuation in
            continuation.finish(throwing: FailingModelError.providerUnavailable)
        })
    }
}

private actor FailingModelProvider: ModelProvider {
    let id: String = "failing"
    nonisolated var supportedModels: [String] { ["mock-model"] }
    nonisolated let callStore = MockCallStore()

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return FailingMockLanguageModel()
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func requestedModelsSnapshot() -> [String] { callStore.models }
}

// MARK: - PromptCapturingModelProvider

private struct PromptCapturingMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let callStore: MockCallStore
    let streamOutput: String?

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("PromptCapturingMockLanguageModel: only String supported") }
        callStore.recordInstructions(session.instructions?.description)
        callStore.recordPrompt(extractPromptText(from: prompt))
        return LanguageModelSession.Response(
            content: "Captured." as! Content,
            rawContent: GeneratedContent("Captured."),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        guard type == String.self else { fatalError("PromptCapturingMockLanguageModel: only String supported") }
        guard let output = streamOutput else {
            return LanguageModelSession.ResponseStream(stream: AsyncThrowingStream { $0.finish() })
        }
        let store = callStore
        let instructions = session.instructions?.description
        let text = extractPromptText(from: prompt)
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                store.recordInstructions(instructions)
                store.recordPrompt(text)
                continuation.yield(.init(content: output as! Content.PartiallyGenerated, rawContent: GeneratedContent(output)))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private final class PromptCapturingModelProvider: ModelProvider, @unchecked Sendable {
    let id: String = "prompt-capturing"
    let supportedModels: [String]
    private let streamOutput: String?
    let callStore = MockCallStore()

    init(models: [String] = ["mock-model"], streamOutput: String? = nil) {
        self.supportedModels = models
        self.streamOutput = streamOutput
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callStore.recordModel(modelName)
        return PromptCapturingMockLanguageModel(callStore: callStore, streamOutput: streamOutput)
    }

    func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        callStore.recordEffort(reasoningEffort)
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func lastPrompt() async -> String? { callStore.lastPrompt }
    func allPrompts() async -> [String] { callStore.allPrompts }
    func allInstructions() async -> [String] { callStore.allInstructions }
    func requestedModelsSnapshot() async -> [String] { callStore.models }
    func requestedReasoningEffortsSnapshot() async -> [ReasoningEffort?] { callStore.reasoningEfforts }
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
    #expect(await provider.requestedModelsSnapshot() == ["mock-model"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [nil])
}

@Test
func respondInlineParsesToolCallEmbeddedInAssistantText() async {
    let provider = SequencedModelProvider(
        outputs: [
            """
            Initial inspection hit a tool failure, so I need a recovery step.

            {"tool":"agents.list","arguments":{},"reason":"recover after previous tool failure"}
            """,
            "Final answer after recovery tool execution."
        ]
    )
    let invocationCounter = ToolInvocationCounter()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    let decision = await system.postMessage(
        channelId: "tool-loop-inline-json",
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
    let snapshot = await system.channelState(channelId: "tool-loop-inline-json")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Final answer after recovery tool execution.")
    #expect(await invocationCounter.value() == 1)
}

@Test
func respondInlineRecreatesSessionWhenRequestedModelChanges() async {
    let provider = SequencedModelProvider(outputs: ["First", "Second"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-a")
    let channelId = "model-switch"

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "u1", content: "hello", model: "mock-a")
    )
    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "u1", content: "hello again", model: "mock-b")
    )

    #expect(await provider.requestedModelsSnapshot() == ["mock-a", "mock-b"])
}

@Test
func respondInlineIncludesBootstrapContextInPrompt() async {
    let provider = PromptCapturingModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let channelId = "session-bootstrap"

    let bootstrapContent = """
    [agent_session_context_bootstrap_v1]
    [IDENTITY.md]
    Тебя зовут Серега
    """
    await system.setChannelBootstrap(channelId: channelId, content: bootstrapContent)

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "привет, как тебя зовут?")
    )

    let instructions = await provider.allInstructions()
    let prompts = await provider.allPrompts()
    let bootstrapInstructions = instructions.last ?? ""
    let userPrompt = prompts.last ?? ""

    #expect(bootstrapInstructions.contains("[agent_session_context_bootstrap_v1]"))
    #expect(bootstrapInstructions.contains("Тебя зовут Серега"))
    #expect(userPrompt.contains("привет, как тебя зовут?"))
}

@Test
func respondInlineInjectsScopedMemoryForAgentSession() async {
    let provider = PromptCapturingModelProvider()
    let memory = InMemoryMemoryStore()
    let channelId = "agent:test-agent:session:test-session"
    let otherChannelId = "agent:test-agent:session:other-session"
    _ = await memory.save(
        entry: MemoryWriteRequest(
            note: "The project codename is Aurora.",
            summary: "Project codename Aurora",
            kind: .fact,
            memoryClass: .semantic,
            scope: .channel(channelId)
        )
    )
    _ = await memory.save(
        entry: MemoryWriteRequest(
            note: "The project codename is Borealis.",
            summary: "Unrelated session codename Borealis",
            kind: .fact,
            memoryClass: .semantic,
            scope: .channel(otherChannelId)
        )
    )
    let system = RuntimeSystem(
        modelProvider: provider,
        defaultModel: "mock-model",
        memoryStore: memory
    )

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "What is the project codename?")
    )

    let prompt = await provider.lastPrompt() ?? ""
    #expect(prompt.contains("[Recalled scoped memory]"))
    #expect(prompt.contains("Project codename Aurora"))
    #expect(prompt.contains("[Current user message]"))
    #expect(prompt.contains("What is the project codename?"))
    #expect(!prompt.contains("Borealis"))
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
func respondInlineRepairsEmptyStreamAndCompletion() async {
    let provider = SequencedModelProvider(outputs: ["   ", "\n", "Recovered final answer."])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "empty-repair",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let snapshot = await system.channelState(channelId: "empty-repair")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Recovered final answer.")
    #expect(await provider.requestedModelsSnapshot() == ["mock-model", "mock-model"])
}

@Test
func respondInlineFallsBackWhenEmptyRepairAlsoReturnsEmpty() async {
    let provider = SequencedModelProvider(outputs: ["   ", "\n", "\t "])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "empty-repair-fallback",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let snapshot = await system.channelState(channelId: "empty-repair-fallback")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Model returned an empty response. Please try rephrasing or try again.")
    #expect(await provider.requestedModelsSnapshot() == ["mock-model", "mock-model"])
}

@Test
func respondInlineProviderErrorsBypassEmptyRepair() async {
    let provider = FailingModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "provider-error-no-repair",
        request: ChannelMessageRequest(userId: "u1", content: "finish the task")
    )

    let snapshot = await system.channelState(channelId: "provider-error-no-repair")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage.contains("Model provider error:"))
    #expect(finalMessage.contains("providerUnavailable") || finalMessage.contains("provider unavailable"))
    #expect(await provider.requestedModelsSnapshot() == ["mock-model"])
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

    #expect(await provider.requestedModelsSnapshot() == ["mock-model"])
    #expect(await provider.requestedReasoningEffortsSnapshot() == [.medium])
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

private func waitUntil(
    timeoutNanoseconds: UInt64,
    condition: @escaping @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000.0)
    while Date() < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - Persistent session tests

@Test
func persistentSessionReusesLanguageModelAcrossMessages() async {
    let provider = PromptCapturingModelProvider(models: ["mock-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "reuse-channel",
        request: ChannelMessageRequest(userId: "u1", content: "first message")
    )
    _ = await system.postMessage(
        channelId: "reuse-channel",
        request: ChannelMessageRequest(userId: "u1", content: "second message")
    )

    #expect(await provider.requestedModelsSnapshot().count == 1)
}

@Test
func persistentSessionInvalidatedOnModelProviderUpdate() async {
    let provider = PromptCapturingModelProvider(models: ["mock-model"])
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "invalidation-channel",
        request: ChannelMessageRequest(userId: "u1", content: "first message")
    )

    await system.updateModelProvider(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "invalidation-channel",
        request: ChannelMessageRequest(userId: "u1", content: "second message")
    )

    #expect(await provider.requestedModelsSnapshot().count == 2)
}

@Test
func abortChannelCancelsActiveInlineResponseTask() async {
    let provider = CancellableStreamModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let postTask = Task {
        await system.postMessage(
            channelId: "cancel-inline-channel",
            request: ChannelMessageRequest(userId: "u1", content: "please wait")
        )
    }

    await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await provider.hasStarted()
    }
    let cancelled = await system.abortChannel(channelId: "cancel-inline-channel", reason: "test interrupt")
    _ = await postTask.value

    #expect(cancelled == 1)
    let snapshot = await system.channelState(channelId: "cancel-inline-channel")
    #expect(snapshot?.messages.contains(where: { $0.userId == "system" && $0.content == "late response" }) == false)
}

@Test
func persistentSessionContextOverflowCreatesNewSession() async {
    let provider = ContextOverflowModelProvider(recoveryResponse: "Recovered response.")
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    _ = await system.postMessage(
        channelId: "overflow-channel",
        request: ChannelMessageRequest(userId: "u1", content: "hello")
    )

    let snapshot = await system.channelState(channelId: "overflow-channel")
    let lastSystemMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(lastSystemMessage == "Recovered response.")
    #expect(await provider.currentCallCount() == 2)
}

// MARK: - CancellableStreamModelProvider

private actor CancellableStreamState {
    private var started = false

    func markStarted() {
        started = true
    }

    func hasStarted() -> Bool {
        started
    }
}

private actor CancellableStreamModelProvider: ModelProvider {
    let id: String = "cancellable-stream"
    nonisolated let supportedModels: [String] = ["mock-model"]
    private let state = CancellableStreamState()

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        CancellableStreamLanguageModel(state: state)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func hasStarted() async -> Bool {
        await state.hasStarted()
    }
}

private struct CancellableStreamLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let state: CancellableStreamState

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("only String supported") }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return LanguageModelSession.Response(
            content: "late response" as! Content,
            rawContent: GeneratedContent("late response"),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        guard type == String.self else { fatalError("only String supported") }
        let state = state
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            let task = Task {
                await state.markStarted()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    let text = "late response"
                    continuation.yield(.init(content: text as! Content.PartiallyGenerated, rawContent: GeneratedContent(text)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

// MARK: - ContextOverflowModelProvider

private actor ContextOverflowModelProvider: ModelProvider {
    let id: String = "context-overflow"
    nonisolated let supportedModels: [String] = ["mock-model"]
    private var callCount = 0
    private let recoveryResponse: String

    init(recoveryResponse: String) {
        self.recoveryResponse = recoveryResponse
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        callCount += 1
        if callCount == 1 {
            return ContextOverflowLanguageModel()
        }
        return FixedResponseLanguageModel(text: recoveryResponse)
    }

    nonisolated func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func currentCallCount() -> Int { callCount }
}

private struct ContextOverflowLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("only String supported") }
        return LanguageModelSession.Response(
            content: "" as! Content,
            rawContent: GeneratedContent(""),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            continuation.finish(throwing: LanguageModelSession.GenerationError.exceededContextWindowSize(
                LanguageModelSession.GenerationError.Context(debugDescription: "test context overflow")
            ))
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private struct FixedResponseLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let text: String

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else { fatalError("only String supported") }
        return LanguageModelSession.Response(
            content: text as! Content,
            rawContent: GeneratedContent(text),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let output = text
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                continuation.yield(.init(content: output as! Content.PartiallyGenerated, rawContent: GeneratedContent(output)))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

// MARK: - ReasoningContentCapture tests

@Test
func reasoningContentCaptureAppendAndConsume() {
    let capture = ReasoningContentCapture()
    capture.append("Hello")
    capture.append(", world")
    let result = capture.consume()
    #expect(result == "Hello, world")
    let afterConsume = capture.consume()
    #expect(afterConsume.isEmpty)
}

@Test
func reasoningContentCaptureConsumeResetsAccumulator() {
    let capture = ReasoningContentCapture()
    capture.append("first")
    _ = capture.consume()
    capture.append("second")
    #expect(capture.consume() == "second")
}

// MARK: - Reasoning observation emission tests

private final class ReasoningCapturingModelProvider: ModelProvider, @unchecked Sendable {
    let id: String = "reasoning-capturing"
    let supportedModels: [String] = ["mock-reasoning-model"]
    let _capture = ReasoningContentCapture()
    let responseText: String

    init(responseText: String = "Response.", reasoning: String = "") {
        self.responseText = responseText
        if !reasoning.isEmpty {
            _capture.append(reasoning)
        }
    }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        ReasoningCapturingMockLanguageModel(responseText: responseText)
    }

    func reasoningCapture(for modelName: String) -> ReasoningContentCapture? {
        _capture
    }
}

private struct ReasoningCapturingMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let responseText: String

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        LanguageModelSession.Response(
            content: responseText as! Content,
            rawContent: GeneratedContent(responseText),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let text = responseText
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            Task {
                continuation.yield(.init(content: text as! Content.PartiallyGenerated, rawContent: GeneratedContent(text)))
                continuation.finish()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor ThinkingCollector {
    var items: [String] = []
    func append(_ text: String) { items.append(text) }
    func all() -> [String] { items }
}

@Test
func reasoningObservationIsEmittedAfterStream() async {
    let provider = ReasoningCapturingModelProvider(
        responseText: "Here is my answer.",
        reasoning: "I think step by step..."
    )
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-reasoning-model")
    let collector = ThinkingCollector()

    _ = await system.postMessage(
        channelId: "reasoning-channel",
        request: ChannelMessageRequest(userId: "u1", content: "solve this"),
        observationHandler: { observation in
            if case .thinking(let text) = observation {
                await collector.append(text)
            }
        }
    )

    let observed = await collector.all()
    #expect(observed.count == 1)
    #expect(observed.first == "I think step by step...")
}

@Test
func noReasoningObservationWhenCaptureIsEmpty() async {
    let provider = ReasoningCapturingModelProvider(responseText: "Answer.", reasoning: "")
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-reasoning-model")
    let collector = ThinkingCollector()

    _ = await system.postMessage(
        channelId: "no-reasoning-channel",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        observationHandler: { observation in
            if case .thinking(let text) = observation {
                await collector.append(text)
            }
        }
    )

    let observed = await collector.all()
    #expect(observed.isEmpty)
}

// MARK: - OpenAIOAuthModel SSE parsing tests

@Test
func openAIOAuthModelParsesOutputTextDelta() {
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5")
    let line = #"data: {"type":"response.output_text.delta","delta":"Hello"}"#
    let result = model.parseSSEOutputDelta(line)
    #expect(result == "Hello")
}

@Test
func openAIOAuthModelParsesReasoningDelta() {
    let capture = ReasoningContentCapture()
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5", reasoningCapture: capture)
    let line = #"data: {"type":"response.reasoning_summary_text.delta","delta":"Let me think"}"#
    let result = model.parseSSEReasoningDelta(line)
    #expect(result == "Let me think")
}

@Test
func openAIOAuthModelIgnoresUnknownSSEEvents() {
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5")
    let line = #"data: {"type":"response.created","response":{}}"#
    #expect(model.parseSSEOutputDelta(line) == nil)
    #expect(model.parseSSEReasoningDelta(line) == nil)
}

@Test
func openAIOAuthModelParsesResponseCompletedWithUsage() {
    let usageCapture = TokenUsageCapture()
    let model = OpenAIOAuthModel(bearerToken: "token", model: "gpt-5", tokenUsageCapture: usageCapture)
    let line = #"data: {"type":"response.completed","response":{"id":"resp_123","usage":{"input_tokens":150,"output_tokens":42}}}"#
    let result = model.parseSSEResponseCompleted(line)
    #expect(result != nil)
    #expect(result?.responseId == "resp_123")
    #expect(result?.inputTokens == 150)
    #expect(result?.outputTokens == 42)
}

@Test
func tokenUsageCaptureStoresAndConsumes() {
    let capture = TokenUsageCapture()
    #expect(capture.consume() == nil)
    capture.store(promptTokens: 100, completionTokens: 50)
    let result = capture.consume()
    #expect(result?.prompt == 100)
    #expect(result?.completion == 50)
    #expect(capture.consume() == nil)
}

private extension Protocols.JSONValue {
    var objectValue: [String: Protocols.JSONValue] {
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

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

    init(outputs: [String]) {
        self.queue = outputs
    }

    func complete(model: String, prompt: String, maxTokens: Int) async throws -> String {
        if queue.isEmpty {
            return "No output."
        }
        return queue.removeFirst()
    }
}

private actor PromptCapturingModelProvider: ModelProviderPlugin {
    let id: String = "prompt-capturing"
    let models: [String] = ["mock-model"]
    private(set) var prompts: [String] = []

    func complete(model: String, prompt: String, maxTokens: Int) async throws -> String {
        prompts.append(prompt)
        return "Captured."
    }

    func lastPrompt() -> String? {
        prompts.last
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

import Foundation
import Foundation
import Testing
@testable import AgentRuntime
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

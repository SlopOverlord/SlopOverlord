import Foundation
import PluginSDK
import Protocols

public actor RuntimeSystem {
    public nonisolated let eventBus: EventBus

    private let memoryStore: InMemoryMemoryStore
    private let channels: ChannelRuntime
    private let workers: WorkerRuntime
    private let branches: BranchRuntime
    private let compactor: Compactor
    private let visor: Visor
    private var modelProvider: (any ModelProviderPlugin)?
    private var defaultModel: String?

    public init(modelProvider: (any ModelProviderPlugin)? = nil, defaultModel: String? = nil) {
        let bus = EventBus()
        let memory = InMemoryMemoryStore()
        self.eventBus = bus
        self.memoryStore = memory
        self.channels = ChannelRuntime(eventBus: bus)
        self.workers = WorkerRuntime(eventBus: bus)
        self.branches = BranchRuntime(eventBus: bus, memoryStore: memory)
        self.compactor = Compactor(eventBus: bus)
        self.visor = Visor(eventBus: bus, memoryStore: memory)
        self.modelProvider = modelProvider
        self.defaultModel = defaultModel ?? modelProvider?.models.first
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
        onResponseChunk: (@Sendable (String) async -> Bool)? = nil
    ) async -> ChannelRouteDecision {
        let ingest = await channels.ingest(channelId: channelId, request: request)

        switch ingest.decision.action {
        case .respond:
            await respondInline(channelId: channelId, userMessage: request.content, onResponseChunk: onResponseChunk)

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
            await channels.appendSystemMessage(channelId: channelId, content: "Compactor applied \(job.level.rawValue) policy")
        }

        return ingest.decision
    }

    /// Uses configured model provider for direct responses or falls back to static response.
    private func respondInline(
        channelId: String,
        userMessage: String,
        onResponseChunk: (@Sendable (String) async -> Bool)?
    ) async {
        guard let modelProvider, let defaultModel else {
            let fallback = "Responded inline"
            if let onResponseChunk {
                _ = await onResponseChunk(fallback)
            }
            await channels.appendSystemMessage(channelId: channelId, content: fallback)
            return
        }

        do {
            var latest = ""
            let stream = modelProvider.stream(model: defaultModel, prompt: userMessage, maxTokens: 1024)
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
                    model: defaultModel,
                    prompt: userMessage,
                    maxTokens: 1024
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

    /// Creates worker and attaches it to channel tracking.
    public func createWorker(spec: WorkerTaskSpec) async -> String {
        let workerId = await workers.spawn(spec: spec, autoStart: true)
        await channels.attachWorker(channelId: spec.channelId, workerId: workerId)
        return workerId
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
    public func generateVisorBulletin() async -> MemoryBulletin {
        let channelSnapshots = await channels.snapshots()
        let workerSnapshots = await workers.snapshots()
        let bulletin = await visor.generateBulletin(
            channels: channelSnapshots,
            workers: workerSnapshots
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

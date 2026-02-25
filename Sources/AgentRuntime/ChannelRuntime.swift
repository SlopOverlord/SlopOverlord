import Foundation
import Protocols

public struct ChannelMessageEntry: Codable, Sendable, Equatable {
    public var id: String
    public var userId: String
    public var content: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, userId: String, content: String, createdAt: Date = Date()) {
        self.id = id
        self.userId = userId
        self.content = content
        self.createdAt = createdAt
    }
}

public struct ChannelSnapshot: Codable, Sendable, Equatable {
    public var channelId: String
    public var messages: [ChannelMessageEntry]
    public var contextUtilization: Double
    public var activeWorkerIds: [String]
    public var lastDecision: ChannelRouteDecision?

    public init(
        channelId: String,
        messages: [ChannelMessageEntry],
        contextUtilization: Double,
        activeWorkerIds: [String],
        lastDecision: ChannelRouteDecision?
    ) {
        self.channelId = channelId
        self.messages = messages
        self.contextUtilization = contextUtilization
        self.activeWorkerIds = activeWorkerIds
        self.lastDecision = lastDecision
    }
}

public struct ChannelIngestResult: Sendable, Equatable {
    public var decision: ChannelRouteDecision
    public var contextUtilization: Double

    public init(decision: ChannelRouteDecision, contextUtilization: Double) {
        self.decision = decision
        self.contextUtilization = contextUtilization
    }
}

private struct ChannelState: Sendable {
    var messages: [ChannelMessageEntry] = []
    var contextUtilization: Double = 0
    var activeWorkerIds: Set<String> = []
    var lastDecision: ChannelRouteDecision?
}

public actor ChannelRuntime {
    private let eventBus: EventBus
    private var channels: [String: ChannelState] = [:]

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Ingests user message into channel state and emits routing decision.
    public func ingest(channelId: String, request: ChannelMessageRequest) async -> ChannelIngestResult {
        var state = channels[channelId, default: ChannelState()]
        let message = ChannelMessageEntry(userId: request.userId, content: request.content)
        state.messages.append(message)
        state.contextUtilization = estimateUtilization(state.messages)

        let decision = decideRoute(for: request.content, utilization: state.contextUtilization)
        state.lastDecision = decision
        channels[channelId] = state

        await publish(channelId: channelId, messageType: .channelMessageReceived, payload: [
            "userId": .string(request.userId),
            "message": .string(request.content)
        ])

        if let payload = try? JSONValueCoder.encode(decision) {
            await publish(channelId: channelId, messageType: .channelRouteDecided, payload: payload.objectValue)
        }

        return ChannelIngestResult(decision: decision, contextUtilization: state.contextUtilization)
    }

    /// Appends a synthetic system message into channel history.
    public func appendSystemMessage(channelId: String, content: String) {
        var state = channels[channelId, default: ChannelState()]
        state.messages.append(ChannelMessageEntry(userId: "system", content: content))
        state.contextUtilization = estimateUtilization(state.messages)
        channels[channelId] = state
    }

    /// Marks worker as active for a channel.
    public func attachWorker(channelId: String, workerId: String) {
        var state = channels[channelId, default: ChannelState()]
        state.activeWorkerIds.insert(workerId)
        channels[channelId] = state
    }

    /// Detaches worker from active channel worker set.
    public func detachWorker(channelId: String, workerId: String) {
        guard var state = channels[channelId] else { return }
        state.activeWorkerIds.remove(workerId)
        channels[channelId] = state
    }

    /// Writes branch conclusion digest into channel history.
    public func applyBranchConclusion(channelId: String, conclusion: BranchConclusion) {
        appendSystemMessage(channelId: channelId, content: "Branch conclusion: \(conclusion.summary)")
    }

    /// Broadcasts visor digest to all known channels.
    public func applyBulletinDigest(_ digest: String) {
        for key in channels.keys {
            appendSystemMessage(channelId: key, content: "[Visor] \(digest)")
        }
    }

    /// Returns single-channel snapshot.
    public func snapshot(channelId: String) -> ChannelSnapshot? {
        guard let state = channels[channelId] else {
            return nil
        }
        return ChannelSnapshot(
            channelId: channelId,
            messages: state.messages,
            contextUtilization: state.contextUtilization,
            activeWorkerIds: Array(state.activeWorkerIds),
            lastDecision: state.lastDecision
        )
    }

    /// Returns snapshots for all active channels.
    public func snapshots() -> [ChannelSnapshot] {
        channels.map { key, state in
            ChannelSnapshot(
                channelId: key,
                messages: state.messages,
                contextUtilization: state.contextUtilization,
                activeWorkerIds: Array(state.activeWorkerIds),
                lastDecision: state.lastDecision
            )
        }
    }

    private func estimateUtilization(_ messages: [ChannelMessageEntry]) -> Double {
        let characters = messages.reduce(0) { $0 + $1.content.count }
        let estimatedTokens = max(1, characters / 4)
        return min(Double(estimatedTokens) / 32_000.0, 1.0)
    }

    private func decideRoute(for message: String, utilization: Double) -> ChannelRouteDecision {
        let lower = message.lowercased()

        if utilization > 0.85 {
            return ChannelRouteDecision(
                action: .spawnBranch,
                reason: "context_over_85_percent",
                confidence: 0.92,
                tokenBudget: 1_500
            )
        }

        let workerKeywords = ["implement", "fix", "run", "build", "execute", "тест", "сделай", "запусти"]
        if workerKeywords.contains(where: lower.contains) {
            return ChannelRouteDecision(
                action: .spawnWorker,
                reason: "matched_worker_intent",
                confidence: 0.86,
                tokenBudget: 3_500
            )
        }

        let branchKeywords = ["analyze", "research", "разбери", "обдумай", "архитектур"]
        if branchKeywords.contains(where: lower.contains) {
            return ChannelRouteDecision(
                action: .spawnBranch,
                reason: "matched_branch_intent",
                confidence: 0.81,
                tokenBudget: 2_000
            )
        }

        return ChannelRouteDecision(
            action: .respond,
            reason: "direct_response",
            confidence: 0.75,
            tokenBudget: 1_000
        )
    }

    private func publish(channelId: String, messageType: MessageType, payload: [String: JSONValue]) async {
        let envelope = EventEnvelope(
            messageType: messageType,
            channelId: channelId,
            payload: .object(payload)
        )
        await eventBus.publish(envelope)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let object) = self {
            return object
        }
        return [:]
    }
}

import Foundation

public enum RouteAction: String, Codable, Sendable {
    case respond
    case spawnBranch = "spawn_branch"
    case spawnWorker = "spawn_worker"
}

public struct ChannelRouteDecision: Codable, Sendable, Equatable {
    public var action: RouteAction
    public var reason: String
    public var confidence: Double
    public var tokenBudget: Int

    public init(action: RouteAction, reason: String, confidence: Double, tokenBudget: Int) {
        self.action = action
        self.reason = reason
        self.confidence = confidence
        self.tokenBudget = tokenBudget
    }
}

public struct ArtifactRef: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var preview: String

    public init(id: String, kind: String, preview: String) {
        self.id = id
        self.kind = kind
        self.preview = preview
    }
}

public struct MemoryRef: Codable, Sendable, Equatable {
    public var id: String
    public var score: Double

    public init(id: String, score: Double) {
        self.id = id
        self.score = score
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var prompt: Int
    public var completion: Int

    public init(prompt: Int, completion: Int) {
        self.prompt = prompt
        self.completion = completion
    }

    public var total: Int {
        prompt + completion
    }
}

public struct BranchConclusion: Codable, Sendable, Equatable {
    public var summary: String
    public var artifactRefs: [ArtifactRef]
    public var memoryRefs: [MemoryRef]
    public var tokenUsage: TokenUsage

    public init(summary: String, artifactRefs: [ArtifactRef], memoryRefs: [MemoryRef], tokenUsage: TokenUsage) {
        self.summary = summary
        self.artifactRefs = artifactRefs
        self.memoryRefs = memoryRefs
        self.tokenUsage = tokenUsage
    }
}

public enum WorkerMode: String, Codable, Sendable {
    case fireAndForget = "fire_and_forget"
    case interactive
}

public struct WorkerTaskSpec: Codable, Sendable, Equatable {
    public var taskId: String
    public var channelId: String
    public var title: String
    public var objective: String
    public var tools: [String]
    public var mode: WorkerMode

    public init(taskId: String, channelId: String, title: String, objective: String, tools: [String], mode: WorkerMode) {
        self.taskId = taskId
        self.channelId = channelId
        self.title = title
        self.objective = objective
        self.tools = tools
        self.mode = mode
    }
}

public enum CompactionLevel: String, Codable, Sendable {
    case soft
    case aggressive
    case emergency
}

public struct CompactionJob: Codable, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var level: CompactionLevel
    public var threshold: Double
    public var createdAt: Date

    public init(id: String = UUID().uuidString, channelId: String, level: CompactionLevel, threshold: Double, createdAt: Date = Date()) {
        self.id = id
        self.channelId = channelId
        self.level = level
        self.threshold = threshold
        self.createdAt = createdAt
    }
}

public struct MemoryBulletin: Codable, Sendable, Equatable {
    public var id: String
    public var generatedAt: Date
    public var headline: String
    public var digest: String
    public var items: [String]

    public init(id: String = UUID().uuidString, generatedAt: Date = Date(), headline: String, digest: String, items: [String]) {
        self.id = id
        self.generatedAt = generatedAt
        self.headline = headline
        self.digest = digest
        self.items = items
    }
}

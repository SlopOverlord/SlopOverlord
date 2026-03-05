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
    public var kind: MemoryKind?
    public var memoryClass: MemoryClass?
    public var source: MemorySource?
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case score
        case kind
        case memoryClass = "class"
        case source
        case createdAt
    }

    enum LegacyCodingKeys: String, CodingKey {
        case memoryClass
    }

    public init(
        id: String,
        score: Double,
        kind: MemoryKind? = nil,
        memoryClass: MemoryClass? = nil,
        source: MemorySource? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.score = score
        self.kind = kind
        self.memoryClass = memoryClass
        self.source = source
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        score = try container.decode(Double.self, forKey: .score)
        kind = try container.decodeIfPresent(MemoryKind.self, forKey: .kind)
        if let decodedMemoryClass = try container.decodeIfPresent(MemoryClass.self, forKey: .memoryClass) {
            memoryClass = decodedMemoryClass
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            memoryClass = try legacyContainer.decodeIfPresent(MemoryClass.self, forKey: .memoryClass)
        }

        if let decodedSource = try? container.decode(MemorySource.self, forKey: .source) {
            source = decodedSource
        } else if let legacySource = try? container.decode(String.self, forKey: .source) {
            source = MemorySource(type: legacySource, id: nil)
        } else {
            source = nil
        }

        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(score, forKey: .score)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(memoryClass, forKey: .memoryClass)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
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
    public enum ValidationError: Error, Sendable, Equatable {
        case emptySummary
        case negativePromptTokens
        case negativeCompletionTokens
        case excessivePromptTokens(maxAllowed: Int)
        case excessiveCompletionTokens(maxAllowed: Int)
        case duplicateArtifactRef(id: String)
        case duplicateMemoryRef(id: String)

        public var code: String {
            switch self {
            case .emptySummary:
                return "empty_summary"
            case .negativePromptTokens:
                return "negative_prompt_tokens"
            case .negativeCompletionTokens:
                return "negative_completion_tokens"
            case .excessivePromptTokens:
                return "excessive_prompt_tokens"
            case .excessiveCompletionTokens:
                return "excessive_completion_tokens"
            case .duplicateArtifactRef:
                return "duplicate_artifact_ref"
            case .duplicateMemoryRef:
                return "duplicate_memory_ref"
            }
        }

        public var message: String {
            switch self {
            case .emptySummary:
                return "Branch conclusion summary must not be empty."
            case .negativePromptTokens:
                return "Branch conclusion prompt token usage must be non-negative."
            case .negativeCompletionTokens:
                return "Branch conclusion completion token usage must be non-negative."
            case .excessivePromptTokens(let maxAllowed):
                return "Branch conclusion prompt token usage exceeds sane limit (\(maxAllowed))."
            case .excessiveCompletionTokens(let maxAllowed):
                return "Branch conclusion completion token usage exceeds sane limit (\(maxAllowed))."
            case .duplicateArtifactRef(let id):
                return "Branch conclusion has duplicate artifact ref id '\(id)'."
            case .duplicateMemoryRef(let id):
                return "Branch conclusion has duplicate memory ref id '\(id)'."
            }
        }
    }

    public static let defaultMaxTokenCount: Int = 1_000_000

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

    public func validate(maxTokenCount: Int = Self.defaultMaxTokenCount) throws {
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else {
            throw ValidationError.emptySummary
        }

        guard tokenUsage.prompt >= 0 else {
            throw ValidationError.negativePromptTokens
        }
        guard tokenUsage.completion >= 0 else {
            throw ValidationError.negativeCompletionTokens
        }
        guard tokenUsage.prompt <= maxTokenCount else {
            throw ValidationError.excessivePromptTokens(maxAllowed: maxTokenCount)
        }
        guard tokenUsage.completion <= maxTokenCount else {
            throw ValidationError.excessiveCompletionTokens(maxAllowed: maxTokenCount)
        }

        var artifactIDs = Set<String>()
        for ref in artifactRefs {
            guard artifactIDs.insert(ref.id).inserted else {
                throw ValidationError.duplicateArtifactRef(id: ref.id)
            }
        }

        var memoryIDs = Set<String>()
        for ref in memoryRefs {
            guard memoryIDs.insert(ref.id).inserted else {
                throw ValidationError.duplicateMemoryRef(id: ref.id)
            }
        }
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
    public var memoryRefs: [MemoryRef]
    public var scope: MemoryScope?

    enum CodingKeys: String, CodingKey {
        case id
        case generatedAt
        case headline
        case digest
        case items
        case memoryRefs
        case scope
    }

    public init(
        id: String = UUID().uuidString,
        generatedAt: Date = Date(),
        headline: String,
        digest: String,
        items: [String],
        memoryRefs: [MemoryRef] = [],
        scope: MemoryScope? = nil
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.headline = headline
        self.digest = digest
        self.items = items
        self.memoryRefs = memoryRefs
        self.scope = scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        headline = try container.decode(String.self, forKey: .headline)
        digest = try container.decode(String.self, forKey: .digest)
        items = try container.decode([String].self, forKey: .items)
        memoryRefs = try container.decodeIfPresent([MemoryRef].self, forKey: .memoryRefs) ?? []
        scope = try container.decodeIfPresent(MemoryScope.self, forKey: .scope)
    }
}

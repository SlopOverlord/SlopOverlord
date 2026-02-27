import Foundation

public struct ChannelMessageRequest: Codable, Sendable {
    public var userId: String
    public var content: String

    public init(userId: String, content: String) {
        self.userId = userId
        self.content = content
    }
}

public struct ChannelRouteRequest: Codable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public struct WorkerCreateRequest: Codable, Sendable {
    public var spec: WorkerTaskSpec

    public init(spec: WorkerTaskSpec) {
        self.spec = spec
    }
}

public struct ArtifactContentResponse: Codable, Sendable {
    public var id: String
    public var content: String

    public init(id: String, content: String) {
        self.id = id
        self.content = content
    }
}

public struct AgentCreateRequest: Codable, Sendable {
    public var id: String
    public var displayName: String
    public var role: String

    public init(id: String, displayName: String, role: String) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

public struct AgentSummary: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var role: String
    public var createdAt: Date

    public init(id: String, displayName: String, role: String, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.createdAt = createdAt
    }
}

public enum ProviderAuthMethod: String, Codable, Sendable {
    case apiKey = "api_key"
    case deeplink
}

public struct OpenAIProviderModelsRequest: Codable, Sendable {
    public var authMethod: ProviderAuthMethod
    public var apiKey: String?
    public var apiUrl: String?

    public init(authMethod: ProviderAuthMethod, apiKey: String? = nil, apiUrl: String? = nil) {
        self.authMethod = authMethod
        self.apiKey = apiKey
        self.apiUrl = apiUrl
    }
}

public struct ProviderModelOption: Codable, Sendable, Equatable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct OpenAIProviderModelsResponse: Codable, Sendable {
    public var provider: String
    public var authMethod: ProviderAuthMethod
    public var usedEnvironmentKey: Bool
    public var source: String
    public var warning: String?
    public var models: [ProviderModelOption]

    public init(
        provider: String,
        authMethod: ProviderAuthMethod,
        usedEnvironmentKey: Bool,
        source: String,
        warning: String?,
        models: [ProviderModelOption]
    ) {
        self.provider = provider
        self.authMethod = authMethod
        self.usedEnvironmentKey = usedEnvironmentKey
        self.source = source
        self.warning = warning
        self.models = models
    }
}

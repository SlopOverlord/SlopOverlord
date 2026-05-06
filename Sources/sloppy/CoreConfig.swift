import Foundation

public struct CoreConfig: Codable, Sendable {
    public static let defaultConfigFileName = "sloppy.json"
    public static var defaultConfigPath: String {
        defaultConfigPath(currentDirectory: FileManager.default.currentDirectoryPath)
    }
    public static let defaultWorkspaceName = ".sloppy"
    public static let defaultWorkspaceBasePath = "."
    public static let defaultSQLiteFileName = "memory/core.sqlite"

    public struct ModelConfig: Codable, Sendable, Equatable {
        public var title: String
        public var apiKey: String
        public var apiUrl: String
        public var model: String
        /// When `true`, this row is ignored for inference and routing (Dashboard).
        public var disabled: Bool
        /// Dashboard catalog id (e.g. `openai-api`, `openrouter`) to disambiguate multiple rows of the same kind.
        public var providerCatalogId: String?

        enum CodingKeys: String, CodingKey {
            case title
            case apiKey
            case apiUrl
            case model
            case disabled
            case providerCatalogId
        }

        public init(
            title: String,
            apiKey: String,
            apiUrl: String,
            model: String,
            disabled: Bool = false,
            providerCatalogId: String? = nil
        ) {
            self.title = title
            self.apiKey = apiKey
            self.apiUrl = apiUrl
            self.model = model
            self.disabled = disabled
            self.providerCatalogId = providerCatalogId
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            apiKey = try container.decode(String.self, forKey: .apiKey)
            apiUrl = try container.decode(String.self, forKey: .apiUrl)
            model = try container.decode(String.self, forKey: .model)
            disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            providerCatalogId = try container.decodeIfPresent(String.self, forKey: .providerCatalogId)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(apiKey, forKey: .apiKey)
            try container.encode(apiUrl, forKey: .apiUrl)
            try container.encode(model, forKey: .model)
            try container.encode(disabled, forKey: .disabled)
            try container.encodeIfPresent(providerCatalogId, forKey: .providerCatalogId)
        }
    }

    public struct PluginConfig: Codable, Sendable, Equatable {
        public var title: String
        public var apiKey: String
        public var apiUrl: String
        public var plugin: String

        public init(title: String, apiKey: String, apiUrl: String, plugin: String) {
            self.title = title
            self.apiKey = apiKey
            self.apiUrl = apiUrl
            self.plugin = plugin
        }
    }

    public struct Listen: Codable, Sendable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public struct Workspace: Codable, Sendable {
        public var name: String
        public var basePath: String

        public init(
            name: String = CoreConfig.defaultWorkspaceName,
            basePath: String = CoreConfig.defaultWorkspaceBasePath
        ) {
            self.name = name
            self.basePath = basePath
        }
    }

    public struct Memory: Codable, Sendable, Equatable {
        public struct Provider: Codable, Sendable, Equatable {
            public struct MCPTools: Codable, Sendable, Equatable {
                public var upsert: String
                public var query: String
                public var delete: String
                public var health: String

                public init(
                    upsert: String = "memory_upsert",
                    query: String = "memory_query",
                    delete: String = "memory_delete",
                    health: String = "memory_health"
                ) {
                    self.upsert = upsert
                    self.query = query
                    self.delete = delete
                    self.health = health
                }
            }

            public enum Mode: String, Codable, Sendable, Equatable {
                case local
                case http
                case mcp

                public init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    let rawValue = try container.decode(String.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()

                    switch rawValue {
                    case "local", "builtin", "embedded":
                        self = .local
                    case "http", "remote", "remote_http", "remote-http":
                        self = .http
                    case "mcp", "remote_mcp", "remote-mcp":
                        self = .mcp
                    default:
                        throw DecodingError.dataCorruptedError(
                            in: container,
                            debugDescription: "Unsupported memory provider mode: \(rawValue)"
                        )
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    try container.encode(rawValue)
                }
            }

            public var mode: Mode
            public var endpoint: String?
            public var mcpServer: String?
            public var mcpTools: MCPTools
            public var timeoutMs: Int
            public var apiKeyEnv: String?

            private enum CodingKeys: String, CodingKey {
                case mode
                case endpoint
                case mcpServer
                case mcpTools
                case timeoutMs
                case apiKeyEnv
            }

            public init(
                mode: Mode = .local,
                endpoint: String? = nil,
                mcpServer: String? = nil,
                mcpTools: MCPTools = MCPTools(),
                timeoutMs: Int = 2_500,
                apiKeyEnv: String? = nil
            ) {
                self.mode = mode
                self.endpoint = endpoint
                self.mcpServer = mcpServer
                self.mcpTools = mcpTools
                self.timeoutMs = timeoutMs
                self.apiKeyEnv = apiKeyEnv
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .local
                endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
                mcpServer = try container.decodeIfPresent(String.self, forKey: .mcpServer)
                mcpTools = try container.decodeIfPresent(MCPTools.self, forKey: .mcpTools) ?? .init()
                timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 2_500
                apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv)
            }
        }

        public struct Retrieval: Codable, Sendable, Equatable {
            public var topK: Int
            public var semanticWeight: Double
            public var keywordWeight: Double
            public var graphWeight: Double

            public init(
                topK: Int = 8,
                semanticWeight: Double = 0.55,
                keywordWeight: Double = 0.35,
                graphWeight: Double = 0.10
            ) {
                self.topK = topK
                self.semanticWeight = semanticWeight
                self.keywordWeight = keywordWeight
                self.graphWeight = graphWeight
            }
        }

        public struct Retention: Codable, Sendable, Equatable {
            public var episodicDays: Int
            public var todoCompletedDays: Int
            public var bulletinDays: Int

            public init(
                episodicDays: Int = 90,
                todoCompletedDays: Int = 30,
                bulletinDays: Int = 180
            ) {
                self.episodicDays = episodicDays
                self.todoCompletedDays = todoCompletedDays
                self.bulletinDays = bulletinDays
            }
        }

        public struct Embedding: Codable, Sendable, Equatable {
            /// Whether local embedding is enabled. When false, EmbeddingService is not created.
            public var enabled: Bool
            /// Model identifier for the embeddings endpoint (e.g. "text-embedding-3-small").
            public var model: String
            /// Output vector dimensionality.
            public var dimensions: Int
            /// Full URL to the embeddings endpoint. Nil = derive from configured model providers.
            public var endpoint: String?
            /// Name of the environment variable holding the API key. Nil = fall back to OPENAI_API_KEY.
            public var apiKeyEnv: String?

            public init(
                enabled: Bool = false,
                model: String = "text-embedding-3-small",
                dimensions: Int = 1536,
                endpoint: String? = nil,
                apiKeyEnv: String? = nil
            ) {
                self.enabled = enabled
                self.model = model
                self.dimensions = dimensions
                self.endpoint = endpoint
                self.apiKeyEnv = apiKeyEnv
            }
        }

        public var backend: String
        public var provider: Provider
        public var retrieval: Retrieval
        public var retention: Retention
        public var embedding: Embedding

        public init(
            backend: String,
            provider: Provider = Provider(),
            retrieval: Retrieval = Retrieval(),
            retention: Retention = Retention(),
            embedding: Embedding = Embedding()
        ) {
            self.backend = backend
            self.provider = provider
            self.retrieval = retrieval
            self.retention = retention
            self.embedding = embedding
        }

        private enum CodingKeys: String, CodingKey {
            case backend
            case provider
            case retrieval
            case retention
            case embedding
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            backend = try container.decode(String.self, forKey: .backend)
            provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? Provider()
            retrieval = try container.decodeIfPresent(Retrieval.self, forKey: .retrieval) ?? Retrieval()
            retention = try container.decodeIfPresent(Retention.self, forKey: .retention) ?? Retention()
            embedding = try container.decodeIfPresent(Embedding.self, forKey: .embedding) ?? Embedding()
        }
    }

    public struct MCP: Codable, Sendable, Equatable {
        public struct Server: Codable, Sendable, Equatable {
            public enum Transport: String, Codable, Sendable, Equatable {
                case stdio
                case http
            }

            public var id: String
            public var transport: Transport
            public var command: String?
            public var arguments: [String]
            public var cwd: String?
            public var endpoint: String?
            public var headers: [String: String]
            public var timeoutMs: Int
            public var enabled: Bool
            public var exposeTools: Bool
            public var exposeResources: Bool
            public var exposePrompts: Bool
            public var toolPrefix: String?

            private enum CodingKeys: String, CodingKey {
                case id
                case transport
                case command
                case arguments
                case cwd
                case endpoint
                case headers
                case timeoutMs
                case enabled
                case exposeTools
                case exposeResources
                case exposePrompts
                case toolPrefix
            }

            public init(
                id: String,
                transport: Transport = .stdio,
                command: String? = nil,
                arguments: [String] = [],
                cwd: String? = nil,
                endpoint: String? = nil,
                headers: [String: String] = [:],
                timeoutMs: Int = 15_000,
                enabled: Bool = true,
                exposeTools: Bool = true,
                exposeResources: Bool = true,
                exposePrompts: Bool = true,
                toolPrefix: String? = nil
            ) {
                self.id = id
                self.transport = transport
                self.command = command
                self.arguments = arguments
                self.cwd = cwd
                self.endpoint = endpoint
                self.headers = headers
                self.timeoutMs = timeoutMs
                self.enabled = enabled
                self.exposeTools = exposeTools
                self.exposeResources = exposeResources
                self.exposePrompts = exposePrompts
                self.toolPrefix = toolPrefix
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                transport = try container.decodeIfPresent(Transport.self, forKey: .transport) ?? .stdio
                command = try container.decodeIfPresent(String.self, forKey: .command)
                arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
                cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
                endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
                headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
                timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 15_000
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
                exposeTools = try container.decodeIfPresent(Bool.self, forKey: .exposeTools) ?? true
                exposeResources = try container.decodeIfPresent(Bool.self, forKey: .exposeResources) ?? true
                exposePrompts = try container.decodeIfPresent(Bool.self, forKey: .exposePrompts) ?? true
                toolPrefix = try container.decodeIfPresent(String.self, forKey: .toolPrefix)
            }
        }

        public var servers: [Server]

        public init(servers: [Server] = []) {
            self.servers = servers
        }
    }

    public struct ACP: Codable, Sendable, Equatable {
        public struct Target: Codable, Sendable, Equatable {
            public enum Transport: String, Codable, Sendable, Equatable {
                case stdio
                case ssh
                case websocket
            }

            public enum PermissionMode: String, Codable, Sendable, Equatable {
                case allowOnce = "allow_once"
                case deny
            }

            public var id: String
            public var title: String
            public var transport: Transport
            public var command: String
            public var arguments: [String]
            public var host: String?
            public var user: String?
            public var port: Int?
            public var identityFile: String?
            public var strictHostKeyChecking: Bool
            public var remoteCommand: String?
            public var url: String?
            public var headers: [String: String]
            public var cwd: String?
            public var environment: [String: String]
            public var timeoutMs: Int
            public var enabled: Bool
            public var permissionMode: PermissionMode

            private enum CodingKeys: String, CodingKey {
                case id
                case title
                case transport
                case command
                case arguments
                case host
                case user
                case port
                case identityFile
                case strictHostKeyChecking
                case remoteCommand
                case url
                case headers
                case cwd
                case environment
                case timeoutMs
                case enabled
                case permissionMode
            }

            public init(
                id: String,
                title: String,
                transport: Transport = .stdio,
                command: String = "",
                arguments: [String] = [],
                host: String? = nil,
                user: String? = nil,
                port: Int? = nil,
                identityFile: String? = nil,
                strictHostKeyChecking: Bool = true,
                remoteCommand: String? = nil,
                url: String? = nil,
                headers: [String: String] = [:],
                cwd: String? = nil,
                environment: [String: String] = [:],
                timeoutMs: Int = 30_000,
                enabled: Bool = true,
                permissionMode: PermissionMode = .allowOnce
            ) {
                self.id = id
                self.title = title
                self.transport = transport
                self.command = command
                self.arguments = arguments
                self.host = host
                self.user = user
                self.port = port
                self.identityFile = identityFile
                self.strictHostKeyChecking = strictHostKeyChecking
                self.remoteCommand = remoteCommand
                self.url = url
                self.headers = headers
                self.cwd = cwd
                self.environment = environment
                self.timeoutMs = timeoutMs
                self.enabled = enabled
                self.permissionMode = permissionMode
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
                transport = try container.decodeIfPresent(Transport.self, forKey: .transport) ?? .stdio
                command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
                arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
                host = try container.decodeIfPresent(String.self, forKey: .host)
                user = try container.decodeIfPresent(String.self, forKey: .user)
                port = try container.decodeIfPresent(Int.self, forKey: .port)
                identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
                strictHostKeyChecking = try container.decodeIfPresent(Bool.self, forKey: .strictHostKeyChecking) ?? true
                remoteCommand = try container.decodeIfPresent(String.self, forKey: .remoteCommand)
                url = try container.decodeIfPresent(String.self, forKey: .url)
                headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
                cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
                environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
                timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 30_000
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
                permissionMode = try container.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .allowOnce
            }
        }

        public var enabled: Bool
        public var targets: [Target]

        public init(enabled: Bool = false, targets: [Target] = []) {
            self.enabled = enabled
            self.targets = targets
        }
    }

    public struct Auth: Codable, Sendable {
        public var token: String

        public init(token: String) {
            self.token = token
        }
    }

    public struct Onboarding: Codable, Sendable, Equatable {
        public var completed: Bool

        public init(completed: Bool = false) {
            self.completed = completed
        }
    }

    public struct GitSync: Codable, Sendable, Equatable {
        public struct Schedule: Codable, Sendable, Equatable {
            public enum Frequency: String, Codable, Sendable, Equatable {
                case manual
                case daily
                case weekdays
            }

            public var frequency: Frequency
            public var time: String

            public init(
                frequency: Frequency = .daily,
                time: String = "18:00"
            ) {
                self.frequency = frequency
                self.time = time
            }
        }

        public enum ConflictStrategy: String, Codable, Sendable, Equatable {
            case remoteWins = "remote_wins"
            case localWins = "local_wins"
            case manual
        }

        public var enabled: Bool
        public var authToken: String
        public var repository: String
        public var branch: String
        public var schedule: Schedule
        public var conflictStrategy: ConflictStrategy

        public init(
            enabled: Bool = false,
            authToken: String = "",
            repository: String = "",
            branch: String = "main",
            schedule: Schedule = Schedule(),
            conflictStrategy: ConflictStrategy = .remoteWins
        ) {
            self.enabled = enabled
            self.authToken = authToken
            self.repository = repository
            self.branch = branch
            self.schedule = schedule
            self.conflictStrategy = conflictStrategy
        }

        private enum CodingKeys: String, CodingKey {
            case enabled
            case authToken
            case repository
            case branch
            case schedule
            case conflictStrategy
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
            repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? ""
            branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? "main"
            schedule = try container.decodeIfPresent(Schedule.self, forKey: .schedule) ?? Schedule()
            conflictStrategy = try container.decodeIfPresent(ConflictStrategy.self, forKey: .conflictStrategy) ?? .remoteWins
        }
    }

    public struct Proxy: Codable, Sendable, Equatable {
        public enum ProxyType: String, Codable, Sendable, Equatable {
            case socks5
            case http
            case https
        }

        public var enabled: Bool
        public var type: ProxyType
        public var host: String
        public var port: Int
        public var username: String
        public var password: String

        public init(
            enabled: Bool = false,
            type: ProxyType = .socks5,
            host: String = "",
            port: Int = 1080,
            username: String = "",
            password: String = ""
        ) {
            self.enabled = enabled
            self.type = type
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }

        private enum CodingKeys: String, CodingKey {
            case enabled
            case type
            case host
            case port
            case username
            case password
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            type = try container.decodeIfPresent(ProxyType.self, forKey: .type) ?? .socks5
            host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
            port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 1080
            username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
            password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        }
    }

    public struct Browser: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var executablePath: String
        public var cdpEndpoint: String
        public var profileName: String
        public var profilePath: String?
        public var headless: Bool
        public var startupTimeoutMs: Int
        public var additionalArguments: [String]

        private enum CodingKeys: String, CodingKey {
            case enabled
            case executablePath
            case cdpEndpoint
            case profileName
            case profilePath
            case headless
            case startupTimeoutMs
            case additionalArguments
        }

        public init(
            enabled: Bool = false,
            executablePath: String = "",
            cdpEndpoint: String = "",
            profileName: String = "default",
            profilePath: String? = nil,
            headless: Bool = false,
            startupTimeoutMs: Int = 10_000,
            additionalArguments: [String] = []
        ) {
            self.enabled = enabled
            self.executablePath = executablePath
            self.cdpEndpoint = cdpEndpoint
            self.profileName = profileName
            self.profilePath = profilePath
            self.headless = headless
            self.startupTimeoutMs = startupTimeoutMs
            self.additionalArguments = additionalArguments
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
            cdpEndpoint = try container.decodeIfPresent(String.self, forKey: .cdpEndpoint) ?? ""
            let decodedProfileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? "default"
            profileName = decodedProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "default"
                : decodedProfileName
            profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath)
            headless = try container.decodeIfPresent(Bool.self, forKey: .headless) ?? false
            startupTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .startupTimeoutMs) ?? 10_000
            additionalArguments = try container.decodeIfPresent([String].self, forKey: .additionalArguments) ?? []
        }
    }

    public struct SearchTools: Codable, Sendable, Equatable {
        public enum ProviderID: String, Codable, Sendable, Equatable {
            case brave
            case perplexity
        }

        public struct Provider: Codable, Sendable, Equatable {
            public var apiKey: String

            public init(apiKey: String = "") {
                self.apiKey = apiKey
            }
        }

        public struct Providers: Codable, Sendable, Equatable {
            public var brave: Provider
            public var perplexity: Provider

            public init(
                brave: Provider = Provider(),
                perplexity: Provider = Provider()
            ) {
                self.brave = brave
                self.perplexity = perplexity
            }

            private enum CodingKeys: String, CodingKey {
                case brave
                case perplexity
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                brave = try container.decodeIfPresent(Provider.self, forKey: .brave) ?? Provider()
                perplexity = try container.decodeIfPresent(Provider.self, forKey: .perplexity) ?? Provider()
            }
        }

        public var activeProvider: ProviderID
        public var providers: Providers

        public init(
            activeProvider: ProviderID = .perplexity,
            providers: Providers = Providers()
        ) {
            self.activeProvider = activeProvider
            self.providers = providers
        }

        private enum CodingKeys: String, CodingKey {
            case activeProvider
            case providers
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            activeProvider = try container.decodeIfPresent(ProviderID.self, forKey: .activeProvider) ?? .perplexity
            providers = try container.decodeIfPresent(Providers.self, forKey: .providers) ?? Providers()
        }
    }

    public struct ChannelConfig: Codable, Sendable, Equatable {
        public struct Discord: Codable, Sendable, Equatable {
            /// Discord bot token.
            public var botToken: String
            /// Maps Sloppy channelId -> Discord channel ID.
            public var channelDiscordChannelMap: [String: String]
            /// When non-empty, only these guild IDs are allowed.
            public var allowedGuildIds: [String]
            /// When non-empty, only these channel IDs are allowed.
            public var allowedChannelIds: [String]
            /// When non-empty, only these Discord user IDs are allowed.
            public var allowedUserIds: [String]

            public init(
                botToken: String,
                channelDiscordChannelMap: [String: String] = [:],
                allowedGuildIds: [String] = [],
                allowedChannelIds: [String] = [],
                allowedUserIds: [String] = []
            ) {
                self.botToken = botToken
                self.channelDiscordChannelMap = channelDiscordChannelMap
                self.allowedGuildIds = allowedGuildIds
                self.allowedChannelIds = allowedChannelIds
                self.allowedUserIds = allowedUserIds
            }
        }

        public struct Telegram: Codable, Sendable, Equatable {
            /// Telegram Bot API token.
            public var botToken: String
            /// Maps Sloppy channelId → Telegram chat_id.
            public var channelChatMap: [String: Int64]
            public var topicChannelMap: [String: String]
            /// When non-empty, only these Telegram user IDs are allowed.
            public var allowedUserIds: [Int64]
            /// When non-empty, only these Telegram chat IDs are allowed.
            public var allowedChatIds: [Int64]

            public init(
                botToken: String,
                channelChatMap: [String: Int64] = [:],
                topicChannelMap: [String: String] = [:],
                allowedUserIds: [Int64] = [],
                allowedChatIds: [Int64] = []
            ) {
                self.botToken = botToken
                self.channelChatMap = channelChatMap
                self.topicChannelMap = topicChannelMap
                self.allowedUserIds = allowedUserIds
                self.allowedChatIds = allowedChatIds
            }

            private enum CodingKeys: String, CodingKey {
                case botToken
                case channelChatMap
                case topicChannelMap
                case allowedUserIds
                case allowedChatIds
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                botToken = try container.decodeIfPresent(String.self, forKey: .botToken) ?? ""
                channelChatMap = try container.decodeIfPresent([String: Int64].self, forKey: .channelChatMap) ?? [:]
                topicChannelMap = try container.decodeIfPresent([String: String].self, forKey: .topicChannelMap) ?? [:]
                allowedUserIds = try container.decodeIfPresent([Int64].self, forKey: .allowedUserIds) ?? []
                allowedChatIds = try container.decodeIfPresent([Int64].self, forKey: .allowedChatIds) ?? []
            }
        }

        public var discord: Discord?
        public var telegram: Telegram?
        public var channelInactivityDays: Int

        private enum CodingKeys: String, CodingKey {
            case discord
            case telegram
            case channelInactivityDays
        }

        public init(
            discord: Discord? = nil,
            telegram: Telegram? = nil,
            channelInactivityDays: Int = 2
        ) {
            self.discord = discord
            self.telegram = telegram
            self.channelInactivityDays = channelInactivityDays
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            discord = try container.decodeIfPresent(Discord.self, forKey: .discord)
            telegram = try container.decodeIfPresent(Telegram.self, forKey: .telegram)
            channelInactivityDays = try container.decodeIfPresent(Int.self, forKey: .channelInactivityDays) ?? 2
        }
    }

    public struct LSP: Codable, Sendable, Equatable {
        public struct Server: Codable, Sendable, Equatable {
            public var id: String
            public var command: String
            public var arguments: [String]
            public var cwd: String?
            public var extensions: [String]
            public var enabled: Bool
            public var timeoutMs: Int

            private enum CodingKeys: String, CodingKey {
                case id
                case command
                case arguments
                case cwd
                case extensions
                case enabled
                case timeoutMs
            }

            public init(
                id: String,
                command: String,
                arguments: [String] = [],
                cwd: String? = nil,
                extensions: [String] = [],
                enabled: Bool = true,
                timeoutMs: Int = 15_000
            ) {
                self.id = id
                self.command = command
                self.arguments = arguments
                self.cwd = cwd
                self.extensions = extensions
                self.enabled = enabled
                self.timeoutMs = timeoutMs
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                command = try container.decode(String.self, forKey: .command)
                arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
                cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
                extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
                timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 15_000
            }
        }

        public var servers: [Server]

        public init(servers: [Server] = []) {
            self.servers = servers
        }
    }

    public struct Visor: Codable, Sendable, Equatable {
        public struct Scheduler: Codable, Sendable, Equatable {
            public var enabled: Bool
            public var intervalSeconds: Int
            public var jitterSeconds: Int

            public init(
                enabled: Bool = true,
                intervalSeconds: Int = 300,
                jitterSeconds: Int = 60
            ) {
                self.enabled = enabled
                self.intervalSeconds = intervalSeconds
                self.jitterSeconds = jitterSeconds
            }
        }

        public var scheduler: Scheduler
        public var bootstrapBulletin: Bool
        /// Model identifier used for bulletin LLM synthesis (e.g. "openai:gpt-4o-mini").
        /// When nil, falls back to the default system model.
        public var model: String?
        /// Target word count for LLM-synthesized bulletin summary.
        public var bulletinMaxWords: Int
        /// Interval in seconds for the Visor supervision tick loop.
        public var tickIntervalSeconds: Int
        /// Seconds a worker may stay in .running/.waitingInput before it's considered hanging.
        public var workerTimeoutSeconds: Int
        /// Seconds a branch may stay alive before it's force-concluded by Visor.
        public var branchTimeoutSeconds: Int
        /// Interval in seconds between memory maintenance runs (decay + prune).
        public var maintenanceIntervalSeconds: Int
        /// Daily fractional decay applied to non-identity memory importance.
        public var decayRatePerDay: Double
        /// Memories with importance below this threshold are candidates for pruning.
        public var pruneImportanceThreshold: Double
        /// Minimum age in days before a memory can be pruned.
        public var pruneMinAgeDays: Int
        /// Number of workerFailed events in a channel within the window to trigger channel_degraded signal.
        public var channelDegradedFailureCount: Int
        /// Window in seconds for channel degradation failure counting.
        public var channelDegradedWindowSeconds: Int
        /// Seconds of inactivity before the idle signal is published.
        public var idleThresholdSeconds: Int
        /// Webhook URLs to POST signal events to when visor.signal.* events fire.
        public var webhookURLs: [String]
        /// Whether memory merge is enabled. When false, runMemoryMerge() is skipped.
        public var mergeEnabled: Bool
        /// Minimum recall score (0–1) required to consider two memories merge candidates.
        public var mergeSimilarityThreshold: Double
        /// Maximum number of merge operations performed in a single maintenance run.
        public var mergeMaxPerRun: Int

        public init(
            scheduler: Scheduler = Scheduler(),
            bootstrapBulletin: Bool = true,
            model: String? = nil,
            bulletinMaxWords: Int = 300,
            tickIntervalSeconds: Int = 30,
            workerTimeoutSeconds: Int = 600,
            branchTimeoutSeconds: Int = 60,
            maintenanceIntervalSeconds: Int = 3600,
            decayRatePerDay: Double = 0.05,
            pruneImportanceThreshold: Double = 0.1,
            pruneMinAgeDays: Int = 30,
            channelDegradedFailureCount: Int = 3,
            channelDegradedWindowSeconds: Int = 600,
            idleThresholdSeconds: Int = 1800,
            webhookURLs: [String] = [],
            mergeEnabled: Bool = false,
            mergeSimilarityThreshold: Double = 0.80,
            mergeMaxPerRun: Int = 10
        ) {
            self.scheduler = scheduler
            self.bootstrapBulletin = bootstrapBulletin
            self.model = model
            self.bulletinMaxWords = bulletinMaxWords
            self.tickIntervalSeconds = tickIntervalSeconds
            self.workerTimeoutSeconds = workerTimeoutSeconds
            self.branchTimeoutSeconds = branchTimeoutSeconds
            self.maintenanceIntervalSeconds = maintenanceIntervalSeconds
            self.decayRatePerDay = decayRatePerDay
            self.pruneImportanceThreshold = pruneImportanceThreshold
            self.pruneMinAgeDays = pruneMinAgeDays
            self.channelDegradedFailureCount = channelDegradedFailureCount
            self.channelDegradedWindowSeconds = channelDegradedWindowSeconds
            self.idleThresholdSeconds = idleThresholdSeconds
            self.webhookURLs = webhookURLs
            self.mergeEnabled = mergeEnabled
            self.mergeSimilarityThreshold = mergeSimilarityThreshold
            self.mergeMaxPerRun = mergeMaxPerRun
        }

        private enum CodingKeys: String, CodingKey {
            case scheduler
            case bootstrapBulletin
            case model
            case bulletinMaxWords
            case tickIntervalSeconds
            case workerTimeoutSeconds
            case branchTimeoutSeconds
            case maintenanceIntervalSeconds
            case decayRatePerDay
            case pruneImportanceThreshold
            case pruneMinAgeDays
            case channelDegradedFailureCount
            case channelDegradedWindowSeconds
            case idleThresholdSeconds
            case webhookURLs
            case mergeEnabled
            case mergeSimilarityThreshold
            case mergeMaxPerRun
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scheduler = try container.decodeIfPresent(Scheduler.self, forKey: .scheduler) ?? Scheduler()
            bootstrapBulletin = try container.decodeIfPresent(Bool.self, forKey: .bootstrapBulletin) ?? true
            model = try container.decodeIfPresent(String.self, forKey: .model)
            bulletinMaxWords = try container.decodeIfPresent(Int.self, forKey: .bulletinMaxWords) ?? 300
            tickIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .tickIntervalSeconds) ?? 30
            workerTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .workerTimeoutSeconds) ?? 600
            branchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .branchTimeoutSeconds) ?? 60
            maintenanceIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .maintenanceIntervalSeconds) ?? 3600
            decayRatePerDay = try container.decodeIfPresent(Double.self, forKey: .decayRatePerDay) ?? 0.05
            pruneImportanceThreshold = try container.decodeIfPresent(Double.self, forKey: .pruneImportanceThreshold) ?? 0.1
            pruneMinAgeDays = try container.decodeIfPresent(Int.self, forKey: .pruneMinAgeDays) ?? 30
            channelDegradedFailureCount = try container.decodeIfPresent(Int.self, forKey: .channelDegradedFailureCount) ?? 3
            channelDegradedWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .channelDegradedWindowSeconds) ?? 600
            idleThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? 1800
            webhookURLs = try container.decodeIfPresent([String].self, forKey: .webhookURLs) ?? []
            mergeEnabled = try container.decodeIfPresent(Bool.self, forKey: .mergeEnabled) ?? false
            mergeSimilarityThreshold = try container.decodeIfPresent(Double.self, forKey: .mergeSimilarityThreshold) ?? 0.80
            mergeMaxPerRun = try container.decodeIfPresent(Int.self, forKey: .mergeMaxPerRun) ?? 10
        }
    }

    public struct UI: Codable, Sendable, Equatable {
        public struct DashboardAuth: Codable, Sendable, Equatable {
            public var enabled: Bool
            public var token: String

            private enum CodingKeys: String, CodingKey {
                case enabled
                case token
            }

            public init(
                enabled: Bool = false,
                token: String = ""
            ) {
                self.enabled = enabled
                self.token = token
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
                token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
            }
        }

        public struct DashboardTerminal: Codable, Sendable, Equatable {
            public var enabled: Bool
            public var localOnly: Bool

            private enum CodingKeys: String, CodingKey {
                case enabled
                case localOnly
            }

            public init(
                enabled: Bool = false,
                localOnly: Bool = true
            ) {
                self.enabled = enabled
                self.localOnly = localOnly
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
                localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? true
            }
        }

        public var dashboardAuth: DashboardAuth
        public var dashboardTerminal: DashboardTerminal

        private enum CodingKeys: String, CodingKey {
            case dashboardAuth
            case dashboardTerminal
        }

        public init(
            dashboardAuth: DashboardAuth = DashboardAuth(),
            dashboardTerminal: DashboardTerminal = DashboardTerminal()
        ) {
            self.dashboardAuth = dashboardAuth
            self.dashboardTerminal = dashboardTerminal
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dashboardAuth = try container.decodeIfPresent(DashboardAuth.self, forKey: .dashboardAuth) ?? .init()
            dashboardTerminal = try container.decodeIfPresent(DashboardTerminal.self, forKey: .dashboardTerminal) ?? .init()
        }
    }

    public struct ToolHooks: Codable, Sendable, Equatable {
        public struct PreTools: Codable, Sendable, Equatable {
            public enum FailurePolicy: String, Codable, Sendable, Equatable {
                case allow
                case block
            }

            public var enabled: Bool
            public var command: String
            public var arguments: [String]
            public var timeoutMs: Int
            public var maxOutputBytes: Int
            public var failurePolicy: FailurePolicy

            public init(
                enabled: Bool = false,
                command: String = "",
                arguments: [String] = [],
                timeoutMs: Int = 2_000,
                maxOutputBytes: Int = 65_536,
                failurePolicy: FailurePolicy = .block
            ) {
                self.enabled = enabled
                self.command = command
                self.arguments = arguments
                self.timeoutMs = timeoutMs
                self.maxOutputBytes = maxOutputBytes
                self.failurePolicy = failurePolicy
            }

            private enum CodingKeys: String, CodingKey {
                case enabled
                case command
                case arguments
                case timeoutMs
                case maxOutputBytes
                case failurePolicy
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
                command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
                arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
                timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 2_000
                maxOutputBytes = try container.decodeIfPresent(Int.self, forKey: .maxOutputBytes) ?? 65_536
                failurePolicy = try container.decodeIfPresent(FailurePolicy.self, forKey: .failurePolicy) ?? .block
            }
        }

        public var preTools: PreTools

        public init(preTools: PreTools = PreTools()) {
            self.preTools = preTools
        }

        private enum CodingKeys: String, CodingKey {
            case preTools
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preTools = try container.decodeIfPresent(PreTools.self, forKey: .preTools) ?? .init()
        }
    }

    public var listen: Listen
    public var workspace: Workspace
    public var auth: Auth
    public var onboarding: Onboarding
    public var models: [ModelConfig]
    public var disableModelInference: Bool
    public var memory: Memory
    public var nodes: [String]
    public var gateways: [String]
    public var plugins: [PluginConfig]
    public var channels: ChannelConfig
    public var gitSync: GitSync
    public var mcp: MCP
    public var acp: ACP
    public var lsp: LSP
    public var searchTools: SearchTools
    public var proxy: Proxy
    public var browser: Browser
    public var visor: Visor
    public var ui: UI
    public var toolHooks: ToolHooks
    public var sqlitePath: String
    /// Optional aliases for model ids (e.g. `"fast"` → `"openai:gpt-5.4-mini"`) used when resolving `model` from SKILL.md or tools.
    public var modelRouting: [String: String]

    public init(
        listen: Listen,
        workspace: Workspace,
        auth: Auth,
        onboarding: Onboarding = Onboarding(),
        models: [ModelConfig],
        memory: Memory,
        nodes: [String],
        gateways: [String],
        plugins: [PluginConfig],
        channels: ChannelConfig = ChannelConfig(),
        gitSync: GitSync = GitSync(),
        mcp: MCP = MCP(),
        acp: ACP = ACP(),
        lsp: LSP = LSP(),
        searchTools: SearchTools = SearchTools(),
        proxy: Proxy = Proxy(),
        browser: Browser = Browser(),
        visor: Visor = Visor(),
        ui: UI = UI(),
        toolHooks: ToolHooks = ToolHooks(),
        sqlitePath: String,
        modelRouting: [String: String] = [:],
        disableModelInference: Bool = false
    ) {
        self.listen = listen
        self.workspace = workspace
        self.auth = auth
        self.onboarding = onboarding
        self.models = models
        self.memory = memory
        self.nodes = nodes
        self.gateways = gateways
        self.plugins = plugins
        self.channels = channels
        self.gitSync = gitSync
        self.mcp = mcp
        self.acp = acp
        self.lsp = lsp
        self.searchTools = searchTools
        self.proxy = proxy
        self.browser = browser
        self.visor = visor
        self.ui = ui
        self.toolHooks = toolHooks
        self.sqlitePath = sqlitePath
        self.modelRouting = modelRouting
        self.disableModelInference = disableModelInference
    }

    public static var `default`: CoreConfig {
        CoreConfig(
            listen: .init(host: "0.0.0.0", port: 25101),
            workspace: .init(),
            auth: .init(token: "dev-token"),
            onboarding: .init(),
            models: [
                .init(
                    title: "openai-main",
                    apiKey: "",
                    apiUrl: "https://api.openai.com/v1",
                    model: "gpt-5.4-mini"
                ),
                .init(
                    title: "ollama-local",
                    apiKey: "",
                    apiUrl: "http://127.0.0.1:11434",
                    model: "qwen3"
                )
            ],
            memory: .init(backend: "sqlite-local-vectors"),
            nodes: ["local"],
            gateways: [],
            plugins: [],
            channels: .init(),
            gitSync: .init(),
            mcp: .init(),
            acp: .init(),
            searchTools: .init(),
            proxy: .init(),
            browser: .init(),
            visor: .init(),
            ui: .init(),
            toolHooks: .init(),
            sqlitePath: CoreConfig.defaultSQLiteFileName,
            modelRouting: [:]
        )
    }

    public static func defaultConfigPath(
        for workspace: Workspace = Workspace(),
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        let cwd = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return Self.resolvePath(workspace.basePath, currentDirectory: cwd)
            .appendingPathComponent(workspace.name, isDirectory: true)
            .appendingPathComponent(defaultConfigFileName)
            .path
    }

    public static func load(
        from path: String? = nil,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> CoreConfig {
        let normalizedPath = path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedPath, !normalizedPath.isEmpty {
            if let decoded = decodeConfigFile(at: normalizedPath) {
                return decoded
            }
            return .default
        }

        let resolvedPath = defaultConfigPath(currentDirectory: currentDirectory)
        if let decoded = decodeConfigFile(at: resolvedPath) {
            return decoded
        }

        return .default
    }

    private static func decodeConfigFile(at path: String) -> CoreConfig? {
        let fileURL = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        return try? decoder.decode(CoreConfig.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case listen
        case workspace
        case auth
        case onboarding
        case models
        case memory
        case nodes
        case gateways
        case plugins
        case channels
        case gitSync
        case mcp
        case acp
        case lsp
        case searchTools
        case proxy
        case browser
        case visor
        case ui
        case toolHooks
        case sqlitePath
        case modelRouting
        case disableModelInference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        listen = try container.decode(Listen.self, forKey: .listen)
        workspace = try container.decodeIfPresent(Workspace.self, forKey: .workspace) ?? .init()
        auth = try container.decode(Auth.self, forKey: .auth)
        onboarding = try container.decodeIfPresent(Onboarding.self, forKey: .onboarding) ?? .init()
        memory = try container.decode(Memory.self, forKey: .memory)
        nodes = try container.decodeIfPresent([String].self, forKey: .nodes) ?? []
        gateways = try container.decodeIfPresent([String].self, forKey: .gateways) ?? []
        channels = try container.decodeIfPresent(ChannelConfig.self, forKey: .channels) ?? .init()
        gitSync = try container.decodeIfPresent(GitSync.self, forKey: .gitSync) ?? .init()
        mcp = try container.decodeIfPresent(MCP.self, forKey: .mcp) ?? .init()
        acp = try container.decodeIfPresent(ACP.self, forKey: .acp) ?? .init()
        lsp = try container.decodeIfPresent(LSP.self, forKey: .lsp) ?? .init()
        searchTools = try container.decodeIfPresent(SearchTools.self, forKey: .searchTools) ?? .init()
        proxy = try container.decodeIfPresent(Proxy.self, forKey: .proxy) ?? .init()
        browser = try container.decodeIfPresent(Browser.self, forKey: .browser) ?? .init()
        visor = try container.decodeIfPresent(Visor.self, forKey: .visor) ?? .init()
        ui = try container.decodeIfPresent(UI.self, forKey: .ui) ?? .init()
        toolHooks = try container.decodeIfPresent(ToolHooks.self, forKey: .toolHooks) ?? .init()
        sqlitePath = try container.decode(String.self, forKey: .sqlitePath)
        models = try container.decodeIfPresent([ModelConfig].self, forKey: .models) ?? []
        plugins = try container.decodeIfPresent([PluginConfig].self, forKey: .plugins) ?? []
        modelRouting = try container.decodeIfPresent([String: String].self, forKey: .modelRouting) ?? [:]
        disableModelInference = try container.decodeIfPresent(Bool.self, forKey: .disableModelInference) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(listen, forKey: .listen)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(auth, forKey: .auth)
        try container.encode(onboarding, forKey: .onboarding)
        try container.encode(models, forKey: .models)
        try container.encode(memory, forKey: .memory)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(gateways, forKey: .gateways)
        try container.encode(plugins, forKey: .plugins)
        try container.encode(channels, forKey: .channels)
        try container.encode(gitSync, forKey: .gitSync)
        try container.encode(mcp, forKey: .mcp)
        try container.encode(acp, forKey: .acp)
        try container.encode(lsp, forKey: .lsp)
        try container.encode(searchTools, forKey: .searchTools)
        try container.encode(proxy, forKey: .proxy)
        try container.encode(browser, forKey: .browser)
        try container.encode(visor, forKey: .visor)
        try container.encode(ui, forKey: .ui)
        try container.encode(toolHooks, forKey: .toolHooks)
        try container.encode(sqlitePath, forKey: .sqlitePath)
        if !modelRouting.isEmpty {
            try container.encode(modelRouting, forKey: .modelRouting)
        }
        try container.encode(disableModelInference, forKey: .disableModelInference)
    }

    public func resolvedWorkspaceRootURL(currentDirectory: String = FileManager.default.currentDirectoryPath) -> URL {
        let cwd = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return Self.resolvePath(workspace.basePath, currentDirectory: cwd)
            .appendingPathComponent(workspace.name, isDirectory: true)
    }

    public func resolvedSQLiteURL(currentDirectory: String = FileManager.default.currentDirectoryPath) -> URL {
        if Self.isAbsolutePath(sqlitePath) {
            return URL(fileURLWithPath: sqlitePath)
        }

        return resolvedWorkspaceRootURL(currentDirectory: currentDirectory)
            .appendingPathComponent(sqlitePath)
    }

    private static func resolvePath(_ rawPath: String, currentDirectory: URL) -> URL {
        if let expandedHome = expandHomeShortcut(rawPath) {
            return URL(fileURLWithPath: expandedHome, isDirectory: true)
        }
        if isAbsolutePath(rawPath) {
            return URL(fileURLWithPath: rawPath, isDirectory: true)
        }
        return currentDirectory.appendingPathComponent(rawPath, isDirectory: true).standardized
    }

    private static func expandHomeShortcut(_ rawPath: String) -> String? {
        // Match `~` and literal `$HOME` in config to the same rule as CLI: `HOME`, else FileManager.
        let home = resolvedHomeDirectoryPath()
        if rawPath == "~" {
            return home
        }
        if rawPath.hasPrefix("~/") {
            let suffix = String(rawPath.dropFirst(2))
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: true)
                .path
        }
        if rawPath == "$HOME" {
            return home
        }
        if rawPath.hasPrefix("$HOME/") {
            let suffix = String(rawPath.dropFirst("$HOME/".count))
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: true)
                .path
        }
        return nil
    }

    private static func isAbsolutePath(_ rawPath: String) -> Bool {
        rawPath.hasPrefix("/")
    }
}

extension CoreConfig {
    public static func resolvedHomeDirectoryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty
        {
            return home
        }

        return fileManager.homeDirectoryForCurrentUser.path
    }
}

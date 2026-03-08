import Foundation

public struct CoreConfig: Codable, Sendable {
    public static let defaultConfigFileName = "sloppy.json"
    public static let legacyDefaultConfigFileName = "sloppy.config.json"
    public static var defaultConfigPath: String {
        defaultConfigPath(currentDirectory: FileManager.default.currentDirectoryPath)
    }
    public static let defaultWorkspaceName = "workspace"
    public static let defaultWorkspaceBasePath = "~"
    public static let defaultSQLiteFileName = "core.sqlite"
    public static let legacyDefaultSQLitePath = "./.data/core.sqlite"

    public struct ModelConfig: Codable, Sendable, Equatable {
        public var title: String
        public var apiKey: String
        public var apiUrl: String
        public var model: String

        public init(title: String, apiKey: String, apiUrl: String, model: String) {
            self.title = title
            self.apiKey = apiKey
            self.apiUrl = apiUrl
            self.model = model
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
            public var timeoutMs: Int
            public var apiKeyEnv: String?

            public init(
                mode: Mode = .local,
                endpoint: String? = nil,
                mcpServer: String? = nil,
                timeoutMs: Int = 2_500,
                apiKeyEnv: String? = nil
            ) {
                self.mode = mode
                self.endpoint = endpoint
                self.mcpServer = mcpServer
                self.timeoutMs = timeoutMs
                self.apiKeyEnv = apiKeyEnv
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

        public var backend: String
        public var provider: Provider
        public var retrieval: Retrieval
        public var retention: Retention

        public init(
            backend: String,
            provider: Provider = Provider(),
            retrieval: Retrieval = Retrieval(),
            retention: Retention = Retention()
        ) {
            self.backend = backend
            self.provider = provider
            self.retrieval = retrieval
            self.retention = retention
        }

        private enum CodingKeys: String, CodingKey {
            case backend
            case provider
            case retrieval
            case retention
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            backend = try container.decode(String.self, forKey: .backend)
            provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? Provider()
            retrieval = try container.decodeIfPresent(Retrieval.self, forKey: .retrieval) ?? Retrieval()
            retention = try container.decodeIfPresent(Retention.self, forKey: .retention) ?? Retention()
        }
    }

    public struct Auth: Codable, Sendable {
        public var token: String

        public init(token: String) {
            self.token = token
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
            /// When non-empty, only these Telegram user IDs are allowed.
            public var allowedUserIds: [Int64]
            /// When non-empty, only these Telegram chat IDs are allowed.
            public var allowedChatIds: [Int64]

            public init(
                botToken: String,
                channelChatMap: [String: Int64] = [:],
                allowedUserIds: [Int64] = [],
                allowedChatIds: [Int64] = []
            ) {
                self.botToken = botToken
                self.channelChatMap = channelChatMap
                self.allowedUserIds = allowedUserIds
                self.allowedChatIds = allowedChatIds
            }
        }

        public var discord: Discord?
        public var telegram: Telegram?

        public init(
            discord: Discord? = nil,
            telegram: Telegram? = nil
        ) {
            self.discord = discord
            self.telegram = telegram
        }
    }

    public struct Browser: Codable, Sendable, Equatable {
        public struct Profile: Codable, Sendable, Equatable {
            public var id: String
            public var title: String
            public var userDataDir: String
            public var profileDirectory: String

            public init(
                id: String,
                title: String,
                userDataDir: String,
                profileDirectory: String = "Default"
            ) {
                self.id = id
                self.title = title
                self.userDataDir = userDataDir
                self.profileDirectory = profileDirectory
            }

            private enum CodingKeys: String, CodingKey {
                case id
                case title
                case userDataDir
                case profileDirectory
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                title = try container.decode(String.self, forKey: .title)
                userDataDir = try container.decode(String.self, forKey: .userDataDir)
                profileDirectory = try container.decodeIfPresent(String.self, forKey: .profileDirectory) ?? "Default"
            }
        }

        public var browserPath: String
        public var headless: Bool
        public var allowJavaScriptEvaluation: Bool
        public var profiles: [Profile]

        public init(
            browserPath: String = "/usr/bin/chromium",
            headless: Bool = true,
            allowJavaScriptEvaluation: Bool = false,
            profiles: [Profile] = []
        ) {
            self.browserPath = browserPath
            self.headless = headless
            self.allowJavaScriptEvaluation = allowJavaScriptEvaluation
            self.profiles = profiles
        }

        private enum CodingKeys: String, CodingKey {
            case browserPath
            case headless
            case allowJavaScriptEvaluation
            case profiles
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            browserPath = try container.decodeIfPresent(String.self, forKey: .browserPath) ?? "/usr/bin/chromium"
            headless = try container.decodeIfPresent(Bool.self, forKey: .headless) ?? true
            allowJavaScriptEvaluation = try container.decodeIfPresent(Bool.self, forKey: .allowJavaScriptEvaluation) ?? false
            profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
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

        public init(
            scheduler: Scheduler = Scheduler(),
            bootstrapBulletin: Bool = true
        ) {
            self.scheduler = scheduler
            self.bootstrapBulletin = bootstrapBulletin
        }
    }

    public var listen: Listen
    public var workspace: Workspace
    public var auth: Auth
    public var models: [ModelConfig]
    public var memory: Memory
    public var nodes: [String]
    public var gateways: [String]
    public var plugins: [PluginConfig]
    public var channels: ChannelConfig
    public var browser: Browser
    public var gitSync: GitSync
    public var searchTools: SearchTools
    public var visor: Visor
    public var sqlitePath: String

    public init(
        listen: Listen,
        workspace: Workspace,
        auth: Auth,
        models: [ModelConfig],
        memory: Memory,
        nodes: [String],
        gateways: [String],
        plugins: [PluginConfig],
        channels: ChannelConfig = ChannelConfig(),
        browser: Browser = Browser(),
        gitSync: GitSync = GitSync(),
        searchTools: SearchTools = SearchTools(),
        visor: Visor = Visor(),
        sqlitePath: String
    ) {
        self.listen = listen
        self.workspace = workspace
        self.auth = auth
        self.models = models
        self.memory = memory
        self.nodes = nodes
        self.gateways = gateways
        self.plugins = plugins
        self.channels = channels
        self.browser = browser
        self.gitSync = gitSync
        self.searchTools = searchTools
        self.visor = visor
        self.sqlitePath = sqlitePath
    }

    public static var `default`: CoreConfig {
        CoreConfig(
            listen: .init(host: "0.0.0.0", port: 25101),
            workspace: .init(),
            auth: .init(token: "dev-token"),
            models: [
                .init(
                    title: "openai-main",
                    apiKey: "",
                    apiUrl: "https://api.openai.com/v1",
                    model: "gpt-4.1-mini"
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
            browser: .init(),
            gitSync: .init(),
            searchTools: .init(),
            visor: .init(),
            sqlitePath: CoreConfig.defaultSQLiteFileName
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

        // Keep backward compatibility for repositories that still rely on
        // sloppy.config.json in the working directory.
        if path == nil || normalizedPath?.isEmpty == true {
            let legacyPath = URL(fileURLWithPath: currentDirectory, isDirectory: true)
                .appendingPathComponent(legacyDefaultConfigFileName)
                .path
            if let decodedLegacy = decodeConfigFile(at: legacyPath) {
                return decodedLegacy
            }
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
        case models
        case memory
        case nodes
        case gateways
        case plugins
        case channels
        case browser
        case gitSync
        case searchTools
        case visor
        case sqlitePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        listen = try container.decode(Listen.self, forKey: .listen)
        workspace = try container.decodeIfPresent(Workspace.self, forKey: .workspace) ?? .init()
        auth = try container.decode(Auth.self, forKey: .auth)
        memory = try container.decode(Memory.self, forKey: .memory)
        nodes = try container.decodeIfPresent([String].self, forKey: .nodes) ?? []
        gateways = try container.decodeIfPresent([String].self, forKey: .gateways) ?? []
        channels = try container.decodeIfPresent(ChannelConfig.self, forKey: .channels) ?? .init()
        browser = try container.decodeIfPresent(Browser.self, forKey: .browser) ?? .init()
        gitSync = try container.decodeIfPresent(GitSync.self, forKey: .gitSync) ?? .init()
        searchTools = try container.decodeIfPresent(SearchTools.self, forKey: .searchTools) ?? .init()
        visor = try container.decodeIfPresent(Visor.self, forKey: .visor) ?? .init()
        sqlitePath = try container.decode(String.self, forKey: .sqlitePath)
        if sqlitePath == CoreConfig.legacyDefaultSQLitePath {
            sqlitePath = CoreConfig.defaultSQLiteFileName
        }

        if let decodedModels = try? container.decode([ModelConfig].self, forKey: .models) {
            models = decodedModels
        } else if let legacyModels = try? container.decode([String].self, forKey: .models) {
            models = legacyModels.map(Self.modelFromLegacy)
        } else {
            models = []
        }

        if let decodedPlugins = try? container.decode([PluginConfig].self, forKey: .plugins) {
            plugins = decodedPlugins
        } else if let legacyPlugins = try? container.decode([String].self, forKey: .plugins) {
            plugins = legacyPlugins.map { legacy in
                PluginConfig(
                    title: legacy,
                    apiKey: "",
                    apiUrl: "",
                    plugin: legacy
                )
            }
        } else {
            plugins = []
        }
    }

    private static func modelFromLegacy(_ legacy: String) -> ModelConfig {
        let parts = legacy.split(separator: ":", maxSplits: 1).map(String.init)
        let provider: String
        let model: String
        if parts.count == 2 {
            provider = parts[0].lowercased()
            model = parts[1]
        } else {
            provider = ""
            model = legacy
        }

        let apiUrl: String
        switch provider {
        case "openai":
            apiUrl = "https://api.openai.com/v1"
        case "ollama":
            apiUrl = "http://127.0.0.1:11434"
        default:
            apiUrl = ""
        }

        let title = provider.isEmpty ? model : "\(provider)-\(model)"
        return ModelConfig(title: title, apiKey: "", apiUrl: apiUrl, model: model)
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

    public func resolvedBrowserUserDataDir(
        _ rawPath: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> URL {
        let cwd = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return Self.resolvePath(rawPath, currentDirectory: cwd)
    }

    private static func resolvePath(_ rawPath: String, currentDirectory: URL) -> URL {
        if let expandedHome = expandHomeShortcut(rawPath) {
            return URL(fileURLWithPath: expandedHome, isDirectory: true)
        }
        if isAbsolutePath(rawPath) {
            return URL(fileURLWithPath: rawPath, isDirectory: true)
        }
        return currentDirectory.appendingPathComponent(rawPath, isDirectory: true)
    }

    private static func expandHomeShortcut(_ rawPath: String) -> String? {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if rawPath == "~" {
            return homePath
        }
        if rawPath.hasPrefix("~/") {
            let suffix = String(rawPath.dropFirst(2))
            return URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: true)
                .path
        }
        if rawPath == "$HOME" {
            return homePath
        }
        if rawPath.hasPrefix("$HOME/") {
            let suffix = String(rawPath.dropFirst("$HOME/".count))
            return URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: true)
                .path
        }
        return nil
    }

    private static func isAbsolutePath(_ rawPath: String) -> Bool {
        rawPath.hasPrefix("/")
    }
}

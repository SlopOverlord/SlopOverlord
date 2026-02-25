import Foundation

public struct CoreConfig: Codable, Sendable {
    public static let defaultConfigPath = "slopoverlord.config.json"

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

    public struct Memory: Codable, Sendable {
        public var backend: String

        public init(backend: String) {
            self.backend = backend
        }
    }

    public struct Auth: Codable, Sendable {
        public var token: String

        public init(token: String) {
            self.token = token
        }
    }

    public var listen: Listen
    public var auth: Auth
    public var models: [ModelConfig]
    public var memory: Memory
    public var nodes: [String]
    public var gateways: [String]
    public var plugins: [PluginConfig]
    public var sqlitePath: String

    public init(
        listen: Listen,
        auth: Auth,
        models: [ModelConfig],
        memory: Memory,
        nodes: [String],
        gateways: [String],
        plugins: [PluginConfig],
        sqlitePath: String
    ) {
        self.listen = listen
        self.auth = auth
        self.models = models
        self.memory = memory
        self.nodes = nodes
        self.gateways = gateways
        self.plugins = plugins
        self.sqlitePath = sqlitePath
    }

    public static var `default`: CoreConfig {
        CoreConfig(
            listen: .init(host: "0.0.0.0", port: 25101),
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
            sqlitePath: "./.data/core.sqlite"
        )
    }

    public static func load(from path: String = CoreConfig.defaultConfigPath) -> CoreConfig {
        let fileURL = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: fileURL) else {
            return .default
        }

        let decoder = JSONDecoder()
        return (try? decoder.decode(CoreConfig.self, from: data)) ?? .default
    }

    private enum CodingKeys: String, CodingKey {
        case listen
        case auth
        case models
        case memory
        case nodes
        case gateways
        case plugins
        case sqlitePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        listen = try container.decode(Listen.self, forKey: .listen)
        auth = try container.decode(Auth.self, forKey: .auth)
        memory = try container.decode(Memory.self, forKey: .memory)
        nodes = try container.decodeIfPresent([String].self, forKey: .nodes) ?? []
        gateways = try container.decodeIfPresent([String].self, forKey: .gateways) ?? []
        sqlitePath = try container.decode(String.self, forKey: .sqlitePath)

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
}

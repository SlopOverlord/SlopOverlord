import Foundation

public struct CoreConfig: Codable, Sendable {
    public static let defaultConfigPath = "slopoverlord.config.json"

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
    public var models: [String]
    public var memory: Memory
    public var nodes: [String]
    public var gateways: [String]
    public var plugins: [String]
    public var sqlitePath: String

    public init(
        listen: Listen,
        auth: Auth,
        models: [String],
        memory: Memory,
        nodes: [String],
        gateways: [String],
        plugins: [String],
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
            listen: .init(host: "0.0.0.0", port: 251018),
            auth: .init(token: "dev-token"),
            models: ["openai:gpt-4.1-mini", "ollama:qwen3"],
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
}

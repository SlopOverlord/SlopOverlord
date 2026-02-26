import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AgentRuntime
import PluginSDK
import Protocols

public actor CoreService {
    private let runtime: RuntimeSystem
    private let store: any PersistenceStore
    private let configPath: String
    private var currentConfig: CoreConfig
    private var eventTask: Task<Void, Never>?

    /// Creates core orchestration service with runtime and persistence backend.
    public init(config: CoreConfig, configPath: String = CoreConfig.defaultConfigPath) {
        let resolvedModels = Self.resolveModelIdentifiers(config: config)
        let modelProvider = Self.buildModelProvider(config: config, resolvedModels: resolvedModels)
        self.runtime = RuntimeSystem(
            modelProvider: modelProvider,
            defaultModel: modelProvider?.models.first ?? resolvedModels.first
        )
        let schema = Self.loadSchemaSQL()
        self.store = SQLiteStore(path: config.sqlitePath, schemaSQL: schema)
        self.configPath = configPath
        self.currentConfig = config
        Task {
            await self.startEventPersistence()
        }
    }

    deinit {
        eventTask?.cancel()
    }

    /// Accepts a user channel message and returns routing decision.
    public func postChannelMessage(channelId: String, request: ChannelMessageRequest) async -> ChannelRouteDecision {
        await runtime.postMessage(channelId: channelId, request: request)
    }

    /// Routes interactive message into a running worker.
    public func postChannelRoute(channelId: String, workerId: String, request: ChannelRouteRequest) async -> Bool {
        await runtime.routeMessage(channelId: channelId, workerId: workerId, message: request.message)
    }

    /// Returns current state snapshot for a channel.
    public func getChannelState(channelId: String) async -> ChannelSnapshot? {
        await runtime.channelState(channelId: channelId)
    }

    /// Returns known visor bulletins, preferring in-memory runtime state.
    public func getBulletins() async -> [MemoryBulletin] {
        let runtimeBulletins = await runtime.bulletins()
        if runtimeBulletins.isEmpty {
            return await store.listBulletins()
        }
        return runtimeBulletins
    }

    /// Creates worker instance from API request.
    public func postWorker(request: WorkerCreateRequest) async -> String {
        await runtime.createWorker(spec: request.spec)
    }

    /// Reads artifact content from runtime or persistent storage.
    public func getArtifactContent(id: String) async -> ArtifactContentResponse? {
        if let runtimeArtifact = await runtime.artifactContent(id: id) {
            await store.persistArtifact(id: id, content: runtimeArtifact)
            return ArtifactContentResponse(id: id, content: runtimeArtifact)
        }

        if let storedArtifact = await store.artifactContent(id: id) {
            return ArtifactContentResponse(id: id, content: storedArtifact)
        }

        return nil
    }

    /// Forces immediate visor bulletin generation and stores it.
    public func triggerVisorBulletin() async -> MemoryBulletin {
        let bulletin = await runtime.generateVisorBulletin()
        await store.persistBulletin(bulletin)
        return bulletin
    }

    /// Exposes worker snapshots for observability endpoints.
    public func workerSnapshots() async -> [WorkerSnapshot] {
        await runtime.workerSnapshots()
    }

    /// Returns currently active runtime config snapshot.
    public func getConfig() -> CoreConfig {
        currentConfig
    }

    /// Returns OpenAI model catalog using API key auth or environment fallback.
    public func listOpenAIModels(request: OpenAIProviderModelsRequest) async -> OpenAIProviderModelsResponse {
        let primaryOpenAIConfig = currentConfig.models.first {
            Self.resolvedIdentifier(for: $0).hasPrefix("openai:")
        }

        let configuredURL = primaryOpenAIConfig?.apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedURL = request.apiUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = Self.parseURL(requestedURL) ?? Self.parseURL(configuredURL) ?? URL(string: "https://api.openai.com/v1")

        let configuredKey = primaryOpenAIConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var usedEnvironmentKey = false
        let resolvedKey: String? = {
            switch request.authMethod {
            case .apiKey:
                if !requestKey.isEmpty {
                    return requestKey
                }
                if !configuredKey.isEmpty {
                    return configuredKey
                }
                if !envKey.isEmpty {
                    usedEnvironmentKey = true
                    return envKey
                }
                return nil
            case .deeplink:
                if !envKey.isEmpty {
                    usedEnvironmentKey = true
                    return envKey
                }
                return nil
            }
        }()

        guard let apiKey = resolvedKey, !apiKey.isEmpty, let baseURL else {
            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "fallback",
                warning: "OpenAI API key is missing. Provide API key or set OPENAI_API_KEY.",
                models: Self.fallbackOpenAIModels
            )
        }

        do {
            let models = try await Self.fetchOpenAIModels(apiKey: apiKey, baseURL: baseURL)
            if models.isEmpty {
                return OpenAIProviderModelsResponse(
                    provider: "openai",
                    authMethod: request.authMethod,
                    usedEnvironmentKey: usedEnvironmentKey,
                    source: "fallback",
                    warning: "Provider returned empty model list.",
                    models: Self.fallbackOpenAIModels
                )
            }

            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "remote",
                warning: nil,
                models: models
            )
        } catch {
            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "fallback",
                warning: "Failed to fetch OpenAI models: \(error.localizedDescription)",
                models: Self.fallbackOpenAIModels
            )
        }
    }

    /// Persists config to file and updates in-memory snapshot.
    public func updateConfig(_ config: CoreConfig) throws -> CoreConfig {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encoded = try encoder.encode(config)
        let payload = encoded + Data("\n".utf8)
        let url = URL(fileURLWithPath: configPath)
        try payload.write(to: url, options: .atomic)

        currentConfig = config
        return currentConfig
    }

    /// Loads bundled SQL schema text used by SQLite store.
    private static func loadSchemaSQL() -> String {
        let fileManager = FileManager.default
        let executablePath = CommandLine.arguments.first ?? ""
        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        // Resolve schema from source checkout or alongside released binaries.
        let candidatePaths = [
            cwd.appendingPathComponent("Sources/Core/Storage/schema.sql").path,
            executableDirectory.appendingPathComponent("Sources/Core/Storage/schema.sql").path,
            cwd.appendingPathComponent("SlopOverlord_Core.resources/schema.sql").path,
            cwd.appendingPathComponent("SlopOverlord_Core.bundle/schema.sql").path,
            executableDirectory.appendingPathComponent("SlopOverlord_Core.resources/schema.sql").path,
            executableDirectory.appendingPathComponent("SlopOverlord_Core.bundle/schema.sql").path
        ]

        for candidatePath in candidatePaths where fileManager.fileExists(atPath: candidatePath) {
            if let schema = try? String(contentsOfFile: candidatePath, encoding: .utf8), !schema.isEmpty {
                return schema
            }
        }

        // Last resort fallback to embedded schema for container/runtime safety.
        return embeddedSchemaSQL
    }

    /// Builds model provider plugin for AnyLanguageModel-based agent responses.
    private static func buildModelProvider(
        config: CoreConfig,
        resolvedModels: [String]
    ) -> AnyLanguageModelProviderPlugin? {
        let supportsOpenAI = resolvedModels.contains { $0.hasPrefix("openai:") }
        let supportsOllama = resolvedModels.contains { $0.hasPrefix("ollama:") }

        let primaryOpenAIConfig = config.models.first {
            resolvedIdentifier(for: $0).hasPrefix("openai:")
        }
        let primaryOllamaConfig = config.models.first {
            resolvedIdentifier(for: $0).hasPrefix("ollama:")
        }

        var openAISettings: AnyLanguageModelProviderPlugin.OpenAISettings?
        if supportsOpenAI {
            let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
            let configuredKey = primaryOpenAIConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedKey = configuredKey.isEmpty ? apiKey : configuredKey

            if !resolvedKey.isEmpty {
                if let baseURL = parseURL(primaryOpenAIConfig?.apiUrl) {
                    openAISettings = .init(apiKey: { resolvedKey }, baseURL: baseURL)
                } else {
                    openAISettings = .init(apiKey: { resolvedKey })
                }
            }
        }

        let ollamaSettings: AnyLanguageModelProviderPlugin.OllamaSettings? = {
            guard supportsOllama else {
                return nil
            }
            if let baseURL = parseURL(primaryOllamaConfig?.apiUrl) {
                return .init(baseURL: baseURL)
            }
            return .init()
        }()

        let availableModels = resolvedModels.filter { model in
            if model.hasPrefix("openai:") {
                return openAISettings != nil
            }
            if model.hasPrefix("ollama:") {
                return ollamaSettings != nil
            }
            return openAISettings != nil || ollamaSettings != nil
        }

        guard !availableModels.isEmpty else {
            return nil
        }

        return AnyLanguageModelProviderPlugin(
            id: "any-language-model",
            models: availableModels,
            openAI: openAISettings,
            ollama: ollamaSettings,
            systemInstructions: "You are SlopOverlord core channel assistant."
        )
    }

    private static func resolveModelIdentifiers(config: CoreConfig) -> [String] {
        var identifiers = config.models.map(resolvedIdentifier(for:))
        let hasOpenAI = identifiers.contains { $0.hasPrefix("openai:") }
        let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !hasOpenAI, !environmentKey.isEmpty {
            identifiers.append("openai:gpt-4.1-mini")
        }

        return identifiers
    }

    private static func resolvedIdentifier(for model: CoreConfig.ModelConfig) -> String {
        let modelValue = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelValue.hasPrefix("openai:") || modelValue.hasPrefix("ollama:") {
            return modelValue
        }

        let provider = inferredProvider(model: model)
        if let provider {
            return "\(provider):\(modelValue)"
        }

        return modelValue
    }

    private static func inferredProvider(model: CoreConfig.ModelConfig) -> String? {
        let title = model.title.lowercased()
        let apiURL = model.apiUrl.lowercased()

        if title.contains("openai") || apiURL.contains("openai") {
            return "openai"
        }

        if title.contains("ollama") || apiURL.contains("ollama") || apiURL.contains("11434") {
            return "ollama"
        }

        return nil
    }

    private static func parseURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private struct OpenAIModelsResponse: Decodable {
        struct ModelItem: Decodable {
            let id: String
        }

        let data: [ModelItem]
    }

    private static let fallbackOpenAIModels: [ProviderModelOption] = [
        .init(id: "gpt-4.1", title: "gpt-4.1"),
        .init(id: "gpt-4.1-mini", title: "gpt-4.1-mini"),
        .init(id: "gpt-4o", title: "gpt-4o"),
        .init(id: "gpt-4o-mini", title: "gpt-4o-mini"),
        .init(id: "o4-mini", title: "o4-mini")
    ]

    private static func fetchOpenAIModels(apiKey: String, baseURL: URL) async throws -> [ProviderModelOption] {
        let endpoint = openAIModelsURL(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted()
            .map { ProviderModelOption(id: $0, title: $0) }
    }

    private static func openAIModelsURL(baseURL: URL) -> URL {
        if baseURL.path.isEmpty || baseURL.path == "/" {
            return baseURL.appendingPathComponent("models")
        }

        let normalizedPath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        if normalizedPath.hasSuffix("/models") {
            return baseURL
        }

        return baseURL.appendingPathComponent("models")
    }

    /// Subscribes to runtime event stream and persists events in background.
    private func startEventPersistence() async {
        eventTask = Task {
            let stream = await runtime.eventBus.subscribe()
            for await event in stream {
                await store.persist(event: event)
            }
        }
    }
}

private let embeddedSchemaSQL =
    """
    CREATE TABLE IF NOT EXISTS channels (
        id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        status TEXT NOT NULL,
        title TEXT NOT NULL,
        objective TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        message_type TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        task_id TEXT,
        branch_id TEXT,
        worker_id TEXT,
        payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_events_channel_created ON events(channel_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_events_task_created ON events(task_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS artifacts (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS memory_bulletins (
        id TEXT PRIMARY KEY,
        headline TEXT NOT NULL,
        digest TEXT NOT NULL,
        items_json TEXT NOT NULL,
        created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS token_usage (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        task_id TEXT,
        prompt_tokens INTEGER NOT NULL,
        completion_tokens INTEGER NOT NULL,
        total_tokens INTEGER NOT NULL,
        created_at TEXT NOT NULL
    );
    """

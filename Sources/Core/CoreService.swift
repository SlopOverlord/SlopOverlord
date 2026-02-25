import Foundation
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
            defaultModel: resolvedModels.first
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

        guard openAISettings != nil || ollamaSettings != nil else {
            return nil
        }

        return AnyLanguageModelProviderPlugin(
            id: "any-language-model",
            models: resolvedModels,
            openAI: openAISettings,
            ollama: ollamaSettings,
            systemInstructions: "You are SlopOverlord core channel assistant."
        )
    }

    private static func resolveModelIdentifiers(config: CoreConfig) -> [String] {
        config.models.map(resolvedIdentifier(for:))
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

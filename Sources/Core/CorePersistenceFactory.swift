import Foundation
import Protocols

public protocol CorePersistenceBuilding: Sendable {
    func makeStore(config: CoreConfig) -> any PersistenceStore
}

public struct DefaultCorePersistenceBuilder: CorePersistenceBuilding {
    public init() {}

    public func makeStore(config: CoreConfig) -> any PersistenceStore {
        CorePersistenceFactory.makeStore(config: config)
    }
}

public struct InMemoryCorePersistenceBuilder: CorePersistenceBuilding {
    public init() {}

    public func makeStore(config: CoreConfig) -> any PersistenceStore {
        InMemoryPersistenceStore()
    }
}

public actor InMemoryPersistenceStore: PersistenceStore {
    private var events: [EventEnvelope] = []
    private var tokenUsages: [(channelId: String, taskId: String?, usage: TokenUsage)] = []
    private var bulletins: [MemoryBulletin] = []
    private var artifacts: [String: String] = [:]
    private var artifactRecords: [String: PersistedArtifactRecord] = [:]
    private var channels: [String: PersistedChannelRecord] = [:]
    private var tasks: [String: PersistedTaskRecord] = [:]
    private var projects: [String: ProjectRecord] = [:]

    public init() {}

    public func persist(event: EventEnvelope) async {
        events.append(event)
        upsertChannel(from: event)
        upsertTask(from: event)
    }

    public func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async {
        tokenUsages.append((channelId: channelId, taskId: taskId, usage: usage))
    }

    public func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> [TokenUsageRecord] {
        var result: [TokenUsageRecord] = []
        let formatter = ISO8601DateFormatter()

        for (index, entry) in tokenUsages.enumerated() {
            // Apply filters
            if let channelId, entry.channelId != channelId { continue }
            if let taskId, entry.taskId != taskId { continue }

            // For in-memory store, we don't have exact timestamps per record, use index-based approximation
            // In real implementation, records would have actual timestamps
            let record = TokenUsageRecord(
                id: "mem-\(index)",
                channelId: entry.channelId,
                taskId: entry.taskId,
                promptTokens: entry.usage.prompt,
                completionTokens: entry.usage.completion,
                totalTokens: entry.usage.total,
                createdAt: Date()
            )
            result.append(record)
        }

        return result
    }

    public func persistBulletin(_ bulletin: MemoryBulletin) async {
        bulletins.append(bulletin)
    }

    public func listPersistedEvents() async -> [EventEnvelope] {
        events.sorted { left, right in
            if left.ts == right.ts {
                return left.messageId < right.messageId
            }
            return left.ts < right.ts
        }
    }

    public func listChannelEvents(
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) async -> [EventEnvelope] {
        guard limit > 0 else {
            return []
        }

        let sorted = events
            .filter { $0.channelId == channelId }
            .sorted { left, right in
                if left.ts == right.ts {
                    return left.messageId > right.messageId
                }
                return left.ts > right.ts
            }

        var result: [EventEnvelope] = []
        result.reserveCapacity(max(limit, 0))

        for event in sorted {
            if let before, !(event.ts < before) {
                continue
            }
            if let after, !(event.ts > after) {
                continue
            }
            if let cursor {
                if event.ts > cursor.createdAt {
                    continue
                }
                if event.ts == cursor.createdAt, event.messageId >= cursor.eventId {
                    continue
                }
            }

            result.append(event)
            if result.count >= limit {
                break
            }
        }

        return result
    }

    public func listPersistedChannels() async -> [PersistedChannelRecord] {
        channels.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func listPersistedTasks() async -> [PersistedTaskRecord] {
        tasks.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func listPersistedArtifacts() async -> [PersistedArtifactRecord] {
        artifactRecords.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func persistArtifact(id: String, content: String) async {
        artifacts[id] = content
        let createdAt = artifactRecords[id]?.createdAt ?? Date()
        artifactRecords[id] = PersistedArtifactRecord(id: id, content: content, createdAt: createdAt)
    }

    public func artifactContent(id: String) async -> String? {
        artifacts[id]
    }

    public func listBulletins() async -> [MemoryBulletin] {
        bulletins
    }

    public func listProjects() async -> [ProjectRecord] {
        projects.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func project(id: String) async -> ProjectRecord? {
        projects[id]
    }

    public func saveProject(_ project: ProjectRecord) async {
        projects[project.id] = project
    }

    public func deleteProject(id: String) async {
        projects[id] = nil
    }

    private var channelPlugins: [String: ChannelPluginRecord] = [:]

    public func listChannelPlugins() async -> [ChannelPluginRecord] {
        channelPlugins.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func channelPlugin(id: String) async -> ChannelPluginRecord? {
        channelPlugins[id]
    }

    public func saveChannelPlugin(_ plugin: ChannelPluginRecord) async {
        channelPlugins[plugin.id] = plugin
    }

    public func deleteChannelPlugin(id: String) async {
        channelPlugins[id] = nil
    }

    private func upsertChannel(from event: EventEnvelope) {
        if var existing = channels[event.channelId] {
            existing.updatedAt = max(existing.updatedAt, event.ts)
            channels[event.channelId] = existing
            return
        }

        channels[event.channelId] = PersistedChannelRecord(
            id: event.channelId,
            createdAt: event.ts,
            updatedAt: event.ts
        )
    }

    private func upsertTask(from event: EventEnvelope) {
        guard let taskId = event.taskId, !taskId.isEmpty else {
            return
        }

        let now = event.ts
        let payload = event.payload.objectValue
        let inferredStatus = inferredTaskStatus(from: event.messageType)
        let incomingTitle = payload["title"]?.stringValue ?? payload["progress"]?.stringValue
        let incomingObjective = payload["objective"]?.stringValue

        if var existing = tasks[taskId] {
            existing.channelId = event.channelId
            existing.status = inferredStatus ?? existing.status
            if let incomingTitle, !incomingTitle.isEmpty {
                existing.title = incomingTitle
            }
            if let incomingObjective, !incomingObjective.isEmpty {
                existing.objective = incomingObjective
            }
            existing.updatedAt = max(existing.updatedAt, now)
            tasks[taskId] = existing
            return
        }

        tasks[taskId] = PersistedTaskRecord(
            id: taskId,
            channelId: event.channelId,
            status: inferredStatus ?? "unknown",
            title: incomingTitle ?? "Task \(taskId)",
            objective: incomingObjective ?? "",
            createdAt: now,
            updatedAt: now
        )
    }

    private func inferredTaskStatus(from messageType: MessageType) -> String? {
        switch messageType {
        case .workerSpawned:
            "queued"
        case .workerProgress:
            "running"
        case .workerCompleted:
            "completed"
        case .workerFailed:
            "failed"
        default:
            nil
        }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let object) = self {
            return object
        }
        return [:]
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

enum CorePersistenceFactory {
    static func makeStore(config: CoreConfig) -> any PersistenceStore {
        SQLiteStore(path: config.sqlitePath, schemaSQL: loadSchemaSQL())
    }

    private static func loadSchemaSQL() -> String {
        let fileManager = FileManager.default
        let executablePath = CommandLine.arguments.first ?? ""
        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)

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

        return embeddedSchemaSQL
    }

    private static let embeddedSchemaSQL =
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

        CREATE TABLE IF NOT EXISTS memory_entries (
            id TEXT PRIMARY KEY,
            class TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT NOT NULL,
            summary TEXT,
            scope_type TEXT NOT NULL,
            scope_id TEXT NOT NULL,
            channel_id TEXT,
            project_id TEXT,
            agent_id TEXT,
            importance REAL NOT NULL DEFAULT 0.5,
            confidence REAL NOT NULL DEFAULT 0.7,
            source_type TEXT,
            source_id TEXT,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            expires_at TEXT,
            deleted_at TEXT
        );

        CREATE TABLE IF NOT EXISTS memory_edges (
            id TEXT PRIMARY KEY,
            from_memory_id TEXT NOT NULL,
            to_memory_id TEXT NOT NULL,
            relation TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1.0,
            provenance TEXT,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory_provider_outbox (
            id TEXT PRIMARY KEY,
            memory_id TEXT NOT NULL,
            op TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            attempt INTEGER NOT NULL DEFAULT 0,
            next_retry_at TEXT NOT NULL,
            last_error TEXT,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory_recall_log (
            id TEXT PRIMARY KEY,
            query TEXT NOT NULL,
            scope_type TEXT,
            scope_id TEXT,
            top_k INTEGER NOT NULL,
            result_ids_json TEXT NOT NULL,
            latency_ms INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(
            id UNINDEXED,
            text,
            summary
        );

        CREATE INDEX IF NOT EXISTS idx_memory_entries_scope_time ON memory_entries(scope_type, scope_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_memory_entries_kind ON memory_entries(kind);
        CREATE INDEX IF NOT EXISTS idx_memory_entries_class ON memory_entries(class);
        CREATE INDEX IF NOT EXISTS idx_memory_entries_expires ON memory_entries(expires_at);
        CREATE INDEX IF NOT EXISTS idx_memory_edges_from ON memory_edges(from_memory_id);
        CREATE INDEX IF NOT EXISTS idx_memory_edges_to ON memory_edges(to_memory_id);
        CREATE INDEX IF NOT EXISTS idx_memory_outbox_retry ON memory_provider_outbox(next_retry_at, attempt);

        CREATE TABLE IF NOT EXISTS token_usage (
            id TEXT PRIMARY KEY,
            channel_id TEXT NOT NULL,
            task_id TEXT,
            prompt_tokens INTEGER NOT NULL,
            completion_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS dashboard_projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS dashboard_project_channels (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            title TEXT NOT NULL,
            channel_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            UNIQUE(project_id, channel_id)
        );

        CREATE INDEX IF NOT EXISTS idx_dashboard_project_channels_project ON dashboard_project_channels(project_id);

        CREATE TABLE IF NOT EXISTS dashboard_project_tasks (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            priority TEXT NOT NULL,
            status TEXT NOT NULL,
            actor_id TEXT,
            team_id TEXT,
            claimed_actor_id TEXT,
            claimed_agent_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_dashboard_project_tasks_project ON dashboard_project_tasks(project_id);

        CREATE TABLE IF NOT EXISTS channel_plugins (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            base_url TEXT NOT NULL,
            channel_ids_json TEXT NOT NULL DEFAULT '[]',
            config_json TEXT NOT NULL DEFAULT '{}',
            enabled INTEGER NOT NULL DEFAULT 1,
            delivery_mode TEXT NOT NULL DEFAULT 'http',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """
}

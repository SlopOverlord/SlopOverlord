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

    public func listTokenUsage(channelIds: [String], from: Date?, to: Date?) async -> [TokenUsageRecord] {
        // In-memory store: keep it simple by delegating to per-channel filtering (no timestamps tracked).
        var result: [TokenUsageRecord] = []
        for channelId in channelIds {
            let records = await listTokenUsage(channelId: channelId, taskId: nil, from: from, to: to)
            result.append(contentsOf: records)
        }
        return result
    }

    public func persistToolInvocation(
        id: String,
        projectId: String?,
        taskId: String?,
        agentId: String,
        sessionId: String,
        tool: String,
        ok: Bool,
        durationMs: Int?,
        traceId: String?,
        createdAt: Date
    ) async {
        // Intentionally ignored for in-memory store (used for lightweight dev/testing only).
    }

    public func persistProjectEventFact(
        id: String,
        projectId: String,
        channelId: String,
        messageType: String,
        traceId: String?,
        createdAt: Date
    ) async {
        // Intentionally ignored for in-memory store (used for lightweight dev/testing only).
    }

    public func listProjectEventCounts(projectId: String, from: Date?, to: Date?) async -> [String: Int] {
        [:]
    }

    public func listToolInvocationAggregates(projectId: String, from: Date?, to: Date?) async -> [PersistedToolInvocationAggregate] {
        []
    }

    public func listToolInvocationDurations(projectId: String, from: Date?, to: Date?, limit: Int) async -> [Int] {
        []
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

    public func listProjectSummaries() async -> [ProjectListRecord] {
        projects.values
            .map(Self.projectListRecord)
            .sorted { $0.createdAt < $1.createdAt }
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

    private var cronTasks: [String: AgentCronTask] = [:]

    private static func projectListRecord(_ project: ProjectRecord) -> ProjectListRecord {
        var counts = ProjectTaskCountSummary(total: project.tasks.count)
        for task in project.tasks {
            switch ProjectTaskStatus(rawValue: task.status) {
            case .backlog: counts.backlog += 1
            case .ready: counts.ready += 1
            case .inProgress: counts.inProgress += 1
            case .waitingInput: counts.waitingInput += 1
            case .blocked: counts.blocked += 1
            case .needsReview: counts.needsReview += 1
            case .done: counts.done += 1
            default: break
            }
        }
        return ProjectListRecord(
            id: project.id,
            name: project.name,
            description: project.description,
            icon: project.icon,
            channels: project.channels,
            actors: project.actors,
            teams: project.teams,
            repoPath: project.repoPath,
            taskCounts: counts,
            isFavorite: project.isFavorite,
            isArchived: project.isArchived,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    public func listCronTasks(agentId: String) async -> [AgentCronTask] {
        cronTasks.values.filter { $0.agentId == agentId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func listAllCronTasks() async -> [AgentCronTask] {
        cronTasks.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func cronTask(id: String) async -> AgentCronTask? {
        cronTasks[id]
    }

    public func saveCronTask(_ task: AgentCronTask) async {
        cronTasks[task.id] = task
    }

    public func deleteCronTask(id: String) async {
        cronTasks[id] = nil
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

    private var clarifications: [String: TaskClarificationRecord] = [:]

    public func listClarifications(projectId: String, taskId: String) async -> [TaskClarificationRecord] {
        clarifications.values
            .filter { $0.projectId == projectId && $0.taskId == taskId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func clarification(id: String) async -> TaskClarificationRecord? {
        clarifications[id]
    }

    public func saveClarification(_ record: TaskClarificationRecord) async {
        clarifications[record.id] = record
    }

    public func deleteClarification(id: String) async {
        clarifications[id] = nil
    }

    private var accessUsers: [String: ChannelAccessUser] = [:]

    public func listChannelAccessUsers(platform: String?) async -> [ChannelAccessUser] {
        let all = accessUsers.values.sorted { $0.createdAt < $1.createdAt }
        guard let platform else { return all }
        return all.filter { $0.platform == platform }
    }

    public func channelAccessUser(platform: String, platformUserId: String) async -> ChannelAccessUser? {
        accessUsers.values.first { $0.platform == platform && $0.platformUserId == platformUserId }
    }

    public func saveChannelAccessUser(_ user: ChannelAccessUser) async {
        if let existing = accessUsers.values.first(where: { $0.platform == user.platform && $0.platformUserId == user.platformUserId }) {
            accessUsers[existing.id] = nil
        }
        accessUsers[user.id] = user
    }

    public func deleteChannelAccessUser(id: String) async {
        accessUsers[id] = nil
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

    @discardableResult
    static func prepareSQLiteDatabaseIfNeeded(config: CoreConfig) -> String? {
        guard !FileManager.default.fileExists(atPath: config.sqlitePath) else {
            return nil
        }
        return SQLiteStore.prepareDatabase(path: config.sqlitePath, schemaSQL: loadSchemaSQL())
    }

    private static func loadSchemaSQL() -> String {
        let fileManager = FileManager.default
        let executablePath = CommandLine.arguments.first ?? ""
        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        let candidatePaths = [
            cwd.appendingPathComponent("Sources/sloppy/Storage/schema.sql").path,
            executableDirectory.appendingPathComponent("Sources/sloppy/Storage/schema.sql").path,
            cwd.appendingPathComponent("Sloppy_sloppy.resources/schema.sql").path,
            cwd.appendingPathComponent("Sloppy_sloppy.bundle/schema.sql").path,
            executableDirectory.appendingPathComponent("Sloppy_sloppy.resources/schema.sql").path,
            executableDirectory.appendingPathComponent("Sloppy_sloppy.bundle/schema.sql").path
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

        CREATE TABLE IF NOT EXISTS tool_invocations (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            task_id TEXT,
            agent_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            tool TEXT NOT NULL,
            ok INTEGER NOT NULL,
            duration_ms INTEGER,
            trace_id TEXT,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_tool_invocations_project_created ON tool_invocations(project_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_tool_invocations_tool_created ON tool_invocations(tool, created_at DESC);

        CREATE TABLE IF NOT EXISTS project_event_facts (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            channel_id TEXT NOT NULL,
            message_type TEXT NOT NULL,
            trace_id TEXT,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_project_event_facts_project_created ON project_event_facts(project_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_project_event_facts_project_type_created ON project_event_facts(project_id, message_type, created_at DESC);

        CREATE TABLE IF NOT EXISTS dashboard_projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            actors_json TEXT NOT NULL DEFAULT '[]',
            teams_json TEXT NOT NULL DEFAULT '[]',
            task_sync_settings_json TEXT NOT NULL DEFAULT '{}',
            is_favorite INTEGER NOT NULL DEFAULT 0,
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
            parent_task_id TEXT,
            swarm_id TEXT,
            swarm_task_id TEXT,
            swarm_parent_task_id TEXT,
            swarm_dependency_ids_json TEXT NOT NULL DEFAULT '[]',
            swarm_depth INTEGER,
            swarm_actor_path_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            worktree_branch TEXT,
            kind TEXT,
            loop_mode_override TEXT,
            origin_type TEXT,
            origin_channel_id TEXT,
            is_archived INTEGER NOT NULL DEFAULT 0,
            selected_model TEXT,
            external_metadata_json TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]'
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

        CREATE TABLE IF NOT EXISTS task_clarifications (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            target_type TEXT NOT NULL DEFAULT 'human',
            target_actor_id TEXT,
            target_channel_id TEXT,
            question_text TEXT NOT NULL,
            options_json TEXT NOT NULL DEFAULT '[]',
            allow_note INTEGER NOT NULL DEFAULT 1,
            created_by_agent_id TEXT,
            selected_option_ids_json TEXT NOT NULL DEFAULT '[]',
            note TEXT,
            created_at TEXT NOT NULL,
            answered_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_task_clarifications_task ON task_clarifications(project_id, task_id);

        CREATE TABLE IF NOT EXISTS channel_access_users (
            id TEXT PRIMARY KEY,
            platform TEXT NOT NULL,
            platform_user_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(platform, platform_user_id)
        );

        CREATE INDEX IF NOT EXISTS idx_channel_access_users_platform ON channel_access_users(platform, status);
        """
}

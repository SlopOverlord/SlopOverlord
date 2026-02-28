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
    private var projects: [String: ProjectRecord] = [:]

    public init() {}

    public func persist(event: EventEnvelope) async {
        events.append(event)
    }

    public func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async {
        tokenUsages.append((channelId: channelId, taskId: taskId, usage: usage))
    }

    public func persistBulletin(_ bulletin: MemoryBulletin) async {
        bulletins.append(bulletin)
    }

    public func persistArtifact(id: String, content: String) async {
        artifacts[id] = content
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
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_dashboard_project_tasks_project ON dashboard_project_tasks(project_id);
        """
}

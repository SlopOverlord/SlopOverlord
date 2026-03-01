import Foundation
import Protocols

#if canImport(SQLite3)
import SQLite3
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

/// SQLite-backed persistence store.
/// On Debian and Windows this backend works when `SQLite3` module is available in the toolchain,
/// otherwise the actor automatically falls back to in-memory storage.
public actor SQLiteStore: PersistenceStore {
#if canImport(SQLite3)
    private var db: OpaquePointer?
#endif
    private let isoFormatter = ISO8601DateFormatter()
    private let fallbackProjectsFileURL: URL

    private var fallbackEvents: [EventEnvelope] = []
    private var fallbackBulletins: [MemoryBulletin] = []
    private var fallbackArtifacts: [String: String] = [:]
    private var fallbackProjects: [String: ProjectRecord] = [:]
    private var fallbackPlugins: [String: ChannelPluginRecord] = [:]

    /// Creates a persistence store and applies schema when SQLite is available.
    public init(path: String, schemaSQL: String, fallbackProjectsPath: String? = nil) {
        fallbackProjectsFileURL = Self.resolveFallbackProjectsFileURL(
            sqlitePath: path,
            explicitPath: fallbackProjectsPath
        )
        fallbackProjects = Self.loadFallbackProjects(from: fallbackProjectsFileURL)
#if canImport(SQLite3)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        if sqlite3_open(path, &db) == SQLITE_OK {
            _ = sqlite3_exec(db, schemaSQL, nil, nil, nil)
            Self.applyProjectTaskMigrations(db: db)
            Self.applyChannelPluginMigrations(db: db)
        } else {
            db = nil
        }
#endif
    }

    /// Persists runtime event envelope.
    public func persist(event: EventEnvelope) async {
#if canImport(SQLite3)
        guard let db else {
            fallbackEvents.append(event)
            return
        }

        let sql =
            """
            INSERT INTO events(
                id,
                message_type,
                channel_id,
                task_id,
                branch_id,
                worker_id,
                payload_json,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackEvents.append(event)
            return
        }
        defer { sqlite3_finalize(statement) }

        let payloadData = try? JSONEncoder().encode(event.payload)
        let payloadString = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        bindText(event.messageId, at: 1, statement: statement)
        bindText(event.messageType.rawValue, at: 2, statement: statement)
        bindText(event.channelId, at: 3, statement: statement)
        bindOptionalText(event.taskId, at: 4, statement: statement)
        bindOptionalText(event.branchId, at: 5, statement: statement)
        bindOptionalText(event.workerId, at: 6, statement: statement)
        bindText(payloadString, at: 7, statement: statement)
        bindText(isoFormatter.string(from: event.ts), at: 8, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackEvents.append(event)
        }
#else
        fallbackEvents.append(event)
#endif
    }

    /// Persists prompt/completion token usage metrics.
    public func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async {
#if canImport(SQLite3)
        guard let db else { return }

        let sql =
            """
            INSERT INTO token_usage(
                id,
                channel_id,
                task_id,
                prompt_tokens,
                completion_tokens,
                total_tokens,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(UUID().uuidString, at: 1, statement: statement)
        bindText(channelId, at: 2, statement: statement)
        bindOptionalText(taskId, at: 3, statement: statement)
        sqlite3_bind_int(statement, 4, Int32(usage.prompt))
        sqlite3_bind_int(statement, 5, Int32(usage.completion))
        sqlite3_bind_int(statement, 6, Int32(usage.total))
        bindText(isoFormatter.string(from: Date()), at: 7, statement: statement)

        _ = sqlite3_step(statement)
#endif
    }

    /// Persists generated memory bulletin.
    public func persistBulletin(_ bulletin: MemoryBulletin) async {
#if canImport(SQLite3)
        guard let db else {
            fallbackBulletins.append(bulletin)
            return
        }

        let sql =
            """
            INSERT INTO memory_bulletins(
                id,
                headline,
                digest,
                items_json,
                created_at
            ) VALUES(?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackBulletins.append(bulletin)
            return
        }
        defer { sqlite3_finalize(statement) }

        let itemsJSON = (try? String(data: JSONEncoder().encode(bulletin.items), encoding: .utf8)) ?? "[]"
        bindText(bulletin.id, at: 1, statement: statement)
        bindText(bulletin.headline, at: 2, statement: statement)
        bindText(bulletin.digest, at: 3, statement: statement)
        bindText(itemsJSON, at: 4, statement: statement)
        bindText(isoFormatter.string(from: bulletin.generatedAt), at: 5, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackBulletins.append(bulletin)
        }
#else
        fallbackBulletins.append(bulletin)
#endif
    }

    /// Persists artifact text payload by identifier.
    public func persistArtifact(id: String, content: String) async {
#if canImport(SQLite3)
        guard let db else {
            fallbackArtifacts[id] = content
            return
        }

        let sql =
            """
            INSERT OR REPLACE INTO artifacts(
                id,
                content,
                created_at
            ) VALUES(?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fallbackArtifacts[id] = content
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(id, at: 1, statement: statement)
        bindText(content, at: 2, statement: statement)
        bindText(isoFormatter.string(from: Date()), at: 3, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            fallbackArtifacts[id] = content
        }
#else
        fallbackArtifacts[id] = content
#endif
    }

    /// Returns artifact text payload by identifier.
    public func artifactContent(id: String) async -> String? {
#if canImport(SQLite3)
        if let db {
            let sql =
                """
                SELECT content
                FROM artifacts
                WHERE id = ?
                LIMIT 1;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackArtifacts[id]
            }
            defer { sqlite3_finalize(statement) }

            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                return String(cString: cString)
            }
        }
#endif
        return fallbackArtifacts[id]
    }

    /// Lists recent memory bulletins.
    public func listBulletins() async -> [MemoryBulletin] {
#if canImport(SQLite3)
        guard let db else {
            return fallbackBulletins
        }

        let sql =
            """
            SELECT id, headline, digest, items_json, created_at
            FROM memory_bulletins
            ORDER BY created_at DESC
            LIMIT 100;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackBulletins
        }
        defer { sqlite3_finalize(statement) }

        var result: [MemoryBulletin] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let headlinePtr = sqlite3_column_text(statement, 1),
                let digestPtr = sqlite3_column_text(statement, 2),
                let itemsPtr = sqlite3_column_text(statement, 3),
                let createdAtPtr = sqlite3_column_text(statement, 4)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let headline = String(cString: headlinePtr)
            let digest = String(cString: digestPtr)
            let itemsJSON = String(cString: itemsPtr)
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let itemsData = Data(itemsJSON.utf8)
            let items = (try? JSONDecoder().decode([String].self, from: itemsData)) ?? []

            result.append(
                MemoryBulletin(
                    id: id,
                    generatedAt: createdAt,
                    headline: headline,
                    digest: digest,
                    items: items
                )
            )
        }

        if result.isEmpty {
            return fallbackBulletins
        }
        return result
#else
        return fallbackBulletins
#endif
    }

    public func listProjects() async -> [ProjectRecord] {
#if canImport(SQLite3)
        guard let db else {
            return fallbackProjects.values.sorted { $0.createdAt < $1.createdAt }
        }

        let sql =
            """
            SELECT id, name, description, created_at, updated_at
            FROM dashboard_projects
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return fallbackProjects.values.sorted { $0.createdAt < $1.createdAt }
        }
        defer { sqlite3_finalize(statement) }

        var result: [ProjectRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let namePtr = sqlite3_column_text(statement, 1),
                let descriptionPtr = sqlite3_column_text(statement, 2),
                let createdAtPtr = sqlite3_column_text(statement, 3),
                let updatedAtPtr = sqlite3_column_text(statement, 4)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let name = String(cString: namePtr)
            let description = String(cString: descriptionPtr)
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            let channels = loadProjectChannels(db: db, projectID: id)
            let tasks = loadProjectTasks(db: db, projectID: id)
            result.append(
                ProjectRecord(
                    id: id,
                    name: name,
                    description: description,
                    channels: channels,
                    tasks: tasks,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
#else
        return fallbackProjects.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func project(id: String) async -> ProjectRecord? {
#if canImport(SQLite3)
        if let db {
            let sql =
                """
                SELECT id, name, description, created_at, updated_at
                FROM dashboard_projects
                WHERE id = ?
                LIMIT 1;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackProjects[id]
            }
            defer { sqlite3_finalize(statement) }

            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW,
               let idPtr = sqlite3_column_text(statement, 0),
               let namePtr = sqlite3_column_text(statement, 1),
               let descriptionPtr = sqlite3_column_text(statement, 2),
               let createdAtPtr = sqlite3_column_text(statement, 3),
               let updatedAtPtr = sqlite3_column_text(statement, 4) {
                let projectID = String(cString: idPtr)
                let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
                let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
                return ProjectRecord(
                    id: projectID,
                    name: String(cString: namePtr),
                    description: String(cString: descriptionPtr),
                    channels: loadProjectChannels(db: db, projectID: projectID),
                    tasks: loadProjectTasks(db: db, projectID: projectID),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            }
            return nil
        }
#endif
        return fallbackProjects[id]
    }

    public func saveProject(_ project: ProjectRecord) async {
        fallbackProjects[project.id] = project
        persistFallbackProjectsToDisk()
#if canImport(SQLite3)
        guard let db else {
            return
        }

        let projectSQL =
            """
            INSERT OR REPLACE INTO dashboard_projects(
                id,
                name,
                description,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?);
            """

        var projectStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, projectSQL, -1, &projectStatement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(projectStatement) }

        bindText(project.id, at: 1, statement: projectStatement)
        bindText(project.name, at: 2, statement: projectStatement)
        bindText(project.description, at: 3, statement: projectStatement)
        bindText(isoFormatter.string(from: project.createdAt), at: 4, statement: projectStatement)
        bindText(isoFormatter.string(from: project.updatedAt), at: 5, statement: projectStatement)
        guard sqlite3_step(projectStatement) == SQLITE_DONE else {
            return
        }

        removeProjectChildren(db: db, projectID: project.id)

        let channelSQL =
            """
            INSERT INTO dashboard_project_channels(
                id,
                project_id,
                title,
                channel_id,
                created_at
            ) VALUES(?, ?, ?, ?, ?);
            """

        for channel in project.channels {
            var channelStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, channelSQL, -1, &channelStatement, nil) == SQLITE_OK else {
                continue
            }
            defer { sqlite3_finalize(channelStatement) }
            bindText(channel.id, at: 1, statement: channelStatement)
            bindText(project.id, at: 2, statement: channelStatement)
            bindText(channel.title, at: 3, statement: channelStatement)
            bindText(channel.channelId, at: 4, statement: channelStatement)
            bindText(isoFormatter.string(from: channel.createdAt), at: 5, statement: channelStatement)
            _ = sqlite3_step(channelStatement)
        }

        let taskSQL =
            """
            INSERT INTO dashboard_project_tasks(
                id,
                project_id,
                title,
                description,
                priority,
                status,
                actor_id,
                team_id,
                claimed_actor_id,
                claimed_agent_id,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        for task in project.tasks {
            var taskStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, taskSQL, -1, &taskStatement, nil) == SQLITE_OK else {
                continue
            }
            defer { sqlite3_finalize(taskStatement) }
            bindText(task.id, at: 1, statement: taskStatement)
            bindText(project.id, at: 2, statement: taskStatement)
            bindText(task.title, at: 3, statement: taskStatement)
            bindText(task.description, at: 4, statement: taskStatement)
            bindText(task.priority, at: 5, statement: taskStatement)
            bindText(task.status, at: 6, statement: taskStatement)
            bindOptionalText(task.actorId, at: 7, statement: taskStatement)
            bindOptionalText(task.teamId, at: 8, statement: taskStatement)
            bindOptionalText(task.claimedActorId, at: 9, statement: taskStatement)
            bindOptionalText(task.claimedAgentId, at: 10, statement: taskStatement)
            bindText(isoFormatter.string(from: task.createdAt), at: 11, statement: taskStatement)
            bindText(isoFormatter.string(from: task.updatedAt), at: 12, statement: taskStatement)
            _ = sqlite3_step(taskStatement)
        }
#endif
    }

    public func deleteProject(id: String) async {
        fallbackProjects[id] = nil
        persistFallbackProjectsToDisk()
#if canImport(SQLite3)
        guard let db else {
            return
        }

        removeProjectChildren(db: db, projectID: id)

        let sql =
            """
            DELETE FROM dashboard_projects
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    // MARK: - Channel Plugins

    public func listChannelPlugins() async -> [ChannelPluginRecord] {
#if canImport(SQLite3)
        guard let db else {
            return fallbackPlugins.values.sorted { $0.createdAt < $1.createdAt }
        }
        let result = loadChannelPlugins(db: db)
        if result.isEmpty && !fallbackPlugins.isEmpty {
            return fallbackPlugins.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackPlugins.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func channelPlugin(id: String) async -> ChannelPluginRecord? {
#if canImport(SQLite3)
        if let db {
            let sql =
                """
                SELECT id, type, base_url, channel_ids_json, config_json, enabled, delivery_mode, created_at, updated_at
                FROM channel_plugins
                WHERE id = ?
                LIMIT 1;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return fallbackPlugins[id]
            }
            defer { sqlite3_finalize(statement) }
            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return decodePluginRow(statement: statement)
            }
            return nil
        }
#endif
        return fallbackPlugins[id]
    }

    public func saveChannelPlugin(_ plugin: ChannelPluginRecord) async {
        fallbackPlugins[plugin.id] = plugin
#if canImport(SQLite3)
        guard let db else { return }

        let sql =
            """
            INSERT OR REPLACE INTO channel_plugins(
                id, type, base_url, channel_ids_json, config_json, enabled, delivery_mode, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let channelIdsJSON = (try? String(data: JSONEncoder().encode(plugin.channelIds), encoding: .utf8)) ?? "[]"
        let configJSON = (try? String(data: JSONEncoder().encode(plugin.config), encoding: .utf8)) ?? "{}"

        bindText(plugin.id, at: 1, statement: statement)
        bindText(plugin.type, at: 2, statement: statement)
        bindText(plugin.baseUrl, at: 3, statement: statement)
        bindText(channelIdsJSON, at: 4, statement: statement)
        bindText(configJSON, at: 5, statement: statement)
        sqlite3_bind_int(statement, 6, plugin.enabled ? 1 : 0)
        bindText(plugin.deliveryMode, at: 7, statement: statement)
        bindText(isoFormatter.string(from: plugin.createdAt), at: 8, statement: statement)
        bindText(isoFormatter.string(from: plugin.updatedAt), at: 9, statement: statement)

        _ = sqlite3_step(statement)
#endif
    }

    public func deleteChannelPlugin(id: String) async {
        fallbackPlugins[id] = nil
#if canImport(SQLite3)
        guard let db else { return }

        let sql = "DELETE FROM channel_plugins WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    private func persistFallbackProjectsToDisk() {
        let projects = fallbackProjects.values.sorted { left, right in
            left.createdAt < right.createdAt
        }

        let parentDirectory = fallbackProjectsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(projects) else {
            return
        }

        try? payload.write(to: fallbackProjectsFileURL, options: .atomic)
    }

    private static func resolveFallbackProjectsFileURL(
        sqlitePath: String,
        explicitPath: String?
    ) -> URL {
        if let explicitPath {
            let trimmed = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed)
            }
        }

        let fileManager = FileManager.default
        let sqliteDirectory = URL(fileURLWithPath: sqlitePath).deletingLastPathComponent().path
        let sqliteFileName = URL(fileURLWithPath: sqlitePath).lastPathComponent
        let fallbackFileName: String
        if sqliteFileName.isEmpty {
            fallbackFileName = "dashboard-projects-fallback.json"
        } else {
            fallbackFileName = "\(sqliteFileName).dashboard-projects-fallback.json"
        }
        if fileManager.isWritableFile(atPath: sqliteDirectory) {
            return URL(fileURLWithPath: sqliteDirectory, isDirectory: true)
                .appendingPathComponent(fallbackFileName)
        }

        let dataDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".data", isDirectory: true)
        return dataDirectory.appendingPathComponent(fallbackFileName)
    }

    private static func loadFallbackProjects(from fileURL: URL) -> [String: ProjectRecord] {
        guard let payload = try? Data(contentsOf: fileURL) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ProjectRecord].self, from: payload) else {
            return [:]
        }

        var map: [String: ProjectRecord] = [:]
        for project in decoded {
            map[project.id] = project
        }
        return map
    }

#if canImport(SQLite3)
    private func removeProjectChildren(db: OpaquePointer, projectID: String) {
        let deleteChannelsSQL =
            """
            DELETE FROM dashboard_project_channels
            WHERE project_id = ?;
            """
        var channelsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteChannelsSQL, -1, &channelsStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(channelsStatement) }
            bindText(projectID, at: 1, statement: channelsStatement)
            _ = sqlite3_step(channelsStatement)
        }

        let deleteTasksSQL =
            """
            DELETE FROM dashboard_project_tasks
            WHERE project_id = ?;
            """
        var tasksStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteTasksSQL, -1, &tasksStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(tasksStatement) }
            bindText(projectID, at: 1, statement: tasksStatement)
            _ = sqlite3_step(tasksStatement)
        }
    }

    private func loadProjectChannels(db: OpaquePointer, projectID: String) -> [ProjectChannel] {
        let sql =
            """
            SELECT id, title, channel_id, created_at
            FROM dashboard_project_channels
            WHERE project_id = ?
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bindText(projectID, at: 1, statement: statement)

        var result: [ProjectChannel] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let titlePtr = sqlite3_column_text(statement, 1),
                let channelIDPtr = sqlite3_column_text(statement, 2),
                let createdAtPtr = sqlite3_column_text(statement, 3)
            else {
                continue
            }
            result.append(
                ProjectChannel(
                    id: String(cString: idPtr),
                    title: String(cString: titlePtr),
                    channelId: String(cString: channelIDPtr),
                    createdAt: isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
                )
            )
        }

        return result
    }

    private func loadProjectTasks(db: OpaquePointer, projectID: String) -> [ProjectTask] {
        let sql =
            """
            SELECT
                id,
                title,
                description,
                priority,
                status,
                actor_id,
                team_id,
                claimed_actor_id,
                claimed_agent_id,
                created_at,
                updated_at
            FROM dashboard_project_tasks
            WHERE project_id = ?
            ORDER BY created_at ASC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bindText(projectID, at: 1, statement: statement)

        var result: [ProjectTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let titlePtr = sqlite3_column_text(statement, 1),
                let descriptionPtr = sqlite3_column_text(statement, 2),
                let priorityPtr = sqlite3_column_text(statement, 3),
                let statusPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 9),
                let updatedAtPtr = sqlite3_column_text(statement, 10)
            else {
                continue
            }
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            result.append(
                ProjectTask(
                    id: String(cString: idPtr),
                    title: String(cString: titlePtr),
                    description: String(cString: descriptionPtr),
                    priority: String(cString: priorityPtr),
                    status: String(cString: statusPtr),
                    actorId: optionalText(statement: statement, index: 5),
                    teamId: optionalText(statement: statement, index: 6),
                    claimedActorId: optionalText(statement: statement, index: 7),
                    claimedAgentId: optionalText(statement: statement, index: 8),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
    }

    private func bindText(_ value: String, at index: Int32, statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func bindOptionalText(_ value: String?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            bindText(value, at: index, statement: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func optionalText(statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private static func applyProjectTaskMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }

        let statements = [
            "ALTER TABLE dashboard_project_tasks ADD COLUMN actor_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN team_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN claimed_actor_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN claimed_agent_id TEXT;"
        ]

        for statement in statements {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    private static func applyChannelPluginMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE channel_plugins ADD COLUMN delivery_mode TEXT NOT NULL DEFAULT 'http';",
            nil, nil, nil
        )
    }

    private func loadChannelPlugins(db: OpaquePointer) -> [ChannelPluginRecord] {
        let sql =
            """
            SELECT id, type, base_url, channel_ids_json, config_json, enabled, delivery_mode, created_at, updated_at
            FROM channel_plugins
            ORDER BY created_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var result: [ChannelPluginRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decodePluginRow(statement: statement) {
                result.append(record)
            }
        }
        return result
    }

    private func decodePluginRow(statement: OpaquePointer?) -> ChannelPluginRecord? {
        guard
            let idPtr = sqlite3_column_text(statement, 0),
            let typePtr = sqlite3_column_text(statement, 1),
            let baseUrlPtr = sqlite3_column_text(statement, 2),
            let channelIdsPtr = sqlite3_column_text(statement, 3),
            let configPtr = sqlite3_column_text(statement, 4),
            let createdAtPtr = sqlite3_column_text(statement, 7),
            let updatedAtPtr = sqlite3_column_text(statement, 8)
        else {
            return nil
        }

        let enabled = sqlite3_column_int(statement, 5) != 0
        let deliveryModePtr = sqlite3_column_text(statement, 6)
        let deliveryMode = deliveryModePtr.map { String(cString: $0) } ?? ChannelPluginRecord.DeliveryMode.http
        let channelIds = (try? JSONDecoder().decode([String].self, from: Data(String(cString: channelIdsPtr).utf8))) ?? []
        let config = (try? JSONDecoder().decode([String: String].self, from: Data(String(cString: configPtr).utf8))) ?? [:]
        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

        return ChannelPluginRecord(
            id: String(cString: idPtr),
            type: String(cString: typePtr),
            baseUrl: String(cString: baseUrlPtr),
            channelIds: channelIds,
            config: config,
            enabled: enabled,
            deliveryMode: deliveryMode,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
#endif
}

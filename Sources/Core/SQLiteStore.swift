import Foundation
import Protocols

#if canImport(CSQLite3)
import CSQLite3
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

/// SQLite-backed persistence store.
/// This backend works when the package `CSQLite3` system module can import `sqlite3`,
/// otherwise the actor automatically falls back to in-memory storage.
public actor SQLiteStore: PersistenceStore {
#if canImport(CSQLite3)
    private var db: OpaquePointer?
#endif
    private let isoFormatter = ISO8601DateFormatter()
    private let fallbackProjectsFileURL: URL

    private var fallbackEvents: [EventEnvelope] = []
    private var fallbackBulletins: [MemoryBulletin] = []
    private var fallbackArtifacts: [String: PersistedArtifactRecord] = [:]
    private var fallbackChannels: [String: PersistedChannelRecord] = [:]
    private var fallbackTasks: [String: PersistedTaskRecord] = [:]
    private var fallbackProjects: [String: ProjectRecord] = [:]
    private var fallbackPlugins: [String: ChannelPluginRecord] = [:]
    private var fallbackCronTasks: [String: AgentCronTask] = [:]

    /// Creates a persistence store and applies schema when SQLite is available.
    public init(path: String, schemaSQL: String, fallbackProjectsPath: String? = nil) {
        fallbackProjectsFileURL = Self.resolveFallbackProjectsFileURL(
            sqlitePath: path,
            explicitPath: fallbackProjectsPath
        )
        fallbackProjects = Self.loadFallbackProjects(from: fallbackProjectsFileURL)
#if canImport(CSQLite3)
        self.db = Self.openDatabase(path: path, schemaSQL: schemaSQL).0
#endif
    }

    @discardableResult
    static func prepareDatabase(path: String, schemaSQL: String) -> String? {
#if canImport(CSQLite3)
        let (db, error) = openDatabase(path: path, schemaSQL: schemaSQL)
        if let db {
            sqlite3_close(db)
            return nil
        }
        return error ?? "Unknown SQLite initialization error"
#else
        return "SQLite3 is not available on this platform"
#endif
    }

    /// Persists runtime event envelope.
    public func persist(event: EventEnvelope) async {
#if canImport(CSQLite3)
        guard let db else {
            persistFallbackEvent(event)
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
                extensions_json,
                created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            persistFallbackEvent(event)
            return
        }
        defer { sqlite3_finalize(statement) }

        let payloadData = try? JSONEncoder().encode(event.payload)
        let payloadString = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let extensionsData = try? JSONEncoder().encode(event.extensions)
        let extensionsString = extensionsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        bindText(event.messageId, at: 1, statement: statement)
        bindText(event.messageType.rawValue, at: 2, statement: statement)
        bindText(event.channelId, at: 3, statement: statement)
        bindOptionalText(event.taskId, at: 4, statement: statement)
        bindOptionalText(event.branchId, at: 5, statement: statement)
        bindOptionalText(event.workerId, at: 6, statement: statement)
        bindText(payloadString, at: 7, statement: statement)
        bindText(extensionsString, at: 8, statement: statement)
        bindText(isoFormatter.string(from: event.ts), at: 9, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            persistFallbackEvent(event)
            return
        }

        upsertChannel(db: db, channelId: event.channelId, timestamp: event.ts)
        upsertTask(db: db, event: event)
#else
        persistFallbackEvent(event)
#endif
    }

    /// Persists prompt/completion token usage metrics.
    public func persistTokenUsage(channelId: String, taskId: String?, usage: TokenUsage) async {
#if canImport(CSQLite3)
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

    /// Lists token usage records with optional filters.
    public func listTokenUsage(channelId: String?, taskId: String?, from: Date?, to: Date?) async -> [TokenUsageRecord] {
#if canImport(CSQLite3)
        guard let db else { return [] }

        var conditions: [String] = []
        if channelId != nil { conditions.append("channel_id = ?") }
        if taskId != nil { conditions.append("task_id = ?") }
        if from != nil { conditions.append("created_at >= ?") }
        if to != nil { conditions.append("created_at <= ?") }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql =
            """
            SELECT id, channel_id, task_id, prompt_tokens, completion_tokens, total_tokens, created_at
            FROM token_usage
            \(whereClause)
            ORDER BY created_at DESC
            LIMIT 1000;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        if let channelId {
            bindText(channelId, at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let taskId {
            bindOptionalText(taskId, at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let from {
            bindText(isoFormatter.string(from: from), at: paramIndex, statement: statement)
            paramIndex += 1
        }
        if let to {
            bindText(isoFormatter.string(from: to), at: paramIndex, statement: statement)
        }

        var result: [TokenUsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let channelIdPtr = sqlite3_column_text(statement, 1),
                let createdAtPtr = sqlite3_column_text(statement, 6)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let recordChannelId = String(cString: channelIdPtr)
            let taskId = optionalText(statement: statement, index: 2)
            let promptTokens = Int(sqlite3_column_int(statement, 3))
            let completionTokens = Int(sqlite3_column_int(statement, 4))
            let totalTokens = Int(sqlite3_column_int(statement, 5))
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()

            result.append(
                TokenUsageRecord(
                    id: id,
                    channelId: recordChannelId,
                    taskId: taskId,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: totalTokens,
                    createdAt: createdAt
                )
            )
        }

        return result
#else
        return []
#endif
    }

    /// Persists generated memory bulletin.
    public func persistBulletin(_ bulletin: MemoryBulletin) async {
#if canImport(CSQLite3)
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

    /// Lists persisted events in deterministic replay order.
    public func listPersistedEvents() async -> [EventEnvelope] {
#if canImport(CSQLite3)
        guard let db else {
            return sortedFallbackEvents()
        }

        let result = loadPersistedEvents(db: db)
        if result.isEmpty && !fallbackEvents.isEmpty {
            return sortedFallbackEvents()
        }
        return result
#else
        return sortedFallbackEvents()
#endif
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
#if canImport(CSQLite3)
        guard let db else {
            return filteredFallbackChannelEvents(
                channelId: channelId,
                limit: limit,
                cursor: cursor,
                before: before,
                after: after
            )
        }

        let result = loadChannelEvents(
            db: db,
            channelId: channelId,
            limit: limit,
            cursor: cursor,
            before: before,
            after: after
        )
        if result.isEmpty && !fallbackEvents.isEmpty {
            return filteredFallbackChannelEvents(
                channelId: channelId,
                limit: limit,
                cursor: cursor,
                before: before,
                after: after
            )
        }
        return result
#else
        return filteredFallbackChannelEvents(
            channelId: channelId,
            limit: limit,
            cursor: cursor,
            before: before,
            after: after
        )
#endif
    }

    /// Lists persisted channels in creation order.
    public func listPersistedChannels() async -> [PersistedChannelRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackChannels.values.sorted { $0.createdAt < $1.createdAt }
        }

        let result = loadPersistedChannels(db: db)
        if result.isEmpty && !fallbackChannels.isEmpty {
            return fallbackChannels.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackChannels.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    /// Lists persisted task rows in creation order.
    public func listPersistedTasks() async -> [PersistedTaskRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackTasks.values.sorted { $0.createdAt < $1.createdAt }
        }

        let result = loadPersistedTasks(db: db)
        if result.isEmpty && !fallbackTasks.isEmpty {
            return fallbackTasks.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackTasks.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    /// Lists persisted artifacts in creation order.
    public func listPersistedArtifacts() async -> [PersistedArtifactRecord] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackArtifacts.values.sorted { $0.createdAt < $1.createdAt }
        }

        let result = loadPersistedArtifacts(db: db)
        if result.isEmpty && !fallbackArtifacts.isEmpty {
            return fallbackArtifacts.values.sorted { $0.createdAt < $1.createdAt }
        }
        return result
#else
        return fallbackArtifacts.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    /// Persists artifact text payload by identifier.
    public func persistArtifact(id: String, content: String) async {
#if canImport(CSQLite3)
        guard let db else {
            persistFallbackArtifact(id: id, content: content, createdAt: Date())
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
            persistFallbackArtifact(id: id, content: content, createdAt: Date())
            return
        }
        defer { sqlite3_finalize(statement) }

        let createdAt = Date()
        bindText(id, at: 1, statement: statement)
        bindText(content, at: 2, statement: statement)
        bindText(isoFormatter.string(from: createdAt), at: 3, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            persistFallbackArtifact(id: id, content: content, createdAt: createdAt)
        }
#else
        persistFallbackArtifact(id: id, content: content, createdAt: Date())
#endif
    }

    /// Returns artifact text payload by identifier.
    public func artifactContent(id: String) async -> String? {
#if canImport(CSQLite3)
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
                return fallbackArtifacts[id]?.content
            }
            defer { sqlite3_finalize(statement) }

            bindText(id, at: 1, statement: statement)
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                return String(cString: cString)
            }
        }
#endif
        return fallbackArtifacts[id]?.content
    }

    /// Lists recent memory bulletins.
    public func listBulletins() async -> [MemoryBulletin] {
#if canImport(CSQLite3)
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
#if canImport(CSQLite3)
        guard let db else {
            return fallbackProjects.values.sorted { $0.createdAt < $1.createdAt }
        }

        let sql =
            """
            SELECT id, name, description, actors_json, teams_json, created_at, updated_at
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
                let actorsPtr = sqlite3_column_text(statement, 3),
                let teamsPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 5),
                let updatedAtPtr = sqlite3_column_text(statement, 6)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let name = String(cString: namePtr)
            let description = String(cString: descriptionPtr)
            let actorsJSON = String(cString: actorsPtr)
            let teamsJSON = String(cString: teamsPtr)
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            let actors = (try? JSONDecoder().decode([String].self, from: Data(actorsJSON.utf8))) ?? []
            let teams = (try? JSONDecoder().decode([String].self, from: Data(teamsJSON.utf8))) ?? []
            let channels = loadProjectChannels(db: db, projectID: id)
            let tasks = loadProjectTasks(db: db, projectID: id)
            result.append(
                ProjectRecord(
                    id: id,
                    name: name,
                    description: description,
                    channels: channels,
                    tasks: tasks,
                    actors: actors,
                    teams: teams,
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
#if canImport(CSQLite3)
        if let db {
            let sql =
                """
                SELECT id, name, description, actors_json, teams_json, created_at, updated_at
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
               let actorsPtr = sqlite3_column_text(statement, 3),
               let teamsPtr = sqlite3_column_text(statement, 4),
               let createdAtPtr = sqlite3_column_text(statement, 5),
               let updatedAtPtr = sqlite3_column_text(statement, 6) {
                let projectID = String(cString: idPtr)
                let actorsJSON = String(cString: actorsPtr)
                let teamsJSON = String(cString: teamsPtr)
                let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
                let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
                let actors = (try? JSONDecoder().decode([String].self, from: Data(actorsJSON.utf8))) ?? []
                let teams = (try? JSONDecoder().decode([String].self, from: Data(teamsJSON.utf8))) ?? []
                return ProjectRecord(
                    id: projectID,
                    name: String(cString: namePtr),
                    description: String(cString: descriptionPtr),
                    channels: loadProjectChannels(db: db, projectID: projectID),
                    tasks: loadProjectTasks(db: db, projectID: projectID),
                    actors: actors,
                    teams: teams,
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
#if canImport(CSQLite3)
        guard let db else {
            return
        }

        let projectSQL =
            """
            INSERT OR REPLACE INTO dashboard_projects(
                id,
                name,
                description,
                actors_json,
                teams_json,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """

        var projectStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, projectSQL, -1, &projectStatement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(projectStatement) }

        let actorsJSON = (try? String(data: JSONEncoder().encode(project.actors), encoding: .utf8)) ?? "[]"
        let teamsJSON = (try? String(data: JSONEncoder().encode(project.teams), encoding: .utf8)) ?? "[]"

        bindText(project.id, at: 1, statement: projectStatement)
        bindText(project.name, at: 2, statement: projectStatement)
        bindText(project.description, at: 3, statement: projectStatement)
        bindText(actorsJSON, at: 4, statement: projectStatement)
        bindText(teamsJSON, at: 5, statement: projectStatement)
        bindText(isoFormatter.string(from: project.createdAt), at: 6, statement: projectStatement)
        bindText(isoFormatter.string(from: project.updatedAt), at: 7, statement: projectStatement)
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
                swarm_id,
                swarm_task_id,
                swarm_parent_task_id,
                swarm_dependency_ids_json,
                swarm_depth,
                swarm_actor_path_json,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        for task in project.tasks {
            var taskStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, taskSQL, -1, &taskStatement, nil) == SQLITE_OK else {
                continue
            }
            defer { sqlite3_finalize(taskStatement) }
            let dependencyIdsJSON = encodedStringArray(task.swarmDependencyIds ?? [])
            let actorPathJSON = encodedStringArray(task.swarmActorPath ?? [])
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
            bindOptionalText(task.swarmId, at: 11, statement: taskStatement)
            bindOptionalText(task.swarmTaskId, at: 12, statement: taskStatement)
            bindOptionalText(task.swarmParentTaskId, at: 13, statement: taskStatement)
            bindText(dependencyIdsJSON, at: 14, statement: taskStatement)
            if let swarmDepth = task.swarmDepth {
                sqlite3_bind_int(taskStatement, 15, Int32(swarmDepth))
            } else {
                sqlite3_bind_null(taskStatement, 15)
            }
            bindText(actorPathJSON, at: 16, statement: taskStatement)
            bindText(isoFormatter.string(from: task.createdAt), at: 17, statement: taskStatement)
            bindText(isoFormatter.string(from: task.updatedAt), at: 18, statement: taskStatement)
            _ = sqlite3_step(taskStatement)
        }
#endif
    }

    public func deleteProject(id: String) async {
        fallbackProjects[id] = nil
        persistFallbackProjectsToDisk()
#if canImport(CSQLite3)
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
#if canImport(CSQLite3)
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
#if canImport(CSQLite3)
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
#if canImport(CSQLite3)
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
#if canImport(CSQLite3)
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

    private func sortedFallbackEvents() -> [EventEnvelope] {
        fallbackEvents.sorted { left, right in
            if left.ts == right.ts {
                return left.messageId < right.messageId
            }
            return left.ts < right.ts
        }
    }

    private func filteredFallbackChannelEvents(
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) -> [EventEnvelope] {
        var filtered = fallbackEvents
            .filter { $0.channelId == channelId }
            .sorted { left, right in
                if left.ts == right.ts {
                    return left.messageId > right.messageId
                }
                return left.ts > right.ts
            }

        filtered.removeAll { event in
            if let before, !(event.ts < before) {
                return true
            }
            if let after, !(event.ts > after) {
                return true
            }
            if let cursor {
                if event.ts > cursor.createdAt {
                    return true
                }
                if event.ts == cursor.createdAt, event.messageId >= cursor.eventId {
                    return true
                }
            }
            return false
        }

        return Array(filtered.prefix(limit))
    }

    private func persistFallbackEvent(_ event: EventEnvelope) {
        fallbackEvents.append(event)
        upsertFallbackChannel(channelId: event.channelId, timestamp: event.ts)
        upsertFallbackTask(event: event)
    }

    private func persistFallbackArtifact(id: String, content: String, createdAt: Date) {
        let preservedCreatedAt = fallbackArtifacts[id]?.createdAt ?? createdAt
        fallbackArtifacts[id] = PersistedArtifactRecord(
            id: id,
            content: content,
            createdAt: preservedCreatedAt
        )
    }

    private func upsertFallbackChannel(channelId: String, timestamp: Date) {
        if var existing = fallbackChannels[channelId] {
            existing.updatedAt = max(existing.updatedAt, timestamp)
            fallbackChannels[channelId] = existing
            return
        }

        fallbackChannels[channelId] = PersistedChannelRecord(
            id: channelId,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func upsertFallbackTask(event: EventEnvelope) {
        guard let taskID = event.taskId, !taskID.isEmpty else {
            return
        }

        let payload = event.payload.objectValue
        let status = inferredTaskStatus(from: event.messageType)
        let title = payload["title"]?.stringValue ?? payload["progress"]?.stringValue
        let objective = payload["objective"]?.stringValue

        if var existing = fallbackTasks[taskID] {
            existing.channelId = event.channelId
            existing.status = status ?? existing.status
            if let title, !title.isEmpty {
                existing.title = title
            }
            if let objective, !objective.isEmpty {
                existing.objective = objective
            }
            existing.updatedAt = max(existing.updatedAt, event.ts)
            fallbackTasks[taskID] = existing
            return
        }

        fallbackTasks[taskID] = PersistedTaskRecord(
            id: taskID,
            channelId: event.channelId,
            status: status ?? "unknown",
            title: title ?? "Task \(taskID)",
            objective: objective ?? "",
            createdAt: event.ts,
            updatedAt: event.ts
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

#if canImport(CSQLite3)
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
                swarm_id,
                swarm_task_id,
                swarm_parent_task_id,
                swarm_dependency_ids_json,
                swarm_depth,
                swarm_actor_path_json,
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
                let createdAtPtr = sqlite3_column_text(statement, 15),
                let updatedAtPtr = sqlite3_column_text(statement, 16)
            else {
                continue
            }
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            let dependencyIds = decodeOptionalStringArray(optionalText(statement: statement, index: 12))
            let actorPath = decodeOptionalStringArray(optionalText(statement: statement, index: 14))
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
                    swarmId: optionalText(statement: statement, index: 9),
                    swarmTaskId: optionalText(statement: statement, index: 10),
                    swarmParentTaskId: optionalText(statement: statement, index: 11),
                    swarmDependencyIds: dependencyIds,
                    swarmDepth: optionalInt(statement: statement, index: 13),
                    swarmActorPath: actorPath,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
    }

    private func loadPersistedEvents(db: OpaquePointer) -> [EventEnvelope] {
        let sql =
            """
            SELECT id, message_type, channel_id, task_id, branch_id, worker_id, payload_json, extensions_json, created_at
            FROM events
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [EventEnvelope] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let messageTypePtr = sqlite3_column_text(statement, 1),
                let channelIDPtr = sqlite3_column_text(statement, 2),
                let payloadPtr = sqlite3_column_text(statement, 6),
                let extensionsPtr = sqlite3_column_text(statement, 7),
                let createdAtPtr = sqlite3_column_text(statement, 8)
            else {
                continue
            }

            let messageID = String(cString: idPtr)
            let rawMessageType = String(cString: messageTypePtr)
            guard let messageType = MessageType(rawValue: rawMessageType) else {
                continue
            }

            let timestamp = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let payloadJSON = String(cString: payloadPtr)
            let payloadData = Data(payloadJSON.utf8)
            let payload = (try? JSONDecoder().decode(JSONValue.self, from: payloadData)) ?? .object([:])
            let extensionsJSON = String(cString: extensionsPtr)
            let extensionsData = Data(extensionsJSON.utf8)
            let extensions = (try? JSONDecoder().decode([String: JSONValue].self, from: extensionsData)) ?? [:]

            result.append(
                EventEnvelope(
                    messageId: messageID,
                    messageType: messageType,
                    ts: timestamp,
                    traceId: messageID,
                    channelId: String(cString: channelIDPtr),
                    taskId: optionalText(statement: statement, index: 3),
                    branchId: optionalText(statement: statement, index: 4),
                    workerId: optionalText(statement: statement, index: 5),
                    payload: payload,
                    extensions: extensions
                )
            )
        }

        return result
    }

    private func loadChannelEvents(
        db: OpaquePointer,
        channelId: String,
        limit: Int,
        cursor: PersistedEventCursor?,
        before: Date?,
        after: Date?
    ) -> [EventEnvelope] {
        var conditions: [String] = ["channel_id = ?"]
        if before != nil {
            conditions.append("created_at < ?")
        }
        if after != nil {
            conditions.append("created_at > ?")
        }
        if cursor != nil {
            conditions.append("(created_at < ? OR (created_at = ? AND id < ?))")
        }

        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
        let sql =
            """
            SELECT id, message_type, channel_id, task_id, branch_id, worker_id, payload_json, extensions_json, created_at
            FROM events
            \(whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var parameter: Int32 = 1
        bindText(channelId, at: parameter, statement: statement)
        parameter += 1

        if let before {
            bindText(isoFormatter.string(from: before), at: parameter, statement: statement)
            parameter += 1
        }
        if let after {
            bindText(isoFormatter.string(from: after), at: parameter, statement: statement)
            parameter += 1
        }
        if let cursor {
            let cursorTimestamp = isoFormatter.string(from: cursor.createdAt)
            bindText(cursorTimestamp, at: parameter, statement: statement)
            parameter += 1
            bindText(cursorTimestamp, at: parameter, statement: statement)
            parameter += 1
            bindText(cursor.eventId, at: parameter, statement: statement)
            parameter += 1
        }

        sqlite3_bind_int(statement, parameter, Int32(limit))

        var result: [EventEnvelope] = []
        result.reserveCapacity(limit)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let messageTypePtr = sqlite3_column_text(statement, 1),
                let channelIDPtr = sqlite3_column_text(statement, 2),
                let payloadPtr = sqlite3_column_text(statement, 6),
                let extensionsPtr = sqlite3_column_text(statement, 7),
                let createdAtPtr = sqlite3_column_text(statement, 8)
            else {
                continue
            }

            let messageID = String(cString: idPtr)
            let rawMessageType = String(cString: messageTypePtr)
            guard let messageType = MessageType(rawValue: rawMessageType) else {
                continue
            }

            let timestamp = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let payloadJSON = String(cString: payloadPtr)
            let payloadData = Data(payloadJSON.utf8)
            let payload = (try? JSONDecoder().decode(JSONValue.self, from: payloadData)) ?? .object([:])
            let extensionsJSON = String(cString: extensionsPtr)
            let extensionsData = Data(extensionsJSON.utf8)
            let extensions = (try? JSONDecoder().decode([String: JSONValue].self, from: extensionsData)) ?? [:]

            result.append(
                EventEnvelope(
                    messageId: messageID,
                    messageType: messageType,
                    ts: timestamp,
                    traceId: messageID,
                    channelId: String(cString: channelIDPtr),
                    taskId: optionalText(statement: statement, index: 3),
                    branchId: optionalText(statement: statement, index: 4),
                    workerId: optionalText(statement: statement, index: 5),
                    payload: payload,
                    extensions: extensions
                )
            )
        }

        return result
    }

    private func loadPersistedChannels(db: OpaquePointer) -> [PersistedChannelRecord] {
        let sql =
            """
            SELECT id, created_at, updated_at
            FROM channels
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [PersistedChannelRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let createdAtPtr = sqlite3_column_text(statement, 1),
                let updatedAtPtr = sqlite3_column_text(statement, 2)
            else {
                continue
            }
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            result.append(
                PersistedChannelRecord(
                    id: String(cString: idPtr),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
    }

    private func loadPersistedTasks(db: OpaquePointer) -> [PersistedTaskRecord] {
        let sql =
            """
            SELECT id, channel_id, status, title, objective, created_at, updated_at
            FROM tasks
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [PersistedTaskRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let channelIDPtr = sqlite3_column_text(statement, 1),
                let statusPtr = sqlite3_column_text(statement, 2),
                let titlePtr = sqlite3_column_text(statement, 3),
                let objectivePtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 5),
                let updatedAtPtr = sqlite3_column_text(statement, 6)
            else {
                continue
            }

            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
            result.append(
                PersistedTaskRecord(
                    id: String(cString: idPtr),
                    channelId: String(cString: channelIDPtr),
                    status: String(cString: statusPtr),
                    title: String(cString: titlePtr),
                    objective: String(cString: objectivePtr),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return result
    }

    private func loadPersistedArtifacts(db: OpaquePointer) -> [PersistedArtifactRecord] {
        let sql =
            """
            SELECT id, content, created_at
            FROM artifacts
            ORDER BY created_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [PersistedArtifactRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let contentPtr = sqlite3_column_text(statement, 1),
                let createdAtPtr = sqlite3_column_text(statement, 2)
            else {
                continue
            }

            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            result.append(
                PersistedArtifactRecord(
                    id: String(cString: idPtr),
                    content: String(cString: contentPtr),
                    createdAt: createdAt
                )
            )
        }

        return result
    }

    private func upsertChannel(db: OpaquePointer, channelId: String, timestamp: Date) {
        let createdAtText = isoFormatter.string(from: timestamp)
        let updatedAtText = createdAtText
        let insertSQL =
            """
            INSERT OR IGNORE INTO channels(id, created_at, updated_at)
            VALUES(?, ?, ?);
            """
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(insertStatement) }
            bindText(channelId, at: 1, statement: insertStatement)
            bindText(createdAtText, at: 2, statement: insertStatement)
            bindText(updatedAtText, at: 3, statement: insertStatement)
            _ = sqlite3_step(insertStatement)
        }

        let updateSQL =
            """
            UPDATE channels
            SET updated_at = ?
            WHERE id = ?;
            """
        var updateStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(updateStatement) }
            bindText(updatedAtText, at: 1, statement: updateStatement)
            bindText(channelId, at: 2, statement: updateStatement)
            _ = sqlite3_step(updateStatement)
        }
    }

    private func upsertTask(db: OpaquePointer, event: EventEnvelope) {
        guard let taskID = event.taskId, !taskID.isEmpty else {
            return
        }

        let existing = loadPersistedTask(db: db, taskID: taskID)
        let payload = event.payload.objectValue
        let status = inferredTaskStatus(from: event.messageType) ?? existing?.status ?? "unknown"
        let title = payload["title"]?.stringValue ?? payload["progress"]?.stringValue ?? existing?.title ?? "Task \(taskID)"
        let objective = payload["objective"]?.stringValue ?? existing?.objective ?? ""
        let createdAt = existing?.createdAt ?? event.ts
        let updatedAt = max(existing?.updatedAt ?? event.ts, event.ts)

        let sql =
            """
            INSERT OR REPLACE INTO tasks(
                id,
                channel_id,
                status,
                title,
                objective,
                created_at,
                updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            upsertFallbackTask(event: event)
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(taskID, at: 1, statement: statement)
        bindText(event.channelId, at: 2, statement: statement)
        bindText(status, at: 3, statement: statement)
        bindText(title, at: 4, statement: statement)
        bindText(objective, at: 5, statement: statement)
        bindText(isoFormatter.string(from: createdAt), at: 6, statement: statement)
        bindText(isoFormatter.string(from: updatedAt), at: 7, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE {
            upsertFallbackTask(event: event)
        }
    }

    private func loadPersistedTask(db: OpaquePointer, taskID: String) -> PersistedTaskRecord? {
        let sql =
            """
            SELECT id, channel_id, status, title, objective, created_at, updated_at
            FROM tasks
            WHERE id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bindText(taskID, at: 1, statement: statement)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let idPtr = sqlite3_column_text(statement, 0),
              let channelIDPtr = sqlite3_column_text(statement, 1),
              let statusPtr = sqlite3_column_text(statement, 2),
              let titlePtr = sqlite3_column_text(statement, 3),
              let objectivePtr = sqlite3_column_text(statement, 4),
              let createdAtPtr = sqlite3_column_text(statement, 5),
              let updatedAtPtr = sqlite3_column_text(statement, 6)
        else {
            return nil
        }

        let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt
        return PersistedTaskRecord(
            id: String(cString: idPtr),
            channelId: String(cString: channelIDPtr),
            status: String(cString: statusPtr),
            title: String(cString: titlePtr),
            objective: String(cString: objectivePtr),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
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

    private func optionalInt(statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private static func applyProjectTaskMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }

        let statements = [
            "ALTER TABLE dashboard_project_tasks ADD COLUMN actor_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN team_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN claimed_actor_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN claimed_agent_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_task_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_parent_task_id TEXT;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_dependency_ids_json TEXT NOT NULL DEFAULT '[]';",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_depth INTEGER;",
            "ALTER TABLE dashboard_project_tasks ADD COLUMN swarm_actor_path_json TEXT NOT NULL DEFAULT '[]';"
        ]

        for statement in statements {
            _ = sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    private static func applyRuntimeEventMigrations(db: OpaquePointer?) {
        guard let db else {
            return
        }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE events ADD COLUMN extensions_json TEXT NOT NULL DEFAULT '{}';",
            nil, nil, nil
        )
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

    private func encodedStringArray(_ values: [String]) -> String {
        let encoded = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: encoded, encoding: .utf8) ?? "[]"
    }

    private func decodeOptionalStringArray(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else {
            return nil
        }
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        return values.isEmpty ? nil : values
    }
#endif

    // MARK: - Cron Tasks

    public func listAllCronTasks() async -> [AgentCronTask] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackCronTasks.values.sorted { $0.createdAt < $1.createdAt }
        }
        let sql =
            """
            SELECT id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            FROM agent_cron_tasks
            ORDER BY created_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var result: [AgentCronTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let agentIdPtr = sqlite3_column_text(statement, 1),
                let channelIdPtr = sqlite3_column_text(statement, 2),
                let schedulePtr = sqlite3_column_text(statement, 3),
                let commandPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 6),
                let updatedAtPtr = sqlite3_column_text(statement, 7)
            else { continue }

            let id = String(cString: idPtr)
            let agentId = String(cString: agentIdPtr)
            let channelId = String(cString: channelIdPtr)
            let schedule = String(cString: schedulePtr)
            let command = String(cString: commandPtr)
            let enabled = sqlite3_column_int(statement, 5) != 0

            guard
                let createdAtDate = isoFormatter.date(from: String(cString: createdAtPtr)),
                let updatedAtDate = isoFormatter.date(from: String(cString: updatedAtPtr))
            else { continue }

            result.append(
                AgentCronTask(
                    id: id,
                    agentId: agentId,
                    channelId: channelId,
                    schedule: schedule,
                    command: command,
                    enabled: enabled,
                    createdAt: createdAtDate,
                    updatedAt: updatedAtDate
                )
            )
        }
        return result
#else
        return fallbackCronTasks.values.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func listCronTasks(agentId: String) async -> [AgentCronTask] {
#if canImport(CSQLite3)
        guard let db else {
            return fallbackCronTasks.values.filter { $0.agentId == agentId }.sorted { $0.createdAt < $1.createdAt }
        }
        let sql =
            """
            SELECT id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            FROM agent_cron_tasks
            WHERE agent_id = ?
            ORDER BY created_at ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(agentId, at: 1, statement: statement)

        var result: [AgentCronTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let agentIdPtr = sqlite3_column_text(statement, 1),
                let channelIdPtr = sqlite3_column_text(statement, 2),
                let schedulePtr = sqlite3_column_text(statement, 3),
                let commandPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 6),
                let updatedAtPtr = sqlite3_column_text(statement, 7)
            else { continue }

            let enabled = sqlite3_column_int(statement, 5) != 0
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

            result.append(AgentCronTask(
                id: String(cString: idPtr),
                agentId: String(cString: agentIdPtr),
                channelId: String(cString: channelIdPtr),
                schedule: String(cString: schedulePtr),
                command: String(cString: commandPtr),
                enabled: enabled,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return result
#else
        return fallbackCronTasks.values.filter { $0.agentId == agentId }.sorted { $0.createdAt < $1.createdAt }
#endif
    }

    public func saveCronTask(_ task: AgentCronTask) async {
        fallbackCronTasks[task.id] = task
#if canImport(CSQLite3)
        guard let db else { return }
        let sql =
            """
            INSERT OR REPLACE INTO agent_cron_tasks(
                id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(task.id, at: 1, statement: statement)
        bindText(task.agentId, at: 2, statement: statement)
        bindText(task.channelId, at: 3, statement: statement)
        bindText(task.schedule, at: 4, statement: statement)
        bindText(task.command, at: 5, statement: statement)
        sqlite3_bind_int(statement, 6, task.enabled ? 1 : 0)
        bindText(isoFormatter.string(from: task.createdAt), at: 7, statement: statement)
        bindText(isoFormatter.string(from: task.updatedAt), at: 8, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func deleteCronTask(id: String) async {
        fallbackCronTasks[id] = nil
#if canImport(CSQLite3)
        guard let db else { return }
        let sql = "DELETE FROM agent_cron_tasks WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func cronTask(id: String) async -> AgentCronTask? {
#if canImport(CSQLite3)
        guard let db else { return fallbackCronTasks[id] }
        let sql =
            """
            SELECT id, agent_id, channel_id, schedule, command, enabled, created_at, updated_at
            FROM agent_cron_tasks
            WHERE id = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return fallbackCronTasks[id] }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)

        if sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let agentIdPtr = sqlite3_column_text(statement, 1),
                let channelIdPtr = sqlite3_column_text(statement, 2),
                let schedulePtr = sqlite3_column_text(statement, 3),
                let commandPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 6),
                let updatedAtPtr = sqlite3_column_text(statement, 7)
            else { return nil }

            let enabled = sqlite3_column_int(statement, 5) != 0
            let createdAt = isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date()
            let updatedAt = isoFormatter.date(from: String(cString: updatedAtPtr)) ?? createdAt

            return AgentCronTask(
                id: String(cString: idPtr),
                agentId: String(cString: agentIdPtr),
                channelId: String(cString: channelIdPtr),
                schedule: String(cString: schedulePtr),
                command: String(cString: commandPtr),
                enabled: enabled,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
        return nil
#else
        return fallbackCronTasks[id]
#endif
    }

    // MARK: - ChannelAccessUser

    public func listChannelAccessUsers(platform: String?) async -> [ChannelAccessUser] {
#if canImport(CSQLite3)
        guard let db else { return [] }
        let sql: String
        if let platform {
            sql = "SELECT id, platform, platform_user_id, display_name, status, created_at, updated_at FROM channel_access_users WHERE platform = ? ORDER BY created_at DESC;"
        } else {
            sql = "SELECT id, platform, platform_user_id, display_name, status, created_at, updated_at FROM channel_access_users ORDER BY created_at DESC;"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let platform {
            bindText(platform, at: 1, statement: statement)
        }
        var results: [ChannelAccessUser] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let platformPtr = sqlite3_column_text(statement, 1),
                let userIdPtr = sqlite3_column_text(statement, 2),
                let namePtr = sqlite3_column_text(statement, 3),
                let statusPtr = sqlite3_column_text(statement, 4),
                let createdAtPtr = sqlite3_column_text(statement, 5),
                let updatedAtPtr = sqlite3_column_text(statement, 6)
            else { continue }
            results.append(ChannelAccessUser(
                id: String(cString: idPtr),
                platform: String(cString: platformPtr),
                platformUserId: String(cString: userIdPtr),
                displayName: String(cString: namePtr),
                status: String(cString: statusPtr),
                createdAt: isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date(),
                updatedAt: isoFormatter.date(from: String(cString: updatedAtPtr)) ?? Date()
            ))
        }
        return results
#else
        return []
#endif
    }

    public func channelAccessUser(platform: String, platformUserId: String) async -> ChannelAccessUser? {
#if canImport(CSQLite3)
        guard let db else { return nil }
        let sql = "SELECT id, platform, platform_user_id, display_name, status, created_at, updated_at FROM channel_access_users WHERE platform = ? AND platform_user_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(platform, at: 1, statement: statement)
        bindText(platformUserId, at: 2, statement: statement)
        if sqlite3_step(statement) == SQLITE_ROW,
           let idPtr = sqlite3_column_text(statement, 0),
           let platformPtr = sqlite3_column_text(statement, 1),
           let userIdPtr = sqlite3_column_text(statement, 2),
           let namePtr = sqlite3_column_text(statement, 3),
           let statusPtr = sqlite3_column_text(statement, 4),
           let createdAtPtr = sqlite3_column_text(statement, 5),
           let updatedAtPtr = sqlite3_column_text(statement, 6) {
            return ChannelAccessUser(
                id: String(cString: idPtr),
                platform: String(cString: platformPtr),
                platformUserId: String(cString: userIdPtr),
                displayName: String(cString: namePtr),
                status: String(cString: statusPtr),
                createdAt: isoFormatter.date(from: String(cString: createdAtPtr)) ?? Date(),
                updatedAt: isoFormatter.date(from: String(cString: updatedAtPtr)) ?? Date()
            )
        }
        return nil
#else
        return nil
#endif
    }

    public func saveChannelAccessUser(_ user: ChannelAccessUser) async {
#if canImport(CSQLite3)
        guard let db else { return }
        let sql = """
            INSERT INTO channel_access_users(id, platform, platform_user_id, display_name, status, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(platform, platform_user_id) DO UPDATE SET
                display_name = excluded.display_name,
                status = excluded.status,
                updated_at = excluded.updated_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(user.id, at: 1, statement: statement)
        bindText(user.platform, at: 2, statement: statement)
        bindText(user.platformUserId, at: 3, statement: statement)
        bindText(user.displayName, at: 4, statement: statement)
        bindText(user.status, at: 5, statement: statement)
        bindText(isoFormatter.string(from: user.createdAt), at: 6, statement: statement)
        bindText(isoFormatter.string(from: user.updatedAt), at: 7, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

    public func deleteChannelAccessUser(id: String) async {
#if canImport(CSQLite3)
        guard let db else { return }
        let sql = "DELETE FROM channel_access_users WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(id, at: 1, statement: statement)
        _ = sqlite3_step(statement)
#endif
    }

#if canImport(CSQLite3)
    private static func applyCronTaskMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS agent_cron_tasks(
                id TEXT PRIMARY KEY,
                agent_id TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                schedule TEXT NOT NULL,
                command TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """,
            nil, nil, nil
        )
    }

    private static func applyDashboardProjectsMigrations(db: OpaquePointer?) {
        guard let db else { return }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN actors_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
        _ = sqlite3_exec(
            db,
            "ALTER TABLE dashboard_projects ADD COLUMN teams_json TEXT NOT NULL DEFAULT '[]';",
            nil, nil, nil
        )
    }

    private static func openDatabase(path: String, schemaSQL: String) -> (OpaquePointer?, String?) {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                return (nil, "Failed to create database directory at \(directory): \(error.localizedDescription)")
            }
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open(path, &db)
        guard openResult == SQLITE_OK else {
            let errorMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Result code: \(openResult)"
            if let db {
                sqlite3_close(db)
            }
            return (nil, "Failed to open SQLite database at \(path): \(errorMsg)")
        }

        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)

        if sqlite3_exec(db, schemaSQL, nil, nil, nil) != SQLITE_OK {
            let errorMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown execution error"
            sqlite3_close(db)
            return (nil, "Failed to apply schema to database at \(path): \(errorMsg)")
        }

        applyRuntimeEventMigrations(db: db)
        applyProjectTaskMigrations(db: db)
        applyChannelPluginMigrations(db: db)
        applyCronTaskMigrations(db: db)
        applyDashboardProjectsMigrations(db: db)
        return (db, nil)
    }
#endif
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

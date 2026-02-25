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

    private var fallbackEvents: [EventEnvelope] = []
    private var fallbackBulletins: [MemoryBulletin] = []
    private var fallbackArtifacts: [String: String] = [:]

    /// Creates a persistence store and applies schema when SQLite is available.
    public init(path: String, schemaSQL: String) {
#if canImport(SQLite3)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        if sqlite3_open(path, &db) == SQLITE_OK {
            _ = sqlite3_exec(db, schemaSQL, nil, nil, nil)
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

#if canImport(SQLite3)
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
#endif
}

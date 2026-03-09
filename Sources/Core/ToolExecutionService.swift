import Foundation
import AgentRuntime
import Logging
import Protocols

final class ToolExecutionService: @unchecked Sendable {
    private let runtime: RuntimeSystem
    private let memoryStore: any MemoryStore
    private let sessionStore: AgentSessionFileStore
    private let agentCatalogStore: AgentCatalogFileStore
    private let processRegistry: SessionProcessRegistry
    private let channelSessionStore: ChannelSessionFileStore
    private var store: any PersistenceStore
    private let searchProviderService: SearchProviderService
    private let logger: Logger
    private var workspaceRootURL: URL

    init(
        workspaceRootURL: URL,
        runtime: RuntimeSystem,
        memoryStore: any MemoryStore,
        sessionStore: AgentSessionFileStore,
        agentCatalogStore: AgentCatalogFileStore,
        processRegistry: SessionProcessRegistry,
        channelSessionStore: ChannelSessionFileStore,
        store: any PersistenceStore,
        searchProviderService: SearchProviderService,
        logger: Logger = Logger(label: "sloppy.core.tools")
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.runtime = runtime
        self.memoryStore = memoryStore
        self.sessionStore = sessionStore
        self.agentCatalogStore = agentCatalogStore
        self.processRegistry = processRegistry
        self.channelSessionStore = channelSessionStore
        self.store = store
        self.searchProviderService = searchProviderService
        self.logger = logger
    }

    func updateWorkspaceRootURL(_ url: URL) {
        self.workspaceRootURL = url
    }

    func updateStore(_ store: any PersistenceStore) {
        self.store = store
    }

    func cleanupSessionProcesses(_ sessionID: String) async {
        await processRegistry.cleanup(sessionID: sessionID)
    }

    func shutdown() async {
        await processRegistry.shutdown()
    }

    func activeProcessCount(sessionID: String) async -> Int {
        await processRegistry.activeCount(sessionID: sessionID)
    }

    func invoke(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest,
        policy: AgentToolsPolicy
    ) async -> ToolInvocationResult {
        let startedAt = Date()
        let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)

        let result: ToolInvocationResult
        switch toolID {
        case "files.read":
            result = executeFilesRead(request: request, policy: policy)
        case "files.edit":
            result = executeFilesEdit(request: request, policy: policy)
        case "files.write":
            result = executeFilesWrite(request: request, policy: policy)
        case "runtime.exec":
            result = await executeRuntimeExec(request: request, policy: policy)
        case "runtime.process":
            result = await executeRuntimeProcess(sessionID: sessionID, request: request, policy: policy)
        case "sessions.spawn":
            result = await executeSessionsSpawn(agentID: agentID, request: request)
        case "sessions.list":
            result = executeSessionsList(agentID: agentID)
        case "sessions.history":
            result = executeSessionsHistory(agentID: agentID, defaultSessionID: sessionID, request: request)
        case "sessions.status":
            result = await executeSessionsStatus(agentID: agentID, defaultSessionID: sessionID, request: request)
        case "sessions.send", "messages.send":
            result = await executeSessionsSend(agentID: agentID, defaultSessionID: sessionID, request: request)
        case "agents.list":
            result = executeAgentsList()
        case "channel.history":
            result = await executeChannelHistory(request: request)
        case "memory.get", "memory.recall":
            result = await executeMemoryRecall(tool: toolID, request: request)
        case "memory.search":
            result = await executeMemorySearch(tool: toolID, request: request)
        case "memory.save":
            result = await executeMemorySave(tool: toolID, request: request)
        case "web.search":
            result = await executeWebSearch(tool: toolID, request: request, policy: policy)
        case "web.fetch":
            result = unsupportedAdapterResult(tool: toolID)
        case "cron":
            result = await executeCron(agentID: agentID, sessionID: sessionID, request: request)
        case "system.list_tools":
            result = executeSystemListTools(request: request)
        default:
            result = failed(
                tool: toolID,
                code: "unknown_tool",
                message: "Unknown tool '\(toolID)'",
                retryable: false
            )
        }

        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        return ToolInvocationResult(
            tool: result.tool,
            ok: result.ok,
            data: result.data,
            error: result.error,
            durationMs: durationMs
        )
    }

    private func executeFilesRead(request: ToolInvocationRequest, policy: AgentToolsPolicy) -> ToolInvocationResult {
        let pathValue = request.arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pathValue.isEmpty else {
            return failed(tool: request.tool, code: "invalid_arguments", message: "`path` is required.", retryable: false)
        }

        guard let fileURL = resolveReadableURL(path: pathValue, policy: policy) else {
            return failed(tool: request.tool, code: "path_not_allowed", message: "File path is outside allowed roots.", retryable: false)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let maxBytes = request.arguments["maxBytes"]?.asInt ?? policy.guardrails.maxReadBytes
            if data.count > max(1, maxBytes) {
                return failed(tool: request.tool, code: "file_too_large", message: "File exceeds max readable bytes.", retryable: false)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return failed(tool: request.tool, code: "binary_not_supported", message: "Only UTF-8 files are supported.", retryable: false)
            }
            return success(tool: request.tool, data: .object([
                "path": .string(fileURL.path),
                "content": .string(text),
                "sizeBytes": .number(Double(data.count))
            ]))
        } catch {
            return failed(tool: request.tool, code: "read_failed", message: "Failed to read file.", retryable: true)
        }
    }

    private func executeFilesWrite(request: ToolInvocationRequest, policy: AgentToolsPolicy) -> ToolInvocationResult {
        let pathValue = request.arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = request.arguments["content"]?.asString ?? ""
        guard !pathValue.isEmpty else {
            return failed(tool: request.tool, code: "invalid_arguments", message: "`path` is required.", retryable: false)
        }
        guard !content.isEmpty || request.arguments["allowEmpty"]?.asBool == true else {
            return failed(tool: request.tool, code: "invalid_arguments", message: "`content` is required.", retryable: false)
        }

        guard let fileURL = resolveWritableURL(path: pathValue, policy: policy) else {
            return failed(tool: request.tool, code: "path_not_allowed", message: "File path is outside allowed roots.", retryable: false)
        }

        let byteCount = content.lengthOfBytes(using: .utf8)
        if byteCount > policy.guardrails.maxWriteBytes {
            return failed(tool: request.tool, code: "content_too_large", message: "Content exceeds max writable bytes.", retryable: false)
        }

        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return success(tool: request.tool, data: .object([
                "path": .string(fileURL.path),
                "sizeBytes": .number(Double(byteCount))
            ]))
        } catch {
            return failed(tool: request.tool, code: "write_failed", message: "Failed to write file.", retryable: true)
        }
    }

    private func executeFilesEdit(request: ToolInvocationRequest, policy: AgentToolsPolicy) -> ToolInvocationResult {
        let pathValue = request.arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let search = request.arguments["search"]?.asString ?? ""
        let replace = request.arguments["replace"]?.asString ?? ""
        let replaceAll = request.arguments["all"]?.asBool ?? false

        guard !pathValue.isEmpty, !search.isEmpty else {
            return failed(
                tool: request.tool,
                code: "invalid_arguments",
                message: "`path` and `search` are required for files.edit.",
                retryable: false
            )
        }

        guard let fileURL = resolveWritableURL(path: pathValue, policy: policy) else {
            return failed(tool: request.tool, code: "path_not_allowed", message: "File path is outside allowed roots.", retryable: false)
        }

        do {
            let original = try String(contentsOf: fileURL, encoding: .utf8)
            let updated: String
            let replacements: Int
            if replaceAll {
                updated = original.replacingOccurrences(of: search, with: replace)
                replacements = occurrences(of: search, in: original)
            } else {
                if let range = original.range(of: search) {
                    var copy = original
                    copy.replaceSubrange(range, with: replace)
                    updated = copy
                    replacements = 1
                } else {
                    updated = original
                    replacements = 0
                }
            }

            guard replacements > 0 else {
                return failed(tool: request.tool, code: "search_not_found", message: "Search text not found.", retryable: false)
            }

            if updated.lengthOfBytes(using: .utf8) > policy.guardrails.maxWriteBytes {
                return failed(tool: request.tool, code: "content_too_large", message: "Result exceeds max writable bytes.", retryable: false)
            }
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            return success(tool: request.tool, data: .object([
                "path": .string(fileURL.path),
                "replacements": .number(Double(replacements))
            ]))
        } catch {
            return failed(tool: request.tool, code: "edit_failed", message: "Failed to edit file.", retryable: true)
        }
    }

    private func executeRuntimeExec(request: ToolInvocationRequest, policy: AgentToolsPolicy) async -> ToolInvocationResult {
        let command = request.arguments["command"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return failed(tool: request.tool, code: "invalid_arguments", message: "`command` is required.", retryable: false)
        }

        let arguments = request.arguments["arguments"]?.asArray?.compactMap(\.asString) ?? []
        let timeoutMs = max(100, request.arguments["timeoutMs"]?.asInt ?? policy.guardrails.execTimeoutMs)
        let cwdValue = request.arguments["cwd"]?.asString

        guard isCommandAllowed(command: command, deniedPrefixes: policy.guardrails.deniedCommandPrefixes) else {
            return failed(tool: request.tool, code: "command_blocked", message: "Command blocked by guardrail denylist.", retryable: false)
        }

        let cwdURL: URL?
        if let cwdValue, !cwdValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = resolveExecCwd(path: cwdValue, policy: policy) else {
                return failed(tool: request.tool, code: "cwd_not_allowed", message: "CWD is outside allowed execution roots.", retryable: false)
            }
            cwdURL = resolved
        } else {
            cwdURL = workspaceRootURL
        }

        do {
            let payload = try await runForegroundProcess(
                command: command,
                arguments: arguments,
                cwd: cwdURL,
                timeoutMs: timeoutMs,
                maxOutputBytes: policy.guardrails.maxExecOutputBytes
            )
            return success(tool: request.tool, data: payload)
        } catch {
            logger.error(
                "Command execution failed",
                metadata: [
                    "tool": .string(request.tool),
                    "command": .string(command),
                    "arguments": .string(arguments.joined(separator: " ")),
                    "error": .string(String(describing: error))
                ]
            )
            return failed(tool: request.tool, code: "exec_failed", message: "Command execution failed: \(error.localizedDescription)", retryable: true)
        }
    }

    private func executeRuntimeProcess(
        sessionID: String,
        request: ToolInvocationRequest,
        policy: AgentToolsPolicy
    ) async -> ToolInvocationResult {
        let action = request.arguments["action"]?.asString?.lowercased() ?? "list"

        do {
            switch action {
            case "start":
                let command = request.arguments["command"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !command.isEmpty else {
                    return failed(tool: request.tool, code: "invalid_arguments", message: "`command` is required for start action.", retryable: false)
                }
                guard isCommandAllowed(command: command, deniedPrefixes: policy.guardrails.deniedCommandPrefixes) else {
                    return failed(tool: request.tool, code: "command_blocked", message: "Command blocked by guardrail denylist.", retryable: false)
                }

                let arguments = request.arguments["arguments"]?.asArray?.compactMap(\.asString) ?? []
                let cwdValue = request.arguments["cwd"]?.asString
                if let cwdValue, !cwdValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   resolveExecCwd(path: cwdValue, policy: policy) == nil {
                    return failed(tool: request.tool, code: "cwd_not_allowed", message: "CWD is outside allowed execution roots.", retryable: false)
                }
                let payload = try await processRegistry.start(
                    sessionID: sessionID,
                    command: command,
                    arguments: arguments,
                    cwd: cwdValue,
                    maxProcesses: policy.guardrails.maxProcessesPerSession
                )
                return success(tool: request.tool, data: payload)

            case "status":
                let processID = request.arguments["processId"]?.asString ?? ""
                guard !processID.isEmpty else {
                    return failed(tool: request.tool, code: "invalid_arguments", message: "`processId` is required for status action.", retryable: false)
                }
                let payload = try await processRegistry.status(sessionID: sessionID, processID: processID)
                return success(tool: request.tool, data: payload)

            case "stop":
                let processID = request.arguments["processId"]?.asString ?? ""
                guard !processID.isEmpty else {
                    return failed(tool: request.tool, code: "invalid_arguments", message: "`processId` is required for stop action.", retryable: false)
                }
                let payload = try await processRegistry.stop(sessionID: sessionID, processID: processID)
                return success(tool: request.tool, data: payload)

            case "list":
                let payload = await processRegistry.list(sessionID: sessionID)
                return success(tool: request.tool, data: payload)

            default:
                return failed(tool: request.tool, code: "invalid_arguments", message: "Unsupported runtime.process action '\(action)'.", retryable: false)
            }
        } catch SessionProcessRegistry.RegistryError.processLimitReached {
            return failed(tool: request.tool, code: "process_limit_reached", message: "Max process count per session reached.", retryable: false)
        } catch SessionProcessRegistry.RegistryError.processNotFound {
            return failed(tool: request.tool, code: "process_not_found", message: "Process not found.", retryable: false)
        } catch {
            return failed(tool: request.tool, code: "process_error", message: "Failed to execute process action.", retryable: true)
        }
    }

    private func executeSessionsSpawn(agentID: String, request: ToolInvocationRequest) async -> ToolInvocationResult {
        let title = request.arguments["title"]?.asString
        let parent = request.arguments["parentSessionId"]?.asString
        logger.info(
            "Tool requested session spawn",
            metadata: [
                "agent_id": .string(agentID),
                "title": .string(optionalString(title)),
                "parent_session_id": .string(optionalString(parent))
            ]
        )

        do {
            let summary = try sessionStore.createSession(
                agentID: agentID,
                request: AgentSessionCreateRequest(
                    title: title,
                    parentSessionId: parent
                )
            )
            logger.info(
                "Session spawned via tool",
                metadata: [
                    "agent_id": .string(summary.agentId),
                    "session_id": .string(summary.id),
                    "title": .string(summary.title),
                    "parent_session_id": .string(optionalString(summary.parentSessionId))
                ]
            )
            return success(tool: request.tool, data: encodeJSONValue(summary))
        } catch {
            logger.error(
                "Session spawn via tool failed",
                metadata: [
                    "agent_id": .string(agentID),
                    "title": .string(optionalString(title)),
                    "parent_session_id": .string(optionalString(parent))
                ]
            )
            return failed(tool: request.tool, code: "session_spawn_failed", message: "Failed to create session.", retryable: true)
        }
    }

    private func executeSessionsList(agentID: String) -> ToolInvocationResult {
        do {
            let sessions = try sessionStore.listSessions(agentID: agentID)
            return success(tool: "sessions.list", data: encodeJSONValue(sessions))
        } catch {
            return failed(tool: "sessions.list", code: "session_list_failed", message: "Failed to list sessions.", retryable: true)
        }
    }

    private func executeSessionsHistory(
        agentID: String,
        defaultSessionID: String,
        request: ToolInvocationRequest
    ) -> ToolInvocationResult {
        let targetSession = request.arguments["sessionId"]?.asString ?? defaultSessionID
        do {
            let detail = try sessionStore.loadSession(agentID: agentID, sessionID: targetSession)
            return success(tool: request.tool, data: encodeJSONValue(detail))
        } catch {
            return failed(tool: request.tool, code: "session_history_failed", message: "Failed to load session history.", retryable: true)
        }
    }

    private func executeSessionsStatus(
        agentID: String,
        defaultSessionID: String,
        request: ToolInvocationRequest
    ) async -> ToolInvocationResult {
        let targetSession = request.arguments["sessionId"]?.asString ?? defaultSessionID
        do {
            let detail = try sessionStore.loadSession(agentID: agentID, sessionID: targetSession)
            let activeProcesses = await processRegistry.activeCount(sessionID: targetSession)
            let status = SessionStatusResponse(
                sessionId: targetSession,
                status: statusFrom(events: detail.events),
                messageCount: detail.summary.messageCount,
                updatedAt: detail.summary.updatedAt,
                activeProcessCount: activeProcesses
            )
            return success(tool: request.tool, data: encodeJSONValue(status))
        } catch {
            return failed(tool: request.tool, code: "session_status_failed", message: "Failed to load session status.", retryable: true)
        }
    }

    private func executeSessionsSend(
        agentID: String,
        defaultSessionID: String,
        request: ToolInvocationRequest
    ) async -> ToolInvocationResult {
        let targetSession = request.arguments["sessionId"]?.asString ?? defaultSessionID
        let content = request.arguments["content"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userId = request.arguments["userId"]?.asString ?? "tool"
        guard !content.isEmpty else {
            return failed(tool: request.tool, code: "invalid_arguments", message: "`content` is required.", retryable: false)
        }

        do {
            _ = try sessionStore.loadSession(agentID: agentID, sessionID: targetSession)
            let channelID = sessionChannelID(agentID: agentID, sessionID: targetSession)
            _ = await runtime.postMessage(
                channelId: channelID,
                request: ChannelMessageRequest(userId: userId, content: content)
            )

            let snapshot = await runtime.channelState(channelId: channelID)
            let assistantText = snapshot?.messages.reversed().first(where: {
                $0.userId == "system"
            })?.content ?? "Responded inline"

            let appended = [
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: targetSession,
                    type: .message,
                    message: AgentSessionMessage(
                        role: .user,
                        segments: [.init(kind: .text, text: content)],
                        userId: userId
                    )
                ),
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: targetSession,
                    type: .message,
                    message: AgentSessionMessage(
                        role: .assistant,
                        segments: [.init(kind: .text, text: assistantText)],
                        userId: "agent"
                    )
                ),
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: targetSession,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .done,
                        label: "Done",
                        details: "Response is ready."
                    )
                )
            ]
            let summary = try sessionStore.appendEvents(agentID: agentID, sessionID: targetSession, events: appended)
            return success(
                tool: request.tool,
                data: encodeJSONValue(
                    AgentSessionMessageResponse(summary: summary, appendedEvents: appended, routeDecision: snapshot?.lastDecision)
                )
            )
        } catch {
            return failed(tool: request.tool, code: "session_send_failed", message: "Failed to send message to session.", retryable: true)
        }
    }

    private func executeAgentsList() -> ToolInvocationResult {
        do {
            let list = try agentCatalogStore.listAgents()
            return success(tool: "agents.list", data: encodeJSONValue(list))
        } catch {
            return failed(tool: "agents.list", code: "agents_list_failed", message: "Failed to list agents.", retryable: true)
        }
    }

    private func executeChannelHistory(request: ToolInvocationRequest) async -> ToolInvocationResult {
        let args = request.arguments
        guard case .string(let channelId) = args["channel_id"] else {
            return failed(
                tool: "channel.history",
                code: "missing_channel_id",
                message: "Missing required parameter 'channel_id'.",
                retryable: false
            )
        }

        let limit: Int
        if case .number(let n) = args["limit"] {
            limit = Int(n)
        } else if case .string(let s) = args["limit"] {
            limit = Int(s) ?? 50
        } else {
            limit = 50
        }

        do {
            let history = try await channelSessionStore.getMessageHistory(
                channelId: channelId,
                limit: limit
            )

            let messages: [[String: JSONValue]] = history.map { entry in
                [
                    "id": .string(entry.id),
                    "user_id": .string(entry.userId),
                    "content": .string(entry.content),
                    "created_at": .string(ISO8601DateFormatter().string(from: entry.createdAt))
                ]
            }

            let result: [String: JSONValue] = [
                "channel_id": .string(channelId),
                "messages": .array(messages.map { .object($0) }),
                "count": .number(Double(history.count))
            ]

            return success(tool: "channel.history", data: .object(result))
        } catch {
            return failed(
                tool: "channel.history",
                code: "history_load_failed",
                message: "Failed to load channel history: \(error.localizedDescription)",
                retryable: true
            )
        }
    }

    private func executeSystemListTools(request: ToolInvocationRequest) -> ToolInvocationResult {
        return success(
            tool: request.tool,
            data: .array(ToolCatalog.listToolsPayload())
        )
    }

    private func unsupportedAdapterResult(tool: String) -> ToolInvocationResult {
        failed(tool: tool, code: "not_configured", message: "Tool adapter is not configured.", retryable: false)
    }

    private func executeWebSearch(
        tool: String,
        request: ToolInvocationRequest,
        policy: AgentToolsPolicy
    ) async -> ToolInvocationResult {
        let query = request.arguments["query"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return failed(tool: tool, code: "invalid_arguments", message: "`query` is required.", retryable: false)
        }

        let count = min(10, max(1, request.arguments["count"]?.asInt ?? 5))

        do {
            let response = try await searchProviderService.search(
                query: query,
                count: count,
                timeoutMs: policy.guardrails.webTimeoutMs,
                maxBytes: policy.guardrails.webMaxBytes
            )

            return success(
                tool: tool,
                data: .object([
                    "query": .string(response.query),
                    "provider": .string(response.provider),
                    "results": .array(response.results.map { item in
                        .object([
                            "title": .string(item.title),
                            "url": .string(item.url),
                            "snippet": .string(item.snippet)
                        ])
                    }),
                    "citations": .array(response.citations.map { citation in
                        .object([
                            "title": .string(citation.title),
                            "url": .string(citation.url)
                        ])
                    }),
                    "count": .number(Double(response.count))
                ])
            )
        } catch let error as SearchProviderService.SearchError {
            switch error {
            case .notConfigured:
                return failed(tool: tool, code: "not_configured", message: "Search provider is not configured.", retryable: false)
            case .responseTooLarge:
                return failed(tool: tool, code: "response_too_large", message: "Search response exceeded configured size limit.", retryable: false)
            case .httpError(let status):
                return failed(tool: tool, code: "search_http_error", message: "Search provider returned HTTP \(status).", retryable: true)
            case .invalidResponse:
                return failed(tool: tool, code: "invalid_response", message: "Search provider returned an invalid response.", retryable: true)
            case .transportFailure:
                return failed(tool: tool, code: "transport_failed", message: "Search request failed.", retryable: true)
            }
        } catch {
            return failed(tool: tool, code: "search_failed", message: "Search request failed.", retryable: true)
        }
    }

    private func executeMemorySave(tool: String, request: ToolInvocationRequest) async -> ToolInvocationResult {
        let args = request.arguments
        let note = args["note"]?.asString ?? args["content"]?.asString ?? ""
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else {
            return failed(tool: tool, code: "invalid_arguments", message: "`note` is required.", retryable: false)
        }

        let summary = args["summary"]?.asString
        let kind = args["kind"]?.asString.flatMap { MemoryKind(rawValue: $0.lowercased()) }
        let memoryClass = args["class"]?.asString.flatMap { MemoryClass(rawValue: $0.lowercased()) }
            ?? args["memory_class"]?.asString.flatMap { MemoryClass(rawValue: $0.lowercased()) }
        let scope = parseScope(arguments: args)
        let importance = args["importance"]?.asNumber
        let confidence = args["confidence"]?.asNumber

        let sourceType = args["source_type"]?.asString
        let sourceId = args["source_id"]?.asString
        let source = sourceType.map { MemorySource(type: $0, id: sourceId) }

        var metadata: [String: JSONValue] = [:]
        if let metadataObject = args["metadata"]?.asObject {
            metadata = metadataObject
        }

        let ref = await memoryStore.save(
            entry: MemoryWriteRequest(
                note: trimmedNote,
                summary: summary,
                kind: kind,
                memoryClass: memoryClass,
                scope: scope,
                source: source,
                importance: importance,
                confidence: confidence,
                metadata: metadata
            )
        )

        return success(
            tool: tool,
            data: .object([
                "id": .string(ref.id),
                "score": .number(ref.score),
                "kind": .string(ref.kind?.rawValue ?? ""),
                "class": .string(ref.memoryClass?.rawValue ?? "")
            ])
        )
    }

    private func executeMemoryRecall(tool: String, request: ToolInvocationRequest) async -> ToolInvocationResult {
        let args = request.arguments
        let query = args["query"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return failed(tool: tool, code: "invalid_arguments", message: "`query` is required.", retryable: false)
        }

        let limit = max(1, args["limit"]?.asInt ?? 8)
        let scope = parseScope(arguments: args)
        let hits = await memoryStore.recall(
            request: MemoryRecallRequest(
                query: query,
                limit: limit,
                scope: scope
            )
        )

        let payload: [JSONValue] = hits.map { hit in
            .object([
                "id": .string(hit.ref.id),
                "score": .number(hit.ref.score),
                "note": .string(hit.note),
                "summary": hit.summary.map(JSONValue.string) ?? .null,
                "kind": .string(hit.ref.kind?.rawValue ?? ""),
                "class": .string(hit.ref.memoryClass?.rawValue ?? "")
            ])
        }

        return success(
            tool: tool,
            data: .object([
                "query": .string(query),
                "count": .number(Double(payload.count)),
                "items": .array(payload)
            ])
        )
    }

    private func executeMemorySearch(tool: String, request: ToolInvocationRequest) async -> ToolInvocationResult {
        await executeMemoryRecall(tool: tool, request: request)
    }

    private func success(tool: String, data: JSONValue) -> ToolInvocationResult {
        ToolInvocationResult(tool: tool, ok: true, data: data)
    }

    private func failed(tool: String, code: String, message: String, retryable: Bool) -> ToolInvocationResult {
        ToolInvocationResult(
            tool: tool,
            ok: false,
            error: ToolErrorPayload(code: code, message: message, retryable: retryable)
        )
    }

    private func encodeJSONValue<T: Encodable>(_ value: T) -> JSONValue {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            let decoder = JSONDecoder()
            return try decoder.decode(JSONValue.self, from: data)
        } catch {
            return .null
        }
    }

    private func statusFrom(events: [AgentSessionEvent]) -> String {
        for event in events.reversed() where event.type == .runStatus {
            if let stage = event.runStatus?.stage.rawValue {
                return stage
            }
        }
        return "idle"
    }

    private func resolveReadableURL(path: String, policy: AgentToolsPolicy) -> URL? {
        resolvePath(path: path, extraRoots: policy.guardrails.allowedWriteRoots)
    }

    private func resolveWritableURL(path: String, policy: AgentToolsPolicy) -> URL? {
        resolvePath(path: path, extraRoots: policy.guardrails.allowedWriteRoots)
    }

    private func resolveExecCwd(path: String, policy: AgentToolsPolicy) -> URL? {
        resolvePath(path: path, extraRoots: policy.guardrails.allowedExecRoots)
    }

    private func resolvePath(path: String, extraRoots: [String]) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = workspaceRootURL.appendingPathComponent(trimmed)
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootCandidates = [workspaceRootURL] + extraRoots.map { raw in
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw)
            }
            return workspaceRootURL.appendingPathComponent(raw)
        }

        for root in rootCandidates {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
            if resolvedCandidate.path == resolvedRoot.path || resolvedCandidate.path.hasPrefix(rootPath) {
                return resolvedCandidate
            }
        }

        return nil
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        if needle.isEmpty {
            return 0
        }
        var result = 0
        var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            result += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return result
    }

    private func isCommandAllowed(command: String, deniedPrefixes: [String]) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return false
        }
        let basename = URL(fileURLWithPath: normalized).lastPathComponent
        let candidates = [normalized, basename]
        for prefix in deniedPrefixes.map({ $0.lowercased() }) {
            if candidates.contains(where: { $0 == prefix || $0.hasPrefix(prefix + " ") }) {
                return false
            }
        }
        return true
    }

    private func runForegroundProcess(
        command: String,
        arguments: [String],
        cwd: URL?,
        timeoutMs: Int,
        maxOutputBytes: Int
    ) async throws -> JSONValue {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        if command.hasPrefix("/") || command.hasPrefix("./") || command.hasPrefix("../") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            // Use /usr/bin/env to resolve command from PATH
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }

        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = cwd

        try process.run()

        let didTimeout = await raceProcessAgainstTimeout(process: process, timeoutMs: timeoutMs)
        if didTimeout, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let trimmedStdout = trimData(stdoutData, maxBytes: maxOutputBytes)
        let trimmedStderr = trimData(stderrData, maxBytes: maxOutputBytes)

        return .object([
            "command": .string(command),
            "arguments": .array(arguments.map { .string($0) }),
            "exitCode": .number(Double(process.terminationStatus)),
            "timedOut": .bool(didTimeout),
            "stdout": .string(String(decoding: trimmedStdout, as: UTF8.self)),
            "stderr": .string(String(decoding: trimmedStderr, as: UTF8.self))
        ])
    }

    private func raceProcessAgainstTimeout(process: Process, timeoutMs: Int) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                process.waitUntilExit()
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                return true
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func trimData(_ data: Data, maxBytes: Int) -> Data {
        if data.count <= maxBytes {
            return data
        }
        return data.prefix(maxBytes)
    }

    private func sessionChannelID(agentID: String, sessionID: String) -> String {
        "agent:\(agentID):session:\(sessionID)"
    }

    private func optionalString(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(none)" : trimmed
    }

    private func parseScope(arguments: [String: JSONValue]) -> MemoryScope? {
        if let scopeObject = arguments["scope"]?.asObject {
            let scopeType = scopeObject["type"]?.asString?.lowercased()
            let scopeID = scopeObject["id"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let scopeType, let type = MemoryScopeType(rawValue: scopeType), !scopeID.isEmpty else {
                return nil
            }
            return MemoryScope(
                type: type,
                id: scopeID,
                channelId: scopeObject["channel_id"]?.asString,
                projectId: scopeObject["project_id"]?.asString,
                agentId: scopeObject["agent_id"]?.asString
            )
        }

        let scopeType = arguments["scope_type"]?.asString?.lowercased()
        let scopeID = arguments["scope_id"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let scopeType, let type = MemoryScopeType(rawValue: scopeType), !scopeID.isEmpty else {
            return nil
        }
        return MemoryScope(type: type, id: scopeID)
    }

    private func executeCron(agentID: String, sessionID: String, request: ToolInvocationRequest) async -> ToolInvocationResult {
        let schedule = request.arguments["schedule"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = request.arguments["command"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let channelId = request.arguments["channel_id"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? sessionChannelID(agentID: agentID, sessionID: sessionID)

        guard !schedule.isEmpty, !command.isEmpty else {
            return failed(tool: request.tool, code: "invalid_arguments", message: "`schedule` and `command` are required.", retryable: false)
        }

        let task = AgentCronTask(
            id: UUID().uuidString,
            agentId: agentID,
            channelId: channelId,
            schedule: schedule,
            command: command,
            enabled: true
        )

        await store.saveCronTask(task)

        return success(tool: request.tool, data: .object([
            "task_id": .string(task.id),
            "status": .string("created")
        ]))
    }
}

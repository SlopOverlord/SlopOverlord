import Foundation
import AgentRuntime
import Logging
import Protocols

final class ToolExecutionService: @unchecked Sendable {
    private let runtime: RuntimeSystem
    private let sessionStore: AgentSessionFileStore
    private let agentCatalogStore: AgentCatalogFileStore
    private let processRegistry: SessionProcessRegistry
    private let logger: Logger
    private var workspaceRootURL: URL

    init(
        workspaceRootURL: URL,
        runtime: RuntimeSystem,
        sessionStore: AgentSessionFileStore,
        agentCatalogStore: AgentCatalogFileStore,
        processRegistry: SessionProcessRegistry,
        logger: Logger = Logger(label: "slopoverlord.core.tools")
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.runtime = runtime
        self.sessionStore = sessionStore
        self.agentCatalogStore = agentCatalogStore
        self.processRegistry = processRegistry
        self.logger = logger
    }

    func updateWorkspaceRootURL(_ url: URL) {
        self.workspaceRootURL = url
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
        case "web.search", "web.fetch", "memory.get", "memory.search", "cron":
            result = unsupportedAdapterResult(tool: toolID)
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
            return failed(tool: request.tool, code: "exec_failed", message: "Command execution failed.", retryable: true)
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

    private func unsupportedAdapterResult(tool: String) -> ToolInvocationResult {
        failed(tool: tool, code: "not_configured", message: "Tool adapter is not configured.", retryable: false)
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
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
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
}

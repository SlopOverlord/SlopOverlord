import Foundation
import AgentRuntime
import Protocols

// MARK: - Agent memory checkpoint (shadow)

extension CoreService {
    static let agentMemoryCheckpointUserTurnThreshold = 8

    static let memoryCheckpointToolAllowlist: Set<String> = [
        "visor.status",
        "memory.save",
        "agent.documents.set_user_markdown",
        "agent.documents.set_memory_markdown",
        "project.meta_memory_set",
    ]

    /// Parses `agent:{agentId}:session:{sessionId}`; strips an ephemeral `…:memory-checkpoint:…` suffix if present.
    static func parseAgentSessionChannelId(_ channelId: String) -> (agentID: String, sessionID: String)? {
        let trimmed = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("agent:") else { return nil }
        let withoutAgent = trimmed.dropFirst("agent:".count)
        guard let range = withoutAgent.range(of: ":session:") else { return nil }
        let agentID = String(withoutAgent[..<range.lowerBound])
        var sessionPart = String(withoutAgent[range.upperBound...])
        if let checkpointRange = sessionPart.range(of: ":memory-checkpoint:") {
            sessionPart = String(sessionPart[..<checkpointRange.lowerBound])
        }
        let agent = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty, !session.isEmpty else { return nil }
        return (agent, session)
    }

    func handleMemoryCheckpointRuntimeEvent(_ event: EventEnvelope) async {
        guard event.messageType == .compactorThresholdHit else { return }
        guard let parsed = Self.parseAgentSessionChannelId(event.channelId) else { return }
        guard let agentID = normalizedAgentID(parsed.agentID),
              let sessionID = normalizedSessionID(parsed.sessionID) else { return }
        await runAgentMemoryCheckpoint(agentID: agentID, sessionID: sessionID, reason: "compaction_threshold")
    }

    func handleGatewayChannelClosedForMemoryCheckpoint(_ summary: ChannelSessionSummary) async {
        guard summary.status == .closed else { return }
        guard let parsed = Self.parseAgentSessionChannelId(summary.channelId) else { return }
        guard let agentID = normalizedAgentID(parsed.agentID),
              let sessionID = normalizedSessionID(parsed.sessionID) else { return }
        await runAgentMemoryCheckpoint(agentID: agentID, sessionID: sessionID, reason: "gateway_session_timeout")
    }

    public func requestAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String?) async throws -> AgentMemoryCheckpointResponse {
        await waitForStartup()
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentSessionError.invalidAgentID
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            throw AgentSessionError.invalidSessionID
        }
        _ = try getAgent(id: normalizedAgentID)
        _ = try getAgentSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedReason = trimmedReason.isEmpty ? "api_request" : trimmedReason
        await runAgentMemoryCheckpoint(agentID: normalizedAgentID, sessionID: normalizedSessionID, reason: resolvedReason)
        return AgentMemoryCheckpointResponse(ok: true, reason: reason)
    }

    func scheduleAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String) {
        guard let normalizedAgentID = normalizedAgentID(agentID),
              let normalizedSessionID = normalizedSessionID(sessionID)
        else {
            logger.warning(
                "memory.checkpoint.background_failed",
                metadata: [
                    "agent_id": .string(agentID),
                    "session_id": .string(sessionID),
                    "reason": .string(reason),
                    "error": .string("invalid_identifier"),
                ]
            )
            return
        }

        logger.info(
            "memory.checkpoint.background_scheduled",
            metadata: [
                "agent_id": .string(normalizedAgentID),
                "session_id": .string(normalizedSessionID),
                "reason": .string(reason),
            ]
        )

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.runScheduledAgentMemoryCheckpoint(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                reason: reason
            )
        }
    }

    private func runScheduledAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String) async {
        logger.info(
            "memory.checkpoint.background_started",
            metadata: [
                "agent_id": .string(agentID),
                "session_id": .string(sessionID),
                "reason": .string(reason),
            ]
        )
        await runAgentMemoryCheckpoint(agentID: agentID, sessionID: sessionID, reason: reason)
        logger.info(
            "memory.checkpoint.background_completed",
            metadata: [
                "agent_id": .string(agentID),
                "session_id": .string(sessionID),
                "reason": .string(reason),
            ]
        )
    }

    func runAgentMemoryCheckpoint(agentID: String, sessionID: String, reason: String) async {
        guard let normalizedAgentID = normalizedAgentID(agentID) else { return }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return }

        let lockKey = memoryCheckpointLockKey(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        guard !memoryCheckpointLocks.contains(lockKey) else {
            logger.info(
                "memory.checkpoint.skipped_overlap",
                metadata: [
                    "agent_id": .string(normalizedAgentID),
                    "session_id": .string(normalizedSessionID),
                ]
            )
            return
        }
        memoryCheckpointLocks.insert(lockKey)
        defer { memoryCheckpointLocks.remove(lockKey) }

        do {
            _ = try getAgent(id: normalizedAgentID)
            _ = try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            logger.warning(
                "memory.checkpoint.session_unavailable",
                metadata: [
                    "agent_id": .string(normalizedAgentID),
                    "session_id": .string(normalizedSessionID),
                    "error": .string(error.localizedDescription),
                ]
            )
            return
        }

        let models = availableAgentModels()
        let config: AgentConfigDetail
        do {
            config = try agentCatalogStore.getAgentConfig(
                agentID: normalizedAgentID,
                availableModels: models,
                persistedModelAllowed: makePersistedModelAllowance()
            )
        } catch {
            logger.warning("memory.checkpoint.no_agent_config", metadata: ["agent_id": .string(normalizedAgentID)])
            return
        }

        let selectedModel = config.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelForRequest = (selectedModel?.isEmpty == false) ? selectedModel : nil

        let documents: AgentDocumentBundle
        do {
            documents = try agentCatalogStore.readAgentDocuments(agentID: normalizedAgentID)
        } catch {
            documents = AgentDocumentBundle(
                userMarkdown: "",
                agentsMarkdown: "",
                soulMarkdown: "",
                identityMarkdown: ""
            )
        }

        let detail: AgentSessionDetail
        do {
            detail = try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            logger.warning("memory.checkpoint.load_detail_failed", metadata: ["error": .string(error.localizedDescription)])
            return
        }

        let transcript = Self.formattedCheckpointTranscript(from: detail, maxUTF16Scalars: 90_000)
        let projects = await store.listProjects()
        let currentProjectID = detail.summary.projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentProject = currentProjectID.flatMap { pid in
            projects.first { $0.id.caseInsensitiveCompare(pid) == .orderedSame }
        }
        let currentProjectBlock: String
        if let currentProject {
            let repoPath = currentProject.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            currentProjectBlock = """
            - id: `\(currentProject.id)`
            - name: \(currentProject.name)
            - repoPath: \(repoPath.isEmpty ? "(none)" : repoPath)
            - memoryPath: \(projectMetaMemoryFileURL(projectID: currentProject.id).path)
            """
        } else if let currentProjectID, !currentProjectID.isEmpty {
            currentProjectBlock = "- id: `\(currentProjectID)` (not found in project registry)"
        } else {
            currentProjectBlock = "(session is not attached to a project)"
        }
        let currentProjectMetaMemory = currentProject.map { readProjectMetaMemory(projectID: $0.id) } ?? ""
        let projectIndex: String
        if projects.isEmpty {
            projectIndex = "(no projects registered)"
        } else {
            projectIndex = projects
                .map { project in
                    let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = name.isEmpty ? project.id : name
                    return "- `\(project.id)`: \(label)"
                }
                .joined(separator: "\n")
        }

        let bootstrap = Self.memoryCheckpointBootstrap(
            agentID: normalizedAgentID,
            sessionID: normalizedSessionID,
            reason: reason,
            userMarkdown: documents.userMarkdown,
            memoryMarkdown: documents.memoryMarkdown,
            transcript: transcript,
            projectIndex: projectIndex,
            currentProject: currentProjectBlock,
            currentProjectMetaMemory: currentProjectMetaMemory
        )

        let uuid = UUID().uuidString.lowercased()
        let ephemeralChannelId = "agent:\(normalizedAgentID):session:\(normalizedSessionID):memory-checkpoint:\(uuid)"

        await runtime.setChannelBootstrap(channelId: ephemeralChannelId, content: bootstrap)

        let toolInvoker: @Sendable (ToolInvocationRequest) async -> ToolInvocationResult = { request in
            guard Self.memoryCheckpointToolAllowlist.contains(request.tool) else {
                return ToolInvocationResult(
                    tool: request.tool,
                    ok: false,
                    error: ToolErrorPayload(
                        code: "checkpoint_tool_not_allowed",
                        message: "This tool is not available during memory checkpoints. Use visor.status, memory.save, agent.documents.set_* or project.meta_memory_set only.",
                        retryable: false
                    )
                )
            }
            return await self.invokeToolFromRuntime(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request,
                recordSessionEvents: false
            )
        }

        let userPrompt = """
        Execute the memory checkpoint now: read visor status if useful, then update persistent memory via the allowed tools. \
        Do not address the end user. Keep tool arguments concise. Prefer updating `agent.documents.set_memory_markdown`; \
        use `memory.save` with `scope_type: project` for durable project facts, and use `project.meta_memory_set` for \
        durable project-wide facts that belong in the workspace-private `.meta/MEMORY.md` file.
        """

        await runtime.postMessage(
            channelId: ephemeralChannelId,
            request: ChannelMessageRequest(
                userId: "memory_checkpoint",
                content: userPrompt,
                model: modelForRequest,
                reasoningEffort: nil
            ),
            onResponseChunk: { _ in true },
            toolInvoker: toolInvoker,
            observationHandler: nil
        )

        await runtime.discardEphemeralCheckpointChannel(channelId: ephemeralChannelId)

        do {
            try sessionStore.resetUserTurnCount(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch {
            logger.warning(
                "memory.checkpoint.reset_turns_failed",
                metadata: ["error": .string(error.localizedDescription)]
            )
        }

        logger.info(
            "memory.checkpoint.completed",
            metadata: [
                "agent_id": .string(normalizedAgentID),
                "session_id": .string(normalizedSessionID),
                "reason": .string(reason),
            ]
        )
    }

    private func memoryCheckpointLockKey(agentID: String, sessionID: String) -> String {
        "\(agentID)::\(sessionID)"
    }

    private func readProjectMetaMemory(projectID: String) -> String {
        guard let normalizedID = normalizedProjectID(projectID) else { return "" }
        return (try? String(contentsOf: projectMetaMemoryFileURL(projectID: normalizedID), encoding: .utf8)) ?? ""
    }

    private static func formattedCheckpointTranscript(from detail: AgentSessionDetail, maxUTF16Scalars: Int) -> String {
        let sorted = detail.events.sorted { $0.createdAt < $1.createdAt }
        var lines: [String] = []
        for event in sorted {
            guard event.type == .message, let msg = event.message else { continue }
            let role = msg.role.rawValue
            let text = msg.segments.map { seg -> String in
                switch seg.kind {
                case .text:
                    return seg.text ?? ""
                case .attachment:
                    if let attachment = seg.attachment {
                        return "[attachment: \(attachment.name)]"
                    }
                    return ""
                case .thinking:
                    if let t = seg.text {
                        return "(thinking) \(t)"
                    }
                    return ""
                }
            }.joined(separator: "\n")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append("[\(role)] \(trimmed)")
        }
        var result = lines.joined(separator: "\n\n")
        if result.unicodeScalars.count > maxUTF16Scalars {
            let idx = result.unicodeScalars.index(result.unicodeScalars.startIndex, offsetBy: maxUTF16Scalars)
            result = String(result[..<idx]) + "\n\n…(truncated)"
        }
        return result
    }

    static func memoryCheckpointBootstrap(
        agentID: String,
        sessionID: String,
        reason: String,
        userMarkdown: String,
        memoryMarkdown: String,
        transcript: String,
        projectIndex: String,
        currentProject: String,
        currentProjectMetaMemory: String
    ) -> String {
        let um = truncatePrefix(userMarkdown, maxScalars: 6_000)
        let mm = truncatePrefix(memoryMarkdown, maxScalars: 8_000)
        let pm = truncatePrefix(currentProjectMetaMemory, maxScalars: 8_000)
        return """
        Internal MEMORY checkpoint (not visible in the user chat). Reason: \(reason).

        Agent: \(agentID)
        Session: \(sessionID)

        Allowed tools only: `visor.status`, `memory.save`, `agent.documents.set_user_markdown`, `agent.documents.set_memory_markdown`, `project.meta_memory_set`.
        Character limits: USER.md ≤ \(AgentMarkdownLimits.userMarkdownMaxCharacters), MEMORY.md ≤ \(AgentMarkdownLimits.memoryMarkdownMaxCharacters), `.meta/MEMORY.md` ≤ \(AgentMarkdownLimits.projectMetaMemoryMarkdownMaxCharacters).
        Project `.meta/MEMORY.md` is workspace-private at `~/.sloppy/projects/<projectId>/.meta/MEMORY.md`, not inside the source repository.

        If the session is attached to a project, save durable project facts, decisions, conventions, preferences, and follow-ups with `memory.save` using:
        - `scope_type`: `project`
        - `scope_id`: the current project id
        - `summary`: concise
        - `kind`: one of `decision`, `preference`, `fact`, `todo`, `goal`, or `observation`
        - `class`: `semantic` or `procedural`
        - `source_type`: `memory_checkpoint`
        - `source_id`: `\(sessionID)`
        - `metadata`: include `agentId`, `sessionId`, and `reason`

        Do not save runtime bulletins, transient status, or duplicate facts. Keep project memory writes high-signal; at most five project-scoped saves per checkpoint.

        Projects (use `project.meta_memory_set` with a project id when appropriate):
        \(projectIndex)

        Current project:
        \(currentProject)

        Current project .meta/MEMORY.md:
        \(pm)

        Current USER.md:
        \(um)

        Current MEMORY.md:
        \(mm)

        Recent session transcript (ground truth for what to remember):
        \(transcript)
        """
    }

    private static func truncatePrefix(_ text: String, maxScalars: Int) -> String {
        if text.unicodeScalars.count <= maxScalars {
            return text.isEmpty ? "(empty)" : text
        }
        let idx = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: maxScalars)
        return String(text[..<idx]) + "\n…(truncated)"
    }
}

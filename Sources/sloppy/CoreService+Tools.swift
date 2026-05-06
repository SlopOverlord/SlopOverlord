import Foundation
import Logging
import Protocols
import Tracing

// MARK: - Tool Invocation

extension CoreService {
    public func invokeTool(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest
    ) async throws -> ToolInvocationResult {
        let result = await invokeToolFromRuntime(agentID: agentID, sessionID: sessionID, request: request)
        if result.ok || result.error?.code != "tool_forbidden" {
            return result
        }
        throw ToolInvocationError.forbidden(result.error ?? .init(code: "tool_forbidden", message: "Forbidden", retryable: false))
    }

    /// Internal runtime path used by auto tool-calling loop.
    public func invokeToolFromRuntime(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest,
        recordSessionEvents: Bool = true,
        requireApproval: Bool = false,
        chatMode: AgentChatMode? = nil
    ) async -> ToolInvocationResult {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        }
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_session_id", message: "Invalid session id.", retryable: false)
            )
        }
        guard !request.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_tool", message: "Tool id is required.", retryable: false)
            )
        }

        let sessionDetail: AgentSessionDetail
        do {
            _ = try getAgent(id: normalizedAgentID)
            sessionDetail = try sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        } catch let error as AgentStorageError {
            if case .notFound = error {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "agent_not_found", message: "Agent not found.", retryable: false)
                )
            }
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "session_not_found", message: "Session not found.", retryable: false)
            )
        }

        let authorization: ToolAuthorizationDecision
        do {
            authorization = try await toolsAuthorization.authorize(agentID: normalizedAgentID, toolID: request.tool)
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "authorization_failed", message: "Failed to authorize tool call.", retryable: true)
            )
        }

        let trimmedToolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToolID == "planning.request_input" {
            return await handleAgentPlanInputTool(
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                request: request,
                chatMode: chatMode
            )
        }

        if authorization.allowed,
           let allowOverlay = sessionSubagentToolAllowList[normalizedSessionID],
           !allowOverlay.isEmpty,
           !allowOverlay.contains(trimmedToolID) {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(
                    code: "tool_forbidden",
                    message: "Tool '\(trimmedToolID)' is not available in this subagent session.",
                    retryable: false
                )
            )
        }

        let sessionToolContext = await toolContextForSession(
            sessionID: normalizedSessionID,
            sessionTitle: sessionDetail.summary.title,
            projectID: sessionDetail.summary.projectId
        )

        var effectivePolicy = authorization.policy
        if authorization.allowed,
           !sessionToolContext.extraRoots.isEmpty {
            effectivePolicy.guardrails.allowedExecRoots += sessionToolContext.extraRoots
            effectivePolicy.guardrails.allowedWriteRoots += sessionToolContext.extraRoots
        } else if authorization.allowed,
           let extraRoots = sessionExtraRoots[normalizedSessionID],
           !extraRoots.isEmpty {
            effectivePolicy.guardrails.allowedExecRoots += extraRoots
            effectivePolicy.guardrails.allowedWriteRoots += extraRoots
        }
        let currentDirectoryURL = sessionToolContext.workingDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        var effectiveRequest = request
        var preHookBlockedResult: ToolInvocationResult?
        if authorization.allowed {
            switch await toolPreHookService.evaluate(
                globalConfig: currentConfig.toolHooks.preTools,
                agentOverride: effectivePolicy.preToolsHook,
                agentID: normalizedAgentID,
                sessionID: normalizedSessionID,
                channelID: nil,
                source: .agentSession,
                request: request,
                workingDirectory: sessionToolContext.workingDirectory,
                workspaceRootURL: workspaceRootURL
            ) {
            case .allow(let rewritten):
                effectiveRequest = rewritten
            case .block(let blocked):
                preHookBlockedResult = blocked
            }
        }

        let loopDecision: ToolLoopGuard.Decision
        if authorization.allowed, preHookBlockedResult == nil {
            loopDecision = await toolLoopGuard.evaluate(
                sessionID: normalizedSessionID,
                request: effectiveRequest,
                policy: effectivePolicy,
                workspaceRootURL: workspaceRootURL,
                currentDirectoryURL: currentDirectoryURL
            )
        } else {
            loopDecision = .allow(signature: "")
        }

        let toolCallEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            type: .toolCall,
            toolCall: AgentToolCallEvent(
                tool: effectiveRequest.tool,
                arguments: effectiveRequest.arguments,
                reason: effectiveRequest.reason
            )
        )

        if recordSessionEvents, preHookBlockedResult == nil {
            do {
                let summary = try sessionStore.appendEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    events: [toolCallEvent]
                )
                publishLiveSessionEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    summary: summary,
                    events: [toolCallEvent]
                )
            } catch {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "session_write_failed", message: "Failed to persist tool call event.", retryable: true)
                )
            }
        }

        let result: ToolInvocationResult
        if authorization.allowed {
            if let preHookBlockedResult {
                result = preHookBlockedResult
            } else {
                switch loopDecision {
                case .block(let message):
                    result = .init(
                        tool: effectiveRequest.tool,
                        ok: false,
                        error: .init(
                            code: "tool_loop_detected",
                            message: message,
                            retryable: false,
                            hint: "Change the command or arguments, or summarize the blocker instead of retrying the same tool call."
                        )
                    )

                case .allow:
                    if let approval = await requestToolApprovalIfNeeded(
                        agentID: normalizedAgentID,
                        sessionID: normalizedSessionID,
                        channelID: nil,
                        topicID: nil,
                        request: effectiveRequest,
                        requireApproval: requireApproval || effectivePolicy.approval.enabled
                    ), let deniedResult = toolApprovalDeniedResult(tool: effectiveRequest.tool, approval: approval) {
                        result = deniedResult
                        break
                    }
                    await toolLoopGuard.recordStarted(
                        sessionID: normalizedSessionID,
                        request: effectiveRequest,
                        policy: effectivePolicy,
                        workspaceRootURL: workspaceRootURL,
                        currentDirectoryURL: currentDirectoryURL
                    )
                    let toolExecution = self.toolExecution
                    let invocationPolicy = effectivePolicy
                    let invocationRequest = effectiveRequest
                    let timeoutMs = toolInvocationHardTimeoutMs(request: invocationRequest, policy: invocationPolicy)
                    result = await runToolInvocationWithHardTimeout(
                        toolID: invocationRequest.tool,
                        timeoutMs: timeoutMs
                    ) {
                        await withSpan("tool.invoke", ofKind: .internal) { span in
                            span.attributes["agent_id"] = "\(normalizedAgentID)"
                            span.attributes["session_id"] = "\(normalizedSessionID)"
                            span.attributes["tool_id"] = "\(invocationRequest.tool)"
                            return await toolExecution.invoke(
                                agentID: normalizedAgentID,
                                sessionID: normalizedSessionID,
                                request: invocationRequest,
                                policy: invocationPolicy,
                                currentDirectoryURL: currentDirectoryURL
                            )
                        }
                    }
                    await toolLoopGuard.recordResult(
                        sessionID: normalizedSessionID,
                        request: effectiveRequest,
                        result: result,
                        policy: effectivePolicy,
                        workspaceRootURL: workspaceRootURL,
                        currentDirectoryURL: currentDirectoryURL
                    )
                }
            }
        } else {
            result = .init(
                tool: request.tool,
                ok: false,
                error: authorization.error ?? .init(code: "tool_forbidden", message: "Tool is forbidden.", retryable: false)
            )
        }

        let toolResultEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            type: .toolResult,
            toolResult: AgentToolResultEvent(
                tool: result.tool,
                ok: result.ok,
                data: result.data,
                error: result.error,
                durationMs: result.durationMs
            )
        )

        if recordSessionEvents {
            do {
                var eventsToAppend: [AgentSessionEvent] = []
                if result.error?.code == "tool_loop_detected" {
                    eventsToAppend.append(
                        AgentSessionEvent(
                            agentId: normalizedAgentID,
                            sessionId: normalizedSessionID,
                            type: .runStatus,
                            runStatus: AgentRunStatusEvent(
                                stage: .paused,
                                label: "Loop blocked",
                                details: result.error?.message ?? "Loop blocked: repeated identical tool call."
                            )
                        )
                    )
                } else if result.error?.code == "tool_timeout" {
                    eventsToAppend.append(
                        AgentSessionEvent(
                            agentId: normalizedAgentID,
                            sessionId: normalizedSessionID,
                            type: .runStatus,
                            runStatus: AgentRunStatusEvent(
                                stage: .paused,
                                label: "Tool timed out",
                                details: result.error?.message ?? "Tool timed out."
                            )
                        )
                    )
                }
                eventsToAppend.append(toolResultEvent)
                let summary = try sessionStore.appendEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    events: eventsToAppend
                )
                publishLiveSessionEvents(
                    agentID: normalizedAgentID,
                    sessionID: normalizedSessionID,
                    summary: summary,
                    events: eventsToAppend
                )
            } catch {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "session_write_failed", message: "Failed to persist tool result event.", retryable: true)
                )
            }
        }

        await persistToolInvocationAnalytics(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            sessionTitle: sessionDetail.summary.title,
            toolId: result.tool,
            ok: result.ok,
            durationMs: result.durationMs
        )

        return result
    }

    /// Internal runtime path used by gateway/channel sessions linked to an agent.
    public func invokeToolFromChannelRuntime(
        agentID: String,
        channelID: String,
        request: ToolInvocationRequest,
        topicID: String? = nil,
        requireApproval: Bool = false,
        chatMode: AgentChatMode? = nil
    ) async -> ToolInvocationResult {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        }
        guard !request.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_tool", message: "Tool id is required.", retryable: false)
            )
        }

        do {
            _ = try getAgent(id: normalizedAgentID)
        } catch let error as AgentStorageError {
            if case .notFound = error {
                return .init(
                    tool: request.tool,
                    ok: false,
                    error: .init(code: "agent_not_found", message: "Agent not found.", retryable: false)
                )
            }
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "invalid_agent_id", message: "Invalid agent id.", retryable: false)
            )
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "agent_not_found", message: "Agent not found.", retryable: false)
            )
        }

        let authorization: ToolAuthorizationDecision
        do {
            authorization = try await toolsAuthorization.authorize(agentID: normalizedAgentID, toolID: request.tool)
        } catch {
            return .init(
                tool: request.tool,
                ok: false,
                error: .init(code: "authorization_failed", message: "Failed to authorize tool call.", retryable: true)
            )
        }

        let trimmedToolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToolID == "planning.request_input" {
            return await handleChannelPlanInputTool(
                agentID: normalizedAgentID,
                channelID: channelID,
                request: request,
                topicID: topicID,
                chatMode: chatMode
            )
        }

        var effectivePolicy = authorization.policy
        let channelToolContext = await toolContextForChannel(channelID: channelID)
        if authorization.allowed, !channelToolContext.extraRoots.isEmpty {
            effectivePolicy.guardrails.allowedExecRoots += channelToolContext.extraRoots
            effectivePolicy.guardrails.allowedWriteRoots += channelToolContext.extraRoots
        }
        let currentDirectoryURL = channelToolContext.workingDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        var effectiveRequest = request
        var preHookBlockedResult: ToolInvocationResult?
        if authorization.allowed {
            switch await toolPreHookService.evaluate(
                globalConfig: currentConfig.toolHooks.preTools,
                agentOverride: effectivePolicy.preToolsHook,
                agentID: normalizedAgentID,
                sessionID: nil,
                channelID: channelID,
                source: .channelRuntime,
                request: request,
                workingDirectory: channelToolContext.workingDirectory,
                workspaceRootURL: workspaceRootURL
            ) {
            case .allow(let rewritten):
                effectiveRequest = rewritten
            case .block(let blocked):
                preHookBlockedResult = blocked
            }
        }

        let loopDecision: ToolLoopGuard.Decision
        if authorization.allowed, preHookBlockedResult == nil {
            loopDecision = await toolLoopGuard.evaluate(
                sessionID: channelID,
                request: effectiveRequest,
                policy: effectivePolicy,
                workspaceRootURL: workspaceRootURL,
                currentDirectoryURL: currentDirectoryURL
            )
        } else {
            loopDecision = .allow(signature: "")
        }

        let result: ToolInvocationResult
        if authorization.allowed {
            if let preHookBlockedResult {
                result = preHookBlockedResult
            } else {
                switch loopDecision {
                case .block(let message):
                    result = .init(
                        tool: effectiveRequest.tool,
                        ok: false,
                        error: .init(
                            code: "tool_loop_detected",
                            message: message,
                            retryable: false,
                            hint: "Change the command or arguments, or summarize the blocker instead of retrying the same tool call."
                        )
                    )

                case .allow:
                    if let approval = await requestToolApprovalIfNeeded(
                        agentID: normalizedAgentID,
                        sessionID: nil,
                        channelID: channelID,
                        topicID: topicID,
                        request: effectiveRequest,
                        requireApproval: requireApproval || effectivePolicy.approval.enabled
                    ), let deniedResult = toolApprovalDeniedResult(tool: effectiveRequest.tool, approval: approval) {
                        result = deniedResult
                        break
                    }
                    await toolLoopGuard.recordStarted(
                        sessionID: channelID,
                        request: effectiveRequest,
                        policy: effectivePolicy,
                        workspaceRootURL: workspaceRootURL,
                        currentDirectoryURL: currentDirectoryURL
                    )
                    let toolExecution = self.toolExecution
                    let invocationPolicy = effectivePolicy
                    let invocationRequest = effectiveRequest
                    let timeoutMs = toolInvocationHardTimeoutMs(request: invocationRequest, policy: invocationPolicy)
                    result = await runToolInvocationWithHardTimeout(
                        toolID: invocationRequest.tool,
                        timeoutMs: timeoutMs
                    ) {
                        await withSpan("tool.invoke.channel", ofKind: .internal) { span in
                            span.attributes["agent_id"] = "\(normalizedAgentID)"
                            span.attributes["channel_id"] = "\(channelID)"
                            span.attributes["tool_id"] = "\(invocationRequest.tool)"
                            return await toolExecution.invoke(
                                agentID: normalizedAgentID,
                                sessionID: channelID,
                                request: invocationRequest,
                                policy: invocationPolicy,
                                currentDirectoryURL: currentDirectoryURL
                            )
                        }
                    }
                    await toolLoopGuard.recordResult(
                        sessionID: channelID,
                        request: effectiveRequest,
                        result: result,
                        policy: effectivePolicy,
                        workspaceRootURL: workspaceRootURL,
                        currentDirectoryURL: currentDirectoryURL
                    )
                }
            }
        } else {
            result = .init(
                tool: request.tool,
                ok: false,
                error: authorization.error ?? .init(code: "tool_forbidden", message: "Tool is forbidden.", retryable: false)
            )
        }

        return result
    }

    func persistToolInvocationAnalytics(
        agentId: String,
        sessionId: String,
        sessionTitle: String,
        toolId: String,
        ok: Bool,
        durationMs: Int
    ) async {
        let trimmedTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskId: String?
        if trimmedTitle.hasPrefix("task-") {
            let raw = String(trimmedTitle.dropFirst("task-".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            taskId = raw.isEmpty ? nil : raw
        } else {
            taskId = nil
        }

        let projectId: String?
        if let taskId {
            let projects = await store.listProjects()
            projectId = projects.first(where: { $0.tasks.contains(where: { $0.id == taskId }) })?.id
        } else {
            projectId = nil
        }

        await store.persistToolInvocation(
            id: UUID().uuidString,
            projectId: projectId,
            taskId: taskId,
            agentId: agentId,
            sessionId: sessionId,
            tool: toolId,
            ok: ok,
            durationMs: durationMs,
            traceId: nil,
            createdAt: Date()
        )
    }

    /// Persists config to file and updates in-memory snapshot.
    public func toolCatalog() async -> [AgentToolCatalogEntry] {
        await ToolCatalog.entries(mcpRegistry: mcpRegistry)
    }

    /// Returns agent tools policy from `/agents/<agentID>/tools/tools.json`.
    public func getAgentToolsPolicy(agentID: String) async throws -> AgentToolsPolicy {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentToolsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)
        do {
            return try await toolsAuthorization.policy(agentID: normalizedAgentID)
        } catch {
            throw mapAgentToolsError(error)
        }
    }

    /// Updates agent tools policy.
    public func updateAgentToolsPolicy(agentID: String, request: AgentToolsUpdateRequest) async throws -> AgentToolsPolicy {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw AgentToolsError.invalidAgentID
        }
        _ = try getAgent(id: normalizedAgentID)
        do {
            return try await toolsAuthorization.updatePolicy(agentID: normalizedAgentID, request: request)
        } catch {
            throw mapAgentToolsError(error)
        }
    }

    func configureToolExecutionServices() {
        toolExecution.projectService = self
        toolExecution.configService = self
        toolExecution.skillsService = self
        toolExecution.applyAgentMarkdown = { [weak self] agentID, field, markdown in
            guard let self else {
                throw AgentConfigError.storageFailure
            }
            try await self.applyAgentMarkdownFromTool(agentID: agentID, field: field, markdown: markdown)
        }
        toolExecution.delegateSubagent = { [weak self] agentID, taskID, objective, workingDirectory, toolsetNames, selectedModel, parentSessionID in
            guard let self else { return nil }
            return await self.runSubagentTask(
                agentID: agentID,
                taskID: taskID,
                objective: objective,
                workingDirectory: workingDirectory,
                toolsetNames: toolsetNames,
                selectedModel: selectedModel,
                parentSessionID: parentSessionID
            )
        }
    }

    func toolContextForSession(
        sessionID: String,
        sessionTitle: String,
        projectID: String?
    ) async -> (workingDirectory: String?, extraRoots: [String]) {
        if let roots = sessionExtraRoots[sessionID] {
            return (sessionWorkingDirectories[sessionID], roots)
        }

        if let projectContext = await toolContextForProject(projectID: projectID) {
            sessionExtraRoots[sessionID] = projectContext.extraRoots
            sessionWorkingDirectories[sessionID] = projectContext.workingDirectory
            return projectContext
        }

        let trimmedTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.hasPrefix("task-") else {
            return (nil, [])
        }

        let taskID = String(trimmedTitle.dropFirst("task-".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else {
            return (nil, [])
        }

        let projects = await store.listProjects()
        for project in projects {
            guard let task = project.tasks.first(where: { $0.id == taskID }),
                  let repoPath = project.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !repoPath.isEmpty
            else {
                continue
            }

            let workingDirectory: String
            if task.worktreeBranch != nil {
                workingDirectory = gitWorktreeService.worktreePath(repoPath: repoPath, taskId: task.id)
            } else {
                workingDirectory = repoPath
            }

            var roots = sessionToolRoots(forWorkingDirectory: workingDirectory)
            if !roots.contains(repoPath) {
                roots.append(repoPath)
            }
            sessionExtraRoots[sessionID] = roots
            sessionWorkingDirectories[sessionID] = workingDirectory
            return (workingDirectory, roots)
        }

        return (nil, [])
    }

    private func toolContextForProject(projectID: String?) async -> (workingDirectory: String?, extraRoots: [String])? {
        guard let trimmedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedProjectID.isEmpty,
              let workingDirectoryURL = try? await resolveProjectWorkspaceRoot(projectID: trimmedProjectID)
        else {
            return nil
        }

        let workingDirectory = workingDirectoryURL.path
        return (workingDirectory, sessionToolRoots(forWorkingDirectory: workingDirectory))
    }

    func toolContextForChannel(
        channelID: String
    ) async -> (workingDirectory: String?, extraRoots: [String]) {
        let savedRoots = channelExtraRoots[channelID] ?? []
        let savedWorkingDirectory = channelWorkingDirectories[channelID]
        guard let project = await projectForChannel(channelId: channelID) else {
            return (savedWorkingDirectory, savedRoots)
        }
        guard let workingDirectoryURL = try? await resolveProjectWorkspaceRoot(projectID: project.id) else {
            return (savedWorkingDirectory, savedRoots)
        }

        let workingDirectory = workingDirectoryURL.path
        var roots = sessionToolRoots(forWorkingDirectory: workingDirectory)
        if !roots.contains(workingDirectory) {
            roots.append(workingDirectory)
        }
        for root in savedRoots where !roots.contains(root) {
            roots.append(root)
        }
        return (savedWorkingDirectory ?? workingDirectory, roots)
    }

}

private actor ToolInvocationResultBox {
    private var stored: ToolInvocationResult?

    func complete(_ result: ToolInvocationResult) {
        guard stored == nil else { return }
        stored = result
    }

    var value: ToolInvocationResult? {
        stored
    }
}

private func runToolInvocationWithHardTimeout(
    toolID: String,
    timeoutMs: Int,
    operation: @escaping @Sendable () async -> ToolInvocationResult
) async -> ToolInvocationResult {
    let box = ToolInvocationResultBox()
    let startedAt = Date()
    let timeoutMs = max(1, timeoutMs)
    let task = Task {
        let result = await operation()
        await box.complete(result)
    }
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

    while Date() < deadline {
        if let result = await box.value {
            return result
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    if let result = await box.value {
        return result
    }

    task.cancel()
    let durationMs = max(timeoutMs, Int(Date().timeIntervalSince(startedAt) * 1000))
    return ToolInvocationResult(
        tool: toolID,
        ok: false,
        data: .object([
            "timedOut": .bool(true),
            "timeoutMs": .number(Double(timeoutMs))
        ]),
        error: ToolErrorPayload(
            code: "tool_timeout",
            message: "Tool execution timed out after \(timeoutMs) ms.",
            retryable: true,
            hint: "Stop retrying the same tool call. Summarize the blocker or use runtime.process for long-running commands."
        ),
        durationMs: durationMs
    )
}

private func toolInvocationHardTimeoutMs(request: ToolInvocationRequest, policy: AgentToolsPolicy) -> Int {
    let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
    switch toolID {
    case "runtime.exec":
        return resolvedExecTimeoutMs(arguments: request.arguments, guardrails: policy.guardrails) + 3_000

    case "tools.sleep":
        let rawSeconds = request.arguments["seconds"]?.asInt ?? 0
        let seconds = min(max(0, rawSeconds), SleepTool.maxSeconds)
        return seconds * 1_000 + 1_000

    default:
        return max(30_000, policy.guardrails.maxExecTimeoutMs + 5_000)
    }
}

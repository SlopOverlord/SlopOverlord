import Foundation
import PluginSDK
import Protocols

// MARK: - Tool Approvals

extension CoreService: ToolApprovalBridge {
    public func listPendingToolApprovals() async -> [ToolApprovalRecord] {
        await toolApprovalService.listPending()
    }

    public func approveToolApproval(id: String, decidedBy: String?) async -> ToolApprovalRecord? {
        await approveToolApproval(id: id, decidedBy: decidedBy, scope: .once)
    }

    public func approveToolApproval(
        id: String,
        decidedBy: String?,
        scope: ToolApprovalDecisionScope
    ) async -> ToolApprovalRecord? {
        guard let record = await toolApprovalService.approve(id: id, decidedBy: decidedBy) else {
            return nil
        }
        if scope == .session {
            rememberToolApprovalSessionAllowance(record)
        }
        _ = await channelDelivery.updateToolApproval(record)
        return record
    }

    public func rejectToolApproval(id: String, decidedBy: String?) async -> ToolApprovalRecord? {
        guard let record = await toolApprovalService.reject(id: id, decidedBy: decidedBy) else {
            return nil
        }
        _ = await channelDelivery.updateToolApproval(record)
        return record
    }

    public func resolveToolApproval(id: String, approved: Bool, decidedBy: String?) async -> ToolApprovalRecord? {
        if approved {
            return await approveToolApproval(id: id, decidedBy: decidedBy)
        }
        return await rejectToolApproval(id: id, decidedBy: decidedBy)
    }

    func requestToolApprovalIfNeeded(
        agentID: String,
        sessionID: String?,
        channelID: String?,
        topicID: String?,
        request: ToolInvocationRequest,
        requireApproval: Bool
    ) async -> ToolApprovalWaitResult? {
        guard requireApproval, requiresHumanApproval(toolID: request.tool, arguments: request.arguments) else {
            return nil
        }
        if isToolApprovalAllowedForSession(
            agentID: agentID,
            sessionID: sessionID,
            channelID: channelID,
            toolID: request.tool
        ) {
            return nil
        }

        let record = await toolApprovalService.createPending(
            agentId: agentID,
            sessionId: sessionID,
            channelId: channelID,
            topicId: topicID,
            request: request
        )
        await appendToolApprovalPausedStatusIfNeeded(agentID: agentID, sessionID: sessionID, record: record)
        if let sessionID {
            await markTaskWaitingInputForAgentSession(
                agentID: agentID,
                sessionID: sessionID,
                reason: "Tool approval required for \(request.tool).",
                source: "agent"
            )
        }
        _ = await channelDelivery.presentToolApproval(record)
        let result = await toolApprovalService.waitForDecision(id: record.id)
        if case .timedOut(let timedOut) = result {
            _ = await channelDelivery.updateToolApproval(timedOut)
        }
        return result
    }

    func toolApprovalDeniedResult(tool: String, approval: ToolApprovalWaitResult) -> ToolInvocationResult? {
        switch approval {
        case .approved:
            return nil
        case .rejected(let record):
            return ToolInvocationResult(
                tool: tool,
                ok: false,
                data: .object([
                    "approvalId": .string(record.id),
                    "status": .string(record.status.rawValue)
                ]),
                error: ToolErrorPayload(
                    code: "tool_approval_rejected",
                    message: "Tool call was rejected by a human approver.",
                    retryable: false
                )
            )
        case .timedOut(let record):
            return ToolInvocationResult(
                tool: tool,
                ok: false,
                data: .object([
                    "approvalId": .string(record.id),
                    "status": .string(ToolApprovalStatus.timedOut.rawValue)
                ]),
                error: ToolErrorPayload(
                    code: "tool_approval_timeout",
                    message: "Tool approval timed out before a human approved it.",
                    retryable: false
                )
            )
        }
    }

    func requiresHumanApproval(toolID rawToolID: String, arguments: [String: JSONValue]) -> Bool {
        let toolID = rawToolID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !toolID.isEmpty else { return false }

        let exactRisky: Set<String> = [
            "files.write",
            "files.edit",
            "runtime.exec",
            "project.create",
            "project.update",
            "project.delete",
            "project.task_create",
            "project.task_update",
            "project.task_cancel",
            "project.task_clarification_create",
            "project.escalate_to_user",
            "project.meta_memory_set",
            "memory.save",
            "messages.send",
            "sessions.spawn",
            "agents.delegate_task",
            "agent.documents.set_user_markdown",
            "agent.documents.set_memory_markdown",
            "branches.spawn",
            "workers.spawn",
            "workers.route",
            "actor.discuss_with_actor",
            "actor.conclude_discussion",
            "skills.install",
            "skills.uninstall",
            "cron",
            "mcp.call_tool",
            "mcp.save_server",
            "mcp.remove_server",
            "mcp.install_server",
            "mcp.uninstall_server"
        ]
        if exactRisky.contains(toolID) {
            return true
        }

        if toolID == "runtime.process" {
            let action = arguments["action"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return action == nil || action == "start" || action == "stop"
        }

        if toolID.hasPrefix("mcp.") {
            let safeTools: Set<String> = [
                "mcp.list_servers",
                "mcp.list_tools",
                "mcp.list_resources",
                "mcp.read_resource",
                "mcp.list_prompts",
                "mcp.get_prompt"
            ]
            return !safeTools.contains(toolID)
        }

        return false
    }

    private func rememberToolApprovalSessionAllowance(_ record: ToolApprovalRecord) {
        guard let scopeID = toolApprovalSessionScopeID(sessionID: record.sessionId, channelID: record.channelId) else {
            return
        }
        let key = toolApprovalSessionAllowanceKey(agentID: record.agentId, scopeID: scopeID)
        var allowedTools = toolApprovalSessionAllowances[key] ?? []
        allowedTools.insert("*")
        toolApprovalSessionAllowances[key] = allowedTools
    }

    private func isToolApprovalAllowedForSession(
        agentID: String,
        sessionID: String?,
        channelID: String?,
        toolID: String
    ) -> Bool {
        guard let scopeID = toolApprovalSessionScopeID(sessionID: sessionID, channelID: channelID) else {
            return false
        }
        let key = toolApprovalSessionAllowanceKey(agentID: agentID, scopeID: scopeID)
        let allowedTools = toolApprovalSessionAllowances[key] ?? []
        return allowedTools.contains("*") || allowedTools.contains(normalizedToolApprovalToolID(toolID))
    }

    private func toolApprovalSessionScopeID(sessionID: String?, channelID: String?) -> String? {
        if let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            return "session:\(sessionID)"
        }
        if let channelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines), !channelID.isEmpty {
            return "channel:\(channelID)"
        }
        return nil
    }

    private func toolApprovalSessionAllowanceKey(agentID: String, scopeID: String) -> String {
        "\(agentID)\n\(scopeID)"
    }

    private func normalizedToolApprovalToolID(_ toolID: String) -> String {
        toolID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func appendToolApprovalPausedStatusIfNeeded(
        agentID: String,
        sessionID: String?,
        record: ToolApprovalRecord
    ) async {
        guard let sessionID else {
            return
        }
        let details = record.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? record.reason!
            : "Tool: \(record.tool)"
        let event = AgentSessionEvent(
            agentId: agentID,
            sessionId: sessionID,
            type: .runStatus,
            runStatus: AgentRunStatusEvent(
                stage: .paused,
                label: "Tool approval required",
                details: details
            )
        )
        guard let summary = try? sessionStore.appendEvents(agentID: agentID, sessionID: sessionID, events: [event]) else {
            return
        }
        publishLiveSessionEvents(agentID: agentID, sessionID: sessionID, summary: summary, events: [event])
    }
}

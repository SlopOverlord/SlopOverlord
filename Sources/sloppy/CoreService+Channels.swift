import Foundation
import AgentRuntime
import PluginSDK
import Protocols
import Logging

// MARK: - Channels

extension CoreService {
    public func postChannelMessage(channelId: String, request: ChannelMessageRequest) async -> ChannelRouteDecision {
        await waitForStartup()

        let sessionChannelId = ChannelGatewayScope.scopedChannelId(
            baseChannelId: channelId,
            topicKey: request.topicId
        )

        let trimmedContent = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let addDirReply = await handleAddDirCommand(channelId: sessionChannelId, content: request.content) {
            return ChannelRouteDecision(action: .respond, reason: addDirReply, confidence: 1.0, tokenBudget: 0)
        }

        if trimmedContent.lowercased() == "/abort" {
            await channelStreamCancelRegistry.requestCancel(channelId: sessionChannelId)
            let cancelled = await runtime.abortChannel(channelId: sessionChannelId, reason: "Aborted by user")
            await channelStreamCancelRegistry.clearCancel(channelId: sessionChannelId)
            let reason = cancelled > 0
                ? "Aborted \(cancelled) active worker(s)."
                : "No active workers to abort."
            return ChannelRouteDecision(action: .respond, reason: reason, confidence: 1.0, tokenBudget: 0)
        }

        if let btwTail = ChannelInboundBtwParsing.btwModelTailIfCommand(request.content) {
            await channelStreamCancelRegistry.requestCancel(channelId: sessionChannelId)
            _ = await runtime.abortChannel(channelId: sessionChannelId, reason: "Interrupted by /btw")
            await runtime.invalidateChannelSession(channelId: sessionChannelId)
            if btwTail.isEmpty {
                return ChannelRouteDecision(
                    action: .respond,
                    reason: "btw_context_cleared",
                    confidence: 1.0,
                    tokenBudget: 0
                )
            }
            let enrichedTail = await enrichMessageWithTaskReferences(btwTail)
            let nextRequest = ChannelMessageRequest(
                userId: request.userId,
                content: enrichedTail,
                topicId: request.topicId
            )
            return await runtime.postMessage(channelId: sessionChannelId, request: nextRequest)
        }

        if let approvalReference = TaskApprovalCommandParser.parse(request.content) {
            return await handleTaskApprovalCommand(channelId: sessionChannelId, reference: approvalReference)
        }
        if let plannedDecision = await handleVisorTaskPlan(channelId: sessionChannelId, request: request) {
            return plannedDecision
        }

        let enrichedContent = await enrichMessageWithTaskReferences(request.content)
        let nextRequest = ChannelMessageRequest(
            userId: request.userId,
            content: enrichedContent,
            topicId: request.topicId
        )
        return await runtime.postMessage(channelId: sessionChannelId, request: nextRequest)
    }

    /// Controls channel processing: abort active workers on this channel.
    public func controlChannel(channelId: String, action: AgentRunControlAction) async -> ChannelControlResponse {
        await waitForStartup()
        switch action {
        case .interrupt, .interruptTree:
            let cancelled = await runtime.abortChannel(channelId: channelId, reason: "Interrupted by user")
            return ChannelControlResponse(
                channelId: channelId,
                action: action,
                cancelledWorkers: cancelled,
                message: cancelled > 0
                    ? "Aborted \(cancelled) active worker(s)."
                    : "No active workers to abort."
            )
        case .pause, .resume:
            return ChannelControlResponse(
                channelId: channelId,
                action: action,
                cancelledWorkers: 0,
                message: "Action \(action.rawValue) acknowledged."
            )
        }
    }

    /// Routes interactive message into a running worker.
    public func postChannelRoute(channelId: String, workerId: String, request: ChannelRouteRequest) async -> Bool {
        await waitForStartup()
        return await runtime.routeMessage(channelId: channelId, workerId: workerId, message: request.message)
    }

    /// Delivers an outbound message to the channel plugin responsible for this channelId.
    @discardableResult
    public func deliverToChannelPlugin(
        channelId: String,
        userId: String = "system",
        content: String,
        topicId: String? = nil
    ) async -> Bool {
        await channelDelivery.deliver(channelId: channelId, userId: userId, content: content, topicId: topicId)
    }

    /// Returns current state snapshot for a channel.
    public func getChannelState(channelId: String) async -> ChannelSnapshot? {
        await waitForStartup()
        return await runtime.channelState(channelId: channelId)
    }

    /// Returns known visor bulletins, preferring in-memory runtime state.
    public func listChannelEvents(
        channelId: String,
        limit: Int = 50,
        cursor: String? = nil,
        before: Date? = nil,
        after: Date? = nil
    ) async -> ChannelEventsResponse {
        let boundedLimit = min(max(limit, 1), 200)
        let parsedCursor = Self.decodeEventCursor(cursor)
        let events = await store.listChannelEvents(
            channelId: channelId,
            limit: boundedLimit,
            cursor: parsedCursor,
            before: before,
            after: after
        )
        let nextCursor = events.last.map(Self.encodeEventCursor)
        return ChannelEventsResponse(channelId: channelId, items: events, nextCursor: nextCursor)
    }

    public func listChannelSessions(
        status: ChannelSessionStatus? = nil,
        agentID: String? = nil,
        recentMessagesLimit: Int? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> [ChannelSessionSummary] {
        await waitForStartup()

        let board = try? getActorBoard()
        let filteredChannelIDs: Set<String>?
        if let agentID {
            guard let normalizedAgentID = normalizedAgentID(agentID) else {
                throw AgentStorageError.invalidID
            }
            _ = try getAgent(id: normalizedAgentID)
            filteredChannelIDs = boundChannelIDs(agentID: normalizedAgentID, board: board)
        } else {
            filteredChannelIDs = nil
        }

        let timeoutByChannel = channelSessionTimeouts(
            board: board,
            limitToChannelIDs: filteredChannelIDs
        )
        let globalDefault = globalChannelInactivityTimeoutMinutes()
        let closed = try await channelSessionStore.expireInactiveSessions(
            timeoutByChannel: timeoutByChannel,
            globalDefaultTimeoutMinutes: globalDefault
        )
        for summary in closed {
            clearChannelSessionDirectories(channelID: summary.channelId)
            await handleGatewayChannelClosedForMemoryCheckpoint(summary)
        }
        return try await channelSessionStore.listSessions(
            status: status,
            channelIds: filteredChannelIDs,
            recentMessagesLimit: recentMessagesLimit,
            limit: limit,
            offset: offset
        )
    }

    public func getChannelSession(sessionID: String) async throws -> ChannelSessionDetail {
        await waitForStartup()
        return try await channelSessionStore.loadSessionDetail(sessionID: sessionID)
    }

    public func deleteChannelSession(sessionID: String) async throws {
        await waitForStartup()
        let detail = try? await channelSessionStore.loadSessionDetail(sessionID: sessionID)
        try await channelSessionStore.deleteSession(sessionID: sessionID)
        if let channelID = detail?.summary.channelId {
            clearChannelSessionDirectories(channelID: channelID)
        }
    }

    /// Returns one dashboard project by identifier.
    func prepareChannelSession(channelId: String) async throws {
        let normalizedChannelID = normalizeWhitespace(channelId)
        guard !normalizedChannelID.isEmpty else {
            return
        }

        let board = try? getActorBoard()
        let timeoutByChannel = channelSessionTimeouts(
            board: board,
            limitToChannelIDs: Set([normalizedChannelID])
        )
        let globalDefault = globalChannelInactivityTimeoutMinutes()
        let closed = try await channelSessionStore.expireInactiveSessions(
            timeoutByChannel: timeoutByChannel,
            globalDefaultTimeoutMinutes: globalDefault
        )
        for summary in closed {
            clearChannelSessionDirectories(channelID: summary.channelId)
            await handleGatewayChannelClosedForMemoryCheckpoint(summary)
        }
    }

    func clearChannelSessionDirectories(channelID: String) {
        channelExtraRoots.removeValue(forKey: channelID)
        channelWorkingDirectories.removeValue(forKey: channelID)
    }

    func globalChannelInactivityTimeoutMinutes() -> Int? {
        let days = currentConfig.channels.channelInactivityDays
        guard days > 0 else { return nil }
        return days * 24 * 60
    }

    func channelSessionTimeouts(
        board: ActorBoardSnapshot?,
        limitToChannelIDs: Set<String>? = nil
    ) -> [String: Int] {
        guard let board else {
            return [:]
        }

        var timeoutByChannel: [String: Int] = [:]
        let sortedNodes = board.nodes.sorted { left, right in
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }

        for node in sortedNodes {
            let channelID = normalizeWhitespace(node.channelId ?? "")
            let agentID = normalizeWhitespace(node.linkedAgentId ?? "")
            guard !channelID.isEmpty, !agentID.isEmpty else {
                continue
            }
            if let limitToChannelIDs, !limitToChannelIDs.contains(channelID) {
                continue
            }
            if timeoutByChannel[channelID] != nil {
                continue
            }

            guard let config = try? getAgentConfig(agentID: agentID) else {
                continue
            }
            guard config.channelSessions.autoCloseEnabled else {
                continue
            }
            timeoutByChannel[channelID] = max(1, config.channelSessions.autoCloseAfterMinutes)
        }

        return timeoutByChannel
    }

    func boundChannelIDs(agentID: String, board: ActorBoardSnapshot?) -> Set<String> {
        var bindings: Set<String> = []

        if let board {
            for node in board.nodes where normalizeWhitespace(node.linkedAgentId ?? "") == agentID {
                let channelID = normalizeWhitespace(node.channelId ?? "")
                if !channelID.isEmpty {
                    bindings.insert(channelID)
                }
            }
        }

        if let config = try? getAgentConfig(agentID: agentID) {
            bindings.formUnion(config.channelSessions.allowedChannelIds.map(normalizeWhitespace).filter { !$0.isEmpty })
            bindings = bindings.filter { binding in
                !config.channelSessions.excludedChannelIds.contains { excluded in
                    channelBindingMatches(excluded, channelID: binding)
                }
            }
        }

        return bindings
    }

    func linkedAgentID(forChannelID channelID: String, board: ActorBoardSnapshot?) -> String? {
        let normalizedChannelID = normalizeWhitespace(
            ChannelGatewayScope.parse(channelID).baseChannelId
        )
        guard !normalizedChannelID.isEmpty else {
            return nil
        }

        if let board {
            for node in board.nodes {
                guard channelBindingMatches(node.channelId ?? "", channelID: normalizedChannelID) else {
                    continue
                }
                let linkedAgentID = normalizeWhitespace(node.linkedAgentId ?? "")
                if !linkedAgentID.isEmpty, !agent(linkedAgentID, excludesChannelID: normalizedChannelID) {
                    return linkedAgentID
                }
            }
        }

        guard let agents = try? listAgents() else {
            return nil
        }
        for agent in agents {
            guard let config = try? getAgentConfig(agentID: agent.id) else {
                continue
            }
            if config.channelSessions.excludedChannelIds.contains(where: { channelBindingMatches($0, channelID: normalizedChannelID) }) {
                continue
            }
            if config.channelSessions.allowedChannelIds.contains(where: { channelBindingMatches($0, channelID: normalizedChannelID) }) {
                return agent.id
            }
        }
        return nil
    }

    func agent(_ agentID: String, excludesChannelID channelID: String) -> Bool {
        guard let config = try? getAgentConfig(agentID: agentID) else {
            return false
        }
        return config.channelSessions.excludedChannelIds.contains { excluded in
            channelBindingMatches(excluded, channelID: channelID)
        }
    }

    func channelBindingMatches(_ binding: String, channelID: String) -> Bool {
        let normalizedBinding = normalizeWhitespace(ChannelGatewayScope.parse(binding).baseChannelId)
        let normalizedChannelID = normalizeWhitespace(ChannelGatewayScope.parse(channelID).baseChannelId)
        guard !normalizedBinding.isEmpty, !normalizedChannelID.isEmpty else {
            return false
        }
        return ChannelGatewayScope.sessionMatchesBinding(
            sessionChannelId: normalizedChannelID,
            bindingChannelId: normalizedBinding
        )
    }

}

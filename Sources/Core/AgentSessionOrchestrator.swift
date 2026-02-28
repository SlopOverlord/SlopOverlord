import Foundation
import AgentRuntime
import Protocols

actor AgentSessionOrchestrator {
    private static let sessionContextBootstrapMarker = "[agent_session_context_bootstrap_v1]"
    typealias ToolInvoker = @Sendable (String, String, ToolInvocationRequest) async -> ToolInvocationResult

    enum OrchestratorError: Error {
        case invalidAgentID
        case invalidSessionID
        case invalidPayload
        case agentNotFound
        case sessionNotFound
        case storageFailure
    }

    private let runtime: RuntimeSystem
    private let sessionStore: AgentSessionFileStore
    private let agentCatalogStore: AgentCatalogFileStore
    private var toolInvoker: ToolInvoker?

    private var activeSessionRunChannels: Set<String> = []
    private var interruptedSessionRunChannels: Set<String> = []
    private var streamedAssistantByChannel: [String: String] = [:]
    private var streamedAssistantLastPersistedByChannel: [String: String] = [:]
    private var streamedAssistantLastPersistedAtByChannel: [String: Date] = [:]

    init(
        runtime: RuntimeSystem,
        sessionStore: AgentSessionFileStore,
        agentCatalogStore: AgentCatalogFileStore,
        toolInvoker: ToolInvoker? = nil
    ) {
        self.runtime = runtime
        self.sessionStore = sessionStore
        self.agentCatalogStore = agentCatalogStore
        self.toolInvoker = toolInvoker
    }

    func updateAgentsRootURL(_ url: URL) {
        sessionStore.updateAgentsRootURL(url)
        agentCatalogStore.updateAgentsRootURL(url)
    }

    func updateToolInvoker(_ toolInvoker: ToolInvoker?) {
        self.toolInvoker = toolInvoker
    }

    func createSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        do {
            let summary = try sessionStore.createSession(agentID: agentID, request: request)
            do {
                try await ensureSessionContextLoaded(agentID: agentID, sessionID: summary.id)
            } catch {
                try? sessionStore.deleteSession(agentID: agentID, sessionID: summary.id)
                throw OrchestratorError.storageFailure
            }
            return summary
        } catch {
            throw mapSessionStoreError(error)
        }
    }

    func postMessage(
        agentID: String,
        sessionID: String,
        request: AgentSessionPostMessageRequest
    ) async throws -> AgentSessionMessageResponse {
        do {
            try await ensureSessionContextLoaded(agentID: agentID, sessionID: sessionID)
        } catch {
            throw OrchestratorError.storageFailure
        }

        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !request.attachments.isEmpty else {
            throw OrchestratorError.invalidPayload
        }

        let attachments: [AgentAttachment]
        do {
            attachments = try sessionStore.persistAttachments(
                agentID: agentID,
                sessionID: sessionID,
                uploads: request.attachments
            )
        } catch {
            throw mapSessionStoreError(error)
        }

        var userSegments: [AgentMessageSegment] = []
        if !content.isEmpty {
            userSegments.append(.init(kind: .text, text: content))
        }
        userSegments += attachments.map { attachment in
            .init(kind: .attachment, attachment: attachment)
        }

        let userMessage = AgentSessionMessage(
            role: .user,
            segments: userSegments,
            userId: request.userId
        )

        let thinkingText =
            """
            Building route plan and evaluating context budget.
            - Agent: \(agentID)
            - Session: \(sessionID)
            - Attachments: \(attachments.count)
            """

        let thinkingStatus = AgentRunStatusEvent(
            stage: .thinking,
            label: "Thinking",
            details: "Planning response strategy.",
            expandedText: thinkingText
        )

        var initialEvents: [AgentSessionEvent] = [
            AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .message,
                message: userMessage
            ),
            AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .runStatus,
                runStatus: thinkingStatus
            )
        ]

        let shouldSearch = shouldUseSearchStage(content: content, attachmentCount: attachments.count)
        if shouldSearch {
            initialEvents.append(
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .searching,
                        label: "Searching",
                        details: "Collecting relevant context."
                    )
                )
            )
        }

        initialEvents.append(
            AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: .responding,
                    label: "Responding",
                    details: "Generating response..."
                )
            )
        )

        var summary: AgentSessionSummary
        do {
            summary = try sessionStore.appendEvents(
                agentID: agentID,
                sessionID: sessionID,
                events: initialEvents
            )
        } catch {
            throw mapSessionStoreError(error)
        }

        let channelID = sessionChannelID(agentID: agentID, sessionID: sessionID)
        activeSessionRunChannels.insert(channelID)
        interruptedSessionRunChannels.remove(channelID)
        streamedAssistantByChannel[channelID] = ""
        streamedAssistantLastPersistedByChannel[channelID] = ""
        streamedAssistantLastPersistedAtByChannel[channelID] = .distantPast
        defer {
            cleanupSessionRunTracking(channelID: channelID)
        }

        let messageContent = content.isEmpty ? "User attached files." : content
        let routeDecision = await runtime.postMessage(
            channelId: channelID,
            request: ChannelMessageRequest(userId: request.userId, content: messageContent),
            onResponseChunk: { [weak self] partialText in
                guard let self else {
                    return false
                }
                return await self.handleSessionResponseChunk(
                    agentID: agentID,
                    sessionID: sessionID,
                    channelID: channelID,
                    partialText: partialText
                )
            },
            toolInvoker: { [weak self] toolRequest in
                guard let self else {
                    return ToolInvocationResult(
                        tool: toolRequest.tool,
                        ok: false,
                        error: ToolErrorPayload(
                            code: "tool_invoker_unavailable",
                            message: "Tool invoker is unavailable.",
                            retryable: true
                        )
                    )
                }
                return await self.invokeTool(agentID: agentID, sessionID: sessionID, request: toolRequest)
            }
        )

        let snapshot = await runtime.channelState(channelId: channelID)
        let streamedAssistantText = streamedAssistantByChannel[channelID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let assistantTextFromSnapshot = snapshot?.messages.reversed().first(where: {
            $0.userId == "system" && !$0.content.contains(Self.sessionContextBootstrapMarker)
        })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let assistantText = !streamedAssistantText.isEmpty
            ? streamedAssistantText
            : (!assistantTextFromSnapshot.isEmpty ? assistantTextFromSnapshot : "Done.")
        let wasInterrupted = interruptedSessionRunChannels.contains(channelID)

        var finalEvents: [AgentSessionEvent] = []
        if request.spawnSubSession {
            let childSummary: AgentSessionSummary
            do {
                childSummary = try sessionStore.createSession(
                    agentID: agentID,
                    request: AgentSessionCreateRequest(
                        title: "Sub-session \(Date().formatted(date: .omitted, time: .shortened))",
                        parentSessionId: sessionID
                    )
                )
                try await ensureSessionContextLoaded(agentID: agentID, sessionID: childSummary.id)
            } catch {
                if let storeError = error as? AgentSessionFileStore.StoreError {
                    throw mapSessionStoreError(storeError)
                }
                throw OrchestratorError.storageFailure
            }

            finalEvents.append(
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .subSession,
                    subSession: AgentSubSessionEvent(
                        childSessionId: childSummary.id,
                        title: childSummary.title
                    )
                )
            )
        }

        if !assistantText.isEmpty {
            finalEvents.append(
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .message,
                    message: AgentSessionMessage(
                        role: .assistant,
                        segments: [
                            .init(kind: .text, text: assistantText)
                        ],
                        userId: "agent"
                    )
                )
            )
        }

        if wasInterrupted {
            finalEvents.append(
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .interrupted,
                        label: "Interrupted",
                        details: "Response generation stopped."
                    )
                )
            )
        } else if isAssistantErrorText(assistantText) {
            finalEvents.append(
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .interrupted,
                        label: "Error",
                        details: assistantText
                    )
                )
            )
        } else {
            finalEvents.append(
                AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .done,
                        label: "Done",
                        details: "Response is ready."
                    )
                )
            )
        }

        if !finalEvents.isEmpty {
            do {
                summary = try sessionStore.appendEvents(
                    agentID: agentID,
                    sessionID: sessionID,
                    events: finalEvents
                )
            } catch {
                throw mapSessionStoreError(error)
            }
        }

        return AgentSessionMessageResponse(
            summary: summary,
            appendedEvents: initialEvents + finalEvents,
            routeDecision: routeDecision
        )
    }

    func controlSession(
        agentID: String,
        sessionID: String,
        request: AgentSessionControlRequest
    ) throws -> AgentSessionMessageResponse {
        let statusStage: AgentRunStage
        let statusLabel: String
        switch request.action {
        case .pause:
            statusStage = .paused
            statusLabel = "Paused"
        case .resume:
            statusStage = .thinking
            statusLabel = "Resumed"
        case .interrupt:
            statusStage = .interrupted
            statusLabel = "Interrupted"
            interruptedSessionRunChannels.insert(sessionChannelID(agentID: agentID, sessionID: sessionID))
        }

        let events = [
            AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .runControl,
                runControl: AgentRunControlEvent(
                    action: request.action,
                    requestedBy: request.requestedBy,
                    reason: request.reason
                )
            ),
            AgentSessionEvent(
                agentId: agentID,
                sessionId: sessionID,
                type: .runStatus,
                runStatus: AgentRunStatusEvent(
                    stage: statusStage,
                    label: statusLabel,
                    details: request.reason
                )
            )
        ]

        let summary: AgentSessionSummary
        do {
            summary = try sessionStore.appendEvents(
                agentID: agentID,
                sessionID: sessionID,
                events: events
            )
        } catch {
            throw mapSessionStoreError(error)
        }

        return AgentSessionMessageResponse(summary: summary, appendedEvents: events, routeDecision: nil)
    }

    private func cleanupSessionRunTracking(channelID: String) {
        activeSessionRunChannels.remove(channelID)
        interruptedSessionRunChannels.remove(channelID)
        streamedAssistantByChannel.removeValue(forKey: channelID)
        streamedAssistantLastPersistedByChannel.removeValue(forKey: channelID)
        streamedAssistantLastPersistedAtByChannel.removeValue(forKey: channelID)
    }

    private func handleSessionResponseChunk(
        agentID: String,
        sessionID: String,
        channelID: String,
        partialText: String
    ) async -> Bool {
        let normalized = partialText.replacingOccurrences(of: "\r\n", with: "\n")
        streamedAssistantByChannel[channelID] = normalized

        if interruptedSessionRunChannels.contains(channelID) {
            return false
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let lastPersistedText = streamedAssistantLastPersistedByChannel[channelID] ?? ""
        let lastPersistedAt = streamedAssistantLastPersistedAtByChannel[channelID] ?? .distantPast
        let now = Date()
        let progressed = max(0, normalized.count - lastPersistedText.count)
        let shouldPersist = lastPersistedText.isEmpty ||
            progressed >= 24 ||
            now.timeIntervalSince(lastPersistedAt) >= 0.35

        if shouldPersist {
            do {
                _ = try sessionStore.appendEvents(
                    agentID: agentID,
                    sessionID: sessionID,
                    events: [
                        AgentSessionEvent(
                            agentId: agentID,
                            sessionId: sessionID,
                            type: .runStatus,
                            runStatus: AgentRunStatusEvent(
                                stage: .responding,
                                label: "Responding",
                                details: "Generating response...",
                                expandedText: normalized
                            )
                        )
                    ]
                )
                streamedAssistantLastPersistedByChannel[channelID] = normalized
                streamedAssistantLastPersistedAtByChannel[channelID] = now
            } catch {
                return false
            }
        }

        return !interruptedSessionRunChannels.contains(channelID)
    }

    private func shouldUseSearchStage(content: String, attachmentCount: Int) -> Bool {
        if attachmentCount > 0 {
            return true
        }

        let lower = content.lowercased()
        let keywords = ["search", "find", "google", "lookup", "research", "найди", "поиск", "исследуй"]
        return keywords.contains(where: lower.contains)
    }

    private func isAssistantErrorText(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            return false
        }

        return value.hasPrefix("model provider error:") ||
            value.hasPrefix("error:") ||
            value.contains(" failed") ||
            value.contains("exception")
    }

    private func sessionChannelID(agentID: String, sessionID: String) -> String {
        "agent:\(agentID):session:\(sessionID)"
    }

    private func invokeTool(
        agentID: String,
        sessionID: String,
        request: ToolInvocationRequest
    ) async -> ToolInvocationResult {
        guard let toolInvoker else {
            return ToolInvocationResult(
                tool: request.tool,
                ok: false,
                error: ToolErrorPayload(
                    code: "tool_invoker_unavailable",
                    message: "Tool invoker is unavailable.",
                    retryable: true
                )
            )
        }
        return await toolInvoker(agentID, sessionID, request)
    }

    private func ensureSessionContextLoaded(agentID: String, sessionID: String) async throws {
        let channelID = sessionChannelID(agentID: agentID, sessionID: sessionID)
        if let existingSnapshot = await runtime.channelState(channelId: channelID),
           existingSnapshot.messages.contains(where: {
               $0.userId == "system" && $0.content.contains(Self.sessionContextBootstrapMarker)
           }) {
            return
        }

        let documents: AgentDocumentBundle
        do {
            documents = try agentCatalogStore.readAgentDocuments(agentID: agentID)
        } catch {
            throw OrchestratorError.storageFailure
        }
        let bootstrapMessage = sessionBootstrapContextMessage(
            agentID: agentID,
            sessionID: sessionID,
            documents: documents
        )
        await runtime.appendSystemMessage(channelId: channelID, content: bootstrapMessage)
    }

    private func sessionBootstrapContextMessage(
        agentID: String,
        sessionID: String,
        documents: AgentDocumentBundle
    ) -> String {
        """
        \(Self.sessionContextBootstrapMarker)
        Session context initialized.
        Agent: \(agentID)
        Session: \(sessionID)

        [Agents.md]
        \(documents.agentsMarkdown)

        [User.md]
        \(documents.userMarkdown)

        [Identity.md]
        \(documents.identityMarkdown)

        [Soul.md]
        \(documents.soulMarkdown)
        """
    }

    private func mapSessionStoreError(_ error: Error) -> OrchestratorError {
        guard let storeError = error as? AgentSessionFileStore.StoreError else {
            return .storageFailure
        }

        switch storeError {
        case .invalidAgentID:
            return .invalidAgentID
        case .invalidSessionID:
            return .invalidSessionID
        case .agentNotFound:
            return .agentNotFound
        case .sessionNotFound:
            return .sessionNotFound
        case .invalidPayload:
            return .invalidPayload
        }
    }
}

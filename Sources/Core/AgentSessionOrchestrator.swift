import Foundation
import AgentRuntime
import Logging
import Protocols

actor AgentSessionOrchestrator {
    private static let sessionContextBootstrapMarker = "[agent_session_context_bootstrap_v1]"
    typealias ToolInvoker = @Sendable (String, String, ToolInvocationRequest) async -> ToolInvocationResult
    typealias ResponseChunkObserver = @Sendable (String, String, String) async -> Void

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
    private let agentSkillsStore: AgentSkillsFileStore?
    private let promptComposer: AgentPromptComposer
    private var availableModels: [ProviderModelOption]
    private let logger: Logger
    private var toolInvoker: ToolInvoker?
    private var responseChunkObserver: ResponseChunkObserver?

    private var activeSessionRunChannels: Set<String> = []
    private var interruptedSessionRunChannels: Set<String> = []
    private var streamedAssistantByChannel: [String: String] = [:]
    private var streamedAssistantLastPersistedByChannel: [String: String] = [:]
    private var streamedAssistantLastPersistedAtByChannel: [String: Date] = [:]

    init(
        runtime: RuntimeSystem,
        sessionStore: AgentSessionFileStore,
        agentCatalogStore: AgentCatalogFileStore,
        agentSkillsStore: AgentSkillsFileStore? = nil,
        promptComposer: AgentPromptComposer = AgentPromptComposer(),
        availableModels: [ProviderModelOption],
        toolInvoker: ToolInvoker? = nil,
        responseChunkObserver: ResponseChunkObserver? = nil,
        logger: Logger = Logger(label: "sloppy.core.sessions")
    ) {
        self.runtime = runtime
        self.sessionStore = sessionStore
        self.agentCatalogStore = agentCatalogStore
        self.agentSkillsStore = agentSkillsStore
        self.promptComposer = promptComposer
        self.availableModels = availableModels
        self.toolInvoker = toolInvoker
        self.responseChunkObserver = responseChunkObserver
        self.logger = logger
    }

    func updateAgentsRootURL(_ url: URL) {
        sessionStore.updateAgentsRootURL(url)
        agentCatalogStore.updateAgentsRootURL(url)
    }

    func updateAvailableModels(_ models: [ProviderModelOption]) {
        availableModels = models
    }

    func updateToolInvoker(_ toolInvoker: ToolInvoker?) {
        self.toolInvoker = toolInvoker
    }

    func updateResponseChunkObserver(_ observer: ResponseChunkObserver?) {
        self.responseChunkObserver = observer
    }

    func createSession(agentID: String, request: AgentSessionCreateRequest) async throws -> AgentSessionSummary {
        logger.info(
            "Session creation requested",
            metadata: [
                "agent_id": .string(agentID),
                "title": .string(optionalString(request.title)),
                "parent_session_id": .string(optionalString(request.parentSessionId))
            ]
        )

        do {
            let summary = try sessionStore.createSession(agentID: agentID, request: request)
            do {
                try await ensureSessionContextLoaded(agentID: agentID, sessionID: summary.id)
            } catch {
                logger.error(
                    "Session context bootstrap failed",
                    metadata: [
                        "agent_id": .string(agentID),
                        "session_id": .string(summary.id)
                    ]
                )
                try? sessionStore.deleteSession(agentID: agentID, sessionID: summary.id)
                throw OrchestratorError.storageFailure
            }

            logger.info(
                "Session created",
                metadata: [
                    "agent_id": .string(summary.agentId),
                    "session_id": .string(summary.id),
                    "title": .string(summary.title),
                    "parent_session_id": .string(optionalString(summary.parentSessionId))
                ]
            )
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

        let agentConfig: AgentConfigDetail
        do {
            agentConfig = try agentCatalogStore.getAgentConfig(agentID: agentID, availableModels: availableModels)
        } catch {
            throw OrchestratorError.storageFailure
        }

        let selectedModel = agentConfig.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModelCapabilities = Set(
            agentConfig.availableModels
                .first(where: { $0.id == selectedModel })?
                .capabilities
                .map { $0.lowercased() } ?? []
        )
        let reasoningEffort = selectedModelCapabilities.contains("reasoning") ? request.reasoningEffort : nil

        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !request.attachments.isEmpty else {
            throw OrchestratorError.invalidPayload
        }

        logger.info(
            "Session prompt accepted",
            metadata: [
                "agent_id": .string(agentID),
                "session_id": .string(sessionID),
                "user_id": .string(request.userId),
                "attachment_count": .stringConvertible(request.attachments.count),
                "prompt": .string(truncateForLog(content.isEmpty ? "[attachments_only_prompt]" : content))
            ]
        )

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
            request: ChannelMessageRequest(
                userId: request.userId,
                content: messageContent,
                model: selectedModel.isEmpty ? nil : selectedModel,
                reasoningEffort: reasoningEffort
            ),
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
                
                let toolCallEvent = AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .toolCall,
                    toolCall: AgentToolCallEvent(
                        tool: toolRequest.tool,
                        arguments: toolRequest.arguments,
                        reason: toolRequest.reason
                    )
                )
                
                let toolCallStatusEvent = AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .searching,
                        label: "Executing tool",
                        details: "Tool: \(toolRequest.tool)"
                    )
                )

                await self.appendEventsSafely(
                    agentID: agentID,
                    sessionID: sessionID,
                    events: [toolCallStatusEvent, toolCallEvent]
                )

                let result = await self.invokeTool(agentID: agentID, sessionID: sessionID, request: toolRequest)

                let toolResultEvent = AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .toolResult,
                    toolResult: AgentToolResultEvent(
                        tool: result.tool,
                        ok: result.ok,
                        data: result.data,
                        error: result.error,
                        durationMs: result.durationMs
                    )
                )

                let toolResultStatusEvent = AgentSessionEvent(
                    agentId: agentID,
                    sessionId: sessionID,
                    type: .runStatus,
                    runStatus: AgentRunStatusEvent(
                        stage: .responding,
                        label: "Responding",
                        details: "Generating response..."
                    )
                )

                await self.appendEventsSafely(
                    agentID: agentID,
                    sessionID: sessionID,
                    events: [toolResultEvent, toolResultStatusEvent]
                )

                return result
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

            logger.info(
                "Sub-session created from parent session",
                metadata: [
                    "agent_id": .string(agentID),
                    "parent_session_id": .string(sessionID),
                    "child_session_id": .string(childSummary.id),
                    "child_title": .string(childSummary.title)
                ]
            )

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

    private func appendEventsSafely(agentID: String, sessionID: String, events: [AgentSessionEvent]) {
        _ = try? sessionStore.appendEvents(agentID: agentID, sessionID: sessionID, events: events)
    }

    private func handleSessionResponseChunk(
        agentID: String,
        sessionID: String,
        channelID: String,
        partialText: String
    ) async -> Bool {
        let normalized = partialText.replacingOccurrences(of: "\r\n", with: "\n")
        streamedAssistantByChannel[channelID] = normalized

        if let responseChunkObserver {
            await responseChunkObserver(agentID, sessionID, normalized)
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
            value.hasPrefix("exception:")
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
            logger.debug(
                "Session context already initialized",
                metadata: [
                    "agent_id": .string(agentID),
                    "session_id": .string(sessionID)
                ]
            )
            return
        }

        let documents: AgentDocumentBundle
        do {
            documents = try agentCatalogStore.readAgentDocuments(agentID: agentID)
        } catch {
            throw OrchestratorError.storageFailure
        }
        let installedSkills = loadInstalledSkills(agentID: agentID)
        let bootstrapMessage: String
        do {
            bootstrapMessage = try promptComposer.compose(
                context: .agentSessionBootstrap(
                    agentID: agentID,
                    sessionID: sessionID,
                    bootstrapMarker: Self.sessionContextBootstrapMarker,
                    documents: documents,
                    installedSkills: installedSkills
                )
            )
        } catch {
            logger.warning(
                "Prompt composer failed, using fallback bootstrap prompt",
                metadata: [
                    "agent_id": .string(agentID),
                    "session_id": .string(sessionID),
                    "error": .string(String(describing: error))
                ]
            )
            bootstrapMessage = fallbackSessionBootstrapContextMessage(
                agentID: agentID,
                sessionID: sessionID,
                documents: documents
            )
        }

        logger.info(
            "Session bootstrap prompt prepared",
            metadata: [
                "agent_id": .string(agentID),
                "session_id": .string(sessionID),
                "agents_md_chars": .stringConvertible(documents.agentsMarkdown.count),
                "user_md_chars": .stringConvertible(documents.userMarkdown.count),
                "identity_md_chars": .stringConvertible(documents.identityMarkdown.count),
                "soul_md_chars": .stringConvertible(documents.soulMarkdown.count),
                "skills_count": .stringConvertible(installedSkills.count),
                "bootstrap_prompt": .string(truncateForLog(bootstrapMessage, limit: 24000))
            ]
        )

        await runtime.appendSystemMessage(channelId: channelID, content: bootstrapMessage)
    }

    private func fallbackSessionBootstrapContextMessage(
        agentID: String,
        sessionID: String,
        documents: AgentDocumentBundle
    ) -> String {
        let capabilitiesSection = renderedFallbackPromptPartial(
            named: "session_capabilities",
            fallback:
                """
                [Runtime capabilities]
                - This session runs with a persistent channel history and agent bootstrap context.
                - You can use available tools when the runtime exposes tool calls.
                - To call a tool, respond with exactly one JSON object and no surrounding prose: `{"tool":"<tool-id>","arguments":{},"reason":"<short reason>"}`
                - If you don't know the exact arguments or tools available, you MUST call `{"tool":"system.list_tools","arguments":{},"reason":"Discovering available tools"}` to get the catalog before attempting any unknown tool.
                - Common tools:
                  - `system.list_tools` with `{}`
                  - `files.read` with `{"path":"path/to/file"}`
                  - `files.write` with `{"path":"path/to/file","content":"..."}`
                  - `files.edit` with `{"path":"path/to/file","search":"old","replace":"new"}`
                  - `runtime.exec` with `{"command":"mkdir","arguments":["-p","agents/ceo"]}`
                """
        )
        let runtimeRulesSection = renderedFallbackPromptPartial(
            named: "runtime_rules",
            fallback:
                """
                [Runtime task-reference rules]
                - If user mentions task references like #MOBILE-1, call tool `project.task_get` with {"taskId":"MOBILE-1"} before answering.
                - Use fetched task details (status, priority, description, assignee) in the response.
                - If task is not found, explicitly say that and ask for a correct task id.
                - Blend your own concrete suggestions based on the user's goal, not only direct execution.
                """
        )
        let toolsInstructionSection = renderedFallbackPromptPartial(
            named: "tools_instruction",
            fallback:
                """
                [Tools usage rules]
                - You MUST request the list of available tools before answering the user if you don't know what tools are available.
                - You can get the available tools by using the appropriately named tool (e.g. `get_available_tools` or similar).
                - Do not guess the tool schemas or names. Always check the available tools first.
                """
        )

        return """
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

        \(capabilitiesSection)

        \(runtimeRulesSection)
        
        \(toolsInstructionSection)
        """
    }

    private func renderedFallbackPromptPartial(named name: String, fallback: String) -> String {
        do {
            let loader = PromptTemplateLoader()
            let renderer = PromptTemplateRenderer()
            let template = try loader.loadPartial(named: name)
            return try renderer.render(template: template, values: [:])
        } catch {
            logger.warning(
                "Fallback prompt partial rendering failed",
                metadata: [
                    "partial": .string(name),
                    "error": .string(String(describing: error))
                ]
            )
            return fallback
        }
    }

    private func loadInstalledSkills(agentID: String) -> [InstalledSkill] {
        guard let agentSkillsStore else {
            return []
        }

        do {
            return try agentSkillsStore.listSkills(agentID: agentID)
        } catch {
            logger.warning(
                "Failed to load installed skills for prompt bootstrap",
                metadata: [
                    "agent_id": .string(agentID),
                    "error": .string(String(describing: error))
                ]
            )
            return []
        }
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

    private func optionalString(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(none)" : trimmed
    }

    private func truncateForLog(_ value: String, limit: Int = 12000) -> String {
        guard value.count > limit else {
            return value
        }
        let endIndex = value.index(value.startIndex, offsetBy: limit)
        return "\(value[..<endIndex])… [truncated]"
    }
}

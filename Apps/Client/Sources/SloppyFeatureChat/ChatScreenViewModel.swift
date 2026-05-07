import AdaEngine
import Foundation
import Observation
import SloppyClientCore

@Observable
@MainActor
public final class ChatTranscriptState {
    public private(set) var messages: [ChatMessage] = []

    var isEmpty: Bool {
        messages.isEmpty
    }

    var lastMessage: ChatMessage? {
        messages.last
    }

    var hasEarlierMessages: Bool {
        false
    }

    var hiddenMessageCount: Int {
        0
    }

    func replaceAll(_ newMessages: [ChatMessage]) {
        messages = newMessages
    }

    func clear() {
        messages = []
    }

    func append(_ message: ChatMessage) {
        messages.append(message)
    }

    func removeAll(where shouldBeRemoved: (ChatMessage) -> Bool) {
        messages.removeAll(where: shouldBeRemoved)
    }

    func upsert(_ message: ChatMessage) {
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx] = message
        } else {
            messages.append(message)
        }
    }

    func revealEarlierMessages() {
        // Kept as a no-op for compatibility with older views/tests: all
        // loaded session messages are now visible and scrollable at once.
    }
}

@Observable
@MainActor
public final class ChatScreenViewModel {
    public private(set) var agents: [APIAgentRecord] = []
    public private(set) var selectedAgent: APIAgentRecord?
    public private(set) var sessions: [ChatSessionSummary] = []
    public var selectedSessionId: String?
    public private(set) var activeContextTitle: String?
    public private(set) var sessionActionStatus: String?
    public private(set) var isLoadingSessions = false
    public private(set) var isSending = false
    public var showAgentPicker = false
    public var showSessionPicker = false
    public let transcript = ChatTranscriptState()
    public let composerDraft = ChatComposerDraft()

    public var messages: [ChatMessage] {
        transcript.messages
    }

    @ObservationIgnored private let apiClient: SloppyAPIClient
    @ObservationIgnored private let settings: ClientSettings
    public let connectionMonitor: ConnectionMonitor
    @ObservationIgnored private let onOpenSettings: @MainActor () -> Void

    @ObservationIgnored private var socketManager: SessionSocketManager?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var sessionStatusTask: Task<Void, Never>?
    @ObservationIgnored private var streamingFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStreamingSessionId: String?
    @ObservationIgnored private var pendingStreamingAssistantText: String?
    @ObservationIgnored private var pendingNavigationRequest: ChatNavigationRequest?
    @ObservationIgnored private var lastAppliedNavigationRequestId: Int?
    @ObservationIgnored private var activeProjectId: String?
    @ObservationIgnored private var didLoadInitialData = false
    @ObservationIgnored private var isLoadingInitialData = false
    @ObservationIgnored private var sessionLoadGeneration = 0

    public init(
        apiClient: SloppyAPIClient,
        settings: ClientSettings,
        connectionMonitor: ConnectionMonitor,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.apiClient = apiClient
        self.settings = settings
        self.connectionMonitor = connectionMonitor
        self.onOpenSettings = onOpenSettings
    }

    public func openSettings() {
        onOpenSettings()
    }

    public func dismissOverlays() {
        showAgentPicker = false
        showSessionPicker = false
    }

    public func loadInitialData() {
        guard !didLoadInitialData, !isLoadingInitialData else { return }

        isLoadingInitialData = true
        Task { @MainActor in
            defer {
                didLoadInitialData = true
                isLoadingInitialData = false
            }

            let fetched = (try? await apiClient.fetchAgents()) ?? []
            agents = fetched

            let lastId = settings.lastAgentId
            let agent = fetched.first(where: { $0.id == lastId }) ?? fetched.first
            if let agent {
                selectedAgent = agent
                await loadSessions(for: agent)
                selectedSessionId = nil
                transcript.clear()
                activeContextTitle = nil
                activeProjectId = nil
                settings.lastSessionId = nil
            }

            if let pendingNavigationRequest {
                applyNavigationRequest(pendingNavigationRequest)
            }
        }
    }

    public func loadSessions(for agent: APIAgentRecord, projectId: String? = nil) async {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration
        isLoadingSessions = true
        let fetched = (try? await apiClient.fetchAgentSessions(agentId: agent.id, projectId: projectId)) ?? []
        guard generation == sessionLoadGeneration else { return }
        sessions = fetched
            .filter { $0.kind != "heartbeat" }
            .sorted { $0.updatedAt > $1.updatedAt }
        isLoadingSessions = false
    }

    public func pickAgent(_ agent: APIAgentRecord) {
        showAgentPicker = false
        switchAgent(agent)
    }

    public func pickSession(_ session: ChatSessionSummary) {
        showSessionPicker = false
        selectSession(session.id, contextTitle: displayTitle(for: session), projectId: session.projectId)
    }

    public func pickNewSession() {
        showSessionPicker = false
        startNewSession()
    }

    public func deleteSession(_ session: ChatSessionSummary) {
        guard let agent = selectedAgent else { return }
        Task { @MainActor in
            do {
                try await apiClient.deleteAgentSession(agentId: agent.id, sessionId: session.id)
                sessions.removeAll { $0.id == session.id }

                if selectedSessionId == session.id {
                    disconnectCurrentSession()
                    selectedSessionId = nil
                    settings.lastSessionId = nil
                    transcript.clear()
                    activeContextTitle = nil
                    activeProjectId = nil
                }

                showSessionStatus("Deleted \(displayTitle(for: session))")
            } catch {
                showSessionStatus("Could not delete \(displayTitle(for: session))")
            }
        }
    }

    #if DEBUG
    public func downloadSession(_ session: ChatSessionSummary) {
        guard let agent = selectedAgent else { return }
        Task { @MainActor in
            do {
                let data = try await apiClient.fetchAgentSessionData(agentId: agent.id, sessionId: session.id)
                let fileURL = try saveDebugSessionData(data, session: session)
                showSessionStatus("Saved \(fileURL.lastPathComponent)")
            } catch {
                showSessionStatus("Could not save \(displayTitle(for: session))")
            }
        }
    }
    #endif

    public func applyNavigationRequest(_ request: ChatNavigationRequest?) {
        guard let request else { return }
        guard lastAppliedNavigationRequestId != request.id else { return }

        if agents.isEmpty {
            pendingNavigationRequest = request
            return
        }

        pendingNavigationRequest = nil
        lastAppliedNavigationRequestId = request.id
        dismissOverlays()

        switch request.context {
        case .blank:
            routeToBlankChat()
        case .project(let projectId, let projectName, _):
            routeToContext(request, projectId: projectId, title: "Project: \(projectName)")
        case .task(let projectId, let projectName, let taskId, let taskTitle, _):
            routeToContext(
                request,
                projectId: projectId,
                title: "\(projectName) / \(taskTitle)",
                preferredSessionTitle: taskTitle,
                preferredTaskId: taskId
            )
        }
    }

    private func switchAgent(_ agent: APIAgentRecord) {
        disconnectCurrentSession()
        selectedAgent = agent
        selectedSessionId = nil
        transcript.clear()
        activeContextTitle = nil
        activeProjectId = nil
        settings.lastAgentId = agent.id
        settings.lastSessionId = nil
        Task { @MainActor in
            await loadSessions(for: agent)
        }
    }

    private func startNewSession() {
        guard let agent = selectedAgent else { return }
        disconnectCurrentSession()
        let contextTitle = activeContextTitle
        let projectId = activeProjectId
        transcript.clear()
        selectedSessionId = nil
        activeContextTitle = contextTitle
        activeProjectId = projectId
        Task { @MainActor in
            guard let summary = try? await apiClient.createAgentSession(
                agentId: agent.id,
                title: contextTitle ?? "Chat with \(agent.displayName)",
                projectId: projectId
            ) else { return }
            sessions.insert(summary, at: 0)
            selectedSessionId = summary.id
            settings.lastSessionId = summary.id
            connectToSession(agentId: agent.id, sessionId: summary.id)
        }
    }

    private func selectSession(
        _ sessionId: String,
        contextTitle: String? = nil,
        projectId: String? = nil
    ) {
        guard let agent = selectedAgent else { return }
        let retainedContextTitle = contextTitle ?? activeContextTitle
        let retainedProjectId = projectId ?? activeProjectId
        disconnectCurrentSession()
        transcript.clear()
        selectedSessionId = sessionId
        activeContextTitle = retainedContextTitle
        activeProjectId = retainedProjectId
        settings.lastSessionId = sessionId
        connectToSession(agentId: agent.id, sessionId: sessionId)
    }

    private func routeToBlankChat() {
        let agent = selectedAgent ?? agents.first
        guard let agent else {
            selectedAgent = nil
            selectedSessionId = nil
            transcript.clear()
            activeContextTitle = nil
            activeProjectId = nil
            return
        }

        activateDraft(agent: agent, contextTitle: nil)
    }

    private func routeToContext(
        _ request: ChatNavigationRequest,
        projectId: String,
        title: String,
        preferredSessionTitle: String? = nil,
        preferredTaskId: String? = nil
    ) {
        let agent = agentForNavigation(request) ?? selectedAgent ?? agents.first
        guard let agent else {
            selectedAgent = nil
            selectedSessionId = nil
            transcript.clear()
            activeContextTitle = title
            activeProjectId = projectId
            return
        }

        activateProjectContext(
            agent: agent,
            projectId: projectId,
            contextTitle: title,
            preferredSessionTitle: preferredSessionTitle,
            preferredTaskId: preferredTaskId
        )
    }

    private func agentForNavigation(_ request: ChatNavigationRequest) -> APIAgentRecord? {
        guard let preferredAgentId = request.preferredAgentId else { return nil }
        return agents.first {
            $0.id.caseInsensitiveCompare(preferredAgentId) == .orderedSame
        }
    }

    private func activateDraft(agent: APIAgentRecord, contextTitle: String?) {
        disconnectCurrentSession()
        selectedAgent = agent
        selectedSessionId = nil
        transcript.clear()
        activeContextTitle = contextTitle
        activeProjectId = nil
        settings.lastAgentId = agent.id
        settings.lastSessionId = nil

        Task { @MainActor in
            await loadSessions(for: agent)
        }
    }

    private func activateProjectContext(
        agent: APIAgentRecord,
        projectId: String,
        contextTitle: String,
        preferredSessionTitle: String?,
        preferredTaskId: String?
    ) {
        disconnectCurrentSession()
        selectedAgent = agent
        selectedSessionId = nil
        transcript.clear()
        activeContextTitle = contextTitle
        activeProjectId = projectId
        settings.lastAgentId = agent.id
        settings.lastSessionId = nil

        Task { @MainActor in
            await loadSessions(for: agent, projectId: preferredTaskId == nil ? projectId : nil)
            guard selectedAgent?.id == agent.id,
                  activeProjectId == projectId,
                  selectedSessionId == nil else {
                return
            }

            guard let session = preferredSession(
                in: sessions,
                title: preferredSessionTitle,
                taskId: preferredTaskId,
                projectId: projectId,
                allowsFallback: preferredTaskId == nil
            ) else {
                guard let taskId = preferredTaskId else {
                    return
                }

                guard let summary = try? await apiClient.createAgentSession(
                    agentId: agent.id,
                    title: taskSessionTitle(for: taskId),
                    projectId: projectId
                ) else {
                    return
                }

                guard selectedAgent?.id == agent.id,
                      activeProjectId == projectId,
                      selectedSessionId == nil else {
                    return
                }

                sessions.insert(summary, at: 0)
                selectSession(summary.id, contextTitle: contextTitle, projectId: projectId)
                return
            }

            selectSession(session.id, contextTitle: contextTitle, projectId: projectId)
        }
    }

    private func disconnectCurrentSession() {
        let manager = socketManager
        streamTask?.cancel()
        streamTask = nil
        cancelPendingStreamingAssistantText()
        socketManager = nil
        if let manager {
            Task { await manager.disconnect() }
        }
    }

    private func connectToSession(agentId: String, sessionId: String) {
        let manager = SessionSocketManager(baseURL: apiClient.baseURL, agentId: agentId, sessionId: sessionId)
        socketManager = manager

        streamTask = Task { @MainActor in
            defer {
                Task { await manager.disconnect() }
            }

            if let detail = try? await apiClient.fetchAgentSession(agentId: agentId, sessionId: sessionId) {
                guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
                transcript.replaceAll(detail.messages)
            }

            let stream = await manager.connect()

            for await update in stream {
                guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
                await handleStreamUpdate(update, agentId: agentId, sessionId: sessionId)
            }
        }
    }

    private func handleStreamUpdate(
        _ update: ChatStreamUpdate,
        agentId: String,
        sessionId: String
    ) async {
        switch update.kind {
        case .sessionReady:
            guard transcript.isEmpty else { break }
            if let detail = try? await apiClient.fetchAgentSession(agentId: agentId, sessionId: sessionId) {
                transcript.replaceAll(detail.messages)
            }
        case .sessionEvent, .sessionDelta:
            if update.kind == .sessionDelta, let text = update.messageText {
                scheduleStreamingAssistantText(text, sessionId: sessionId)
            } else if let msg = update.message {
                upsertMessage(msg, sessionId: sessionId)
            }
        case .sessionClosed, .sessionError:
            flushPendingStreamingAssistantText()
        case .heartbeat:
            break
        }
    }

    private func isCurrentSession(agentId: String, sessionId: String) -> Bool {
        selectedAgent?.id == agentId && selectedSessionId == sessionId
    }

    private func upsertMessage(_ message: ChatMessage, sessionId: String) {
        if message.role == .assistant {
            cancelPendingStreamingAssistantText(for: sessionId)
            transcript.removeAll { $0.id == streamingAssistantMessageId(for: sessionId) }
        } else if message.role == .user {
            transcript.removeAll { $0.id.hasPrefix("optimistic-user-") }
        }

        transcript.upsert(message)
    }

    private func scheduleStreamingAssistantText(_ text: String, sessionId: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingStreamingSessionId = sessionId
        pendingStreamingAssistantText = text

        guard streamingFlushTask == nil else {
            return
        }

        streamingFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            flushPendingStreamingAssistantText()
        }
    }

    private func flushPendingStreamingAssistantText() {
        guard let sessionId = pendingStreamingSessionId,
              let text = pendingStreamingAssistantText else {
            streamingFlushTask = nil
            return
        }

        pendingStreamingSessionId = nil
        pendingStreamingAssistantText = nil
        streamingFlushTask = nil
        applyStreamingAssistantText(text, sessionId: sessionId)
    }

    private func cancelPendingStreamingAssistantText(for sessionId: String? = nil) {
        guard sessionId == nil || pendingStreamingSessionId == sessionId else {
            return
        }

        streamingFlushTask?.cancel()
        streamingFlushTask = nil
        pendingStreamingSessionId = nil
        pendingStreamingAssistantText = nil
    }

    private func applyStreamingAssistantText(_ text: String, sessionId: String) {
        let id = streamingAssistantMessageId(for: sessionId)
        let message = ChatMessage(
            id: id,
            role: .assistant,
            segments: [ChatMessageSegment(kind: .text, text: text)]
        )

        transcript.upsert(message)
    }

    private func streamingAssistantMessageId(for sessionId: String) -> String {
        "streaming-assistant-\(sessionId)"
    }

    private func displayTitle(for session: ChatSessionSummary) -> String {
        session.title.isEmpty ? "Chat" : session.title
    }

    private func taskSessionTitle(for taskId: String) -> String {
        "task-\(taskId)"
    }

    private func preferredSession(
        in sessions: [ChatSessionSummary],
        title: String?,
        taskId: String? = nil,
        projectId: String? = nil,
        allowsFallback: Bool = true
    ) -> ChatSessionSummary? {
        let candidates = sessions
            .filter { $0.kind != "heartbeat" }
            .sorted { $0.updatedAt > $1.updatedAt }

        if let taskId = taskId?.trimmingCharacters(in: .whitespacesAndNewlines), !taskId.isEmpty {
            var normalizedTaskTitles = [taskSessionTitle(for: taskId)]
            if let projectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !projectId.isEmpty {
                normalizedTaskTitles.append("task-comment:\(projectId):\(taskId)")
            }
            normalizedTaskTitles = normalizedTaskTitles.map { $0.lowercased() }

            if let taskSession = candidates.first(where: { session in
                normalizedTaskTitles.contains(session.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }) {
                return taskSession
            }
        }

        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return allowsFallback ? candidates.first : nil
        }

        let normalizedTitle = title.lowercased()
        let titleMatch = candidates.first {
            let sessionTitle = $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return sessionTitle == normalizedTitle || sessionTitle.contains(normalizedTitle)
        }

        return titleMatch ?? (allowsFallback ? candidates.first : nil)
    }

    private func showSessionStatus(_ status: String) {
        sessionStatusTask?.cancel()
        sessionActionStatus = status
        sessionStatusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                sessionActionStatus = nil
            }
        }
    }

    #if DEBUG
    private func saveDebugSessionData(_ data: Data, session: ChatSessionSummary) throws -> URL {
        let fileManager = FileManager.default
        let fileName = "sloppy-session-\(safeFileName(displayTitle(for: session)))-\(session.id).json"
        let searchDirectories: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory,
            .documentDirectory,
        ]

        var lastError: Error?
        for directory in searchDirectories {
            do {
                let directoryURL = try fileManager.url(
                    for: directory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let fileURL = directoryURL.appendingPathComponent(fileName)
                try data.write(to: fileURL, options: .atomic)
                return fileURL
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitizedScalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(sanitizedScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "chat" : String(collapsed.prefix(48))
    }
    #endif

    public func sendMessage(content: String) {
        guard let agent = selectedAgent, !isSending else { return }

        if selectedSessionId == nil {
            Task { @MainActor in
                guard let summary = try? await apiClient.createAgentSession(
                    agentId: agent.id,
                    title: activeContextTitle ?? "Chat with \(agent.displayName)",
                    projectId: activeProjectId
                ) else { return }
                sessions.insert(summary, at: 0)
                selectedSessionId = summary.id
                settings.lastSessionId = summary.id
                connectToSession(agentId: agent.id, sessionId: summary.id)
                await postMessage(content: content, agentId: agent.id, sessionId: summary.id)
            }
            return
        }

        guard let sessionId = selectedSessionId else { return }
        Task { @MainActor in
            await postMessage(content: content, agentId: agent.id, sessionId: sessionId)
        }
    }

    private func postMessage(content: String, agentId: String, sessionId: String) async {
        isSending = true
        let optimistic = ChatMessage(
            id: "optimistic-user-\(UUID().uuidString)",
            role: .user,
            segments: [ChatMessageSegment(kind: .text, text: content)]
        )
        transcript.append(optimistic)
        _ = try? await apiClient.postSessionMessage(agentId: agentId, sessionId: sessionId, content: content)
        isSending = false
    }
}

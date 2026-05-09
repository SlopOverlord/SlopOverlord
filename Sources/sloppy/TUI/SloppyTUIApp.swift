import Foundation
import Protocols
import TauTUI

struct SloppyTUIApp {
    var configPath: String?
    var requestedSessionID: String?
    var initialAction: SloppyTUIInitialAction

    init(
        configPath: String? = nil,
        requestedSessionID: String? = nil,
        initialAction: SloppyTUIInitialAction = .none
    ) {
        self.configPath = configPath
        self.requestedSessionID = requestedSessionID
        self.initialAction = initialAction
    }

    @MainActor
    func run() async throws {
        let runtime = try await SloppyTUIBootstrap(configPath: configPath).prepare()
        defer {
            Task { await runtime.service.shutdownChannelPlugins() }
        }

        let project = try await runtime.service.resolveOrCreateProjectForCurrentDirectory(runtime.cwd)
        let stateStore = SloppyTUIStateStore(workspaceRoot: runtime.workspaceRoot)
        let state = stateStore.load()
        let selectionKey = SloppyTUIStateStore.selectionKey(projectId: project.id)
        let selection = state.selections[selectionKey]

        let agents = (try? await runtime.service.listAgents(includeSystem: false)) ?? []
        let resolved: SloppyTUILaunchSelection
        if let requestedSessionID = requestedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSessionID.isEmpty {
            let explicit = try await resolveExplicitSession(
                service: runtime.service,
                projectID: project.id,
                sessionID: requestedSessionID,
                agents: agents
            )
            resolved = SloppyTUILaunchSelection(
                agent: explicit.agent,
                session: explicit.session,
                hasPersistedSession: true
            )
        } else {
            let agent = try await resolveAgent(
                service: runtime.service,
                preferredID: selection?.agentId,
                agents: agents
            )
            resolved = SloppyTUILaunchSelection(
                agent: agent,
                session: Self.makeDraftSession(agent: agent, projectID: project.id),
                hasPersistedSession: false
            )
        }
        let agent = resolved.agent
        let session = resolved.session

        var nextState = state
        nextState.selections[selectionKey] = .init(
            agentId: agent.id,
            sessionId: resolved.hasPersistedSession ? session.id : nil
        )
        nextState.welcomeTipCursor = state.welcomeTipCursor + 1
        stateStore.save(nextState)

        try await withCheckedThrowingContinuation { continuation in
            do {
                try startTUI(
                    runtime: runtime,
                    project: project,
                    agent: agent,
                    session: session,
                    hasPersistedSession: resolved.hasPersistedSession,
                    stateStore: stateStore,
                    state: nextState,
                    welcomeTipCursor: state.welcomeTipCursor,
                    initialAction: initialAction,
                    continuation: continuation
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @MainActor
    private func startTUI(
        runtime: SloppyTUIRuntime,
        project: ProjectRecord,
        agent: AgentSummary,
        session: AgentSessionSummary,
        hasPersistedSession: Bool,
        stateStore: SloppyTUIStateStore,
        state: SloppyTUIState,
        welcomeTipCursor: Int,
        initialAction: SloppyTUIInitialAction,
        continuation: CheckedContinuation<Void, Error>
    ) throws {
        let runHandle = SloppyTUIRunHandle(continuation: continuation)
        do {
            let terminal = ProcessTerminal()
            let tui = TUI(terminal: terminal)
            let screen = SloppyTUIScreen(
                runtime: runtime,
                project: project,
                agent: agent,
                session: session,
                hasPersistedSession: hasPersistedSession,
                stateStore: stateStore,
                state: state,
                welcomeTipCursor: welcomeTipCursor,
                initialAction: initialAction,
                tui: tui,
                terminal: terminal
            )
            screen.onExit = { runHandle.finish() }
            runHandle.tui = tui
            runHandle.screen = screen
            tui.addChild(screen)
            tui.apply(theme: SloppyTUITheme.palette)
            tui.setFocus(screen)

            tui.onControlC = {
                Task { @MainActor in
                    screen.handleControlC()
                }
            }

            try tui.start()
            screen.start()
        } catch {
            runHandle.finish(with: error)
        }
    }

    private func resolveAgent(
        service: CoreService,
        preferredID: String?,
        agents: [AgentSummary]
    ) async throws -> AgentSummary {
        if let preferredID,
           let agent = agents.first(where: { $0.id == preferredID }) {
            return agent
        }
        if let first = agents.first {
            return first
        }
        return try await service.createAgent(
            AgentCreateRequest(
                id: "sloppy",
                displayName: "SLOPPY",
                role: "SLOPPY"
            )
        )
    }

    private func resolveExplicitSession(
        service: CoreService,
        projectID: String,
        sessionID: String,
        agents: [AgentSummary]
    ) async throws -> (agent: AgentSummary, session: AgentSessionSummary) {
        for agent in agents {
            let sessions = (try? await service.listAgentSessions(agentID: agent.id, projectID: projectID)) ?? []
            if let session = sessions.first(where: { $0.id == sessionID }) {
                return (agent, session)
            }
        }
        throw SloppyTUIError.sessionNotFound(sessionID)
    }

    static func makeDraftSession(agent: AgentSummary, projectID: String) -> AgentSessionSummary {
        AgentSessionSummary(
            id: "new",
            agentId: agent.id,
            title: "New session",
            projectId: projectID
        )
    }
}

private struct SloppyTUILaunchSelection {
    var agent: AgentSummary
    var session: AgentSessionSummary
    var hasPersistedSession: Bool
}

private enum SloppyTUIError: LocalizedError {
    case sessionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "No TUI session `\(id)` was found for this directory. Run `sloppy`, then choose `/sessions` to see available sessions."
        }
    }
}

enum SloppyTUIInitialAction {
    case none
    case modelPicker(exitAfterSelection: Bool)
}

@MainActor
private final class SloppyTUIRunHandle: @unchecked Sendable {
    var tui: TUI?
    var screen: SloppyTUIScreen?

    private var continuation: CheckedContinuation<Void, Error>?
    private var didFinish = false

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish() {
        finish(with: nil)
    }

    func finish(with error: Error?) {
        guard !didFinish else { return }
        didFinish = true

        screen?.stopBackgroundTasks()
        screen?.onExit = nil
        tui?.onControlC = nil
        tui?.stop()
        tui?.clear()

        let continuation = continuation
        self.continuation = nil
        screen = nil
        tui = nil

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

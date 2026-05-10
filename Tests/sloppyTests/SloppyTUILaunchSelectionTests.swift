import Foundation
import Testing
@testable import sloppy
@testable import Protocols

@Test
func tuiLaunchRestoresPersistedSessionSelection() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    defer {
        try? FileManager.default.removeItem(at: config.resolvedWorkspaceRootURL())
    }

    let agent = try await service.createAgent(
        AgentCreateRequest(id: "yadev", displayName: "YADev", role: "Developer")
    )
    let session = try await service.createAgentSession(
        agentID: agent.id,
        request: AgentSessionCreateRequest(projectId: "mobius")
    )

    let resolved = try await SloppyTUIApp.resolveLaunchSelection(
        service: service,
        projectID: "mobius",
        requestedSessionID: nil,
        selection: .init(agentId: agent.id, sessionId: session.id),
        agents: [agent]
    )

    #expect(resolved.agent.id == agent.id)
    #expect(resolved.session.id == session.id)
    #expect(resolved.hasPersistedSession)
}

@Test
func tuiLaunchFallsBackToDraftWhenPersistedSessionIsMissing() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    defer {
        try? FileManager.default.removeItem(at: config.resolvedWorkspaceRootURL())
    }

    let agent = try await service.createAgent(
        AgentCreateRequest(id: "yadev", displayName: "YADev", role: "Developer")
    )

    let resolved = try await SloppyTUIApp.resolveLaunchSelection(
        service: service,
        projectID: "mobius",
        requestedSessionID: nil,
        selection: .init(agentId: agent.id, sessionId: "session-missing"),
        agents: [agent]
    )

    #expect(resolved.agent.id == agent.id)
    #expect(resolved.session.id == "new")
    #expect(!resolved.hasPersistedSession)
}

@Test
func tuiLaunchRestoresLatestProjectSessionWhenSelectionHasNoSessionID() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    defer {
        try? FileManager.default.removeItem(at: config.resolvedWorkspaceRootURL())
    }

    let agent = try await service.createAgent(
        AgentCreateRequest(id: "yadev", displayName: "YADev", role: "Developer")
    )
    let session = try await service.createAgentSession(
        agentID: agent.id,
        request: AgentSessionCreateRequest(projectId: "mobius")
    )

    let resolved = try await SloppyTUIApp.resolveLaunchSelection(
        service: service,
        projectID: "mobius",
        requestedSessionID: nil,
        selection: .init(agentId: agent.id),
        agents: [agent]
    )

    #expect(resolved.agent.id == agent.id)
    #expect(resolved.session.id == session.id)
    #expect(resolved.hasPersistedSession)
}

@Test
func tuiLaunchRequestedSessionCanResolveWithoutProjectMetadata() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config, persistenceBuilder: InMemoryCorePersistenceBuilder())
    defer {
        try? FileManager.default.removeItem(at: config.resolvedWorkspaceRootURL())
    }

    let agent = try await service.createAgent(
        AgentCreateRequest(id: "yadev", displayName: "YADev", role: "Developer")
    )
    let legacySession = try await service.createAgentSession(
        agentID: agent.id,
        request: AgentSessionCreateRequest()
    )

    let resolved = try await SloppyTUIApp.resolveLaunchSelection(
        service: service,
        projectID: "mobius",
        requestedSessionID: legacySession.id,
        selection: nil,
        agents: [agent]
    )

    #expect(resolved.agent.id == agent.id)
    #expect(resolved.session.id == legacySession.id)
    #expect(resolved.hasPersistedSession)
}

import Foundation
import Testing
@testable import Protocols
@testable import sloppy

@Test
func agentSessionStoreCachesListsAndInvalidatesSummarySidecar() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "cache-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Cache Agent", role: "Testing"),
        availableModels: []
    )

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let session = try store.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Cached session")
    )
    let summaryURL = rootURL
        .appendingPathComponent(agentID, isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("\(session.id).summary.json")
    try? FileManager.default.removeItem(at: summaryURL)
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

    let warmed = try store.listSessions(agentID: agentID)
    #expect(warmed.map(\.id) == [session.id])
    #expect(FileManager.default.fileExists(atPath: summaryURL.path))

    let userEvent = AgentSessionEvent(
        agentId: agentID,
        sessionId: session.id,
        type: .message,
        createdAt: Date().addingTimeInterval(60),
        message: AgentSessionMessage(
            role: .user,
            segments: [AgentMessageSegment(kind: .text, text: "Fresh summary text")],
            userId: "tester"
        )
    )
    _ = try store.appendEvents(agentID: agentID, sessionID: session.id, events: [userEvent])
    let afterAppend = try store.listSessions(agentID: agentID)
    #expect(afterAppend.first?.messageCount == 1)
    #expect(afterAppend.first?.lastMessagePreview == "Fresh summary text")

    _ = try store.incrementUserTurnCount(agentID: agentID, sessionID: session.id)
    let afterTurnCount = try store.listSessions(agentID: agentID)
    #expect(afterTurnCount.first?.userTurnCount == 1)

    try store.deleteSession(agentID: agentID, sessionID: session.id)
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))
    #expect(try store.listSessions(agentID: agentID).isEmpty)
}

@Test
func agentSessionStorePaginatesCachedSessionList() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-pagination-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "paged-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Paged Agent", role: "Testing"),
        availableModels: []
    )

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let first = try store.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "First"))
    let second = try store.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Second"))
    let third = try store.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Third"))

    for (index, session) in [first, second, third].enumerated() {
        let event = AgentSessionEvent(
            agentId: agentID,
            sessionId: session.id,
            type: .message,
            createdAt: Date().addingTimeInterval(TimeInterval(index + 1) * 60),
            message: AgentSessionMessage(
                role: .user,
                segments: [AgentMessageSegment(kind: .text, text: "message \(index)")],
                userId: "tester"
            )
        )
        _ = try store.appendEvents(agentID: agentID, sessionID: session.id, events: [event])
    }

    let page = try store.listSessions(agentID: agentID, limit: 1, offset: 1)
    #expect(page.count == 1)
    #expect(page.first?.id == second.id)
}

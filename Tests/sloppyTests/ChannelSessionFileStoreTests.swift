import Foundation
import Protocols
import Testing
@testable import sloppy

@Test
func channelSessionStoreCreatesClosesAndReopensSessions() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-store-\(UUID().uuidString)", isDirectory: true)
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let firstSummary = try await store.recordUserMessage(
        channelId: "support",
        userId: "user-1",
        content: "First message",
        createdAt: startedAt
    )
    #expect(firstSummary.status == .open)
    #expect(firstSummary.messageCount == 1)

    let updatedSummary = try await store.recordAssistantMessage(
        channelId: "support",
        content: "Assistant reply",
        createdAt: startedAt.addingTimeInterval(10)
    )
    #expect(updatedSummary.sessionId == firstSummary.sessionId)
    #expect(updatedSummary.messageCount == 2)
    #expect(updatedSummary.updatedAt == startedAt.addingTimeInterval(10))
    #expect(updatedSummary.lastMessagePreview == "Assistant reply")

    _ = try await store.expireInactiveSessions(
        timeoutByChannel: ["support": 1],
        referenceDate: startedAt.addingTimeInterval(90)
    )

    let closedSessions = try await store.listSessions(status: .closed)
    #expect(closedSessions.count == 1)
    #expect(closedSessions.first?.sessionId == firstSummary.sessionId)
    #expect(closedSessions.first?.closedAt == startedAt.addingTimeInterval(90))

    let activeSessionsAfterClose = try await store.listSessions(status: .open)
    #expect(activeSessionsAfterClose.isEmpty)

    let historyAfterClose = try await store.getMessageHistory(channelId: "support", limit: 10)
    #expect(historyAfterClose.isEmpty)

    let reopenedSummary = try await store.recordUserMessage(
        channelId: "support",
        userId: "user-1",
        content: "Second session message",
        createdAt: startedAt.addingTimeInterval(120)
    )
    #expect(reopenedSummary.status == .open)
    #expect(reopenedSummary.sessionId != firstSummary.sessionId)
    #expect(reopenedSummary.messageCount == 1)

    let activeSessions = try await store.listSessions(status: .open)
    #expect(activeSessions.count == 1)
    #expect(activeSessions.first?.sessionId == reopenedSummary.sessionId)

    let allSessions = try await store.listSessions()
    #expect(allSessions.count == 2)
}

@Test
func channelSessionStoreExpiresViaGlobalDefaultTimeout() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-global-\(UUID().uuidString)", isDirectory: true)
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let startedAt = Date(timeIntervalSince1970: 1_700_001_000)
    _ = try await store.recordUserMessage(
        channelId: "alpha",
        userId: "user-1",
        content: "Hello from alpha",
        createdAt: startedAt
    )
    _ = try await store.recordUserMessage(
        channelId: "beta",
        userId: "user-2",
        content: "Hello from beta",
        createdAt: startedAt
    )

    let twoDaysInMinutes = 2 * 24 * 60
    let justBefore = startedAt.addingTimeInterval(TimeInterval(twoDaysInMinutes * 60 - 1))
    _ = try await store.expireInactiveSessions(
        timeoutByChannel: [:],
        globalDefaultTimeoutMinutes: twoDaysInMinutes,
        referenceDate: justBefore
    )
    let stillOpen = try await store.listSessions(status: .open)
    #expect(stillOpen.count == 2)

    let afterExpiry = startedAt.addingTimeInterval(TimeInterval(twoDaysInMinutes * 60 + 1))
    let closed = try await store.expireInactiveSessions(
        timeoutByChannel: [:],
        globalDefaultTimeoutMinutes: twoDaysInMinutes,
        referenceDate: afterExpiry
    )
    #expect(closed.count == 2)

    let openAfter = try await store.listSessions(status: .open)
    #expect(openAfter.isEmpty)
}

@Test
func channelSessionStorePerAgentOverridesGlobalDefault() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-override-\(UUID().uuidString)", isDirectory: true)
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let startedAt = Date(timeIntervalSince1970: 1_700_002_000)
    _ = try await store.recordUserMessage(
        channelId: "fast-channel",
        userId: "user-1",
        content: "Quick close",
        createdAt: startedAt
    )
    _ = try await store.recordUserMessage(
        channelId: "slow-channel",
        userId: "user-2",
        content: "Uses global default",
        createdAt: startedAt
    )

    let fiveMinutesLater = startedAt.addingTimeInterval(5 * 60 + 1)
    let closed = try await store.expireInactiveSessions(
        timeoutByChannel: ["fast-channel": 5],
        globalDefaultTimeoutMinutes: 2 * 24 * 60,
        referenceDate: fiveMinutesLater
    )
    #expect(closed.count == 1)
    #expect(closed.first?.channelId == "fast-channel")

    let remaining = try await store.listSessions(status: .open)
    #expect(remaining.count == 1)
    #expect(remaining.first?.channelId == "slow-channel")
}

@Test
func channelSessionStoreNoExpirationWhenGlobalDefaultIsZero() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-no-expire-\(UUID().uuidString)", isDirectory: true)
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let startedAt = Date(timeIntervalSince1970: 1_700_003_000)
    _ = try await store.recordUserMessage(
        channelId: "persistent",
        userId: "user-1",
        content: "Should never auto-close",
        createdAt: startedAt
    )

    let farFuture = startedAt.addingTimeInterval(365 * 24 * 3600)
    let closed = try await store.expireInactiveSessions(
        timeoutByChannel: [:],
        globalDefaultTimeoutMinutes: 0,
        referenceDate: farFuture
    )
    #expect(closed.isEmpty)

    let open = try await store.listSessions(status: .open)
    #expect(open.count == 1)
}

@Test
func channelSessionStorePersistsTechnicalEventsWithoutAffectingMessageCounters() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-technical-\(UUID().uuidString)", isDirectory: true)
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let startedAt = Date(timeIntervalSince1970: 1_700_000_500)
    let initialSummary = try await store.recordUserMessage(
        channelId: "engineering",
        userId: "user-42",
        content: "Check deployment status",
        createdAt: startedAt
    )

    let afterThinking = try await store.recordThinking(
        channelId: "engineering",
        content: "Evaluating route and deciding whether tools are needed.",
        createdAt: startedAt.addingTimeInterval(2)
    )
    #expect(afterThinking.sessionId == initialSummary.sessionId)
    #expect(afterThinking.messageCount == 1)
    #expect(afterThinking.lastMessagePreview == "Check deployment status")

    let afterToolCall = try await store.recordToolCall(
        channelId: "engineering",
        tool: "web.search",
        arguments: .object(["query": .string("deployment health")]),
        reason: "Need latest service status",
        createdAt: startedAt.addingTimeInterval(4)
    )
    #expect(afterToolCall.messageCount == 1)
    #expect(afterToolCall.lastMessagePreview == "Check deployment status")

    let afterToolResult = try await store.recordToolResult(
        channelId: "engineering",
        tool: "web.search",
        ok: true,
        data: .object(["resultCount": .number(3)]),
        error: nil,
        durationMs: 120,
        createdAt: startedAt.addingTimeInterval(6)
    )
    #expect(afterToolResult.messageCount == 1)
    #expect(afterToolResult.lastMessagePreview == "Check deployment status")

    let finalSummary = try await store.recordAssistantMessage(
        channelId: "engineering",
        content: "Deployment looks healthy.",
        createdAt: startedAt.addingTimeInterval(8)
    )
    #expect(finalSummary.messageCount == 2)
    #expect(finalSummary.lastMessagePreview == "Deployment looks healthy.")

    let detail = try await store.loadSessionDetail(sessionID: initialSummary.sessionId)
    let eventTypes = detail.events.map(\.type)
    #expect(eventTypes == [.sessionOpened, .userMessage, .thinking, .toolCall, .toolResult, .assistantMessage])
}

@Test
func channelSessionStoreReturnsMessageHistoryForDateRangeOnly() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-range-\(UUID().uuidString)", isDirectory: true)
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await store.recordUserMessage(
        channelId: "daily",
        userId: "user-1",
        content: "Yesterday context",
        createdAt: dayStart.addingTimeInterval(-60)
    )
    _ = try await store.recordUserMessage(
        channelId: "daily",
        userId: "user-1",
        content: "Today starts here",
        createdAt: dayStart
    )
    _ = try await store.recordThinking(
        channelId: "daily",
        content: "Technical event should be ignored.",
        createdAt: dayStart.addingTimeInterval(30)
    )
    _ = try await store.recordAssistantMessage(
        channelId: "daily",
        content: "Today assistant reply",
        createdAt: dayStart.addingTimeInterval(60)
    )
    _ = try await store.recordUserMessage(
        channelId: "daily",
        userId: "user-1",
        content: "Tomorrow context",
        createdAt: dayStart.addingTimeInterval(86_400)
    )

    let history = try await store.getMessageHistory(
        channelId: "daily",
        from: dayStart,
        to: dayStart.addingTimeInterval(86_400)
    )

    #expect(history.map(\.content) == ["Today starts here", "Today assistant reply"])
    #expect(history.map(\.userId) == ["user-1", "assistant"])
}

@Test
func channelSessionStoreCachesSummariesWithRecentMessages() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspaceRootURL) }
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let startedAt = Date(timeIntervalSince1970: 1_700_010_000)
    let first = try await store.recordUserMessage(
        channelId: "support",
        userId: "user-1",
        content: "First",
        createdAt: startedAt
    )
    _ = try await store.recordAssistantMessage(
        channelId: "support",
        content: "Second",
        createdAt: startedAt.addingTimeInterval(1)
    )
    _ = try await store.recordUserMessage(
        channelId: "support",
        userId: "user-2",
        content: "Third",
        createdAt: startedAt.addingTimeInterval(2)
    )

    let summaryURL = workspaceRootURL
        .appendingPathComponent("channel-sessions", isDirectory: true)
        .appendingPathComponent("\(first.sessionId).summary.json")
    try? FileManager.default.removeItem(at: summaryURL)
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

    let warmed = try await store.listSessions(status: .open, recentMessagesLimit: 2)
    #expect(warmed.count == 1)
    #expect(FileManager.default.fileExists(atPath: summaryURL.path))
    #expect(warmed.first?.messageCount == 3)
    #expect(warmed.first?.lastMessagePreview == "Third")
    #expect(warmed.first?.recentMessages?.map(\.content) == ["Second", "Third"])
    #expect(warmed.first?.recentMessages?.first?.isBot == true)

    _ = try await store.recordAssistantMessage(
        channelId: "support",
        content: "Fourth",
        createdAt: startedAt.addingTimeInterval(3)
    )
    let afterAppend = try await store.listSessions(status: .open, recentMessagesLimit: 1)
    #expect(afterAppend.first?.messageCount == 4)
    #expect(afterAppend.first?.lastMessagePreview == "Fourth")
    #expect(afterAppend.first?.recentMessages?.map(\.content) == ["Fourth"])

    try await store.deleteSession(sessionID: first.sessionId)
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))
}

@Test
func channelSessionStorePaginatesSummaries() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("channel-session-pagination-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspaceRootURL) }
    let store = ChannelSessionFileStore(workspaceRootURL: workspaceRootURL)

    let startedAt = Date(timeIntervalSince1970: 1_700_020_000)
    _ = try await store.recordUserMessage(channelId: "one", userId: "u", content: "One", createdAt: startedAt)
    _ = try await store.recordUserMessage(channelId: "two", userId: "u", content: "Two", createdAt: startedAt.addingTimeInterval(10))
    _ = try await store.recordUserMessage(channelId: "three", userId: "u", content: "Three", createdAt: startedAt.addingTimeInterval(20))

    let page = try await store.listSessions(status: .open, limit: 1, offset: 1)
    #expect(page.count == 1)
    #expect(page.first?.channelId == "two")
}

import Foundation
import AgentRuntime
import PluginSDK
import Protocols

/// File-based persistence store for channel sessions.
/// Stores sessions at: workspace/channel-sessions/{sessionId}.jsonl
actor ChannelSessionFileStore {
    enum StoreError: Error {
        case invalidChannelID
        case invalidSessionID
        case sessionNotFound
        case storageFailure
    }

    private let fileManager: FileManager
    private let sessionsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let summaryCacheSchemaVersion = 1
    private static let cachedRecentMessageLimit = 50

    init(workspaceRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.sessionsRootURL = workspaceRootURL
            .appendingPathComponent("channel-sessions", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try? fileManager.createDirectory(
            at: sessionsRootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func listSessions(
        status: ChannelSessionStatus? = nil,
        channelIds: Set<String>? = nil,
        recentMessagesLimit: Int? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [ChannelSessionSummary] {
        let files = try sessionFiles()
        var summaries: [ChannelSessionSummary] = []
        summaries.reserveCapacity(files.count)

        for fileURL in files {
            guard let summary = try? loadSessionSummary(
                fileURL: fileURL,
                recentMessagesLimit: recentMessagesLimit
            ) else {
                continue
            }
            if let status, summary.status != status {
                continue
            }
            if let channelIds {
                let matchesBinding = channelIds.contains { binding in
                    ChannelGatewayScope.sessionMatchesBinding(
                        sessionChannelId: summary.channelId,
                        bindingChannelId: binding
                    )
                }
                if !matchesBinding {
                    continue
                }
            }
            summaries.append(summary)
        }

        let sorted = summaries.sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.createdAt > right.createdAt
            }
            return left.updatedAt > right.updatedAt
        }
        return Self.paginated(sorted, limit: limit, offset: offset)
    }

    func deleteSession(sessionID: String) throws {
        let normalizedSessionID = try normalizedSessionID(sessionID)
        let fileURL = try existingSessionFileURL(sessionID: normalizedSessionID)
        do {
            try fileManager.removeItem(at: fileURL)
            removeSummaryCache(sessionID: normalizedSessionID)
        } catch {
            throw StoreError.storageFailure
        }
    }

    func loadSession(sessionID: String) throws -> [ChannelSessionEvent] {
        let normalizedSessionID = try normalizedSessionID(sessionID)
        let fileURL = sessionFileURL(sessionId: normalizedSessionID)
        if fileManager.fileExists(atPath: fileURL.path) {
            return try readEvents(fileURL: fileURL)
        }
        throw StoreError.sessionNotFound
    }

    func loadSessionDetail(sessionID: String) throws -> ChannelSessionDetail {
        let normalizedSessionID = try normalizedSessionID(sessionID)
        let fileURL = try existingSessionFileURL(sessionID: normalizedSessionID)
        let summary = try loadSessionSummary(fileURL: fileURL)
        let events = try readEvents(fileURL: fileURL)
        return ChannelSessionDetail(summary: summary, events: events)
    }

    @discardableResult
    func ensureOpenSession(channelId: String, createdAt: Date = Date()) throws -> ChannelSessionSummary {
        let normalizedChannelID = try normalizedChannelID(channelId)
        if let open = try currentOpenSession(channelId: normalizedChannelID) {
            return open
        }
        return try createSession(channelId: normalizedChannelID, createdAt: createdAt)
    }

    func closeSession(
        sessionID: String,
        reason: String = "inactive_timeout",
        closedAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        let normalizedSessionID = try normalizedSessionID(sessionID)
        let fileURL = try existingSessionFileURL(sessionID: normalizedSessionID)
        let summary = try loadSessionSummary(fileURL: fileURL)
        if summary.status == .closed {
            return summary
        }

        let event = ChannelSessionEvent(
            channelId: summary.channelId,
            type: .sessionClosed,
            userId: "system",
            content: "Session closed automatically after inactivity.",
            createdAt: closedAt,
            metadata: ["reason": reason]
        )
        try append(events: [event], to: fileURL, createIfMissing: false)
        return try loadSessionSummary(fileURL: fileURL)
    }

    @discardableResult
    func expireInactiveSessions(
        timeoutByChannel: [String: Int],
        globalDefaultTimeoutMinutes: Int? = nil,
        referenceDate: Date = Date()
    ) throws -> [ChannelSessionSummary] {
        let hasGlobalDefault = (globalDefaultTimeoutMinutes ?? 0) > 0
        guard !timeoutByChannel.isEmpty || hasGlobalDefault else {
            return []
        }

        let openSessions = try listSessions(status: .open)
        var closed: [ChannelSessionSummary] = []

        for summary in openSessions {
            let bindingId = ChannelGatewayScope.parse(summary.channelId).baseChannelId
            let timeoutMinutes = timeoutByChannel[summary.channelId]
                ?? timeoutByChannel[bindingId]
                ?? globalDefaultTimeoutMinutes ?? 0
            guard timeoutMinutes > 0 else {
                continue
            }
            let timeoutSeconds = TimeInterval(timeoutMinutes * 60)
            guard referenceDate.timeIntervalSince(summary.updatedAt) >= timeoutSeconds else {
                continue
            }
            closed.append(
                try closeSession(
                    sessionID: summary.sessionId,
                    reason: "inactive_timeout",
                    closedAt: referenceDate
                )
            )
        }

        return closed
    }

    @discardableResult
    func recordUserMessage(
        channelId: String,
        userId: String,
        content: String,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        try appendMessage(
            channelId: channelId,
            userId: userId,
            content: content,
            type: .userMessage,
            createdAt: createdAt
        )
    }

    @discardableResult
    func recordAssistantMessage(
        channelId: String,
        content: String,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        try appendMessage(
            channelId: channelId,
            userId: "assistant",
            content: content,
            type: .assistantMessage,
            createdAt: createdAt
        )
    }

    @discardableResult
    func recordSystemMessage(
        channelId: String,
        content: String,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        try appendMessage(
            channelId: channelId,
            userId: "system",
            content: content,
            type: .systemMessage,
            createdAt: createdAt
        )
    }

    @discardableResult
    func recordThinking(
        channelId: String,
        content: String,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        try appendEvent(
            channelId: channelId,
            userId: "assistant",
            content: content,
            type: .thinking,
            createdAt: createdAt
        )
    }

    @discardableResult
    func recordToolCall(
        channelId: String,
        tool: String,
        arguments: JSONValue,
        reason: String? = nil,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        let argumentsText = prettyJSONString(arguments)
        let content = [
            reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "Reason: \(reason!)" : nil,
            "Arguments:",
            argumentsText
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")

        return try appendEvent(
            channelId: channelId,
            userId: "assistant",
            content: content,
            type: .toolCall,
            metadata: [
                "tool": tool.trimmingCharacters(in: .whitespacesAndNewlines),
                "reason": reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ],
            createdAt: createdAt
        )
    }

    @discardableResult
    func recordToolResult(
        channelId: String,
        tool: String,
        ok: Bool,
        data: JSONValue? = nil,
        error: ToolErrorPayload? = nil,
        durationMs: Int? = nil,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        var parts = ["Status: \(ok ? "success" : "failed")"]
        if let durationMs {
            parts.append("Duration: \(durationMs) ms")
        }
        if let data {
            parts.append("Data:\n\(prettyJSONString(data))")
        }
        if let error {
            parts.append("Error:\n\(prettyJSONString(error))")
        }

        return try appendEvent(
            channelId: channelId,
            userId: "assistant",
            content: parts.joined(separator: "\n\n"),
            type: .toolResult,
            metadata: [
                "tool": tool.trimmingCharacters(in: .whitespacesAndNewlines),
                "ok": ok ? "true" : "false",
                "durationMs": durationMs.map(String.init) ?? ""
            ],
            createdAt: createdAt
        )
    }

    @discardableResult
    func recordInputRequest(
        channelId: String,
        request: PlanInputRequest,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try appendEvent(
            channelId: channelId,
            userId: "assistant",
            content: title?.isEmpty == false ? title! : "Input requested.",
            type: .inputRequest,
            metadata: ["requestId": request.id],
            createdAt: createdAt,
            inputRequest: request
        )
    }

    @discardableResult
    func recordInputResponse(
        channelId: String,
        response: PlanInputResponse,
        summary: String,
        createdAt: Date = Date()
    ) throws -> ChannelSessionSummary {
        return try appendEvent(
            channelId: channelId,
            userId: response.userId,
            content: summary,
            type: .inputResponse,
            metadata: [
                "requestId": response.requestId,
                "status": response.status.rawValue
            ],
            createdAt: createdAt,
            inputResponse: response
        )
    }

    func getMessageHistory(channelId: String, limit: Int = 50) throws -> [ChannelMessageEntry] {
        guard let openSession = try currentOpenSession(channelId: channelId) else {
            return []
        }

        let events = try loadSession(sessionID: openSession.sessionId)
        let messageEvents = events.filter {
            $0.type == .userMessage || $0.type == .assistantMessage
        }
        let recent = messageEvents.suffix(max(1, limit))

        return recent.map { event in
            ChannelMessageEntry(
                id: event.id,
                userId: event.userId,
                content: event.content,
                createdAt: event.createdAt
            )
        }
    }

    func getMessageHistory(
        channelId: String,
        from startDate: Date,
        to endDate: Date
    ) throws -> [ChannelMessageEntry] {
        guard startDate < endDate else {
            return []
        }
        guard let openSession = try currentOpenSession(channelId: channelId) else {
            return []
        }

        let events = try loadSession(sessionID: openSession.sessionId)
        return events
            .filter { event in
                (event.type == .userMessage || event.type == .assistantMessage) &&
                    event.createdAt >= startDate &&
                    event.createdAt < endDate
            }
            .sorted { $0.createdAt < $1.createdAt }
            .map { event in
                ChannelMessageEntry(
                    id: event.id,
                    userId: event.userId,
                    content: event.content,
                    createdAt: event.createdAt
                )
            }
    }

    func hasPendingInputRequest(channelId: String) throws -> Bool {
        try pendingInputRequest(channelId: channelId) != nil
    }

    func pendingInputRequest(channelId: String) throws -> (sessionId: String, request: PlanInputRequest)? {
        guard let openSession = try currentOpenSession(channelId: channelId) else {
            return nil
        }
        let events = try loadSession(sessionID: openSession.sessionId)
        let answered = Set(events.compactMap { $0.inputResponse?.requestId })
        for event in events.reversed() where event.type == .inputRequest {
            guard let requestID = event.inputRequest?.id else { continue }
            if !answered.contains(requestID) {
                return event.inputRequest.map { (openSession.sessionId, $0) }
            }
        }
        return nil
    }

    private func appendMessage(
        channelId: String,
        userId: String,
        content: String,
        type: ChannelSessionEventType,
        createdAt: Date
    ) throws -> ChannelSessionSummary {
        try appendEvent(
            channelId: channelId,
            userId: userId,
            content: content,
            type: type,
            createdAt: createdAt
        )
    }

    private func appendEvent(
        channelId: String,
        userId: String,
        content: String,
        type: ChannelSessionEventType,
        metadata: [String: String]? = nil,
        createdAt: Date,
        inputRequest: PlanInputRequest? = nil,
        inputResponse: PlanInputResponse? = nil
    ) throws -> ChannelSessionSummary {
        let normalizedChannelID = try normalizedChannelID(channelId)
        let summary = try currentOpenSession(channelId: normalizedChannelID)
            ?? createSession(channelId: normalizedChannelID, createdAt: createdAt)
        let fileURL = sessionFileURL(sessionId: summary.sessionId)
        let event = ChannelSessionEvent(
            channelId: normalizedChannelID,
            type: type,
            userId: userId,
            content: content,
            createdAt: createdAt,
            metadata: metadata,
            inputRequest: inputRequest,
            inputResponse: inputResponse
        )
        try append(events: [event], to: fileURL, createIfMissing: false)
        return try loadSessionSummary(fileURL: fileURL)
    }

    private func createSession(channelId: String, createdAt: Date) throws -> ChannelSessionSummary {
        let sessionId = "session-\(UUID().uuidString.lowercased())"
        let fileURL = sessionFileURL(sessionId: sessionId)
        let openedEvent = ChannelSessionEvent(
            channelId: channelId,
            type: .sessionOpened,
            userId: "system",
            content: "Session opened.",
            createdAt: createdAt
        )
        try append(events: [openedEvent], to: fileURL, createIfMissing: true)
        return try loadSessionSummary(fileURL: fileURL)
    }

    private func currentOpenSession(channelId: String) throws -> ChannelSessionSummary? {
        try listSessions(status: .open, channelIds: Set([channelId])).first
    }

    private func sessionFiles() throws -> [URL] {
        guard fileManager.fileExists(atPath: sessionsRootURL.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" }
    }

    private func existingSessionFileURL(sessionID: String) throws -> URL {
        let directURL = sessionFileURL(sessionId: sessionID)
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }
        throw StoreError.sessionNotFound
    }

    private func sessionFileURL(sessionId: String) -> URL {
        sessionsRootURL.appendingPathComponent("\(sessionId).jsonl")
    }

    private func loadSessionSummary(fileURL: URL, recentMessagesLimit: Int? = nil) throws -> ChannelSessionSummary {
        if let cached = try? readSummaryCache(fileURL: fileURL, recentMessagesLimit: recentMessagesLimit) {
            return cached
        }
        return try refreshSummaryCache(fileURL: fileURL, recentMessagesLimit: recentMessagesLimit)
    }

    @discardableResult
    private func refreshSummaryCache(fileURL: URL, recentMessagesLimit: Int? = nil) throws -> ChannelSessionSummary {
        let events = try readEvents(fileURL: fileURL)
        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        let summary = summaryForSession(
            sessionID: sessionID,
            events: events,
            fallbackChannelId: legacyChannelID(fromSessionID: sessionID)
        )
        let cachedRecentMessages = recentMessages(from: events, limit: Self.cachedRecentMessageLimit)
        try writeSummaryCache(summary, recentMessages: cachedRecentMessages, fileURL: fileURL)
        return summaryWithRecentMessages(
            summary,
            cachedRecentMessages: cachedRecentMessages,
            limit: recentMessagesLimit
        )
    }

    private struct ChannelSessionSummaryCache: Codable {
        var schemaVersion: Int
        var sourceByteCount: Int
        var sourceModifiedAt: TimeInterval
        var summary: ChannelSessionSummary
        var recentMessages: [ChannelSessionMessagePreview]
    }

    private func readSummaryCache(fileURL: URL, recentMessagesLimit: Int?) throws -> ChannelSessionSummary? {
        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        let cacheURL = sessionSummaryCacheURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: cacheURL)
        let cache = try decoder.decode(ChannelSessionSummaryCache.self, from: data)
        guard cache.schemaVersion == Self.summaryCacheSchemaVersion,
              let fingerprint = try sourceFingerprint(fileURL: fileURL),
              cache.sourceByteCount == fingerprint.byteCount,
              cache.sourceModifiedAt == fingerprint.modifiedAt else {
            return nil
        }
        return summaryWithRecentMessages(
            cache.summary,
            cachedRecentMessages: cache.recentMessages,
            limit: recentMessagesLimit
        )
    }

    private func writeSummaryCache(
        _ summary: ChannelSessionSummary,
        recentMessages: [ChannelSessionMessagePreview],
        fileURL: URL
    ) throws {
        guard let fingerprint = try sourceFingerprint(fileURL: fileURL) else {
            return
        }
        var summaryForCache = summary
        summaryForCache.recentMessages = nil
        let cache = ChannelSessionSummaryCache(
            schemaVersion: Self.summaryCacheSchemaVersion,
            sourceByteCount: fingerprint.byteCount,
            sourceModifiedAt: fingerprint.modifiedAt,
            summary: summaryForCache,
            recentMessages: recentMessages
        )
        let payload = try encoder.encode(cache)
        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        try payload.write(to: sessionSummaryCacheURL(sessionID: sessionID), options: .atomic)
    }

    private func removeSummaryCache(sessionID: String) {
        let cacheURL = sessionSummaryCacheURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }
        try? fileManager.removeItem(at: cacheURL)
    }

    private func sessionSummaryCacheURL(sessionID: String) -> URL {
        sessionsRootURL.appendingPathComponent("\(sessionID).summary.json")
    }

    private func sourceFingerprint(fileURL: URL) throws -> (byteCount: Int, modifiedAt: TimeInterval)? {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let byteCount = values.fileSize,
              let modifiedAt = values.contentModificationDate else {
            return nil
        }
        return (byteCount, modifiedAt.timeIntervalSince1970)
    }

    private func summaryWithRecentMessages(
        _ summary: ChannelSessionSummary,
        cachedRecentMessages: [ChannelSessionMessagePreview],
        limit: Int?
    ) -> ChannelSessionSummary {
        guard let limit, limit > 0 else {
            var copy = summary
            copy.recentMessages = nil
            return copy
        }
        var copy = summary
        copy.recentMessages = Array(cachedRecentMessages.suffix(min(limit, cachedRecentMessages.count)))
        return copy
    }

    private func recentMessages(from events: [ChannelSessionEvent], limit: Int) -> [ChannelSessionMessagePreview] {
        let messages = events
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { event -> ChannelSessionMessagePreview? in
                switch event.type {
                case .userMessage:
                    return ChannelSessionMessagePreview(
                        id: event.id,
                        userId: event.userId,
                        content: event.content,
                        createdAt: event.createdAt,
                        isBot: false
                    )
                case .assistantMessage:
                    return ChannelSessionMessagePreview(
                        id: event.id,
                        userId: "bot",
                        content: event.content,
                        createdAt: event.createdAt,
                        isBot: true
                    )
                default:
                    return nil
                }
            }
        return Array(messages.suffix(max(0, limit)))
    }

    private static func paginated(_ summaries: [ChannelSessionSummary], limit: Int?, offset: Int) -> [ChannelSessionSummary] {
        let start = min(max(0, offset), summaries.count)
        let tail = summaries[start...]
        guard let limit else {
            return Array(tail)
        }
        return Array(tail.prefix(max(0, limit)))
    }

    private func summaryForSession(
        sessionID: String,
        events: [ChannelSessionEvent],
        fallbackChannelId: String?
    ) -> ChannelSessionSummary {
        let sortedEvents = events.sorted { $0.createdAt < $1.createdAt }
        let firstEvent = sortedEvents.first
        let lastEvent = sortedEvents.last

        var channelId = fallbackChannelId ?? firstEvent?.channelId ?? ""
        var messageCount = 0
        var lastPreview: String?
        var closedAt: Date?

        for event in sortedEvents {
            if channelId.isEmpty {
                channelId = event.channelId
            }
            switch event.type {
            case .userMessage, .assistantMessage:
                messageCount += 1
                if let preview = previewText(for: event.content), !preview.isEmpty {
                    lastPreview = preview
                }
            case .sessionClosed:
                closedAt = event.createdAt
            default:
                continue
            }
        }

        let createdAt = firstEvent?.createdAt ?? Date()
        let updatedAt = lastEvent?.createdAt ?? createdAt

        return ChannelSessionSummary(
            channelId: channelId,
            sessionId: sessionID,
            messageCount: messageCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            closedAt: closedAt,
            status: closedAt == nil ? .open : .closed,
            lastMessagePreview: lastPreview
        )
    }

    private func readEvents(fileURL: URL) throws -> [ChannelSessionEvent] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionNotFound
        }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw StoreError.storageFailure
        }

        let lines = content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var events: [ChannelSessionEvent] = []
        events.reserveCapacity(lines.count)

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(ChannelSessionEvent.self, from: lineData)
            else {
                continue
            }
            events.append(event)
        }

        guard !events.isEmpty else {
            throw StoreError.sessionNotFound
        }

        return events
    }

    private func append(events: [ChannelSessionEvent], to fileURL: URL, createIfMissing: Bool) throws {
        if createIfMissing && !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.storageFailure
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }

        try handle.seekToEnd()
        for event in events {
            var payload = try encoder.encode(event)
            payload.append(0x0A)
            try handle.write(contentsOf: payload)
        }
    }

    private func previewText(for content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed.count > 120 ? String(trimmed.prefix(120)) : trimmed
    }

    private func prettyJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return text
    }

    private func normalizedChannelID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidChannelID
        }
        return trimmed
    }

    private func normalizedSessionID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidSessionID
        }
        return trimmed
    }

    private func legacyChannelID(fromSessionID sessionID: String) -> String? {
        guard sessionID.hasPrefix("session-") else {
            return nil
        }
        let channelId = String(sessionID.dropFirst("session-".count))
        if UUID(uuidString: channelId) != nil {
            return nil
        }
        return channelId.isEmpty ? nil : channelId
    }
}

public struct ChannelSessionEvent: Codable, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var type: ChannelSessionEventType
    public var userId: String
    public var content: String
    public var createdAt: Date
    public var metadata: [String: String]?
    public var inputRequest: PlanInputRequest?
    public var inputResponse: PlanInputResponse?

    public init(
        id: String = UUID().uuidString,
        channelId: String,
        type: ChannelSessionEventType,
        userId: String,
        content: String,
        createdAt: Date = Date(),
        metadata: [String: String]? = nil,
        inputRequest: PlanInputRequest? = nil,
        inputResponse: PlanInputResponse? = nil
    ) {
        self.id = id
        self.channelId = channelId
        self.type = type
        self.userId = userId
        self.content = content
        self.createdAt = createdAt
        self.metadata = metadata
        self.inputRequest = inputRequest
        self.inputResponse = inputResponse
    }
}

public enum ChannelSessionEventType: String, Codable, Sendable {
    case sessionOpened = "session_opened"
    case sessionClosed = "session_closed"
    case userMessage = "user_message"
    case assistantMessage = "assistant_message"
    case systemMessage = "system_message"
    case thinking = "thinking"
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case inputRequest = "input_request"
    case inputResponse = "input_response"
}

public enum ChannelSessionStatus: String, Codable, Sendable, Equatable {
    case open = "open"
    case closed = "closed"
}

public struct ChannelSessionMessagePreview: Codable, Sendable, Equatable {
    public var id: String
    public var userId: String
    public var content: String
    public var createdAt: Date
    public var isBot: Bool

    public init(
        id: String,
        userId: String,
        content: String,
        createdAt: Date,
        isBot: Bool
    ) {
        self.id = id
        self.userId = userId
        self.content = content
        self.createdAt = createdAt
        self.isBot = isBot
    }
}

public struct ChannelSessionSummary: Codable, Sendable, Equatable {
    public var channelId: String
    public var sessionId: String
    public var messageCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    public var status: ChannelSessionStatus
    public var lastMessagePreview: String?
    public var recentMessages: [ChannelSessionMessagePreview]?

    public init(
        channelId: String,
        sessionId: String,
        messageCount: Int,
        createdAt: Date,
        updatedAt: Date,
        closedAt: Date? = nil,
        status: ChannelSessionStatus = .open,
        lastMessagePreview: String? = nil,
        recentMessages: [ChannelSessionMessagePreview]? = nil
    ) {
        self.channelId = channelId
        self.sessionId = sessionId
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.status = status
        self.lastMessagePreview = lastMessagePreview
        self.recentMessages = recentMessages
    }
}

public struct ChannelSessionDetail: Codable, Sendable, Equatable {
    public var summary: ChannelSessionSummary
    public var events: [ChannelSessionEvent]

    public init(summary: ChannelSessionSummary, events: [ChannelSessionEvent]) {
        self.summary = summary
        self.events = events
    }
}

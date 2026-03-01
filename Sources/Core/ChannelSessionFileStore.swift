import Foundation
import AgentRuntime
import Protocols

/// File-based persistence store for channel sessions.
/// Stores sessions at: workspace/channel-sessions/session-{channelId}.jsonl
/// Session ID format: session-{CHANNEL_ID}
actor ChannelSessionFileStore {
    enum StoreError: Error {
        case invalidChannelID
        case sessionNotFound
        case storageFailure
    }

    private let fileManager: FileManager
    private let sessionsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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

        // Ensure sessions directory exists
        try? fileManager.createDirectory(
            at: sessionsRootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Returns the session ID for a channel (format: session-{channelId})
    func sessionID(for channelId: String) -> String {
        return "session-\(channelId)"
    }

    /// Returns the file URL for a channel session
    private func sessionFileURL(channelId: String) -> URL {
        let sessionId = sessionID(for: channelId)
        return sessionsRootURL.appendingPathComponent("\(sessionId).jsonl")
    }

    /// Checks if a session exists for the channel
    func sessionExists(channelId: String) -> Bool {
        let fileURL = sessionFileURL(channelId: channelId)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Loads session events for a channel, returns empty array if session doesn't exist
    func loadSession(channelId: String) throws -> [ChannelSessionEvent] {
        let fileURL = sessionFileURL(channelId: channelId)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        guard let data = fileManager.contents(atPath: fileURL.path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var events: [ChannelSessionEvent] = []

        for line in lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let event = try? decoder.decode(ChannelSessionEvent.self, from: lineData) {
                events.append(event)
            }
        }

        return events
    }

    /// Appends events to a channel session (creates session if it doesn't exist)
    func appendEvents(channelId: String, events: [ChannelSessionEvent]) throws {
        guard !events.isEmpty else { return }

        let fileURL = sessionFileURL(channelId: channelId)
        let createIfMissing = !fileManager.fileExists(atPath: fileURL.path)

        try append(events: events, to: fileURL, createIfMissing: createIfMissing)
    }

    /// Records a user message in the channel session
    func recordUserMessage(channelId: String, userId: String, content: String) throws {
        let event = ChannelSessionEvent(
            channelId: channelId,
            type: .userMessage,
            userId: userId,
            content: content
        )
        try appendEvents(channelId: channelId, events: [event])
    }

    /// Records an assistant (bot) message in the channel session
    func recordAssistantMessage(channelId: String, content: String) throws {
        let event = ChannelSessionEvent(
            channelId: channelId,
            type: .assistantMessage,
            userId: "assistant",
            content: content
        )
        try appendEvents(channelId: channelId, events: [event])
    }

    /// Records a system message in the channel session
    func recordSystemMessage(channelId: String, content: String) throws {
        let event = ChannelSessionEvent(
            channelId: channelId,
            type: .systemMessage,
            userId: "system",
            content: content
        )
        try appendEvents(channelId: channelId, events: [event])
    }

    /// Returns recent message history formatted for LLM context
    func getMessageHistory(channelId: String, limit: Int = 50) throws -> [ChannelMessageEntry] {
        let events = try loadSession(channelId: channelId)
        let messageEvents = events.filter {
            $0.type == .userMessage || $0.type == .assistantMessage
        }
        let recent = messageEvents.suffix(limit)

        return recent.map { event in
            ChannelMessageEntry(
                id: event.id,
                userId: event.userId,
                content: event.content,
                createdAt: event.createdAt
            )
        }
    }

    /// Deletes a channel session
    func deleteSession(channelId: String) throws {
        let fileURL = sessionFileURL(channelId: channelId)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionNotFound
        }
        try fileManager.removeItem(at: fileURL)
    }

    // MARK: - Private Helpers

    private func append(events: [ChannelSessionEvent], to fileURL: URL, createIfMissing: Bool) throws {
        var lines: [String] = []
        for event in events {
            guard let data = try? encoder.encode(event),
                  let line = String(data: data, encoding: .utf8) else {
                continue
            }
            lines.append(line)
        }

        guard !lines.isEmpty else { return }

        let content = lines.joined(separator: "\n") + "\n"
        guard let data = content.data(using: .utf8) else {
            throw StoreError.storageFailure
        }

        if createIfMissing {
            fileManager.createFile(atPath: fileURL.path, contents: data, attributes: nil)
        } else if let handle = FileHandle(forWritingAtPath: fileURL.path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            throw StoreError.storageFailure
        }
    }
}

// MARK: - Channel Session Event Types

public struct ChannelSessionEvent: Codable, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var type: ChannelSessionEventType
    public var userId: String
    public var content: String
    public var createdAt: Date
    public var metadata: [String: String]?

    public init(
        id: String = UUID().uuidString,
        channelId: String,
        type: ChannelSessionEventType,
        userId: String,
        content: String,
        createdAt: Date = Date(),
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.channelId = channelId
        self.type = type
        self.userId = userId
        self.content = content
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public enum ChannelSessionEventType: String, Codable, Sendable {
    case userMessage = "user_message"
    case assistantMessage = "assistant_message"
    case systemMessage = "system_message"
    case toolCall = "tool_call"
    case toolResult = "tool_result"
}

/// Summary of a channel session
public struct ChannelSessionSummary: Codable, Sendable, Equatable {
    public var channelId: String
    public var sessionId: String
    public var messageCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var lastMessagePreview: String?

    public init(
        channelId: String,
        sessionId: String,
        messageCount: Int,
        createdAt: Date,
        updatedAt: Date,
        lastMessagePreview: String? = nil
    ) {
        self.channelId = channelId
        self.sessionId = sessionId
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessagePreview = lastMessagePreview
    }
}

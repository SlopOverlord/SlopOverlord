import Foundation
import Protocols

final class AgentSessionFileStore {
    enum StoreError: Error {
        case invalidAgentID
        case invalidSessionID
        case agentNotFound
        case sessionNotFound
        case invalidPayload
    }

    private let fileManager: FileManager
    private var agentsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func updateAgentsRootURL(_ url: URL) {
        self.agentsRootURL = url
    }

    func listSessions(agentID: String) throws -> [AgentSessionSummary] {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let sessionsDirectory = try sessionsDirectoryURL(agentID: normalizedAgentID, createIfMissing: false)

        guard fileManager.fileExists(atPath: sessionsDirectory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let sessionFiles = files.filter { $0.pathExtension == "jsonl" }
        var summaries: [AgentSessionSummary] = []
        for file in sessionFiles {
            let sessionID = file.deletingPathExtension().lastPathComponent
            if let detail = try? loadSession(agentID: normalizedAgentID, sessionID: sessionID) {
                summaries.append(detail.summary)
            }
        }

        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func createSession(agentID: String, request: AgentSessionCreateRequest) throws -> AgentSessionSummary {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedParentSessionID = try normalizedOptionalSessionID(request.parentSessionId)
        let sessionsDirectory = try sessionsDirectoryURL(agentID: normalizedAgentID, createIfMissing: true)

        let sessionID = "session-\(UUID().uuidString.lowercased())"
        let trimmedTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let trimmedTitle, !trimmedTitle.isEmpty {
            title = trimmedTitle
        } else {
            title = "Session \(sessionID.prefix(8))"
        }

        let createdEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: sessionID,
            type: .sessionCreated,
            metadata: AgentSessionMetadataEvent(title: title, parentSessionId: normalizedParentSessionID)
        )

        let fileURL = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        try append(events: [createdEvent], to: fileURL, createIfMissing: true)
        return try loadSession(agentID: normalizedAgentID, sessionID: sessionID).summary
    }

    func loadSession(agentID: String, sessionID: String) throws -> AgentSessionDetail {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSessionID = try normalizedSessionID(sessionID)
        let events = try readEvents(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        let summary = summaryForSession(agentID: normalizedAgentID, sessionID: normalizedSessionID, events: events)
        return AgentSessionDetail(summary: summary, events: events)
    }

    @discardableResult
    func appendEvents(agentID: String, sessionID: String, events: [AgentSessionEvent]) throws -> AgentSessionSummary {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSessionID = try normalizedSessionID(sessionID)
        guard !events.isEmpty else {
            throw StoreError.invalidPayload
        }

        let fileURL = sessionFileURL(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionNotFound
        }

        try append(events: events, to: fileURL, createIfMissing: false)
        return try loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID).summary
    }

    func deleteSession(agentID: String, sessionID: String) throws {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSessionID = try normalizedSessionID(sessionID)

        let fileURL = sessionFileURL(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionNotFound
        }

        try fileManager.removeItem(at: fileURL)

        let assetsDirectory = assetsDirectoryURL(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        if fileManager.fileExists(atPath: assetsDirectory.path) {
            try fileManager.removeItem(at: assetsDirectory)
        }
    }

    func persistAttachments(agentID: String, sessionID: String, uploads: [AgentAttachmentUpload]) throws -> [AgentAttachment] {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSessionID = try normalizedSessionID(sessionID)

        if uploads.isEmpty {
            return []
        }

        var attachments: [AgentAttachment] = []
        for upload in uploads {
            let cleanName = sanitizeFilename(upload.name)
            let normalizedName = cleanName.isEmpty ? "attachment.bin" : cleanName
            let mimeType = upload.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
            let attachmentID = UUID().uuidString.lowercased()
            let fileName = "\(attachmentID)-\(normalizedName)"

            var relativePath: String?
            if let contentBase64 = upload.contentBase64, !contentBase64.isEmpty {
                guard let data = Data(base64Encoded: contentBase64, options: [.ignoreUnknownCharacters]) else {
                    throw StoreError.invalidPayload
                }

                let assetsDirectory = assetsDirectoryURL(agentID: normalizedAgentID, sessionID: normalizedSessionID)
                try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

                let fileURL = assetsDirectory.appendingPathComponent(fileName)
                try data.write(to: fileURL, options: .atomic)
                relativePath = "sessions/\(normalizedSessionID).assets/\(fileName)"
            }

            attachments.append(
                AgentAttachment(
                    id: attachmentID,
                    name: normalizedName,
                    mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType,
                    sizeBytes: max(upload.sizeBytes, 0),
                    relativePath: relativePath
                )
            )
        }

        return attachments
    }

    private func append(events: [AgentSessionEvent], to fileURL: URL, createIfMissing: Bool) throws {
        if createIfMissing && !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
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

    private func readEvents(agentID: String, sessionID: String) throws -> [AgentSessionEvent] {
        let fileURL = sessionFileURL(agentID: agentID, sessionID: sessionID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionNotFound
        }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidPayload
        }

        let lines = content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var events: [AgentSessionEvent] = []
        events.reserveCapacity(lines.count)
        for line in lines {
            guard let lineData = line.data(using: .utf8) else {
                continue
            }
            if let event = try? decoder.decode(AgentSessionEvent.self, from: lineData) {
                events.append(event)
            }
        }

        if events.isEmpty {
            throw StoreError.sessionNotFound
        }

        return events.sorted { $0.createdAt < $1.createdAt }
    }

    private func summaryForSession(agentID: String, sessionID: String, events: [AgentSessionEvent]) -> AgentSessionSummary {
        var title = "Session \(sessionID.prefix(8))"
        var parentSessionID: String?
        var createdAt = events.first?.createdAt ?? Date()
        var updatedAt = createdAt
        var messageCount = 0
        var lastPreview: String?

        for event in events {
            createdAt = min(createdAt, event.createdAt)
            updatedAt = max(updatedAt, event.createdAt)

            if event.type == .sessionCreated, let metadata = event.metadata {
                title = metadata.title
                parentSessionID = metadata.parentSessionId
            }

            if let message = event.message {
                messageCount += 1
                if let preview = previewText(for: message), !preview.isEmpty {
                    lastPreview = preview
                }
            }
        }

        return AgentSessionSummary(
            id: sessionID,
            agentId: agentID,
            title: title,
            parentSessionId: parentSessionID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messageCount,
            lastMessagePreview: lastPreview
        )
    }

    private func previewText(for message: AgentSessionMessage) -> String? {
        for segment in message.segments {
            if let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text.count > 120 ? String(text.prefix(120)) : text
            }
            if let attachment = segment.attachment {
                return "Attachment: \(attachment.name)"
            }
        }
        return nil
    }

    private func sessionsDirectoryURL(agentID: String, createIfMissing: Bool) throws -> URL {
        let agentDirectory = agentsRootURL.appendingPathComponent(agentID, isDirectory: true)
        guard fileManager.fileExists(atPath: agentDirectory.path) else {
            throw StoreError.agentNotFound
        }

        let sessionsDirectory = agentDirectory.appendingPathComponent("sessions", isDirectory: true)
        if createIfMissing {
            try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }
        return sessionsDirectory
    }

    private func sessionFileURL(agentID: String, sessionID: String) -> URL {
        agentsRootURL
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    private func assetsDirectoryURL(agentID: String, sessionID: String) -> URL {
        agentsRootURL
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).assets", isDirectory: true)
    }

    private func normalizedAgentID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidAgentID
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw StoreError.invalidAgentID
        }

        return trimmed
    }

    private func normalizedSessionID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidSessionID
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw StoreError.invalidSessionID
        }

        return trimmed
    }

    private func normalizedOptionalSessionID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return try normalizedSessionID(trimmed)
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        let normalized = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))

        return normalized
    }
}

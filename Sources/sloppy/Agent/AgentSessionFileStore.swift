import Foundation
import Logging
import Protocols

final class AgentSessionFileStore {
    enum StoreError: Error, CustomStringConvertible {
        case invalidAgentID
        case invalidSessionID
        case agentNotFound
        case sessionNotFound
        case sessionFileNotFound(agentID: String, sessionID: String, agentsRoot: String)
        case sessionEventsEmpty(agentID: String, sessionID: String, lineCount: Int, filePath: String)
        case invalidPayload

        var description: String {
            switch self {
            case .invalidAgentID: return "invalidAgentID"
            case .invalidSessionID: return "invalidSessionID"
            case .agentNotFound: return "agentNotFound"
            case .sessionNotFound: return "sessionNotFound"
            case .sessionFileNotFound(let a, let s, let root):
                return "sessionFileNotFound(agent=\(a), session=\(s), agentsRoot=\(root))"
            case .sessionEventsEmpty(let a, let s, let lc, let fp):
                return "sessionEventsEmpty(agent=\(a), session=\(s), lines=\(lc), file=\(fp))"
            case .invalidPayload: return "invalidPayload"
            }
        }
    }

    private let fileManager: FileManager
    private var agentsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger

    init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL
        self.logger = Logger(label: "sloppy.session.store")

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

    func listSessions(agentID: String, includeHeartbeat: Bool = false) throws -> [AgentSessionSummary] {
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
                if includeHeartbeat || detail.summary.kind != .heartbeat {
                    summaries.append(detail.summary)
                }
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
            title = "Session \(Self.shortSessionID(sessionID))"
        }

        let projectIdMeta: String? = {
            guard let raw = request.projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }()

        let createdEvent = AgentSessionEvent(
            agentId: normalizedAgentID,
            sessionId: sessionID,
            type: .sessionCreated,
            metadata: AgentSessionMetadataEvent(
                title: title,
                parentSessionId: normalizedParentSessionID,
                kind: request.kind,
                projectId: projectIdMeta
            )
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

        guard let fileURL = sessionFileURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
              fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionNotFound
        }

        try append(events: events, to: fileURL, createIfMissing: false)
        return try loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID).summary
    }

    func deleteSession(agentID: String, sessionID: String) throws {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSessionID = try normalizedSessionID(sessionID)

        guard let fileURL = sessionFileURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
              fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionNotFound
        }

        try fileManager.removeItem(at: fileURL)

        if let sidecar = sessionSidecarURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
           fileManager.fileExists(atPath: sidecar.path) {
            try? fileManager.removeItem(at: sidecar)
        }

        if let assetsDirectory = assetsDirectoryURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
           fileManager.fileExists(atPath: assetsDirectory.path) {
            try fileManager.removeItem(at: assetsDirectory)
        }
    }

    func incrementUserTurnCount(agentID: String, sessionID: String) throws -> Int {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSessionID = try normalizedSessionID(sessionID)
        let prior = try readUserTurnCount(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        let next = prior + 1
        try writeUserTurnCount(agentID: normalizedAgentID, sessionID: normalizedSessionID, count: next)
        return next
    }

    func resetUserTurnCount(agentID: String, sessionID: String) throws {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSessionID = try normalizedSessionID(sessionID)
        try writeUserTurnCount(agentID: normalizedAgentID, sessionID: normalizedSessionID, count: 0)
    }

    private struct AgentSessionSidecar: Codable {
        var userTurnCount: Int
    }

    private func sessionSidecarURL(agentID: String, sessionID: String) -> URL? {
        resolvedAgentDirectoryURL(agentID: agentID)?
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).sidecar.json", isDirectory: false)
    }

    private func readUserTurnCount(agentID: String, sessionID: String) throws -> Int {
        guard let url = sessionSidecarURL(agentID: agentID, sessionID: sessionID),
              fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let data = try Data(contentsOf: url)
        let sidecar = try JSONDecoder().decode(AgentSessionSidecar.self, from: data)
        return max(0, sidecar.userTurnCount)
    }

    private func writeUserTurnCount(agentID: String, sessionID: String, count: Int) throws {
        guard let url = sessionSidecarURL(agentID: agentID, sessionID: sessionID) else {
            throw StoreError.agentNotFound
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = try JSONEncoder().encode(AgentSessionSidecar(userTurnCount: max(0, count)))
        try payload.write(to: url, options: .atomic)
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

                guard let assetsDirectory = assetsDirectoryURL(agentID: normalizedAgentID, sessionID: normalizedSessionID) else {
                    throw StoreError.agentNotFound
                }
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

    func resolveAttachmentFileURL(agentID: String, attachment: AgentAttachment) throws -> URL? {
        let normalizedAgentID = try normalizedAgentID(agentID)
        guard let relativePath = attachment.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relativePath.isEmpty,
              let agentDirectory = resolvedAgentDirectoryURL(agentID: normalizedAgentID) else {
            return nil
        }
        return agentDirectory.appendingPathComponent(relativePath, isDirectory: false)
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
        guard let fileURL = sessionFileURL(agentID: agentID, sessionID: sessionID) else {
            logger.warning(
                "Session file URL resolution failed",
                metadata: [
                    "agent_id": .string(agentID),
                    "session_id": .string(sessionID),
                    "agents_root": .string(agentsRootURL.path)
                ]
            )
            throw StoreError.sessionFileNotFound(
                agentID: agentID,
                sessionID: sessionID,
                agentsRoot: agentsRootURL.path
            )
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionFileNotFound(
                agentID: agentID,
                sessionID: sessionID,
                agentsRoot: agentsRootURL.path
            )
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
            throw StoreError.sessionEventsEmpty(
                agentID: agentID,
                sessionID: sessionID,
                lineCount: lines.count,
                filePath: fileURL.path
            )
        }

        return events.sorted { $0.createdAt < $1.createdAt }
    }

    private func summaryForSession(agentID: String, sessionID: String, events: [AgentSessionEvent]) -> AgentSessionSummary {
        var title = "Session \(sessionID.prefix(8))"
        var parentSessionID: String?
        var kind: AgentSessionKind = .chat
        var projectID: String?
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
                kind = metadata.kind
                projectID = metadata.projectId
            }

            if let message = event.message {
                messageCount += 1
                if let preview = previewText(for: message), !preview.isEmpty {
                    lastPreview = preview
                }
            }
        }

        let userTurnCount = (try? readUserTurnCount(agentID: agentID, sessionID: sessionID)) ?? 0

        return AgentSessionSummary(
            id: sessionID,
            agentId: agentID,
            title: title,
            parentSessionId: parentSessionID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messageCount,
            lastMessagePreview: lastPreview,
            kind: kind,
            userTurnCount: userTurnCount,
            projectId: projectID
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

    private func resolvedAgentDirectoryURL(agentID: String) -> URL? {
        let regular = agentsRootURL.appendingPathComponent(agentID, isDirectory: true)
        if fileManager.fileExists(atPath: regular.path) {
            return regular
        }
        let system = agentsRootURL.appendingPathComponent(".system", isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
        if fileManager.fileExists(atPath: system.path) {
            return system
        }
        return nil
    }

    private func sessionsDirectoryURL(agentID: String, createIfMissing: Bool) throws -> URL {
        guard let agentDirectory = resolvedAgentDirectoryURL(agentID: agentID) else {
            throw StoreError.agentNotFound
        }

        let sessionsDirectory = agentDirectory.appendingPathComponent("sessions", isDirectory: true)
        if createIfMissing {
            try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }
        return sessionsDirectory
    }

    private func sessionFileURL(agentID: String, sessionID: String) -> URL? {
        resolvedAgentDirectoryURL(agentID: agentID)?
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    private func assetsDirectoryURL(agentID: String, sessionID: String) -> URL? {
        resolvedAgentDirectoryURL(agentID: agentID)?
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

    private static func shortSessionID(_ sessionID: String) -> String {
        let prefix = "session-"
        if sessionID.hasPrefix(prefix) {
            return String(sessionID.dropFirst(prefix.count).prefix(8))
        }
        return String(sessionID.prefix(8))
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

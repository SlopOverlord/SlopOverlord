import Foundation
import Logging

public struct PendingApprovalEntry: Codable, Sendable, Equatable {
    public var id: String
    public var platform: String
    public var platformUserId: String
    public var displayName: String
    public var chatId: String
    public var channelId: String?
    public var code: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        platform: String,
        platformUserId: String,
        displayName: String,
        chatId: String,
        channelId: String? = nil,
        code: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.platform = platform
        self.platformUserId = platformUserId
        self.displayName = displayName
        self.chatId = chatId
        self.channelId = channelId
        self.code = code
        self.createdAt = createdAt
    }
}

/// Manages pending approval entries for channel access requests.
/// Stores state in memory, persisting to a JSON file in the workspace directory.
public actor PendingApprovalService {
    private var entries: [String: PendingApprovalEntry] = [:]
    private let fileURL: URL
    private let logger: Logger

    public init(workspaceDirectory: String, logger: Logger? = nil) {
        self.fileURL = URL(fileURLWithPath: workspaceDirectory)
            .appendingPathComponent("pending_approval.json")
        self.logger = logger ?? Logger(label: "sloppy.core.pending-approval")
        self.entries = Self.load(from: self.fileURL)
    }

    public func addPending(
        platform: String,
        platformUserId: String,
        displayName: String,
        chatId: String,
        channelId: String? = nil
    ) -> PendingApprovalEntry {
        if let existing = entries.values.first(where: {
            $0.platform == platform && $0.platformUserId == platformUserId
        }) {
            return existing
        }
        let entry = PendingApprovalEntry(
            platform: platform,
            platformUserId: platformUserId,
            displayName: displayName,
            chatId: chatId,
            channelId: channelId,
            code: Self.generateCode()
        )
        entries[entry.id] = entry
        persist()
        logger.info("Pending approval added: platform=\(platform) userId=\(platformUserId) id=\(entry.id)")
        return entry
    }

    public func listPending() -> [PendingApprovalEntry] {
        Array(entries.values).sorted { $0.createdAt < $1.createdAt }
    }

    public func listPending(platform: String) -> [PendingApprovalEntry] {
        entries.values.filter { $0.platform == platform }.sorted { $0.createdAt < $1.createdAt }
    }

    public func findById(_ id: String) -> PendingApprovalEntry? {
        entries[id]
    }

    public func findByUser(platform: String, platformUserId: String) -> PendingApprovalEntry? {
        entries.values.first { $0.platform == platform && $0.platformUserId == platformUserId }
    }

    public func removePending(id: String) {
        guard entries[id] != nil else { return }
        entries[id] = nil
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let list = Array(entries.values)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.warning("Failed to persist pending approvals: \(error)")
        }
    }

    private static func load(from url: URL) -> [String: PendingApprovalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([PendingApprovalEntry].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    // MARK: - Code generation

    private static func generateCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}

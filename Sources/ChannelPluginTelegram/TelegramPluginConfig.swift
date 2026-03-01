import Foundation

struct TelegramPluginConfig: Sendable {
    let botToken: String
    let allowedUserIds: Set<Int64>
    let allowedChatIds: Set<Int64>
    /// Maps SlopOverlord channelId → Telegram chat_id.
    let channelChatMap: [String: Int64]

    /// Initialise from structured config values (used when loading from CoreConfig).
    init(
        botToken: String,
        channelChatMap: [String: Int64] = [:],
        allowedUserIds: [Int64] = [],
        allowedChatIds: [Int64] = []
    ) {
        self.botToken = botToken
        self.channelChatMap = channelChatMap
        self.allowedUserIds = Set(allowedUserIds)
        self.allowedChatIds = Set(allowedChatIds)
    }

    /// Reverse lookup: Telegram chat_id → channelId.
    func channelId(forChatId chatId: Int64) -> String? {
        channelChatMap.first(where: { $0.value == chatId })?.key
    }

    func chatId(forChannelId channelId: String) -> Int64? {
        channelChatMap[channelId]
    }

    func isAllowed(userId: Int64, chatId: Int64) -> Bool {
        if allowedUserIds.isEmpty && allowedChatIds.isEmpty {
            return true
        }
        if !allowedUserIds.isEmpty && !allowedUserIds.contains(userId) {
            return false
        }
        if !allowedChatIds.isEmpty && !allowedChatIds.contains(chatId) {
            return false
        }
        return true
    }
}

import Foundation

struct TelegramPluginConfig: Sendable {
    let botToken: String
    let coreBaseURL: String
    let coreAuthToken: String
    let listenHost: String
    let listenPort: Int
    let allowedUserIds: Set<Int64>
    let allowedChatIds: Set<Int64>
    /// Maps SlopOverlord channelId → Telegram chat_id.
    let channelChatMap: [String: Int64]

    static func fromEnvironment() -> TelegramPluginConfig {
        let botToken = envRequired("TELEGRAM_BOT_TOKEN")
        let coreBaseURL = env("CORE_BASE_URL", default: "http://127.0.0.1:25101")
        let coreAuthToken = env("CORE_AUTH_TOKEN", default: "dev-token")
        let listenHost = env("PLUGIN_HOST", default: "127.0.0.1")
        let listenPort = Int(env("PLUGIN_PORT", default: "9100")) ?? 9100
        let allowedUserIds = parseIntSet(env("TELEGRAM_ALLOWED_USER_IDS", default: ""))
        let allowedChatIds = parseIntSet(env("TELEGRAM_ALLOWED_CHAT_IDS", default: ""))
        let channelChatMap = parseChannelChatMap(env("TELEGRAM_CHANNEL_CHAT_MAP", default: ""))

        return TelegramPluginConfig(
            botToken: botToken,
            coreBaseURL: coreBaseURL,
            coreAuthToken: coreAuthToken,
            listenHost: listenHost,
            listenPort: listenPort,
            allowedUserIds: allowedUserIds,
            allowedChatIds: allowedChatIds,
            channelChatMap: channelChatMap
        )
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

private func env(_ key: String, default fallback: String) -> String {
    ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
}

private func envRequired(_ key: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        fatalError("Required environment variable \(key) is not set.")
    }
    return value
}

private func parseIntSet(_ value: String) -> Set<Int64> {
    let parts = value.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    return Set(parts)
}

/// Format: "channelId1:chatId1,channelId2:chatId2"
private func parseChannelChatMap(_ value: String) -> [String: Int64] {
    var map: [String: Int64] = [:]
    for pair in value.split(separator: ",") {
        let parts = pair.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let chatId = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else {
            continue
        }
        let channelId = parts[0].trimmingCharacters(in: .whitespaces)
        if !channelId.isEmpty {
            map[channelId] = chatId
        }
    }
    return map
}

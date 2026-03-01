import Foundation
import Logging
import PluginSDK

/// In-process GatewayPlugin that bridges Telegram to SlopOverlord channels.
/// Uses long-polling to receive messages and InboundMessageReceiver to forward them to Core.
public final class TelegramGatewayPlugin: GatewayPlugin, @unchecked Sendable {
    public let id: String = "telegram"

    public var channelIds: [String] {
        Array(config.channelChatMap.keys)
    }

    private let config: TelegramPluginConfig
    private let bot: TelegramBotAPI
    private let logger: Logger
    private var pollerTask: Task<Void, Never>?

    public init(
        botToken: String,
        channelChatMap: [String: Int64],
        allowedUserIds: [Int64] = [],
        allowedChatIds: [Int64] = [],
        logger: Logger? = nil
    ) {
        self.config = TelegramPluginConfig(
            botToken: botToken,
            channelChatMap: channelChatMap,
            allowedUserIds: allowedUserIds,
            allowedChatIds: allowedChatIds
        )
        let resolvedLogger = logger ?? Logger(label: "slopoverlord.plugin.telegram")
        self.logger = resolvedLogger
        self.bot = TelegramBotAPI(botToken: botToken, logger: resolvedLogger)
    }

    public func start(inboundReceiver: any InboundMessageReceiver) async throws {
        guard pollerTask == nil else {
            logger.warning("Telegram plugin start() called but poller is already running.")
            return
        }
        let tokenPrefix = String(config.botToken.prefix(10))
        logger.info("Telegram gateway plugin starting. token=\(tokenPrefix)... channels=\(channelIds) allowedUsers=\(config.allowedUserIds.count) allowedChats=\(config.allowedChatIds.count)")
        if channelIds.isEmpty {
            logger.warning("No channel-chat mappings configured. Bot will receive messages but cannot route them to Core channels.")
        }
        let poller = TelegramPoller(
            bot: bot,
            receiver: inboundReceiver,
            config: config,
            logger: logger
        )
        pollerTask = Task { await poller.run() }
    }

    public func stop() async {
        pollerTask?.cancel()
        pollerTask = nil
        logger.info("Telegram gateway plugin stopped.")
    }

    public func send(channelId: String, message: String) async throws {
        guard let chatId = config.chatId(forChannelId: channelId) else {
            logger.warning("No Telegram chat mapping for channel \(channelId). Message dropped.")
            return
        }
        try await bot.sendMessage(chatId: chatId, text: message)
    }
}

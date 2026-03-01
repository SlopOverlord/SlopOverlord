import Foundation
import Logging

/// Long-polls Telegram for updates and forwards messages to Core via CoreBridge.
actor TelegramPoller {
    private let bot: TelegramBotAPI
    private let bridge: CoreBridge
    private let config: TelegramPluginConfig
    private let commands: CommandHandler
    private let logger: Logger
    private var offset: Int64? = nil

    init(bot: TelegramBotAPI, bridge: CoreBridge, config: TelegramPluginConfig, logger: Logger) {
        self.bot = bot
        self.bridge = bridge
        self.config = config
        self.commands = CommandHandler()
        self.logger = logger
    }

    func run() async {
        logger.info("Telegram poller started. Waiting for messages...")
        while !Task.isCancelled {
            do {
                let updates = try await bot.getUpdates(offset: offset, timeout: 60)
                for update in updates {
                    offset = update.updateId + 1
                    if let message = update.message {
                        await handleMessage(message)
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                logger.warning("Polling error: \(error). Retrying in 5s...")
                try? await Task.sleep(for: .seconds(5))
            }
        }
        logger.info("Telegram poller stopped.")
    }

    private func handleMessage(_ message: TelegramBotAPI.Message) async {
        guard let text = message.text, !text.isEmpty else { return }
        let userId = message.from?.id ?? 0
        let chatId = message.chat.id
        let displayName = message.from?.displayName ?? "unknown"

        if !config.isAllowed(userId: userId, chatId: chatId) {
            logger.info("Blocked message from user \(userId) in chat \(chatId) — not in allow list.")
            try? await bot.sendMessage(chatId: chatId, text: "Access denied.")
            return
        }

        guard let channelId = config.channelId(forChatId: chatId) else {
            logger.warning("No channel mapping for Telegram chat \(chatId). Ignoring.")
            return
        }

        if let localReply = commands.handle(text: text, from: displayName) {
            try? await bot.sendMessage(chatId: chatId, text: localReply)
            return
        }

        let coreContent = commands.transformForCore(text: text, from: displayName)
        let userIdString = "tg:\(userId)"

        let ok = await bridge.postChannelMessage(
            channelId: channelId,
            userId: userIdString,
            content: coreContent
        )

        if !ok {
            logger.warning("Failed to forward message to Core for channel \(channelId).")
            try? await bot.sendMessage(chatId: chatId, text: "Failed to reach Core. Please try again later.")
        }
    }
}

import Foundation
import ChannelPluginSupport
import Logging
import PluginSDK

/// Long-polls Telegram for updates and forwards messages to Core via InboundMessageReceiver.
actor TelegramPoller {
    private let bot: TelegramBotAPI
    private let receiver: any InboundMessageReceiver
    private let config: TelegramPluginConfig
    private let commands: ChannelCommandHandler
    private let logger: Logger
    private var offset: Int64? = nil

    init(
        bot: TelegramBotAPI,
        receiver: any InboundMessageReceiver,
        config: TelegramPluginConfig,
        logger: Logger
    ) {
        self.bot = bot
        self.receiver = receiver
        self.config = config
        self.commands = ChannelCommandHandler(platformName: "Telegram")
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
        let chatTitle = message.chat.title.map { " (\($0))" } ?? ""

        logger.info("Incoming message: userId=\(userId) chatId=\(chatId)\(chatTitle) from=\(displayName) length=\(text.count)")

        // Fast-path: config allowlist takes priority when non-empty
        if !config.allowedUserIds.isEmpty || !config.allowedChatIds.isEmpty {
            if !config.isAllowed(userId: userId, chatId: chatId) {
                logger.warning("Blocked: userId=\(userId) chatId=\(chatId) — not in allow list. allowedUsers=\(config.allowedUserIds) allowedChats=\(config.allowedChatIds)")
                let hint = "Access denied.\n\nTo allow this chat, add the following IDs to your config:\n• User ID: \(userId)\n• Chat ID: \(chatId)"
                _ = try? await bot.sendMessage(chatId: chatId, text: hint)
                return
            }
        } else {
            let accessResult = await receiver.checkAccess(
                platform: "telegram",
                platformUserId: String(userId),
                displayName: displayName,
                chatId: String(chatId)
            )
            switch accessResult {
            case .allowed:
                break
            case .pendingApproval(_, let message):
                logger.info("Access pending: userId=\(userId) chatId=\(chatId)")
                _ = try? await bot.sendMessage(chatId: chatId, text: message)
                return
            case .blocked:
                logger.warning("Access blocked: userId=\(userId) chatId=\(chatId)")
                _ = try? await bot.sendMessage(chatId: chatId, text: "Access denied.")
                return
            }
        }

        guard let channelId = config.channelId(forChatId: chatId) else {
            logger.warning("No channel mapping for chatId=\(chatId). Known mappings: \(config.channelChatMap). Message dropped.")
            let hint = "This chat is not connected to any channel.\n\nTo route messages here, add the following binding to your config:\n• Chat ID: \(chatId)\n\nMap it to a channel ID in the Channels → Bindings section."
            _ = try? await bot.sendMessage(chatId: chatId, text: hint)
            return
        }

        logger.info("Routing message: chatId=\(chatId) → channelId=\(channelId)")

        if let localReply = commands.handle(text: text, from: displayName) {
            logger.debug("Handled locally by CommandHandler, not forwarding to Core.")
            _ = try? await bot.sendMessage(chatId: chatId, text: localReply)
            return
        }

        let userIdString = "tg:\(userId)"

        let ok = await receiver.postMessage(
            channelId: channelId,
            userId: userIdString,
            content: text
        )

        if ok {
            logger.debug("Message forwarded to Core: channelId=\(channelId) userId=\(userIdString)")
        } else {
            logger.warning("Failed to forward message to Core: channelId=\(channelId)")
            _ = try? await bot.sendMessage(chatId: chatId, text: "Failed to reach Core. Please try again later.")
        }
    }
}

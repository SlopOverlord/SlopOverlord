import Foundation
import ArgumentParser
import Logging

@main
struct TelegramPluginMain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ChannelPluginTelegram",
        abstract: "SlopOverlord Channel Plugin for Telegram"
    )

    func run() async throws {
        var logger = Logger(label: "slopoverlord.plugin.telegram")
        logger.logLevel = .info

        let config = TelegramPluginConfig.fromEnvironment()
        logger.info("Channel-chat map: \(config.channelChatMap)")

        let bot = TelegramBotAPI(botToken: config.botToken)
        let bridge = CoreBridge(baseURL: config.coreBaseURL, authToken: config.coreAuthToken)

        let server = DeliverServer(
            host: config.listenHost,
            port: config.listenPort,
            bot: bot,
            config: config,
            logger: logger
        )
        let channel = try server.start()

        let poller = TelegramPoller(bot: bot, bridge: bridge, config: config, logger: logger)
        let pollerTask = Task { await poller.run() }

        logger.info("Telegram plugin ready. Deliver server on \(config.listenHost):\(config.listenPort)")

        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            logger.info("Received SIGINT, shutting down...")
            pollerTask.cancel()
            try? channel.close().wait()
        }
        signalSource.resume()

        try await channel.closeFuture.get()
    }
}

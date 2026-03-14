import Foundation
import ChannelPluginSupport
import Logging
import PluginSDK
import Protocols

actor DiscordGatewayLoop {
    private struct IncomingAuthor: Sendable {
        let id: String
        let username: String
        let globalName: String?
        let isBot: Bool

        var displayName: String {
            if let globalName, !globalName.isEmpty {
                return globalName
            }
            return username
        }
    }

    private struct IncomingMessage: Sendable {
        let id: String
        let channelId: String
        let guildId: String?
        let content: String
        let type: Int
        let author: IncomingAuthor

        init?(payload: DiscordGatewayPayload) {
            guard payload.op == 0,
                  payload.t == "MESSAGE_CREATE",
                  let object = payload.d?.asObject,
                  let id = object["id"]?.asString,
                  let channelId = object["channel_id"]?.asString,
                  let content = object["content"]?.asString,
                  let type = object["type"]?.asInt,
                  let authorObject = object["author"]?.asObject,
                  let authorId = authorObject["id"]?.asString,
                  let username = authorObject["username"]?.asString
            else {
                return nil
            }

            self.id = id
            self.channelId = channelId
            self.guildId = object["guild_id"]?.asString
            self.content = content
            self.type = type
            self.author = IncomingAuthor(
                id: authorId,
                username: username,
                globalName: authorObject["global_name"]?.asString,
                isBot: authorObject["bot"]?.asBool ?? false
            )
        }
    }

    private enum SessionControl: Error {
        case reconnect
    }

    private let client: any DiscordPlatformClient
    private let receiver: any InboundMessageReceiver
    private let config: DiscordPluginConfig
    private let commands: ChannelCommandHandler
    private let logger: Logger
    private var sequence: Int?
    private var botUserID: String?

    init(
        client: any DiscordPlatformClient,
        receiver: any InboundMessageReceiver,
        config: DiscordPluginConfig,
        logger: Logger
    ) {
        self.client = client
        self.receiver = receiver
        self.config = config
        self.commands = ChannelCommandHandler(platformName: "Discord")
        self.logger = logger
    }

    func run() async {
        logger.info("Discord gateway loop started. Waiting for messages...")
        var reconnectAttempt = 0

        while !Task.isCancelled {
            do {
                try await runSession()
                reconnectAttempt = 0
            } catch is CancellationError {
                break
            } catch SessionControl.reconnect {
                reconnectAttempt += 1
                let delay = min(max(reconnectAttempt, 1) * 2, 30)
                logger.info("Discord gateway requested reconnect. Retrying in \(delay)s.")
                try? await Task.sleep(for: .seconds(delay))
            } catch {
                reconnectAttempt += 1
                let delay = min(max(reconnectAttempt, 1) * 2, 30)
                logger.warning("Discord gateway loop error: \(error). Retrying in \(delay)s.")
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        logger.info("Discord gateway loop stopped.")
    }

    private func runSession() async throws {
        sequence = nil
        let url = try await client.gatewayURL()
        let session = try await client.connectGateway(url: url)

        defer {
            Task {
                await session.close()
            }
        }

        try await withTaskCancellationHandler {
            let hello = try await session.receive()
            let heartbeatInterval = try heartbeatInterval(from: hello)
            try await identify(session: session)

            let heartbeatTask = Task {
                await self.heartbeatLoop(session: session, intervalMilliseconds: heartbeatInterval)
            }
            defer {
                heartbeatTask.cancel()
            }

            while !Task.isCancelled {
                let payload = try await session.receive()
                if let sequence = payload.s {
                    self.sequence = sequence
                }
                try await handle(payload: payload, session: session)
            }
        } onCancel: {
            Task {
                await session.close()
            }
        }
    }

    private func heartbeatInterval(from payload: DiscordGatewayPayload) throws -> Int {
        guard payload.op == 10,
              let data = payload.d?.asObject,
              let interval = data["heartbeat_interval"]?.asInt
        else {
            throw DiscordTransportError.invalidResponse(method: "gateway.hello")
        }
        return interval
    }

    private func identify(session: any DiscordGatewaySession) async throws {
        let properties: [String: JSONValue] = [
            "os": .string("macOS"),
            "browser": .string("sloppy"),
            "device": .string("sloppy")
        ]
        let intents = 1 << 9
        let payload = DiscordGatewayOutboundPayload(
            op: 2,
            d: .object([
                "token": .string(config.botToken),
                "properties": .object(properties),
                "intents": .number(Double(intents))
            ])
        )
        try await session.send(payload)
    }

    private func heartbeatLoop(session: any DiscordGatewaySession, intervalMilliseconds: Int) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(intervalMilliseconds))
                guard !Task.isCancelled else {
                    return
                }
                try await session.send(
                    DiscordGatewayOutboundPayload(
                        op: 1,
                        d: sequence.map { .number(Double($0)) } ?? .null
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                logger.warning("Discord heartbeat failed: \(error)")
                return
            }
        }
    }

    private func handle(
        payload: DiscordGatewayPayload,
        session: any DiscordGatewaySession
    ) async throws {
        switch payload.op {
        case 0:
            try await handleDispatch(payload)
        case 1:
            try await session.send(
                DiscordGatewayOutboundPayload(
                    op: 1,
                    d: sequence.map { .number(Double($0)) } ?? .null
                )
            )
        case 7, 9:
            throw SessionControl.reconnect
        case 10, 11:
            return
        default:
            return
        }
    }

    private func handleDispatch(_ payload: DiscordGatewayPayload) async throws {
        switch payload.t {
        case "READY":
            botUserID = payload.d?.asObject?["user"]?.asObject?["id"]?.asString
            logger.info("Discord gateway READY received. botUserId=\(botUserID ?? "unknown")")
        case "MESSAGE_CREATE":
            if let message = IncomingMessage(payload: payload) {
                await handleIncomingMessage(message)
            }
        default:
            return
        }
    }

    private func handleIncomingMessage(_ message: IncomingMessage) async {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return
        }
        guard message.type == 0 else {
            return
        }
        guard !message.author.isBot else {
            return
        }
        if let botUserID, botUserID == message.author.id {
            return
        }

        logger.info(
            "Incoming Discord message: userId=\(message.author.id) channelId=\(message.channelId) guildId=\(message.guildId ?? "none") from=\(message.author.displayName) length=\(content.count)"
        )

        // Fast-path: config allowlist takes priority when non-empty
        if !config.allowedUserIds.isEmpty || !config.allowedGuildIds.isEmpty || !config.allowedChannelIds.isEmpty {
            if !config.isAllowed(
                userId: message.author.id,
                guildId: message.guildId,
                channelId: message.channelId
            ) {
                logger.warning(
                    "Blocked Discord message: userId=\(message.author.id) channelId=\(message.channelId) guildId=\(message.guildId ?? "none")"
                )
                _ = try? await client.sendMessage(
                    channelId: message.channelId,
                    content: trimmedContent(
                        """
                        Access denied.

                        Allow one or more of these IDs in your Discord config:
                        User ID: \(message.author.id)
                        Channel ID: \(message.channelId)
                        Guild ID: \(message.guildId ?? "n/a")
                        """
                    )
                )
                return
            }
        } else {
            let accessResult = await receiver.checkAccess(
                platform: "discord",
                platformUserId: message.author.id,
                displayName: message.author.displayName,
                chatId: message.channelId
            )
            switch accessResult {
            case .allowed:
                break
            case .pendingApproval(_, let msg):
                logger.info("Access pending: userId=\(message.author.id) channelId=\(message.channelId)")
                _ = try? await client.sendMessage(channelId: message.channelId, content: trimmedContent(msg))
                return
            case .blocked:
                logger.warning("Access blocked: userId=\(message.author.id) channelId=\(message.channelId)")
                _ = try? await client.sendMessage(channelId: message.channelId, content: "Access denied.")
                return
            }
        }

        guard let sloppyChannelId = config.channelId(forDiscordChannelId: message.channelId) else {
            logger.warning("No Discord channel mapping for channelId=\(message.channelId).")
            _ = try? await client.sendMessage(
                channelId: message.channelId,
                content: trimmedContent(
                    """
                    This Discord channel is not connected to any Sloppy channel.

                    Add the following binding to your config:
                    Channel ID: \(message.channelId)
                    """
                )
            )
            return
        }

        if let localReply = commands.handle(text: content, from: message.author.displayName) {
            _ = try? await client.sendMessage(
                channelId: message.channelId,
                content: trimmedContent(localReply)
            )
            return
        }

        let ok = await receiver.postMessage(
            channelId: sloppyChannelId,
            userId: "discord:\(message.author.id)",
            content: content
        )

        if !ok {
            _ = try? await client.sendMessage(
                channelId: message.channelId,
                content: "Failed to reach Core. Please try again later."
            )
        }
    }

    private func trimmedContent(_ value: String) -> String {
        let limit = 2_000
        if value.count <= limit {
            return value
        }
        let endIndex = value.index(value.startIndex, offsetBy: limit - 1)
        return String(value[..<endIndex]) + "…"
    }
}

import Foundation
import Logging
import PluginSDK
import Protocols

public actor DiscordGatewayPlugin: StreamingGatewayPlugin, PlanInputGatewayPlugin {
    private struct StreamState: Sendable {
        let discordChannelId: String
        let messageId: String
        var lastRenderedText: String
        var lastUpdatedAt: Date
    }

    public nonisolated let id: String = "discord"
    public nonisolated let channelIds: [String]

    private let config: DiscordPluginConfig
    private let client: any DiscordPlatformClient
    private let logger: Logger
    private let planInputMenus = DiscordGatewayLoop.PlanInputMenuStore()
    private var gatewayTask: Task<Void, Never>?
    private var streams: [String: StreamState] = [:]

    public init(
        botToken: String,
        channelDiscordChannelMap: [String: String],
        allowedGuildIds: [String] = [],
        allowedChannelIds: [String] = [],
        allowedUserIds: [String] = [],
        logger: Logger? = nil
    ) {
        self.init(
            botToken: botToken,
            channelDiscordChannelMap: channelDiscordChannelMap,
            allowedGuildIds: allowedGuildIds,
            allowedChannelIds: allowedChannelIds,
            allowedUserIds: allowedUserIds,
            logger: logger,
            client: nil
        )
    }

    init(
        botToken: String,
        channelDiscordChannelMap: [String: String],
        allowedGuildIds: [String] = [],
        allowedChannelIds: [String] = [],
        allowedUserIds: [String] = [],
        logger: Logger? = nil,
        client: (any DiscordPlatformClient)? = nil
    ) {
        self.config = DiscordPluginConfig(
            botToken: botToken,
            channelDiscordChannelMap: channelDiscordChannelMap,
            allowedGuildIds: allowedGuildIds,
            allowedChannelIds: allowedChannelIds,
            allowedUserIds: allowedUserIds
        )
        self.channelIds = Array(channelDiscordChannelMap.keys)
        let resolvedLogger = logger ?? Logger(label: "sloppy.plugin.discord")
        self.logger = resolvedLogger
        self.client = client ?? DiscordHTTPClient(botToken: botToken, logger: resolvedLogger)
    }

    public func start(inboundReceiver: any InboundMessageReceiver) async throws {
        guard gatewayTask == nil else {
            logger.warning("Discord plugin start() called but gateway loop is already running.")
            return
        }

        logger.info(
            "Discord gateway plugin starting. channels=\(channelIds) allowedGuilds=\(config.allowedGuildIds.count) allowedChannels=\(config.allowedChannelIds.count) allowedUsers=\(config.allowedUserIds.count)"
        )
        if channelIds.isEmpty {
            logger.warning("No channel mappings configured for Discord plugin.")
        }

        let loop = DiscordGatewayLoop(
            client: client,
            receiver: inboundReceiver,
            config: config,
            sloppyChannelIds: channelIds,
            logger: logger,
            planInputMenus: planInputMenus
        )
        gatewayTask = Task {
            await loop.run()
        }
    }

    public func stop() async {
        gatewayTask?.cancel()
        gatewayTask = nil
        streams.removeAll()
        logger.info("Discord gateway plugin stopped.")
    }

    public func send(channelId: String, message: String, topicId: String?) async throws {
        guard let discordChannelId = config.discordChannelId(forChannelId: channelId) else {
            logger.warning("No Discord channel mapping for channel \(channelId). Message dropped.")
            return
        }
        _ = try await client.sendMessage(
            channelId: discordChannelId,
            content: renderContent(message)
        )
    }

    public func presentPlanInputRequest(
        channelId: String,
        userId _: String,
        request: PlanInputRequest,
        topicId _: String?
    ) async throws {
        guard let discordChannelId = config.discordChannelId(forChannelId: channelId) else {
            logger.warning("No Discord channel mapping for plan input \(request.id).")
            return
        }
        let nonce = String(UUID().uuidString.prefix(8))
        await planInputMenus.set(
            nonce: nonce,
            menu: .init(
                sloppyChannelId: ChannelGatewayScope.parse(channelId).baseChannelId,
                discordChannelId: discordChannelId,
                request: request
            )
        )
        _ = try await client.sendMessage(
            channelId: discordChannelId,
            content: renderContent(Self.planInputText(request)),
            components: Self.planInputComponents(nonce: nonce, request: request)
        )
    }

    public func beginStreaming(channelId: String, userId: String, topicId: String?) async throws -> GatewayOutboundStreamHandle {
        guard let discordChannelId = config.discordChannelId(forChannelId: channelId) else {
            logger.warning("No Discord channel mapping for channel \(channelId). Stream start dropped.")
            throw DiscordTransportError.invalidResponse(method: "beginStreaming")
        }

        let placeholder = try await client.sendMessage(
            channelId: discordChannelId,
            content: "Thinking..."
        )
        let handle = GatewayOutboundStreamHandle(id: UUID().uuidString)
        streams[handle.id] = StreamState(
            discordChannelId: discordChannelId,
            messageId: placeholder.id,
            lastRenderedText: "",
            lastUpdatedAt: .distantPast
        )
        return handle
    }

    public func updateStreaming(
        handle: GatewayOutboundStreamHandle,
        channelId: String,
        content: String
    ) async throws {
        guard var state = streams[handle.id] else {
            return
        }

        let normalized = renderContent(content.replacingOccurrences(of: "\r\n", with: "\n"))
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized != state.lastRenderedText
        else {
            return
        }

        let now = Date()
        let minInterval: TimeInterval = 1.0
        guard now.timeIntervalSince(state.lastUpdatedAt) >= minInterval else {
            return
        }

        _ = try await client.editMessage(
            channelId: state.discordChannelId,
            messageId: state.messageId,
            content: normalized
        )
        state.lastRenderedText = normalized
        state.lastUpdatedAt = now
        streams[handle.id] = state
    }

    public func endStreaming(
        handle: GatewayOutboundStreamHandle,
        channelId: String,
        userId: String,
        finalContent: String?
    ) async throws {
        guard let state = streams.removeValue(forKey: handle.id) else {
            return
        }

        guard let finalContent,
              !finalContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            try await client.deleteMessage(
                channelId: state.discordChannelId,
                messageId: state.messageId
            )
            return
        }

        let rendered = renderContent(finalContent)
        guard rendered != state.lastRenderedText else {
            return
        }

        _ = try await client.editMessage(
            channelId: state.discordChannelId,
            messageId: state.messageId,
            content: rendered
        )
    }

    private func renderContent(_ value: String) -> String {
        let limit = 2_000
        if value.count <= limit {
            return value
        }
        let endIndex = value.index(value.startIndex, offsetBy: limit - 1)
        return String(value[..<endIndex]) + "…"
    }

    private static func planInputText(_ request: PlanInputRequest) -> String {
        var lines: [String] = [request.title ?? "Plan input requested"]
        for (index, question) in request.questions.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(question.question)")
            for option in question.options {
                if let description = option.description, !description.isEmpty {
                    lines.append("- \(option.label): \(description)")
                } else {
                    lines.append("- \(option.label)")
                }
            }
        }
        lines.append("")
        if request.questions.count == 1 {
            lines.append("Use a button, or send your own answer as the next message.")
        } else {
            lines.append("Send custom answers as the next message, one line per question.")
        }
        return lines.joined(separator: "\n")
    }

    private static func planInputComponents(nonce: String, request: PlanInputRequest) -> JSONValue? {
        guard request.questions.count == 1, let question = request.questions.first else {
            return nil
        }
        var rows: [JSONValue] = []
        var current: [JSONValue] = []
        for (index, option) in question.options.enumerated() {
            current.append(.object([
                "type": .number(2),
                "style": .number(1),
                "label": .string(String(option.label.prefix(80))),
                "custom_id": .string("sloppy:pi:\(nonce):\(index)")
            ]))
            if current.count == 5 {
                rows.append(.object(["type": .number(1), "components": .array(current)]))
                current = []
            }
        }
        if !current.isEmpty {
            rows.append(.object(["type": .number(1), "components": .array(current)]))
        }
        return .array(rows)
    }
}

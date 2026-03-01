import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import Logging

/// Minimal HTTP server that accepts POST /deliver from Core and sends the message via Telegram.
final class DeliverServer: Sendable {
    private let host: String
    private let port: Int
    private let bot: TelegramBotAPI
    private let config: TelegramPluginConfig
    private let logger: Logger

    init(host: String, port: Int, bot: TelegramBotAPI, config: TelegramPluginConfig, logger: Logger) {
        self.host = host
        self.port = port
        self.bot = bot
        self.config = config
        self.logger = logger
    }

    func start() throws -> Channel {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [bot, config, logger] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(DeliverHandler(bot: bot, config: config, logger: logger))
                }
            }
        let channel = try bootstrap.bind(host: host, port: port).wait()
        logger.info("Deliver server listening on \(host):\(port)")
        return channel
    }
}

private final class DeliverHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let bot: TelegramBotAPI
    private let config: TelegramPluginConfig
    private let logger: Logger

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(bot: TelegramBotAPI, config: TelegramPluginConfig, logger: Logger) {
        self.bot = bot
        self.config = config
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
        case .body(var body):
            requestBody?.writeBuffer(&body)
        case .end:
            guard let head = requestHead else {
                writeResponse(context: context, status: .badRequest, body: #"{"error":"bad_request"}"#)
                return
            }
            handleRequest(context: context, head: head, body: requestBody)
            requestHead = nil
            requestBody = nil
        }
    }

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?) {
        if head.method == .POST && head.uri.hasPrefix("/deliver") {
            handleDeliver(context: context, body: body)
        } else if head.method == .GET && head.uri == "/health" {
            writeResponse(context: context, status: .ok, body: #"{"ok":true}"#)
        } else {
            writeResponse(context: context, status: .notFound, body: #"{"error":"not_found"}"#)
        }
    }

    private func handleDeliver(context: ChannelHandlerContext, body: ByteBuffer?) {
        guard let body,
              let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes),
              let payload = try? JSONDecoder().decode(DeliverPayload.self, from: Data(bytes)) else {
            writeResponse(context: context, status: .badRequest, body: #"{"error":"invalid_body"}"#)
            return
        }

        guard let chatId = config.chatId(forChannelId: payload.channelId) else {
            writeResponse(context: context, status: .ok, body: #"{"ok":false,"reason":"unmapped_channel"}"#)
            return
        }

        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let bot = self.bot
        let logger = self.logger

        context.eventLoop.makeFutureWithTask {
            do {
                try await bot.sendMessage(chatId: chatId, text: payload.content)
            } catch {
                logger.warning("Failed to deliver message to Telegram chat \(chatId): \(error)")
            }
            let ctx = loopBoundContext.value
            self.writeResponse(context: ctx, status: .ok, body: #"{"ok":true}"#)
        }.whenFailure { error in
            let ctx = loopBoundContext.value
            self.writeResponse(context: ctx, status: .internalServerError, body: #"{"error":"delivery_failed"}"#)
        }
    }

    private func writeResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)

        var head = HTTPResponseHead(version: .http1_1, status: status)
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")

        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private struct DeliverPayload: Decodable {
    let channelId: String
    let userId: String
    let content: String
}

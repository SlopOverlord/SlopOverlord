import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

/// Runs HTTP transport for CoreRouter using SwiftNIO HTTP/1.1.
public final class CoreHTTPServer {
    private let host: String
    private let port: Int
    private let router: CoreRouter
    private let logger: Logger
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(host: String, port: Int, router: CoreRouter, logger: Logger) {
        self.host = host
        self.port = port
        self.router = router
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Binds to host:port and starts accepting HTTP requests.
    public func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [router, logger] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CoreHTTPHandler(router: router, logger: logger))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    /// Waits until server channel is closed.
    public func waitUntilClosed() throws {
        guard let channel else {
            return
        }
        try channel.closeFuture.wait()
    }

    /// Returns dynamically bound TCP port (useful when server starts with port 0 in tests).
    public var boundPort: Int? {
        guard let address = channel?.localAddress else {
            return nil
        }
        return address.port
    }

    /// Shuts server down and releases event loops.
    public func shutdown() throws {
        if let channel {
            try channel.close().wait()
        }
        try group.syncShutdownGracefully()
    }
}

private final class CoreHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: CoreRouter
    private let logger: Logger
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var streamTask: Task<Void, Never>?

    init(router: CoreRouter, logger: Logger) {
        self.router = router
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            streamTask?.cancel()
            streamTask = nil
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)

        case .body(var bodyPart):
            if requestBody == nil {
                requestBody = context.channel.allocator.buffer(capacity: bodyPart.readableBytes)
            }
            requestBody?.writeBuffer(&bodyPart)

        case .end:
            guard let head = requestHead else {
                return
            }

            requestHead = nil
            var bodyBuffer = requestBody
            requestBody = nil

            if head.method == .OPTIONS {
                writePreflightResponse(context: context, requestHead: head)
                return
            }

            let method = head.method.rawValue
            let path = head.uri
            let bodyData = readData(from: &bodyBuffer)
            let router = self.router

            let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            let responseFuture = context.eventLoop.makeFutureWithTask {
                await router.handle(method: method, path: path, body: bodyData)
            }

            responseFuture.whenSuccess { [weak self] response in
                let context = loopBoundContext.value
                self?.writeResponse(context: context, requestHead: head, response: response)
            }

            responseFuture.whenFailure { [weak self] error in
                let context = loopBoundContext.value
                self?.logger.error("Failed to handle request: \(String(describing: error))")
                self?.writeServerError(context: context, requestHead: head)
            }
        }
    }

    private func writeResponse(
        context: ChannelHandlerContext,
        requestHead: HTTPRequestHead,
        response: CoreRouterResponse
    ) {
        if let sseStream = response.sseStream {
            writeSSEStreamResponse(
                context: context,
                requestHead: requestHead,
                response: response,
                stream: sseStream
            )
            return
        }

        let keepAlive = requestHead.isKeepAlive
        var headers = defaultHeaders(contentType: response.contentType, contentLength: response.body.count)
        headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")

        let head = HTTPResponseHead(
            version: requestHead.version,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )

        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive {
                loopBoundContext.value.close(promise: nil)
            }
        }
    }

    private func writeSSEStreamResponse(
        context: ChannelHandlerContext,
        requestHead: HTTPRequestHead,
        response: CoreRouterResponse,
        stream: AsyncStream<CoreRouterServerSentEvent>
    ) {
        let keepAlive = requestHead.isKeepAlive
        var headers = defaultHeaders(contentType: "\(response.contentType); charset=utf-8")
        headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")
        headers.replaceOrAdd(name: "cache-control", value: "no-cache")
        headers.replaceOrAdd(name: "x-accel-buffering", value: "no")
        headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")

        let head = HTTPResponseHead(
            version: requestHead.version,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )

        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.flush()

        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.writeStreamChunk(
                eventLoop: eventLoop,
                loopBoundContext: loopBoundContext,
                bytes: Data(": stream-open\n\n".utf8)
            )

            for await event in stream {
                if Task.isCancelled {
                    break
                }
                await self.writeStreamChunk(
                    eventLoop: eventLoop,
                    loopBoundContext: loopBoundContext,
                    bytes: self.encodeSSEPacket(event: event)
                )
            }

            await self.finishStreamResponse(
                eventLoop: eventLoop,
                loopBoundContext: loopBoundContext,
                keepAlive: keepAlive
            )
        }
    }

    private func writePreflightResponse(context: ChannelHandlerContext, requestHead: HTTPRequestHead) {
        var headers = defaultHeaders(contentType: "application/json", contentLength: 0)
        headers.replaceOrAdd(name: "connection", value: requestHead.isKeepAlive ? "keep-alive" : "close")

        let responseHead = HTTPResponseHead(
            version: requestHead.version,
            status: .ok,
            headers: headers
        )

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !requestHead.isKeepAlive {
                loopBoundContext.value.close(promise: nil)
            }
        }
    }

    private func writeServerError(context: ChannelHandlerContext, requestHead: HTTPRequestHead) {
        let payload = Data("{\"error\":\"internal\"}".utf8)
        let response = CoreRouterResponse(status: 500, body: payload)
        writeResponse(context: context, requestHead: requestHead, response: response)
    }

    private func encodeSSEPacket(event: CoreRouterServerSentEvent) -> Data {
        var lines: [String] = []
        if let id = event.id, !id.isEmpty {
            lines.append("id: \(id)")
        }
        lines.append("event: \(event.event)")

        let payload = String(data: event.data, encoding: .utf8) ?? "{}"
        let payloadLines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        if payloadLines.isEmpty {
            lines.append("data: {}")
        } else {
            for line in payloadLines {
                lines.append("data: \(line)")
            }
        }

        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func writeStreamChunk(
        eventLoop: any EventLoop,
        loopBoundContext: NIOLoopBound<ChannelHandlerContext>,
        bytes: Data
    ) async {
        await withCheckedContinuation { continuation in
            eventLoop.execute { [weak self, loopBoundContext] in
                guard let self else {
                    continuation.resume()
                    return
                }

                let context = loopBoundContext.value
                var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func finishStreamResponse(
        eventLoop: any EventLoop,
        loopBoundContext: NIOLoopBound<ChannelHandlerContext>,
        keepAlive: Bool
    ) async {
        await withCheckedContinuation { continuation in
            eventLoop.execute { [weak self, loopBoundContext] in
                guard let self else {
                    continuation.resume()
                    return
                }

                let context = loopBoundContext.value
                let innerLoopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                    if !keepAlive {
                        innerLoopBoundContext.value.close(promise: nil)
                    }
                    continuation.resume()
                }
            }
        }
    }


    private func readData(from buffer: inout ByteBuffer?) -> Data? {
        guard var buffer else {
            return nil
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return Data(bytes)
    }

    private func defaultHeaders(contentType: String, contentLength: Int? = nil) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        if let contentLength {
            headers.add(name: "content-length", value: "\(contentLength)")
        }
        headers.add(name: "access-control-allow-origin", value: "*")
        headers.add(name: "access-control-allow-methods", value: "GET,POST,PUT,PATCH,DELETE,OPTIONS")
        headers.add(name: "access-control-allow-headers", value: "content-type,authorization,last-event-id")
        headers.add(name: "access-control-max-age", value: "600")
        return headers
    }

    func channelInactive(context: ChannelHandlerContext) {
        streamTask?.cancel()
        streamTask = nil
        context.fireChannelInactive()
    }
}

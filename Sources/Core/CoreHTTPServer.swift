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

    init(router: CoreRouter, logger: Logger) {
        self.router = router
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
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
            let path = normalizedPath(head.uri)
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

    private func normalizedPath(_ uri: String) -> String {
        if let separatorIndex = uri.firstIndex(of: "?") {
            return String(uri[..<separatorIndex])
        }
        return uri
    }

    private func readData(from buffer: inout ByteBuffer?) -> Data? {
        guard var buffer else {
            return nil
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return Data(bytes)
    }

    private func defaultHeaders(contentType: String, contentLength: Int) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: "\(contentLength)")
        headers.add(name: "access-control-allow-origin", value: "*")
        headers.add(name: "access-control-allow-methods", value: "GET,POST,PUT,OPTIONS")
        headers.add(name: "access-control-allow-headers", value: "content-type,authorization")
        headers.add(name: "access-control-max-age", value: "600")
        return headers
    }
}

import Foundation

/// Retains an ``InboundMessageReceiver`` for plugin C ABI handoff.
public final class GatewayPluginReceiverBox: @unchecked Sendable {
    public let receiver: any InboundMessageReceiver

    public init(receiver: any InboundMessageReceiver) {
        self.receiver = receiver
    }
}

/// Wraps a gateway plugin implementation for return through `sloppy_gateway_create`.
public final class AnyGatewayPluginBox: GatewayPlugin, @unchecked Sendable {
    public let id: String
    public let channelIds: [String]
    private let _start: @Sendable (any InboundMessageReceiver) async throws -> Void
    private let _stop: @Sendable () async -> Void
    private let _send: @Sendable (String, String, String?) async throws -> Void

    public init(
        id: String,
        channelIds: [String],
        start: @escaping @Sendable (any InboundMessageReceiver) async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        send: @escaping @Sendable (String, String, String?) async throws -> Void
    ) {
        self.id = id
        self.channelIds = channelIds
        self._start = start
        self._stop = stop
        self._send = send
    }

    public convenience init(
        id: String,
        channelIds: [String],
        start: @escaping @Sendable (any InboundMessageReceiver) async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        send: @escaping @Sendable (String, String) async throws -> Void
    ) {
        self.init(
            id: id,
            channelIds: channelIds,
            start: start,
            stop: stop,
            send: { channelId, message, _ in
                try await send(channelId, message)
            }
        )
    }

    public func start(inboundReceiver: any InboundMessageReceiver) async throws {
        try await _start(inboundReceiver)
    }

    public func stop() async {
        await _stop()
    }

    public func send(channelId: String, message: String, topicId: String?) async throws {
        try await _send(channelId, message, topicId)
    }
}

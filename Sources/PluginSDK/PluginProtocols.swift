import Foundation
import Protocols

/// Receives inbound messages from external channels and routes them into Core.
/// Implementations bridge external platforms (Telegram, Slack, etc.) to channel runtime.
public protocol InboundMessageReceiver: Sendable {
    func postMessage(channelId: String, userId: String, content: String) async -> Bool
}

/// In-process gateway plugin for direct integration.
/// Bundled plugins (e.g. Telegram) are linked directly; external plugins are loaded via dlopen.
/// For out-of-process channel plugins see: docs/specs/channel-plugin-protocol.md
public protocol GatewayPlugin: Sendable {
    var id: String { get }
    /// Channel IDs this plugin handles. Used to register plugin delivery routes.
    var channelIds: [String] { get }
    /// Start the plugin, supplying a receiver for inbound messages from the platform.
    func start(inboundReceiver: any InboundMessageReceiver) async throws
    func stop() async
    func send(channelId: String, message: String) async throws
}

public protocol ToolPlugin: Sendable {
    var id: String { get }
    var supportedTools: [String] { get }
    func invoke(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue
}

public protocol MemoryPlugin: Sendable {
    var id: String { get }
    func recall(query: String, limit: Int) async throws -> [MemoryRef]
    func save(note: String) async throws -> MemoryRef
}

public protocol ModelProviderPlugin: Sendable {
    var id: String { get }
    var models: [String] { get }
    func complete(model: String, prompt: String, maxTokens: Int) async throws -> String
    func stream(model: String, prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, any Error>
}

public extension ModelProviderPlugin {
    func stream(model: String, prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await complete(model: model, prompt: prompt, maxTokens: maxTokens)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

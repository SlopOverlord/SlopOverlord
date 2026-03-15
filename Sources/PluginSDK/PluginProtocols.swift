import AnyLanguageModel
import Foundation
import Protocols

/// Result of an access check for an incoming message from an external platform user.
public enum ChannelAccessResult: Sendable {
    case allowed
    case pendingApproval(code: String, message: String)
    case blocked
}

/// Receives inbound messages from external channels and routes them into Core.
/// Implementations bridge external platforms (Telegram, Slack, etc.) to channel runtime.
public protocol InboundMessageReceiver: Sendable {
    func postMessage(channelId: String, userId: String, content: String) async -> Bool

    /// Checks whether a user is allowed to interact with the given channel.
    /// Returns `.allowed` by default; override in CoreService to enforce allowlists and pending approval.
    func checkAccess(
        platform: String,
        platformUserId: String,
        displayName: String,
        chatId: String
    ) async -> ChannelAccessResult
}

public extension InboundMessageReceiver {
    func checkAccess(
        platform: String,
        platformUserId: String,
        displayName: String,
        chatId: String
    ) async -> ChannelAccessResult {
        .allowed
    }
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

    /// Stop the plugin.
    func stop() async

    /// Send a message to a channel.
    func send(channelId: String, message: String) async throws
}

public struct GatewayOutboundStreamHandle: Codable, Sendable, Equatable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

/// Optional outbound streaming contract for gateway plugins that support editing messages in place.
/// Extends the base `GatewayPlugin` to support progressive, streaming updates to messages,
/// such as partial completion updates or editable live output to a channel (e.g., Telegram, Slack).
public protocol StreamingGatewayPlugin: GatewayPlugin {
    /// Begin a streaming output session for the specified channel and user.
    /// Returns a handle used for subsequent updates and closing the stream.
    /// - Parameters:
    ///   - channelId: The unique channel identifier for this conversation or context.
    ///   - userId: The identifier of the user who initiated the operation.
    /// - Returns: A handle representing the streaming session, to be passed to update/end operations.
    func beginStreaming(channelId: String, userId: String) async throws -> GatewayOutboundStreamHandle

    /// Update the ongoing streaming session with new content.
    /// This may be called multiple times as new output is generated, e.g., partial completions.
    /// - Parameters:
    ///   - handle: The stream session handle, as returned by `beginStreaming`.
    ///   - channelId: The target channel identifier.
    ///   - content: The (possibly partial) content to send or update in the stream.
    func updateStreaming(handle: GatewayOutboundStreamHandle, channelId: String, content: String) async throws

    /// Finish and close the streaming session, optionally replacing the final message with `finalContent`.
    /// After this is called, the handle must not be used again.
    /// - Parameters:
    ///   - handle: The session handle previously returned by `beginStreaming`.
    ///   - channelId: The channel where the message was sent.
    ///   - userId: The user for which the stream was initiated.
    ///   - finalContent: If provided, replaces the last state of the message with this final content.
    func endStreaming(
        handle: GatewayOutboundStreamHandle,
        channelId: String,
        userId: String,
        finalContent: String?
    ) async throws
}

/// Plugin interface for exposing structured external tools ("actions") to an agent runtime.
/// Each tool must declare its contract (name, arguments) and implement `invoke`.
public protocol ToolPlugin: Sendable {
    /// Unique plugin identifier.
    var id: String { get }

    /// List of supported tool names (e.g. ["weather", "search", "code_search"]).
    var supportedTools: [String] { get }

    /// Invoke a named tool with arguments, returning result as serializable JSON.
    /// - Parameters:
    ///   - tool: Tool operation identifier.
    ///   - arguments: Named argument values.
    /// - Returns: Tool result as a JSONValue.
    func invoke(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue
}

/// Plugin for agent memory extension/persistence.
/// Implements recall (search) and save (add) operations for memory notes.
public protocol MemoryPlugin: Sendable {
    /// Unique plugin identifier.
    var id: String { get }

    /// Perform search in memory for a given free-text query, returning up to `limit` results.
    /// - Parameters:
    ///   - query: Search query string.
    ///   - limit: Maximum number of returned results.
    func recall(query: String, limit: Int) async throws -> [MemoryRef]

    /// Save a new note to memory, returning a reference object.
    /// - Parameter note: String representation of the note to store.
    func save(note: String) async throws -> MemoryRef
}

/// Plugin interface for model providers (Large Language Model integrations).
/// Used to integrate OpenAI, Ollama, and custom model backends.
/// Supports standard (single-turn) and streaming (progressive) completions.
public protocol ModelProviderPlugin: Sendable {
    /// Unique plugin identifier.
    var id: String { get }

    /// The list of supported model names or aliases.
    var models: [String] { get }

    /// Execute a single-turn text completion for the specified model and prompt.
    /// - Parameters:
    ///   - model: Model name or alias to use.
    ///   - prompt: Task or input prompt string.
    ///   - maxTokens: Max tokens to generate.
    ///   - reasoningEffort: (Optional) Optional reasoning effort parameter.
    /// - Returns: The generated text response.
    func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) async throws -> String

    /// Begin a streaming text completion, returning progressive output snapshots.
    /// - Parameters:
    ///   - model: Model name or alias to use.
    ///   - prompt: Input prompt.
    ///   - maxTokens: Max tokens to generate.
    ///   - reasoningEffort: (Optional) Optional reasoning effort parameter.
    /// - Returns: An AsyncThrowingStream of partial/final response texts.
    func stream(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?
    ) -> AsyncThrowingStream<String, any Error>
}

/// Default implementations for ModelProviderPlugin.
public extension ModelProviderPlugin {
    /// Execute a single-turn completion with native tool support.
    ///
    /// When `toolCallHandler` is provided, the plugin routes tool calls through it
    /// and continues the conversation until the model produces a final text response.
    /// The default implementation ignores the handler and delegates to `complete(model:prompt:maxTokens:reasoningEffort:)`.
    func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?,
        tools: [any Tool],
        toolCallHandler: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?
    ) async throws -> String {
        try await complete(model: model, prompt: prompt, maxTokens: maxTokens, reasoningEffort: reasoningEffort)
    }

    /// Begin a streaming completion with native tool support.
    ///
    /// When `toolCallHandler` is provided, tool calls are executed natively and the stream
    /// yields only the final text response. The default falls back to `stream(model:prompt:maxTokens:reasoningEffort:)`.
    func stream(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?,
        tools: [any Tool],
        toolCallHandler: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?
    ) -> AsyncThrowingStream<String, any Error> {
        stream(model: model, prompt: prompt, maxTokens: maxTokens, reasoningEffort: reasoningEffort)
    }
}

/// Default streaming implementation: if the plugin doesn't provide native streaming,
/// this mimics progressive output by yielding the final result as a single chunk.
public extension ModelProviderPlugin {
    func stream(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await complete(
                        model: model,
                        prompt: prompt,
                        maxTokens: maxTokens,
                        reasoningEffort: reasoningEffort
                    )
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
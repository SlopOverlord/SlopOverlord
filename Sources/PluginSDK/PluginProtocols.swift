import AnyLanguageModel
import Foundation
import Protocols

/// Result of an access check for an incoming message from an external platform user.
public enum ChannelAccessResult: Sendable {
    case allowed
    case pendingApproval(code: String, message: String)
    case blocked
}

/// Hints from a gateway plugin about how the user addressed this bot (group / shared-channel UX).
public struct ChannelInboundContext: Sendable, Equatable {
    /// `@bot` / `<@id>` / entity mention includes this integration.
    public var mentionsThisBot: Bool
    /// User replied to a message sent by this bot.
    public var isReplyToThisBot: Bool

    public init(mentionsThisBot: Bool = false, isReplyToThisBot: Bool = false) {
        self.mentionsThisBot = mentionsThisBot
        self.isReplyToThisBot = isReplyToThisBot
    }
}

public struct ChannelProjectLinkOption: Sendable, Equatable {
    public let projectId: String
    public let name: String

    public init(projectId: String, name: String) {
        self.projectId = projectId
        self.name = name
    }
}

public struct ChannelProjectLinkAgentOption: Sendable, Equatable {
    public let actorId: String
    public let agentId: String
    public let name: String
    public let channelId: String

    public init(actorId: String, agentId: String, name: String, channelId: String) {
        self.actorId = actorId
        self.agentId = agentId
        self.name = name
        self.channelId = channelId
    }
}

public enum ChannelProjectLinkResult: Sendable, Equatable {
    case linked(projectId: String, projectName: String, channelId: String, status: String)
    case conflict(ownerProjectId: String, ownerProjectName: String)
    case notFound
    case failed(message: String)
}

/// Receives inbound messages from external channels and routes them into sloppy.
/// Implementations bridge external platforms (Telegram, Slack, etc.) to channel runtime.
public protocol InboundMessageReceiver: Sendable {
    /// - Parameters:
    ///   - topicId: Optional platform-specific thread/topic scope (e.g. Telegram forum `message_thread_id` as decimal string).
    ///   - inboundContext: When non-`nil`, Core may apply per-agent activation policy (mention/reply-only). Pass `nil` for non-gateway callers.
    func postMessage(
        channelId: String,
        userId: String,
        content: String,
        topicId: String?,
        inboundContext: ChannelInboundContext?
    ) async -> Bool

    /// Checks whether a user is allowed to interact with the given channel.
    /// Returns `.allowed` by default; override in CoreService to enforce allowlists and pending approval.
    func checkAccess(
        platform: String,
        platformUserId: String,
        displayName: String,
        chatId: String
    ) async -> ChannelAccessResult

    /// Slash tokens for user-invocable skills installed on the agent linked to this channel (for `/token` handling).
    func skillSlashCommandTokens(forChannelID: String) async -> [String]

    /// Unique skill slash menu rows for all linked agents across the given channel ids (Telegram/Discord menus).
    func skillSlashMenuEntriesUnion(forChannelIDs: [String]) async -> [ChannelSlashCommandItem]

    /// Active dashboard projects available for gateway project-link pickers.
    func projectLinkOptions() async -> [ChannelProjectLinkOption]

    /// Agent routes available for a project-link picker.
    func projectLinkAgentOptions(projectId: String) async -> [ChannelProjectLinkAgentOption]

    /// Links the current platform channel or topic to a project.
    func linkProjectChannel(
        projectId: String,
        channelId: String,
        topicId: String?,
        title: String?,
        routeChannelId: String?,
        platform: String?,
        platformChannelId: String?
    ) async -> ChannelProjectLinkResult

    /// Answers a pending plan-mode input request from a native platform option button.
    func answerChannelPlanInputOption(
        channelId: String,
        userId: String,
        requestId: String,
        questionId: String,
        optionId: String,
        topicId: String?
    ) async -> Bool
}

public extension InboundMessageReceiver {
    func postMessage(channelId: String, userId: String, content: String, topicId: String?) async -> Bool {
        await postMessage(channelId: channelId, userId: userId, content: content, topicId: topicId, inboundContext: nil)
    }

    func postMessage(channelId: String, userId: String, content: String) async -> Bool {
        await postMessage(channelId: channelId, userId: userId, content: content, topicId: nil, inboundContext: nil)
    }

    func checkAccess(
        platform: String,
        platformUserId: String,
        displayName: String,
        chatId: String
    ) async -> ChannelAccessResult {
        .allowed
    }

    func skillSlashCommandTokens(forChannelID: String) async -> [String] {
        []
    }

    func skillSlashMenuEntriesUnion(forChannelIDs: [String]) async -> [ChannelSlashCommandItem] {
        []
    }

    func projectLinkOptions() async -> [ChannelProjectLinkOption] {
        []
    }

    func projectLinkAgentOptions(projectId: String) async -> [ChannelProjectLinkAgentOption] {
        []
    }

    func linkProjectChannel(
        projectId: String,
        channelId: String,
        topicId: String?,
        title: String?,
        routeChannelId: String?,
        platform: String?,
        platformChannelId: String?
    ) async -> ChannelProjectLinkResult {
        .failed(message: "Project linking is not available.")
    }

    func answerChannelPlanInputOption(
        channelId: String,
        userId: String,
        requestId: String,
        questionId: String,
        optionId: String,
        topicId: String?
    ) async -> Bool {
        false
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
    /// - Parameter topicId: Optional platform thread/topic (e.g. Telegram forum thread id as string); nil for default / non-threaded chat.
    func send(channelId: String, message: String, topicId: String?) async throws
}

public extension GatewayPlugin {
    func send(channelId: String, message: String) async throws {
        try await send(channelId: channelId, message: message, topicId: nil)
    }
}

/// Optional gateway capability for presenting plan-mode input requests with native platform actions.
public protocol PlanInputGatewayPlugin: GatewayPlugin {
    func presentPlanInputRequest(
        channelId: String,
        userId: String,
        request: PlanInputRequest,
        topicId: String?
    ) async throws
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
    ///   - topicId: Optional platform thread/topic matching the inbound message (e.g. Telegram forum thread).
    /// - Returns: A handle representing the streaming session, to be passed to update/end operations.
    func beginStreaming(channelId: String, userId: String, topicId: String?) async throws -> GatewayOutboundStreamHandle

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

public extension StreamingGatewayPlugin {
    func beginStreaming(channelId: String, userId: String) async throws -> GatewayOutboundStreamHandle {
        try await beginStreaming(channelId: channelId, userId: userId, topicId: nil)
    }
}

/// Optional gateway capability for presenting human approval prompts with native platform actions.
public protocol ToolApprovalGatewayPlugin: GatewayPlugin {
    func presentToolApproval(_ approval: ToolApprovalRecord) async throws
    func updateToolApproval(_ approval: ToolApprovalRecord) async throws
}

/// Lets an in-process gateway resolve tool approval callbacks without depending on CoreService.
public protocol ToolApprovalBridge: Sendable {
    func resolveToolApproval(id: String, approved: Bool, decidedBy: String?) async -> ToolApprovalRecord?
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

/// Thread-safe accumulator for model reasoning content captured during a single inference call.
///
/// Providers that support reasoning summaries (e.g. OpenAI o-series via OAuth) write deltas here
/// during streaming. The runtime reads the accumulated text once after the stream completes and
/// emits it as a `.thinking` observation.
public final class ReasoningContentCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _content: String = ""

    public init() {}

    public func append(_ delta: String) {
        lock.withLock { _content += delta }
    }

    public func consume() -> String {
        lock.withLock {
            let text = _content
            _content = ""
            return text
        }
    }
}

/// Thread-safe capture for token usage from a single model inference call.
///
/// Providers that receive usage data in API responses (e.g. OpenAI `response.completed` event)
/// write here during streaming. The runtime reads the captured usage once after the stream
/// completes and persists it.
public final class TokenUsageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _promptTokens: Int = 0
    private var _completionTokens: Int = 0

    public init() {}

    public func store(promptTokens: Int, completionTokens: Int) {
        lock.withLock {
            _promptTokens = promptTokens
            _completionTokens = completionTokens
        }
    }

    public func consume() -> (prompt: Int, completion: Int)? {
        lock.withLock {
            guard _promptTokens > 0 || _completionTokens > 0 else { return nil }
            let result = (prompt: _promptTokens, completion: _completionTokens)
            _promptTokens = 0
            _completionTokens = 0
            return result
        }
    }
}

/// Plugin interface for model providers (Large Language Model integrations).
/// Providers create `LanguageModel` instances that are used via `LanguageModelSession`.
public protocol ModelProvider: Sendable {
    /// Unique provider identifier.
    var id: String { get }

    /// The list of supported model identifiers (with provider prefix, e.g. "openai:gpt-4o").
    var supportedModels: [String] { get }

    /// System instructions injected into every session created from this provider.
    var systemInstructions: String? { get }

    /// Tools made available to every session created from this provider.
    var tools: [any Tool] { get }

    /// Creates a `LanguageModel` backend for the given model identifier.
    /// May perform async work (e.g. OAuth token refresh) before returning the model.
    func createLanguageModel(for modelName: String) async throws -> any LanguageModel

    /// Builds provider-specific `GenerationOptions` for the given parameters.
    func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions

    /// Returns the reasoning capture object for the given model, or `nil` if not supported.
    /// Composite providers should route to the matching sub-provider.
    func reasoningCapture(for modelName: String) -> ReasoningContentCapture?

    /// Returns the token usage capture object for the given model, or `nil` if not supported.
    func tokenUsageCapture(for modelName: String) -> TokenUsageCapture?

    /// Whether this provider can serve the given prefixed model id (including dynamic ids not listed in ``supportedModels``).
    func supports(modelName: String) -> Bool
}

public extension ModelProvider {
    var systemInstructions: String? { nil }
    var tools: [any Tool] { [] }

    func supports(modelName: String) -> Bool {
        supportedModels.contains(modelName)
    }

    func reasoningCapture(for modelName: String) -> ReasoningContentCapture? { nil }
    func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? { nil }

    func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: maxTokens)
    }
}

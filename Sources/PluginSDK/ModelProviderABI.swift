import AnyLanguageModel
import Foundation
import Protocols

/// Wraps a model provider implementation for return through `sloppy_model_provider_create`.
public final class AnyModelProviderBox: ModelProvider, @unchecked Sendable {
    public let id: String
    public let supportedModels: [String]
    public let systemInstructions: String?
    public let tools: [any Tool]

    private let _createLanguageModel: @Sendable (String) async throws -> any LanguageModel
    private let _generationOptions: @Sendable (String, Int, ReasoningEffort?) -> GenerationOptions
    private let _reasoningCapture: @Sendable (String) -> ReasoningContentCapture?
    private let _tokenUsageCapture: @Sendable (String) -> TokenUsageCapture?
    private let _supports: @Sendable (String) -> Bool

    public init(
        id: String,
        supportedModels: [String],
        systemInstructions: String? = nil,
        tools: [any Tool] = [],
        createLanguageModel: @escaping @Sendable (String) async throws -> any LanguageModel,
        generationOptions: @escaping @Sendable (String, Int, ReasoningEffort?) -> GenerationOptions = { _, maxTokens, _ in
            GenerationOptions(maximumResponseTokens: maxTokens)
        },
        reasoningCapture: @escaping @Sendable (String) -> ReasoningContentCapture? = { _ in nil },
        tokenUsageCapture: @escaping @Sendable (String) -> TokenUsageCapture? = { _ in nil },
        supports: @escaping @Sendable (String) -> Bool
    ) {
        self.id = id
        self.supportedModels = supportedModels
        self.systemInstructions = systemInstructions
        self.tools = tools
        self._createLanguageModel = createLanguageModel
        self._generationOptions = generationOptions
        self._reasoningCapture = reasoningCapture
        self._tokenUsageCapture = tokenUsageCapture
        self._supports = supports
    }

    public convenience init(
        id: String,
        supportedModels: [String],
        systemInstructions: String? = nil,
        tools: [any Tool] = [],
        createLanguageModel: @escaping @Sendable (String) async throws -> any LanguageModel
    ) {
        self.init(
            id: id,
            supportedModels: supportedModels,
            systemInstructions: systemInstructions,
            tools: tools,
            createLanguageModel: createLanguageModel,
            supports: { supportedModels.contains($0) }
        )
    }

    public func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        try await _createLanguageModel(modelName)
    }

    public func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        _generationOptions(modelName, maxTokens, reasoningEffort)
    }

    public func reasoningCapture(for modelName: String) -> ReasoningContentCapture? {
        _reasoningCapture(modelName)
    }

    public func tokenUsageCapture(for modelName: String) -> TokenUsageCapture? {
        _tokenUsageCapture(modelName)
    }

    public func supports(modelName: String) -> Bool {
        _supports(modelName)
    }
}

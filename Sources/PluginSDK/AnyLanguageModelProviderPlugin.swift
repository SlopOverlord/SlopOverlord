import AnyLanguageModel
import Foundation
import Logging
import Protocols

/// Bridges Sloppy `ModelProviderPlugin` protocol to AnyLanguageModel backends.
public struct AnyLanguageModelProviderPlugin: ModelProviderPlugin {
    /// OpenAI-compatible backend settings.
    public struct OpenAISettings: Sendable {
        public var apiKey: @Sendable () -> String
        public var baseURL: URL
        public var apiVariant: OpenAILanguageModel.APIVariant
        public var accountId: String?

        public init(
            apiKey: @escaping @Sendable () -> String,
            baseURL: URL = OpenAILanguageModel.defaultBaseURL,
            apiVariant: OpenAILanguageModel.APIVariant = .chatCompletions,
            accountId: String? = nil
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.apiVariant = apiVariant
            self.accountId = accountId
        }
    }

    /// Ollama backend settings.
    public struct OllamaSettings: Sendable {
        public var baseURL: URL

        public init(baseURL: URL = OllamaLanguageModel.defaultBaseURL) {
            self.baseURL = baseURL
        }
    }

    public enum PluginError: Error {
        case unsupportedModel(String)
        case missingConfiguration(String)
    }

    public let id: String
    public let models: [String]
    public let systemInstructions: String?

    private let openAI: OpenAISettings?
    private let ollama: OllamaSettings?
    private static let logger = Logger(label: "sloppy.plugin.any-language-model")

    public init(
        id: String = "any-language-model",
        models: [String],
        openAI: OpenAISettings? = nil,
        ollama: OllamaSettings? = nil,
        systemInstructions: String? = nil
    ) {
        self.id = id
        self.models = models
        self.openAI = openAI
        self.ollama = ollama
        self.systemInstructions = systemInstructions
    }

    /// Executes single-turn completion with the backend resolved from the model prefix.
    public func complete(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws -> String {
        let resolvedBackend: Backend
        do {
            resolvedBackend = try backend(for: model)
        } catch {
            logTerminalError(
                error,
                operation: "complete",
                model: model,
                backend: "resolver",
                apiVariant: nil
            )
            throw error
        }

        switch resolvedBackend {
        case .openAI(let settings):
            let resolvedModel = normalizeModelName(model, removing: "openai:")
            do {
                return try await completeOpenAI(
                    settings: settings,
                    model: resolvedModel,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    reasoningEffort: reasoningEffort,
                    apiVariant: settings.apiVariant
                )
            } catch {
                if shouldRetryOpenAIWithResponses(error: error, currentVariant: settings.apiVariant) {
                    logRetry(
                        operation: "complete",
                        model: model,
                        fromVariant: settings.apiVariant,
                        error: error
                    )
                    do {
                        return try await completeOpenAI(
                            settings: settings,
                            model: resolvedModel,
                            prompt: prompt,
                            maxTokens: maxTokens,
                            reasoningEffort: reasoningEffort,
                            apiVariant: .responses
                        )
                    } catch {
                        logTerminalError(
                            error,
                            operation: "complete",
                            model: model,
                            backend: "openai",
                            apiVariant: .responses
                        )
                        throw error
                    }
                }
                logTerminalError(
                    error,
                    operation: "complete",
                    model: model,
                    backend: "openai",
                    apiVariant: settings.apiVariant
                )
                throw error
            }
            
        case .openAIOAuth(let settings):
            let resolvedModel = normalizeModelName(model, removing: "openai:")
            let oauthModel = OpenAIOAuthModel(
                baseURL: settings.baseURL,
                bearerToken: settings.apiKey(),
                model: resolvedModel,
                apiVariant: .responses,
                accountId: settings.accountId
            )
            
            let session = LanguageModelSession(
                model: oauthModel,
                instructions: resolvedInstructions
            )
            let options = openAIGenerationOptions(maxTokens: maxTokens, reasoningEffort: reasoningEffort)
            let response: LanguageModelSession.Response<String> = try await session.respond(
                to: Prompt(prompt),
                generating: String.self,
                options: options
            )
            return response.content

        case .ollama(let settings):
            do {
                let session = LanguageModelSession(
                    model: OllamaLanguageModel(
                        baseURL: settings.baseURL,
                        model: normalizeModelName(model, removing: "ollama:")
                    ),
                    instructions: resolvedInstructions
                )
                let options = GenerationOptions(maximumResponseTokens: maxTokens)
                let response: LanguageModelSession.Response<String> = try await session.respond(
                    to: Prompt(prompt),
                    generating: String.self,
                    options: options
                )
                return response.content
            } catch {
                logTerminalError(
                    error,
                    operation: "complete",
                    model: model,
                    backend: "ollama",
                    apiVariant: nil
                )
                throw error
            }
        }
    }

    /// Streams single-turn completion snapshots, yielding progressively built text.
    public func stream(
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resolvedBackend: Backend
                    do {
                        resolvedBackend = try backend(for: model)
                    } catch {
                        logTerminalError(
                            error,
                            operation: "stream",
                            model: model,
                            backend: "resolver",
                            apiVariant: nil
                        )
                        throw error
                    }

                    switch resolvedBackend {
                    case .openAI(let settings):
                        let resolvedModel = normalizeModelName(model, removing: "openai:")
                        do {
                            try await streamOpenAI(
                                settings: settings,
                                model: resolvedModel,
                                prompt: prompt,
                                maxTokens: maxTokens,
                                reasoningEffort: reasoningEffort,
                                apiVariant: settings.apiVariant,
                                continuation: continuation
                            )
                            continuation.finish()
                        } catch {
                            if shouldRetryOpenAIWithResponses(error: error, currentVariant: settings.apiVariant) {
                                logRetry(
                                    operation: "stream",
                                    model: model,
                                    fromVariant: settings.apiVariant,
                                    error: error
                                )
                                do {
                                    try await streamOpenAI(
                                        settings: settings,
                                        model: resolvedModel,
                                        prompt: prompt,
                                        maxTokens: maxTokens,
                                        reasoningEffort: reasoningEffort,
                                        apiVariant: .responses,
                                        continuation: continuation
                                    )
                                    continuation.finish()
                                } catch {
                                    logTerminalError(
                                        error,
                                        operation: "stream",
                                        model: model,
                                        backend: "openai",
                                        apiVariant: .responses
                                    )
                                    continuation.finish(throwing: error)
                                }
                            } else {
                                logTerminalError(
                                    error,
                                    operation: "stream",
                                    model: model,
                                    backend: "openai",
                                    apiVariant: settings.apiVariant
                                )
                                continuation.finish(throwing: error)
                            }
                        }
                    
                    case .openAIOAuth(let settings):
                        let resolvedModel = normalizeModelName(model, removing: "openai:")
                        let oauthModel = OpenAIOAuthModel(
                            baseURL: settings.baseURL,
                            bearerToken: settings.apiKey(),
                            model: resolvedModel,
                            apiVariant: .responses,
                            accountId: settings.accountId
                        )
                        
                        let session = LanguageModelSession(
                            model: oauthModel,
                            instructions: resolvedInstructions
                        )
                        let options = openAIGenerationOptions(maxTokens: maxTokens, reasoningEffort: reasoningEffort)
                        
                        let stream = session.streamResponse(to: Prompt(prompt), generating: String.self, options: options)
                        for try await snapshot in stream {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()

                    case .ollama(let settings):
                        let session = LanguageModelSession(
                            model: OllamaLanguageModel(
                                baseURL: settings.baseURL,
                                model: normalizeModelName(model, removing: "ollama:")
                            ),
                            instructions: resolvedInstructions
                        )
                        let options = GenerationOptions(maximumResponseTokens: maxTokens)
                        if #available(macOS 26.0, *) {
                            let stream = session.streamResponse(to: Prompt(prompt), options: options)
                            var aggregated = ""
                            for try await snapshot in stream {
                                let next = snapshot.content
                                if next.hasPrefix(aggregated) {
                                    aggregated = next
                                } else {
                                    aggregated += next
                                }
                                continuation.yield(aggregated)
                            }
                        } else {
                            let completion = try await complete(
                                model: model,
                                prompt: prompt,
                                maxTokens: maxTokens,
                                reasoningEffort: reasoningEffort
                            )
                            try await yieldSimulatedStream(from: completion, continuation: continuation)
                        }
                        continuation.finish()
                    }
                } catch {
                    logTerminalError(
                        error,
                        operation: "stream",
                        model: model,
                        backend: "runtime",
                        apiVariant: nil
                    )
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func completeOpenAI(
        settings: OpenAISettings,
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?,
        apiVariant: OpenAILanguageModel.APIVariant
    ) async throws -> String {
        let session = LanguageModelSession(
            model: OpenAILanguageModel(
                baseURL: settings.baseURL,
                apiKey: settings.apiKey(),
                model: model,
                apiVariant: apiVariant
            ),
            instructions: resolvedInstructions
        )
        let options = openAIGenerationOptions(maxTokens: maxTokens, reasoningEffort: reasoningEffort)
        let response: LanguageModelSession.Response<String> = try await session.respond(
            to: Prompt(prompt),
            generating: String.self,
            options: options
        )
        return response.content
    }

    private func streamOpenAI(
        settings: OpenAISettings,
        model: String,
        prompt: String,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort?,
        apiVariant: OpenAILanguageModel.APIVariant,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(
                model: OpenAILanguageModel(
                    baseURL: settings.baseURL,
                    apiKey: settings.apiKey(),
                    model: model,
                    apiVariant: apiVariant
                ),
                instructions: resolvedInstructions
            )
            let options = openAIGenerationOptions(maxTokens: maxTokens, reasoningEffort: reasoningEffort)
            let stream = session.streamResponse(to: Prompt(prompt), options: options)
            var aggregated = ""
            for try await snapshot in stream {
                let next = snapshot.content
                if next.hasPrefix(aggregated) {
                    aggregated = next
                } else {
                    aggregated += next
                }
                continuation.yield(aggregated)
            }
            return
        }

        let completion = try await completeOpenAI(
            settings: settings,
            model: model,
            prompt: prompt,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            apiVariant: apiVariant
        )
        try await yieldSimulatedStream(from: completion, continuation: continuation)
    }

    private func openAIGenerationOptions(maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions {
        var options = GenerationOptions(maximumResponseTokens: maxTokens)
        guard let reasoningEffort = mapReasoningEffort(reasoningEffort) else {
            return options
        }

        options[custom: OpenAILanguageModel.self] = .init(
            reasoningEffort: reasoningEffort,
            reasoning: .init(effort: reasoningEffort)
        )
        return options
    }

    private func mapReasoningEffort(
        _ effort: ReasoningEffort?
    ) -> OpenAILanguageModel.CustomGenerationOptions.ReasoningEffort? {
        switch effort {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case nil:
            return nil
        }
    }

    private func shouldRetryOpenAIWithResponses(
        error: any Error,
        currentVariant: OpenAILanguageModel.APIVariant
    ) -> Bool {
        guard currentVariant == .chatCompletions else {
            return false
        }
        let text = String(describing: error).lowercased()
        if text.contains("not a chat model") {
            return true
        }
        if text.contains("v1/chat/completions") && text.contains("did you mean to use v1/completions") {
            return true
        }
        return false
    }

    private func yieldSimulatedStream(
        from text: String,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.isEmpty {
            continuation.yield("")
            return
        }

        var built = ""
        for token in normalized.split(separator: " ", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            if built.isEmpty {
                built = String(token)
            } else {
                built += " \(token)"
            }
            continuation.yield(built)
            try await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    /// Default instruction fallback when config does not provide system instructions.
    private var resolvedInstructions: String {
        if let systemInstructions, !systemInstructions.isEmpty {
            return systemInstructions
        }
        return "You are an execution-focused assistant for Sloppy agents."
    }

    private enum Backend {
        case openAI(OpenAISettings)
        case openAIOAuth(OpenAISettings)
        case ollama(OllamaSettings)
    }

    /// Detects if token is an OAuth token (not an API key)
    internal func isOAuthToken(_ token: String) -> Bool {
        // OAuth tokens do not start with 'sk-' (OpenAI API keys)
        return !token.hasPrefix("sk-") && !token.isEmpty
    }

    /// Resolves backend by model prefix (`openai:` / `ollama:`) and validates configuration.
    private func backend(for model: String) throws -> Backend {
        if model.hasPrefix("openai:") {
            guard let openAI else {
                throw PluginError.missingConfiguration("openai")
            }
            let token = openAI.apiKey()
            if isOAuthToken(token) {
                return .openAIOAuth(openAI)
            } else {
                return .openAI(openAI)
            }
        }

        if model.hasPrefix("ollama:") {
            guard let ollama else {
                throw PluginError.missingConfiguration("ollama")
            }
            return .ollama(ollama)
        }

        if let openAI {
            let token = openAI.apiKey()
            if isOAuthToken(token) {
                return .openAIOAuth(openAI)
            } else {
                return .openAI(openAI)
            }
        }

        if let ollama {
            return .ollama(ollama)
        }

        throw PluginError.unsupportedModel(model)
    }

    /// Removes provider prefix before passing model id to backend SDK.
    private func normalizeModelName(_ model: String, removing prefix: String) -> String {
        if model.hasPrefix(prefix) {
            return String(model.dropFirst(prefix.count))
        }
        return model
    }

    private func logRetry(
        operation: String,
        model: String,
        fromVariant: OpenAILanguageModel.APIVariant,
        error: any Error
    ) {
        let serializedError = String(describing: error)
        Self.logger.warning(
            "anylm.retry_openai_with_responses operation=\(operation) model=\(model) from_variant=\(String(describing: fromVariant)) error=\(serializedError)"
        )
    }

    private func logTerminalError(
        _ error: any Error,
        operation: String,
        model: String,
        backend: String,
        apiVariant: OpenAILanguageModel.APIVariant?
    ) {
        let serializedError = String(describing: error)
        let variant = apiVariant.map { String(describing: $0) } ?? "n/a"
        if error is CancellationError {
            Self.logger.debug(
                "anylm.cancelled operation=\(operation) model=\(model) backend=\(backend) variant=\(variant) error=\(serializedError)"
            )
            return
        }

        Self.logger.error(
            "anylm.failed operation=\(operation) model=\(model) backend=\(backend) variant=\(variant) error=\(serializedError)"
        )
    }
}

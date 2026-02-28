import AnyLanguageModel
import Foundation

/// Bridges SlopOverlord `ModelProviderPlugin` protocol to AnyLanguageModel backends.
public struct AnyLanguageModelProviderPlugin: ModelProviderPlugin {
    /// OpenAI-compatible backend settings.
    public struct OpenAISettings: Sendable {
        public var apiKey: @Sendable () -> String
        public var baseURL: URL
        public var apiVariant: OpenAILanguageModel.APIVariant

        public init(
            apiKey: @escaping @Sendable () -> String,
            baseURL: URL = OpenAILanguageModel.defaultBaseURL,
            apiVariant: OpenAILanguageModel.APIVariant = .chatCompletions
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.apiVariant = apiVariant
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
    public func complete(model: String, prompt: String, maxTokens: Int) async throws -> String {
        switch try backend(for: model) {
        case .openAI(let settings):
            let session = LanguageModelSession(
                model: OpenAILanguageModel(
                    baseURL: settings.baseURL,
                    apiKey: settings.apiKey(),
                    model: normalizeModelName(model, removing: "openai:"),
                    apiVariant: settings.apiVariant
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

        case .ollama(let settings):
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
        }
    }

    /// Streams single-turn completion snapshots, yielding progressively built text.
    public func stream(model: String, prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch try backend(for: model) {
                    case .openAI(let settings):
                        let session = LanguageModelSession(
                            model: OpenAILanguageModel(
                                baseURL: settings.baseURL,
                                apiKey: settings.apiKey(),
                                model: normalizeModelName(model, removing: "openai:"),
                                apiVariant: settings.apiVariant
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
                            let completion = try await complete(model: model, prompt: prompt, maxTokens: maxTokens)
                            try await yieldSimulatedStream(from: completion, continuation: continuation)
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
                            let completion = try await complete(model: model, prompt: prompt, maxTokens: maxTokens)
                            try await yieldSimulatedStream(from: completion, continuation: continuation)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
        return "You are an execution-focused assistant for SlopOverlord agents."
    }

    private enum Backend {
        case openAI(OpenAISettings)
        case ollama(OllamaSettings)
    }

    /// Resolves backend by model prefix (`openai:` / `ollama:`) and validates configuration.
    private func backend(for model: String) throws -> Backend {
        if model.hasPrefix("openai:") {
            guard let openAI else {
                throw PluginError.missingConfiguration("openai")
            }
            return .openAI(openAI)
        }

        if model.hasPrefix("ollama:") {
            guard let ollama else {
                throw PluginError.missingConfiguration("ollama")
            }
            return .ollama(ollama)
        }

        if let openAI {
            return .openAI(openAI)
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
}

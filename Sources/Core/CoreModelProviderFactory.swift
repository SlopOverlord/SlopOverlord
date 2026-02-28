import Foundation
import PluginSDK

enum CoreModelProviderFactory {
    static func buildModelProvider(
        config: CoreConfig,
        resolvedModels: [String]
    ) -> AnyLanguageModelProviderPlugin? {
        let supportsOpenAI = resolvedModels.contains { $0.hasPrefix("openai:") }
        let supportsOllama = resolvedModels.contains { $0.hasPrefix("ollama:") }

        let primaryOpenAIConfig = config.models.first {
            resolvedIdentifier(for: $0).hasPrefix("openai:")
        }
        let primaryOllamaConfig = config.models.first {
            resolvedIdentifier(for: $0).hasPrefix("ollama:")
        }

        var openAISettings: AnyLanguageModelProviderPlugin.OpenAISettings?
        if supportsOpenAI {
            let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
            let configuredKey = primaryOpenAIConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedKey = configuredKey.isEmpty ? apiKey : configuredKey

            if !resolvedKey.isEmpty {
                if let baseURL = parseURL(primaryOpenAIConfig?.apiUrl) {
                    openAISettings = .init(apiKey: { resolvedKey }, baseURL: baseURL)
                } else {
                    openAISettings = .init(apiKey: { resolvedKey })
                }
            }
        }

        let ollamaSettings: AnyLanguageModelProviderPlugin.OllamaSettings? = {
            guard supportsOllama else {
                return nil
            }
            if let baseURL = parseURL(primaryOllamaConfig?.apiUrl) {
                return .init(baseURL: baseURL)
            }
            return .init()
        }()

        let availableModels = resolvedModels.filter { model in
            if model.hasPrefix("openai:") {
                return openAISettings != nil
            }
            if model.hasPrefix("ollama:") {
                return ollamaSettings != nil
            }
            return openAISettings != nil || ollamaSettings != nil
        }

        guard !availableModels.isEmpty else {
            return nil
        }

        return AnyLanguageModelProviderPlugin(
            id: "any-language-model",
            models: availableModels,
            openAI: openAISettings,
            ollama: ollamaSettings,
            systemInstructions: "You are SlopOverlord core channel assistant."
        )
    }

    static func resolveModelIdentifiers(config: CoreConfig) -> [String] {
        var identifiers = config.models.map(resolvedIdentifier(for:))
        let hasOpenAI = identifiers.contains { $0.hasPrefix("openai:") }
        let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !hasOpenAI, !environmentKey.isEmpty {
            identifiers.append("openai:gpt-4.1-mini")
        }

        return identifiers
    }

    static func resolvedIdentifier(for model: CoreConfig.ModelConfig) -> String {
        let modelValue = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelValue.hasPrefix("openai:") || modelValue.hasPrefix("ollama:") {
            return modelValue
        }

        let provider = inferredProvider(model: model)
        if let provider {
            return "\(provider):\(modelValue)"
        }

        return modelValue
    }

    private static func inferredProvider(model: CoreConfig.ModelConfig) -> String? {
        let title = model.title.lowercased()
        let apiURL = model.apiUrl.lowercased()

        if title.contains("openai") || apiURL.contains("openai") {
            return "openai"
        }

        if title.contains("ollama") || apiURL.contains("ollama") || apiURL.contains("11434") {
            return "ollama"
        }

        return nil
    }

    static func parseURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }
}

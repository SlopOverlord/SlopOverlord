import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols

struct OpenAIProviderCatalogService {
    private struct OpenAIModelsResponse: Decodable {
        struct ModelItem: Decodable {
            let id: String
        }

        let data: [ModelItem]
    }

    private static let fallbackOpenAIModels: [ProviderModelOption] = [
        .init(id: "gpt-4.1", title: "GPT-4.1", contextWindow: "1.0M", capabilities: ["tools"]),
        .init(id: "gpt-4.1-mini", title: "GPT-4.1 mini", contextWindow: "1.0M", capabilities: ["tools"]),
        .init(id: "gpt-4.1-nano", title: "GPT-4.1 nano", contextWindow: "1.0M", capabilities: ["tools"]),
        .init(id: "gpt-4o", title: "GPT-4o", contextWindow: "128K", capabilities: ["tools"]),
        .init(id: "gpt-4o-mini", title: "GPT-4o mini", contextWindow: "128K", capabilities: ["tools"]),
        .init(id: "o4-mini", title: "o4-mini", contextWindow: "200K", capabilities: ["reasoning", "tools"])
    ]

    func listModels(config: CoreConfig, request: OpenAIProviderModelsRequest) async -> OpenAIProviderModelsResponse {
        let primaryOpenAIConfig = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0).hasPrefix("openai:")
        }

        let configuredURL = primaryOpenAIConfig?.apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedURL = request.apiUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = CoreModelProviderFactory.parseURL(requestedURL)
            ?? CoreModelProviderFactory.parseURL(configuredURL)
            ?? URL(string: "https://api.openai.com/v1")

        let configuredKey = primaryOpenAIConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var usedEnvironmentKey = false
        let resolvedKey: String? = {
            switch request.authMethod {
            case .apiKey:
                if !requestKey.isEmpty {
                    return requestKey
                }
                if !configuredKey.isEmpty {
                    return configuredKey
                }
                if !envKey.isEmpty {
                    usedEnvironmentKey = true
                    return envKey
                }
                return nil
            case .deeplink:
                if !envKey.isEmpty {
                    usedEnvironmentKey = true
                    return envKey
                }
                return nil
            }
        }()

        guard let apiKey = resolvedKey, !apiKey.isEmpty, let baseURL else {
            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "fallback",
                warning: "OpenAI API key is missing. Provide API key or set OPENAI_API_KEY.",
                models: Self.fallbackOpenAIModels
            )
        }

        do {
            let models = try await fetchOpenAIModels(apiKey: apiKey, baseURL: baseURL)
            if models.isEmpty {
                return OpenAIProviderModelsResponse(
                    provider: "openai",
                    authMethod: request.authMethod,
                    usedEnvironmentKey: usedEnvironmentKey,
                    source: "fallback",
                    warning: "Provider returned empty model list.",
                    models: Self.fallbackOpenAIModels
                )
            }

            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "remote",
                warning: nil,
                models: models
            )
        } catch {
            return OpenAIProviderModelsResponse(
                provider: "openai",
                authMethod: request.authMethod,
                usedEnvironmentKey: usedEnvironmentKey,
                source: "fallback",
                warning: "Failed to fetch OpenAI models: \(error.localizedDescription)",
                models: Self.fallbackOpenAIModels
            )
        }
    }

    func status(config: CoreConfig) -> OpenAIProviderStatusResponse {
        let primaryOpenAIConfig = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0).hasPrefix("openai:")
        }

        let configuredKey = primaryOpenAIConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasConfiguredKey = !configuredKey.isEmpty
        let hasEnvironmentKey = !envKey.isEmpty

        return OpenAIProviderStatusResponse(
            provider: "openai",
            hasEnvironmentKey: hasEnvironmentKey,
            hasConfiguredKey: hasConfiguredKey,
            hasAnyKey: hasConfiguredKey || hasEnvironmentKey
        )
    }

    private func fetchOpenAIModels(apiKey: String, baseURL: URL) async throws -> [ProviderModelOption] {
        let endpoint = openAIModelsURL(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted()
            .map(Self.enrichedOpenAIModelOption)
    }

    private func openAIModelsURL(baseURL: URL) -> URL {
        if baseURL.path.isEmpty || baseURL.path == "/" {
            return baseURL.appendingPathComponent("models")
        }

        let normalizedPath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        if normalizedPath.hasSuffix("/models") {
            return baseURL
        }

        return baseURL.appendingPathComponent("models")
    }

    private static func enrichedOpenAIModelOption(id: String) -> ProviderModelOption {
        let lowered = id.lowercased()
        let title = humanReadableOpenAIModelTitle(id: id)
        var contextWindow: String?
        var capabilities: [String] = []

        if lowered.hasPrefix("gpt-4.1") {
            contextWindow = "1.0M"
            capabilities.append("tools")
        } else if lowered.hasPrefix("gpt-4o") {
            contextWindow = "128K"
            capabilities.append("tools")
        } else if lowered.hasPrefix("o4") || lowered.hasPrefix("o3") {
            contextWindow = "200K"
            capabilities.append(contentsOf: ["reasoning", "tools"])
        } else if lowered.hasPrefix("o1") {
            contextWindow = "128K"
            capabilities.append(contentsOf: ["reasoning", "tools"])
        }

        return ProviderModelOption(
            id: id,
            title: title,
            contextWindow: contextWindow,
            capabilities: capabilities
        )
    }

    private static func humanReadableOpenAIModelTitle(id: String) -> String {
        let lower = id.lowercased()
        if lower.hasPrefix("gpt-4.1") {
            let suffix = lower.replacingOccurrences(of: "gpt-4.1", with: "")
            return "GPT-4.1" + titleSuffix(from: suffix)
        }
        if lower.hasPrefix("gpt-4o") {
            let suffix = lower.replacingOccurrences(of: "gpt-4o", with: "")
            return "GPT-4o" + titleSuffix(from: suffix)
        }
        return id
    }

    private static func titleSuffix(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        guard !trimmed.isEmpty else {
            return ""
        }

        let parts = trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.capitalized }
        guard !parts.isEmpty else {
            return ""
        }
        return " " + parts.joined(separator: " ")
    }
}

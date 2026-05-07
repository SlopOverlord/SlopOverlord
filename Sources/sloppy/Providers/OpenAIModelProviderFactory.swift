import AnyLanguageModel
import Foundation
import PluginSDK

/// OpenAI model provider factory.
struct OpenAIModelProviderFactory: ModelProviderFactory {
    func buildProvider(from config: ModelProviderBuildConfig) -> (any ModelProvider)? {
        let openAIModels = config.resolvedModels.filter { $0.hasPrefix("openai:") }
        guard !openAIModels.isEmpty else { return nil }

        let primaryConfig = config.coreConfig.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("openai:") == true
        }
        let primaryIsOAuth = primaryConfig.map(isOpenAIOAuthEntry) ?? false

        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        let configuredKey = (primaryConfig?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedStaticKey = primaryIsOAuth ? "" : (configuredKey.isEmpty ? apiKey : configuredKey)

        let parsedPrimaryURL = CoreModelProviderFactory.parseURL(primaryConfig?.apiUrl)
        let allowKeylessLAN = parsedPrimaryURL.map { OpenAICompatibleCatalogEndpoint.hostAllowsKeylessOpenAIProbe(host: $0.host) } ?? false

        let keyProvider: (@Sendable () -> String)?
        let isOAuth: Bool
        if primaryIsOAuth {
            if let oauthProvider = config.oauthTokenProvider, oauthProvider() != nil {
                keyProvider = { config.oauthTokenProvider?() ?? "" }
                isOAuth = true
            } else if !configuredKey.isEmpty {
                keyProvider = { configuredKey }
                isOAuth = true
            } else {
                return nil
            }
        } else if !resolvedStaticKey.isEmpty {
            keyProvider = { resolvedStaticKey }
            isOAuth = false
        } else if allowKeylessLAN {
            keyProvider = { "" }
            isOAuth = false
        } else if let oauthProvider = config.oauthTokenProvider, oauthProvider() != nil {
            keyProvider = { config.oauthTokenProvider?() ?? "" }
            isOAuth = true
        } else {
            return nil
        }

        guard let keyProvider else { return nil }

        let resolvedAccountId = isOAuth ? config.oauthAccountId : nil
        let resolvedRefresh = isOAuth ? config.oauthTokenRefresh : nil
        let resolvedForceRefresh = isOAuth ? config.oauthTokenForceRefresh : nil

        let baseURL = CoreModelProviderFactory.parseURL(primaryConfig?.apiUrl)
            ?? OpenAILanguageModel.defaultBaseURL

        let settings = OpenAIModelProvider.Settings(
            apiKey: keyProvider,
            baseURL: baseURL,
            accountId: resolvedAccountId,
            refreshTokenIfNeeded: resolvedRefresh,
            refreshTokenAfterInvalidToken: resolvedForceRefresh,
            session: config.proxySession
        )

        return OpenAIModelProvider(
            supportedModels: openAIModels,
            settings: settings,
            tools: config.tools,
            systemInstructions: config.systemInstructions
        )
    }

    private func isOpenAIOAuthEntry(_ model: CoreConfig.ModelConfig) -> Bool {
        let catalog = model.providerCatalogId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if catalog == "openai-oauth" {
            return true
        }
        let title = model.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.contains("oauth") || title.contains("deeplink")
    }
}

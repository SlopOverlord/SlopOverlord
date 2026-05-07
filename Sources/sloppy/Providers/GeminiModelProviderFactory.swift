import AnyLanguageModel
import Foundation
import PluginSDK

struct GeminiModelProviderFactory: ModelProviderFactory {
    func buildProvider(from config: ModelProviderBuildConfig) -> (any ModelProvider)? {
        let geminiModels = config.resolvedModels.filter { $0.hasPrefix("gemini:") }
        guard !geminiModels.isEmpty else { return nil }

        let primaryConfig = config.coreConfig.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("gemini:") == true
        }

        let baseURL = CoreModelProviderFactory.parseURL(primaryConfig?.apiUrl)
            ?? GeminiLanguageModel.defaultBaseURL

        let configuredKey = (primaryConfig?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let envKey = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            .compactMap { ProcessInfo.processInfo.environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let resolvedKey = configuredKey.isEmpty ? envKey : configuredKey
        if !resolvedKey.isEmpty {
            return GeminiModelProvider(
                supportedModels: geminiModels,
                apiKey: { resolvedKey },
                baseURL: baseURL,
                tools: config.tools,
                systemInstructions: config.systemInstructions,
                session: config.proxySession
            )
        }

        if let oauthCredentials = config.geminiOAuthCredentialsProvider?() {
            let tokenBox = GeminiOAuthTokenBox(credentials: oauthCredentials)
            return GeminiModelProvider(
                supportedModels: geminiModels,
                apiKey: { tokenBox.accessToken() },
                refreshTokenIfNeeded: {
                    guard tokenBox.credentials().isUsableForGenerativeLanguageAPI else {
                        throw GeminiOAuthCredentialsError.missingRequiredScope(
                            currentScopes: tokenBox.credentials().generativeLanguageScopeDescription
                        )
                    }
                    let refreshed = try await tokenBox.credentials().refreshedIfNeeded()
                    guard refreshed.isUsableForGenerativeLanguageAPI else {
                        throw GeminiOAuthCredentialsError.missingRequiredScope(
                            currentScopes: refreshed.generativeLanguageScopeDescription
                        )
                    }
                    tokenBox.update(refreshed)
                },
                baseURL: baseURL,
                tools: config.tools,
                systemInstructions: config.systemInstructions,
                session: ProxySessionFactory.makeSession(
                    proxy: config.coreConfig.proxy,
                    protocolClasses: [GeminiOAuthURLProtocol.self]
                )
            )
        }

        return nil
    }
}

private final class GeminiOAuthTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GeminiOAuthCredentials

    init(credentials: GeminiOAuthCredentials) {
        self.value = credentials
    }

    func credentials() -> GeminiOAuthCredentials {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func accessToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value.accessToken
    }

    func update(_ credentials: GeminiOAuthCredentials) {
        lock.lock()
        value = credentials
        lock.unlock()
    }
}

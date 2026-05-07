import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PluginSDK
@testable import Protocols
@testable import sloppy

private final class OAuthTokenBox: @unchecked Sendable {
    var token: String
    var refreshCount = 0

    init(token: String) {
        self.token = token
    }
}

@Test
func coreModelProviderFactoryAcceptsOpenRouterPrefixedModel() {
    let model = CoreConfig.ModelConfig(
        title: "openrouter-main",
        apiKey: "",
        apiUrl: "",
        model: "openrouter:anthropic/claude-3.5-sonnet"
    )
    #expect(CoreModelProviderFactory.resolvedIdentifier(for: model) == "openrouter:anthropic/claude-3.5-sonnet")
}

@Test
func coreModelProviderFactoryInfersOpenRouterFromApiHost() {
    let model = CoreConfig.ModelConfig(
        title: "edge",
        apiKey: "sk-or-test",
        apiUrl: "https://openrouter.ai/api/v1",
        model: "openai/gpt-4o-mini"
    )
    #expect(CoreModelProviderFactory.resolvedIdentifier(for: model) == "openrouter:openai/gpt-4o-mini")
}

@Test
func geminiOAuthCredentialsLoadReadsGeminiCLIFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemini-oauth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("oauth_creds.json")
    try Data(
        """
        {
          "access_token": "oauth-token",
          "refresh_token": "refresh-token",
          "token_type": "Bearer",
          "expiry_date": 1893456000000
        }
        """.utf8
    ).write(to: url)

    let credentials = try #require(GeminiOAuthCredentials.load(url: url))
    #expect(credentials.accessToken == "oauth-token")
    #expect(credentials.refreshToken == "refresh-token")
    #expect(credentials.authorizationHeaderValue == "Bearer oauth-token")
}

@Test
func geminiOAuthCredentialsLoadAcceptsRefreshTokenOnlyCLIFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemini-oauth-refresh-only-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("oauth_creds.json")
    try Data(
        """
        {
          "access_token": "",
          "scope": "https://www.googleapis.com/auth/cloud-platform",
          "token_type": "Bearer",
          "id_token": "",
          "expiry_date": 1778105904231,
          "refresh_token": "refresh-token"
        }
        """.utf8
    ).write(to: url)

    let credentials = try #require(GeminiOAuthCredentials.load(url: url))
    #expect(credentials.accessToken == "")
    #expect(credentials.refreshToken == "refresh-token")
    #expect(credentials.scope == "https://www.googleapis.com/auth/cloud-platform")
    #expect(credentials.isUsableForGenerativeLanguageAPI == false)
}

@Test
func geminiOAuthCredentialsRefreshesExpiredCLIFile() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemini-oauth-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("oauth_creds.json")
    try Data(
        """
        {
          "access_token": "expired-token",
          "scope": "https://www.googleapis.com/auth/cloud-platform",
          "token_type": "Bearer",
          "expiry_date": 946684800000,
          "refresh_token": "refresh-token"
        }
        """.utf8
    ).write(to: url)

    let bodyBox = OAuthTokenBox(token: "")
    let credentials = try #require(GeminiOAuthCredentials.load(url: url))
    let refreshed = try await credentials.refreshedIfNeeded(
        url: url,
        now: Date(timeIntervalSince1970: 1_800_000_000),
        transport: { request in
            bodyBox.token = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                """
                {
                  "access_token": "fresh-token",
                  "expires_in": 3600,
                  "token_type": "Bearer",
                  "scope": "https://www.googleapis.com/auth/cloud-platform"
                }
                """.utf8
            )
            return (data, response)
        }
    )

    #expect(bodyBox.token.contains("grant_type=refresh_token"))
    #expect(bodyBox.token.contains("refresh_token=refresh-token"))
    #expect(refreshed.accessToken == "fresh-token")
    #expect(refreshed.refreshToken == "refresh-token")
    let stored = try #require(GeminiOAuthCredentials.load(url: url))
    #expect(stored.accessToken == "fresh-token")
    #expect(stored.refreshToken == "refresh-token")
}

@Test
func coreModelProviderFactoryBuildsGeminiFromOAuthCredentialsWithoutAPIKey() {
    var config = CoreConfig.test
    config.models = [
        CoreConfig.ModelConfig(
            title: "gemini",
            apiKey: "",
            apiUrl: "https://generativelanguage.googleapis.com",
            model: "gemini-2.5-flash",
            providerCatalogId: "gemini"
        )
    ]
    let provider = CoreModelProviderFactory.buildModelProvider(
        config: config,
        resolvedModels: ["gemini:gemini-2.5-flash"],
        geminiOAuthCredentialsProvider: {
            GeminiOAuthCredentials(
                accessToken: "oauth-token",
                refreshToken: nil,
                tokenType: "Bearer",
                expiryDate: nil
            )
        }
    )

    #expect(provider?.supportedModels == ["gemini:gemini-2.5-flash"])
}

@Test
func coreModelProviderFactorySurfacesGeminiOAuthCredentialsWithoutRequiredScope() async throws {
    var config = CoreConfig.test
    config.models = [
        CoreConfig.ModelConfig(
            title: "gemini",
            apiKey: "",
            apiUrl: "https://generativelanguage.googleapis.com",
            model: "gemini-2.5-flash",
            providerCatalogId: "gemini"
        )
    ]
    let provider = CoreModelProviderFactory.buildModelProvider(
        config: config,
        resolvedModels: ["gemini:gemini-2.5-flash"],
        geminiOAuthCredentialsProvider: {
            GeminiOAuthCredentials(
                accessToken: "oauth-token",
                refreshToken: nil,
                tokenType: "Bearer",
                expiryDate: nil,
                scope: "https://www.googleapis.com/auth/cloud-platform"
            )
        }
    )

    let geminiProvider = try #require(provider)
    #expect(geminiProvider.supportedModels == ["gemini:gemini-2.5-flash"])
    do {
        _ = try await geminiProvider.createLanguageModel(for: "gemini:gemini-2.5-flash")
        Issue.record("Expected Gemini OAuth scope validation to fail.")
    } catch let error as GeminiOAuthCredentialsError {
        #expect(error.localizedDescription.contains(GeminiOAuthCredentials.requiredGenerativeLanguageScope))
    }
}

@Test
func coreModelProviderFactoryAllowsGeminiConfiguredKeyWhenOAuthScopeIsMissing() {
    var config = CoreConfig.test
    config.models = [
        CoreConfig.ModelConfig(
            title: "gemini",
            apiKey: "configured-key",
            apiUrl: "https://generativelanguage.googleapis.com",
            model: "gemini-2.5-flash",
            providerCatalogId: "gemini"
        )
    ]
    let provider = CoreModelProviderFactory.buildModelProvider(
        config: config,
        resolvedModels: ["gemini:gemini-2.5-flash"],
        geminiOAuthCredentialsProvider: {
            GeminiOAuthCredentials(
                accessToken: "oauth-token",
                refreshToken: nil,
                tokenType: "Bearer",
                expiryDate: nil,
                scope: "https://www.googleapis.com/auth/cloud-platform"
            )
        }
    )

    #expect(provider?.supportedModels == ["gemini:gemini-2.5-flash"])
}

@Test
func openAIModelProviderUsesDynamicOAuthTokenWhenCodexSessionIsCached() async throws {
    let box = OAuthTokenBox(token: "stale-oauth-token")
    let provider = OpenAIModelProvider(
        supportedModels: ["openai:gpt-5-codex-mini"],
        settings: .init(
            apiKey: { box.token },
            refreshTokenIfNeeded: {
                box.refreshCount += 1
                box.token = "fresh-oauth-token"
            }
        )
    )

    let languageModel = try await provider.createLanguageModel(for: "openai:gpt-5-codex-mini")
    let oauthModel = try #require(languageModel as? OpenAIOAuthModel)
    let request = try await oauthModel.buildHTTPRequestForTesting(body: Data())

    #expect(box.refreshCount == 1)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-oauth-token")
}

@Test
func openAIOAuthConfigPrefersOAuthTokenProviderOverAPIKey() async throws {
    var config = CoreConfig.test
    config.models = [
        CoreConfig.ModelConfig(
            title: "openai-oauth",
            apiKey: "sk-proj-static-key",
            apiUrl: "https://chatgpt.com/backend-api",
            model: "gpt-5.4",
            providerCatalogId: "openai-oauth"
        )
    ]

    let builtProvider = CoreModelProviderFactory.buildModelProvider(
        config: config,
        resolvedModels: ["openai:gpt-5.4"],
        oauthTokenProvider: { "oauth-access-token" },
        oauthAccountId: "acct_test"
    )
    let provider = try #require(builtProvider)
    let languageModel = try await provider.createLanguageModel(for: "openai:gpt-5.4")
    let oauthModel = try #require(languageModel as? OpenAIOAuthModel)
    let request = try await oauthModel.buildHTTPRequestForTesting(body: Data())

    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-access-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct_test")
}

@Test
func availableAgentModelsIncludesCachedOpenAIOAuthCatalog() async throws {
    var config = CoreConfig.test
    config.models = []
    config.disableModelInference = false

    let workspaceRootURL = config.resolvedWorkspaceRootURL(
        currentDirectory: FileManager.default.currentDirectoryPath
    )
    let authDirectoryURL = workspaceRootURL.appendingPathComponent("auth", isDirectory: true)
    try FileManager.default.createDirectory(at: authDirectoryURL, withIntermediateDirectories: true)
    try Data(
        """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "oauth-token",
            "account_id": "acct_test"
          },
          "last_refresh": "2026-05-07T00:00:00Z"
        }
        """.utf8
    ).write(to: authDirectoryURL.appendingPathComponent("openai-oauth-auth.json"))

    let service = CoreService(
        config: config,
        persistenceBuilder: InMemoryCorePersistenceBuilder()
    )
    await service.cacheOAuthModels([
        ProviderModelOption(
            id: "gpt-5.5",
            title: "GPT-5.5",
            contextWindow: "272K",
            capabilities: ["tools"]
        )
    ])

    let models = await service.availableAgentModels()
    let cached = models.first { $0.id == "openai:gpt-5.5" }
    #expect(cached?.title == "GPT-5.5")
    #expect(cached?.contextWindow == "272K")
}

@Test
func geminiOAuthURLProtocolRewritesAPIKeyHeaderToBearerAuth() throws {
    var request = URLRequest(url: try #require(URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent")))
    request.setValue("oauth-token", forHTTPHeaderField: "x-goog-api-key")

    let modified = GeminiOAuthURLProtocol.modifiedRequest(from: request)

    #expect(modified.value(forHTTPHeaderField: "x-goog-api-key") == nil)
    #expect(modified.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
}

@Test
func sloppyExtraCertificateAuthorityExtractsMultiplePEMCertificates() {
    let first = Data([0x01, 0x02, 0x03]).base64EncodedString()
    let second = Data([0x04, 0x05, 0x06]).base64EncodedString()
    let pem =
        """
        -----BEGIN CERTIFICATE-----
        \(first)
        -----END CERTIFICATE-----
        -----BEGIN CERTIFICATE-----
        \(second)
        -----END CERTIFICATE-----
        """

    let certificates = SloppyExtraCertificateAuthority.certificateData(fromPEM: pem)

    #expect(certificates == [Data([0x01, 0x02, 0x03]), Data([0x04, 0x05, 0x06])])
}

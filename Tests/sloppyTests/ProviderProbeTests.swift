import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import sloppy
@testable import Protocols

private func makeProbeHTTPResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
}

@Test
func providerProbeEndpointReturnsFailureWhenOpenAIKeyIsMissing() async throws {
    let config = CoreConfig.test
    let service = CoreService(
        config: config,
        providerProbeService: ProviderProbeService(
            environmentLookup: { _ in nil },
            transport: { request in
                Issue.record("Transport should not be used when OpenAI key is missing.")
                return (Data(), makeProbeHTTPResponse(url: request.url!))
            }
        ),
        builtInGatewayPluginFactory: .live
    )
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(
        ProviderProbeRequest(
            providerId: .openAIAPI,
            apiUrl: "https://api.openai.com/v1"
        )
    )
    let response = await router.handle(method: "POST", path: "/v1/providers/probe", body: body)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(ProviderProbeResponse.self, from: response.body)
    #expect(payload.providerId == ProviderProbeID.openAIAPI)
    #expect(payload.ok == false)
    #expect(payload.models.isEmpty)
}

@Test
func providerProbeEndpointReturnsFriendlyFailureWhenOAuthIsNotConnected() async throws {
    let config = CoreConfig.test
    let service = CoreService(
        config: config,
        builtInGatewayPluginFactory: .live
    )
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(
        ProviderProbeRequest(
            providerId: .openAIOAuth,
            apiUrl: "https://chatgpt.com/backend-api"
        )
    )
    let response = await router.handle(method: "POST", path: "/v1/providers/probe", body: body)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(ProviderProbeResponse.self, from: response.body)
    #expect(payload.providerId == ProviderProbeID.openAIOAuth)
    #expect(payload.ok == false)
    #expect(payload.models.isEmpty)
    #expect(payload.message == "Failed to connect to OpenAI OAuth: OpenAI OAuth is not connected yet. Start sign-in first.")
}

@Test
func providerProbeEndpointMapsOllamaModelsFromTagsResponse() async throws {
    let config = CoreConfig.test
    let service = CoreService(
        config: config,
        providerProbeService: ProviderProbeService(
            transport: { request in
                let payload =
                    """
                    {
                      "models": [
                        { "name": "qwen3:latest" },
                        { "name": "llama3.2" }
                      ]
                    }
                    """
                return (Data(payload.utf8), makeProbeHTTPResponse(url: request.url!))
            }
        ),
        builtInGatewayPluginFactory: .live
    )
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(
        ProviderProbeRequest(
            providerId: .ollama,
            apiUrl: "http://127.0.0.1:11434"
        )
    )
    let response = await router.handle(method: "POST", path: "/v1/providers/probe", body: body)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(ProviderProbeResponse.self, from: response.body)
    #expect(payload.providerId == ProviderProbeID.ollama)
    #expect(payload.ok == true)
    #expect(payload.models.map { $0.id } == ["llama3.2", "qwen3:latest"])
    #expect(payload.models.map { $0.title } == ["llama3.2", "qwen3"])
}

@Test
func providerProbeEndpointRejectsInvalidProviderID() async throws {
    let router = CoreRouter(service: CoreService(config: .test))
    let body = Data(#"{"providerId":"invalid-provider"}"#.utf8)
    let response = await router.handle(method: "POST", path: "/v1/providers/probe", body: body)

    #expect(response.status == 400)
}

@Test
func providerProbeOpenAIListsModelsWithoutKeyOnPrivateLAN() async throws {
    let config = CoreConfig.test
    let service = CoreService(
        config: config,
        providerProbeService: ProviderProbeService(
            environmentLookup: { _ in nil },
            transport: { request in
                let path = request.url?.path ?? ""
                #expect(path.hasSuffix("/v1/models"))
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let payload = #"{"data":[{"id":"lm-studio-model"}]}"#
                return (Data(payload.utf8), makeProbeHTTPResponse(url: request.url!))
            }
        ),
        builtInGatewayPluginFactory: .live
    )
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(
        ProviderProbeRequest(
            providerId: .openAIAPI,
            apiUrl: "http://192.168.3.43:1234"
        )
    )
    let response = await router.handle(method: "POST", path: "/v1/providers/probe", body: body)

    #expect(response.status == 200)
    let payload = try JSONDecoder().decode(ProviderProbeResponse.self, from: response.body)
    #expect(payload.providerId == ProviderProbeID.openAIAPI)
    #expect(payload.ok == true)
    #expect(payload.models.map(\.id) == ["lm-studio-model"])
}

@Test
func providerProbeGeminiPrefersRequestAPIKeyOverOAuthCredentialsFile() async throws {
    let service = ProviderProbeService(
        environmentLookup: { key in
            key == "GEMINI_API_KEY" ? "env-api-key" : nil
        },
        transport: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.query?.contains("key=request-api-key") == true)
            let payload =
                """
                {
                  "models": [
                    { "name": "models/gemini-2.5-flash", "displayName": "Gemini 2.5 Flash" }
                  ]
                }
                """
            return (Data(payload.utf8), makeProbeHTTPResponse(url: request.url!))
        },
        geminiOAuthCredentialsProvider: {
            GeminiOAuthCredentials(
                accessToken: "oauth-access-token",
                refreshToken: nil,
                tokenType: "Bearer",
                expiryDate: nil,
                scope: "https://www.googleapis.com/auth/cloud-platform"
            )
        }
    )

    let response = await service.probe(
        config: .test,
        request: ProviderProbeRequest(
            providerId: .gemini,
            apiKey: "request-api-key",
            apiUrl: "https://generativelanguage.googleapis.com"
        )
    )

    #expect(response.ok == true)
    #expect(response.usedEnvironmentKey == false)
    #expect(response.message == "Connected to Gemini with API key. Loaded 1 models.")
    #expect(response.models.map(\.id) == ["gemini-2.5-flash"])
}

@Test
func providerProbeGeminiRejectsOAuthCredentialsWithoutGeminiScope() async throws {
    let service = ProviderProbeService(
        transport: { request in
            Issue.record("Unexpected Gemini probe request: \(request)")
            return (Data(), makeProbeHTTPResponse(url: request.url!, statusCode: 500))
        },
        geminiOAuthCredentialsProvider: {
            GeminiOAuthCredentials(
                accessToken: "oauth-access-token",
                refreshToken: nil,
                tokenType: "Bearer",
                expiryDate: nil,
                scope: "https://www.googleapis.com/auth/cloud-platform"
            )
        }
    )

    let response = await service.probe(
        config: .test,
        request: ProviderProbeRequest(
            providerId: .gemini,
            apiUrl: "https://generativelanguage.googleapis.com"
        )
    )

    #expect(response.ok == false)
    #expect(response.message.contains(GeminiOAuthCredentials.requiredGenerativeLanguageScope))
    #expect(response.models.isEmpty)
}

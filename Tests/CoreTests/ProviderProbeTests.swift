import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Core
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
    let service = CoreService(
        config: .default,
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
func providerProbeEndpointMapsOllamaModelsFromTagsResponse() async throws {
    let service = CoreService(
        config: .default,
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
    let router = CoreRouter(service: CoreService(config: .default))
    let body = Data(#"{"providerId":"invalid-provider"}"#.utf8)
    let response = await router.handle(method: "POST", path: "/v1/providers/probe", body: body)

    #expect(response.status == 400)
}

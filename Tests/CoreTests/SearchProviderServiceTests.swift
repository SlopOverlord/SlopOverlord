import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Core
@testable import Protocols

private final class HeaderRecorder: @unchecked Sendable {
    var value: String?
}

private func makeHTTPResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
}

private func makeSearchConfig(activeProvider: CoreConfig.SearchTools.ProviderID) -> CoreConfig.SearchTools {
    CoreConfig.SearchTools(
        activeProvider: activeProvider,
        providers: .init(
            brave: .init(apiKey: "brave-config-key"),
            perplexity: .init(apiKey: "pplx-config-key")
        )
    )
}

private func makeSearchService(
    config: CoreConfig.SearchTools,
    environment: [String: String] = [:],
    transport: SearchProviderService.Transport? = nil
) -> SearchProviderService {
    SearchProviderService(
        config: config,
        transport: transport,
        environmentLookup: { key in environment[key] }
    )
}

private func makeSearchTestHarness(
    config: CoreConfig,
    searchProviderService: SearchProviderService
) async throws -> (CoreRouter, String, String) {
    let service = CoreService(config: config, searchProviderService: searchProviderService)
    let router = CoreRouter(service: service)
    let agentID = "agent-search-\(UUID().uuidString)"
    let summary = try await service.createAgent(
        AgentCreateRequest(
            id: agentID,
            displayName: "Search Agent",
            role: "Exercises web.search"
        )
    )
    let session = try await service.createAgentSession(
        agentID: summary.id,
        request: AgentSessionCreateRequest(title: "Search Session")
    )
    return (router, summary.id, session.id)
}

@Test
func searchProviderStatusPrefersEnvironmentKeys() async throws {
    let service = makeSearchService(
        config: makeSearchConfig(activeProvider: .perplexity),
        environment: [
            "BRAVE_API_KEY": "brave-env-key",
            "PERPLEXITY_API_KEY": "pplx-env-key"
        ]
    )

    let status = await service.status()

    #expect(status.activeProvider == "perplexity")
    #expect(status.brave.hasEnvironmentKey == true)
    #expect(status.brave.hasConfiguredKey == true)
    #expect(status.brave.hasAnyKey == true)
    #expect(status.perplexity.hasEnvironmentKey == true)
    #expect(status.perplexity.hasConfiguredKey == true)
    #expect(status.perplexity.hasAnyKey == true)
}

@Test
func searchProviderStatusEndpointReturnsConfiguredProviders() async throws {
    let searchTools = makeSearchConfig(activeProvider: .brave)
    var config = CoreConfig.default
    config.searchTools = searchTools

    let router = CoreRouter(
        service: CoreService(
            config: config,
            searchProviderService: makeSearchService(config: searchTools)
        )
    )

    let response = await router.handle(method: "GET", path: "/v1/providers/search/status", body: nil)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(SearchToolsStatusResponse.self, from: response.body)
    #expect(payload.activeProvider == "brave")
    #expect(payload.brave.hasConfiguredKey == true)
    #expect(payload.perplexity.hasConfiguredKey == true)
}

@Test
func searchRequestsPreferEnvironmentKeyOverConfiguredKey() async throws {
    let braveConfig = makeSearchConfig(activeProvider: .brave)
    let braveHeader = HeaderRecorder()
    let braveService = makeSearchService(
        config: braveConfig,
        environment: ["BRAVE_API_KEY": "brave-env-key"],
        transport: { request, _, _ in
            braveHeader.value = request.value(forHTTPHeaderField: "X-Subscription-Token")
            let payload = #"{"web":{"results":[]}}"#
            return (Data(payload.utf8), makeHTTPResponse(url: request.url!))
        }
    )
    _ = try await braveService.search(query: "swift", count: 3, timeoutMs: 1_000, maxBytes: 32_768)
    #expect(braveHeader.value == "brave-env-key")

    let perplexityConfig = makeSearchConfig(activeProvider: .perplexity)
    let perplexityHeader = HeaderRecorder()
    let perplexityService = makeSearchService(
        config: perplexityConfig,
        environment: ["PERPLEXITY_API_KEY": "pplx-env-key"],
        transport: { request, _, _ in
            perplexityHeader.value = request.value(forHTTPHeaderField: "Authorization")
            let payload = #"{"results":[]}"#
            return (Data(payload.utf8), makeHTTPResponse(url: request.url!))
        }
    )
    _ = try await perplexityService.search(query: "swift", count: 3, timeoutMs: 1_000, maxBytes: 32_768)
    #expect(perplexityHeader.value == "Bearer pplx-env-key")
}

@Test
func invokeWebSearchRequiresQuery() async throws {
    var config = CoreConfig.default
    config.workspace = .init(name: "workspace-search-\(UUID().uuidString)", basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-search-\(UUID().uuidString).sqlite")
        .path
    config.searchTools = CoreConfig.SearchTools(activeProvider: .brave)

    let (router, agentID, sessionID) = try await makeSearchTestHarness(
        config: config,
        searchProviderService: makeSearchService(config: config.searchTools)
    )

    let body = try JSONEncoder().encode(ToolInvocationRequest(tool: "web.search"))
    let response = await router.handle(
        method: "POST",
        path: "/v1/agents/\(agentID)/sessions/\(sessionID)/tools/invoke",
        body: body
    )
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(ToolInvocationResult.self, from: response.body)
    #expect(payload.ok == false)
    #expect(payload.error?.code == "invalid_arguments")
}

@Test
func invokeWebSearchReturnsNotConfiguredWhenSelectedProviderHasNoKey() async throws {
    var config = CoreConfig.default
    config.workspace = .init(name: "workspace-search-\(UUID().uuidString)", basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-search-\(UUID().uuidString).sqlite")
        .path
    config.searchTools = .init(activeProvider: .perplexity)

    let (router, agentID, sessionID) = try await makeSearchTestHarness(
        config: config,
        searchProviderService: makeSearchService(config: config.searchTools)
    )

    let body = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "web.search",
            arguments: ["query": .string("latest swift release")]
        )
    )
    let response = await router.handle(
        method: "POST",
        path: "/v1/agents/\(agentID)/sessions/\(sessionID)/tools/invoke",
        body: body
    )
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(ToolInvocationResult.self, from: response.body)
    #expect(payload.ok == false)
    #expect(payload.error?.code == "not_configured")
}

@Test
func invokeWebSearchNormalizesBraveResults() async throws {
    let searchTools = makeSearchConfig(activeProvider: .brave)
    let transport: SearchProviderService.Transport = { request, _, _ in
        let payload =
            """
            {
              "web": {
                "results": [
                  {
                    "title": "Swift.org",
                    "url": "https://www.swift.org",
                    "description": "The Swift Programming Language",
                    "extra_snippets": ["Extra snippet"]
                  }
                ]
              }
            }
            """
        return (Data(payload.utf8), makeHTTPResponse(url: request.url!))
    }

    var config = CoreConfig.default
    config.workspace = .init(name: "workspace-search-\(UUID().uuidString)", basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-search-\(UUID().uuidString).sqlite")
        .path
    config.searchTools = searchTools

    let (router, agentID, sessionID) = try await makeSearchTestHarness(
        config: config,
        searchProviderService: makeSearchService(config: searchTools, transport: transport)
    )

    let body = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "web.search",
            arguments: [
                "query": .string("swift language"),
                "count": .number(7)
            ]
        )
    )
    let response = await router.handle(
        method: "POST",
        path: "/v1/agents/\(agentID)/sessions/\(sessionID)/tools/invoke",
        body: body
    )
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(ToolInvocationResult.self, from: response.body)
    let data = payload.data?.asObject
    #expect(payload.ok == true)
    #expect(data?["provider"]?.asString == "brave")
    #expect(data?["query"]?.asString == "swift language")
    #expect(data?["count"]?.asInt == 1)
    #expect(data?["results"]?.asArray?.first?.asObject?["title"]?.asString == "Swift.org")
    #expect(data?["results"]?.asArray?.first?.asObject?["snippet"]?.asString == "The Swift Programming Language")
    #expect(data?["citations"]?.asArray?.first?.asObject?["url"]?.asString == "https://www.swift.org")
}

@Test
func invokeWebSearchNormalizesPerplexityResults() async throws {
    let searchTools = makeSearchConfig(activeProvider: .perplexity)
    let transport: SearchProviderService.Transport = { request, _, _ in
        let payload =
            """
            {
              "results": [
                {
                  "title": "Swift Package Manager",
                  "url": "https://www.swift.org/package-manager/",
                  "snippet": "SPM is the package manager for Swift."
                }
              ]
            }
            """
        return (Data(payload.utf8), makeHTTPResponse(url: request.url!))
    }

    var config = CoreConfig.default
    config.workspace = .init(name: "workspace-search-\(UUID().uuidString)", basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-search-\(UUID().uuidString).sqlite")
        .path
    config.searchTools = searchTools

    let (router, agentID, sessionID) = try await makeSearchTestHarness(
        config: config,
        searchProviderService: makeSearchService(config: searchTools, transport: transport)
    )

    let body = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "web.search",
            arguments: [
                "query": .string("swift package manager"),
                "count": .number(3)
            ]
        )
    )
    let response = await router.handle(
        method: "POST",
        path: "/v1/agents/\(agentID)/sessions/\(sessionID)/tools/invoke",
        body: body
    )
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(ToolInvocationResult.self, from: response.body)
    let data = payload.data?.asObject
    #expect(payload.ok == true)
    #expect(data?["provider"]?.asString == "perplexity")
    #expect(data?["count"]?.asInt == 1)
    #expect(data?["results"]?.asArray?.first?.asObject?["title"]?.asString == "Swift Package Manager")
    #expect(data?["results"]?.asArray?.first?.asObject?["snippet"]?.asString == "SPM is the package manager for Swift.")
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols

public actor SearchProviderService {
    struct SearchResult: Sendable, Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    struct Citation: Sendable, Equatable {
        let title: String
        let url: String
    }

    struct SearchResponse: Sendable, Equatable {
        let query: String
        let provider: String
        let results: [SearchResult]
        let citations: [Citation]
        let count: Int
    }

    enum SearchError: Error, Equatable {
        case notConfigured
        case invalidResponse
        case responseTooLarge
        case transportFailure
        case httpError(Int)
    }

    typealias Transport = @Sendable (URLRequest, Int, Int) async throws -> (Data, HTTPURLResponse)
    typealias EnvironmentLookup = @Sendable (String) -> String?

    private struct BraveSearchResponse: Decodable {
        struct WebPayload: Decodable {
            struct ResultItem: Decodable {
                let title: String?
                let url: String?
                let description: String?
                let extraSnippets: [String]?

                private enum CodingKeys: String, CodingKey {
                    case title
                    case url
                    case description
                    case extraSnippets = "extra_snippets"
                }
            }

            let results: [ResultItem]?
        }

        let web: WebPayload?
    }

    private struct PerplexitySearchResponse: Decodable {
        struct ResultItem: Decodable {
            let title: String?
            let url: String?
            let snippet: String?
        }

        let results: [ResultItem]
    }

    private var config: CoreConfig.SearchTools
    private let transport: Transport
    private let environmentLookup: EnvironmentLookup

    init(
        config: CoreConfig.SearchTools = .init(),
        transport: Transport? = nil,
        environmentLookup: EnvironmentLookup? = nil
    ) {
        self.config = config
        self.transport = transport ?? Self.defaultTransport
        self.environmentLookup = environmentLookup ?? { key in
            ProcessInfo.processInfo.environment[key]
        }
    }

    func updateConfig(_ config: CoreConfig.SearchTools) {
        self.config = config
    }

    func status() -> SearchToolsStatusResponse {
        let brave = providerStatus(for: .brave)
        let perplexity = providerStatus(for: .perplexity)
        return SearchToolsStatusResponse(
            activeProvider: config.activeProvider.rawValue,
            brave: brave,
            perplexity: perplexity
        )
    }

    func search(
        query: String,
        count: Int,
        timeoutMs: Int,
        maxBytes: Int
    ) async throws -> SearchResponse {
        let provider = config.activeProvider
        let resolvedKey = resolvedKey(for: provider)
        guard let apiKey = resolvedKey, !apiKey.isEmpty else {
            throw SearchError.notConfigured
        }

        switch provider {
        case .brave:
            return try await searchBrave(
                query: query,
                count: count,
                apiKey: apiKey,
                timeoutMs: timeoutMs,
                maxBytes: maxBytes
            )
        case .perplexity:
            return try await searchPerplexity(
                query: query,
                count: count,
                apiKey: apiKey,
                timeoutMs: timeoutMs,
                maxBytes: maxBytes
            )
        }
    }

    private func providerStatus(for provider: CoreConfig.SearchTools.ProviderID) -> SearchProviderStatusResponse {
        let environmentKey = environmentKey(for: provider)
        let configuredKey = configuredKey(for: provider)
        let hasEnvironmentKey = !environmentKey.isEmpty
        let hasConfiguredKey = !configuredKey.isEmpty
        return SearchProviderStatusResponse(
            provider: provider.rawValue,
            hasEnvironmentKey: hasEnvironmentKey,
            hasConfiguredKey: hasConfiguredKey,
            hasAnyKey: hasEnvironmentKey || hasConfiguredKey
        )
    }

    private func resolvedKey(for provider: CoreConfig.SearchTools.ProviderID) -> String? {
        let environmentKey = environmentKey(for: provider)
        if !environmentKey.isEmpty {
            return environmentKey
        }

        let configuredKey = configuredKey(for: provider)
        return configuredKey.isEmpty ? nil : configuredKey
    }

    private func environmentKey(for provider: CoreConfig.SearchTools.ProviderID) -> String {
        let keyName: String
        switch provider {
        case .brave:
            keyName = "BRAVE_API_KEY"
        case .perplexity:
            keyName = "PERPLEXITY_API_KEY"
        }

        return environmentLookup(keyName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func configuredKey(for provider: CoreConfig.SearchTools.ProviderID) -> String {
        let apiKey: String
        switch provider {
        case .brave:
            apiKey = config.providers.brave.apiKey
        case .perplexity:
            apiKey = config.providers.perplexity.apiKey
        }

        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchBrave(
        query: String,
        count: Int,
        apiKey: String,
        timeoutMs: Int,
        maxBytes: Int
    ) async throws -> SearchResponse {
        guard var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else {
            throw SearchError.invalidResponse
        }
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "count", value: String(count))
        ]
        guard let url = components.url else {
            throw SearchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        let (data, response) = try await perform(request: request, timeoutMs: timeoutMs, maxBytes: maxBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw SearchError.httpError(response.statusCode)
        }

        let decoded = try JSONDecoder().decode(BraveSearchResponse.self, from: data)
        let normalizedResults = (decoded.web?.results ?? []).compactMap { item -> SearchResult? in
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (item.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = preferredSnippet(primary: item.description, secondary: item.extraSnippets?.first)
            guard !title.isEmpty, !url.isEmpty else {
                return nil
            }
            return SearchResult(title: title, url: url, snippet: snippet)
        }

        return SearchResponse(
            query: query,
            provider: CoreConfig.SearchTools.ProviderID.brave.rawValue,
            results: normalizedResults,
            citations: normalizedResults.map { Citation(title: $0.title, url: $0.url) },
            count: normalizedResults.count
        )
    }

    private func searchPerplexity(
        query: String,
        count: Int,
        apiKey: String,
        timeoutMs: Int,
        maxBytes: Int
    ) async throws -> SearchResponse {
        guard let url = URL(string: "https://api.perplexity.ai/search") else {
            throw SearchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "query": query,
                "max_results": count
            ],
            options: []
        )

        let (data, response) = try await perform(request: request, timeoutMs: timeoutMs, maxBytes: maxBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw SearchError.httpError(response.statusCode)
        }

        let decoded = try JSONDecoder().decode(PerplexitySearchResponse.self, from: data)
        let normalizedResults = decoded.results.compactMap { item -> SearchResult? in
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (item.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = preferredSnippet(primary: item.snippet, secondary: nil)
            guard !title.isEmpty, !url.isEmpty else {
                return nil
            }
            return SearchResult(title: title, url: url, snippet: snippet)
        }

        return SearchResponse(
            query: query,
            provider: CoreConfig.SearchTools.ProviderID.perplexity.rawValue,
            results: normalizedResults,
            citations: normalizedResults.map { Citation(title: $0.title, url: $0.url) },
            count: normalizedResults.count
        )
    }

    private func perform(
        request: URLRequest,
        timeoutMs: Int,
        maxBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(request, timeoutMs, maxBytes)
        } catch let error as SearchError {
            throw error
        } catch {
            throw SearchError.transportFailure
        }
    }

    private func preferredSnippet(primary: String?, secondary: String?) -> String {
        let primaryValue = primary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primaryValue.isEmpty {
            return primaryValue
        }

        return secondary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static let defaultTransport: Transport = { request, timeoutMs, maxBytes in
        var request = request
        request.timeoutInterval = max(0.1, Double(timeoutMs) / 1000.0)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        let session = URLSession(configuration: configuration)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse
        }
        guard data.count <= maxBytes else {
            throw SearchError.responseTooLarge
        }
        return (data, httpResponse)
    }
}

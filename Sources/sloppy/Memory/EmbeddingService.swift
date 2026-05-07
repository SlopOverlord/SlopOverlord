import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

/// OpenAI-compatible embedding service.
/// Sends batched text to a `/v1/embeddings` endpoint and returns float vectors.
/// Works with OpenAI, Ollama (`/v1/embeddings`), and any compatible server.
public actor EmbeddingService {
    private let endpoint: URL
    private let model: String
    private let dimensions: Int
    private let apiKey: String?
    private let timeoutSeconds: Double
    private let logger: Logger

    public init(
        endpoint: URL,
        model: String,
        dimensions: Int,
        apiKey: String? = nil,
        timeoutSeconds: Double = 10,
        logger: Logger = Logger(label: "sloppy.memory.embedding")
    ) {
        self.endpoint = endpoint
        self.model = model
        self.dimensions = dimensions
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.logger = logger
    }

    public func embed(text: String) async throws -> [Float] {
        let results = try await embed(texts: [text])
        guard let first = results.first else {
            throw EmbeddingError.emptyResponse
        }
        return first
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let requestBody = EmbeddingRequest(model: model, input: texts, dimensions: dimensions)
        let bodyData = try JSONEncoder().encode(requestBody)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        let (data, response) = try await SloppyURLSessionFactory.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingError.transportFailure
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.warning("Embedding request failed [\(httpResponse.statusCode)]: \(body.prefix(200))")
            throw EmbeddingError.httpError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        let sorted = decoded.data.sorted { $0.index < $1.index }
        return sorted.map { $0.embedding }
    }
}

// MARK: - Wire format

private struct EmbeddingRequest: Encodable {
    let model: String
    let input: [String]
    let dimensions: Int
}

private struct EmbeddingResponse: Decodable {
    struct EmbeddingObject: Decodable {
        let index: Int
        let embedding: [Float]
    }

    let data: [EmbeddingObject]
}

// MARK: - Errors

enum EmbeddingError: Error {
    case emptyResponse
    case transportFailure
    case httpError(Int)
}

// MARK: - Factory

extension EmbeddingService {
    /// Resolves endpoint, model, and API key from config and environment, then creates the service.
    /// Returns nil when embedding is disabled in config.
    static func make(config: CoreConfig, logger: Logger) -> EmbeddingService? {
        guard config.memory.embedding.enabled else { return nil }

        let cfg = config.memory.embedding

        let openAIConfigs = config.models.filter {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("openai:") == true
                && !isOpenAIOAuthEntry($0)
        }
        let preferredOpenAI = openAIConfigs.first {
            !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? openAIConfigs.first

        let endpoint: URL
        if let raw = cfg.endpoint,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: raw) {
            endpoint = url
        } else if let openAIConfig = preferredOpenAI,
                  !openAIConfig.apiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let base = URL(string: openAIConfig.apiUrl) {
            endpoint = base.appendingPathComponent("embeddings")
        } else {
            endpoint = URL(string: "https://api.openai.com/v1/embeddings")!
        }

        let apiKey: String?
        if let envName = cfg.apiKeyEnv,
           let value = ProcessInfo.processInfo.environment[envName],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiKey = value
        } else if let value = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiKey = value
        } else if let configKey = preferredOpenAI?.apiKey,
                  !configKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiKey = configKey
        } else {
            apiKey = nil
        }

        return EmbeddingService(
            endpoint: endpoint,
            model: cfg.model,
            dimensions: cfg.dimensions,
            apiKey: apiKey,
            logger: logger
        )
    }

    private static func isOpenAIOAuthEntry(_ model: CoreConfig.ModelConfig) -> Bool {
        let catalog = model.providerCatalogId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if catalog == "openai-oauth" {
            return true
        }
        let title = model.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.contains("oauth") || title.contains("deeplink")
    }
}

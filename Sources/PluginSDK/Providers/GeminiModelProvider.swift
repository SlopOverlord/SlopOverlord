import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Protocols

public struct GeminiModelProvider: ModelProvider {
    public let id: String
    public let supportedModels: [String]
    public let systemInstructions: String?
    public let tools: [any Tool]
    private let apiKey: @Sendable () -> String
    private let refreshTokenIfNeeded: (@Sendable () async throws -> Void)?
    private let baseURL: URL
    private let session: URLSession?

    public init(
        id: String = "gemini",
        supportedModels: [String],
        apiKey: @escaping @Sendable () -> String,
        refreshTokenIfNeeded: (@Sendable () async throws -> Void)? = nil,
        baseURL: URL = GeminiLanguageModel.defaultBaseURL,
        tools: [any Tool] = [],
        systemInstructions: String? = nil,
        session: URLSession? = nil
    ) {
        self.id = id
        self.supportedModels = supportedModels
        self.apiKey = apiKey
        self.refreshTokenIfNeeded = refreshTokenIfNeeded
        self.baseURL = baseURL
        self.tools = tools
        self.systemInstructions = systemInstructions
        self.session = session
    }

    public func supports(modelName: String) -> Bool {
        if supportedModels.contains(modelName) {
            return true
        }
        return modelName.hasPrefix("gemini:")
    }

    public func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        try await refreshTokenIfNeeded?()
        let resolved = modelName.hasPrefix("gemini:") ? String(modelName.dropFirst(7)) : modelName
        if let session {
            return GeminiLanguageModel(
                baseURL: baseURL,
                apiKey: apiKey(),
                model: resolved,
                session: session
            )
        }
        return GeminiLanguageModel(
            baseURL: baseURL,
            apiKey: apiKey(),
            model: resolved
        )
    }
}

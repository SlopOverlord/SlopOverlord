import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif


/// OpenAI Language Model with OAuth Bearer token support
public struct OpenAIOAuthModel: LanguageModel {
    public typealias UnavailableReason = String
    public typealias CustomGenerationOptions = Never
    
    private let baseURL: URL
    private let bearerToken: String
    private let modelName: String
    private let apiVariant: APIVariant
    private let accountId: String?
    
    public enum APIVariant: Sendable {
        case chatCompletions
        case responses
    }
    
    public var availability: Availability<String> {
        guard !bearerToken.isEmpty else {
            return .unavailable("Bearer token is required")
        }
        return .available
    }
    
    public init(
        baseURL: URL = URL(string: "https://api.openai.com")!,
        bearerToken: String,
        model: String,
        apiVariant: APIVariant = .responses,
        accountId: String? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.modelName = model
        self.apiVariant = apiVariant
        self.accountId = accountId
    }
}

// MARK: - LanguageModel Implementation

extension OpenAIOAuthModel {
    public func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        
        let requestBody = try buildRequestBody(
            prompt: prompt,
            options: options,
            stream: false
        )
        
        let responseData = try await performHTTPRequest(
            body: requestBody,
            stream: false
        )
        
        let content = try parseResponse(responseData, as: type)
        return LanguageModelSession.Response(
            content: content,
            rawContent: GeneratedContent(content as? String ?? ""),
            transcriptEntries: []
        )
    }
    
    public func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, Error> { continuation in
            let task = Task {
                do {
                    let requestBody = try buildRequestBody(
                        prompt: prompt,
                        options: options,
                        stream: true
                    )
                    
                    try await performStreamingRequest(
                        body: requestBody,
                        continuation: continuation,
                        contentType: type
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

// MARK: - HTTP Client Implementation

private extension OpenAIOAuthModel {
    func performHTTPRequest(
        body: Data,
        stream: Bool
    ) async throws -> Data {
        let endpoint = apiEndpoint()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 {
                throw OpenAIError.invalidToken("OAuth token is invalid or expired")
            } else if httpResponse.statusCode == 403 {
                throw OpenAIError.invalidToken("OAuth token does not have required permissions")
            }
            
            // Try to parse error from response
            let errorMessage = parseErrorMessage(from: data) ?? "HTTP Error \(httpResponse.statusCode)"
            throw OpenAIError.httpError(httpResponse.statusCode, errorMessage)
        }
        
        return data
    }
    
    func performStreamingRequest<Content>(
        body: Data,
        continuation: AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, Error>.Continuation,
        contentType: Content.Type
    ) async throws where Content: Generable {
        let endpoint = apiEndpoint()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = body
        
        #if canImport(FoundationNetworking)
        let (asyncBytes, response) = try await URLSession.shared.linuxBytes(for: request)
        #else
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        #endif
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 {
                throw OpenAIError.invalidToken("OAuth token is invalid or expired")
            } else if httpResponse.statusCode == 403 {
                throw OpenAIError.invalidToken("OAuth token does not have required permissions")
            }
            throw OpenAIError.httpError(httpResponse.statusCode, "Streaming request failed")
        }
        
        var accumulatedContent = ""
        
        for try await line in asyncBytes.lines {
            if line.hasPrefix("data: ") {
                let jsonString = String(line.dropFirst(6))
                
                if jsonString == "[DONE]" {
                    break
                }
                
                if let deltaContent = parseStreamingDelta(jsonString) {
                    accumulatedContent += deltaContent
                    
                    if let content = try? parseAccumulatedContent(accumulatedContent, as: contentType) {
                        let snapshot = LanguageModelSession.ResponseStream<Content>.Snapshot(
                            content: content as! Content.PartiallyGenerated,
                            rawContent: GeneratedContent(accumulatedContent)
                        )
                        continuation.yield(snapshot)
                    }
                }
            }
        }
    }
    
    func apiEndpoint() -> URL {
        let base = baseURL.absoluteString.hasSuffix("/v1") || baseURL.absoluteString.hasSuffix("/v1/")
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        switch apiVariant {
        case .chatCompletions:
            return base.appendingPathComponent("chat/completions")
        case .responses:
            return base.appendingPathComponent("responses")
        }
    }
}

#if canImport(FoundationNetworking)
extension URLSession {
    fileprivate func linuxBytes(for request: URLRequest) async throws -> (StreamWrapper, URLResponse) {
        let delegate = LinuxStreamingDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        let response = try await delegate.waitForResponse()
        return (StreamWrapper(stream: delegate.stream), response)
    }

    struct StreamWrapper: AsyncSequence {
        typealias Element = UInt8
        let stream: AsyncThrowingStream<UInt8, Error>
        
        func makeAsyncIterator() -> AsyncThrowingStream<UInt8, Error>.Iterator {
            stream.makeAsyncIterator()
        }
        
        var lines: AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    var buffer = Data()
                    do {
                        for try await byte in stream {
                            if byte == UInt8(ascii: "\n") {
                                let line = String(data: buffer, encoding: .utf8) ?? ""
                                continuation.yield(line)
                                buffer.removeAll()
                            } else if byte != UInt8(ascii: "\r") {
                                buffer.append(byte)
                            }
                        }
                        if !buffer.isEmpty {
                            let line = String(data: buffer, encoding: .utf8) ?? ""
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}

private final class LinuxStreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    nonisolated(unsafe) private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    nonisolated(unsafe) private var streamContinuation: AsyncThrowingStream<UInt8, Error>.Continuation?
    let stream: AsyncThrowingStream<UInt8, Error>
    
    override init() {
        var cont: AsyncThrowingStream<UInt8, Error>.Continuation?
        self.stream = AsyncThrowingStream { cont = $0 }
        self.streamContinuation = cont
        super.init()
    }
    
    func waitForResponse() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { self.responseContinuation = $0 }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for byte in data {
            streamContinuation?.yield(byte)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if let responseContinuation = responseContinuation {
                responseContinuation.resume(throwing: error)
                self.responseContinuation = nil
            }
            streamContinuation?.finish(throwing: error)
        } else {
            streamContinuation?.finish()
        }
    }
}
#endif

// MARK: - Request/Response Parsing

private extension OpenAIOAuthModel {
    func buildRequestBody(
        prompt: Prompt,
        options: GenerationOptions,
        stream: Bool
    ) throws -> Data {
        let messages = [
            OpenAIMessage(role: "user", content: String(describing: prompt))
        ]
        
        let request = OpenAIRequest(
            model: modelName,
            messages: messages,
            maxTokens: options.maximumResponseTokens,
            temperature: options.temperature,
            stream: stream
        )
        
        return try JSONEncoder().encode(request)
    }
    
    func parseResponse<Content>(
        _ data: Data,
        as type: Content.Type
    ) throws -> Content where Content: Generable {
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        
        guard let choice = response.choices.first,
              let message = choice.message else {
            throw OpenAIError.decodingError("No response content found")
        }
        
        return try parseContent(message.content, as: type)
    }
    
    func parseStreamingDelta(_ jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let streamResponse = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: data),
              let choice = streamResponse.choices.first,
              let delta = choice.delta,
              let content = delta.content else {
            return nil
        }
        return content
    }
    
    func parseAccumulatedContent<Content>(
        _ content: String,
        as type: Content.Type
    ) throws -> Content where Content: Generable {
        return try parseContent(content, as: type)
    }
    
    func parseContent<Content>(
        _ content: String,
        as type: Content.Type
    ) throws -> Content where Content: Generable {
        if Content.self == String.self {
            return content as! Content
        }
        
        // For other types, we'd need to implement proper parsing
        // For now, just return string representation
        return content as! Content
    }
    
    func parseErrorMessage(from data: Data) -> String? {
        guard let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) else {
            return nil
        }
        return errorResponse.error.message
    }
}

// MARK: - Data Models

private struct OpenAIRequest: Codable {
    let model: String
    let messages: [OpenAIMessage]
    let maxTokens: Int?
    let temperature: Double?
    let stream: Bool?
    
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIResponse: Codable {
    let choices: [OpenAIChoice]
}

private struct OpenAIChoice: Codable {
    let message: OpenAIMessage?
}

private struct OpenAIStreamResponse: Codable {
    let choices: [OpenAIStreamChoice]
}

private struct OpenAIStreamChoice: Codable {
    let delta: OpenAIDelta?
}

private struct OpenAIDelta: Codable {
    let content: String?
}

private struct OpenAIErrorResponse: Codable {
    let error: OpenAIErrorDetail
}

private struct OpenAIErrorDetail: Codable {
    let message: String
    let type: String?
    let code: String?
}

// MARK: - Error Types

enum OpenAIError: Error, LocalizedError {
    case invalidToken(String)
    case invalidResponse
    case httpError(Int, String)
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidToken(let message):
            return "OAuth Authentication Error: \(message)"
        case .invalidResponse:
            return "Invalid response from OpenAI API"
        case .httpError(let code, let message):
            return "HTTP Error \(code): \(message)"
        case .decodingError(let message):
            return "Response parsing error: \(message)"
        }
    }
}
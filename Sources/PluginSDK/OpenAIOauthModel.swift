import AnyLanguageModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI OAuth model implementation.
public struct OpenAIOAuthModel: LanguageModel {
    public typealias UnavailableReason = String
    public typealias CustomGenerationOptions = Never

    public static let defaultBaseURL = URL(string: "https://chatgpt.com/backend-api/codex")!

    private let baseURL: URL
    private let bearerToken: String
    private let modelName: String
    private let accountId: String?
    private let instructions: String

    public var availability: Availability<String> {
        guard !bearerToken.isEmpty else {
            return .unavailable("Bearer token is required")
        }
        return .available
    }

    public init(
        baseURL: URL = OpenAIOAuthModel.defaultBaseURL,
        bearerToken: String,
        model: String,
        accountId: String? = nil,
        instructions: String = "You are a helpful assistant."
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.modelName = model
        self.accountId = accountId
        self.instructions = instructions
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
        let requestBody = try buildRequestBody(prompt: prompt, options: options)
        let fullText = try await collectStreamingResponse(body: requestBody)
        let content = fullText as! Content
        return LanguageModelSession.Response(
            content: content,
            rawContent: GeneratedContent(fullText),
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
                    let requestBody = try buildRequestBody(prompt: prompt, options: options)
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

// MARK: - HTTP Client

private extension OpenAIOAuthModel {
    var responsesEndpoint: URL {
        baseURL.appendingPathComponent("responses")
    }

    func buildHTTPRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: responsesEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = body
        return request
    }

    func collectStreamingResponse(body: Data) async throws -> String {
        let request = buildHTTPRequest(body: body)

        #if canImport(FoundationNetworking)
        let (asyncBytes, response) = try await URLSession.shared.linuxBytes(for: request)
        #else
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        #endif

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            var errorText = ""
            for try await line in asyncBytes.lines {
                errorText += line
            }
            throw classifyHTTPError(statusCode: httpResponse.statusCode, body: errorText)
        }

        var accumulated = ""
        for try await line in asyncBytes.lines {
            if let delta = parseSSEDelta(line) {
                accumulated += delta
            }
        }
        return accumulated
    }

    func performStreamingRequest<Content>(
        body: Data,
        continuation: AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, Error>.Continuation,
        contentType: Content.Type
    ) async throws where Content: Generable {
        let request = buildHTTPRequest(body: body)

        #if canImport(FoundationNetworking)
        let (asyncBytes, response) = try await URLSession.shared.linuxBytes(for: request)
        #else
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        #endif

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            var errorText = ""
            for try await line in asyncBytes.lines {
                errorText += line
            }
            throw classifyHTTPError(statusCode: httpResponse.statusCode, body: errorText)
        }

        var accumulated = ""
        for try await line in asyncBytes.lines {
            if let delta = parseSSEDelta(line) {
                accumulated += delta
                if Content.self == String.self {
                    let snapshot = LanguageModelSession.ResponseStream<Content>.Snapshot(
                        content: accumulated as! Content.PartiallyGenerated,
                        rawContent: GeneratedContent(accumulated)
                    )
                    continuation.yield(snapshot)
                }
            }
        }
    }

    func classifyHTTPError(statusCode: Int, body: String) -> OpenAIError {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] as? String {
            if statusCode == 401 {
                return .invalidToken(detail)
            }
            return .httpError(statusCode, detail)
        }
        if statusCode == 401 {
            return .invalidToken("OAuth token is invalid or expired")
        } else if statusCode == 403 {
            return .invalidToken("OAuth token does not have required permissions")
        }
        return .httpError(statusCode, body.isEmpty ? "Request failed" : body)
    }
}

// MARK: - Request/Response Parsing

private extension OpenAIOAuthModel {
    func buildRequestBody(prompt: Prompt, options: GenerationOptions) throws -> Data {
        var body: [String: Any] = [
            "model": modelName,
            "instructions": instructions,
            "input": [
                ["role": "user", "content": String(describing: prompt)]
            ],
            "stream": true,
            "store": false
        ]
        if let temperature = options.temperature {
            body["temperature"] = temperature
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func parseSSEDelta(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "response.output_text.delta",
              let delta = obj["delta"] as? String
        else { return nil }
        return delta
    }
}

// MARK: - Linux Streaming Support

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

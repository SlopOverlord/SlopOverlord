import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import Testing
@testable import Core
@testable import Protocols

private struct SSEMalformedResponseError: Error {}

private final class SSEDataCollector: NSObject, URLSessionDataDelegate {
    private var receivedData = Data()
    private var httpResponse: HTTPURLResponse?
    private var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private var task: URLSessionDataTask?

    func start(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.task = session.dataTask(with: request)
            self.task?.resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        if let response = httpResponse, receivedData.count > 0 {
            let text = String(data: receivedData, encoding: .utf8) ?? ""
            if text.contains("data: "), let continuation = continuation {
                self.continuation = nil
                dataTask.cancel()
                continuation.resume(returning: (response, receivedData))
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpResponse = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        if let error = error {
            continuation.resume(throwing: error)
        } else if let response = httpResponse {
            continuation.resume(returning: (response, receivedData))
        } else {
            continuation.resume(throwing: SSEMalformedResponseError())
        }
    }
}

private func readFirstSSEEvent(url: URL) async throws -> (HTTPURLResponse, String, Data) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10

    let collector = SSEDataCollector()
    let (response, data) = try await collector.start(request: request)

    let text = String(data: data, encoding: .utf8) ?? ""
    let lines = text.components(separatedBy: CharacterSet.newlines)

    var eventName = "message"
    for line in lines {
        if line.hasPrefix(":") || line.isEmpty {
            continue
        }
        if line.hasPrefix("event: ") {
            eventName = String(line.dropFirst("event: ".count)).trimmingCharacters(in: .whitespaces)
            continue
        }
        if line.hasPrefix("data: ") {
            let payload = String(line.dropFirst("data: ".count))
            return (response, eventName, Data(payload.utf8))
        }
    }

    throw SSEMalformedResponseError()
}

@Test
func sseStreamEndpointOverHTTPServerReturnsSessionReadyEvent() async throws {
    let workspaceName = "workspace-http-sse-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-http-sse-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let server = CoreHTTPServer(
        host: "127.0.0.1",
        port: 0,
        router: router,
        logger: Logger(label: "slopoverlord.core.httpserver.tests")
    )
    try server.start()
    defer { try? server.shutdown() }

    guard let boundPort = server.boundPort else {
        throw SSEMalformedResponseError()
    }

    _ = try await service.createAgent(
        AgentCreateRequest(
            id: "agent-http-stream",
            displayName: "Agent HTTP Stream",
            role: "SSE regression"
        )
    )
    let session = try await service.createAgentSession(
        agentID: "agent-http-stream",
        request: AgentSessionCreateRequest(title: "HTTP SSE Session")
    )

    let url = try #require(
        URL(string: "http://127.0.0.1:\(boundPort)/v1/agents/agent-http-stream/sessions/\(session.id)/stream")
    )

    let (httpResponse, eventName, payload) = try await readFirstSSEEvent(url: url)

    #expect(httpResponse.statusCode == 200)
    #expect((httpResponse.value(forHTTPHeaderField: "content-type") ?? "").contains("text/event-stream"))
    #expect(eventName == AgentSessionStreamUpdateKind.sessionReady.rawValue)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let update = try decoder.decode(AgentSessionStreamUpdate.self, from: payload)
    #expect(update.kind == .sessionReady)
    #expect(update.summary?.id == session.id)
}

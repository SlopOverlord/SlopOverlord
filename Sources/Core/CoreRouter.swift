import Foundation
import AgentRuntime
import Protocols

/// Minimal transport-agnostic response type used by Core router handlers.
public struct CoreRouterResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }
}

public enum HTTPRouteMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// Typed request object passed into router callbacks.
public struct HTTPRequest: Sendable {
    public var method: HTTPRouteMethod
    public var path: String
    public var segments: [String]
    public var params: [String: String]
    public var body: Data?

    public init(
        method: HTTPRouteMethod,
        path: String,
        segments: [String],
        params: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.segments = segments
        self.params = params
        self.body = body
    }

    public func pathParam(_ key: String) -> String? {
        params[key]
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let body else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: body)
    }
}

/// WebSocket-style placeholder callback context for future transport integration.
public struct WebSocketConnectionContext: Sendable {
    public init() {}
}

enum CoreRouterConstants {
    static let emptyJSONData = Data("{}".utf8)
}

private enum HTTPStatus {
    static let ok = 200
    static let created = 201
    static let badRequest = 400
    static let conflict = 409
    static let notFound = 404
    static let internalServerError = 500
}

private enum ErrorCode {
    static let invalidBody = "invalid_body"
    static let notFound = "not_found"
    static let artifactNotFound = "artifact_not_found"
    static let configWriteFailed = "config_write_failed"
    static let invalidAgentId = "invalid_agent_id"
    static let invalidAgentPayload = "invalid_agent_payload"
    static let agentAlreadyExists = "agent_already_exists"
    static let agentNotFound = "agent_not_found"
    static let agentCreateFailed = "agent_create_failed"
    static let agentsListFailed = "agents_list_failed"
    static let invalidSessionId = "invalid_session_id"
    static let invalidSessionPayload = "invalid_session_payload"
    static let sessionNotFound = "session_not_found"
    static let sessionCreateFailed = "session_create_failed"
    static let sessionListFailed = "session_list_failed"
    static let sessionDeleteFailed = "session_delete_failed"
    static let sessionWriteFailed = "session_write_failed"
    static let invalidAgentConfigPayload = "invalid_agent_config_payload"
    static let invalidAgentModel = "invalid_agent_model"
    static let agentConfigReadFailed = "agent_config_read_failed"
    static let agentConfigWriteFailed = "agent_config_write_failed"
}

private struct AcceptResponse: Encodable {
    let accepted: Bool
}

private struct WorkerCreateResponse: Encodable {
    let workerId: String
}

private enum RoutePathSegment: Equatable {
    case literal(String)
    case parameter(String)
}

private struct RouteDefinition {
    typealias Callback = (HTTPRequest) async -> CoreRouterResponse

    let method: HTTPRouteMethod
    let segments: [RoutePathSegment]
    let callback: Callback

    init(method: HTTPRouteMethod, path: String, callback: @escaping Callback) {
        self.method = method
        self.segments = parseRoutePath(path)
        self.callback = callback
    }

    func match(pathSegments: [String]) -> [String: String]? {
        guard segments.count == pathSegments.count else {
            return nil
        }

        var params: [String: String] = [:]
        for (pattern, value) in zip(segments, pathSegments) {
            switch pattern {
            case .literal(let literal):
                guard literal == value else {
                    return nil
                }
            case .parameter(let key):
                params[key] = value
            }
        }
        return params
    }
}

private struct WebSocketRouteDefinition {
    typealias Callback = (HTTPRequest, WebSocketConnectionContext) async -> Void

    let segments: [RoutePathSegment]
    let callback: Callback

    init(path: String, callback: @escaping Callback) {
        self.segments = parseRoutePath(path)
        self.callback = callback
    }
}

public actor CoreRouter {
    private let service: CoreService
    private var routes: [RouteDefinition]
    private var webSocketRoutes: [WebSocketRouteDefinition]

    public init(service: CoreService) {
        self.service = service
        self.routes = Self.defaultRoutes(service: service)
        self.webSocketRoutes = []
    }

    /// Registers generic HTTP route callback.
    public func register(
        path: String,
        method: HTTPRouteMethod,
        callback: @escaping (HTTPRequest) async -> CoreRouterResponse
    ) {
        routes.append(.init(method: method, path: path, callback: callback))
    }

    public func get(_ path: String, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .get, callback: callback)
    }

    public func post(_ path: String, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .post, callback: callback)
    }

    public func put(_ path: String, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .put, callback: callback)
    }

    public func delete(_ path: String, callback: @escaping (HTTPRequest) async -> CoreRouterResponse) {
        register(path: path, method: .delete, callback: callback)
    }

    /// WebSocket-like registration API (transport integration to be wired in CoreHTTPServer later).
    public func webSocket(
        _ path: String,
        callback: @escaping (HTTPRequest, WebSocketConnectionContext) async -> Void
    ) {
        webSocketRoutes.append(.init(path: path, callback: callback))
    }

    /// Routes incoming HTTP-like request into registered Core handlers.
    public func handle(method: String, path: String, body: Data?) async -> CoreRouterResponse {
        guard let httpMethod = HTTPRouteMethod(rawValue: method.uppercased()) else {
            return Self.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }

        let pathSegments = splitPath(path)
        for route in routes where route.method == httpMethod {
            guard let params = route.match(pathSegments: pathSegments) else {
                continue
            }

            let request = HTTPRequest(
                method: httpMethod,
                path: path,
                segments: pathSegments,
                params: params,
                body: body
            )
            return await route.callback(request)
        }

        return Self.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
    }

    private static func defaultRoutes(service: CoreService) -> [RouteDefinition] {
        var routes: [RouteDefinition] = []

        func add(
            _ method: HTTPRouteMethod,
            _ path: String,
            _ callback: @escaping (HTTPRequest) async -> CoreRouterResponse
        ) {
            routes.append(.init(method: method, path: path, callback: callback))
        }

        add(.get, "/health") { _ in
            Self.json(status: HTTPStatus.ok, payload: ["status": "ok"])
        }

        add(.get, "/v1/channels/:channelId/state") { request in
            let channelId = request.pathParam("channelId") ?? ""
            let state = await service.getChannelState(channelId: channelId) ?? ChannelSnapshot(
                channelId: channelId,
                messages: [],
                contextUtilization: 0,
                activeWorkerIds: [],
                lastDecision: nil
            )
            return Self.encodable(status: HTTPStatus.ok, payload: state)
        }

        add(.get, "/v1/bulletins") { _ in
            let bulletins = await service.getBulletins()
            return Self.encodable(status: HTTPStatus.ok, payload: bulletins)
        }

        add(.get, "/v1/workers") { _ in
            let workers = await service.workerSnapshots()
            return Self.encodable(status: HTTPStatus.ok, payload: workers)
        }

        add(.get, "/v1/config") { _ in
            let config = await service.getConfig()
            return Self.encodable(status: HTTPStatus.ok, payload: config)
        }

        add(.get, "/v1/agents") { _ in
            do {
                let agents = try await service.listAgents()
                return Self.encodable(status: HTTPStatus.ok, payload: agents)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentsListFailed])
            }
        }

        add(.get, "/v1/agents/:agentId") { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let agent = try await service.getAgent(id: agentId)
                return Self.encodable(status: HTTPStatus.ok, payload: agent)
            } catch CoreService.AgentStorageError.invalidID {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return Self.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentNotFound])
            }
        }

        add(.get, "/v1/agents/:agentId/sessions") { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let sessions = try await service.listAgentSessions(agentID: agentId)
                return Self.encodable(status: HTTPStatus.ok, payload: sessions)
            } catch let error as CoreService.AgentSessionError {
                return Self.agentSessionErrorResponse(error, fallback: ErrorCode.sessionListFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionListFailed])
            }
        }

        add(.get, "/v1/agents/:agentId/config") { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let detail = try await service.getAgentConfig(agentID: agentId)
                return Self.encodable(status: HTTPStatus.ok, payload: detail)
            } catch let error as CoreService.AgentConfigError {
                return Self.agentConfigErrorResponse(error, fallback: ErrorCode.agentConfigReadFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentConfigReadFailed])
            }
        }

        add(.get, "/v1/agents/:agentId/sessions/:sessionId") { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            do {
                let detail = try await service.getAgentSession(agentID: agentId, sessionID: sessionId)
                return Self.encodable(status: HTTPStatus.ok, payload: detail)
            } catch let error as CoreService.AgentSessionError {
                return Self.agentSessionErrorResponse(error, fallback: ErrorCode.sessionNotFound)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionNotFound])
            }
        }

        add(.get, "/v1/artifacts/:artifactId/content") { request in
            let artifactId = request.pathParam("artifactId") ?? ""
            guard let response = await service.getArtifactContent(id: artifactId) else {
                return Self.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.artifactNotFound])
            }
            return Self.encodable(status: HTTPStatus.ok, payload: response)
        }

        add(.put, "/v1/config") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: CoreConfig.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let config = try await service.updateConfig(payload)
                return Self.encodable(status: HTTPStatus.ok, payload: config)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.configWriteFailed])
            }
        }

        add(.put, "/v1/agents/:agentId/config") { request in
            let agentId = request.pathParam("agentId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: AgentConfigUpdateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentConfigPayload])
            }

            do {
                let detail = try await service.updateAgentConfig(agentID: agentId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: detail)
            } catch let error as CoreService.AgentConfigError {
                return Self.agentConfigErrorResponse(error, fallback: ErrorCode.agentConfigWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentConfigWriteFailed])
            }
        }

        add(.post, "/v1/providers/openai/models") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: OpenAIProviderModelsRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let response = await service.listOpenAIModels(request: payload)
            return Self.encodable(status: HTTPStatus.ok, payload: response)
        }

        add(.post, "/v1/agents") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: AgentCreateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let agent = try await service.createAgent(payload)
                return Self.encodable(status: HTTPStatus.created, payload: agent)
            } catch CoreService.AgentStorageError.invalidID {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.invalidPayload {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentPayload])
            } catch CoreService.AgentStorageError.alreadyExists {
                return Self.json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.agentAlreadyExists])
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentCreateFailed])
            }
        }

        add(.post, "/v1/agents/:agentId/sessions") { request in
            let agentId = request.pathParam("agentId") ?? ""
            let payload: AgentSessionCreateRequest

            if let body = request.body {
                guard let decoded = Self.decode(body, as: AgentSessionCreateRequest.self) else {
                    return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
                }
                payload = decoded
            } else {
                payload = AgentSessionCreateRequest()
            }

            do {
                let summary = try await service.createAgentSession(agentID: agentId, request: payload)
                return Self.encodable(status: HTTPStatus.created, payload: summary)
            } catch let error as CoreService.AgentSessionError {
                return Self.agentSessionErrorResponse(error, fallback: ErrorCode.sessionCreateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionCreateFailed])
            }
        }

        add(.post, "/v1/agents/:agentId/sessions/:sessionId/messages") { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: AgentSessionPostMessageRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.postAgentSessionMessage(
                    agentID: agentId,
                    sessionID: sessionId,
                    request: payload
                )
                return Self.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return Self.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        add(.post, "/v1/agents/:agentId/sessions/:sessionId/control") { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: AgentSessionControlRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.controlAgentSession(
                    agentID: agentId,
                    sessionID: sessionId,
                    request: payload
                )
                return Self.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.AgentSessionError {
                return Self.agentSessionErrorResponse(error, fallback: ErrorCode.sessionWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionWriteFailed])
            }
        }

        add(.post, "/v1/channels/:channelId/messages") { request in
            let channelId = request.pathParam("channelId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ChannelMessageRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let decision = await service.postChannelMessage(channelId: channelId, request: payload)
            return Self.encodable(status: HTTPStatus.ok, payload: decision)
        }

        add(.post, "/v1/channels/:channelId/route/:workerId") { request in
            let channelId = request.pathParam("channelId") ?? ""
            let workerId = request.pathParam("workerId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ChannelRouteRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let accepted = await service.postChannelRoute(
                channelId: channelId,
                workerId: workerId,
                request: payload
            )
            return Self.encodable(
                status: accepted ? HTTPStatus.ok : HTTPStatus.notFound,
                payload: AcceptResponse(accepted: accepted)
            )
        }

        add(.post, "/v1/workers") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: WorkerCreateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let workerId = await service.postWorker(request: payload)
            return Self.encodable(status: HTTPStatus.created, payload: WorkerCreateResponse(workerId: workerId))
        }

        add(.delete, "/v1/agents/:agentId/sessions/:sessionId") { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""

            do {
                try await service.deleteAgentSession(agentID: agentId, sessionID: sessionId)
                return Self.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch let error as CoreService.AgentSessionError {
                return Self.agentSessionErrorResponse(error, fallback: ErrorCode.sessionDeleteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionDeleteFailed])
            }
        }

        return routes
    }

    private static func agentSessionErrorResponse(_ error: CoreService.AgentSessionError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidSessionID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidSessionId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidSessionPayload])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .sessionNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.sessionNotFound])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    private static func agentConfigErrorResponse(_ error: CoreService.AgentConfigError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentConfigPayload])
        case .invalidModel:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentModel])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    private static func json(status: Int, payload: [String: String]) -> CoreRouterResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? CoreRouterConstants.emptyJSONData
        return CoreRouterResponse(status: status, body: data)
    }

    private static func encodable<T: Encodable>(status: Int, payload: T) -> CoreRouterResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(payload)) ?? CoreRouterConstants.emptyJSONData
        return CoreRouterResponse(status: status, body: data)
    }

    private static func decode<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

private func parseRoutePath(_ path: String) -> [RoutePathSegment] {
    splitPath(path).map { segment in
        if segment.hasPrefix(":"), segment.count > 1 {
            return .parameter(String(segment.dropFirst()))
        }
        return .literal(segment)
    }
}

private func splitPath(_ rawPath: String) -> [String] {
    let withoutHash = rawPath.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
    let withoutQuery = withoutHash.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutHash
    return withoutQuery
        .split(separator: "/")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

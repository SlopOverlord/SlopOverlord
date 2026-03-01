import Foundation
import AgentRuntime
import Protocols

/// Minimal transport-agnostic response type used by Core router handlers.
public struct CoreRouterResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var sseStream: AsyncStream<CoreRouterServerSentEvent>?

    public init(
        status: Int,
        body: Data,
        contentType: String = "application/json",
        sseStream: AsyncStream<CoreRouterServerSentEvent>? = nil
    ) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.sseStream = sseStream
    }
}

public struct CoreRouterServerSentEvent: Sendable {
    public var event: String
    public var data: Data
    public var id: String?

    public init(event: String, data: Data, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

public enum HTTPRouteMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
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
    static let forbidden = 403
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
    static let sessionStreamFailed = "session_stream_failed"
    static let invalidAgentConfigPayload = "invalid_agent_config_payload"
    static let invalidAgentModel = "invalid_agent_model"
    static let agentConfigReadFailed = "agent_config_read_failed"
    static let agentConfigWriteFailed = "agent_config_write_failed"
    static let invalidAgentToolsPayload = "invalid_agent_tools_payload"
    static let invalidToolInvocationPayload = "invalid_tool_invocation_payload"
    static let agentToolsReadFailed = "agent_tools_read_failed"
    static let agentToolsWriteFailed = "agent_tools_write_failed"
    static let toolForbidden = "tool_forbidden"
    static let toolInvokeFailed = "tool_invoke_failed"
    static let systemLogsReadFailed = "system_logs_read_failed"
    static let invalidActorPayload = "invalid_actor_payload"
    static let actorNotFound = "actor_not_found"
    static let linkNotFound = "link_not_found"
    static let teamNotFound = "team_not_found"
    static let actorProtected = "actor_protected"
    static let actorBoardReadFailed = "actor_board_read_failed"
    static let actorBoardWriteFailed = "actor_board_write_failed"
    static let actorRouteFailed = "actor_route_failed"
    static let invalidProjectId = "invalid_project_id"
    static let invalidProjectPayload = "invalid_project_payload"
    static let invalidProjectTaskId = "invalid_project_task_id"
    static let invalidProjectChannelId = "invalid_project_channel_id"
    static let projectNotFound = "project_not_found"
    static let projectConflict = "project_conflict"
    static let projectCreateFailed = "project_create_failed"
    static let projectUpdateFailed = "project_update_failed"
    static let projectDeleteFailed = "project_delete_failed"
    static let projectListFailed = "project_list_failed"
    static let projectReadFailed = "project_read_failed"
    static let invalidPluginId = "invalid_plugin_id"
    static let invalidPluginPayload = "invalid_plugin_payload"
    static let pluginNotFound = "plugin_not_found"
    static let pluginConflict = "plugin_conflict"
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

        add(.get, "/v1/projects") { _ in
            let projects = await service.listProjects()
            return Self.encodable(status: HTTPStatus.ok, payload: projects)
        }

        add(.get, "/v1/projects/:projectId") { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let project = try await service.getProject(id: projectId)
                return Self.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectReadFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectReadFailed])
            }
        }

        add(.get, "/v1/providers/openai/status") { _ in
            let status = await service.openAIProviderStatus()
            return Self.encodable(status: HTTPStatus.ok, payload: status)
        }

        add(.get, "/v1/config") { _ in
            let config = await service.getConfig()
            return Self.encodable(status: HTTPStatus.ok, payload: config)
        }

        add(.get, "/v1/logs") { _ in
            do {
                let response = try await service.getSystemLogs()
                return Self.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.SystemLogsError {
                return Self.systemLogsErrorResponse(error, fallback: ErrorCode.systemLogsReadFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.systemLogsReadFailed])
            }
        }

        add(.get, "/v1/agents") { _ in
            do {
                let agents = try await service.listAgents()
                return Self.encodable(status: HTTPStatus.ok, payload: agents)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentsListFailed])
            }
        }

        add(.get, "/v1/actors/board") { _ in
            do {
                let board = try await service.getActorBoard()
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardReadFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardReadFailed])
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

        add(.get, "/v1/agents/:agentId/tasks") { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let tasks = try await service.listAgentTasks(agentID: agentId)
                return Self.encodable(status: HTTPStatus.ok, payload: tasks)
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

        add(.get, "/v1/agents/:agentId/tools") { request in
            let agentId = request.pathParam("agentId") ?? ""
            do {
                let policy = try await service.getAgentToolsPolicy(agentID: agentId)
                return Self.encodable(status: HTTPStatus.ok, payload: policy)
            } catch let error as CoreService.AgentToolsError {
                return Self.agentToolsErrorResponse(error, fallback: ErrorCode.agentToolsReadFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentToolsReadFailed])
            }
        }

        add(.get, "/v1/agents/:agentId/tools/catalog") { _ in
            let catalog = await service.toolCatalog()
            return Self.encodable(status: HTTPStatus.ok, payload: catalog)
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

        add(.get, "/v1/agents/:agentId/sessions/:sessionId/stream") { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            do {
                let stream = try await service.streamAgentSessionEvents(agentID: agentId, sessionID: sessionId)
                return Self.sse(status: HTTPStatus.ok, updates: stream)
            } catch let error as CoreService.AgentSessionError {
                return Self.agentSessionErrorResponse(error, fallback: ErrorCode.sessionStreamFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.sessionStreamFailed])
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

        add(.put, "/v1/agents/:agentId/tools") { request in
            let agentId = request.pathParam("agentId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: AgentToolsUpdateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentToolsPayload])
            }

            do {
                let policy = try await service.updateAgentToolsPolicy(agentID: agentId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: policy)
            } catch let error as CoreService.AgentToolsError {
                return Self.agentToolsErrorResponse(error, fallback: ErrorCode.agentToolsWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentToolsWriteFailed])
            }
        }

        add(.put, "/v1/actors/board") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorBoardUpdateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let board = try await service.updateActorBoard(request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.put, "/v1/actors/nodes/:actorId") { request in
            let actorId = request.pathParam("actorId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorNode.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let board = try await service.updateActorNode(actorID: actorId, node: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.put, "/v1/actors/links/:linkId") { request in
            let linkId = request.pathParam("linkId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorLink.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let board = try await service.updateActorLink(linkID: linkId, link: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.put, "/v1/actors/teams/:teamId") { request in
            let teamId = request.pathParam("teamId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorTeam.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let board = try await service.updateActorTeam(teamID: teamId, team: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
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

        add(.post, "/v1/projects") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: ProjectCreateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.createProject(payload)
                return Self.encodable(status: HTTPStatus.created, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectCreateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectCreateFailed])
            }
        }

        add(.post, "/v1/projects/:projectId/channels") { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ProjectChannelCreateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.createProjectChannel(projectID: projectId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        add(.post, "/v1/projects/:projectId/tasks") { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ProjectTaskCreateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.createProjectTask(projectID: projectId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
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

        add(.post, "/v1/actors/nodes") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorNode.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let board = try await service.createActorNode(node: payload)
                return Self.encodable(status: HTTPStatus.created, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.post, "/v1/actors/links") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorLink.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let board = try await service.createActorLink(link: payload)
                return Self.encodable(status: HTTPStatus.created, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.post, "/v1/actors/teams") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorTeam.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let board = try await service.createActorTeam(team: payload)
                return Self.encodable(status: HTTPStatus.created, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
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

        add(.post, "/v1/agents/:agentId/sessions/:sessionId/tools/invoke") { request in
            let agentId = request.pathParam("agentId") ?? ""
            let sessionId = request.pathParam("sessionId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ToolInvocationRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidToolInvocationPayload])
            }

            do {
                let result = try await service.invokeTool(agentID: agentId, sessionID: sessionId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: result)
            } catch let error as CoreService.ToolInvocationError {
                return Self.toolInvocationErrorResponse(error, fallback: ErrorCode.toolInvokeFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.toolInvokeFailed])
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

        add(.post, "/v1/actors/route") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: ActorRouteRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
            }

            do {
                let response = try await service.resolveActorRoute(request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorRouteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorRouteFailed])
            }
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

        add(.patch, "/v1/projects/:projectId") { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ProjectUpdateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.updateProject(projectID: projectId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        add(.patch, "/v1/projects/:projectId/tasks/:taskId") { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ProjectTaskUpdateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.updateProjectTask(projectID: projectId, taskID: taskId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
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

        add(.delete, "/v1/actors/nodes/:actorId") { request in
            let actorId = request.pathParam("actorId") ?? ""

            do {
                let board = try await service.deleteActorNode(actorID: actorId)
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.delete, "/v1/actors/links/:linkId") { request in
            let linkId = request.pathParam("linkId") ?? ""

            do {
                let board = try await service.deleteActorLink(linkID: linkId)
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.delete, "/v1/actors/teams/:teamId") { request in
            let teamId = request.pathParam("teamId") ?? ""

            do {
                let board = try await service.deleteActorTeam(teamID: teamId)
                return Self.encodable(status: HTTPStatus.ok, payload: board)
            } catch let error as CoreService.ActorBoardError {
                return Self.actorBoardErrorResponse(error, fallback: ErrorCode.actorBoardWriteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.actorBoardWriteFailed])
            }
        }

        add(.delete, "/v1/projects/:projectId") { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                try await service.deleteProject(projectID: projectId)
                return Self.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectDeleteFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectDeleteFailed])
            }
        }

        add(.delete, "/v1/projects/:projectId/channels/:channelId") { request in
            let projectId = request.pathParam("projectId") ?? ""
            let channelId = request.pathParam("channelId") ?? ""
            do {
                let project = try await service.deleteProjectChannel(projectID: projectId, channelID: channelId)
                return Self.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        add(.delete, "/v1/projects/:projectId/tasks/:taskId") { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            do {
                let project = try await service.deleteProjectTask(projectID: projectId, taskID: taskId)
                return Self.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return Self.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        // MARK: - Channel Plugins

        add(.get, "/v1/plugins") { _ in
            let plugins = await service.listChannelPlugins()
            return Self.encodable(status: HTTPStatus.ok, payload: plugins)
        }

        add(.post, "/v1/plugins") { request in
            guard let body = request.body,
                  let payload = Self.decode(body, as: ChannelPluginCreateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidPluginPayload])
            }
            do {
                let plugin = try await service.createChannelPlugin(payload)
                return Self.encodable(status: HTTPStatus.created, payload: plugin)
            } catch let error as CoreService.ChannelPluginError {
                return Self.channelPluginErrorResponse(error)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.invalidPluginPayload])
            }
        }

        add(.get, "/v1/plugins/:pluginId") { request in
            let pluginId = request.pathParam("pluginId") ?? ""
            do {
                let plugin = try await service.getChannelPlugin(id: pluginId)
                return Self.encodable(status: HTTPStatus.ok, payload: plugin)
            } catch let error as CoreService.ChannelPluginError {
                return Self.channelPluginErrorResponse(error)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.pluginNotFound])
            }
        }

        add(.put, "/v1/plugins/:pluginId") { request in
            let pluginId = request.pathParam("pluginId") ?? ""
            guard let body = request.body,
                  let payload = Self.decode(body, as: ChannelPluginUpdateRequest.self)
            else {
                return Self.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidPluginPayload])
            }
            do {
                let plugin = try await service.updateChannelPlugin(id: pluginId, request: payload)
                return Self.encodable(status: HTTPStatus.ok, payload: plugin)
            } catch let error as CoreService.ChannelPluginError {
                return Self.channelPluginErrorResponse(error)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.invalidPluginPayload])
            }
        }

        add(.delete, "/v1/plugins/:pluginId") { request in
            let pluginId = request.pathParam("pluginId") ?? ""
            do {
                try await service.deleteChannelPlugin(id: pluginId)
                return Self.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch let error as CoreService.ChannelPluginError {
                return Self.channelPluginErrorResponse(error)
            } catch {
                return Self.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.pluginNotFound])
            }
        }

        return routes
    }

    private static func channelPluginErrorResponse(_ error: CoreService.ChannelPluginError) -> CoreRouterResponse {
        switch error {
        case .invalidID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidPluginId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidPluginPayload])
        case .notFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.pluginNotFound])
        case .conflict:
            return json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.pluginConflict])
        }
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

    private static func agentToolsErrorResponse(_ error: CoreService.AgentToolsError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentToolsPayload])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    private static func toolInvocationErrorResponse(_ error: CoreService.ToolInvocationError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidAgentID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
        case .invalidSessionID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidSessionId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidToolInvocationPayload])
        case .agentNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
        case .sessionNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.sessionNotFound])
        case .forbidden(_):
            return json(status: HTTPStatus.forbidden, payload: ["error": ErrorCode.toolForbidden])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    private static func systemLogsErrorResponse(_ error: CoreService.SystemLogsError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    private static func actorBoardErrorResponse(_ error: CoreService.ActorBoardError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidActorPayload])
        case .actorNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.actorNotFound])
        case .linkNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.linkNotFound])
        case .teamNotFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.teamNotFound])
        case .protectedActor:
            return json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.actorProtected])
        case .storageFailure:
            return json(status: HTTPStatus.internalServerError, payload: ["error": fallback])
        }
    }

    private static func projectErrorResponse(_ error: CoreService.ProjectError, fallback: String) -> CoreRouterResponse {
        switch error {
        case .invalidProjectID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectId])
        case .invalidChannelID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectChannelId])
        case .invalidTaskID:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectTaskId])
        case .invalidPayload:
            return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidProjectPayload])
        case .notFound:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.projectNotFound])
        case .conflict:
            return json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.projectConflict])
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

    private static func sse(status: Int, updates: AsyncStream<AgentSessionStreamUpdate>) -> CoreRouterResponse {
        let stream = AsyncStream<CoreRouterServerSentEvent>(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let task = Task {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601

                for await update in updates {
                    let payload = (try? encoder.encode(update)) ?? CoreRouterConstants.emptyJSONData
                    continuation.yield(
                        CoreRouterServerSentEvent(
                            event: update.kind.rawValue,
                            data: payload,
                            id: String(update.cursor)
                        )
                    )
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return CoreRouterResponse(
            status: status,
            body: Data(),
            contentType: "text/event-stream",
            sseStream: stream
        )
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
        .map { segment in
            let rawSegment = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            return rawSegment.removingPercentEncoding ?? rawSegment
        }
        .filter { !$0.isEmpty }
}

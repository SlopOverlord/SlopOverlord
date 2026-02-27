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

/// Shared serializer constants.
enum CoreRouterConstants {
    static let contentTypeJSON = "application/json"
    static let emptyJSONData = Data("{}".utf8)
}

private enum HTTPMethod {
    static let get = "GET"
    static let post = "POST"
    static let put = "PUT"
}

private enum HTTPStatus {
    static let ok = 200
    static let created = 201
    static let badRequest = 400
    static let conflict = 409
    static let notFound = 404
    static let internalServerError = 500
}

private enum RoutePath {
    static let health = "/health"
}

private enum RouteSegment {
    static let v1 = "v1"
    static let providers = "providers"
    static let agents = "agents"
    static let openAI = "openai"
    static let models = "models"
    static let channels = "channels"
    static let messages = "messages"
    static let route = "route"
    static let state = "state"
    static let bulletins = "bulletins"
    static let workers = "workers"
    static let artifacts = "artifacts"
    static let content = "content"
    static let config = "config"
}

private enum ErrorCode {
    static let invalidBody = "invalid_body"
    static let notFound = "not_found"
    static let channelNotFound = "channel_not_found"
    static let artifactNotFound = "artifact_not_found"
    static let configWriteFailed = "config_write_failed"
    static let invalidAgentId = "invalid_agent_id"
    static let invalidAgentPayload = "invalid_agent_payload"
    static let agentAlreadyExists = "agent_already_exists"
    static let agentNotFound = "agent_not_found"
    static let agentCreateFailed = "agent_create_failed"
    static let agentsListFailed = "agents_list_failed"
}

private struct AcceptResponse: Encodable {
    let accepted: Bool
}

private struct WorkerCreateResponse: Encodable {
    let workerId: String
}

public actor CoreRouter {
    private let service: CoreService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: CoreService) {
        self.service = service
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Routes incoming HTTP-like request into Core service handlers.
    public func handle(method: String, path: String, body: Data?) async -> CoreRouterResponse {
        if method == HTTPMethod.get, path == RoutePath.health {
            return json(status: HTTPStatus.ok, payload: ["status": "ok"])
        }

        let segments = splitPath(path)
        guard !segments.isEmpty else {
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }

        switch method {
        case HTTPMethod.get:
            return await handleGet(segments: segments)
        case HTTPMethod.post:
            return await handlePost(segments: segments, body: body)
        case HTTPMethod.put:
            return await handlePut(segments: segments, body: body)
        default:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }
    }

    /// Handles all `GET` routes under `/v1`.
    private func handleGet(segments: [String]) async -> CoreRouterResponse {
        switch segments {
        case let route where route.count == 4 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.channels &&
            route[3] == RouteSegment.state:
            let channelId = route[2]
            let state = await service.getChannelState(channelId: channelId) ?? ChannelSnapshot(
                channelId: channelId,
                messages: [],
                contextUtilization: 0,
                activeWorkerIds: [],
                lastDecision: nil
            )
            return encodable(status: HTTPStatus.ok, payload: state)

        case let route where route.count == 2 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.bulletins:
            let bulletins = await service.getBulletins()
            return encodable(status: HTTPStatus.ok, payload: bulletins)

        case let route where route.count == 2 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.workers:
            let workers = await service.workerSnapshots()
            return encodable(status: HTTPStatus.ok, payload: workers)

        case let route where route.count == 2 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.config:
            let config = await service.getConfig()
            return encodable(status: HTTPStatus.ok, payload: config)

        case let route where route.count == 2 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.agents:
            do {
                let agents = try await service.listAgents()
                return encodable(status: HTTPStatus.ok, payload: agents)
            } catch {
                return json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentsListFailed])
            }

        case let route where route.count == 3 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.agents:
            let agentId = route[2]
            do {
                let agent = try await service.getAgent(id: agentId)
                return encodable(status: HTTPStatus.ok, payload: agent)
            } catch CoreService.AgentStorageError.invalidID {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.notFound {
                return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.agentNotFound])
            } catch {
                return json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentNotFound])
            }

        case let route where route.count == 4 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.artifacts &&
            route[3] == RouteSegment.content:
            let artifactId = route[2]
            guard let response = await service.getArtifactContent(id: artifactId) else {
                return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.artifactNotFound])
            }
            return encodable(status: HTTPStatus.ok, payload: response)

        default:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }
    }

    /// Handles all `PUT` routes under `/v1`.
    private func handlePut(segments: [String], body: Data?) async -> CoreRouterResponse {
        switch segments {
        case let route where route.count == 2 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.config:
            guard let body,
                  let request = try? decoder.decode(CoreConfig.self, from: body)
            else {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let config = try await service.updateConfig(request)
                return encodable(status: HTTPStatus.ok, payload: config)
            } catch {
                return json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.configWriteFailed])
            }

        default:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }
    }

    /// Handles all `POST` routes under `/v1`.
    private func handlePost(segments: [String], body: Data?) async -> CoreRouterResponse {
        switch segments {
        case let route where route.count == 4 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.providers &&
            route[2] == RouteSegment.openAI &&
            route[3] == RouteSegment.models:
            guard let body,
                  let request = try? decoder.decode(OpenAIProviderModelsRequest.self, from: body)
            else {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let response = await service.listOpenAIModels(request: request)
            return encodable(status: HTTPStatus.ok, payload: response)

        case let route where route.count == 2 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.agents:
            guard let body,
                  let request = try? decoder.decode(AgentCreateRequest.self, from: body)
            else {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let agent = try await service.createAgent(request)
                return encodable(status: HTTPStatus.created, payload: agent)
            } catch CoreService.AgentStorageError.invalidID {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentId])
            } catch CoreService.AgentStorageError.invalidPayload {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidAgentPayload])
            } catch CoreService.AgentStorageError.alreadyExists {
                return json(status: HTTPStatus.conflict, payload: ["error": ErrorCode.agentAlreadyExists])
            } catch {
                return json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.agentCreateFailed])
            }

        case let route where route.count == 4 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.channels &&
            route[3] == RouteSegment.messages:
            let channelId = route[2]
            guard let body,
                  let request = try? decoder.decode(ChannelMessageRequest.self, from: body)
            else {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let decision = await service.postChannelMessage(channelId: channelId, request: request)
            return encodable(status: HTTPStatus.ok, payload: decision)

        case let route where route.count == 5 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.channels &&
            route[3] == RouteSegment.route:
            let channelId = route[2]
            let workerId = route[4]
            guard let body,
                  let request = try? decoder.decode(ChannelRouteRequest.self, from: body)
            else {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let accepted = await service.postChannelRoute(
                channelId: channelId,
                workerId: workerId,
                request: request
            )
            return encodable(
                status: accepted ? HTTPStatus.ok : HTTPStatus.notFound,
                payload: AcceptResponse(accepted: accepted)
            )

        case let route where route.count == 2 &&
            route[0] == RouteSegment.v1 &&
            route[1] == RouteSegment.workers:
            guard let body,
                  let request = try? decoder.decode(WorkerCreateRequest.self, from: body)
            else {
                return json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let workerId = await service.postWorker(request: request)
            return encodable(status: HTTPStatus.created, payload: WorkerCreateResponse(workerId: workerId))

        default:
            return json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }
    }

    /// Splits URL path into normalized segments (without leading slash).
    private func splitPath(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Encodes plain JSON dictionary responses.
    private func json(status: Int, payload: [String: String]) -> CoreRouterResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? CoreRouterConstants.emptyJSONData
        return CoreRouterResponse(status: status, body: data)
    }

    /// Encodes typed payload responses.
    private func encodable<T: Encodable>(status: Int, payload: T) -> CoreRouterResponse {
        let data = (try? encoder.encode(payload)) ?? CoreRouterConstants.emptyJSONData
        return CoreRouterResponse(status: status, body: data)
    }
}

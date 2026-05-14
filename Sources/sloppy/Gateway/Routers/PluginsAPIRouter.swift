import Foundation
import Protocols

struct PluginsAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/plugins", metadata: RouteMetadata(summary: "List channel plugins", description: "Returns a list of all available channel plugins", tags: ["Plugins"])) { _ in
            let plugins = await service.listChannelPlugins()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: plugins)
        }

        router.post("/v1/plugins", metadata: RouteMetadata(summary: "Create channel plugin", description: "Creates a new channel plugin", tags: ["Plugins"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ChannelPluginCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidPluginPayload])
            }
            do {
                let plugin = try await service.createChannelPlugin(payload)
                return CoreRouter.encodable(status: HTTPStatus.created, payload: plugin)
            } catch let error as CoreService.ChannelPluginError {
                return CoreRouter.channelPluginErrorResponse(error)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.invalidPluginPayload])
            }
        }

        router.post("/v1/plugins/install", metadata: RouteMetadata(summary: "Install source plugin", description: "Clones, builds, caches, and loads a SwiftPM source gateway plugin", tags: ["Plugins"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ChannelPluginInstallRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidPluginPayload])
            }
            do {
                let installed = try await service.installSourceChannelPlugin(payload)
                return CoreRouter.encodable(status: HTTPStatus.created, payload: installed)
            } catch let error as CoreService.ChannelPluginError {
                return CoreRouter.channelPluginErrorResponse(error)
            } catch let error as PluginPackageInstallError {
                let status = pluginInstallHTTPStatus(error)
                return CoreRouter.json(
                    status: status,
                    payload: ["error": ErrorCode.pluginInstallFailed, "message": error.localizedDescription]
                )
            } catch let error as PluginPackageBuildError {
                return CoreRouter.json(
                    status: HTTPStatus.internalServerError,
                    payload: ["error": ErrorCode.pluginInstallFailed, "message": error.localizedDescription]
                )
            } catch {
                return CoreRouter.json(
                    status: HTTPStatus.internalServerError,
                    payload: ["error": ErrorCode.pluginInstallFailed, "message": "\(error)"]
                )
            }
        }

        router.get("/v1/plugins/:pluginId", metadata: RouteMetadata(summary: "Get channel plugin", description: "Returns details of a specific channel plugin", tags: ["Plugins"])) { request in
            let pluginId = request.pathParam("pluginId") ?? ""
            do {
                let plugin = try await service.getChannelPlugin(id: pluginId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: plugin)
            } catch let error as CoreService.ChannelPluginError {
                return CoreRouter.channelPluginErrorResponse(error)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.pluginNotFound])
            }
        }

        router.put("/v1/plugins/:pluginId", metadata: RouteMetadata(summary: "Update channel plugin", description: "Updates an existing channel plugin", tags: ["Plugins"])) { request in
            let pluginId = request.pathParam("pluginId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ChannelPluginUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidPluginPayload])
            }
            do {
                let plugin = try await service.updateChannelPlugin(id: pluginId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: plugin)
            } catch let error as CoreService.ChannelPluginError {
                return CoreRouter.channelPluginErrorResponse(error)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.invalidPluginPayload])
            }
        }

        router.delete("/v1/plugins/:pluginId", metadata: RouteMetadata(summary: "Delete channel plugin", description: "Deletes a specific channel plugin", tags: ["Plugins"])) { request in
            let pluginId = request.pathParam("pluginId") ?? ""
            do {
                try await service.deleteChannelPlugin(id: pluginId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch let error as CoreService.ChannelPluginError {
                return CoreRouter.channelPluginErrorResponse(error)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.pluginNotFound])
            }
        }
    }
}

private func pluginInstallHTTPStatus(_ error: PluginPackageInstallError) -> Int {
    switch error {
    case .conflict:
        return HTTPStatus.conflict
    case .gitCommandFailed, .moveFailed:
        return HTTPStatus.internalServerError
    case .invalidSourceURL, .missingPackageSwift, .missingOrInvalidManifest, .unsupportedProtocol, .invalidPluginName:
        return HTTPStatus.badRequest
    }
}

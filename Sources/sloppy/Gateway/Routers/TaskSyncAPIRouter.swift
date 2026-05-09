import Foundation
import Protocols

struct TaskSyncAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.post(
            "/v1/task-sync/:providerId/webhook",
            metadata: RouteMetadata(
                summary: "Task sync provider webhook",
                description: "Receives task sync provider webhooks with provider signature validation",
                tags: ["Task Sync"]
            )
        ) { request in
            let providerId = request.pathParam("providerId") ?? ""
            do {
                let response = try await service.receiveTaskSyncWebhook(
                    providerId: providerId,
                    headers: request.headers,
                    body: request.body ?? Data()
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch CoreService.TaskSyncError.signatureInvalid {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": "invalid_signature"])
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_webhook_failed"])
            }
        }
    }
}

import Foundation
import Protocols

struct ProjectsAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/projects", metadata: RouteMetadata(summary: "List projects", description: "Returns a list of all active projects", tags: ["Projects"])) { _ in
            let projects = await service.listProjects()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: projects)
        }

        router.get("/v1/projects/:projectId", metadata: RouteMetadata(summary: "Get project", description: "Returns details of a specific project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let project = try await service.getProject(id: projectId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectReadFailed])
            }
        }

        router.get("/v1/projects/:projectId/analytics", metadata: RouteMetadata(summary: "Get project analytics", description: "Returns aggregated analytics for a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let windowRaw = (request.queryParam("window") ?? "24h").lowercased()
            let window = ProjectAnalyticsWindow(rawValue: windowRaw) ?? .last24h
            let from = request.queryParam("from").flatMap { CoreRouter.isoDate(from: $0) }
            let to = request.queryParam("to").flatMap { CoreRouter.isoDate(from: $0) }

            do {
                let response = try await service.projectAnalytics(projectID: projectId, query: .init(window: window, from: from, to: to))
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectReadFailed])
            }
        }

        router.get("/v1/projects/:projectId/files", metadata: RouteMetadata(summary: "List project files", description: "Returns the file tree entries for a directory in the project workspace", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let path = request.queryParam("path") ?? ""
            do {
                let entries = try await service.listProjectFiles(projectID: projectId, path: path)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: entries)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectNotFound)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectNotFound])
            }
        }

        router.get("/v1/projects/:projectId/files/search", metadata: RouteMetadata(summary: "Search project files", description: "Returns file and directory paths under the project workspace matching a query string", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let query = request.queryParam("q") ?? ""
            let parsedLimit = Int(request.queryParam("limit") ?? "") ?? 50
            let limit = max(1, min(parsedLimit, 100))
            do {
                let entries = try await service.searchProjectFiles(projectID: projectId, query: query, limit: limit)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: entries)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectNotFound)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectNotFound])
            }
        }

        router.get("/v1/projects/:projectId/files/content", metadata: RouteMetadata(summary: "Read project file", description: "Returns the text content of a file in the project workspace", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let path = request.queryParam("path") ?? ""
            do {
                let response = try await service.readProjectFile(projectID: projectId, path: path)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectNotFound)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectNotFound])
            }
        }

        router.get("/v1/projects/:projectId/git/working-tree", metadata: RouteMetadata(summary: "Project working tree git diff", description: "Returns line add/delete counts and a unified diff for uncommitted changes in the project workspace", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let response = try await service.projectWorkingTreeGit(projectID: projectId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectNotFound)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectReadFailed])
            }
        }

        router.get("/v1/projects/:projectId/changes/stream", metadata: RouteMetadata(summary: "Project working tree change stream", description: "Streams debounced project file metadata changes without file contents", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let stream = try await service.streamProjectWorkingTreeChanges(projectID: projectId)
                return CoreRouter.sseProjectChanges(status: HTTPStatus.ok, stream: stream)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectReadFailed])
            }
        }

        router.post("/v1/projects/:projectId/git/restore", metadata: RouteMetadata(summary: "Restore project file from HEAD", description: "Runs git restore --source=HEAD --staged --worktree for a path under the project repo", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectGitRestoreRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                try await service.restoreProjectWorkingTreeFile(projectID: projectId, path: payload.path)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: ProjectGitRestoreResponse(ok: true))
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.post("/v1/projects", metadata: RouteMetadata(summary: "Create project", description: "Creates a new project", tags: ["Projects"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let result = try await service.createProject(payload)
                return CoreRouter.encodable(status: HTTPStatus.created, payload: result)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectCreateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectCreateFailed])
            }
        }

        router.post("/v1/projects/:projectId/channels", metadata: RouteMetadata(summary: "Create project channel", description: "Adds a new communication channel to a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectChannelCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.createProjectChannel(projectID: projectId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.post("/v1/projects/:projectId/channel-links", metadata: RouteMetadata(summary: "Link project channel", description: "Links an existing Telegram topic, Discord room, or channel id to a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectChannelLinkRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.linkProjectChannel(projectID: projectId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let conflict as CoreService.ProjectChannelLinkConflict {
                return CoreRouter.json(
                    status: HTTPStatus.conflict,
                    payload: [
                        "error": ErrorCode.projectConflict,
                        "ownerProjectId": conflict.ownerProjectId,
                        "ownerProjectName": conflict.ownerProjectName,
                        "channelId": conflict.channelId
                    ]
                )
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.get("/v1/projects/:projectId/tasks/archived", metadata: RouteMetadata(summary: "List archived tasks", description: "Returns tasks that have been archived (done/cancelled for more than 2 days)", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let tasks = try await service.listArchivedTasks(projectID: projectId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: tasks)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectReadFailed])
            }
        }

        router.post("/v1/projects/:projectId/tasks", metadata: RouteMetadata(summary: "Create project task", description: "Adds a new task to a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectTaskCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.createProjectTask(projectID: projectId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.get("/v1/projects/:projectId/task-sync", metadata: RouteMetadata(summary: "Get project task sync settings", description: "Returns task sync settings for a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let settings = try await service.getTaskSyncSettings(projectID: projectId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: settings)
            } catch {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "task_sync_not_found"])
            }
        }

        router.patch("/v1/projects/:projectId/task-sync", metadata: RouteMetadata(summary: "Update project task sync settings", description: "Updates task sync settings for a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectTaskSyncSettingsUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                let response = try await service.updateTaskSyncSettings(projectID: projectId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_update_failed"])
            }
        }

        router.post("/v1/projects/:projectId/task-sync/link", metadata: RouteMetadata(summary: "Link project task sync", description: "Links a project to an external task provider", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectTaskSyncLinkRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                let response = try await service.linkTaskSync(projectID: projectId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_link_failed", "message": error.localizedDescription])
            }
        }

        router.post("/v1/projects/:projectId/task-sync/unlink", metadata: RouteMetadata(summary: "Unlink project task sync", description: "Disables task sync for a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let response = try await service.unlinkTaskSync(projectID: projectId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_unlink_failed"])
            }
        }

        router.post("/v1/projects/:projectId/task-sync/sync-now", metadata: RouteMetadata(summary: "Run project task sync", description: "Runs manual sync for linked project tasks", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let response = try await service.syncTaskSyncNow(projectID: projectId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_failed", "message": error.localizedDescription])
            }
        }

        router.get("/v1/projects/:projectId/task-sync/token", metadata: RouteMetadata(summary: "Get project task sync token status", description: "Returns masked project task sync token status", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let providerId = request.queryParam("providerId") ?? "github"
            do {
                let response = try await service.taskSyncTokenStatus(projectID: projectId, providerId: providerId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_token_status_failed"])
            }
        }

        router.post("/v1/projects/:projectId/task-sync/token", metadata: RouteMetadata(summary: "Set project task sync token", description: "Stores a project-local task sync token override", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let providerId = request.queryParam("providerId") ?? "github"
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectTaskSyncTokenRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                let response = try await service.setTaskSyncToken(projectID: projectId, providerId: providerId, token: payload.token)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_token_set_failed"])
            }
        }

        router.delete("/v1/projects/:projectId/task-sync/token", metadata: RouteMetadata(summary: "Clear project task sync token", description: "Clears a project-local task sync token override", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let providerId = request.queryParam("providerId") ?? "github"
            do {
                let response = try await service.clearTaskSyncToken(projectID: projectId, providerId: providerId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "task_sync_token_clear_failed"])
            }
        }

        router.patch("/v1/projects/:projectId", metadata: RouteMetadata(summary: "Update project", description: "Updates the details of an existing project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.updateProject(projectID: projectId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.post(
            "/v1/projects/:projectId/context/refresh",
            metadata: RouteMetadata(
                summary: "Refresh project context",
                description: "Loads context files from project repoPath and applies them as channel bootstrap to all project channels",
                tags: ["Projects"]
            )
        ) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                let response = try await service.refreshProjectContext(projectID: projectId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectContextRefreshFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectContextRefreshFailed])
            }
        }

        router.patch("/v1/projects/:projectId/tasks/:taskId", metadata: RouteMetadata(summary: "Update project task", description: "Updates an existing task in a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProjectTaskUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let project = try await service.updateProjectTask(projectID: projectId, taskID: taskId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.delete("/v1/projects/:projectId", metadata: RouteMetadata(summary: "Delete project", description: "Deletes a specific project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            do {
                try await service.deleteProject(projectID: projectId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["status": "deleted"])
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectDeleteFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectDeleteFailed])
            }
        }

        router.delete("/v1/projects/:projectId/channels/:channelId", metadata: RouteMetadata(summary: "Delete project channel", description: "Removes a specific channel from a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let channelId = request.pathParam("channelId") ?? ""
            do {
                let project = try await service.deleteProjectChannel(projectID: projectId, channelID: channelId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.delete("/v1/projects/:projectId/tasks/:taskId", metadata: RouteMetadata(summary: "Delete project task", description: "Removes a specific task from a project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            do {
                let project = try await service.deleteProjectTask(projectID: projectId, taskID: taskId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: project)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.post("/v1/projects/:projectId/tasks/:taskId/approve", metadata: RouteMetadata(summary: "Approve project task review", description: "Merges the task worktree branch and marks the task as done", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            do {
                try await service.approveTask(projectID: projectId, taskID: taskId)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.post("/v1/projects/:projectId/tasks/:taskId/reject", metadata: RouteMetadata(summary: "Reject project task review", description: "Rejects the task review and returns it to the developer", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let payload = request.body.flatMap { CoreRouter.decode($0, as: TaskRejectRequest.self) }
            do {
                try await service.rejectTask(projectID: projectId, taskID: taskId, reason: payload?.reason)
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.get("/v1/projects/:projectId/tasks/:taskId/diff", metadata: RouteMetadata(summary: "Get task git diff", description: "Returns the git diff for a task worktree branch", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            do {
                let response = try await service.getTaskDiff(projectID: projectId, taskID: taskId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectNotFound)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectNotFound])
            }
        }

        router.get("/v1/projects/:projectId/tasks/:taskId/review-comments", metadata: RouteMetadata(summary: "List review comments", description: "Returns all review comments for a task", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let comments = await service.listReviewComments(projectID: projectId, taskID: taskId)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: comments)
        }

        router.post("/v1/projects/:projectId/tasks/:taskId/review-comments", metadata: RouteMetadata(summary: "Add review comment", description: "Adds a review comment to a task diff", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ReviewCommentCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "Invalid comment payload"])
            }
            let comment = await service.addReviewComment(projectID: projectId, taskID: taskId, request: payload)
            return CoreRouter.encodable(status: HTTPStatus.created, payload: comment)
        }

        router.register(
            path: "/v1/projects/:projectId/tasks/:taskId/review-comments/:commentId",
            method: .patch,
            metadata: RouteMetadata(summary: "Update review comment", description: "Updates a review comment (resolve/unresolve or edit content)", tags: ["Projects"]))
        { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let commentId = request.pathParam("commentId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ReviewCommentUpdateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "Invalid comment payload"])
            }
            guard let updated = await service.updateReviewComment(projectID: projectId, taskID: taskId, commentID: commentId, request: payload) else {
                return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "Comment not found"])
            }
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: updated)
        }

        router.delete("/v1/projects/:projectId/tasks/:taskId/review-comments/:commentId", metadata: RouteMetadata(summary: "Delete review comment", description: "Deletes a review comment", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let commentId = request.pathParam("commentId") ?? ""
            let deleted = await service.deleteReviewComment(projectID: projectId, taskID: taskId, commentID: commentId)
            if deleted {
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            }
            return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "Comment not found"])
        }

        router.get("/v1/projects/:projectId/tasks/:taskId/comments", metadata: RouteMetadata(summary: "List task comments", description: "Returns all comments for a task", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let comments = await service.listTaskComments(projectID: projectId, taskID: taskId)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: comments)
        }

        router.post("/v1/projects/:projectId/tasks/:taskId/comments", metadata: RouteMetadata(summary: "Add task comment", description: "Adds a comment to a task", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            guard let body = request.body,
                  let payload = try? JSONDecoder().decode(TaskCommentCreateRequest.self, from: body)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "Invalid comment payload"])
            }
            let comment = await service.addTaskComment(projectID: projectId, taskID: taskId, request: payload)
            return CoreRouter.encodable(status: HTTPStatus.created, payload: comment)
        }

        router.delete("/v1/projects/:projectId/tasks/:taskId/comments/:commentId", metadata: RouteMetadata(summary: "Delete task comment", description: "Deletes a task comment", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let commentId = request.pathParam("commentId") ?? ""
            let deleted = await service.deleteTaskComment(projectID: projectId, taskID: taskId, commentID: commentId)
            if deleted {
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            }
            return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "Comment not found"])
        }

        // MARK: - Task Clarifications

        router.get("/v1/projects/:projectId/tasks/:taskId/clarifications", metadata: RouteMetadata(summary: "List task clarifications", description: "Returns all clarification requests for a task", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            do {
                let records = try await service.listTaskClarifications(projectID: projectId, taskID: taskId)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: records)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectReadFailed])
            }
        }

        router.post("/v1/projects/:projectId/tasks/:taskId/clarifications", metadata: RouteMetadata(summary: "Create clarification request", description: "Creates a new clarification request for a task and moves it to waiting_input", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: TaskClarificationCreateRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                let record = try await service.createTaskClarification(projectID: projectId, taskID: taskId, request: payload)
                return CoreRouter.encodable(status: HTTPStatus.created, payload: record)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.post("/v1/projects/:projectId/tasks/:taskId/clarifications/:clarificationId/answer", metadata: RouteMetadata(summary: "Answer clarification", description: "Submits an answer to a pending clarification request", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let clarificationId = request.pathParam("clarificationId") ?? ""
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: TaskClarificationAnswerRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                let record = try await service.answerTaskClarification(
                    projectID: projectId,
                    taskID: taskId,
                    clarificationID: clarificationId,
                    request: payload
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: record)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectUpdateFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectUpdateFailed])
            }
        }

        router.get("/v1/projects/:projectId/tasks/:taskId/activities", metadata: RouteMetadata(summary: "List task activities", description: "Returns the activity history for a task", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let taskId = request.pathParam("taskId") ?? ""
            let activities = await service.listTaskActivities(projectID: projectId, taskID: taskId)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: activities)
        }

        router.get("/v1/projects/:projectId/memories", metadata: RouteMetadata(summary: "List project memories", description: "Returns a list of memory entries scoped to a specific project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let search = request.queryParam("search")
            let rawFilter = request.queryParam("filter")?.lowercased() ?? AgentMemoryFilter.all.rawValue
            guard let filter = AgentMemoryFilter(rawValue: rawFilter) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let parsedLimit = Int(request.queryParam("limit") ?? "") ?? 20
            let limit = max(1, min(parsedLimit, 100))
            let offset = max(0, Int(request.queryParam("offset") ?? "") ?? 0)

            do {
                let response = try await service.listProjectMemories(
                    projectID: projectId,
                    search: search,
                    filter: filter,
                    limit: limit,
                    offset: offset
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectMemoryReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectMemoryReadFailed])
            }
        }

        router.get("/v1/projects/:projectId/memories/graph", metadata: RouteMetadata(summary: "Get project memory graph", description: "Returns a graph representation of memory entries scoped to a specific project", tags: ["Projects"])) { request in
            let projectId = request.pathParam("projectId") ?? ""
            let search = request.queryParam("search")
            let rawFilter = request.queryParam("filter")?.lowercased() ?? AgentMemoryFilter.all.rawValue
            guard let filter = AgentMemoryFilter(rawValue: rawFilter) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.projectMemoryGraph(
                    projectID: projectId,
                    search: search,
                    filter: filter
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch let error as CoreService.ProjectError {
                return CoreRouter.projectErrorResponse(error, fallback: ErrorCode.projectMemoryReadFailed)
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": ErrorCode.projectMemoryReadFailed])
            }
        }
        router.get("/v1/projects/:projectId/kanban/ws", metadata: RouteMetadata(summary: "Kanban WebSocket", description: "WebSocket for real-time project kanban board updates", tags: ["Projects"])) { _ in
            // This is just a placeholder for OpenAPI, actual WS is handled by CoreRouter.webSocket
            return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": ErrorCode.notFound])
        }
    }
}

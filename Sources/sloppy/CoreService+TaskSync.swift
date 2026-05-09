import Foundation
import PluginSDK
import Protocols

extension CoreService {
    public enum TaskSyncError: Error {
        case invalidProjectID
        case invalidPayload
        case projectNotFound
        case unsupportedProvider
        case tokenMissing
        case signatureInvalid
    }

    public func getTaskSyncSettings(projectID: String) async throws -> ProjectTaskSyncSettings {
        let project = try await taskSyncProject(projectID)
        return project.taskSyncSettings
    }

    public func updateTaskSyncSettings(
        projectID: String,
        request: ProjectTaskSyncSettingsUpdateRequest
    ) async throws -> ProjectTaskSyncResponse {
        var project = try await taskSyncProject(projectID)
        var settings = project.taskSyncSettings
        if let enabled = request.enabled { settings.enabled = enabled }
        if request.providerId != nil { settings.providerId = trimmedOrNil(request.providerId) }
        if request.projectURL != nil { settings.projectURL = trimmedOrNil(request.projectURL) }
        if request.projectNodeId != nil { settings.projectNodeId = trimmedOrNil(request.projectNodeId) }
        if request.defaultRepo != nil { settings.defaultRepo = trimmedOrNil(request.defaultRepo) }
        if let tokenMode = request.tokenMode { settings.tokenMode = tokenMode }
        if let mappings = request.statusMappings { settings.statusMappings = normalizedStatusMappings(mappings) }
        settings.health = ProjectTaskSyncHealth(status: "configured", checkedAt: Date())
        project.taskSyncSettings = masked(settings, projectID: project.id)
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
        return ProjectTaskSyncResponse(project: project, settings: project.taskSyncSettings)
    }

    public func linkTaskSync(
        projectID: String,
        request: ProjectTaskSyncLinkRequest
    ) async throws -> ProjectTaskSyncResponse {
        guard request.providerId == "github" else { throw TaskSyncError.unsupportedProvider }
        var project = try await taskSyncProject(projectID)
        let tokenMode = request.tokenMode ?? .inherit
        let provider = GitHubProjectTaskSyncProvider()
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: request.providerId, tokenMode: tokenMode)
        let fallbackRepo = try request.defaultRepo
            ?? defaultGitHubRepoSlug(for: project)
        let descriptor = try await provider.resolveProject(
            url: request.projectURL,
            token: token,
            defaultRepo: fallbackRepo
        )
        let secret = existingWebhookSecret(projectID: project.id, providerId: request.providerId) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try saveWebhookSecret(secret, projectID: project.id, providerId: request.providerId)
        let settings = ProjectTaskSyncSettings(
            enabled: true,
            providerId: request.providerId,
            projectURL: descriptor.projectURL,
            projectNodeId: descriptor.projectNodeId,
            defaultRepo: descriptor.defaultRepo ?? fallbackRepo,
            tokenMode: tokenMode,
            statusMappings: normalizedStatusMappings(request.statusMappings ?? [:]),
            webhook: ProjectTaskSyncWebhookState(
                enabled: true,
                webhookURL: "/v1/task-sync/github/webhook",
                secretMasked: true,
                manualSetupRequired: true
            ),
            health: ProjectTaskSyncHealth(
                status: descriptor.projectNodeId == nil && token != nil ? "partial" : "linked",
                message: descriptor.projectNodeId == nil ? "Project URL parsed; GitHub metadata unavailable." : nil,
                checkedAt: Date()
            )
        )
        project.taskSyncSettings = masked(settings, projectID: project.id)
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
        return ProjectTaskSyncResponse(project: project, settings: project.taskSyncSettings)
    }

    public func unlinkTaskSync(projectID: String) async throws -> ProjectTaskSyncResponse {
        var project = try await taskSyncProject(projectID)
        let providerId = project.taskSyncSettings.providerId ?? "github"
        try? clearOverrideToken(projectID: project.id, providerId: providerId)
        try? clearWebhookSecret(projectID: project.id, providerId: providerId)
        project.taskSyncSettings = ProjectTaskSyncSettings()
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
        return ProjectTaskSyncResponse(project: project, settings: project.taskSyncSettings)
    }

    public func syncTaskSyncNow(projectID: String) async throws -> ProjectTaskSyncNowResponse {
        var project = try await taskSyncProject(projectID)
        let settings = project.taskSyncSettings
        guard settings.enabled, settings.providerId == "github" else {
            throw TaskSyncError.unsupportedProvider
        }
        let provider = GitHubProjectTaskSyncProvider()
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: "github", tokenMode: settings.tokenMode)
        do {
            let imported = try await provider.importTasks(settings: settings, token: token)
            var importedCount = 0
            var updatedCount = 0
            for external in imported {
                if let index = project.tasks.firstIndex(where: { taskSyncTask($0, matches: external.metadata) }) {
                    project.tasks[index].title = external.title
                    project.tasks[index].description = external.description
                    if let status = external.status {
                        project.tasks[index].status = status
                    }
                    project.tasks[index].externalMetadata = external.metadata
                    project.tasks[index].tags = external.tags
                    project.tasks[index].updatedAt = Date()
                    updatedCount += 1
                } else {
                    project.tasks.append(ProjectTask(
                        id: nextProjectTaskID(for: project),
                        title: external.title,
                        description: external.description,
                        priority: "medium",
                        status: external.status ?? ProjectTaskStatus.backlog.rawValue,
                        externalMetadata: external.metadata,
                        tags: external.tags,
                        createdAt: Date(),
                        updatedAt: Date()
                    ))
                    importedCount += 1
                }
            }
            project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "ok", checkedAt: Date())
            project.updatedAt = Date()
            await store.saveProject(project)
            return ProjectTaskSyncNowResponse(imported: importedCount, updated: updatedCount)
        } catch {
            project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "error", message: error.localizedDescription, checkedAt: Date())
            project.updatedAt = Date()
            await store.saveProject(project)
            return ProjectTaskSyncNowResponse(message: error.localizedDescription)
        }
    }

    public func setTaskSyncToken(
        projectID: String,
        providerId: String,
        token: String
    ) async throws -> ProjectTaskSyncTokenStatusResponse {
        guard providerId == "github" else { throw TaskSyncError.unsupportedProvider }
        let project = try await taskSyncProject(projectID)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskSyncError.invalidPayload }
        try saveOverrideToken(trimmed, projectID: project.id, providerId: providerId)
        var settings = project.taskSyncSettings
        settings.tokenMode = .override
        _ = try await updateTaskSyncSettings(
            projectID: project.id,
            request: ProjectTaskSyncSettingsUpdateRequest(tokenMode: .override)
        )
        return ProjectTaskSyncTokenStatusResponse(tokenMode: .override, hasOverrideToken: true, maskedToken: maskedToken(trimmed))
    }

    public func clearTaskSyncToken(
        projectID: String,
        providerId: String
    ) async throws -> ProjectTaskSyncTokenStatusResponse {
        guard providerId == "github" else { throw TaskSyncError.unsupportedProvider }
        let project = try await taskSyncProject(projectID)
        try? clearOverrideToken(projectID: project.id, providerId: providerId)
        _ = try await updateTaskSyncSettings(
            projectID: project.id,
            request: ProjectTaskSyncSettingsUpdateRequest(tokenMode: .inherit)
        )
        return ProjectTaskSyncTokenStatusResponse(tokenMode: .inherit, hasOverrideToken: false, maskedToken: nil)
    }

    public func taskSyncTokenStatus(
        projectID: String,
        providerId: String
    ) async throws -> ProjectTaskSyncTokenStatusResponse {
        let project = try await taskSyncProject(projectID)
        let override = overrideToken(projectID: project.id, providerId: providerId)
        return ProjectTaskSyncTokenStatusResponse(
            tokenMode: project.taskSyncSettings.tokenMode,
            hasOverrideToken: override != nil,
            maskedToken: override.map(maskedToken)
        )
    }

    public func receiveTaskSyncWebhook(
        providerId: String,
        headers: [String: String],
        body: Data
    ) async throws -> TaskSyncWebhookResponse {
        guard providerId == "github" else { throw TaskSyncError.unsupportedProvider }
        let deliveryId = headers["x-github-delivery"] ?? headers["X-GitHub-Delivery"] ?? ""
        guard !deliveryId.isEmpty else { throw TaskSyncError.invalidPayload }
        if webhookDeliverySeen(providerId: providerId, deliveryId: deliveryId) {
            return TaskSyncWebhookResponse(ok: true, duplicate: true)
        }
        let projects = await store.listProjects()
            .filter { $0.taskSyncSettings.enabled && $0.taskSyncSettings.providerId == providerId }
        guard projects.contains(where: { project in
            guard let secret = existingWebhookSecret(projectID: project.id, providerId: providerId) else { return false }
            return TaskSyncCrypto.verifyGitHubSignature(
                body: body,
                secret: secret,
                signatureHeader: headers["x-hub-signature-256"] ?? headers["X-Hub-Signature-256"]
            )
        }) else {
            throw TaskSyncError.signatureInvalid
        }
        markWebhookDeliverySeen(providerId: providerId, deliveryId: deliveryId)
        let event = headers["x-github-event"] ?? headers["X-GitHub-Event"] ?? ""
        await applyGitHubWebhook(event: event, deliveryId: deliveryId, body: body, projects: projects)
        return TaskSyncWebhookResponse(ok: true)
    }

    func syncOutboundTaskIfNeeded(projectID: String, taskID: String) async {
        guard var project = await store.project(id: projectID),
              project.taskSyncSettings.enabled,
              project.taskSyncSettings.providerId == "github",
              let index = project.tasks.firstIndex(where: { $0.id == taskID })
        else { return }
        var task = project.tasks[index]
        guard task.externalMetadata?.origin != "github" else { return }
        let provider = GitHubProjectTaskSyncProvider()
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: "github", tokenMode: project.taskSyncSettings.tokenMode)
        do {
            let metadata = try await provider.createOrUpdateTask(task, settings: project.taskSyncSettings, token: token)
            task.externalMetadata = metadata
            task.tags = Array(Set(task.tags + ["github", "sloppy:\(project.id)"])).sorted()
            task.updatedAt = Date()
            project.tasks[index] = task
            project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "ok", checkedAt: Date())
            project.updatedAt = Date()
            await store.saveProject(project)
        } catch {
            project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "error", message: error.localizedDescription, checkedAt: Date())
            project.updatedAt = Date()
            await store.saveProject(project)
        }
    }

    func mirrorOutboundCommentIfNeeded(projectID: String, taskID: String, commentID: String) async {
        guard let project = await store.project(id: projectID),
              project.taskSyncSettings.enabled,
              project.taskSyncSettings.providerId == "github",
              let task = project.tasks.first(where: { $0.id == taskID })
        else { return }
        let comments = await listTaskComments(projectID: projectID, taskID: taskID)
        guard var comment = comments.first(where: { $0.id == commentID }),
              comment.externalMetadata?.origin != "github",
              !comment.isAgentReply,
              comment.mentionedActorId == nil
        else { return }
        let provider = GitHubProjectTaskSyncProvider()
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: "github", tokenMode: project.taskSyncSettings.tokenMode)
        do {
            comment.externalMetadata = try await provider.mirrorComment(comment, task: task, settings: project.taskSyncSettings, token: token)
            var updated = comments
            if let index = updated.firstIndex(where: { $0.id == commentID }) {
                updated[index] = comment
                saveTaskComments(updated, projectID: projectID, taskID: taskID)
            }
        } catch {
            logger.warning("task_sync.comment_mirror_failed", metadata: ["project_id": .string(projectID), "task_id": .string(taskID), "error": .string(error.localizedDescription)])
        }
    }

    private func taskSyncProject(_ projectID: String) async throws -> ProjectRecord {
        guard let normalized = normalizedProjectID(projectID) else { throw TaskSyncError.invalidProjectID }
        guard let project = await store.project(id: normalized) else { throw TaskSyncError.projectNotFound }
        return project
    }

    private func providerDirectory(providerId: String) -> URL {
        workspaceRootURL
            .appendingPathComponent("auth", isDirectory: true)
            .appendingPathComponent("task-sync", isDirectory: true)
            .appendingPathComponent(providerId, isDirectory: true)
    }

    private func overrideTokenURL(projectID: String, providerId: String) -> URL {
        providerDirectory(providerId: providerId).appendingPathComponent("\(projectID).token")
    }

    private func webhookSecretURL(projectID: String, providerId: String) -> URL {
        providerDirectory(providerId: providerId).appendingPathComponent("\(projectID).webhook-secret")
    }

    private func saveOverrideToken(_ token: String, projectID: String, providerId: String) throws {
        let url = overrideTokenURL(projectID: projectID, providerId: providerId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
    }

    private func clearOverrideToken(projectID: String, providerId: String) throws {
        let url = overrideTokenURL(projectID: projectID, providerId: providerId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func overrideToken(projectID: String, providerId: String) -> String? {
        let url = overrideTokenURL(projectID: projectID, providerId: providerId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    private func resolvedTaskSyncToken(projectID: String, providerId: String, tokenMode: TaskSyncTokenMode) -> String? {
        if tokenMode == .override {
            return overrideToken(projectID: projectID, providerId: providerId)
        }
        if providerId == "github" {
            return githubAuthService.currentToken()
        }
        return nil
    }

    private func saveWebhookSecret(_ secret: String, projectID: String, providerId: String) throws {
        let url = webhookSecretURL(projectID: projectID, providerId: providerId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(secret.utf8).write(to: url, options: .atomic)
    }

    private func clearWebhookSecret(projectID: String, providerId: String) throws {
        let url = webhookSecretURL(projectID: projectID, providerId: providerId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func existingWebhookSecret(projectID: String, providerId: String) -> String? {
        guard let data = try? Data(contentsOf: webhookSecretURL(projectID: projectID, providerId: providerId)) else {
            return nil
        }
        let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return secret.isEmpty ? nil : secret
    }

    private func webhookDeliveryURL(providerId: String, deliveryId: String) -> URL {
        workspaceRootURL
            .appendingPathComponent("task-sync", isDirectory: true)
            .appendingPathComponent("deliveries", isDirectory: true)
            .appendingPathComponent(providerId, isDirectory: true)
            .appendingPathComponent(deliveryId)
    }

    private func webhookDeliverySeen(providerId: String, deliveryId: String) -> Bool {
        FileManager.default.fileExists(atPath: webhookDeliveryURL(providerId: providerId, deliveryId: deliveryId).path)
    }

    private func markWebhookDeliverySeen(providerId: String, deliveryId: String) {
        let url = webhookDeliveryURL(providerId: providerId, deliveryId: deliveryId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(Date().description.utf8).write(to: url, options: .atomic)
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return "********" }
        return "\(token.prefix(4))...\(token.suffix(4))"
    }

    private func masked(_ settings: ProjectTaskSyncSettings, projectID: String) -> ProjectTaskSyncSettings {
        var next = settings
        next.webhook.secretMasked = existingWebhookSecret(projectID: projectID, providerId: settings.providerId ?? "github") != nil
        return next
    }

    private func trimmedOrNil(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedStatusMappings(_ raw: [String: String]) -> [String: String] {
        raw.reduce(into: [:]) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }
    }

    private func defaultGitHubRepoSlug(for project: ProjectRecord) throws -> String? {
        guard let repoPath = project.repoPath, !repoPath.isEmpty else { return nil }
        let metadata = GitRepositoryInspector().inspectRepository(at: URL(fileURLWithPath: repoPath))
        if let remote = metadata?.githubRemote {
            return "\(remote.owner)/\(remote.repo)"
        }
        return nil
    }

    private func taskSyncTask(_ task: ProjectTask, matches metadata: TaskExternalMetadata) -> Bool {
        guard let existing = task.externalMetadata else { return false }
        return existing.externalIssueId == metadata.externalIssueId
            || existing.externalIssueURL == metadata.externalIssueURL
            || (existing.externalIssueNumber != nil && existing.externalIssueNumber == metadata.externalIssueNumber)
    }

    private func applyGitHubWebhook(
        event: String,
        deliveryId: String,
        body: Data,
        projects: [ProjectRecord]
    ) async {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        for var project in projects {
            var changed = false
            if event == "issues", let issue = object["issue"] as? [String: Any] {
                changed = applyGitHubIssue(issue, to: &project) || changed
            } else if event == "issue_comment",
                      let issue = object["issue"] as? [String: Any],
                      let comment = object["comment"] as? [String: Any] {
                changed = applyGitHubIssue(issue, to: &project) || changed
                changed = importGitHubComment(comment, issue: issue, project: project) || changed
            } else if event == "projects_v2_item" {
                project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "received", message: "Project item webhook received.", checkedAt: Date())
                changed = true
            }
            if changed {
                project.taskSyncSettings.webhook.lastDeliveryId = deliveryId
                project.taskSyncSettings.webhook.lastReceivedAt = Date()
                project.updatedAt = Date()
                await store.saveProject(project)
                await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
            }
        }
    }

    private func applyGitHubIssue(_ issue: [String: Any], to project: inout ProjectRecord) -> Bool {
        let issueId = issue["node_id"] as? String ?? (issue["id"] as? NSNumber)?.stringValue
        let issueURL = issue["html_url"] as? String
        let issueNumber = (issue["number"] as? NSNumber)?.intValue
        guard let index = project.tasks.firstIndex(where: { task in
            let external = task.externalMetadata
            return external?.externalIssueId == issueId
                || external?.externalIssueURL == issueURL
                || (issueNumber != nil && external?.externalIssueNumber == issueNumber)
        }) else {
            return false
        }
        if let title = issue["title"] as? String {
            project.tasks[index].title = title
        }
        if let body = issue["body"] as? String {
            project.tasks[index].description = body
        }
        if (issue["state"] as? String) == "closed" {
            project.tasks[index].status = ProjectTaskStatus.done.rawValue
        }
        var external = project.tasks[index].externalMetadata ?? TaskExternalMetadata(providerId: "github")
        external.externalIssueId = issueId
        external.externalIssueNumber = issueNumber
        external.externalIssueURL = issueURL
        external.origin = "github"
        external.syncState = "synced"
        external.lastSyncedAt = Date()
        project.tasks[index].externalMetadata = external
        project.tasks[index].tags = Array(Set(project.tasks[index].tags + ["github", "sloppy:\(project.id)"])).sorted()
        project.tasks[index].updatedAt = Date()
        return true
    }

    private func importGitHubComment(
        _ comment: [String: Any],
        issue: [String: Any],
        project: ProjectRecord
    ) -> Bool {
        let issueId = issue["node_id"] as? String ?? (issue["id"] as? NSNumber)?.stringValue
        let issueURL = issue["html_url"] as? String
        let issueNumber = (issue["number"] as? NSNumber)?.intValue
        guard let task = project.tasks.first(where: { task in
            let external = task.externalMetadata
            return external?.externalIssueId == issueId
                || external?.externalIssueURL == issueURL
                || (issueNumber != nil && external?.externalIssueNumber == issueNumber)
        }) else {
            return false
        }
        let commentId = (comment["id"] as? NSNumber)?.stringValue
        var comments = (try? JSONDecoder().decode([TaskComment].self, from: Data(contentsOf: taskCommentsFileURL(projectID: project.id, taskID: task.id)))) ?? []
        guard !comments.contains(where: { $0.externalMetadata?.externalCommentId == commentId }) else {
            return false
        }
        let user = (comment["user"] as? [String: Any])?["login"] as? String
        comments.append(TaskComment(
            id: UUID().uuidString,
            taskId: task.id,
            content: comment["body"] as? String ?? "",
            authorActorId: "github",
            externalMetadata: TaskExternalMetadata(
                providerId: "github",
                externalIssueId: issueId,
                externalIssueNumber: issueNumber,
                externalIssueURL: issueURL,
                externalCommentId: commentId,
                origin: "github",
                syncState: "synced",
                lastSyncedAt: Date()
            ),
            sourceAuthor: user,
            createdAt: Date()
        ))
        saveTaskComments(comments, projectID: project.id, taskID: task.id)
        return true
    }
}

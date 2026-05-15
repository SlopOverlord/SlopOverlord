import Foundation
import AgentRuntime
import Protocols
import Logging

private extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let dict) = self { return dict }
        return [:]
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

func sessionToolRoots(forWorkingDirectory workingDirectory: String) -> [String] {
    let workURL = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
    var roots = [workURL.path]

    let worktreesDir = workURL.deletingLastPathComponent()
    if worktreesDir.lastPathComponent == ".sloppy-worktrees" {
        let repoRoot = worktreesDir.deletingLastPathComponent().standardizedFileURL.path
        if repoRoot != "/" && !repoRoot.isEmpty {
            roots.append(repoRoot)
        }
    }

    var seen = Set<String>()
    return roots.filter { root in
        seen.insert(root).inserted
    }
}

// MARK: - Task Lifecycle

extension CoreService {
    func handleTaskBecameReady(projectID: String, taskID: String) async {
        await waitForStartup()

        guard var project = await store.project(id: projectID),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            return
        }

        var task = project.tasks[taskIndex]
        guard task.status == ProjectTaskStatus.ready.rawValue else {
            return
        }

        _ = await triggerVisorBulletin()
        logger.info(
            "visor.task.approved",
            metadata: [
                "project_id": .string(projectID),
                "task_id": .string(taskID),
                "source": .string("status_ready")
            ]
        )

        let workers = await runtime.workerSnapshots()
        let hasActiveWorker = workers.contains { snapshot in
            snapshot.taskId == task.id &&
            (snapshot.status == .queued || snapshot.status == .running || snapshot.status == .waitingInput)
        }
        guard !hasActiveWorker else {
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "already_running",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: workers.first(where: { $0.taskId == task.id })?.workerId,
                message: "Skipped auto-delegation because task already has an active worker."
            )
            return
        }

        let delegation: TaskDelegation?
        if task.swarmId != nil, let swarmTaskId = task.swarmTaskId, swarmTaskId != "root" {
            delegation = await resolveSwarmTaskDelegation(project: project, task: task)
        } else {
            delegation = await resolveTaskDelegation(project: project, task: task)
        }
        guard let delegation else {
            let blockedMessage = "Task \(task.id) is ready but no eligible actor route was resolved."
            if let channelID = resolveExecutionChannelID(project: project, task: task) {
                await runtime.appendSystemMessage(channelId: channelID, content: blockedMessage)
            }
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "route_blocked",
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                message: blockedMessage
            )
            return
        }

        if await startSwarmIfHierarchical(projectID: project.id, taskID: task.id, delegation: delegation) {
            return
        }

        task.claimedActorId = delegation.actorID
        task.claimedAgentId = delegation.agentID
        if let actorID = delegation.actorID {
            task.actorId = actorID
        }
        let routeUpdate = recordAutonomousRoute(
            task: task,
            actorID: delegation.actorID,
            agentID: delegation.agentID,
            reason: "delegate",
            settings: project.reviewSettings
        )
        task = routeUpdate.task
        if let blockedMessage = routeUpdate.blockedMessage {
            await persistAutonomousRouteBlock(
                project: project,
                taskIndex: taskIndex,
                task: task,
                previousStatus: task.status,
                message: blockedMessage,
                channelID: delegation.channelID,
                workerID: nil,
                actorID: delegation.actorID,
                agentID: delegation.agentID
            )
            return
        }

        var worktreePath: String?
        if let repoPath = project.repoPath,
           project.reviewSettings.enabled,
           task.worktreeBranch == nil {
            do {
                let result = try await createOrReclaimWorktree(repoPath: repoPath, taskId: task.id)
                task.worktreeBranch = result.branchName
                worktreePath = result.worktreePath
            } catch {
                logger.warning(
                    "visor.task.worktree_failed",
                    metadata: [
                        "project_id": .string(projectID),
                        "task_id": .string(taskID),
                        "error": .string(error.localizedDescription)
                    ]
                )
                appendTaskLifecycleLog(
                    projectID: projectID,
                    taskID: taskID,
                    stage: "worktree_failed",
                    channelID: resolveExecutionChannelID(project: project, task: task),
                    workerID: nil,
                    message: "Worktree creation failed: \(error.localizedDescription). Proceeding without worktree."
                )
            }
        } else if task.worktreeBranch != nil {
            if let repoPath = project.repoPath {
                worktreePath = gitWorktreeService.worktreePath(repoPath: repoPath, taskId: task.id)
            }
        }

        let prevStatusForLog = task.status
        task.status = ProjectTaskStatus.inProgress.rawValue
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevStatusForLog, to: task.status, source: "system")

        let effectiveWorkingDirectory = worktreePath ?? project.repoPath
        let workerMode: WorkerMode = task.kind == .planning ? .interactive : .fireAndForget
        let workerObjective = buildWorkerObjective(task: task, project: project, worktreePath: worktreePath)
        let workerId = await runtime.createWorker(
            spec: WorkerTaskSpec(
                taskId: task.id,
                channelId: delegation.channelID,
                title: task.title,
                objective: workerObjective,
                agentID: delegation.agentID,
                tools: ["shell", "file", "exec", "browser"],
                mode: workerMode,
                workingDirectory: effectiveWorkingDirectory,
                selectedModel: {
                    let t = task.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return t.isEmpty ? nil : t
                }()
            )
        )

        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: "worker_spawned",
            channelID: delegation.channelID,
            workerID: workerId,
            message: "Task delegated.",
            actorID: delegation.actorID,
            agentID: delegation.agentID
        )

        logger.info(
            "visor.task.worker_spawned",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id),
                "worker_id": .string(workerId),
                "channel_id": .string(delegation.channelID),
                "agent_id": .string(delegation.agentID ?? "none")
            ]
        )
        // Build a descriptive spawn message including agent/actor details and log path.
        let delegateMessage: String
        if let agentID = delegation.agentID {
            delegateMessage = "Task \(task.id) delegated to agent \(agentID)."
        } else if let actorID = delegation.actorID {
            delegateMessage = "Task \(task.id) delegated to actor \(actorID)."
        } else {
            delegateMessage = "Task \(task.id) started in channel \(delegation.channelID)."
        }
        let logsPath = projectTaskLogFileURL(projectID: project.id, taskID: task.id).path
        let spawnMessage = "\(delegateMessage) Logs: \(logsPath)"
        await runtime.appendSystemMessage(
            channelId: delegation.channelID,
            content: spawnMessage
        )
        await deliverToChannelPlugin(
            channelId: delegation.channelID,
            content: spawnMessage
        )
    }

    func resolveExecutionChannelID(project: ProjectRecord, task: ProjectTask) -> String? {
        if let markedChannelID = extractOriginChannelID(from: task.description),
           project.channels.contains(where: { $0.channelId == markedChannelID }) {
            return markedChannelID
        }
        return project.channels.sorted(by: { $0.createdAt < $1.createdAt }).first?.channelId
    }

    struct AutonomousRouteUpdate {
        var task: ProjectTask
        var blockedMessage: String?
    }

    func recordAutonomousRoute(
        task: ProjectTask,
        actorID: String?,
        agentID: String?,
        reason: String,
        settings: ProjectReviewSettings
    ) -> AutonomousRouteUpdate {
        let normalizedActorID = normalizeWhitespace(actorID ?? "")
        let normalizedAgentID = normalizeWhitespace(agentID ?? "")
        let routeIdentity: String?
        if !normalizedActorID.isEmpty {
            routeIdentity = "actor:\(normalizedActorID)"
        } else if !normalizedAgentID.isEmpty {
            routeIdentity = "agent:\(normalizedAgentID)"
        } else {
            routeIdentity = nil
        }

        guard let routeIdentity else {
            return AutonomousRouteUpdate(task: task, blockedMessage: nil)
        }

        var task = task
        if let last = task.routeHistory.last,
           autonomousRouteIdentity(actorID: last.actorId, agentID: last.agentId) == routeIdentity {
            return AutonomousRouteUpdate(task: task, blockedMessage: nil)
        }

        let step = ProjectTaskRouteStep(
            actorId: normalizedActorID.isEmpty ? nil : normalizedActorID,
            agentId: normalizedAgentID.isEmpty ? nil : normalizedAgentID,
            reason: normalizeWhitespace(reason).isEmpty ? "delegate" : normalizeWhitespace(reason)
        )
        let previousHistory = task.routeHistory
        task.routeHistory.append(step)

        let path = autonomousRoutePath(task.routeHistory)
        if previousHistory.contains(where: {
            autonomousRouteIdentity(actorID: $0.actorId, agentID: $0.agentId) == routeIdentity
        }) {
            return AutonomousRouteUpdate(
                task: task,
                blockedMessage: "Autonomous routing loop detected: \(path). Human intervention required."
            )
        }

        let maxRouteSteps = max(1, settings.maxAutonomousRouteSteps)
        if previousHistory.count >= maxRouteSteps {
            return AutonomousRouteUpdate(
                task: task,
                blockedMessage: "Autonomous route limit reached (\(maxRouteSteps) steps): \(path). Human intervention required."
            )
        }

        return AutonomousRouteUpdate(task: task, blockedMessage: nil)
    }

    func autonomousRouteIdentity(actorID: String?, agentID: String?) -> String? {
        let normalizedActorID = normalizeWhitespace(actorID ?? "")
        if !normalizedActorID.isEmpty {
            return "actor:\(normalizedActorID)"
        }
        let normalizedAgentID = normalizeWhitespace(agentID ?? "")
        if !normalizedAgentID.isEmpty {
            return "agent:\(normalizedAgentID)"
        }
        return nil
    }

    func autonomousRoutePath(_ history: [ProjectTaskRouteStep]) -> String {
        let labels = history.map { step in
            if let actorID = step.actorId, !actorID.isEmpty {
                return actorID
            }
            if let agentID = step.agentId, !agentID.isEmpty {
                return "agent:\(agentID)"
            }
            return "unknown"
        }
        return labels.isEmpty ? "(empty)" : labels.joined(separator: " -> ")
    }

    func persistAutonomousRouteBlock(
        project: ProjectRecord,
        taskIndex: Int,
        task: ProjectTask,
        previousStatus: String,
        message: String,
        channelID: String?,
        workerID: String?,
        actorID: String?,
        agentID: String?,
        artifactPath: String? = nil
    ) async {
        var project = project
        var task = task
        task.status = ProjectTaskStatus.blocked.rawValue
        task.updatedAt = Date()
        let note = "Autonomous route blocked: \(message)"
        if task.description.isEmpty {
            task.description = note
        } else if !task.description.contains(note) {
            task.description += "\n\n\(note)"
        }
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
        await recordSystemStatusChange(
            projectID: project.id,
            taskID: task.id,
            from: previousStatus,
            to: task.status,
            source: "system"
        )
        appendTaskLifecycleLog(
            projectID: project.id,
            taskID: task.id,
            stage: "loop_guard_blocked",
            channelID: channelID,
            workerID: workerID,
            message: message,
            actorID: actorID,
            agentID: agentID,
            artifactPath: artifactPath
        )
        if let channelID {
            let statusMessage = "Task \(task.id) blocked: \(message)"
            await runtime.appendSystemMessage(channelId: channelID, content: statusMessage)
            await deliverToChannelPlugin(channelId: channelID, content: statusMessage)
        }
        logger.warning(
            "visor.task.loop_guard_blocked",
            metadata: [
                "project_id": .string(project.id),
                "task_id": .string(task.id),
                "message": .string(message)
            ]
        )
    }

    /// Stops background tasks and waits for pending work.
    func handleReviewHandoff(
        project: ProjectRecord,
        task: ProjectTask,
        taskIndex: Int,
        handoffDelegate: TeamRetryDelegate,
        event: EventEnvelope,
        completionArtifactPath: String?
    ) async {
        var project = project
        var task = task
        let prevReviewStatus = task.status

        let approvalMode = project.reviewSettings.approvalMode
        let reviewerChannelID = handoffDelegate.agentID.map { "agent:\($0)" }
            ?? event.channelId

        switch approvalMode {
        case .auto:
            task.status = ProjectTaskStatus.needsReview.rawValue
            task.claimedActorId = handoffDelegate.actorID
            task.claimedAgentId = handoffDelegate.agentID
            task.updatedAt = Date()
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
            await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevReviewStatus, to: task.status, source: "system")
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "review_auto",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Auto-approving task.",
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID
            )
            try? await approveTask(projectID: project.id, taskID: task.id)

        case .human:
            task.status = ProjectTaskStatus.needsReview.rawValue
            task.claimedActorId = handoffDelegate.actorID
            task.claimedAgentId = handoffDelegate.agentID
            task.updatedAt = Date()
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
            await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevReviewStatus, to: task.status, source: "system")
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "review_human",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Awaiting human review.",
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID,
                artifactPath: completionArtifactPath
            )
            let reviewMessage = "Task \(task.id) is ready for review. Approve or reject via the dashboard."
            await runtime.appendSystemMessage(channelId: event.channelId, content: reviewMessage)
            await deliverToChannelPlugin(channelId: event.channelId, content: reviewMessage)

        case .agent:
            let diff: String
            if let repoPath = project.repoPath, let branchName = task.worktreeBranch {
                let baseBranch = (try? await gitWorktreeService.defaultBranch(repoPath: repoPath)) ?? "main"
                diff = (try? await gitWorktreeService.branchDiff(repoPath: repoPath, branchName: branchName, baseBranch: baseBranch)) ?? "Diff unavailable."
            } else {
                diff = "No worktree branch available."
            }
            let reviewObjective = buildReviewObjective(task: task, projectID: project.id, diff: diff)
            task.status = ProjectTaskStatus.needsReview.rawValue
            task.claimedActorId = handoffDelegate.actorID
            task.claimedAgentId = handoffDelegate.agentID
            task.updatedAt = Date()
            project.tasks[taskIndex] = task
            project.updatedAt = Date()
            await store.saveProject(project)
            await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: project.id, task: task))
            await recordSystemStatusChange(projectID: project.id, taskID: task.id, from: prevReviewStatus, to: task.status, source: handoffDelegate.agentID ?? "system")
            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: task.id,
                stage: "review_agent",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Delegated to reviewer agent.",
                actorID: handoffDelegate.actorID,
                agentID: handoffDelegate.agentID,
                artifactPath: completionArtifactPath
            )
            _ = await runtime.createWorker(
                spec: WorkerTaskSpec(
                    taskId: task.id,
                    channelId: reviewerChannelID,
                    title: "Review: \(task.title)",
                    objective: reviewObjective,
                    tools: ["shell", "file"],
                    mode: .fireAndForget
                )
            )
        }
    }

    func buildReviewObjective(task: ProjectTask, projectID: String, diff: String) -> String {
        return normalizeTaskDescription([
            "Review task: \(task.title)",
            "",
            "Original task description:",
            task.description.isEmpty ? "(none)" : task.description,
            "",
            "Changes to review (git diff):",
            diff,
            "",
            "Review instructions:",
            "- Evaluate whether the changes correctly and completely implement the task.",
            "- If the changes are acceptable, call the approve tool.",
            "- If the changes need work, call the reject tool with specific reasons."
        ].joined(separator: "\n"))
    }

    public func approveTask(projectID: String, taskID: String) async throws {
        let projects = await store.listProjects()
        guard var project = projects.first(where: { $0.id == projectID }),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            throw ProjectError.notFound
        }
        var task = project.tasks[taskIndex]
        let prevApproveStatus = task.status

        if let repoPath = project.repoPath, let branchName = task.worktreeBranch {
            let targetBranch = (try? await gitWorktreeService.defaultBranch(repoPath: repoPath)) ?? "main"
            try await gitWorktreeService.mergeBranch(repoPath: repoPath, branchName: branchName, targetBranch: targetBranch)
            let worktreePath = gitWorktreeService.worktreePath(repoPath: repoPath, taskId: taskID)
            try? await gitWorktreeService.removeWorktree(repoPath: repoPath, worktreePath: worktreePath)
        }

        task.status = ProjectTaskStatus.done.rawValue
        task.routeHistory = []
        task.worktreeBranch = nil
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: projectID, task: task))
        await recordSystemStatusChange(projectID: projectID, taskID: taskID, from: prevApproveStatus, to: task.status, source: "user")
        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: taskID,
            stage: "approved",
            channelID: nil,
            workerID: nil,
            message: "Task approved and merged."
        )
        logger.info("visor.task.approved", metadata: ["project_id": .string(projectID), "task_id": .string(taskID)])
    }

    public func getTaskDiff(projectID: String, taskID: String) async throws -> TaskDiffResponse {
        let projects = await store.listProjects()
        guard let project = projects.first(where: { $0.id == projectID }),
              let task = project.tasks.first(where: { $0.id == taskID })
        else {
            throw ProjectError.notFound
        }

        guard let repoPath = project.repoPath else {
            return TaskDiffResponse(diff: "", branchName: "", baseBranch: "", hasChanges: false)
        }

        if let branchName = task.worktreeBranch {
            let baseBranch = (try? await gitWorktreeService.defaultBranch(repoPath: repoPath)) ?? "main"
            let diff = (try? await gitWorktreeService.branchDiff(repoPath: repoPath, branchName: branchName, baseBranch: baseBranch)) ?? ""
            return TaskDiffResponse(diff: diff, branchName: branchName, baseBranch: baseBranch, hasChanges: !diff.isEmpty)
        }

        // Fallback: when a task is in review but no dedicated worktree exists, surface the project's working-tree diff.
        // This is less precise than a task-scoped worktree diff, but it prevents "no diff" when changes were made directly on the repo.
        if task.status == ProjectTaskStatus.needsReview.rawValue, gitWorktreeService.isGitWorkingCopy(repoPath: repoPath) {
            let worktreePath = gitWorktreeService.worktreePath(repoPath: repoPath, taskId: taskID)
            if gitWorktreeService.isGitWorkingCopy(repoPath: worktreePath) {
                let label = (try? await gitWorktreeService.currentBranchLabel(repoPath: worktreePath)) ?? ""
                let patch = (try? await gitWorktreeService.workingTreePatch(repoPath: worktreePath, maxBytes: 512 * 1024)) ?? (text: "", truncated: false)
                let branchName = label.isEmpty ? "worktree (working-tree)" : "\(label) (working-tree)"
                return TaskDiffResponse(diff: patch.text, branchName: branchName, baseBranch: "HEAD", hasChanges: !patch.text.isEmpty)
            }

            let label = (try? await gitWorktreeService.currentBranchLabel(repoPath: repoPath)) ?? ""
            let patch = (try? await gitWorktreeService.workingTreePatch(repoPath: repoPath, maxBytes: 512 * 1024)) ?? (text: "", truncated: false)
            let branchName = label.isEmpty ? "working-tree" : "\(label) (working-tree)"
            return TaskDiffResponse(diff: patch.text, branchName: branchName, baseBranch: "HEAD", hasChanges: !patch.text.isEmpty)
        }

        return TaskDiffResponse(diff: "", branchName: "", baseBranch: "", hasChanges: false)
    }

    public func listReviewComments(projectID: String, taskID: String) async -> [ReviewComment] {
        let url = reviewCommentsFileURL(projectID: projectID, taskID: taskID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ReviewComment].self, from: data)) ?? []
    }

    public func addReviewComment(projectID: String, taskID: String, request: ReviewCommentCreateRequest) async -> ReviewComment {
        var comments = await listReviewComments(projectID: projectID, taskID: taskID)
        let comment = ReviewComment(
            id: UUID().uuidString,
            taskId: taskID,
            filePath: request.filePath,
            lineNumber: request.lineNumber,
            side: request.side,
            content: request.content,
            author: request.author
        )
        comments.append(comment)
        saveReviewComments(comments, projectID: projectID, taskID: taskID)
        return comment
    }

    public func updateReviewComment(projectID: String, taskID: String, commentID: String, request: ReviewCommentUpdateRequest) async -> ReviewComment? {
        var comments = await listReviewComments(projectID: projectID, taskID: taskID)
        guard let index = comments.firstIndex(where: { $0.id == commentID }) else { return nil }
        if let resolved = request.resolved { comments[index].resolved = resolved }
        if let content = request.content { comments[index].content = content }
        saveReviewComments(comments, projectID: projectID, taskID: taskID)
        return comments[index]
    }

    public func deleteReviewComment(projectID: String, taskID: String, commentID: String) async -> Bool {
        var comments = await listReviewComments(projectID: projectID, taskID: taskID)
        let before = comments.count
        comments.removeAll { $0.id == commentID }
        if comments.count == before { return false }
        saveReviewComments(comments, projectID: projectID, taskID: taskID)
        return true
    }

    func reviewCommentsFileURL(projectID: String, taskID: String) -> URL {
        projectMetaDirectoryURL(projectID: projectID)
            .appendingPathComponent("review-comments-\(taskID).json")
    }

    func saveReviewComments(_ comments: [ReviewComment], projectID: String, taskID: String) {
        ensureProjectWorkspaceDirectory(projectID: projectID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(comments) else { return }
        let url = reviewCommentsFileURL(projectID: projectID, taskID: taskID)
        try? data.write(to: url, options: .atomic)
    }

    public func rejectTask(projectID: String, taskID: String, reason: String?) async throws {
        let projects = await store.listProjects()
        guard var project = projects.first(where: { $0.id == projectID }),
              let taskIndex = project.tasks.firstIndex(where: { $0.id == taskID })
        else {
            throw ProjectError.notFound
        }
        var task = project.tasks[taskIndex]
        let prevRejectStatus = task.status

        if let reason, !reason.isEmpty {
            let rejectionNote = "Review rejected: \(reason)"
            if task.description.isEmpty {
                task.description = rejectionNote
            } else {
                task.description += "\n\n\(rejectionNote)"
            }
        }

        let board = try? getActorBoard()
        let nodesByID = Dictionary(uniqueKeysWithValues: (board?.nodes ?? []).map { ($0.id, $0) })
        var developerActorID: String?
        var developerAgentID: String?
        if let teamID = task.teamId,
           let team = board?.teams.first(where: { $0.id == teamID }) {
            for memberID in team.memberActorIds {
                if let node = nodesByID[memberID], node.systemRole == .developer {
                    developerActorID = memberID
                    developerAgentID = node.linkedAgentId
                    break
                }
            }
        }

        task.status = ProjectTaskStatus.ready.rawValue
        task.claimedActorId = developerActorID ?? task.claimedActorId
        task.claimedAgentId = developerAgentID ?? task.claimedAgentId
        if let developerActorID {
            task.actorId = developerActorID
        }
        let routeUpdate = recordAutonomousRoute(
            task: task,
            actorID: task.claimedActorId,
            agentID: task.claimedAgentId,
            reason: "review_reject",
            settings: project.reviewSettings
        )
        task = routeUpdate.task
        if let blockedMessage = routeUpdate.blockedMessage {
            await persistAutonomousRouteBlock(
                project: project,
                taskIndex: taskIndex,
                task: task,
                previousStatus: prevRejectStatus,
                message: blockedMessage,
                channelID: resolveExecutionChannelID(project: project, task: task),
                workerID: nil,
                actorID: task.claimedActorId,
                agentID: task.claimedAgentId
            )
            return
        }
        task.updatedAt = Date()
        project.tasks[taskIndex] = task
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .taskUpdated, projectId: projectID, task: task))
        await recordSystemStatusChange(projectID: projectID, taskID: taskID, from: prevRejectStatus, to: task.status, source: "user")
        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: taskID,
            stage: "rejected",
            channelID: nil,
            workerID: nil,
            message: "Task rejected. Returning to developer."
        )
        logger.info("visor.task.rejected", metadata: ["project_id": .string(projectID), "task_id": .string(taskID)])
        await handleTaskBecameReady(projectID: projectID, taskID: taskID)
    }

    func syncTaskProgressFromWorkerEvent(event: EventEnvelope) async {
        guard let taskID = event.taskId else {
            return
        }
        let progress = event.payload.objectValue["progress"]?.stringValue ?? "progress"

        let projects = await store.listProjects()
        for project in projects {
            guard project.tasks.contains(where: { $0.id == taskID }) else {
                continue
            }

            appendTaskLifecycleLog(
                projectID: project.id,
                taskID: taskID,
                stage: "worker_progress",
                channelID: event.channelId,
                workerID: event.workerId,
                message: progress
            )
            logger.info(
                "visor.task.progress",
                metadata: [
                    "project_id": .string(project.id),
                    "task_id": .string(taskID),
                    "progress": .string(progress)
                ]
            )
            return
        }
    }


    func summarizedTaskTitle(from value: String) -> String {
        let normalized = normalizeWhitespace(value)
        if normalized.isEmpty {
            return "Visor task"
        }

        let separators = CharacterSet(charactersIn: "\n.;:")
        if let splitRange = normalized.rangeOfCharacter(from: separators) {
            let prefix = normalizeWhitespace(String(normalized[..<splitRange.lowerBound]))
            if prefix.count >= 6 {
                return String(prefix.prefix(120))
            }
        }

        return String(normalized.prefix(120))
    }

    func cancelProjectTask(projectID: String, taskID: String, reason: String?) async throws -> ProjectRecord {
        let note = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2_000)
        let normalizedNote = note.map(String.init)
        let update = ProjectTaskUpdateRequest(status: ProjectTaskStatus.cancelled.rawValue)
        _ = try await updateProjectTask(projectID: projectID, taskID: taskID, request: update)

        guard let normalizedProject = normalizedProjectID(projectID),
              var storedProject = await store.project(id: normalizedProject)
        else {
            throw ProjectError.notFound
        }
        guard let index = storedProject.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw ProjectError.notFound
        }

        var task = storedProject.tasks[index]
        if let normalizedNote, !normalizedNote.isEmpty {
            let line = "Cancelled: \(normalizedNote)"
            if task.description.isEmpty {
                task.description = line
            } else {
                task.description += "\n\n\(line)"
            }
        }
        task.updatedAt = Date()
        storedProject.tasks[index] = task
        storedProject.updatedAt = Date()
        await store.saveProject(storedProject)
        return storedProject
    }

    func runAgentTask(
        agentID: String,
        taskID: String,
        objective: String,
        workingDirectory: String?,
        selectedModel: String? = nil
    ) async -> String? {
        await runSubagentTask(
            agentID: agentID,
            taskID: taskID,
            objective: objective,
            workingDirectory: workingDirectory,
            toolsetNames: nil,
            selectedModel: selectedModel
        )
    }

    /// Runs a one-shot agent session with optional toolset restriction and subagent deny rules.
    func runSubagentTask(
        agentID: String,
        taskID: String,
        objective: String,
        workingDirectory: String?,
        toolsetNames: [String]?,
        selectedModel: String? = nil,
        parentSessionID: String? = nil
    ) async -> String? {
        let knownIDs = await ToolCatalog.knownToolIDs(mcpRegistry: mcpRegistry)
        guard let policy = try? await toolsAuthorization.policy(agentID: agentID) else {
            logger.warning(
                "task.subagent.policy_failed",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID)]
            )
            return nil
        }
        let effectiveTools = SubagentDelegation.effectiveToolIDs(
            policy: policy,
            knownToolIDs: knownIDs,
            toolsetNames: toolsetNames
        )
        guard !effectiveTools.isEmpty else {
            logger.warning(
                "task.subagent.no_tools",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID)]
            )
            return nil
        }

        let sessionTitle = "task-\(taskID)"
        let existingSession: AgentSessionSummary? = try? listAgentSessions(agentID: agentID)
            .first(where: { $0.title == sessionTitle })

        if let stale = existingSession {
            try? await deleteAgentSession(agentID: agentID, sessionID: stale.id)
        }

        let session: AgentSessionSummary
        do {
            session = try await createAgentSession(
                agentID: agentID,
                request: AgentSessionCreateRequest(title: sessionTitle, parentSessionId: parentSessionID)
            )
            await appendSubagentSessionTaskCommentIfNeeded(agentID: agentID, taskID: taskID, session: session)
        } catch {
            logger.warning(
                "task.worker.session_create_failed",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID), "error": .string(error.localizedDescription)]
            )
            return nil
        }

        if let parentSessionID = parentSessionID.flatMap(normalizedSessionID) {
            let event = AgentSessionEvent(
                agentId: agentID,
                sessionId: parentSessionID,
                type: .subSession,
                subSession: AgentSubSessionEvent(
                    childSessionId: session.id,
                    title: session.title
                )
            )
            _ = try? await appendAgentSessionEvents(
                agentID: agentID,
                sessionID: parentSessionID,
                request: AgentSessionAppendEventsRequest(events: [event])
            )
        }

        let inheritedContext = await subagentToolContext(
            agentID: agentID,
            parentSessionID: parentSessionID,
            fallbackWorkingDirectory: workingDirectory
        )
        if let workingDirectory = inheritedContext.workingDirectory,
           !workingDirectory.isEmpty {
            sessionWorkingDirectories[session.id] = workingDirectory
        }
        if !inheritedContext.extraRoots.isEmpty {
            sessionExtraRoots[session.id] = inheritedContext.extraRoots
        }

        let channelId = sessionChannelID(agentID: agentID, sessionID: session.id)
        sessionSubagentToolAllowList[session.id] = effectiveTools
        await runtime.setChannelToolAllowList(channelId: channelId, toolIDs: effectiveTools)

        let response: AgentSessionMessageResponse
        do {
            response = try await postAgentSessionMessage(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionPostMessageRequest(
                    userId: "system_task_worker",
                    content: delegatedTaskObjective(objective),
                    selectedModel: {
                        let t = selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return t.isEmpty ? nil : t
                    }()
                )
            )
        } catch {
            logger.warning(
                "task.worker.session_post_failed",
                metadata: ["agent_id": .string(agentID), "task_id": .string(taskID), "error": .string(error.localizedDescription)]
            )
            sessionSubagentToolAllowList.removeValue(forKey: session.id)
            await runtime.clearChannelToolAllowList(channelId: channelId)
            await runtime.invalidateChannelSession(channelId: channelId)
            return nil
        }

        let detail = try? getAgentSession(agentID: agentID, sessionID: session.id)
        var resultEvents = detail?.events ?? response.appendedEvents
        if latestDelegateFinishSummary(from: resultEvents) == nil,
           let syntheticFinish = syntheticDelegateFinishEvent(
               agentID: agentID,
               sessionID: session.id,
               from: resultEvents
           ) {
            _ = try? await appendAgentSessionEvents(
                agentID: agentID,
                sessionID: session.id,
                request: AgentSessionAppendEventsRequest(events: [syntheticFinish])
            )
            resultEvents.append(syntheticFinish)
        }
        let text = delegatedTaskResultText(from: resultEvents)
        sessionSubagentToolAllowList.removeValue(forKey: session.id)
        await runtime.clearChannelToolAllowList(channelId: channelId)
        await runtime.invalidateChannelSession(channelId: channelId)
        return text
    }

    func appendSubagentSessionTaskCommentIfNeeded(
        agentID: String,
        taskID: String,
        session: AgentSessionSummary
    ) async {
        let projects = await store.listProjects()
        guard let project = projects.first(where: { project in
            project.tasks.contains(where: { $0.id == taskID })
        }) else {
            return
        }

        let sessionURL = "/agents/\(dashboardPathComponent(agentID))/chat/\(dashboardPathComponent(session.id))"
        let sessionName = session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? session.id
            : session.title
        _ = await addTaskComment(
            projectID: project.id,
            taskID: taskID,
            request: TaskCommentCreateRequest(
                content: "Task delegated to subagent session [\(sessionName)](\(sessionURL)).",
                authorActorId: "system"
            )
        )
    }

    func subagentToolContext(
        agentID: String,
        parentSessionID: String?,
        fallbackWorkingDirectory: String?
    ) async -> (workingDirectory: String?, extraRoots: [String]) {
        var workingDirectory: String?
        var roots: [String] = []

        if let parentSessionID = parentSessionID.flatMap(normalizedSessionID) {
            if let parentRoots = sessionExtraRoots[parentSessionID] {
                workingDirectory = sessionWorkingDirectories[parentSessionID]
                roots = parentRoots
            } else if let detail = try? getAgentSession(agentID: agentID, sessionID: parentSessionID) {
                let parentContext = await toolContextForSession(
                    sessionID: parentSessionID,
                    sessionTitle: detail.summary.title,
                    projectID: detail.summary.projectId
                )
                workingDirectory = parentContext.workingDirectory
                roots = parentContext.extraRoots
            }
        }

        if let fallback = fallbackWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            let normalizedFallback = URL(fileURLWithPath: fallback, isDirectory: true).standardizedFileURL.path
            if workingDirectory == nil {
                workingDirectory = normalizedFallback
            }
            roots = appendingUniqueRoots(
                sessionToolRoots(forWorkingDirectory: normalizedFallback),
                to: roots
            )
        }

        return (workingDirectory, roots)
    }

    private func delegatedTaskObjective(_ objective: String) -> String {
        """
        [Delegated task protocol]
        You are running as an isolated delegated subagent. When the assigned goal is complete, blocked, or failed, call `agent_delegate.finish` as your final step.
        - Use `status: "completed"` only when you have completed the task and can summarize evidence.
        - Use `status: "failed"` when an error prevents completion.
        - Use `status: "blocked"` when required information, permissions, or tools are missing.
        - Include a concise `summary`; include `error` for failed or blocked outcomes.
        Do not delegate again and do not finish with only a plain text promise.

        \(objective)
        """
    }

    func delegatedTaskResultText(from events: [AgentSessionEvent]) -> String {
        latestDelegateFinishSummary(from: events)
            ?? syntheticDelegateFinishSummary(from: events)
            ?? "[failed] Delegated subagent ended before calling `agent_delegate.finish`.\nError: The subagent ended without a structured delegated-task result."
    }

    private func latestDelegateFinishSummary(from events: [AgentSessionEvent]) -> String? {
        for event in events.reversed() {
            guard event.type == .toolResult,
                  let result = event.toolResult,
                  result.ok,
                  result.tool == "agent_delegate.finish" || result.tool == "agents.delegate_finish",
                  let data = result.data?.asObject,
                  data["finished"]?.asBool == true,
                  let status = data["status"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let summary = data["summary"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty,
                  !summary.isEmpty
            else {
                continue
            }

            let error = data["error"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let error, !error.isEmpty {
                return "[\(status)] \(summary)\nError: \(error)"
            }
            return "[\(status)] \(summary)"
        }
        return nil
    }

    private func syntheticDelegateFinishSummary(from events: [AgentSessionEvent]) -> String? {
        guard let outcome = syntheticDelegateFinishOutcome(from: events) else {
            return nil
        }
        return "[failed] \(outcome.summary)\nError: \(outcome.error)"
    }

    private func syntheticDelegateFinishEvent(
        agentID: String,
        sessionID: String,
        from events: [AgentSessionEvent]
    ) -> AgentSessionEvent? {
        guard let outcome = syntheticDelegateFinishOutcome(from: events) else {
            return nil
        }
        return AgentSessionEvent(
            agentId: agentID,
            sessionId: sessionID,
            type: .toolResult,
            toolResult: AgentToolResultEvent(
                tool: "agent_delegate.finish",
                ok: true,
                data: .object([
                    "finished": .bool(true),
                    "status": .string("failed"),
                    "summary": .string(outcome.summary),
                    "error": .string(outcome.error),
                    "synthetic": .bool(true),
                ])
            )
        )
    }

    private func syntheticDelegateFinishOutcome(from events: [AgentSessionEvent]) -> (summary: String, error: String)? {
        guard let status = events.reversed().compactMap(\.runStatus).first(where: {
            $0.stage == .done || $0.stage == .interrupted
        }) else {
            return nil
        }

        let details = status.details?.trimmingCharacters(in: .whitespacesAndNewlines)
        let error: String
        if let details, !details.isEmpty {
            error = details
        } else {
            error = "The subagent ended without a structured delegated-task result."
        }

        switch status.stage {
        case .interrupted:
            return ("Delegated subagent ended before calling `agent_delegate.finish`.", error)
        case .done:
            return ("Delegated subagent completed without calling `agent_delegate.finish`.", error)
        default:
            return nil
        }
    }

    private func appendingUniqueRoots(_ additions: [String], to existing: [String]) -> [String] {
        var result = existing
        for root in additions {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
            if !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    func createOrReclaimWorktree(repoPath: String, taskId: String) async throws -> GitWorktreeResult {
        do {
            return try await gitWorktreeService.createWorktree(repoPath: repoPath, taskId: taskId)
        } catch GitWorktreeError.worktreeAlreadyExists(let existingPath) {
            try? await gitWorktreeService.removeWorktree(repoPath: repoPath, worktreePath: existingPath)
            return try await gitWorktreeService.createWorktree(repoPath: repoPath, taskId: taskId)
        }
    }

    func buildWorkerObjective(task: ProjectTask, project: ProjectRecord, worktreePath: String? = nil) -> String {
        var sections: [String] = []

        // --- Task ---
        var taskLines: [String] = [
            "[Task]",
            "ID: \(task.id)",
            "Title: \(task.title)",
            "Priority: \(task.priority)",
            "Kind: \(task.kind?.rawValue ?? "execution")"
        ]
        if !task.description.isEmpty {
            taskLines.append("")
            taskLines.append(task.description)
        }
        sections.append(taskLines.joined(separator: "\n"))

        // --- Project context ---
        var projectLines: [String] = [
            "[Project]",
            "ID: \(project.id)",
            "Name: \(project.name)"
        ]
        if let repoPath = project.repoPath, !repoPath.isEmpty {
            projectLines.append("Repository: \(repoPath)")
        }
        if !project.description.isEmpty {
            projectLines.append("Description: \(project.description)")
        }
        sections.append(projectLines.joined(separator: "\n"))

        // --- Workspace ---
        var workspaceLines: [String] = ["[Workspace]"]
        if let worktreePath {
            let repoRoot = URL(fileURLWithPath: worktreePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            workspaceLines.append("Working directory: \(worktreePath)")
            workspaceLines.append("Repository root: \(repoRoot)")
            workspaceLines.append("All code changes MUST be made inside this worktree.")
            workspaceLines.append("Commit changes to the worktree branch before completing the task.")
        } else if let repoPath = project.repoPath, !repoPath.isEmpty {
            workspaceLines.append("Working directory: \(repoPath)")
        }
        sections.append(workspaceLines.joined(separator: "\n"))

        // --- Task lifecycle ---
        sections.append("""
        [Task lifecycle]
        Tasks move through these statuses:
        backlog → ready → in_progress → done
        At any point a task can transition to: waiting_input, blocked, needs_review, cancelled.
        - Your task is now in_progress. The system will NOT mark it done automatically.
        - When the task is truly complete, call `project.task_update` with status=`done`, completionConfidence=`done`, and a brief completionNote.
        - If you are missing user input, use the clarification flow below so the task becomes waiting_input.
        - If you are blocked by missing access, dependencies, or an external issue you cannot resolve, call `project.task_update` with status=`blocked`.
        - To update the task status or metadata, use tool `project.task_update`.
        - To create sub-tasks, use tool `project.task_create` with the same project ID.
        """)

        // --- Clarification flow ---
        sections.append("""
        [Clarification flow]
        When you need information from the user before proceeding:
        1. Call tool `project.task_clarification_create` with taskId="\(task.id)" and your question.
           You may include structured options (id + label) and/or allow freeform notes.
        2. After calling the tool, STOP and wait. Do NOT continue working on the task.
           The system will set the task to waiting_input and notify the user.
        3. When the user answers, the system resumes your session with their response.
           You will receive the answer as a follow-up message. Then continue working.
        Ask all related questions in a single clarification call when possible.
        """)

        // --- Mode-specific instructions ---
        if task.kind == .planning {
            sections.append("""
            [Planning mode]
            You are in PLANNING mode. Your goal is to produce a plan, not code.
            1. Read and analyze the task requirements and the project codebase.
            2. If anything is unclear, use the clarification flow above to ask the user.
            3. Produce a structured implementation plan: break the work into concrete sub-tasks.
            4. Create each sub-task via `project.task_create` with kind=execution and status=backlog.
            5. When the plan is complete, summarize what you created and finish.
            Do NOT write implementation code in planning mode.
            """)
        } else if task.kind == .execution || task.kind == nil {
            sections.append("""
            [Execution mode]
            You are in EXECUTION mode. Your goal is to implement the requested changes.
            1. Analyze the task description and explore the relevant parts of the codebase.
            2. If the requirements are ambiguous, use the clarification flow above to ask the user.
            3. Implement the changes: write code, create files, run commands as needed.
            4. Verify your work compiles/passes and meets the task requirements.
            5. If the task is large, break it into logical commits with clear messages.
            Produce working, tested code. Prefer minimal, focused changes over broad rewrites.
            """)
        } else if task.kind == .bugfix {
            sections.append("""
            [Bugfix mode]
            Focus on identifying and fixing the reported issue.
            1. Reproduce or locate the bug in the codebase.
            2. If the bug description is ambiguous, use the clarification flow to ask the user.
            3. Implement the minimal fix and verify it does not introduce regressions.
            """)
        }

        return normalizeTaskDescription(sections.joined(separator: "\n\n"))
    }


    func appendTaskLifecycleLog(
        projectID: String,
        taskID: String,
        stage: String,
        channelID: String?,
        workerID: String?,
        message: String,
        actorID: String? = nil,
        agentID: String? = nil,
        artifactPath: String? = nil
    ) {
        ensureProjectWorkspaceDirectory(projectID: projectID)
        let logURL = projectTaskLogFileURL(projectID: projectID, taskID: taskID)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeStage = normalizeWhitespace(stage)
        let safeMessage = normalizeWhitespace(message)

        var line = "[\(timestamp)] stage=\(safeStage)"
        line += " task=\(taskID)"
        if let channelID, !channelID.isEmpty {
            line += " channel=\(channelID)"
        }
        if let workerID, !workerID.isEmpty {
            line += " worker=\(workerID)"
        }
        if let actorID, !actorID.isEmpty {
            line += " actor=\(actorID)"
        }
        if let agentID, !agentID.isEmpty {
            line += " agent=\(agentID)"
        }
        if let artifactPath, !artifactPath.isEmpty {
            line += " artifact=\(artifactPath)"
        }
        line += " message=\(safeMessage)\n"

        let payload = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                try handle.close()
                return
            } catch {
                logger.warning(
                    "visor.task.log_append_failed",
                    metadata: [
                        "project_id": .string(projectID),
                        "task_id": .string(taskID),
                        "path": .string(logURL.path)
                    ]
                )
            }
        }

        do {
            try payload.write(to: logURL, options: .atomic)
        } catch {
            logger.warning(
                "visor.task.log_write_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "task_id": .string(taskID),
                    "path": .string(logURL.path)
                ]
            )
        }
    }

    func persistWorkerArtifactForProjectTask(
        projectID: String,
        taskID: String,
        event: EventEnvelope
    ) async -> String? {
        guard let artifactID = event.payload.objectValue["artifactId"]?.stringValue,
              !artifactID.isEmpty
        else {
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_missing_id",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Worker completed without artifactId."
            )
            return nil
        }

        let artifactContent: String?
        if let runtimeArtifact = await runtime.artifactContent(id: artifactID) {
            artifactContent = runtimeArtifact
            await store.persistArtifact(id: artifactID, content: runtimeArtifact)
        } else {
            artifactContent = await store.artifactContent(id: artifactID)
        }

        guard let artifactContent, !artifactContent.isEmpty else {
            appendTaskLifecycleLog(
                projectID: projectID,
                taskID: taskID,
                stage: "artifact_missing_content",
                channelID: event.channelId,
                workerID: event.workerId,
                message: "Artifact payload not found for id \(artifactID)."
            )
            return nil
        }

        let referencedPath: String? = extractCreatedFilePath(from: artifactContent).flatMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return relativePathFromWorkspace(url)
        }

        _ = await addTaskComment(
            projectID: projectID,
            taskID: taskID,
            request: TaskCommentCreateRequest(content: artifactContent, authorActorId: "system")
        )

        appendTaskLifecycleLog(
            projectID: projectID,
            taskID: taskID,
            stage: "artifact_persisted",
            channelID: event.channelId,
            workerID: event.workerId,
            message: "Worker artifact stored as task comment.",
            artifactPath: referencedPath
        )
        return referencedPath ?? artifactID
    }

    func extractCreatedFilePath(from content: String) -> String? {
        if let value = captureGroup(
            content,
            pattern: #"(?im)^Created file at\s+(.+?)\s*$"#
        ) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func ensureProjectWorkspaceDirectory(projectID: String) {
        let directories = [
            projectDirectoryURL(projectID: projectID),
            projectMetaDirectoryURL(projectID: projectID)
        ]
        do {
            for directory in directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            logger.warning(
                "visor.project.directory_create_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "path": .string(projectDirectoryURL(projectID: projectID).path)
                ]
            )
        }
    }

    func legacyProjectSourceSymlinkURL(projectID: String) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent("source", isDirectory: true)
    }

    func normalizedExternalProjectPath(_ rawPath: String?) throws -> String? {
        guard let rawPath else {
            return nil
        }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidateURL: URL
        if trimmed.hasPrefix("file://") {
            guard let parsed = URL(string: trimmed),
                  parsed.isFileURL,
                  parsed.host == nil || parsed.host == "" || parsed.host == "localhost",
                  !parsed.path.isEmpty
            else {
                throw ProjectError.invalidPayload
            }
            candidateURL = parsed
        } else {
            guard trimmed.hasPrefix("/") else {
                throw ProjectError.invalidPayload
            }
            candidateURL = URL(fileURLWithPath: trimmed, isDirectory: true)
        }

        let normalizedURL = candidateURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        guard normalizedPath.hasPrefix("/") else {
            throw ProjectError.invalidPayload
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectError.invalidPayload
        }

        return normalizedPath
    }

    func prepareExternalProjectWorkspace(projectID: String) throws {
        ensureProjectWorkspaceDirectory(projectID: projectID)

        let fileManager = FileManager.default
        let sourceLinkURL = legacyProjectSourceSymlinkURL(projectID: projectID)
        if (try? fileManager.destinationOfSymbolicLink(atPath: sourceLinkURL.path)) != nil {
            try fileManager.removeItem(at: sourceLinkURL)
        }
    }

    /// Clones `repoUrl` into the project workspace directory. Returns `true` only when `git clone` exits successfully.
    func cloneProjectRepository(repoUrl: String, projectID: String, projectDisplayName: String) async -> Bool {
        let trimmedUrl = repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrLogMax = 12_000

        func clipStderr(_ raw: String) -> String {
            if raw.count <= stderrLogMax { return raw }
            return String(raw.prefix(stderrLogMax)) + "…(truncated)"
        }

        guard trimmedUrl.hasPrefix("https://") || trimmedUrl.hasPrefix("git@") || trimmedUrl.hasPrefix("http://") else {
            logger.error(
                "project.clone.invalid_url",
                metadata: ["project_id": .string(projectID), "repo_url": .string(trimmedUrl)]
            )
            ensureProjectWorkspaceDirectory(projectID: projectID)
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but the URL is not supported for cloning (use https://, http://, or git@)."
            )
            return false
        }

        let cloneUrl = authorizedCloneURL(for: trimmedUrl)

        let projectDir = projectDirectoryURL(projectID: projectID)
        let parentDir = projectDir.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "project.clone.parent_dir_failed",
                metadata: [
                    "project_id": .string(projectID),
                    "path": .string(parentDir.path),
                    "error": .string(error.localizedDescription)
                ]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "clone", "--recurse-submodules", cloneUrl, projectDir.path]
        process.currentDirectoryURL = parentDir
        process.environment = childProcessEnvironment(overrides: ["GIT_TERMINAL_PROMPT": "0"])

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            logger.error(
                "project.clone.launch_failed",
                metadata: ["project_id": .string(projectID), "error": .string(error.localizedDescription)]
            )
            ensureProjectWorkspaceDirectory(projectID: projectID)
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but git could not be started: \(error.localizedDescription)"
            )
            return false
        }

        let didTimeout = await waitForProcessExitOrTimeout(process: process, timeoutMs: 120_000)

        if didTimeout, process.isRunning {
            await terminateProcess(process)
            let stderrOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            logger.error(
                "project.clone.timeout",
                metadata: [
                    "project_id": .string(projectID),
                    "repo_url": .string(trimmedUrl),
                    "stderr": .string(clipStderr(stderrOutput))
                ]
            )
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but git clone timed out after 120s. See server logs (project.clone.timeout)."
            )
            return false
        }

        if process.terminationStatus != 0 {
            let stderrOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            logger.error(
                "project.clone.failed",
                metadata: [
                    "project_id": .string(projectID),
                    "repo_url": .string(trimmedUrl),
                    "exit_code": .string(String(process.terminationStatus)),
                    "stderr": .string(clipStderr(stderrOutput))
                ]
            )
            let hint = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)
            let suffix = hint.isEmpty ? "" : " Output: \(hint)"
            await notificationService.pushSystemError(
                title: "Git repository not copied",
                message: "Project \"\(projectDisplayName)\" was saved, but git clone failed (exit \(process.terminationStatus)).\(suffix)"
            )
            return false
        }

        logger.info(
            "project.clone.success",
            metadata: ["project_id": .string(projectID), "repo_url": .string(trimmedUrl)]
        )
        return true
    }

    func authorizedCloneURL(for url: String) -> String {
        guard url.hasPrefix("https://") || url.hasPrefix("http://"),
              let token = githubAuthService.currentToken(),
              var components = URLComponents(string: url)
        else {
            return url
        }
        components.user = "x-access-token"
        components.password = token
        return components.string ?? url
    }

}

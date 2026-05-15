import Foundation
import Testing
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Test
func visorCreatesPendingTaskFromExplicitCreateIntent() async throws {
    let router = try makeRouter()
    let projectID = "visor-project-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let messageBody = try JSONEncoder().encode(
        ChannelMessageRequest(
            userId: "u1",
            content: "create task prepare migration plan for runtime cutover"
        )
    )
    let messageResponse = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: messageBody)
    #expect(messageResponse.status == 200)

    let project = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 5) { project in
        project.tasks.count == 1
    }
    let task = try #require(project?.tasks.first)

    #expect(task.status == "pending_approval")
    #expect(task.title == "prepare migration plan for runtime cutover")
    #expect(task.description == "prepare migration plan for runtime cutover")
}

@Test
func visorDoesNotCreateTasksFromImperativeDiscussion() async throws {
    let router = try makeRouter()
    let projectID = "visor-no-heuristic-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let messageBody = try JSONEncoder().encode(
        ChannelMessageRequest(
            userId: "u1",
            content: """
            research current plan
            нужно проверить релизный сценарий
            сделай прогон smoke тестов
            """
        )
    )
    let messageResponse = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: messageBody)
    #expect(messageResponse.status == 200)

    let response = await router.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
    #expect(response.status == 200)
    let project = try decodeProject(response.body)
    #expect(project.tasks.isEmpty)
}

@Test
func taskCancelCommandMarksTaskCancelled() async throws {
    let router = try makeRouter()
    let projectID = "visor-cancel-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")
    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Ship dashboard cards",
        status: "pending_approval"
    )

    let messageBody = try JSONEncoder().encode(
        ChannelMessageRequest(
            userId: "u1",
            content: "/task cancel #\(taskID) duplicate request"
        )
    )
    let messageResponse = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: messageBody)
    #expect(messageResponse.status == 200)

    let project = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        project.tasks.first(where: { $0.id == taskID })?.status == "cancelled"
    }
    let cancelledTask = project?.tasks.first(where: { $0.id == taskID })
    #expect(cancelledTask?.status == "cancelled")
    #expect(cancelledTask?.description.contains("Cancelled: duplicate request") == true)
}

@Test
func readyStatusAutoSpawnsWorkerAndMovesTaskToInProgress() async throws {
    let router = try makeRouter()
    let projectID = "visor-ready-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Implement autospawn",
        status: "backlog"
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )
    #expect(updateResponse.status == 200)

    let updatedProject = try decodeProject(updateResponse.body)
    let updatedTask = updatedProject.tasks.first(where: { $0.id == taskID })
    #expect(updatedTask?.status == "in_progress" || updatedTask?.status == "done")

    let worker = try await waitForWorker(router: router, taskID: taskID)
    #expect(worker?.taskId == taskID)
}

@Test
func workerCompletedEventWithoutConfirmationBlocksTask() async throws {
    let router = try makeRouter()
    let projectID = "visor-complete-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Complete lifecycle",
        status: "backlog"
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    _ = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )

    let project = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        project.tasks.first(where: { $0.id == taskID })?.status == "blocked"
    }
    let finalTask = project?.tasks.first(where: { $0.id == taskID })
    #expect(finalTask?.status == "blocked")
}

@Test
func workerFailedEventReturnsTaskToBacklog() async throws {
    let router = try makeRouter()
    let projectID = "visor-fail-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Failure rollback",
        status: "backlog"
    )

    let createWorkerBody = try JSONEncoder().encode(
        WorkerCreateRequest(
            spec: WorkerTaskSpec(
                taskId: taskID,
                channelId: "general",
                title: "Fail test worker",
                objective: "force fail",
                tools: ["shell"],
                mode: .interactive
            )
        )
    )
    let createWorkerResponse = await router.handle(method: "POST", path: "/v1/workers", body: createWorkerBody)
    #expect(createWorkerResponse.status == 201)

    let worker = try #require(try await waitForWorker(router: router, taskID: taskID))
    let failMessage = String(
        decoding: try JSONEncoder().encode(WorkerRouteCommand(command: .fail, error: "Worker failed during test")),
        as: UTF8.self
    )
    let routeBody = try JSONEncoder().encode(ChannelRouteRequest(message: failMessage))
    let routeResponse = await router.handle(
        method: "POST",
        path: "/v1/channels/general/route/\(worker.workerId)",
        body: routeBody
    )
    #expect(routeResponse.status == 200)

    let project = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        guard let task = project.tasks.first(where: { $0.id == taskID }) else {
            return false
        }
        return task.status == "backlog" && task.description.contains("Worker failed at")
    }
    let finalTask = project?.tasks.first(where: { $0.id == taskID })
    #expect(finalTask?.status == "backlog")
    #expect(finalTask?.description.contains("Worker failed at") == true)
}

@Test
func naturalLanguagePickUpCommandApprovesByIndex() async throws {
    let router = try makeRouter()
    let projectID = "visor-nl-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    _ = try await createTask(router: router, projectID: projectID, title: "Task one", status: "backlog")
    let secondTaskID = try await createTask(router: router, projectID: projectID, title: "Task two", status: "backlog")

    let commandBody = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "pick up #2"))
    let commandResponse = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: commandBody)
    #expect(commandResponse.status == 200)

    let decision = try JSONDecoder().decode(ChannelRouteDecision.self, from: commandResponse.body)
    #expect(decision.action == .respond)
    #expect(decision.reason == "task_approved_command")

    let project = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        let status = project.tasks.first(where: { $0.id == secondTaskID })?.status
        return status == "in_progress" || status == "done"
    }
    let approvedTask = project?.tasks.first(where: { $0.id == secondTaskID })
    #expect(approvedTask?.status == "in_progress" || approvedTask?.status == "done")
}

@Test
func readyTaskClaimsAssignedActorAndPersistsProjectArtifactsAndLogs() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let projectID = "visor-artifacts-\(UUID().uuidString)"

    try await createAgent(router: router, id: "builder")
    try await updateActorBoard(
        router: router,
        nodes: [
            ActorNode(
                id: "human:dispatcher",
                displayName: "Dispatcher",
                kind: .human,
                channelId: "general"
            ),
            ActorNode(
                id: "agent:builder",
                displayName: "Builder",
                kind: .agent,
                linkedAgentId: "builder",
                channelId: "agent:builder"
            )
        ],
        links: [
            ActorLink(
                id: "dispatch-builder-task",
                sourceActorId: "human:dispatcher",
                targetActorId: "agent:builder",
                direction: .oneWay,
                communicationType: .task
            )
        ],
        teams: []
    )

    try await createProject(router: router, projectID: projectID, channelId: "general")
    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Build artifact",
        status: "backlog",
        actorId: "agent:builder"
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )
    #expect(updateResponse.status == 200)

    let terminalProject = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        guard let status = project.tasks.first(where: { $0.id == taskID })?.status else {
            return false
        }
        return status == "done" || status == "blocked"
    }
    let terminalTask = terminalProject?.tasks.first(where: { $0.id == taskID })
    #expect(terminalTask?.status == "done" || terminalTask?.status == "blocked")
    #expect(terminalTask?.claimedActorId == "agent:builder")
    #expect(terminalTask?.claimedAgentId == "builder")

    let projectWorkspace = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(projectID, isDirectory: true)
    let metaDirectory = projectWorkspace.appendingPathComponent(".meta", isDirectory: true)

    let logPath = metaDirectory.appendingPathComponent("task-\(taskID).log").path
    #expect(FileManager.default.fileExists(atPath: logPath))
    let logContent = try String(contentsOfFile: logPath, encoding: .utf8)
    #expect(logContent.contains("stage=worker_spawned"))
    #expect(logContent.contains("stage=status_synced"))
}

@Test
func fireAndForgetWorkerPersistsObjectiveArtifact() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let projectID = "visor-create-file-\(UUID().uuidString)"

    try await createAgent(router: router, id: "builder")
    try await updateActorBoard(
        router: router,
        nodes: [
            ActorNode(
                id: "human:dispatcher",
                displayName: "Dispatcher",
                kind: .human,
                channelId: "general"
            ),
            ActorNode(
                id: "agent:builder",
                displayName: "Builder",
                kind: .agent,
                linkedAgentId: "builder",
                channelId: "agent:builder"
            )
        ],
        links: [
            ActorLink(
                id: "dispatch-builder-task",
                sourceActorId: "human:dispatcher",
                targetActorId: "agent:builder",
                direction: .oneWay,
                communicationType: .task
            )
        ],
        teams: []
    )
    try await createProject(router: router, projectID: projectID, channelId: "general")
    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Create file with text \"Hello world\"",
        status: "backlog",
        actorId: "agent:builder"
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )
    #expect(updateResponse.status == 200)

    // DefaultWorkerExecutor completes fire-and-forget workers immediately, but CoreService only
    // marks the task `done` after explicit `project.task_update` confirmation. Until then the
    // task is `blocked` while the worker summary is still persisted as a system task comment.
    let terminalProject = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 5) { project in
        guard let status = project.tasks.first(where: { $0.id == taskID })?.status else {
            return false
        }
        return status == "done" || status == "blocked"
    }
    let terminalTask = terminalProject?.tasks.first(where: { $0.id == taskID })
    #expect(terminalTask != nil)
    #expect(terminalTask?.status == "blocked")

    let commentsResponse = await router.handle(
        method: "GET",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)/comments",
        body: nil
    )
    #expect(commentsResponse.status == 200)
    let commentsDecoder = JSONDecoder()
    commentsDecoder.dateDecodingStrategy = .iso8601
    let comments = try commentsDecoder.decode([TaskComment].self, from: commentsResponse.body)
    #expect(comments.contains(where: { $0.authorActorId == "system" && !$0.content.isEmpty }))
    #expect(comments.contains(where: {
        $0.authorActorId == "system" &&
            $0.content.contains("Task delegated to subagent session") &&
            $0.content.contains("](/agents/builder/chat/session-")
    }))
}

@Test
func taskDelegationRespectsActorBoardTaskLinks() async throws {
    let router = try makeRouter()
    let projectID = "visor-route-links-\(UUID().uuidString)"
    let builderAgentID = "builder-\(UUID().uuidString)"
    let reviewerAgentID = "reviewer-\(UUID().uuidString)"
    let builderActorID = "agent:\(builderAgentID)"
    let reviewerActorID = "agent:\(reviewerAgentID)"

    try await createAgent(router: router, id: builderAgentID)
    try await createAgent(router: router, id: reviewerAgentID)
    try await updateActorBoard(
        router: router,
        nodes: [
            ActorNode(
                id: "human:dispatcher",
                displayName: "Dispatcher",
                kind: .human,
                channelId: "general"
            ),
            ActorNode(
                id: builderActorID,
                displayName: "Builder",
                kind: .agent,
                linkedAgentId: builderAgentID,
                channelId: builderActorID
            ),
            ActorNode(
                id: reviewerActorID,
                displayName: "Reviewer",
                kind: .agent,
                linkedAgentId: reviewerAgentID,
                channelId: reviewerActorID
            )
        ],
        links: [
            ActorLink(
                id: "dispatch-reviewer-task",
                sourceActorId: "human:dispatcher",
                targetActorId: reviewerActorID,
                direction: .oneWay,
                communicationType: .task
            )
        ],
        teams: []
    )
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Route constrained task",
        status: "backlog",
        actorId: builderActorID
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )
    #expect(updateResponse.status == 200)

    let project = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 2) { project in
        guard let task = project.tasks.first(where: { $0.id == taskID }) else {
            return false
        }
        return task.status == "ready"
    }
    let task = project?.tasks.first(where: { $0.id == taskID })
    #expect(task?.status == "ready")
    #expect(task?.claimedActorId == nil)
    #expect(task?.claimedAgentId == nil)
}

@Test
func swarmHierarchyCycleBlocksRootTask() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let projectID = "visor-swarm-cycle-\(UUID().uuidString)"
    let rootActorID = "agent:root-\(UUID().uuidString)"
    let childActorID = "agent:child-\(UUID().uuidString)"

    try await createAgent(router: router, id: rootActorID.replacingOccurrences(of: "agent:", with: ""))
    try await createAgent(router: router, id: childActorID.replacingOccurrences(of: "agent:", with: ""))
    try await updateActorBoard(
        router: router,
        nodes: [
            ActorNode(id: "human:dispatcher", displayName: "Dispatcher", kind: .human, channelId: "general"),
            ActorNode(id: rootActorID, displayName: "Root", kind: .agent, linkedAgentId: rootActorID.replacingOccurrences(of: "agent:", with: ""), channelId: rootActorID),
            ActorNode(id: childActorID, displayName: "Child", kind: .agent, linkedAgentId: childActorID.replacingOccurrences(of: "agent:", with: ""), channelId: childActorID)
        ],
        links: [
            ActorLink(
                id: "dispatch-root",
                sourceActorId: "human:dispatcher",
                targetActorId: rootActorID,
                direction: .oneWay,
                relationship: .peer,
                communicationType: .task
            ),
            ActorLink(
                id: "root-child",
                sourceActorId: rootActorID,
                targetActorId: childActorID,
                direction: .oneWay,
                relationship: .hierarchical,
                communicationType: .task
            ),
            ActorLink(
                id: "child-root",
                sourceActorId: childActorID,
                targetActorId: rootActorID,
                direction: .oneWay,
                relationship: .hierarchical,
                communicationType: .task
            )
        ],
        teams: []
    )
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Cycle root task",
        status: "backlog",
        actorId: rootActorID
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )
    #expect(updateResponse.status == 200)

    let blockedProject = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        project.tasks.first(where: { $0.id == taskID })?.status == "blocked"
    }
    let blockedTask = blockedProject?.tasks.first(where: { $0.id == taskID })
    #expect(blockedTask?.status == "blocked")
}

@Test
func swarmPlannerFailureBlocksRootTask() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let projectID = "visor-swarm-planner-\(UUID().uuidString)"
    let rootActorID = "agent:root-\(UUID().uuidString)"
    let childActorID = "agent:child-\(UUID().uuidString)"

    try await createAgent(router: router, id: rootActorID.replacingOccurrences(of: "agent:", with: ""))
    try await createAgent(router: router, id: childActorID.replacingOccurrences(of: "agent:", with: ""))
    try await updateActorBoard(
        router: router,
        nodes: [
            ActorNode(id: "human:dispatcher", displayName: "Dispatcher", kind: .human, channelId: "general"),
            ActorNode(id: rootActorID, displayName: "Root", kind: .agent, linkedAgentId: rootActorID.replacingOccurrences(of: "agent:", with: ""), channelId: rootActorID),
            ActorNode(id: childActorID, displayName: "Child", kind: .agent, linkedAgentId: childActorID.replacingOccurrences(of: "agent:", with: ""), channelId: childActorID)
        ],
        links: [
            ActorLink(
                id: "dispatch-root",
                sourceActorId: "human:dispatcher",
                targetActorId: rootActorID,
                direction: .oneWay,
                relationship: .peer,
                communicationType: .task
            ),
            ActorLink(
                id: "root-child",
                sourceActorId: rootActorID,
                targetActorId: childActorID,
                direction: .oneWay,
                relationship: .hierarchical,
                communicationType: .task
            )
        ],
        teams: []
    )
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Planner root task",
        status: "backlog",
        actorId: rootActorID
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )
    #expect(updateResponse.status == 200)

    let blockedProject = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        project.tasks.first(where: { $0.id == taskID })?.status == "blocked"
    }
    let blockedTask = blockedProject?.tasks.first(where: { $0.id == taskID })
    #expect(blockedTask?.status == "blocked")
}

@Test
func readyTaskWithoutAssigneeAutoSelectsFirstAgent() async throws {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let projectID = "visor-autoassign-\(UUID().uuidString)"
    let agentID = "executor-\(UUID().uuidString)"
    let actorID = "agent:\(agentID)"

    try await createAgent(router: router, id: agentID)
    try await updateActorBoard(
        router: router,
        nodes: [
            ActorNode(
                id: "human:dispatcher",
                displayName: "Dispatcher",
                kind: .human,
                channelId: "general"
            ),
            ActorNode(
                id: actorID,
                displayName: "Executor",
                kind: .agent,
                linkedAgentId: agentID,
                channelId: actorID
            )
        ],
        links: [],
        teams: []
    )

    try await createProject(router: router, projectID: projectID, channelId: "general")

    let taskID = try await createTask(
        router: router,
        projectID: projectID,
        title: "Task without assignee",
        status: "backlog"
    )

    let updateBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateBody
    )
    #expect(updateResponse.status == 200)

    let doneProject = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 5) { project in
        let task = project.tasks.first(where: { $0.id == taskID })
        return task?.status == "in_progress" || task?.status == "done"
    }
    let doneTask = doneProject?.tasks.first(where: { $0.id == taskID })
    #expect(doneTask?.claimedActorId == actorID)
    #expect(doneTask?.claimedAgentId == agentID)
    #expect(doneTask?.actorId == actorID)
}

@Test
func visorSkipsWhenProjectNotFoundForChannel() async throws {
    let router = try makeRouter()

    let messageBody = try JSONEncoder().encode(
        ChannelMessageRequest(
            userId: "u1",
            content: "research this\n- [ ] draft launch checklist"
        )
    )

    let response = await router.handle(method: "POST", path: "/v1/channels/orphan/messages", body: messageBody)
    #expect(response.status == 200)

    let projectsResponse = await router.handle(method: "GET", path: "/v1/projects", body: nil)
    #expect(projectsResponse.status == 200)
    let projects = try JSONDecoder().decode([ProjectRecord].self, from: projectsResponse.body)
    #expect(projects.isEmpty)
}

private func makeRouter() throws -> CoreRouter {
    let config = CoreConfig.test
    let service = CoreService(config: config)
    return CoreRouter(service: service)
}

private func createProject(router: CoreRouter, projectID: String, channelId: String) async throws {
    let body = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Visor Project",
            description: "Visor integration tests",
            channels: [.init(title: "General", channelId: channelId)]
        )
    )

    let response = await router.handle(method: "POST", path: "/v1/projects", body: body)
    #expect(response.status == 201)
}

private func createTask(
    router: CoreRouter,
    projectID: String,
    title: String,
    status: String,
    actorId: String? = nil,
    teamId: String? = nil
) async throws -> String {
    let body = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: title,
            description: "Integration test task",
            priority: "medium",
            status: status,
            actorId: actorId,
            teamId: teamId
        )
    )

    let response = await router.handle(method: "POST", path: "/v1/projects/\(projectID)/tasks", body: body)
    #expect(response.status == 200)

    let project = try decodeProject(response.body)
    return try #require(project.tasks.last?.id)
}

private func createAgent(router: CoreRouter, id: String) async throws {
    let body = try JSONEncoder().encode(
        AgentCreateRequest(
            id: id,
            displayName: id.capitalized,
            role: "Execution"
        )
    )
    let response = await router.handle(method: "POST", path: "/v1/agents", body: body)
    #expect(response.status == 201)
}

private func updateActorBoard(
    router: CoreRouter,
    nodes: [ActorNode],
    links: [ActorLink],
    teams: [ActorTeam]
) async throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let body = try encoder.encode(
        ActorBoardUpdateRequest(
            nodes: nodes,
            links: links,
            teams: teams
        )
    )
    let response = await router.handle(method: "PUT", path: "/v1/actors/board", body: body)
    #expect(response.status == 200)
}

private func decodeProject(_ data: Data) throws -> ProjectRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProjectRecord.self, from: data)
}

private func waitForProject(
    router: CoreRouter,
    projectID: String,
    timeoutSeconds: TimeInterval,
    predicate: @escaping (ProjectRecord) -> Bool
) async throws -> ProjectRecord? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let response = await router.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
        if response.status == 200 {
            let project = try decodeProject(response.body)
            if predicate(project) {
                return project
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    let response = await router.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
    if response.status == 200 {
        let project = try decodeProject(response.body)
        if predicate(project) {
            return project
        }
    }

    return nil
}

private func waitForWorker(router: CoreRouter, taskID: String) async throws -> WorkerSnapshot? {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let response = await router.handle(method: "GET", path: "/v1/workers", body: nil)
        if response.status == 200 {
            let workers = try JSONDecoder().decode([WorkerSnapshot].self, from: response.body)
            if let worker = workers.first(where: { $0.taskId == taskID }) {
                return worker
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
}

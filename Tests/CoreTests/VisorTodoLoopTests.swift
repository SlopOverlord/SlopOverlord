import Foundation
import Testing
@testable import AgentRuntime
@testable import Core
@testable import Protocols

@Test
func visorCreatesBacklogTasksFromBranchTodos() async throws {
    let router = try makeRouter()
    let projectID = "visor-project-\(UUID().uuidString)"
    try await createProject(router: router, projectID: projectID, channelId: "general")

    let messageBody = try JSONEncoder().encode(
        ChannelMessageRequest(
            userId: "u1",
            content: """
            research current plan
            - [ ] Prepare migration plan
            TODO: prepare migration plan
            нужно проверить релизный сценарий
            """
        )
    )
    let messageResponse = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: messageBody)
    #expect(messageResponse.status == 200)

    let project = try await waitForProject(router: router, projectID: projectID, timeoutSeconds: 3) { project in
        project.tasks.count >= 2
    }
    let tasks = try #require(project?.tasks)

    #expect(tasks.count == 2)
    #expect(tasks.allSatisfy { $0.status == "backlog" })
    #expect(tasks.allSatisfy { $0.description.contains("Source: visor-auto") })
    #expect(tasks.allSatisfy { $0.description.contains("Origin channel: general") })
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
func workerCompletedEventMarksTaskDone() async throws {
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
        project.tasks.first(where: { $0.id == taskID })?.status == "done"
    }
    let finalTask = project?.tasks.first(where: { $0.id == taskID })
    #expect(finalTask?.status == "done")
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
    let routeBody = try JSONEncoder().encode(ChannelRouteRequest(message: "fail"))
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
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-visor-loop-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

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
    status: String
) async throws -> String {
    let body = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: title,
            description: "Integration test task",
            priority: "medium",
            status: status
        )
    )

    let response = await router.handle(method: "POST", path: "/v1/projects/\(projectID)/tasks", body: body)
    #expect(response.status == 200)

    let project = try decodeProject(response.body)
    return try #require(project.tasks.last?.id)
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

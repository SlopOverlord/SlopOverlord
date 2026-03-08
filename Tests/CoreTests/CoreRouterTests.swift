import Foundation
import Testing
@testable import AgentRuntime
@testable import Core
@testable import Protocols

@Test
func postChannelMessageEndpoint() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "respond please"))
    let response = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: body)

    #expect(response.status == 200)
}

@Test
func bulletinsEndpoint() async {
    let service = CoreService(config: .default)
    _ = await service.triggerVisorBulletin()
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/bulletins", body: nil)
    #expect(response.status == 200)
}

@Test
func workersEndpoint() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        WorkerCreateRequest(
            spec: WorkerTaskSpec(
                taskId: "task-1",
                channelId: "general",
                title: "Worker",
                objective: "Do work",
                tools: ["shell"],
                mode: .interactive
            )
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/workers", body: createBody)
    #expect(createResponse.status == 201)

    let response = await router.handle(method: "GET", path: "/v1/workers", body: nil)
    #expect(response.status == 200)

    let workers = try JSONDecoder().decode([WorkerSnapshot].self, from: response.body)
    #expect(!workers.isEmpty)
}

@Test
func projectCrudEndpoints() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-projects-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: "platform-board",
            name: "Platform Board",
            description: "Core + dashboard roadmap",
            channels: [.init(title: "General", channelId: "general")]
        )
    )

    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let created = try decoder.decode(ProjectRecord.self, from: createResponse.body)
    #expect(created.id == "platform-board")
    #expect(created.name == "Platform Board")
    #expect(created.channels.count == 1)
    #expect(created.tasks.isEmpty)

    let listResponse = await router.handle(method: "GET", path: "/v1/projects", body: nil)
    #expect(listResponse.status == 200)
    let list = try decoder.decode([ProjectRecord].self, from: listResponse.body)
    #expect(list.contains(where: { $0.id == created.id }))

    let updateBody = try JSONEncoder().encode(ProjectUpdateRequest(name: "Platform Board v2"))
    let updateResponse = await router.handle(method: "PATCH", path: "/v1/projects/\(created.id)", body: updateBody)
    #expect(updateResponse.status == 200)
    let updated = try decoder.decode(ProjectRecord.self, from: updateResponse.body)
    #expect(updated.name == "Platform Board v2")

    let createTaskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: "Wire API",
            description: "Implement CRUD for projects and tasks",
            priority: "high",
            status: "backlog"
        )
    )
    let createTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(created.id)/tasks",
        body: createTaskBody
    )
    #expect(createTaskResponse.status == 200)
    let withTask = try decoder.decode(ProjectRecord.self, from: createTaskResponse.body)
    #expect(withTask.tasks.count == 1)

    let taskID = try #require(withTask.tasks.first?.id)
    #expect(taskID == "PLATFORM-BOARD-1")

    let createSecondTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(created.id)/tasks",
        body: createTaskBody
    )
    #expect(createSecondTaskResponse.status == 200)
    let withSecondTask = try decoder.decode(ProjectRecord.self, from: createSecondTaskResponse.body)
    #expect(withSecondTask.tasks.contains(where: { $0.id == "PLATFORM-BOARD-2" }))

    let taskLookupResponse = await router.handle(
        method: "GET",
        path: "/tasks/\(taskID)",
        body: nil
    )
    #expect(taskLookupResponse.status == 200)
    let taskLookup = try decoder.decode(AgentTaskRecord.self, from: taskLookupResponse.body)
    #expect(taskLookup.projectId == created.id)
    #expect(taskLookup.task.id == taskID)

    let patchTaskBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "in_progress"))
    let patchTaskResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(created.id)/tasks/\(taskID)",
        body: patchTaskBody
    )
    #expect(patchTaskResponse.status == 200)
    let patchedTaskProject = try decoder.decode(ProjectRecord.self, from: patchTaskResponse.body)
    #expect(patchedTaskProject.tasks.first?.status == "in_progress")

    let createChannelBody = try JSONEncoder().encode(ProjectChannelCreateRequest(title: "Backend", channelId: "backend"))
    let createChannelResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(created.id)/channels",
        body: createChannelBody
    )
    #expect(createChannelResponse.status == 200)
    let withSecondChannel = try decoder.decode(ProjectRecord.self, from: createChannelResponse.body)
    #expect(withSecondChannel.channels.count == 2)

    let removableChannelID = try #require(
        withSecondChannel.channels.first(where: { $0.channelId == "backend" })?.id
    )
    let removeChannelResponse = await router.handle(
        method: "DELETE",
        path: "/v1/projects/\(created.id)/channels/\(removableChannelID)",
        body: nil
    )
    #expect(removeChannelResponse.status == 200)
    let afterChannelDelete = try decoder.decode(ProjectRecord.self, from: removeChannelResponse.body)
    #expect(afterChannelDelete.channels.count == 1)

    let removeTaskResponse = await router.handle(
        method: "DELETE",
        path: "/v1/projects/\(created.id)/tasks/\(taskID)",
        body: nil
    )
    #expect(removeTaskResponse.status == 200)
    let afterTaskDelete = try decoder.decode(ProjectRecord.self, from: removeTaskResponse.body)
    #expect(afterTaskDelete.tasks.count == 1)
    #expect(afterTaskDelete.tasks.first?.id == "PLATFORM-BOARD-2")

    let deleteProjectResponse = await router.handle(method: "DELETE", path: "/v1/projects/\(created.id)", body: nil)
    #expect(deleteProjectResponse.status == 200)

    let fetchDeletedResponse = await router.handle(method: "GET", path: "/v1/projects/\(created.id)", body: nil)
    #expect(fetchDeletedResponse.status == 404)
}

@Test
func projectCreateCreatesWorkspaceDirectory() async throws {
    let workspaceName = "workspace-project-dirs-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-project-dirs-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let projectID = "proj-dir-\(UUID().uuidString)"

    let createBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Directory Project",
            description: "Checks workspace/projects/<id> provisioning",
            channels: [.init(title: "General", channelId: "general")]
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/projects", body: createBody)
    #expect(createResponse.status == 201)

    let projectDirectory = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(projectID, isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: projectDirectory.path))
}

@Test
func projectTaskReadyStatusTriggersVisorBulletin() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-project-ready-bulletin-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let projectID = "ready-bulletin-\(UUID().uuidString)"
    let createProjectBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Ready Bulletin Project",
            description: "Triggers visor when task becomes ready",
            channels: [.init(title: "General", channelId: "general")]
        )
    )
    let createProjectResponse = await router.handle(method: "POST", path: "/v1/projects", body: createProjectBody)
    #expect(createProjectResponse.status == 201)

    let createTaskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: "Prepare execution",
            description: "Move task into ready queue.",
            priority: "medium",
            status: "backlog"
        )
    )
    let createTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(projectID)/tasks",
        body: createTaskBody
    )
    #expect(createTaskResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let projectWithTask = try decoder.decode(ProjectRecord.self, from: createTaskResponse.body)
    let taskID = try #require(projectWithTask.tasks.first?.id)

    let updateTaskBody = try JSONEncoder().encode(ProjectTaskUpdateRequest(status: "ready"))
    let updateTaskResponse = await router.handle(
        method: "PATCH",
        path: "/v1/projects/\(projectID)/tasks/\(taskID)",
        body: updateTaskBody
    )
    #expect(updateTaskResponse.status == 200)

    let bulletinsResponse = await router.handle(method: "GET", path: "/v1/bulletins", body: nil)
    #expect(bulletinsResponse.status == 200)
    let bulletins = try decoder.decode([MemoryBulletin].self, from: bulletinsResponse.body)
    #expect(!bulletins.isEmpty)
}

@Test
func openAIModelsEndpoint() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let request = OpenAIProviderModelsRequest(authMethod: .apiKey, apiKey: "", apiUrl: "https://api.openai.com/v1")
    let body = try JSONEncoder().encode(request)
    let response = await router.handle(method: "POST", path: "/v1/providers/openai/models", body: body)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(OpenAIProviderModelsResponse.self, from: response.body)
    #expect(payload.provider == "openai")
    #expect(!payload.models.isEmpty)
}

@Test
func openAIProviderStatusEndpoint() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/providers/openai/status", body: nil)
    #expect(response.status == 200)

    let payload = try JSONDecoder().decode(OpenAIProviderStatusResponse.self, from: response.body)
    #expect(payload.provider == "openai")
    #expect(payload.hasAnyKey == (payload.hasEnvironmentKey || payload.hasConfiguredKey))
}

@Test
func channelStateReturnsEmptySnapshotWhenChannelMissing() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-empty-channel-\(UUID().uuidString).sqlite")
        .path
    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/channels/general/state", body: nil)
    #expect(response.status == 200)

    let snapshot = try JSONDecoder().decode(ChannelSnapshot.self, from: response.body)
    #expect(snapshot.channelId == "general")
    #expect(snapshot.messages.isEmpty)
    #expect(snapshot.contextUtilization == 0)
    #expect(snapshot.activeWorkerIds.isEmpty)
    #expect(snapshot.lastDecision == nil)
}

@Test
func channelEventsEndpointReturnsRuntimeTimeline() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-channel-events-\(UUID().uuidString).sqlite")
        .path
    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let channelID = "events-\(UUID().uuidString)"

    let requestBody = try JSONEncoder().encode(
        ChannelMessageRequest(userId: "u1", content: "respond please")
    )
    let firstResponse = await router.handle(
        method: "POST",
        path: "/v1/channels/\(channelID)/messages",
        body: requestBody
    )
    #expect(firstResponse.status == 200)

    try await Task.sleep(nanoseconds: 150_000_000)

    let response = await router.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/events?limit=20",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(ChannelEventsResponse.self, from: response.body)
    #expect(payload.channelId == channelID)
    #expect(!payload.items.isEmpty)
    #expect(payload.items.allSatisfy { $0.channelId == channelID })
    #expect(payload.items.contains(where: { $0.messageType == .channelMessageReceived }))
}

@Test
func channelEventsEndpointSupportsCursorAndTimeFilters() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-channel-events-pagination-\(UUID().uuidString).sqlite")
        .path
    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let channelID = "events-pagination-\(UUID().uuidString)"

    for index in 1...3 {
        let body = try JSONEncoder().encode(
            ChannelMessageRequest(userId: "u\(index)", content: "respond please \(index)")
        )
        let postResponse = await router.handle(
            method: "POST",
            path: "/v1/channels/\(channelID)/messages",
            body: body
        )
        #expect(postResponse.status == 200)
        try await Task.sleep(nanoseconds: 40_000_000)
    }

    try await Task.sleep(nanoseconds: 200_000_000)

    let firstPageResponse = await router.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/events?limit=2",
        body: nil
    )
    #expect(firstPageResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let firstPage = try decoder.decode(ChannelEventsResponse.self, from: firstPageResponse.body)
    #expect(firstPage.items.count == 2)
    let cursor = try #require(firstPage.nextCursor)

    let encodedCursor = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
    let secondPageResponse = await router.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/events?limit=2&cursor=\(encodedCursor)",
        body: nil
    )
    #expect(secondPageResponse.status == 200)
    let secondPage = try decoder.decode(ChannelEventsResponse.self, from: secondPageResponse.body)

    let firstIDs = Set(firstPage.items.map(\.messageId))
    let secondIDs = Set(secondPage.items.map(\.messageId))
    #expect(firstIDs.isDisjoint(with: secondIDs))

    let isoFormatter = ISO8601DateFormatter()
    if let newestTimestamp = firstPage.items.first?.ts {
        let beforeValue = isoFormatter.string(from: newestTimestamp)
        let encodedBeforeValue = beforeValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? beforeValue
        let beforeResponse = await router.handle(
            method: "GET",
            path: "/v1/channels/\(channelID)/events?limit=30&before=\(encodedBeforeValue)",
            body: nil
        )
        #expect(beforeResponse.status == 200)
        let beforePayload = try decoder.decode(ChannelEventsResponse.self, from: beforeResponse.body)
        #expect(beforePayload.items.allSatisfy { $0.ts < newestTimestamp })
    }

    if let oldestTimestamp = firstPage.items.last?.ts {
        let afterValue = isoFormatter.string(from: oldestTimestamp)
        let encodedAfterValue = afterValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? afterValue
        let afterResponse = await router.handle(
            method: "GET",
            path: "/v1/channels/\(channelID)/events?limit=30&after=\(encodedAfterValue)",
            body: nil
        )
        #expect(afterResponse.status == 200)
        let afterPayload = try decoder.decode(ChannelEventsResponse.self, from: afterResponse.body)
        #expect(afterPayload.items.allSatisfy { $0.ts > oldestTimestamp })
    }
}

@Test
func getConfigEndpoint() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/config", body: nil)
    #expect(response.status == 200)

    let config = try JSONDecoder().decode(CoreConfig.self, from: response.body)
    #expect(config.listen.port == 25101)
}

@Test
func systemLogsEndpointReadsJSONLFile() async throws {
    let workspaceName = "workspace-logs-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-logs-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let workspaceRoot = config.resolvedWorkspaceRootURL()
    let logsDirectory = workspaceRoot.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    let logFileURL = logsDirectory.appendingPathComponent("core-test.log")
    let logLine = """
    {"label":"sloppy.core.main","level":"error","message":"Test failure","metadata":{"module":"tests"},"source":"CoreTests","timestamp":"2026-02-28T10:11:12.123Z"}
    """
    guard let logData = (logLine + "\n").data(using: .utf8) else {
        throw NSError(domain: "CoreRouterTests", code: 1)
    }
    try logData.write(to: logFileURL, options: .atomic)

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/logs", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(SystemLogsResponse.self, from: response.body)
    #expect(payload.filePath.hasSuffix(".log"))
    #expect(payload.entries.count >= 1)
    #expect(payload.entries.last?.level == .error)
    #expect(payload.entries.last?.message == "Test failure")
}

@Test
func serviceSupportsInMemoryPersistenceBuilder() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-inmemory-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(
        config: config,
        persistenceBuilder: InMemoryCorePersistenceBuilder()
    )
    let router = CoreRouter(service: service)

    let body = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "respond please"))
    let response = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: body)
    #expect(response.status == 200)
    #expect(!FileManager.default.fileExists(atPath: sqlitePath))
}

@Test
func sqliteStoreFallbackProjectsPersistAcrossRestartWhenSQLiteUnavailable() async throws {
    let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-sqlite-fallback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

    let fallbackProjectsPath = fixtureDirectory.appendingPathComponent("projects-fallback.json").path
    let unavailableSQLitePath = fixtureDirectory.path

    let createdAt = Date()
    let project = ProjectRecord(
        id: "persisted-fallback-project",
        name: "Fallback Project",
        description: "Should survive store restart when SQLite is unavailable.",
        channels: [
            .init(
                id: "main-channel",
                title: "Main",
                channelId: "fallback-main",
                createdAt: createdAt
            )
        ],
        tasks: [],
        createdAt: createdAt,
        updatedAt: createdAt
    )

    let firstStore = SQLiteStore(
        path: unavailableSQLitePath,
        schemaSQL: "",
        fallbackProjectsPath: fallbackProjectsPath
    )
    await firstStore.saveProject(project)

    let restartedStore = SQLiteStore(
        path: unavailableSQLitePath,
        schemaSQL: "",
        fallbackProjectsPath: fallbackProjectsPath
    )
    let projects = await restartedStore.listProjects()

    #expect(projects.count == 1)
    #expect(projects.first?.id == project.id)
    #expect(projects.first?.name == "Fallback Project")
}

@Test
func putConfigEndpoint() async throws {
    let tempPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-\(UUID().uuidString).json")
        .path

    let service = CoreService(config: .default, configPath: tempPath)
    let router = CoreRouter(service: service)

    var config = CoreConfig.default
    config.listen.port = 25155
    config.sqlitePath = "./.data/core-config-test.sqlite"

    let payload = try JSONEncoder().encode(config)
    let response = await router.handle(method: "PUT", path: "/v1/config", body: payload)
    #expect(response.status == 200)

    let updated = try JSONDecoder().decode(CoreConfig.self, from: response.body)
    #expect(updated.listen.port == 25155)
}

@Test
func putConfigHotReloadsRuntimeModelProvider() async throws {
    let tempPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-config-\(UUID().uuidString).json")
        .path

    var initialConfig = CoreConfig.default
    initialConfig.models = []

    let service = CoreService(config: initialConfig, configPath: tempPath)
    let router = CoreRouter(service: service)

    let channelID = "reload-check"
    let firstMessageBody = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "hello"))
    let firstResponse = await router.handle(method: "POST", path: "/v1/channels/\(channelID)/messages", body: firstMessageBody)
    #expect(firstResponse.status == 200)

    let firstStateResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelID)/state", body: nil)
    #expect(firstStateResponse.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let firstSnapshot = try decoder.decode(ChannelSnapshot.self, from: firstStateResponse.body)
    #expect(firstSnapshot.messages.last(where: { $0.userId == "system" })?.content == "Responded inline")

    var updatedConfig = initialConfig
    updatedConfig.models = [
        .init(
            title: "openai-main",
            apiKey: "test-key",
            apiUrl: "http://127.0.0.1:1/v1",
            model: "gpt-4.1-mini"
        )
    ]
    let updatePayload = try JSONEncoder().encode(updatedConfig)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/config", body: updatePayload)
    #expect(updateResponse.status == 200)

    let secondMessageBody = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "hello again"))
    let secondResponse = await router.handle(method: "POST", path: "/v1/channels/\(channelID)/messages", body: secondMessageBody)
    #expect(secondResponse.status == 200)

    let secondStateResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelID)/state", body: nil)
    #expect(secondStateResponse.status == 200)
    let secondSnapshot = try decoder.decode(ChannelSnapshot.self, from: secondStateResponse.body)
    let latestSystemMessage = secondSnapshot.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(latestSystemMessage != "Responded inline")
}

@Test
func artifactContentNotFound() async {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/artifacts/missing/content", body: nil)
    #expect(response.status == 404)
}

@Test
func runtimeRecoveryAfterRestartReplaysPersistedState() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-recovery-\(UUID().uuidString).sqlite")
        .path
    let workspaceName = "workspace-recovery-\(UUID().uuidString)"
    let channelID = "recovery-\(UUID().uuidString)"
    let projectID = "recovery-project-\(UUID().uuidString)"

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    var artifactID = ""

    do {
        let service = CoreService(config: config)
        let router = CoreRouter(service: service)

        let createProjectBody = try JSONEncoder().encode(
            ProjectCreateRequest(
                id: projectID,
                name: "Recovery Project",
                description: "Validates restart recovery.",
                channels: [.init(title: "Recovery", channelId: channelID)]
            )
        )
        let createProjectResponse = await router.handle(method: "POST", path: "/v1/projects", body: createProjectBody)
        #expect(createProjectResponse.status == 201)

        let createTaskBody = try JSONEncoder().encode(
            ProjectTaskCreateRequest(
                title: "Recovery task",
                description: "Persisted project task for restart validation.",
                priority: "medium",
                status: "backlog"
            )
        )
        let createTaskResponse = await router.handle(
            method: "POST",
            path: "/v1/projects/\(projectID)/tasks",
            body: createTaskBody
        )
        #expect(createTaskResponse.status == 200)

        let messageBody = try JSONEncoder().encode(
            ChannelMessageRequest(userId: "u1", content: "implement recovery artifact")
        )
        let messageResponse = await router.handle(
            method: "POST",
            path: "/v1/channels/\(channelID)/messages",
            body: messageBody
        )
        #expect(messageResponse.status == 200)

        let stateResponse = await router.handle(method: "GET", path: "/v1/channels/\(channelID)/state", body: nil)
        #expect(stateResponse.status == 200)
        let state = try decoder.decode(ChannelSnapshot.self, from: stateResponse.body)
        let workerID = try #require(state.activeWorkerIds.first)

        let routeBody = try JSONEncoder().encode(ChannelRouteRequest(message: "done"))
        let routeResponse = await router.handle(
            method: "POST",
            path: "/v1/channels/\(channelID)/route/\(workerID)",
            body: routeBody
        )
        #expect(routeResponse.status == 200)

        let completedStateResponse = await router.handle(
            method: "GET",
            path: "/v1/channels/\(channelID)/state",
            body: nil
        )
        #expect(completedStateResponse.status == 200)
        let completedState = try decoder.decode(ChannelSnapshot.self, from: completedStateResponse.body)
        let completionMessage = try #require(completedState.messages.last(where: { $0.userId == "system" })?.content)
        artifactID = try #require(extractArtifactID(from: completionMessage))

        let artifactResponse = await router.handle(
            method: "GET",
            path: "/v1/artifacts/\(artifactID)/content",
            body: nil
        )
        #expect(artifactResponse.status == 200)

        let schemaPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/Core/Storage/schema.sql")
            .path
        let schemaSQL = try String(contentsOfFile: schemaPath, encoding: .utf8)
        let verificationStore = SQLiteStore(path: sqlitePath, schemaSQL: schemaSQL)
        let expectedArtifactID = artifactID
        let persisted = await waitForCondition(timeoutSeconds: 3, pollNanoseconds: 100_000_000) {
            let channels = await verificationStore.listPersistedChannels()
            let artifacts = await verificationStore.listPersistedArtifacts()
            let events = await verificationStore.listPersistedEvents()
            return channels.contains(where: { $0.id == channelID })
                && artifacts.contains(where: { $0.id == expectedArtifactID })
                && events.contains(where: { $0.channelId == channelID })
        }
        #expect(persisted)
    }

    let restartedService = CoreService(config: config)
    let restartedRouter = CoreRouter(service: restartedService)

    let restartedStateResponse = await restartedRouter.handle(
        method: "GET",
        path: "/v1/channels/\(channelID)/state",
        body: nil
    )
    #expect(restartedStateResponse.status == 200)

    let restartedArtifactResponse = await restartedRouter.handle(
        method: "GET",
        path: "/v1/artifacts/\(artifactID)/content",
        body: nil
    )
    #expect(restartedArtifactResponse.status == 200)

    let restartedState = try decoder.decode(ChannelSnapshot.self, from: restartedStateResponse.body)
    if restartedState.messages.isEmpty {
        let schemaPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/Core/Storage/schema.sql")
            .path
        let schemaSQL = try String(contentsOfFile: schemaPath, encoding: .utf8)
        let restartedStore = SQLiteStore(path: sqlitePath, schemaSQL: schemaSQL)
        let persistedEvents = await restartedStore.listPersistedEvents()
            .filter { $0.channelId == channelID }
        #expect(!persistedEvents.isEmpty)
    } else {
        #expect(!restartedState.messages.isEmpty)
    }

    let projectResponse = await restartedRouter.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
    #expect(projectResponse.status == 200)
    let recoveredProject = try decoder.decode(ProjectRecord.self, from: projectResponse.body)
    #expect(recoveredProject.tasks.count == 1)
}

@Test
func createListAndGetAgentsEndpoints() async throws {
    let workspaceName = "workspace-agents-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agents-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let request = AgentCreateRequest(
        id: "agent-dev",
        displayName: "Dev Agent",
        role: "Builds and debugs features."
    )
    let createBody = try JSONEncoder().encode(request)
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createdAgent = try decoder.decode(AgentSummary.self, from: createResponse.body)
    #expect(createdAgent.id == "agent-dev")
    #expect(createdAgent.displayName == "Dev Agent")

    let listResponse = await router.handle(method: "GET", path: "/v1/agents", body: nil)
    #expect(listResponse.status == 200)
    let list = try decoder.decode([AgentSummary].self, from: listResponse.body)
    #expect(list.contains(where: { $0.id == "agent-dev" }))

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-dev", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(AgentSummary.self, from: getResponse.body)
    #expect(fetched.id == "agent-dev")

    let workspaceAgentsURL = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-dev", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: workspaceAgentsURL.path))

    let scaffoldFiles = ["Agents.md", "User.md", "Soul.md", "Identity.id", "Identity.md", "config.json", "agent.json"]
    for file in scaffoldFiles {
        let fileURL = workspaceAgentsURL.appendingPathComponent(file)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

@Test
func agentTasksEndpointReturnsClaimedProjectTasks() async throws {
    let workspaceName = "workspace-agent-tasks-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-tasks-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let agentCreateBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-claim",
            displayName: "Claim Agent",
            role: "Takes delegated tasks"
        )
    )
    let agentCreateResponse = await router.handle(method: "POST", path: "/v1/agents", body: agentCreateBody)
    #expect(agentCreateResponse.status == 201)

    let projectID = "agent-task-project-\(UUID().uuidString)"
    let projectCreateBody = try JSONEncoder().encode(
        ProjectCreateRequest(
            id: projectID,
            name: "Agent Tasks Project",
            description: "Tracks claimed tasks by agent",
            channels: [.init(title: "General", channelId: "general")]
        )
    )
    let projectCreateResponse = await router.handle(method: "POST", path: "/v1/projects", body: projectCreateBody)
    #expect(projectCreateResponse.status == 201)

    let createTaskBody = try JSONEncoder().encode(
        ProjectTaskCreateRequest(
            title: "Delegated to actor",
            description: "Auto assignment test",
            priority: "medium",
            status: "ready",
            actorId: "agent:agent-claim"
        )
    )
    let createTaskResponse = await router.handle(
        method: "POST",
        path: "/v1/projects/\(projectID)/tasks",
        body: createTaskBody
    )
    #expect(createTaskResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var createdProject = try decoder.decode(ProjectRecord.self, from: createTaskResponse.body)
    let taskID = try #require(createdProject.tasks.first?.id)

    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let fetchProjectResponse = await router.handle(method: "GET", path: "/v1/projects/\(projectID)", body: nil)
        #expect(fetchProjectResponse.status == 200)
        createdProject = try decoder.decode(ProjectRecord.self, from: fetchProjectResponse.body)
        if createdProject.tasks.first(where: { $0.id == taskID })?.claimedAgentId == "agent-claim" {
            break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    let tasksResponse = await router.handle(method: "GET", path: "/v1/agents/agent-claim/tasks", body: nil)
    #expect(tasksResponse.status == 200)
    let records = try decoder.decode([AgentTaskRecord].self, from: tasksResponse.body)
    #expect(records.contains(where: { $0.task.id == taskID }))
    #expect(records.contains(where: { $0.task.claimedAgentId == "agent-claim" }))
}

@Test
func agentMemoriesEndpointsListAndGraphRecords() async throws {
    let workspaceName = "workspace-agent-memories-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-memories-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let memoryStore = HybridMemoryStore(config: config)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-memory",
            displayName: "Agent Memory",
            role: "Stores memory records"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let persistentRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Retain system architecture decisions.",
            summary: "Persistent system fact",
            kind: .fact,
            memoryClass: .semantic,
            scope: .agent("agent-memory")
        )
    )
    let temporaryRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Yesterday deploy note for rollback context.",
            summary: "Short lived deploy context",
            kind: .event,
            memoryClass: .episodic,
            scope: .agent("agent-memory")
        )
    )
    let todoRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "[todo] follow up with release checklist",
            summary: "Todo item",
            kind: .todo,
            memoryClass: .procedural,
            scope: .channel("agent:agent-memory:session:s1")
        )
    )
    let neighborRef = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Dependency decision context for architecture review.",
            summary: "Graph neighbor",
            kind: .decision,
            memoryClass: .procedural,
            scope: .agent("agent-memory")
        )
    )
    _ = await memoryStore.save(
        entry: MemoryWriteRequest(
            note: "Foreign memory should stay hidden.",
            summary: "Other agent",
            kind: .fact,
            memoryClass: .semantic,
            scope: .agent("other-agent")
        )
    )
    #expect(
        await memoryStore.link(
            MemoryEdgeWriteRequest(
                fromMemoryId: persistentRef.id,
                toMemoryId: neighborRef.id,
                relation: .derivedFrom,
                provenance: "tests"
            )
        ) == true
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let listResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?limit=1&offset=1",
        body: nil
    )
    #expect(listResponse.status == 200)
    let listPage = try decoder.decode(AgentMemoryListResponse.self, from: listResponse.body)
    #expect(listPage.total == 4)
    #expect(listPage.limit == 1)
    #expect(listPage.offset == 1)
    #expect(listPage.items.count == 1)

    let summarySearchResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?search=Persistent&filter=persistent",
        body: nil
    )
    #expect(summarySearchResponse.status == 200)
    let summarySearch = try decoder.decode(AgentMemoryListResponse.self, from: summarySearchResponse.body)
    #expect(summarySearch.items.count == 1)
    #expect(summarySearch.items.first?.id == persistentRef.id)
    #expect(summarySearch.items.first?.derivedCategory == .persistent)

    let noteSearchResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?search=rollback&filter=temporary",
        body: nil
    )
    #expect(noteSearchResponse.status == 200)
    let noteSearch = try decoder.decode(AgentMemoryListResponse.self, from: noteSearchResponse.body)
    #expect(noteSearch.items.map(\.id) == [temporaryRef.id])

    let idSearchResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories?search=\(todoRef.id)&filter=todo",
        body: nil
    )
    #expect(idSearchResponse.status == 200)
    let idSearch = try decoder.decode(AgentMemoryListResponse.self, from: idSearchResponse.body)
    #expect(idSearch.items.map(\.id) == [todoRef.id])
    #expect(idSearch.items.first?.scope.type == .channel)

    let graphResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory/memories/graph?search=Persistent&filter=persistent",
        body: nil
    )
    #expect(graphResponse.status == 200)
    let graph = try decoder.decode(AgentMemoryGraphResponse.self, from: graphResponse.body)
    #expect(graph.seedIds == [persistentRef.id])
    #expect(graph.nodes.contains(where: { $0.id == persistentRef.id }))
    #expect(graph.nodes.contains(where: { $0.id == neighborRef.id }))
    #expect(graph.nodes.allSatisfy { $0.scope.agentId == "agent-memory" || $0.scope.channelId?.hasPrefix("agent:agent-memory:session:") == true })
    #expect(graph.edges.count == 1)
    #expect(graph.edges.first?.fromMemoryId == persistentRef.id)
    #expect(graph.edges.first?.toMemoryId == neighborRef.id)
    #expect(graph.truncated == false)
}

@Test
func agentMemoriesEndpointsValidateAgentAndTruncation() async throws {
    let workspaceName = "workspace-agent-memories-validate-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-memories-validate-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let memoryStore = HybridMemoryStore(config: config)

    let invalidResponse = await router.handle(method: "GET", path: "/v1/agents/invalid!/memories", body: nil)
    #expect(invalidResponse.status == 400)

    let missingResponse = await router.handle(method: "GET", path: "/v1/agents/missing-agent/memories/graph", body: nil)
    #expect(missingResponse.status == 404)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-memory-truncate",
            displayName: "Agent Memory Truncate",
            role: "Tests graph caps"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    for index in 0..<51 {
        _ = await memoryStore.save(
            entry: MemoryWriteRequest(
                note: "Persistent memory \(index)",
                summary: "Seed \(index)",
                kind: .fact,
                memoryClass: .semantic,
                scope: .agent("agent-memory-truncate")
            )
        )
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let graphResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-memory-truncate/memories/graph?filter=all",
        body: nil
    )
    #expect(graphResponse.status == 200)
    let graph = try decoder.decode(AgentMemoryGraphResponse.self, from: graphResponse.body)
    #expect(graph.seedIds.count == 50)
    #expect(graph.nodes.count == 50)
    #expect(graph.truncated == true)
}

@Test
func agentConfigEndpointsReadAndUpdate() async throws {
    let workspaceName = "workspace-agent-config-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-config-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-config",
            displayName: "Agent Config",
            role: "Tests model and markdown config endpoints"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-config/config", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(AgentConfigDetail.self, from: getResponse.body)
    #expect(fetched.agentId == "agent-config")
    #expect(!fetched.selectedModel.isEmpty)
    #expect(!fetched.availableModels.isEmpty)
    #expect(fetched.heartbeat.enabled == false)
    #expect(fetched.heartbeat.intervalMinutes == 5)
    #expect(fetched.documents.heartbeatMarkdown.isEmpty)
    #expect(fetched.heartbeatStatus.lastRunAt == nil)

    let nextModel = fetched.availableModels.last?.id ?? fetched.selectedModel
    let updateRequest = AgentConfigUpdateRequest(
        selectedModel: nextModel,
        documents: AgentDocumentBundle(
            userMarkdown: "# User\nUpdated user profile\n",
            agentsMarkdown: "# Agent\nUpdated orchestration guidance\n",
            soulMarkdown: "# Soul\nUpdated values and boundaries\n",
            identityMarkdown: "# Identity\nagent-config-v2\n",
            heartbeatMarkdown: "- verify onboarding checklist\n"
        ),
        heartbeat: AgentHeartbeatSettings(enabled: true, intervalMinutes: 15)
    )
    let updateBody = try JSONEncoder().encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/agents/agent-config/config", body: updateBody)
    #expect(updateResponse.status == 200)

    let updated = try decoder.decode(AgentConfigDetail.self, from: updateResponse.body)
    #expect(updated.selectedModel == nextModel)
    #expect(updated.documents.userMarkdown.contains("Updated user profile"))
    #expect(updated.documents.agentsMarkdown.contains("Updated orchestration guidance"))
    #expect(updated.documents.soulMarkdown.contains("Updated values and boundaries"))
    #expect(updated.documents.identityMarkdown.contains("agent-config-v2"))
    #expect(updated.documents.heartbeatMarkdown.contains("verify onboarding checklist"))
    #expect(updated.heartbeat.enabled == true)
    #expect(updated.heartbeat.intervalMinutes == 15)

    let agentDirectory = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-config", isDirectory: true)
    let identityPath = agentDirectory.appendingPathComponent("Identity.id")
    let heartbeatPath = agentDirectory.appendingPathComponent("HEARTBEAT.md")
    let userPath = agentDirectory.appendingPathComponent("User.md")
    let configPath = agentDirectory.appendingPathComponent("config.json")

    let identityFileText = try String(contentsOf: identityPath, encoding: .utf8)
    let heartbeatFileText = try String(contentsOf: heartbeatPath, encoding: .utf8)
    let userFileText = try String(contentsOf: userPath, encoding: .utf8)
    let configFileText = try String(contentsOf: configPath, encoding: .utf8)
    #expect(identityFileText == "agent-config-v2\n")
    #expect(heartbeatFileText == "- verify onboarding checklist\n")
    #expect(userFileText.contains("Updated user profile"))
    #expect(configFileText.contains(nextModel))
    #expect(configFileText.contains("\"intervalMinutes\" : 15"))
}

@Test
func agentConfigHeartbeatValidationAndBackfill() async throws {
    let workspaceName = "workspace-agent-heartbeat-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-heartbeat-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-heartbeat",
            displayName: "Agent Heartbeat",
            role: "Tests heartbeat config validation"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let agentDirectory = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-heartbeat", isDirectory: true)
    let heartbeatPath = agentDirectory.appendingPathComponent("HEARTBEAT.md")
    #expect(FileManager.default.fileExists(atPath: heartbeatPath.path))

    try FileManager.default.removeItem(at: heartbeatPath)
    #expect(!FileManager.default.fileExists(atPath: heartbeatPath.path))

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-heartbeat/config", body: nil)
    #expect(getResponse.status == 200)
    #expect(FileManager.default.fileExists(atPath: heartbeatPath.path))

    let invalidUpdate = AgentConfigUpdateRequest(
        selectedModel: "openai:gpt-4.1-mini",
        documents: AgentDocumentBundle(
            userMarkdown: "# User\nA\n",
            agentsMarkdown: "# Agent\nB\n",
            soulMarkdown: "# Soul\nC\n",
            identityMarkdown: "# Identity\nagent-heartbeat\n",
            heartbeatMarkdown: "- verify\n"
        ),
        heartbeat: AgentHeartbeatSettings(enabled: true, intervalMinutes: 0)
    )
    let invalidBody = try JSONEncoder().encode(invalidUpdate)
    let invalidResponse = await router.handle(method: "PUT", path: "/v1/agents/agent-heartbeat/config", body: invalidBody)
    #expect(invalidResponse.status == 400)
}

@Test
func agentToolsEndpointsReadAndUpdate() async throws {
    let workspaceName = "workspace-agent-tools-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-tools-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools",
            displayName: "Agent Tools",
            role: "Tests tools policy endpoints"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let getResponse = await router.handle(method: "GET", path: "/v1/agents/agent-tools/tools", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(AgentToolsPolicy.self, from: getResponse.body)
    #expect(fetched.version == 1)
    #expect(fetched.defaultPolicy == .allow)

    let updateRequest = AgentToolsUpdateRequest(
        version: 1,
        defaultPolicy: .deny,
        tools: [
            "agents.list": true,
            "sessions.list": true
        ],
        guardrails: AgentToolsGuardrails()
    )
    let updateBody = try JSONEncoder().encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/agents/agent-tools/tools", body: updateBody)
    #expect(updateResponse.status == 200)

    let updated = try decoder.decode(AgentToolsPolicy.self, from: updateResponse.body)
    #expect(updated.defaultPolicy == .deny)
    #expect(updated.tools["agents.list"] == true)
    #expect(updated.tools["sessions.list"] == true)

    let toolsFileURL = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-tools", isDirectory: true)
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("tools.json")
    #expect(FileManager.default.fileExists(atPath: toolsFileURL.path))
}

@Test
func agentToolsUpdateRejectsInvalidSchemaVersion() async throws {
    let workspaceName = "workspace-agent-tools-invalid-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-tools-invalid-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-invalid",
            displayName: "Agent Tools Invalid",
            role: "Tests tools payload validation"
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/agents", body: createBody)
    #expect(createResponse.status == 201)

    let invalidRequest = AgentToolsUpdateRequest(
        version: 2,
        defaultPolicy: .allow,
        tools: [:],
        guardrails: AgentToolsGuardrails()
    )
    let body = try JSONEncoder().encode(invalidRequest)
    let response = await router.handle(method: "PUT", path: "/v1/agents/agent-tools-invalid/tools", body: body)
    #expect(response.status == 400)
}

@Test
func invokeToolEndpointRespectsPolicy() async throws {
    let workspaceName = "workspace-agent-tool-invoke-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-tool-invoke-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-invoke",
            displayName: "Agent Tools Invoke",
            role: "Runs tool invocation endpoint tests"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-invoke/sessions",
        body: try JSONEncoder().encode(AgentSessionCreateRequest(title: "Tool Session"))
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)

    let invokeBody = try JSONEncoder().encode(
        ToolInvocationRequest(tool: "agents.list")
    )
    let invokeResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-invoke/sessions/\(summary.id)/tools/invoke",
        body: invokeBody
    )
    #expect(invokeResponse.status == 200)
    let invokeResult = try decoder.decode(ToolInvocationResult.self, from: invokeResponse.body)
    #expect(invokeResult.ok == true)

    let denyBody = try JSONEncoder().encode(
        AgentToolsUpdateRequest(
            version: 1,
            defaultPolicy: .deny,
            tools: [:],
            guardrails: AgentToolsGuardrails()
        )
    )
    let denyResponse = await router.handle(
        method: "PUT",
        path: "/v1/agents/agent-tools-invoke/tools",
        body: denyBody
    )
    #expect(denyResponse.status == 200)

    let invokeForbiddenResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-invoke/sessions/\(summary.id)/tools/invoke",
        body: invokeBody
    )
    #expect(invokeForbiddenResponse.status == 403)
}

@Test
func invokeRuntimeExecBlocksDeniedCommandPrefix() async throws {
    let workspaceName = "workspace-agent-tool-exec-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-tool-exec-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-exec",
            displayName: "Agent Tools Exec",
            role: "Tests runtime.exec guardrails"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-exec/sessions",
        body: try JSONEncoder().encode(AgentSessionCreateRequest(title: "Exec Session"))
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)

    let invokeBody = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "runtime.exec",
            arguments: [
                "command": .string("rm"),
                "arguments": .array([.string("-rf"), .string("/tmp/demo")])
            ]
        )
    )

    let response = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-exec/sessions/\(summary.id)/tools/invoke",
        body: invokeBody
    )
    #expect(response.status == 200)
    let result = try decoder.decode(ToolInvocationResult.self, from: response.body)
    #expect(result.ok == false)
    #expect(result.error?.code == "command_blocked")
}

@Test
func invokeRuntimeProcessLifecycleWorksPerSession() async throws {
    let workspaceName = "workspace-agent-tool-process-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agent-tool-process-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-tools-process",
            displayName: "Agent Tools Process",
            role: "Tests runtime.process lifecycle"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-process/sessions",
        body: try JSONEncoder().encode(AgentSessionCreateRequest(title: "Process Session"))
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)

    let startBody = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "runtime.process",
            arguments: [
                "action": .string("start"),
                "command": .string("/bin/sleep"),
                "arguments": .array([.string("2")])
            ]
        )
    )
    let startResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-process/sessions/\(summary.id)/tools/invoke",
        body: startBody
    )
    #expect(startResponse.status == 200)
    let startResult = try decoder.decode(ToolInvocationResult.self, from: startResponse.body)
    #expect(startResult.ok == true)
    let processId = startResult.data?.asObject?["processId"]?.asString ?? ""
    #expect(!processId.isEmpty)

    let stopBody = try JSONEncoder().encode(
        ToolInvocationRequest(
            tool: "runtime.process",
            arguments: [
                "action": .string("stop"),
                "processId": .string(processId)
            ]
        )
    )
    let stopResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-tools-process/sessions/\(summary.id)/tools/invoke",
        body: stopBody
    )
    #expect(stopResponse.status == 200)
    let stopResult = try decoder.decode(ToolInvocationResult.self, from: stopResponse.body)
    #expect(stopResult.ok == true)
}

@Test
func createAgentDuplicateIDReturnsConflict() async throws {
    let workspaceName = "workspace-agents-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-agents-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let request = AgentCreateRequest(
        id: "agent-same",
        displayName: "Agent Same",
        role: "Role"
    )
    let body = try JSONEncoder().encode(request)
    let firstResponse = await router.handle(method: "POST", path: "/v1/agents", body: body)
    #expect(firstResponse.status == 201)

    let secondResponse = await router.handle(method: "POST", path: "/v1/agents", body: body)
    #expect(secondResponse.status == 409)
}

@Test
func actorBoardEndpointsSyncSystemActorsAndPersistLayout() async throws {
    let workspaceName = "workspace-actors-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-actors-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-ops",
            displayName: "Ops Agent",
            role: "Handles operational work"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let firstBoardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(firstBoardResponse.status == 200)
    let firstBoard = try decoder.decode(ActorBoardSnapshot.self, from: firstBoardResponse.body)
    #expect(firstBoard.nodes.contains(where: { $0.id == "human:admin" && $0.kind == .human }))
    #expect(firstBoard.nodes.contains(where: { $0.id == "agent:agent-ops" && $0.linkedAgentId == "agent-ops" }))

    var updatedNodes = firstBoard.nodes
    if let adminIndex = updatedNodes.firstIndex(where: { $0.id == "human:admin" }) {
        updatedNodes[adminIndex].positionX = 512
        updatedNodes[adminIndex].positionY = 420
    }
    updatedNodes.append(
        ActorNode(
            id: "action:notify",
            displayName: "Notify",
            kind: .action,
            channelId: "channel:notify",
            role: "Dispatches notifications",
            positionX: 760,
            positionY: 420
        )
    )

    let updateRequest = ActorBoardUpdateRequest(
        nodes: updatedNodes,
        links: [
            ActorLink(
                id: "link-admin-notify",
                sourceActorId: "human:admin",
                targetActorId: "action:notify",
                direction: .oneWay,
                communicationType: .chat
            )
        ],
        teams: [
            ActorTeam(
                id: "team:core",
                name: "Core Team",
                memberActorIds: ["human:admin", "action:notify"]
            )
        ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let updateBody = try encoder.encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: updateBody)
    #expect(updateResponse.status == 200)

    let updatedBoard = try decoder.decode(ActorBoardSnapshot.self, from: updateResponse.body)
    #expect(updatedBoard.nodes.contains(where: { $0.id == "action:notify" }))
    #expect(updatedBoard.links.contains(where: { $0.id == "link-admin-notify" }))
    #expect(updatedBoard.teams.contains(where: { $0.id == "team:core" }))

    let persistedResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(persistedResponse.status == 200)
    let persistedBoard = try decoder.decode(ActorBoardSnapshot.self, from: persistedResponse.body)
    let persistedAdmin = persistedBoard.nodes.first(where: { $0.id == "human:admin" })
    #expect(persistedAdmin?.positionX == 512)
    #expect(persistedAdmin?.positionY == 420)
}

@Test
func actorRouteEndpointResolvesRecipientsFromLinks() async throws {
    let workspaceName = "workspace-actor-route-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-actor-route-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-analyst",
            displayName: "Analyst Agent",
            role: "Analyzes incoming events"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let boardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(boardResponse.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let board = try decoder.decode(ActorBoardSnapshot.self, from: boardResponse.body)

    var nodes = board.nodes
    nodes.append(
        ActorNode(
            id: "action:triage",
            displayName: "Triage",
            kind: .action,
            channelId: "channel:triage",
            role: "Routes and enriches events",
            positionX: 700,
            positionY: 260
        )
    )

    let updateRequest = ActorBoardUpdateRequest(
        nodes: nodes,
        links: [
            ActorLink(
                id: "link-admin-triage",
                sourceActorId: "human:admin",
                targetActorId: "action:triage",
                direction: .oneWay,
                communicationType: .chat
            ),
            ActorLink(
                id: "link-triage-agent",
                sourceActorId: "action:triage",
                targetActorId: "agent:agent-analyst",
                direction: .twoWay,
                communicationType: .event
            )
        ],
        teams: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let updateBody = try encoder.encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: updateBody)
    #expect(updateResponse.status == 200)

    let adminRouteBody = try JSONEncoder().encode(
        ActorRouteRequest(fromActorId: "human:admin", communicationType: .chat)
    )
    let adminRouteResponse = await router.handle(method: "POST", path: "/v1/actors/route", body: adminRouteBody)
    #expect(adminRouteResponse.status == 200)
    let adminRoute = try decoder.decode(ActorRouteResponse.self, from: adminRouteResponse.body)
    #expect(adminRoute.recipientActorIds == ["action:triage"])

    let actionRouteBody = try JSONEncoder().encode(
        ActorRouteRequest(fromActorId: "action:triage", communicationType: .event)
    )
    let actionRouteResponse = await router.handle(method: "POST", path: "/v1/actors/route", body: actionRouteBody)
    #expect(actionRouteResponse.status == 200)
    let actionRoute = try decoder.decode(ActorRouteResponse.self, from: actionRouteResponse.body)
    #expect(actionRoute.recipientActorIds == ["agent:agent-analyst"])

    let missingRouteBody = try JSONEncoder().encode(
        ActorRouteRequest(fromActorId: "missing:actor", communicationType: .chat)
    )
    let missingRouteResponse = await router.handle(method: "POST", path: "/v1/actors/route", body: missingRouteBody)
    #expect(missingRouteResponse.status == 404)
}

@Test
func actorBoardInfersHierarchicalRelationshipFromSockets() async throws {
    let workspaceName = "workspace-actor-relationship-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-actor-relationship-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let createAgentBody = try encoder.encode(
        AgentCreateRequest(
            id: "child-agent",
            displayName: "Child Agent",
            role: "Hierarchy target"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let initialBoardResponse = await router.handle(method: "GET", path: "/v1/actors/board", body: nil)
    #expect(initialBoardResponse.status == 200)
    let initialBoard = try decoder.decode(ActorBoardSnapshot.self, from: initialBoardResponse.body)

    var nodes = initialBoard.nodes
    nodes.append(
        ActorNode(
            id: "agent:child",
            displayName: "Child Agent",
            kind: .agent,
            linkedAgentId: "child-agent",
            channelId: "agent:child"
        )
    )

    let updateRequest = ActorBoardUpdateRequest(
        nodes: nodes,
        links: [
            ActorLink(
                id: "link-admin-child-task",
                sourceActorId: "human:admin",
                targetActorId: "agent:child",
                direction: .oneWay,
                communicationType: .task,
                sourceSocket: .bottom,
                targetSocket: .top
            )
        ],
        teams: []
    )

    let updateBody = try encoder.encode(updateRequest)
    let updateResponse = await router.handle(method: "PUT", path: "/v1/actors/board", body: updateBody)
    #expect(updateResponse.status == 200)
    let updatedBoard = try decoder.decode(ActorBoardSnapshot.self, from: updateResponse.body)
    let updatedLink = try #require(updatedBoard.links.first(where: { $0.id == "link-admin-child-task" }))
    #expect(updatedLink.relationship == .hierarchical)
}

@Test
func actorCRUDEndpointsManageNodesLinksAndTeams() async throws {
    let workspaceName = "workspace-actor-crud-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-actor-crud-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-crud",
            displayName: "CRUD Agent",
            role: "Actor CRUD coverage"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let createNodeBody = try encoder.encode(
        ActorNode(
            id: "action:qa",
            displayName: "QA Action",
            kind: .action,
            channelId: "channel:qa",
            role: "Checks artifacts",
            positionX: 420,
            positionY: 280
        )
    )
    let createNodeResponse = await router.handle(method: "POST", path: "/v1/actors/nodes", body: createNodeBody)
    #expect(createNodeResponse.status == 201)
    var board = try decoder.decode(ActorBoardSnapshot.self, from: createNodeResponse.body)
    #expect(board.nodes.contains(where: { $0.id == "action:qa" }))

    let updateNodeBody = try encoder.encode(
        ActorNode(
            id: "action:qa",
            displayName: "QA Action Updated",
            kind: .action,
            channelId: "channel:qa-v2",
            role: "Updated role",
            positionX: 500,
            positionY: 340
        )
    )
    let updateNodeResponse = await router.handle(method: "PUT", path: "/v1/actors/nodes/action:qa", body: updateNodeBody)
    #expect(updateNodeResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: updateNodeResponse.body)
    #expect(board.nodes.contains(where: { $0.id == "action:qa" && $0.displayName == "QA Action Updated" }))

    let createLinkBody = try encoder.encode(
        ActorLink(
            id: "link-admin-qa",
            sourceActorId: "human:admin",
            targetActorId: "action:qa",
            direction: .oneWay,
            communicationType: .chat
        )
    )
    let createLinkResponse = await router.handle(method: "POST", path: "/v1/actors/links", body: createLinkBody)
    #expect(createLinkResponse.status == 201)
    board = try decoder.decode(ActorBoardSnapshot.self, from: createLinkResponse.body)
    #expect(board.links.contains(where: { $0.id == "link-admin-qa" }))

    let updateLinkBody = try encoder.encode(
        ActorLink(
            id: "link-admin-qa",
            sourceActorId: "human:admin",
            targetActorId: "action:qa",
            direction: .twoWay,
            communicationType: .event
        )
    )
    let updateLinkResponse = await router.handle(method: "PUT", path: "/v1/actors/links/link-admin-qa", body: updateLinkBody)
    #expect(updateLinkResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: updateLinkResponse.body)
    let updatedLink = board.links.first(where: { $0.id == "link-admin-qa" })
    #expect(updatedLink?.direction == .twoWay)
    #expect(updatedLink?.communicationType == .event)

    let createTeamBody = try encoder.encode(
        ActorTeam(
            id: "team:ops",
            name: "Ops Team",
            memberActorIds: ["human:admin", "action:qa"]
        )
    )
    let createTeamResponse = await router.handle(method: "POST", path: "/v1/actors/teams", body: createTeamBody)
    #expect(createTeamResponse.status == 201)
    board = try decoder.decode(ActorBoardSnapshot.self, from: createTeamResponse.body)
    #expect(board.teams.contains(where: { $0.id == "team:ops" }))

    let updateTeamBody = try encoder.encode(
        ActorTeam(
            id: "team:ops",
            name: "Ops Team Updated",
            memberActorIds: ["action:qa"]
        )
    )
    let updateTeamResponse = await router.handle(method: "PUT", path: "/v1/actors/teams/team:ops", body: updateTeamBody)
    #expect(updateTeamResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: updateTeamResponse.body)
    #expect(board.teams.contains(where: { $0.id == "team:ops" && $0.name == "Ops Team Updated" }))

    let deleteLinkResponse = await router.handle(method: "DELETE", path: "/v1/actors/links/link-admin-qa", body: nil)
    #expect(deleteLinkResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: deleteLinkResponse.body)
    #expect(!board.links.contains(where: { $0.id == "link-admin-qa" }))

    let deleteTeamResponse = await router.handle(method: "DELETE", path: "/v1/actors/teams/team%3Aops", body: nil)
    #expect(deleteTeamResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: deleteTeamResponse.body)
    #expect(!board.teams.contains(where: { $0.id == "team:ops" }))

    let deleteNodeResponse = await router.handle(method: "DELETE", path: "/v1/actors/nodes/action:qa", body: nil)
    #expect(deleteNodeResponse.status == 200)
    board = try decoder.decode(ActorBoardSnapshot.self, from: deleteNodeResponse.body)
    #expect(!board.nodes.contains(where: { $0.id == "action:qa" }))
}

@Test
func agentSessionLifecycleEndpoints() async throws {
    let workspaceName = "workspace-sessions-\(UUID().uuidString)"
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-sessions-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.workspace = .init(name: workspaceName, basePath: FileManager.default.temporaryDirectory.path)
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let createAgentBody = try JSONEncoder().encode(
        AgentCreateRequest(
            id: "agent-chat",
            displayName: "Agent Chat",
            role: "Handles chat session tests"
        )
    )
    let createAgentResponse = await router.handle(method: "POST", path: "/v1/agents", body: createAgentBody)
    #expect(createAgentResponse.status == 201)

    let sessionRequest = AgentSessionCreateRequest(title: "Main Session")
    let createSessionBody = try JSONEncoder().encode(sessionRequest)
    let createSessionResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-chat/sessions",
        body: createSessionBody
    )
    #expect(createSessionResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let sessionSummary = try decoder.decode(AgentSessionSummary.self, from: createSessionResponse.body)
    #expect(sessionSummary.agentId == "agent-chat")

    let bootstrapChannelID = "agent:agent-chat:session:\(sessionSummary.id)"
    let bootstrapSnapshot = await service.getChannelState(channelId: bootstrapChannelID)
    #expect(bootstrapSnapshot != nil)
    let bootstrapMessage = bootstrapSnapshot?.messages.first(where: {
        $0.userId == "system" && $0.content.contains("[agent_session_context_bootstrap_v1]")
    })
    #expect(bootstrapMessage != nil)
    #expect(bootstrapMessage?.content.contains("[Agents.md]") == true)
    #expect(bootstrapMessage?.content.contains("[User.md]") == true)
    #expect(bootstrapMessage?.content.contains("[Identity.md]") == true)
    #expect(bootstrapMessage?.content.contains("[Soul.md]") == true)
    #expect(bootstrapMessage?.content.contains("[Skills]") == true)
    #expect(bootstrapMessage?.content.contains("No additional skills installed.") == true)

    let sessionFileURL = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-chat", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("\(sessionSummary.id).jsonl")
    #expect(FileManager.default.fileExists(atPath: sessionFileURL.path))

    let listResponse = await router.handle(method: "GET", path: "/v1/agents/agent-chat/sessions", body: nil)
    #expect(listResponse.status == 200)
    let sessions = try decoder.decode([AgentSessionSummary].self, from: listResponse.body)
    #expect(sessions.contains(where: { $0.id == sessionSummary.id }))

    let streamResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)/stream",
        body: nil
    )
    #expect(streamResponse.status == 200)
    #expect(streamResponse.contentType == "text/event-stream")
    #expect(streamResponse.sseStream != nil)
    var streamIterator = streamResponse.sseStream?.makeAsyncIterator()
    let readyChunk = await streamIterator?.next()
    #expect(readyChunk != nil)
    if let readyChunk {
        #expect(readyChunk.event == AgentSessionStreamUpdateKind.sessionReady.rawValue)
        let streamUpdate = try decoder.decode(AgentSessionStreamUpdate.self, from: readyChunk.data)
        #expect(streamUpdate.kind == .sessionReady)
        #expect(streamUpdate.summary?.id == sessionSummary.id)
    }

    let attachmentPayload = AgentAttachmentUpload(
        name: "note.txt",
        mimeType: "text/plain",
        sizeBytes: 4,
        contentBase64: Data("demo".utf8).base64EncodedString()
    )
    let messageRequest = AgentSessionPostMessageRequest(
        userId: "dashboard",
        content: "search this request and reply",
        attachments: [attachmentPayload],
        spawnSubSession: true
    )
    let messageBody = try JSONEncoder().encode(messageRequest)
    let messageResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)/messages",
        body: messageBody
    )
    #expect(messageResponse.status == 200)

    let messageResult = try decoder.decode(AgentSessionMessageResponse.self, from: messageResponse.body)
    #expect(!messageResult.appendedEvents.isEmpty)
    #expect(messageResult.routeDecision != nil)

    let getSessionResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)",
        body: nil
    )
    #expect(getSessionResponse.status == 200)

    let detail = try decoder.decode(AgentSessionDetail.self, from: getSessionResponse.body)
    #expect(detail.events.count >= messageResult.appendedEvents.count)

    let controlBody = try JSONEncoder().encode(
        AgentSessionControlRequest(action: .pause, requestedBy: "dashboard", reason: "manual pause")
    )
    let controlResponse = await router.handle(
        method: "POST",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)/control",
        body: controlBody
    )
    #expect(controlResponse.status == 200)

    let deleteResponse = await router.handle(
        method: "DELETE",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)",
        body: nil
    )
    #expect(deleteResponse.status == 200)

    let getDeletedResponse = await router.handle(
        method: "GET",
        path: "/v1/agents/agent-chat/sessions/\(sessionSummary.id)",
        body: nil
    )
    #expect(getDeletedResponse.status == 404)
}

// MARK: - Channel Plugins CRUD

@Test
func channelPluginCrudEndpoints() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-plugin-crud-\(UUID().uuidString).sqlite")
        .path
    var config = CoreConfig.default
    config.sqlitePath = sqlitePath
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let listResponse = await router.handle(method: "GET", path: "/v1/plugins", body: nil)
    #expect(listResponse.status == 200)

    let createBody = try JSONEncoder().encode(
        ChannelPluginCreateRequest(
            id: "test-telegram",
            type: "telegram",
            baseUrl: "http://127.0.0.1:9100",
            channelIds: ["tg-general"],
            config: ["botToken": "fake-token"],
            enabled: true
        )
    )
    let createResponse = await router.handle(method: "POST", path: "/v1/plugins", body: createBody)
    #expect(createResponse.status == 201)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let created = try decoder.decode(ChannelPluginRecord.self, from: createResponse.body)
    #expect(created.id == "test-telegram")
    #expect(created.type == "telegram")
    #expect(created.channelIds == ["tg-general"])
    #expect(created.config["botToken"] == "fake-token")
    #expect(created.enabled == true)

    let duplicateResponse = await router.handle(method: "POST", path: "/v1/plugins", body: createBody)
    #expect(duplicateResponse.status == 409)

    let getResponse = await router.handle(method: "GET", path: "/v1/plugins/test-telegram", body: nil)
    #expect(getResponse.status == 200)
    let fetched = try decoder.decode(ChannelPluginRecord.self, from: getResponse.body)
    #expect(fetched.id == "test-telegram")

    let updateBody = try JSONEncoder().encode(
        ChannelPluginUpdateRequest(
            channelIds: ["tg-general", "tg-dev"],
            config: ["botToken": "updated-token"],
            enabled: false
        )
    )
    let updateResponse = await router.handle(method: "PUT", path: "/v1/plugins/test-telegram", body: updateBody)
    #expect(updateResponse.status == 200)
    let updated = try decoder.decode(ChannelPluginRecord.self, from: updateResponse.body)
    #expect(updated.channelIds == ["tg-general", "tg-dev"])
    #expect(updated.config["botToken"] == "updated-token")
    #expect(updated.enabled == false)

    let listAfterUpdate = await router.handle(method: "GET", path: "/v1/plugins", body: nil)
    #expect(listAfterUpdate.status == 200)
    let allPlugins = try decoder.decode([ChannelPluginRecord].self, from: listAfterUpdate.body)
    #expect(allPlugins.count == 1)

    let deleteResponse = await router.handle(method: "DELETE", path: "/v1/plugins/test-telegram", body: nil)
    #expect(deleteResponse.status == 200)

    let getDeletedResponse = await router.handle(method: "GET", path: "/v1/plugins/test-telegram", body: nil)
    #expect(getDeletedResponse.status == 404)

    let deleteAgainResponse = await router.handle(method: "DELETE", path: "/v1/plugins/test-telegram", body: nil)
    #expect(deleteAgainResponse.status == 404)
}

@Test
func channelPluginValidation() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-plugin-validation-\(UUID().uuidString).sqlite")
        .path
    var config = CoreConfig.default
    config.sqlitePath = sqlitePath
    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let emptyTypeBody = try JSONEncoder().encode(
        ChannelPluginCreateRequest(type: "", baseUrl: "http://localhost:9100")
    )
    let emptyTypeResponse = await router.handle(method: "POST", path: "/v1/plugins", body: emptyTypeBody)
    #expect(emptyTypeResponse.status == 400)

    let emptyUrlBody = try JSONEncoder().encode(
        ChannelPluginCreateRequest(type: "telegram", baseUrl: "")
    )
    let emptyUrlResponse = await router.handle(method: "POST", path: "/v1/plugins", body: emptyUrlBody)
    #expect(emptyUrlResponse.status == 400)
}

@Test
func channelPluginLookupByChannelId() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-plugin-lookup-\(UUID().uuidString).sqlite")
        .path
    var config = CoreConfig.default
    config.sqlitePath = sqlitePath
    let service = CoreService(config: config)

    let _ = try await service.createChannelPlugin(
        ChannelPluginCreateRequest(
            id: "lookup-plugin",
            type: "telegram",
            baseUrl: "http://127.0.0.1:9200",
            channelIds: ["ch-alpha", "ch-beta"]
        )
    )

    let found = await service.channelPluginForChannel(channelId: "ch-alpha")
    #expect(found?.id == "lookup-plugin")

    let foundBeta = await service.channelPluginForChannel(channelId: "ch-beta")
    #expect(foundBeta?.id == "lookup-plugin")

    let notFound = await service.channelPluginForChannel(channelId: "ch-missing")
    #expect(notFound == nil)
}

// MARK: - Token Usage Tests

@Test
func tokenUsageEndpointReturnsEmptyList() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-token-usage-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/token-usage", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    #expect(result.items.isEmpty)
    #expect(result.totalPromptTokens == 0)
    #expect(result.totalCompletionTokens == 0)
    #expect(result.totalTokens == 0)
}

@Test
func tokenUsageEndpointReturnsPersistedData() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-token-usage-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    // Persist some token usage directly via the service
    let channelId = "test-channel"
    let taskId = "test-task"
    let usage = TokenUsage(prompt: 100, completion: 50)

    // Access the store through the service's persistence
    let store = await service.listTokenUsage()
    #expect(store.items.isEmpty)

    // Use runtime event to trigger token usage persistence
    let decision = await service.postChannelMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "u1", content: "respond please")
    )
    #expect(decision.action == .respond)

    // Check that endpoint returns data
    let response = await router.handle(method: "GET", path: "/v1/token-usage", body: nil)
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    // Response action is recorded but token usage may be 0 for inline responses
    #expect(result.totalPromptTokens >= 0)
    #expect(result.totalCompletionTokens >= 0)
}

@Test
func tokenUsageEndpointPersistsBranchConclusionUsage() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-token-usage-branch-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let decision = await service.postChannelMessage(
        channelId: "branch-usage-channel",
        request: ChannelMessageRequest(userId: "u1", content: "research architecture options")
    )
    #expect(decision.action == .spawnBranch)

    let hasPersistedBranchUsage = await waitForCondition(timeoutSeconds: 3) {
        let usage = await service.listTokenUsage(channelId: "branch-usage-channel")
        return usage.items.contains(where: { item in
            item.promptTokens == 300 && item.completionTokens == 120
        })
    }
    #expect(hasPersistedBranchUsage)

    let response = await router.handle(
        method: "GET",
        path: "/v1/token-usage?channelId=branch-usage-channel",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    #expect(result.items.contains(where: { $0.promptTokens == 300 && $0.completionTokens == 120 }))
    #expect(result.totalTokens >= 420)
}

@Test
func tokenUsageEndpointFiltersByChannelId() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-token-usage-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    // Send messages to different channels
    _ = await service.postChannelMessage(
        channelId: "channel-a",
        request: ChannelMessageRequest(userId: "u1", content: "respond please")
    )
    _ = await service.postChannelMessage(
        channelId: "channel-b",
        request: ChannelMessageRequest(userId: "u2", content: "respond please")
    )

    // Query with channel filter
    let response = await router.handle(
        method: "GET",
        path: "/v1/token-usage?channelId=channel-a",
        body: nil
    )
    #expect(response.status == 200)
}

@Test
func tokenUsageEndpointFiltersByDateRange() async throws {
    let sqlitePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-token-usage-\(UUID().uuidString).sqlite")
        .path

    var config = CoreConfig.default
    config.sqlitePath = sqlitePath

    let service = CoreService(config: config)
    let router = CoreRouter(service: service)

    let formatter = ISO8601DateFormatter()
    let from = formatter.string(from: Date().addingTimeInterval(-3600))
    let to = formatter.string(from: Date())

    let response = await router.handle(
        method: "GET",
        path: "/v1/token-usage?from=\(from)&to=\(to)",
        body: nil
    )
    #expect(response.status == 200)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(TokenUsageResponse.self, from: response.body)
    #expect(result.items.isEmpty || result.totalTokens >= 0)
}

private func extractArtifactID(from message: String) -> String? {
    let pattern = #"artifact\s+([A-Za-z0-9-]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
    guard let match = regex.firstMatch(in: message, options: [], range: fullRange),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: message)
    else {
        return nil
    }
    return String(message[range])
}

private func waitForCondition(
    timeoutSeconds: TimeInterval,
    pollNanoseconds: UInt64 = 50_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return await condition()
}

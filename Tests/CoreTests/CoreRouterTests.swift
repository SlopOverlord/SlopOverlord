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
    #expect(afterTaskDelete.tasks.isEmpty)

    let deleteProjectResponse = await router.handle(method: "DELETE", path: "/v1/projects/\(created.id)", body: nil)
    #expect(deleteProjectResponse.status == 200)

    let fetchDeletedResponse = await router.handle(method: "GET", path: "/v1/projects/\(created.id)", body: nil)
    #expect(fetchDeletedResponse.status == 404)
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
    let service = CoreService(config: .default)
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
func getConfigEndpoint() async throws {
    let service = CoreService(config: .default)
    let router = CoreRouter(service: service)

    let response = await router.handle(method: "GET", path: "/v1/config", body: nil)
    #expect(response.status == 200)

    let config = try JSONDecoder().decode(CoreConfig.self, from: response.body)
    #expect(config.listen.port == 25101)
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
func putConfigEndpoint() async throws {
    let tempPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("slopoverlord-config-\(UUID().uuidString).json")
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
        .appendingPathComponent("slopoverlord-config-\(UUID().uuidString).json")
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

    let nextModel = fetched.availableModels.last?.id ?? fetched.selectedModel
    let updateRequest = AgentConfigUpdateRequest(
        selectedModel: nextModel,
        documents: AgentDocumentBundle(
            userMarkdown: "# User\nUpdated user profile\n",
            agentsMarkdown: "# Agent\nUpdated orchestration guidance\n",
            soulMarkdown: "# Soul\nUpdated values and boundaries\n",
            identityMarkdown: "# Identity\nagent-config-v2\n"
        )
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

    let agentDirectory = config
        .resolvedWorkspaceRootURL()
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("agent-config", isDirectory: true)
    let identityPath = agentDirectory.appendingPathComponent("Identity.id")
    let userPath = agentDirectory.appendingPathComponent("User.md")
    let configPath = agentDirectory.appendingPathComponent("config.json")

    let identityFileText = try String(contentsOf: identityPath, encoding: .utf8)
    let userFileText = try String(contentsOf: userPath, encoding: .utf8)
    let configFileText = try String(contentsOf: configPath, encoding: .utf8)
    #expect(identityFileText == "agent-config-v2\n")
    #expect(userFileText.contains("Updated user profile"))
    #expect(configFileText.contains(nextModel))
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

import Foundation
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

    let scaffoldFiles = ["Agents.md", "User.md", "Soul.md", "Identity.id", "config.json", "agent.json"]
    for file in scaffoldFiles {
        let fileURL = workspaceAgentsURL.appendingPathComponent(file)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
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

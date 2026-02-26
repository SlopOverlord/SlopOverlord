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

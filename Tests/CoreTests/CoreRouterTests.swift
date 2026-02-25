import XCTest
@testable import AgentRuntime
@testable import Core
@testable import Protocols

final class CoreRouterTests: XCTestCase {
    func testPostChannelMessageEndpoint() async throws {
        let service = CoreService(config: .default)
        let router = CoreRouter(service: service)

        let body = try JSONEncoder().encode(ChannelMessageRequest(userId: "u1", content: "respond please"))
        let response = await router.handle(method: "POST", path: "/v1/channels/general/messages", body: body)

        XCTAssertEqual(response.status, 200)
    }

    func testBulletinsEndpoint() async throws {
        let service = CoreService(config: .default)
        _ = await service.triggerVisorBulletin()
        let router = CoreRouter(service: service)

        let response = await router.handle(method: "GET", path: "/v1/bulletins", body: nil)
        XCTAssertEqual(response.status, 200)
    }

    func testChannelStateReturnsEmptySnapshotWhenChannelMissing() async throws {
        let service = CoreService(config: .default)
        let router = CoreRouter(service: service)

        let response = await router.handle(method: "GET", path: "/v1/channels/general/state", body: nil)
        XCTAssertEqual(response.status, 200)

        let snapshot = try JSONDecoder().decode(ChannelSnapshot.self, from: response.body)
        XCTAssertEqual(snapshot.channelId, "general")
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertEqual(snapshot.contextUtilization, 0)
        XCTAssertTrue(snapshot.activeWorkerIds.isEmpty)
        XCTAssertNil(snapshot.lastDecision)
    }

    func testGetConfigEndpoint() async throws {
        let service = CoreService(config: .default)
        let router = CoreRouter(service: service)

        let response = await router.handle(method: "GET", path: "/v1/config", body: nil)
        XCTAssertEqual(response.status, 200)

        let config = try JSONDecoder().decode(CoreConfig.self, from: response.body)
        XCTAssertEqual(config.listen.port, 25101)
    }

    func testPutConfigEndpoint() async throws {
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
        XCTAssertEqual(response.status, 200)

        let updated = try JSONDecoder().decode(CoreConfig.self, from: response.body)
        XCTAssertEqual(updated.listen.port, 25155)
    }

    func testArtifactContentNotFound() async {
        let service = CoreService(config: .default)
        let router = CoreRouter(service: service)

        let response = await router.handle(method: "GET", path: "/v1/artifacts/missing/content", body: nil)
        XCTAssertEqual(response.status, 404)
    }
}

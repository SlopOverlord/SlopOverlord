import XCTest
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

    func testArtifactContentNotFound() async {
        let service = CoreService(config: .default)
        let router = CoreRouter(service: service)

        let response = await router.handle(method: "GET", path: "/v1/artifacts/missing/content", body: nil)
        XCTAssertEqual(response.status, 404)
    }
}

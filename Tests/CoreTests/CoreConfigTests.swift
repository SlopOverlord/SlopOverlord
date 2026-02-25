import XCTest
@testable import Core

final class CoreConfigTests: XCTestCase {
    func testDecodeLegacyStringModelsAndPlugins() throws {
        let legacyJSON =
            """
            {
              "listen": { "host": "0.0.0.0", "port": 25101 },
              "auth": { "token": "dev-token" },
              "models": ["openai:gpt-4.1-mini", "ollama:qwen3"],
              "memory": { "backend": "sqlite-local-vectors" },
              "nodes": ["local"],
              "gateways": [],
              "plugins": ["telegram-gateway"],
              "sqlitePath": "./.data/core.sqlite"
            }
            """

        let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.models.count, 2)
        XCTAssertEqual(decoded.models[0].title, "openai-gpt-4.1-mini")
        XCTAssertEqual(decoded.models[0].model, "gpt-4.1-mini")
        XCTAssertEqual(decoded.plugins.count, 1)
        XCTAssertEqual(decoded.plugins[0].plugin, "telegram-gateway")
    }
}

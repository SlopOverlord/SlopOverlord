import Foundation
import Foundation
import Testing
@testable import Core

@Test
func decodeLegacyStringModelsAndPlugins() throws {
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

    #expect(decoded.models.count == 2)
    #expect(decoded.models[0].title == "openai-gpt-4.1-mini")
    #expect(decoded.models[0].model == "gpt-4.1-mini")
    #expect(decoded.plugins.count == 1)
    #expect(decoded.plugins[0].plugin == "telegram-gateway")
    #expect(decoded.workspace.name == CoreConfig.defaultWorkspaceName)
    #expect(decoded.workspace.basePath == CoreConfig.defaultWorkspaceBasePath)
    #expect(decoded.sqlitePath == CoreConfig.defaultSQLiteFileName)
}

@Test
func resolvedWorkspaceAndSQLiteURLsForRelativePath() {
    var config = CoreConfig.default
    config.workspace = .init(name: "bot-runtime", basePath: ".")
    config.sqlitePath = "storage/core.sqlite"

    let workspaceURL = config.resolvedWorkspaceRootURL(currentDirectory: "/tmp/slop")
    let sqliteURL = config.resolvedSQLiteURL(currentDirectory: "/tmp/slop")

    #expect(workspaceURL.standardizedFileURL.path == "/tmp/slop/bot-runtime")
    #expect(sqliteURL.standardizedFileURL.path == "/tmp/slop/bot-runtime/storage/core.sqlite")
}

@Test
func resolvedSQLiteURLKeepsAbsolutePath() {
    var config = CoreConfig.default
    config.sqlitePath = "/var/lib/slop/core.sqlite"

    let sqliteURL = config.resolvedSQLiteURL(currentDirectory: "/tmp/slop")
    #expect(sqliteURL.path == "/var/lib/slop/core.sqlite")
}

@Test
func resolvedWorkspaceSupportsHomeShortcuts() {
    var tildeConfig = CoreConfig.default
    tildeConfig.workspace = .init(name: "workspace", basePath: "~")

    let tildeWorkspace = tildeConfig.resolvedWorkspaceRootURL(currentDirectory: "/tmp/slop")
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(tildeWorkspace.standardizedFileURL.path == "\(homePath)/workspace")

    var envConfig = CoreConfig.default
    envConfig.workspace = .init(name: "workspace", basePath: "$HOME")

    let envWorkspace = envConfig.resolvedWorkspaceRootURL(currentDirectory: "/tmp/slop")
    #expect(envWorkspace.standardizedFileURL.path == "\(homePath)/workspace")
}

@Test
func defaultConfigPathResolvesInsideWorkspaceRoot() {
    let workspace = CoreConfig.Workspace(name: "workspace-dev", basePath: "/tmp/slop")
    let resolved = CoreConfig.defaultConfigPath(for: workspace, currentDirectory: "/unused")
    #expect(resolved == "/tmp/slop/workspace-dev/slopoverlord.json")
}

@Test
func loadFallsBackToLegacyConfigFileInCurrentDirectory() throws {
    let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-config-legacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

    var config = CoreConfig.default
    config.listen.port = 25999
    let payload = try JSONEncoder().encode(config)
    let legacyPath = fixtureDirectory.appendingPathComponent(CoreConfig.legacyDefaultConfigFileName)
    try payload.write(to: legacyPath, options: .atomic)

    let loaded = CoreConfig.load(currentDirectory: fixtureDirectory.path)
    #expect(loaded.listen.port == 25999)
}

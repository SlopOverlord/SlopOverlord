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
    #expect(decoded.gitSync.enabled == false)
    #expect(decoded.gitSync.branch == "main")
    #expect(decoded.gitSync.conflictStrategy == .remoteWins)
    #expect(decoded.sqlitePath == CoreConfig.defaultSQLiteFileName)
}

@Test
func missingVisorConfigFallsBackToDefaults() throws {
    let json =
        """
        {
          "listen": { "host": "0.0.0.0", "port": 25101 },
          "auth": { "token": "dev-token" },
          "models": [],
          "memory": { "backend": "sqlite-local-vectors" },
          "nodes": ["local"],
          "gateways": [],
          "plugins": [],
          "sqlitePath": "core.sqlite"
        }
        """

    let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(json.utf8))

    #expect(decoded.visor.scheduler.enabled)
    #expect(decoded.visor.scheduler.intervalSeconds == 300)
    #expect(decoded.visor.scheduler.jitterSeconds == 60)
    #expect(decoded.visor.bootstrapBulletin)
    #expect(decoded.browser.browserPath == "/usr/bin/chromium")
    #expect(decoded.browser.headless == true)
    #expect(decoded.browser.allowJavaScriptEvaluation == false)
    #expect(decoded.browser.profiles.isEmpty)
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
    #expect(resolved == "/tmp/slop/workspace-dev/sloppy.json")
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

@Test
func memoryProviderSupportsRemoteAliasAndKeepsSettings() throws {
    let json =
        """
        {
          "listen": { "host": "0.0.0.0", "port": 25101 },
          "workspace": { "name": "workspace", "basePath": "~" },
          "auth": { "token": "dev-token" },
          "models": [],
          "memory": {
            "backend": "sqlite-local-vectors",
            "provider": {
              "mode": "remote",
              "endpoint": "https://memory.example.com",
              "timeoutMs": 5000,
              "apiKeyEnv": "MEMORY_API_KEY"
            }
          },
          "nodes": ["local"],
          "gateways": [],
          "plugins": [],
          "channels": { "telegram": null },
          "sqlitePath": "core.sqlite"
        }
        """

    let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(json.utf8))
    #expect(decoded.memory.provider.mode == .http)
    #expect(decoded.memory.provider.endpoint == "https://memory.example.com")
    #expect(decoded.memory.provider.timeoutMs == 5000)
    #expect(decoded.memory.provider.apiKeyEnv == "MEMORY_API_KEY")
}

@Test
func discordChannelSettingsDecodeWhenPresent() throws {
    let json =
        """
        {
          "listen": { "host": "0.0.0.0", "port": 25101 },
          "workspace": { "name": "workspace", "basePath": "~" },
          "auth": { "token": "dev-token" },
          "models": [],
          "memory": { "backend": "sqlite-local-vectors" },
          "nodes": ["local"],
          "gateways": [],
          "plugins": [],
          "channels": {
            "discord": {
              "botToken": "discord-token",
              "channelDiscordChannelMap": {
                "general": "123456789012345678"
              },
              "allowedGuildIds": ["987654321098765432"],
              "allowedChannelIds": [],
              "allowedUserIds": ["555555555555555555"]
            },
            "telegram": null
          },
          "sqlitePath": "core.sqlite"
        }
        """

    let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(json.utf8))

    #expect(decoded.channels.discord?.botToken == "discord-token")
    #expect(decoded.channels.discord?.channelDiscordChannelMap["general"] == "123456789012345678")
    #expect(decoded.channels.discord?.allowedGuildIds == ["987654321098765432"])
    #expect(decoded.channels.discord?.allowedUserIds == ["555555555555555555"])
}

@Test
func discordChannelSettingsRoundTripPreservesStringIDs() throws {
    var config = CoreConfig.default
    config.channels = .init(
        discord: .init(
            botToken: "discord-token",
            channelDiscordChannelMap: [
                "general": "123456789012345678",
                "ops": "999999999999999999"
            ],
            allowedGuildIds: ["111111111111111111"],
            allowedChannelIds: ["123456789012345678"],
            allowedUserIds: ["222222222222222222"]
        )
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(CoreConfig.self, from: data)

    #expect(decoded.channels.discord?.channelDiscordChannelMap["general"] == "123456789012345678")
    #expect(decoded.channels.discord?.channelDiscordChannelMap["ops"] == "999999999999999999")
    #expect(decoded.channels.discord?.allowedGuildIds == ["111111111111111111"])
    #expect(decoded.channels.discord?.allowedChannelIds == ["123456789012345678"])
    #expect(decoded.channels.discord?.allowedUserIds == ["222222222222222222"])
}

@Test
func gitSyncSettingsDecodeWhenPresent() throws {
    let json =
        """
        {
          "listen": { "host": "0.0.0.0", "port": 25101 },
          "workspace": { "name": "workspace", "basePath": "~" },
          "auth": { "token": "dev-token" },
          "models": [],
          "memory": { "backend": "sqlite-local-vectors" },
          "nodes": ["local"],
          "gateways": [],
          "plugins": [],
          "channels": { "telegram": null },
          "gitSync": {
            "enabled": true,
            "authToken": "ghp_test",
            "repository": "acme/workspace-sync",
            "branch": "sync/main",
            "schedule": {
              "frequency": "daily",
              "time": "18:00"
            },
            "conflictStrategy": "remote_wins"
          },
          "sqlitePath": "core.sqlite"
        }
        """

    let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(json.utf8))
    #expect(decoded.gitSync.enabled == true)
    #expect(decoded.gitSync.authToken == "ghp_test")
    #expect(decoded.gitSync.repository == "acme/workspace-sync")
    #expect(decoded.gitSync.branch == "sync/main")
    #expect(decoded.gitSync.schedule.frequency == .daily)
    #expect(decoded.gitSync.schedule.time == "18:00")
    #expect(decoded.gitSync.conflictStrategy == .remoteWins)
}

@Test
func missingSearchToolsFallsBackToDefaults() throws {
    let json =
        """
        {
          "listen": { "host": "0.0.0.0", "port": 25101 },
          "auth": { "token": "dev-token" },
          "models": [],
          "memory": { "backend": "sqlite-local-vectors" },
          "nodes": ["local"],
          "gateways": [],
          "plugins": [],
          "sqlitePath": "core.sqlite"
        }
        """

    let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(json.utf8))

    #expect(decoded.searchTools.activeProvider == .perplexity)
    #expect(decoded.searchTools.providers.brave.apiKey.isEmpty)
    #expect(decoded.searchTools.providers.perplexity.apiKey.isEmpty)
}

@Test
func searchToolsDecodeWhenPresent() throws {
    let json =
        """
        {
          "listen": { "host": "0.0.0.0", "port": 25101 },
          "auth": { "token": "dev-token" },
          "models": [],
          "memory": { "backend": "sqlite-local-vectors" },
          "nodes": ["local"],
          "gateways": [],
          "plugins": [],
          "searchTools": {
            "activeProvider": "brave",
            "providers": {
              "brave": { "apiKey": "brave-config-key" },
              "perplexity": { "apiKey": "pplx-config-key" }
            }
          },
          "sqlitePath": "core.sqlite"
        }
        """

    let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(json.utf8))

    #expect(decoded.searchTools.activeProvider == .brave)
    #expect(decoded.searchTools.providers.brave.apiKey == "brave-config-key")
    #expect(decoded.searchTools.providers.perplexity.apiKey == "pplx-config-key")
}

@Test
func browserSettingsDecodeWhenPresent() throws {
    let json =
        """
        {
          "listen": { "host": "0.0.0.0", "port": 25101 },
          "workspace": { "name": "workspace", "basePath": "~" },
          "auth": { "token": "dev-token" },
          "models": [],
          "memory": { "backend": "sqlite-local-vectors" },
          "nodes": ["local"],
          "gateways": [],
          "plugins": [],
          "channels": { "telegram": null },
          "browser": {
            "browserPath": "/custom/chromium",
            "headless": false,
            "allowJavaScriptEvaluation": true,
            "profiles": [
              {
                "id": "work",
                "title": "Work",
                "userDataDir": "~/.config/chromium-work"
              },
              {
                "id": "personal",
                "title": "Personal",
                "userDataDir": "~/.config/chromium-personal",
                "profileDirectory": "Profile 2"
              }
            ]
          },
          "sqlitePath": "core.sqlite"
        }
        """

    let decoded = try JSONDecoder().decode(CoreConfig.self, from: Data(json.utf8))
    #expect(decoded.browser.browserPath == "/custom/chromium")
    #expect(decoded.browser.headless == false)
    #expect(decoded.browser.allowJavaScriptEvaluation == true)
    #expect(decoded.browser.profiles.count == 2)
    #expect(decoded.browser.profiles[0].profileDirectory == "Default")
    #expect(decoded.browser.profiles[1].profileDirectory == "Profile 2")
}

@Test
func browserSettingsRoundTripEncodeDecode() throws {
    var config = CoreConfig.default
    config.browser = .init(
        browserPath: "/usr/local/bin/chromium",
        headless: false,
        allowJavaScriptEvaluation: true,
        profiles: [
            .init(id: "work", title: "Work", userDataDir: ".profiles/work"),
            .init(id: "qa", title: "QA", userDataDir: ".profiles/qa", profileDirectory: "Profile 1")
        ]
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(CoreConfig.self, from: data)

    #expect(decoded.browser.browserPath == "/usr/local/bin/chromium")
    #expect(decoded.browser.headless == false)
    #expect(decoded.browser.allowJavaScriptEvaluation == true)
    #expect(decoded.browser.profiles.map(\.id) == ["work", "qa"])
    #expect(decoded.browser.profiles.map(\.profileDirectory) == ["Default", "Profile 1"])
}

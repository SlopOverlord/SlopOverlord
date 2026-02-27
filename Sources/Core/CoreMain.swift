import ArgumentParser
import Configuration
import Foundation
import Logging
import Protocols

@main
struct CoreMain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slopoverlord-core",
        abstract: "Starts SlopOverlord core runtime demo entrypoint."
    )

    @Option(name: [.short, .long], help: "Path to JSON config file")
    var configPath: String = CoreConfig.defaultConfigPath

    @Option(name: .long, help: "Generates an immediate visor bulletin after boot")
    var bootstrapBulletin: Bool = true

    @Flag(name: .long, help: "Runs demo request on startup")
    var runDemoRequest: Bool = false

    @Flag(name: .long, help: "Run one-shot startup flow and exit")
    var oneshot: Bool = false

    mutating func run() async throws {
        await LoggingBootstrapper.shared.bootstrapIfNeeded()
        let logger = Logger(label: "slopoverlord.core.main")

        var resolvedConfigPath = configPath
        var config = CoreConfig.load(from: resolvedConfigPath)

        if #available(macOS 15.0, *) {
            let envConfig = ConfigReader(providers: [EnvironmentVariablesProvider()])
            resolvedConfigPath = envConfig.string(forKey: "core.config.path", default: configPath)
            config = CoreConfig.load(from: resolvedConfigPath)
            config.listen.host = envConfig.string(forKey: "core.listen.host", default: config.listen.host)
            config.listen.port = envConfig.int(forKey: "core.listen.port", default: config.listen.port)
            config.workspace.name = envConfig.string(forKey: "core.workspace.name", default: config.workspace.name)
            let workspaceBasePath = envConfig.string(
                forKey: "core.workspace.base_path",
                default: config.workspace.basePath
            )
            config.workspace.basePath = envConfig.string(
                forKey: "core.workspace.basePath",
                default: workspaceBasePath
            )
            config.auth.token = envConfig.string(forKey: "core.auth.token", default: config.auth.token)
            config.sqlitePath = envConfig.string(forKey: "core.sqlite.path", default: config.sqlitePath)
        }

        let workspaceRoot = try prepareWorkspace(config: &config, logger: logger)
        logger.info("Workspace prepared at \(workspaceRoot.path)")

        let service = CoreService(config: config, configPath: resolvedConfigPath)
        let router = CoreRouter(service: service)
        let server = CoreHTTPServer(
            host: config.listen.host,
            port: config.listen.port,
            router: router,
            logger: logger
        )

        logger.info("SlopOverlord Core initialized")

        if !oneshot {
            try server.start()
            logger.info("Core HTTP server listening on \(config.listen.host):\(config.listen.port)")
        }

        if runDemoRequest {
            let sampleRequest = ChannelMessageRequest(
                userId: "demo-user",
                content: "Implement a feature and run tests"
            )
            let requestBody = try? JSONEncoder().encode(sampleRequest)
            let response = await router.handle(
                method: "POST",
                path: "/v1/channels/general/messages",
                body: requestBody
            )

            if let body = String(data: response.body, encoding: .utf8) {
                logger.info("POST /v1/channels/general/messages -> \(response.status) \(body)")
            }
        }

        if bootstrapBulletin {
            let bulletin = await service.triggerVisorBulletin()
            logger.info("Visor bulletin generated: \(bulletin.headline)")
        }

        // Daemon mode by default: keep process alive for container/service runtime.
        if !oneshot {
            logger.info("SlopOverlord Core daemon mode is active")
            defer { try? server.shutdown() }
            try server.waitUntilClosed()
        }
    }
}

private func prepareWorkspace(config: inout CoreConfig, logger: Logger) throws -> URL {
    let workspaceRoot = config.resolvedWorkspaceRootURL()

    do {
        try createWorkspaceDirectories(at: workspaceRoot)
        config.sqlitePath = resolveSQLitePath(sqlitePath: config.sqlitePath, workspaceRoot: workspaceRoot)
        return workspaceRoot
    } catch {
        let fallbackBasePath = "/tmp/slopoverlord"
        let fallbackRoot = URL(fileURLWithPath: fallbackBasePath, isDirectory: true)
            .appendingPathComponent(config.workspace.name, isDirectory: true)

        logger.warning(
            "Failed to create workspace at \(workspaceRoot.path), falling back to \(fallbackRoot.path): \(error)"
        )

        try createWorkspaceDirectories(at: fallbackRoot)
        config.workspace.basePath = fallbackBasePath
        config.sqlitePath = resolveSQLitePath(sqlitePath: config.sqlitePath, workspaceRoot: fallbackRoot)
        return fallbackRoot
    }
}

private func createWorkspaceDirectories(at workspaceRoot: URL) throws {
    let fileManager = FileManager.default
    let directories = [
        workspaceRoot,
        workspaceRoot.appendingPathComponent("agents", isDirectory: true),
        workspaceRoot.appendingPathComponent("sessions", isDirectory: true),
        workspaceRoot.appendingPathComponent("artifacts", isDirectory: true),
        workspaceRoot.appendingPathComponent("memory", isDirectory: true),
        workspaceRoot.appendingPathComponent("logs", isDirectory: true),
        workspaceRoot.appendingPathComponent("tmp", isDirectory: true)
    ]

    for directory in directories {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

private func resolveSQLitePath(sqlitePath: String, workspaceRoot: URL) -> String {
    if sqlitePath.hasPrefix("/") {
        return sqlitePath
    }
    return workspaceRoot.appendingPathComponent(sqlitePath).path
}

private actor LoggingBootstrapper {
    static let shared = LoggingBootstrapper()

    private var isBootstrapped = false

    func bootstrapIfNeeded() {
        guard !isBootstrapped else {
            return
        }

        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        isBootstrapped = true
    }
}

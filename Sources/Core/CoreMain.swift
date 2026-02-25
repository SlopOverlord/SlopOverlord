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
            config.auth.token = envConfig.string(forKey: "core.auth.token", default: config.auth.token)
            config.sqlitePath = envConfig.string(forKey: "core.sqlite.path", default: config.sqlitePath)
        }

        let service = CoreService(config: config)
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

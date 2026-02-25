import ArgumentParser
import Configuration
import Foundation
import Protocols

@main
struct CoreMain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slopoverlord-core",
        abstract: "Starts SlopOverlord core runtime demo entrypoint."
    )

    @Option(name: [.short, .long], help: "Path to JSON config file")
    var configPath: String = CoreConfig.defaultConfigPath

    @Flag(name: .long, help: "Generates an immediate visor bulletin after boot")
    var bootstrapBulletin: Bool = true

    mutating func run() async throws {
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

        print("SlopOverlord Core initialized on \(config.listen.host):\(config.listen.port)")

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
            print("POST /v1/channels/general/messages -> \(response.status) \(body)")
        }

        if bootstrapBulletin {
            let bulletin = await service.triggerVisorBulletin()
            print("Visor bulletin generated: \(bulletin.headline)")
        }
    }
}

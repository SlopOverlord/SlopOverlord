import ArgumentParser
import Foundation
import Logging

@main
struct NodeMain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slopoverlord-node",
        abstract: "Runs SlopOverlord node daemon entrypoint."
    )

    @Option(name: [.short, .long], help: "Node identifier")
    var nodeId: String = "node-local"

    @Option(name: .long, help: "Bootstrap command path")
    var command: String = "/bin/echo"

    @Option(name: .long, parsing: .upToNextOption, help: "Bootstrap command arguments")
    var arguments: [String] = ["Node daemon ready"]

    mutating func run() async throws {
        await LoggingBootstrapper.shared.bootstrapIfNeeded()
        let logger = Logger(label: "slopoverlord.node.main")

        let daemon = NodeDaemon(nodeId: nodeId)
        await daemon.connect()
        await daemon.heartbeat()

        do {
            let result = try await daemon.spawnProcess(command: command, arguments: arguments)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("Node \(daemon.nodeId) process exit=\(result.exitCode) stdout=\(stdout)")
        } catch {
            logger.error("Node daemon failed to spawn process: \(String(describing: error))")
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

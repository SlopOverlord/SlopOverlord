import ArgumentParser
import Foundation

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
        let daemon = NodeDaemon(nodeId: nodeId)
        await daemon.connect()
        await daemon.heartbeat()

        do {
            let result = try await daemon.spawnProcess(command: command, arguments: arguments)
            print(
                "Node \(daemon.nodeId) process exit=\(result.exitCode) " +
                "stdout=\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        } catch {
            print("Node daemon failed to spawn process: \(error)")
        }
    }
}

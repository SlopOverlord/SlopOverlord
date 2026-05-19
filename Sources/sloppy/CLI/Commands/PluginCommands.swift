import ArgumentParser
import Foundation
import Protocols

struct PluginCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins.",
        subcommands: [
            PluginListCommand.self,
            PluginGetCommand.self,
            PluginCreateCommand.self,
            PluginInstallCommand.self,
            PluginUpdateCommand.self,
            PluginDeleteCommand.self,
        ]
    )
}

struct PluginListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all plugins.")

    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/plugins")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct PluginGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get plugin details.")

    @Argument(help: "Plugin ID") var pluginId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/plugins/\(pluginId)")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct PluginCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a plugin from a JSON file.")

    @Option(name: .long, help: "Path to JSON payload file") var file: String?
    @Option(name: .long, help: "Inline JSON string") var json: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        let body: Data
        if let file {
            body = try Data(contentsOf: URL(fileURLWithPath: file))
        } else if let json, let data = json.data(using: .utf8) {
            body = data
        } else {
            CLIStyle.error("Provide --file or --json."); throw ExitCode.failure
        }
        do {
            let data = try await client.post("/v1/plugins", body: body)
            CLIStyle.success("Plugin created.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct PluginInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a source plugin from a Git URL or local directory.")

    @Argument(help: "Plugin package Git URL or local directory") var sourceUrl: String
    @Option(name: .long, help: "Git ref, branch, or tag to checkout") var ref: String?
    @Flag(name: .customLong("local"), help: "Copy plugin package from a local directory instead of cloning with Git") var local: Bool = false
    @Flag(name: .customLong("local-directory"), help: "Copy plugin package from a local directory instead of cloning with Git") var localDirectory: Bool = false
    @Flag(name: .long, help: "Replace an existing plugin with the same plugin.json name") var force: Bool = false
    @Flag(name: .long, help: "Install and build without starting the plugin") var disabled: Bool = false
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        let request = ChannelPluginInstallRequest(
            sourceUrl: sourceUrl,
            ref: ref,
            force: force,
            enabled: !disabled,
            localDirectory: local || localDirectory
        )
        do {
            let body = try client.encode(request)
            let data = try await client.post("/v1/plugins/install", body: body)
            CLIStyle.success("Plugin installed.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct PluginUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a plugin from a JSON file.")

    @Argument(help: "Plugin ID") var pluginId: String
    @Option(name: .long, help: "Path to JSON payload file") var file: String?
    @Option(name: .long, help: "Inline JSON string") var json: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        let body: Data
        if let file {
            body = try Data(contentsOf: URL(fileURLWithPath: file))
        } else if let json, let data = json.data(using: .utf8) {
            body = data
        } else {
            CLIStyle.error("Provide --file or --json."); throw ExitCode.failure
        }
        do {
            let data = try await client.put("/v1/plugins/\(pluginId)", body: body)
            CLIStyle.success("Plugin updated.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct PluginDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a plugin.")

    @Argument(help: "Plugin ID") var pluginId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/plugins/\(pluginId)")
            CLIStyle.success("Plugin \(CLIStyle.whiteBold(pluginId)) deleted.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

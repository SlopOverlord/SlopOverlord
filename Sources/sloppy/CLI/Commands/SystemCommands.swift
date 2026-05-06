import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check server health."
    )

    @Option(name: .long, help: "Sloppy server URL") var url: String?
    @Option(name: .long, help: "Auth token") var token: String?
    @Flag(name: .long, help: "Show detailed HTTP info") var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/health")
            CLIStyle.success("Server is healthy at \(client.baseURL)")
            if verbose { CLIFormatters.printJSON(data) }
        } catch {
            CLIStyle.error(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for a newer version of Sloppy, or install source updates."
    )

    @Option(name: .long, help: "Sloppy server URL") var url: String?
    @Option(name: .long, help: "Auth token") var token: String?
    @Option(name: .long, help: "Output format: json, table") var format: String = "json"
    @Option(name: .long, help: "Source checkout to update. Defaults to the checkout that built this sloppy binary.")
    var dir: String?
    @Flag(name: .long, help: "Pull and reinstall from the source checkout without requiring a running server.")
    var install: Bool = false
    @Flag(name: .long, help: "Build only the server stack when installing.")
    var serverOnly: Bool = false
    @Flag(name: .long, help: "Do not pull the source checkout before rebuilding.")
    var noGitUpdate: Bool = false
    @Flag(name: .long, help: "Do not create or refresh the sloppy command symlink.")
    var noLink: Bool = false
    @Flag(name: .long, help: "Print installer actions without executing them.")
    var dryRun: Bool = false
    @Flag(name: .long, help: "Show detailed HTTP info") var verbose: Bool = false

    mutating func run() async throws {
        if install {
            try runSourceInstall()
            return
        }

        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.post("/v1/updates/check")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let updateAvailable = json["updateAvailable"] as? Bool {
                if updateAvailable {
                    let latest = json["latestVersion"] as? String ?? "unknown"
                    let current = json["currentVersion"] as? String ?? SloppyVersion.current
                    let updateKind = json["updateKind"] as? String ?? "release"
                    if updateKind == "git" {
                        let branch = json["latestBranch"] as? String ?? json["currentBranch"] as? String ?? "upstream"
                        let commit = json["latestCommit"] as? String ?? latest
                        print(CLIStyle.yellow("Update available:") + " \(CLIStyle.whiteBold(commit)) on \(branch) (current: \(current))")
                        print(CLIStyle.dim("  Run: sloppy update --install"))
                    } else {
                        print(CLIStyle.yellow("Update available:") + " \(CLIStyle.whiteBold(latest)) (current: \(current))")
                    }
                    if let releaseUrl = json["releaseUrl"] as? String {
                        print(CLIStyle.dim("  Release: \(releaseUrl)"))
                    }
                } else {
                    CLIStyle.success("sloppy is up to date (\(json["currentVersion"] as? String ?? SloppyVersion.current))")
                }
            } else {
                CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
            }
        } catch {
            CLIStyle.error(error.localizedDescription)
            throw ExitCode.failure
        }
    }

    private func runSourceInstall() throws {
        let repoURL = try resolveSourceCheckoutURL()
        let scriptURL = repoURL
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("install.sh")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            CLIStyle.error("Cannot find source installer at \(scriptURL.path).")
            throw ExitCode.failure
        }

        let metadata = BuildMetadataResolver(repositoryRootURL: repoURL).resolve()
        let branch = metadata.git?.currentBranch ?? metadata.git?.upstreamBranch ?? "current branch"
        let mode = serverOnly ? "--server-only" : "--bundle"
        print(CLIStyle.cyan("Updating source checkout:") + " \(repoURL.path)")
        print(CLIStyle.cyan("Branch:") + " \(branch)")

        var arguments = [
            "bash",
            scriptURL.path,
            mode,
            "--dir",
            repoURL.path,
            "--no-prompt"
        ]
        if noGitUpdate {
            arguments.append("--no-git-update")
        }
        if noLink {
            arguments.append("--no-link")
        }
        if dryRun {
            arguments.append("--dry-run")
        }
        if verbose {
            arguments.append("--verbose")
        }

        let status = runInstaller(arguments: arguments)
        guard status == 0 else {
            CLIStyle.error("Source update failed with exit code \(status).")
            throw ExitCode.failure
        }

        CLIStyle.success("Source update complete.")
    }

    private func resolveSourceCheckoutURL() throws -> URL {
        if let dir, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }

        let metadata = BuildMetadataResolver().resolve()
        if let path = metadata.git?.repositoryRootPath {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        if let executableURL = currentExecutableURL(),
           let repoURL = repoRootDerivedFromExecutable(executableURL: executableURL) {
            return repoURL
        }

        CLIStyle.error("Cannot determine the source checkout for this sloppy binary. Pass --dir /path/to/Sloppy.")
        throw ExitCode.failure
    }

    private func runInstaller(arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.environment = childProcessEnvironment()

        do {
            try process.run()
        } catch {
            CLIStyle.error("Failed to start installer: \(error.localizedDescription)")
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "View system logs."
    )

    @Option(name: .long, help: "Sloppy server URL") var url: String?
    @Option(name: .long, help: "Auth token") var token: String?
    @Option(name: .long, help: "Output format: json, table") var format: String = "json"
    @Flag(name: .long, help: "Show detailed HTTP info") var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/logs")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}

struct WorkersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workers",
        abstract: "List active workers."
    )

    @Option(name: .long, help: "Sloppy server URL") var url: String?
    @Option(name: .long, help: "Auth token") var token: String?
    @Option(name: .long, help: "Output format: json, table") var format: String = "json"
    @Flag(name: .long, help: "Show detailed HTTP info") var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/workers")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}

struct BulletinsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bulletins",
        abstract: "View system bulletins."
    )

    @Option(name: .long, help: "Sloppy server URL") var url: String?
    @Option(name: .long, help: "Auth token") var token: String?
    @Option(name: .long, help: "Output format: json, table") var format: String = "json"
    @Flag(name: .long, help: "Show detailed HTTP info") var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/bulletins")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}

struct TokenUsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token-usage",
        abstract: "View token usage statistics."
    )

    @Option(name: .long, help: "Sloppy server URL") var url: String?
    @Option(name: .long, help: "Auth token") var token: String?
    @Option(name: .long, help: "Output format: json, table") var format: String = "json"
    @Flag(name: .long, help: "Show detailed HTTP info") var verbose: Bool = false
    @Option(name: .long, help: "Filter by channel ID") var channelId: String?
    @Option(name: .long, help: "Filter by task ID") var taskId: String?
    @Option(name: .long, help: "Filter from date (ISO 8601)") var from: String?
    @Option(name: .long, help: "Filter to date (ISO 8601)") var to: String?

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var query: [String: String] = [:]
        if let channelId { query["channelId"] = channelId }
        if let taskId { query["taskId"] = taskId }
        if let from { query["from"] = from }
        if let to { query["to"] = to }
        do {
            let data = try await client.get("/v1/token-usage", query: query)
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}

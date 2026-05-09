import ArgumentParser
import Foundation

struct ProjectCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Manage projects, tasks, channels.",
        subcommands: [
            ProjectListCommand.self,
            ProjectGetCommand.self,
            ProjectCreateCommand.self,
            ProjectUpdateCommand.self,
            ProjectDeleteCommand.self,
            ProjectTaskSyncCommand.self,
            ProjectTaskCommand.self,
            ProjectChannelCommand.self,
            ProjectMemoryCommand.self,
        ]
    )
}

// MARK: - Project CRUD

struct ProjectListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all projects.")

    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/projects")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get project details.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/projects/\(projectId)")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new project.")

    @Option(name: .long, help: "Project name") var name: String
    @Option(name: .long, help: "Project description") var description: String?
    @Option(name: .long, help: "Repository URL") var repoUrl: String?
    @Option(name: .long, help: "Local repository or project path") var repoPath: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = ["name": name]
        if let description { payload["description"] = description }
        if let repoUrl { payload["repoUrl"] = repoUrl }
        if let repoPath { payload["repoPath"] = repoPath }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/projects", body: body)
            CLIStyle.success("Project created.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a project.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long, help: "New name") var name: String?
    @Option(name: .long, help: "New description") var description: String?
    @Option(name: .long, help: "New repo path") var repoPath: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let name { payload["name"] = name }
        if let description { payload["description"] = description }
        if let repoPath { payload["repoPath"] = repoPath }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.patch("/v1/projects/\(projectId)", body: body)
            CLIStyle.success("Project updated.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a project.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/projects/\(projectId)")
            CLIStyle.success("Project \(CLIStyle.whiteBold(projectId)) deleted.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Task Sync

struct ProjectTaskSyncCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "task-sync",
        abstract: "Manage project task sync.",
        subcommands: [
            ProjectTaskSyncStatusCommand.self,
            ProjectTaskSyncLinkCommand.self,
            ProjectTaskSyncSyncCommand.self,
            ProjectTaskSyncUnlinkCommand.self,
            ProjectTaskSyncTokenCommand.self,
        ]
    )
}

struct ProjectTaskSyncStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show task sync status.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/projects/\(projectId)/task-sync")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskSyncLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link", abstract: "Link GitHub Projects task sync.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long, help: "GitHub Project URL") var projectUrl: String
    @Option(name: .long, help: "Default issue repository owner/repo") var defaultRepo: String?
    @Option(name: .long, help: "Token mode: inherit or override") var tokenMode: String = "inherit"
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [
            "providerId": "github",
            "projectURL": projectUrl,
            "tokenMode": tokenMode
        ]
        if let defaultRepo { payload["defaultRepo"] = defaultRepo }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/projects/\(projectId)/task-sync/link", body: body)
            CLIStyle.success("Task sync linked.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskSyncSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Run manual task sync.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.post("/v1/projects/\(projectId)/task-sync/sync-now")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskSyncUnlinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unlink", abstract: "Disable task sync.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.post("/v1/projects/\(projectId)/task-sync/unlink")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskSyncTokenCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Manage project task sync token override.",
        subcommands: [
            ProjectTaskSyncTokenSetCommand.self,
            ProjectTaskSyncTokenClearCommand.self,
        ]
    )
}

struct ProjectTaskSyncTokenSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set project task sync token override.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long, help: "GitHub token") var githubToken: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let body = try JSONSerialization.data(withJSONObject: ["token": githubToken])
            let data = try await client.post("/v1/projects/\(projectId)/task-sync/token?providerId=github", body: body)
            CLIStyle.success("Task sync token saved.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskSyncTokenClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear project task sync token override.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.delete("/v1/projects/\(projectId)/task-sync/token?providerId=github")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Tasks

struct ProjectTaskCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "task",
        abstract: "Manage project tasks.",
        subcommands: [
            ProjectTaskListCommand.self,
            ProjectTaskGetCommand.self,
            ProjectTaskCreateCommand.self,
            ProjectTaskUpdateCommand.self,
            ProjectTaskDeleteCommand.self,
            ProjectTaskApproveCommand.self,
            ProjectTaskRejectCommand.self,
            ProjectTaskDiffCommand.self,
        ]
    )
}

struct ProjectTaskListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List project tasks.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/projects/\(projectId)")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get task details.")

    @Argument(help: "Project ID") var projectId: String
    @Argument(help: "Task ID") var taskId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/projects/\(projectId)/tasks/\(taskId)")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a task.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long, help: "Task title") var title: String
    @Option(name: .long, help: "Task description") var description: String?
    @Option(name: .long, help: "Priority: low, medium, high") var priority: String?
    @Option(name: .long, help: "Assignee actor ID") var actorId: String?
    @Option(name: .long, help: "Channel ID") var channelId: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = ["title": title]
        if let description { payload["description"] = description }
        if let priority { payload["priority"] = priority }
        if let actorId { payload["actorId"] = actorId }
        if let channelId { payload["channelId"] = channelId }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/projects/\(projectId)/tasks", body: body)
            CLIStyle.success("Task created.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a task.")

    @Argument(help: "Project ID") var projectId: String
    @Argument(help: "Task ID") var taskId: String
    @Option(name: .long) var title: String?
    @Option(name: .long) var description: String?
    @Option(name: .long) var status: String?
    @Option(name: .long) var priority: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let description { payload["description"] = description }
        if let status { payload["status"] = status }
        if let priority { payload["priority"] = priority }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.patch("/v1/projects/\(projectId)/tasks/\(taskId)", body: body)
            CLIStyle.success("Task updated.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a task.")

    @Argument(help: "Project ID") var projectId: String
    @Argument(help: "Task ID") var taskId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/projects/\(projectId)/tasks/\(taskId)")
            CLIStyle.success("Task \(CLIStyle.whiteBold(taskId)) deleted.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskApproveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "approve", abstract: "Approve a task review.")

    @Argument(help: "Project ID") var projectId: String
    @Argument(help: "Task ID") var taskId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.post("/v1/projects/\(projectId)/tasks/\(taskId)/approve")
            CLIStyle.success("Task \(CLIStyle.whiteBold(taskId)) approved.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskRejectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reject", abstract: "Reject a task review.")

    @Argument(help: "Project ID") var projectId: String
    @Argument(help: "Task ID") var taskId: String
    @Option(name: .long, help: "Rejection reason") var reason: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let reason { payload["reason"] = reason }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            _ = try await client.post("/v1/projects/\(projectId)/tasks/\(taskId)/reject", body: body)
            CLIStyle.success("Task \(CLIStyle.whiteBold(taskId)) rejected.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectTaskDiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "Get git diff for a task.")

    @Argument(help: "Project ID") var projectId: String
    @Argument(help: "Task ID") var taskId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/projects/\(projectId)/tasks/\(taskId)/diff")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Channels

struct ProjectChannelCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "channel",
        abstract: "Manage project channels.",
        subcommands: [ProjectChannelCreateCommand.self, ProjectChannelDeleteCommand.self]
    )
}

struct ProjectChannelCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Add a channel to a project.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long, help: "Channel ID") var channelId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        let payload: [String: Any] = ["channelId": channelId]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/projects/\(projectId)/channels", body: body)
            CLIStyle.success("Channel added.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct ProjectChannelDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Remove a channel from a project.")

    @Argument(help: "Project ID") var projectId: String
    @Argument(help: "Channel ID") var channelId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/projects/\(projectId)/channels/\(channelId)")
            CLIStyle.success("Channel \(CLIStyle.whiteBold(channelId)) removed.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Memory

struct ProjectMemoryCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "View project memories.",
        subcommands: [ProjectMemoryListCommand.self]
    )
}

struct ProjectMemoryListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List project memories.")

    @Argument(help: "Project ID") var projectId: String
    @Option(name: .long, help: "Search query") var search: String?
    @Option(name: .long) var limit: Int = 20
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var query: [String: String] = ["limit": "\(limit)"]
        if let search { query["search"] = search }
        do {
            let data = try await client.get("/v1/projects/\(projectId)/memories", query: query)
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

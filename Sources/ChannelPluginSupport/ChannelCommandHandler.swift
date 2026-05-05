import Foundation

public struct BotCommand: Sendable {
    public let name: String
    public let description: String
    public let argument: String?
    public let surfaces: Set<BotCommandSurface>

    public init(
        name: String,
        description: String,
        argument: String? = nil,
        surfaces: Set<BotCommandSurface> = [.telegram, .discord, .dashboard]
    ) {
        self.name = name
        self.description = description
        self.argument = argument
        self.surfaces = surfaces
    }
}

public enum BotCommandSurface: String, Sendable {
    case telegram
    case discord
    case dashboard
    case tui
}

public struct MessageContext: Sendable {
    public let channelId: String
    public let userId: String
    public let platform: String
    public let displayName: String

    public init(channelId: String, userId: String, platform: String, displayName: String) {
        self.channelId = channelId
        self.userId = userId
        self.platform = platform
        self.displayName = displayName
    }
}

/// Handles shared channel bot commands across built-in gateway plugins.
public struct ChannelCommandHandler: Sendable {
    public static let allCommands: [BotCommand] = [
        BotCommand(name: "help", description: "Show available commands"),
        BotCommand(name: "status", description: "Check plugin connectivity"),
        BotCommand(name: "new", description: "Start a new session with the agent"),
        BotCommand(name: "whoami", description: "Show channel and user info"),
        BotCommand(name: "task", description: "Create a task via Sloppy", argument: "description"),
        BotCommand(name: "model", description: "Show or switch model", argument: "model_id"),
        BotCommand(name: "mode", description: "Set chat mode", argument: "ask|build|plan|debug"),
        BotCommand(name: "channel_link", description: "Link this channel or topic to a project"),
        BotCommand(name: "context", description: "Show token usage and context info"),
        BotCommand(name: "abort", description: "Abort current agent processing"),
        BotCommand(name: "btw", description: "Ask a quick side question without interrupting the main conversation", argument: "message", surfaces: [.telegram, .discord, .dashboard]),
        BotCommand(name: "compact", description: "Free up context by summarizing the conversation so far", surfaces: [.telegram, .dashboard]),
        BotCommand(name: "add_dir", description: "Add a working directory to this session", argument: "path", surfaces: [.telegram, .dashboard, .tui]),
        BotCommand(name: "create-skill", description: "Create a new agent skill", argument: "description"),
        BotCommand(name: "create-subagent", description: "Create a subagent", argument: "description"),
        BotCommand(name: "fork", description: "Create a branch of the current conversation", argument: "task", surfaces: [.telegram, .discord, .dashboard]),
        BotCommand(name: "diff", description: "Show uncommitted changes and per-turn diffs", surfaces: [.telegram]),
    ]

    public static let commands: [BotCommand] = allCommands.filter {
        $0.surfaces.contains(.telegram) && $0.surfaces.contains(.discord)
    }

    public static func commands(for surface: BotCommandSurface) -> [BotCommand] {
        allCommands.filter { $0.surfaces.contains(surface) }
    }

    private let platformName: String
    private let surface: BotCommandSurface?

    public init(platformName: String) {
        self.platformName = platformName
        switch platformName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram":
            self.surface = .telegram
        case "discord":
            self.surface = .discord
        default:
            self.surface = nil
        }
    }

    public func handle(text: String, context: MessageContext, skillSlashTokensLowercased: Set<String> = []) -> String? {
        let lower = text.lowercased()
        let visibleCommands = surface.map { Self.commands(for: $0) } ?? Self.commands
        let visibleCommandNames = Set(visibleCommands.map { $0.name.lowercased() })

        if lower == "/start" || lower == "/help" {
            let lines = visibleCommands.map { cmd -> String in
                let usage = cmd.argument.map { " <\($0)>" } ?? ""
                let padded = "/\(cmd.name)\(usage)".padding(toLength: 26, withPad: " ", startingAt: 0)
                return "\(padded)— \(cmd.description)"
            }.joined(separator: "\n")
            return """
            Sloppy Channel Plugin (\(platformName))

            Available commands:
            \(lines)

            Any other message is forwarded to the linked Sloppy channel.
            """
        }

        if lower == "/status" {
            return nil
        }

        if lower == "/whoami" {
            return """
            channel_id: \(context.channelId)
            user_id: \(context.userId)
            platform: \(context.platform)
            display_name: \(context.displayName)
            """
        }

        if lower == "/new" {
            return nil
        }

        if lower.hasPrefix("/task ") {
            return nil
        }

        if lower == "/model" || lower.hasPrefix("/model ") {
            return nil
        }

        if lower == "/channel_link" || lower.hasPrefix("/channel_link ") {
            return nil
        }

        if lower == "/context" {
            return nil
        }

        if lower == "/abort" {
            return nil
        }

        if lower == "/btw" || lower.hasPrefix("/btw ") {
            return nil
        }

        if lower == "/compact", visibleCommandNames.contains("compact") {
            return nil
        }

        if ChannelAddDirCommandParsing.pathTailIfCommand(text) != nil,
           visibleCommandNames.contains("add_dir") {
            return nil
        }

        if lower.hasPrefix("/create-skill") {
            return nil
        }

        if lower.hasPrefix("/create-subagent") {
            return nil
        }

        if lower.hasPrefix("/fork") {
            return nil
        }

        if (lower == "/diff" || lower.hasPrefix("/diff ")), visibleCommandNames.contains("diff") {
            return nil
        }

        if lower.hasPrefix("/"),
           !skillSlashTokensLowercased.isEmpty,
           let token = ChannelSlashLineParsing.firstCommandTokenLowercased(text),
           skillSlashTokensLowercased.contains(token) {
            return nil
        }

        if lower.hasPrefix("/") {
            return "Unknown command. Send /help for available commands."
        }

        return nil
    }
}

public enum ChannelAddDirCommandParsing: Sendable {
    public static func pathTailIfCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }

        guard let commandEnd = trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) else {
            return isAddDirCommandToken(trimmed) ? "" : nil
        }
        let command = String(trimmed[..<commandEnd.lowerBound])
        guard isAddDirCommandToken(command) else {
            return nil
        }

        return strippedOuterQuotes(String(trimmed[commandEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isAddDirCommandToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower == "/add-dir" || lower == "/add_dir"
    }

    private static func strippedOuterQuotes(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

// MARK: - Slash command @bot targeting (Telegram / Discord)

public enum ChannelSlashBotTargeting: Sendable {
    /// `/cmd@otherbot` is meant for another bot — return `false` so this gateway ignores the update.
    public static func telegramCommandTargetsThisBot(commandText: String, ourBotUsernameLowercased: String) -> Bool {
        guard !ourBotUsernameLowercased.isEmpty else { return true }
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return true }
        let withoutSlash = trimmed.dropFirst()
        let firstSegment = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let at = firstSegment.firstIndex(of: "@") else { return true }
        let suffix = String(firstSegment[firstSegment.index(after: at)...]).lowercased()
        guard !suffix.isEmpty else { return true }
        return suffix == ourBotUsernameLowercased
    }

    /// Turns `/model@mybot gpt` → `/model gpt` for core command parsers (must already match ``telegramCommandTargetsThisBot``).
    public static func stripTelegramBotUsernameSuffix(commandText: String, ourBotUsernameLowercased: String) -> String {
        guard !ourBotUsernameLowercased.isEmpty else { return commandText }
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return commandText }
        let withoutSlash = trimmed.dropFirst()
        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let rawCmd = parts.first else { return commandText }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        let cmdStr = String(rawCmd)
        guard let at = cmdStr.firstIndex(of: "@") else { return commandText }
        let suffix = String(cmdStr[cmdStr.index(after: at)...]).lowercased()
        guard suffix == ourBotUsernameLowercased else { return commandText }
        let cmdBase = String(cmdStr[..<at])
        if rest.isEmpty {
            return "/" + cmdBase
        }
        return "/" + cmdBase + " " + rest
    }
}

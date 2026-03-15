import Foundation

/// Handles shared channel bot commands across built-in gateway plugins.
public struct ChannelCommandHandler: Sendable {
    private let platformName: String

    public init(platformName: String) {
        self.platformName = platformName
    }

    public func handle(text: String, from displayName: String) -> String? {
        _ = displayName
        let lower = text.lowercased()

        if lower == "/start" || lower == "/help" {
            return """
            Sloppy Channel Plugin (\(platformName))

            Available commands:
            /help              — show this message
            /status            — check plugin connectivity
            /task <description> — create a task via Core
            /model             — show current model and available options
            /model <model_id>  — switch to a specific model

            Any other message is forwarded to the linked Sloppy channel.
            """
        }

        if lower == "/status" {
            return "Plugin is running. Messages are forwarded to Core."
        }

        if lower.hasPrefix("/task ") {
            return nil
        }

        if lower == "/model" || lower.hasPrefix("/model ") {
            return nil
        }

        if lower.hasPrefix("/") {
            return "Unknown command. Send /help for available commands."
        }

        return nil
    }
}

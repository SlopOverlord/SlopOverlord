import Foundation

/// Handles Telegram bot commands (/start, /help, /task, /status).
/// Returns a response string if the command was handled locally, or nil if it
/// should be forwarded to Core as a regular message.
struct CommandHandler: Sendable {
    func handle(text: String, from displayName: String) -> String? {
        let lower = text.lowercased()

        if lower == "/start" || lower == "/help" {
            return """
            SlopOverlord Channel Plugin (Telegram)

            Available commands:
            /help   — show this message
            /status — check plugin connectivity
            /task <description> — create a task via Core

            Any other message is forwarded to the linked SlopOverlord channel.
            """
        }

        if lower == "/status" {
            return "Plugin is running. Messages are forwarded to Core."
        }

        if lower.hasPrefix("/task ") {
            return nil
        }

        if lower.hasPrefix("/") {
            return "Unknown command. Send /help for available commands."
        }

        return nil
    }

    /// Transforms /task commands into plain content suitable for Core.
    func transformForCore(text: String, from displayName: String) -> String {
        let lower = text.lowercased()
        if lower.hasPrefix("/task ") {
            let description = String(text.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "Create task: \(description)"
        }
        return text
    }
}

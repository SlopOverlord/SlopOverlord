import Foundation

/// Character limits for agent markdown files (`String.count`, extended grapheme clusters).
public enum AgentMarkdownLimits: Sendable {
    public static let userMarkdownMaxCharacters = 2000
    public static let friendReminderMarkdownMaxCharacters = 2000
    public static let memoryMarkdownMaxCharacters = 3000
    public static let projectMetaMemoryMarkdownMaxCharacters = 3000

    public static func validateUserMarkdown(_ text: String) throws {
        if text.count > userMarkdownMaxCharacters {
            throw AgentDocumentLengthError.exceeded(resource: "USER.md", limit: userMarkdownMaxCharacters)
        }
    }

    public static func validateMemoryMarkdown(_ text: String) throws {
        if text.count > memoryMarkdownMaxCharacters {
            throw AgentDocumentLengthError.exceeded(resource: "MEMORY.md", limit: memoryMarkdownMaxCharacters)
        }
    }

    public static func validateFriendReminderMarkdown(_ text: String) throws {
        if text.count > friendReminderMarkdownMaxCharacters {
            throw AgentDocumentLengthError.exceeded(resource: "FRIEND_REMINDER.md", limit: friendReminderMarkdownMaxCharacters)
        }
    }

    public static func validateProjectMetaMemoryMarkdown(_ text: String) throws {
        if text.count > projectMetaMemoryMarkdownMaxCharacters {
            throw AgentDocumentLengthError.exceeded(
                resource: ".meta/MEMORY.md",
                limit: projectMetaMemoryMarkdownMaxCharacters
            )
        }
    }

    public static func validateAgentDocumentBundle(_ documents: AgentDocumentBundle) throws {
        try validateUserMarkdown(documents.userMarkdown)
        try validateFriendReminderMarkdown(documents.friendReminderMarkdown)
        try validateMemoryMarkdown(documents.memoryMarkdown)
    }
}

public enum AgentDocumentLengthError: Error, Sendable, Equatable {
    case exceeded(resource: String, limit: Int)
}

public enum AgentMarkdownDocumentField: String, Sendable, Codable {
    case user
    case memory
}

import Foundation
import Protocols

enum ToolCatalog {
    static let entries: [AgentToolCatalogEntry] = [
        .init(
            id: "files.read",
            domain: "files",
            title: "Read file",
            status: "fully_functional",
            description: "Read UTF-8 text file from workspace."
        ),
        .init(
            id: "files.edit",
            domain: "files",
            title: "Edit file",
            status: "fully_functional",
            description: "Replace exact text fragment in file."
        ),
        .init(
            id: "files.write",
            domain: "files",
            title: "Write file",
            status: "fully_functional",
            description: "Create or overwrite UTF-8 file in workspace."
        ),
        .init(
            id: "web.search",
            domain: "web",
            title: "Web search",
            status: "adapter",
            description: "Search web via external adapter."
        ),
        .init(
            id: "web.fetch",
            domain: "web",
            title: "Web fetch",
            status: "adapter",
            description: "Fetch URL content via external adapter."
        ),
        .init(
            id: "runtime.exec",
            domain: "runtime",
            title: "Exec command",
            status: "fully_functional",
            description: "Run one foreground command with timeout and output limits."
        ),
        .init(
            id: "runtime.process",
            domain: "runtime",
            title: "Manage process",
            status: "fully_functional",
            description: "Start, inspect, list, and stop background session processes."
        ),
        .init(
            id: "memory.get",
            domain: "memory",
            title: "Memory semantic search",
            status: "adapter",
            description: "Semantic memory retrieval via external adapter."
        ),
        .init(
            id: "memory.search",
            domain: "memory",
            title: "Memory file search",
            status: "adapter",
            description: "Search memory files via external adapter."
        ),
        .init(
            id: "messages.send",
            domain: "messages",
            title: "Send message",
            status: "fully_functional",
            description: "Send message into current or target session."
        ),
        .init(
            id: "sessions.spawn",
            domain: "session",
            title: "Spawn session",
            status: "fully_functional",
            description: "Create child or standalone session."
        ),
        .init(
            id: "sessions.list",
            domain: "session",
            title: "List sessions",
            status: "fully_functional",
            description: "List sessions for current agent."
        ),
        .init(
            id: "sessions.history",
            domain: "session",
            title: "Session history",
            status: "fully_functional",
            description: "Read full event history for one session."
        ),
        .init(
            id: "sessions.status",
            domain: "session",
            title: "Session status",
            status: "fully_functional",
            description: "Read summary status for one session."
        ),
        .init(
            id: "sessions.send",
            domain: "session",
            title: "Send to session",
            status: "fully_functional",
            description: "Send user message into target session."
        ),
        .init(
            id: "agents.list",
            domain: "agents",
            title: "List agents",
            status: "fully_functional",
            description: "List all known agents."
        ),
        .init(
            id: "cron",
            domain: "automation",
            title: "Schedule task",
            status: "adapter",
            description: "Schedule recurring task via external adapter."
        ),
        .init(
            id: "project.task_list",
            domain: "project",
            title: "List project tasks",
            status: "fully_functional",
            description: "List tasks for the project associated with the current channel."
        ),
        .init(
            id: "project.task_create",
            domain: "project",
            title: "Create project task",
            status: "fully_functional",
            description: "Create a new task in the project associated with the current channel."
        ),
        .init(
            id: "project.escalate_to_user",
            domain: "project",
            title: "Escalate to user",
            status: "fully_functional",
            description: "Escalate a task or issue to the human user with a reason, sending a notification to the channel."
        ),
        .init(
            id: "actor.discuss_with_actor",
            domain: "actor",
            title: "Discuss with actor",
            status: "fully_functional",
            description: "Initiate LLM-to-LLM discussion with another actor on a topic. Returns the other actor's response."
        ),
        .init(
            id: "actor.conclude_discussion",
            domain: "actor",
            title: "Conclude discussion",
            status: "fully_functional",
            description: "End an ongoing LLM-to-LLM discussion with another actor, summarizing the outcome."
        ),
        .init(
            id: "channel.history",
            domain: "channel",
            title: "Channel history",
            status: "fully_functional",
            description: "Read message history for a channel. Parameters: channel_id (string, required), limit (number, optional, default 50)."
        )
    ]

    static let knownToolIDs: Set<String> = Set(entries.map(\.id))
}

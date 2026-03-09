import Foundation
import Protocols

enum ToolCatalog {
    static let entries: [AgentToolCatalogEntry] = [
        .init(
            id: "system.list_tools",
            domain: "system",
            title: "List tools",
            status: "fully_functional",
            description: "Return the available tool catalog with argument schemas."
        ),
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
            status: "fully_functional",
            description: "Search web via configured Brave or Perplexity provider."
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
            status: "fully_functional",
            description: "Semantic memory retrieval via hybrid memory store."
        ),
        .init(
            id: "memory.recall",
            domain: "memory",
            title: "Memory recall",
            status: "fully_functional",
            description: "Recall scoped memory using hybrid retrieval."
        ),
        .init(
            id: "memory.save",
            domain: "memory",
            title: "Memory save",
            status: "fully_functional",
            description: "Persist memory entry with taxonomy and scope."
        ),
        .init(
            id: "memory.search",
            domain: "memory",
            title: "Memory file search",
            status: "fully_functional",
            description: "Keyword search in memory via canonical local index."
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
            status: "fully_functional",
            description: "Schedule a recurring background task. Parameters: schedule (cron expression string like '*/5 * * * *'), command (string), channel_id (string, optional, defaults to current session)."
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
            id: "project.task_get",
            domain: "project",
            title: "Get project task",
            status: "fully_functional",
            description: "Get full task details by readable id (for example, MOBILE-1). Accepts taskId or reference."
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

    static func listToolsPayload() -> [JSONValue] {
        entries.map { entry in
            .object([
                "name": .string(entry.id),
                "title": .string(entry.title),
                "domain": .string(entry.domain),
                "status": .string(entry.status),
                "description": .string(entry.description),
                "parameters": parameterSchema(for: entry.id)
            ])
        }
    }

    static let knownToolIDs: Set<String> = Set(entries.map(\.id))

    private static func parameterSchema(for toolID: String) -> JSONValue {
        parameterSchemas[toolID] ?? .object(["type": .string("object")])
    }

    private static let parameterSchemas: [String: JSONValue] = [
        "system.list_tools": .object(["type": .string("object")]),
        "files.read": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "maxBytes": .object(["type": .string("number")])
            ]),
            "required": .array([.string("path")])
        ]),
        "files.write": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
                "allowEmpty": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("path"), .string("content")])
        ]),
        "files.edit": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "search": .object(["type": .string("string")]),
                "replace": .object(["type": .string("string")]),
                "all": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("path"), .string("search"), .string("replace")])
        ]),
        "runtime.exec": .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string")]),
                "arguments": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "cwd": .object(["type": .string("string")]),
                "timeoutMs": .object(["type": .string("number")])
            ]),
            "required": .array([.string("command")])
        ]),
        "runtime.process": .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string")]),
                "command": .object(["type": .string("string")]),
                "arguments": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "cwd": .object(["type": .string("string")]),
                "processId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("action")])
        ]),
        "sessions.spawn": .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "parentSessionId": .object(["type": .string("string")])
            ])
        ]),
        "sessions.list": .object(["type": .string("object")]),
        "sessions.history": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ])
        ]),
        "sessions.status": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")])
            ])
        ]),
        "sessions.send": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
                "userId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("content")])
        ]),
        "messages.send": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
                "userId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("content")])
        ]),
        "agents.list": .object(["type": .string("object")]),
        "channel.history": .object([
            "type": .string("object"),
            "properties": .object([
                "channel_id": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ]),
            "required": .array([.string("channel_id")])
        ]),
        "memory.get": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ]),
            "required": .array([.string("query")])
        ]),
        "memory.recall": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ]),
            "required": .array([.string("query")])
        ]),
        "memory.search": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ]),
            "required": .array([.string("query")])
        ]),
        "memory.save": .object([
            "type": .string("object"),
            "properties": .object([
                "note": .object(["type": .string("string")]),
                "summary": .object(["type": .string("string")]),
                "class": .object(["type": .string("string")])
            ]),
            "required": .array([.string("note")])
        ]),
        "web.search": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "count": .object(["type": .string("number")])
            ]),
            "required": .array([.string("query")])
        ]),
        "web.fetch": .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")])
            ]),
            "required": .array([.string("url")])
        ]),
        "cron": .object([
            "type": .string("object"),
            "properties": .object([
                "schedule": .object(["type": .string("string")]),
                "command": .object(["type": .string("string")]),
                "channel_id": .object(["type": .string("string")]),
                "action": .object(["type": .string("string")])
            ])
        ]),
        "project.task_list": .object(["type": .string("object")]),
        "project.task_create": .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "description": .object(["type": .string("string")]),
                "priority": .object(["type": .string("string")]),
                "status": .object(["type": .string("string")])
            ]),
            "required": .array([.string("title")])
        ]),
        "project.task_get": .object([
            "type": .string("object"),
            "properties": .object([
                "taskId": .object(["type": .string("string")]),
                "reference": .object(["type": .string("string")])
            ])
        ]),
        "project.escalate_to_user": .object([
            "type": .string("object"),
            "properties": .object([
                "reason": .object(["type": .string("string")]),
                "taskId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("reason")])
        ]),
        "actor.discuss_with_actor": .object([
            "type": .string("object"),
            "properties": .object([
                "actorId": .object(["type": .string("string")]),
                "topic": .object(["type": .string("string")]),
                "message": .object(["type": .string("string")])
            ]),
            "required": .array([.string("actorId")])
        ]),
        "actor.conclude_discussion": .object([
            "type": .string("object"),
            "properties": .object([
                "discussionId": .object(["type": .string("string")]),
                "summary": .object(["type": .string("string")])
            ]),
            "required": .array([.string("discussionId")])
        ])
    ]
}

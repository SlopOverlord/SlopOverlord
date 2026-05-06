import AnyLanguageModel
import AgentRuntime
import Foundation
import Protocols

struct MemorySearchTool: CoreTool {
    let domain = "memory"
    let title = "Memory file search"
    let status = "fully_functional"
    let name = "memory.search"
    let description = "Keyword search in memory via canonical local index."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "query", description: "Search query", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "limit", description: "Max results to return", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
            .init(
                name: "scope_type",
                description: "Together with scope_id, or omit if using `scope` object. One of: global, project, channel, agent.",
                schema: DynamicGenerationSchema(type: String.self),
                isOptional: true
            ),
            .init(
                name: "scope_id",
                description: "Together with scope_type, or omit if using `scope` object. For channel: agent:<agentId>:session:<sessionId>.",
                schema: DynamicGenerationSchema(type: String.self),
                isOptional: true
            ),
            .init(
                name: "scope",
                description: "Optional object with `type` and `id`, plus optional channel_id, project_id, or agent_id.",
                schema: DynamicGenerationSchema(
                    name: "MemoryScopeArgument",
                    properties: [
                        .init(name: "type", description: "One of: global, project, channel, agent.", schema: DynamicGenerationSchema(type: String.self)),
                        .init(name: "id", description: "Scope identifier.", schema: DynamicGenerationSchema(type: String.self)),
                        .init(name: "channel_id", description: "Optional channel id.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
                        .init(name: "project_id", description: "Optional project id.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
                        .init(name: "agent_id", description: "Optional agent id.", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
                    ]
                ),
                isOptional: true
            )
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let query = arguments["query"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`query` is required.", retryable: false)
        }

        let limit = max(1, arguments["limit"]?.asInt ?? 8)
        let scope = parseMemoryScope(from: arguments)
        let hits = await context.memoryStore.recall(
            request: MemoryRecallRequest(query: query, limit: limit, scope: scope)
        )

        let payload: [JSONValue] = hits.map { hit in
            .object([
                "id": .string(hit.ref.id),
                "score": .number(hit.ref.score),
                "note": .string(hit.note),
                "summary": hit.summary.map(JSONValue.string) ?? .null,
                "kind": .string(hit.ref.kind?.rawValue ?? ""),
                "class": .string(hit.ref.memoryClass?.rawValue ?? "")
            ])
        }

        return toolSuccess(tool: name, data: .object([
            "query": .string(query),
            "count": .number(Double(payload.count)),
            "items": .array(payload)
        ]))
    }
}

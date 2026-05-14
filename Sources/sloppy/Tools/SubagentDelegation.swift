import Foundation
import Protocols

/// Tool allowlists for isolated subagent runs (`agents.delegate_task`, worker-backed sessions).
enum SubagentDelegation {
    static let controlToolIDs: Set<String> = [
        "agent_delegate.finish",
    ]

    /// Tools subagents must never use (recursive delegation, user messaging, shared memory, etc.).
    static let hardDeniedToolIDs: Set<String> = [
        "agents.delegate_task",
        "workers.spawn",
        "workers.route",
        "branches.spawn",
        "project.task_clarification_create",
        "memory.recall",
        "memory.get",
        "memory.save",
        "memory.search",
        "messages.send",
        "sessions.send",
        "runtime.exec",
        "sessions.spawn",
    ]

    /// Maps high-level toolset names to concrete tool IDs (Sloppy).
    private static let toolsetToToolIDs: [String: Set<String>] = [
        "terminal": ["runtime.exec", "runtime.process"],
        "file": ["files.list", "files.read", "files.write", "files.edit"],
        "web": ["web.search", "web.fetch"],
        "skills": ["skills.search", "skills.list", "skills.install", "skills.uninstall"],
        "lsp": ["lsp.query"],
        "visor": ["visor.status"],
        "system": ["system.list_tools"],
        "project": [
            "project.list",
            "project.current",
            "project.create",
            "project.update",
            "project.delete",
            "project.task_list",
            "project.task_create",
            "project.task_get",
            "project.task_update",
            "project.task_cancel",
            "project.escalate_to_user",
            "project.meta_memory_set",
        ],
    ]

    static func isToolAllowedByPolicy(toolID: String, policy: AgentToolsPolicy) -> Bool {
        if let explicit = policy.tools[toolID] {
            return explicit
        }
        return policy.defaultPolicy == .allow
    }

    /// Expands named toolsets into tool IDs. `mcp` includes every `mcp.*` tool present in `knownToolIDs`.
    static func toolIDs(forToolsetNames names: [String], knownToolIDs: Set<String>) -> Set<String> {
        var result = Set<String>()
        for raw in names {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if key == "mcp" {
                result.formUnion(knownToolIDs.filter { $0.hasPrefix("mcp.") })
            } else if let ids = toolsetToToolIDs[key] {
                result.formUnion(ids)
            }
        }
        return result
    }

    /// Effective tools for a subagent: parent policy ∩ optional toolsets − hard denials.
    static func effectiveToolIDs(
        policy: AgentToolsPolicy,
        knownToolIDs: Set<String>,
        toolsetNames: [String]?
    ) -> Set<String> {
        let parentAllowed = Set(
            knownToolIDs.filter { isToolAllowedByPolicy(toolID: $0, policy: policy) }
        )
        let candidates: Set<String>
        if let names = toolsetNames, !names.isEmpty {
            let expanded = toolIDs(forToolsetNames: names, knownToolIDs: knownToolIDs)
            candidates = parentAllowed.intersection(expanded)
        } else {
            candidates = parentAllowed
        }
        let controlTools = parentAllowed.intersection(controlToolIDs)
        return candidates
            .union(controlTools)
            .subtracting(hardDeniedToolIDs)
    }
}

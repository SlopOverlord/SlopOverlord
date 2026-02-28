import Foundation
import Protocols

struct ToolAuthorizationDecision: Sendable {
    let allowed: Bool
    let policy: AgentToolsPolicy
    let error: ToolErrorPayload?
}

actor ToolAuthorizationService {
    private struct CachedPolicy {
        let policy: AgentToolsPolicy
        let modifiedAt: Date?
    }

    private let store: AgentToolsFileStore
    private var cache: [String: CachedPolicy] = [:]
    private var invocationsByAgent: [String: [Date]] = [:]

    init(store: AgentToolsFileStore) {
        self.store = store
    }

    func updateAgentsRootURL(_ url: URL) {
        store.updateAgentsRootURL(url)
        cache.removeAll()
        invocationsByAgent.removeAll()
    }

    func policy(agentID: String) throws -> AgentToolsPolicy {
        try reloadedPolicy(agentID: agentID)
    }

    func updatePolicy(agentID: String, request: AgentToolsUpdateRequest) throws -> AgentToolsPolicy {
        let updated = try store.updatePolicy(
            agentID: agentID,
            request: request,
            knownToolIDs: ToolCatalog.knownToolIDs
        )
        let mtime = try? modificationDate(agentID: agentID)
        cache[agentID] = CachedPolicy(policy: updated, modifiedAt: mtime)
        return updated
    }

    func authorize(agentID: String, toolID: String) throws -> ToolAuthorizationDecision {
        let policy = try reloadedPolicy(agentID: agentID)

        guard ToolCatalog.knownToolIDs.contains(toolID) else {
            return ToolAuthorizationDecision(
                allowed: false,
                policy: policy,
                error: ToolErrorPayload(
                    code: "unknown_tool",
                    message: "Unknown tool '\(toolID)'",
                    retryable: false
                )
            )
        }

        let explicitlyAllowed = policy.tools[toolID]
        let allowed = explicitlyAllowed ?? (policy.defaultPolicy == .allow)
        guard allowed else {
            return ToolAuthorizationDecision(
                allowed: false,
                policy: policy,
                error: ToolErrorPayload(
                    code: "tool_forbidden",
                    message: "Tool '\(toolID)' is disabled by policy.",
                    retryable: false
                )
            )
        }

        let now = Date()
        var timestamps = invocationsByAgent[agentID] ?? []
        let threshold = now.addingTimeInterval(-60)
        timestamps = timestamps.filter { $0 >= threshold }
        if timestamps.count >= policy.guardrails.maxToolCallsPerMinute {
            invocationsByAgent[agentID] = timestamps
            return ToolAuthorizationDecision(
                allowed: false,
                policy: policy,
                error: ToolErrorPayload(
                    code: "rate_limited",
                    message: "Too many tool invocations in a short period.",
                    retryable: true
                )
            )
        }

        timestamps.append(now)
        invocationsByAgent[agentID] = timestamps
        return ToolAuthorizationDecision(allowed: true, policy: policy, error: nil)
    }

    private func reloadedPolicy(agentID: String) throws -> AgentToolsPolicy {
        let currentMtime = try? modificationDate(agentID: agentID)
        if let cached = cache[agentID], cached.modifiedAt == currentMtime {
            return cached.policy
        }

        let loaded = try store.getPolicy(agentID: agentID, knownToolIDs: ToolCatalog.knownToolIDs)
        cache[agentID] = CachedPolicy(policy: loaded, modifiedAt: currentMtime)
        return loaded
    }

    private func modificationDate(agentID: String) throws -> Date? {
        let url = store.toolsConfigURL(agentID: agentID)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }
}

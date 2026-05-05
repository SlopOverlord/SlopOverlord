import Foundation
import AgentRuntime
import PluginSDK
import Protocols

// MARK: - Channel Model

extension CoreService {
    public func getChannelModel(channelId: String) async -> ChannelModelResponse {
        let selected = await channelModelStore.get(channelId: channelId)
        return ChannelModelResponse(
            channelId: channelId,
            selectedModel: selected,
            availableModels: availableAgentModels()
        )
    }

    public func setChannelModel(channelId: String, model: String) async throws -> ChannelModelResponse {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = availableAgentModels()
        let hasOAuth = openAIOAuthService.currentAccessToken() != nil
        let canonical: String?
        if let resolved = CoreService.resolveCanonicalAgentModelID(trimmed, availableModels: available) {
            canonical = resolved
        } else if CoreService.isRuntimeRoutableModelID(trimmed, config: currentConfig, hasOAuthCredentials: hasOAuth) {
            canonical = trimmed
        } else {
            canonical = nil
        }
        guard !trimmed.isEmpty, let canonical else {
            throw AgentConfigError.invalidModel
        }
        await channelModelStore.set(channelId: channelId, model: canonical)
        return ChannelModelResponse(channelId: channelId, selectedModel: canonical, availableModels: available)
    }

    public func removeChannelModel(channelId: String) async {
        await channelModelStore.remove(channelId: channelId)
    }

    func handleModeCommand(channelId: String, content: String) async -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower == "/mode" || lower.hasPrefix("/mode ") else { return nil }

        let bindingId = ChannelGatewayScope.parse(channelId).baseChannelId
        let tail = trimmed.dropFirst("/mode".count).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tail.isEmpty else {
            let current = await channelChatModeStore.get(channelId: bindingId)
            return "Current mode: \(current.rawValue). Usage: /mode ask|build|plan|debug"
        }
        guard let mode = AgentChatMode(rawValue: tail) else {
            return "Unknown mode `\(tail)`. Use ask, build, plan, or debug."
        }
        await channelChatModeStore.set(channelId: bindingId, mode: mode)
        await runtime.invalidateChannelSession(channelId: channelId)
        return "Mode set to \(mode.rawValue)."
    }

    func handleContextCommand(channelId: String, content: String) async -> String? {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower == "/context" else { return nil }

        let bindingId = ChannelGatewayScope.parse(channelId).baseChannelId
        let modelOverride = await channelModelStore.get(channelId: bindingId)
        let available = availableAgentModels()
        let activeModel = modelOverride.flatMap { id in available.first { $0.id == id } } ?? available.first

        let modelName = activeModel?.title ?? modelOverride ?? "unknown"
        let contextWindowStr = activeModel?.contextWindow ?? "—"
        let contextWindowTokens = Self.parseContextWindowString(contextWindowStr)

        let usage = await listTokenUsage(channelId: channelId)
        let promptTokens = usage.totalPromptTokens
        let completionTokens = usage.totalCompletionTokens
        let totalTokens = usage.totalTokens

        let usagePercent = contextWindowTokens > 0
            ? min(100, Int((Double(totalTokens) / Double(contextWindowTokens)) * 100))
            : 0

        let barWidth = 20
        let filledCount = contextWindowTokens > 0 ? (usagePercent * barWidth) / 100 : 0
        let emptyCount = barWidth - filledCount
        let barFill = String(repeating: "█", count: filledCount)
        let barEmpty = String(repeating: "░", count: emptyCount)
        let barEmoji: String
        if usagePercent >= 90 { barEmoji = "🔴" }
        else if usagePercent >= 70 { barEmoji = "🟡" }
        else { barEmoji = "🟢" }

        return """
        📊 Context Usage

        🤖 Model: \(modelName)
        📐 Context Window: \(contextWindowStr)

        ┌──────────────────────────┐
        │ 📥 Prompt:     \(Self.padTokenCount(promptTokens)) │
        │ 📤 Completion:  \(Self.padTokenCount(completionTokens)) │
        │ 📦 Total:      \(Self.padTokenCount(totalTokens)) │
        └──────────────────────────┘

        \(barEmoji) [\(barFill)\(barEmpty)] \(usagePercent)%
           \(Self.formatTokenCountShort(totalTokens)) / \(contextWindowStr)
        """
    }

    func handleCompactCommand(channelId: String, content: String) async -> String? {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower == "/compact" else { return nil }

        await runtime.invalidateChannelSession(channelId: channelId)
        return "Context compacted for this channel. The next turn will rebuild the model context from saved channel state."
    }

    func handleDiffCommand(channelId: String, content: String) async -> String? {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower == "/diff" || lower.hasPrefix("/diff ") else { return nil }

        let baseChannelID = ChannelGatewayScope.parse(channelId).baseChannelId
        let projects = await listProjects()
        guard let project = projects.first(where: { project in
            project.channels.contains { channel in
                channelBindingMatches(channel.channelId, channelID: baseChannelID)
            }
        }) else {
            return "No project is linked to channel `\(baseChannelID)`, so there is no workspace diff to show."
        }

        do {
            let git = try await projectWorkingTreeGit(projectID: project.id)
            guard git.isGitRepository else {
                return git.message ?? "Project `\(project.name)` is not a git repository."
            }
            guard !git.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "No uncommitted changes in `\(project.name)`."
            }

            let maxCharacters = 3_500
            let clipped: String
            if git.diff.count > maxCharacters {
                clipped = String(git.diff.prefix(maxCharacters)) + "\n... diff truncated"
            } else {
                clipped = git.diff
            }
            let branch = git.branch ?? "unknown"
            let truncatedNote = git.diffTruncated ? "\n\nDiff was truncated by the backend." : ""
            return """
            Diff for `\(project.name)` on `\(branch)` (+\(git.linesAdded) -\(git.linesDeleted)):

            ```diff
            \(clipped)
            ```\(truncatedNote)
            """
        } catch {
            return "Could not read project diff: \(String(describing: error))"
        }
    }

    static func parseContextWindowString(_ value: String) -> Int {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let match = normalized.range(of: #"^([\d.]+)\s*([KMB])?$"#, options: .regularExpression) else { return 0 }
        let matched = String(normalized[match])
        let numStr = matched.replacingOccurrences(of: #"[KMB]"#, with: "", options: .regularExpression)
        guard let num = Double(numStr) else { return 0 }
        if normalized.hasSuffix("M") { return Int(num * 1_000_000) }
        if normalized.hasSuffix("K") { return Int(num * 1_000) }
        if normalized.hasSuffix("B") { return Int(num * 1_000_000_000) }
        return Int(num)
    }

    static func formatTokenCountShort(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    static func padTokenCount(_ count: Int) -> String {
        let formatted = count.formatted()
        return formatted.padding(toLength: 10, withPad: " ", startingAt: 0)
    }

    func handleModelCommand(channelId: String, content: String) async -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        guard lower == "/model" || lower.hasPrefix("/model ") else {
            return nil
        }

        let available = availableAgentModels()
        let bindingId = ChannelGatewayScope.parse(channelId).baseChannelId
        let current = await channelModelStore.get(channelId: bindingId)

        if lower == "/model" {
            let currentLine = current.map { "Current model: \($0)" } ?? "Current model: default (not set)"
            let list = available.map { "  \($0.id)" }.joined(separator: "\n")
            return "\(currentLine)\n\nAvailable models:\n\(list)\n\nUse /model <model_id> to switch."
        }

        let modelId = String(trimmed.dropFirst("/model ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty else {
            return "Usage: /model <model_id>"
        }

        let hasOAuth = openAIOAuthService.currentAccessToken() != nil
        let canonical: String?
        if let resolved = CoreService.resolveCanonicalAgentModelID(modelId, availableModels: available) {
            canonical = resolved
        } else if CoreService.isRuntimeRoutableModelID(modelId, config: currentConfig, hasOAuthCredentials: hasOAuth) {
            canonical = modelId
        } else {
            canonical = nil
        }
        guard let canonical else {
            let list = available.map { "  \($0.id)" }.joined(separator: "\n")
            return "Unknown model: \(modelId)\n\nAvailable models:\n\(list)"
        }

        await channelModelStore.set(channelId: bindingId, model: canonical)
        return "Model set to: \(canonical)"
    }

    func handleStatusCommand(channelId: String, content: String) async -> String? {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower == "/status" else { return nil }

        let bindingId = ChannelGatewayScope.parse(channelId).baseChannelId
        let board = try? getActorBoard()
        let agentLabel: String = board?.nodes
            .first(where: { normalizeWhitespace($0.channelId ?? "") == bindingId })
            .flatMap { normalizeWhitespace($0.linkedAgentId ?? "").isEmpty ? nil : normalizeWhitespace($0.linkedAgentId ?? "") }
            ?? bindingId

        let modelOverride = await channelModelStore.get(channelId: bindingId)
        let available = availableAgentModels()
        let activeModel = modelOverride.flatMap { id in available.first { $0.id == id } } ?? available.first
        let modelLabel = activeModel?.title ?? modelOverride ?? "default"

        let snapshot = await runtime.channelState(channelId: channelId)
        let isRunning = !(snapshot?.activeWorkerIds.isEmpty ?? true)
        let stateLabel = isRunning ? "Running" : "Idle"

        let sessions = (try? await channelSessionStore.listSessions(
            status: .open,
            channelIds: Set([channelId])
        )) ?? []
        let sessionLabel = sessions.first?.sessionId ?? "none"

        return "Agent: \(agentLabel)\nSession: \(sessionLabel)\nModel: \(modelLabel)\nState: \(stateLabel)"
    }
}

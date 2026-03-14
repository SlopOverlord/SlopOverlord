import Foundation
import Protocols

final class AgentCatalogFileStore {
    enum StoreError: Error {
        case invalidID
        case invalidPayload
        case invalidModel
        case alreadyExists
        case notFound
        case storageFailure
    }

    private struct AgentConfigFile: Codable {
        let id: String
        let displayName: String
        let role: String
        let createdAt: Date
        let selectedModel: String?
        let heartbeat: AgentHeartbeatSettings?
        let channelSessions: AgentChannelSessionSettings?
    }

    private struct AgentHeartbeatStatusFile: Codable {
        let lastRunAt: Date?
        let lastSuccessAt: Date?
        let lastFailureAt: Date?
        let lastResult: String?
        let lastErrorMessage: String?
        let lastSessionId: String?
    }

    private let fileManager: FileManager
    private var agentsRootURL: URL

    private var systemAgentsRootURL: URL {
        agentsRootURL.appendingPathComponent(".system", isDirectory: true)
    }

    init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL
    }

    func updateAgentsRootURL(_ url: URL) {
        self.agentsRootURL = url
    }

    func listAgents() throws -> [AgentSummary] {
        try ensureAgentsRootDirectory()

        var agents: [AgentSummary] = []

        let entries = try fileManager.contentsOfDirectory(
            at: agentsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let agentID = entry.lastPathComponent
            if let summary = try? readAgentSummary(id: agentID, isSystem: false) {
                agents.append(summary)
            }
        }

        if fileManager.fileExists(atPath: systemAgentsRootURL.path) {
            let systemEntries = try fileManager.contentsOfDirectory(
                at: systemAgentsRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for entry in systemEntries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                let agentID = entry.lastPathComponent
                if let summary = try? readAgentSummary(id: agentID, isSystem: true) {
                    agents.append(summary)
                }
            }
        }

        agents.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return agents
    }

    func getAgent(id: String) throws -> AgentSummary {
        guard let normalizedID = normalizedAgentID(id) else {
            throw StoreError.invalidID
        }

        if fileManager.fileExists(atPath: agentDirectoryURL(for: normalizedID, isSystem: false).path) {
            return try readAgentSummary(id: normalizedID, isSystem: false)
        }
        if fileManager.fileExists(atPath: agentDirectoryURL(for: normalizedID, isSystem: true).path) {
            return try readAgentSummary(id: normalizedID, isSystem: true)
        }
        throw StoreError.notFound
    }

    func createAgent(_ request: AgentCreateRequest, availableModels: [ProviderModelOption]) throws -> AgentSummary {
        guard let normalizedID = normalizedAgentID(request.id) else {
            throw StoreError.invalidID
        }

        let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = request.role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !role.isEmpty else {
            throw StoreError.invalidPayload
        }

        try ensureAgentsRootDirectory()
        if request.isSystem {
            try fileManager.createDirectory(at: systemAgentsRootURL, withIntermediateDirectories: true)
        }

        let directoryURL = agentDirectoryURL(for: normalizedID, isSystem: request.isSystem)
        if fileManager.fileExists(atPath: directoryURL.path) {
            throw StoreError.alreadyExists
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let summary = AgentSummary(
            id: normalizedID,
            displayName: displayName,
            role: role,
            createdAt: Date(),
            isSystem: request.isSystem
        )

        do {
            try writeAgentSummary(summary)
            try writeAgentScaffoldFiles(for: summary, availableModels: availableModels)
            return summary
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    func getAgentConfig(agentID: String, availableModels: [ProviderModelOption]) throws -> AgentConfigDetail {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }

        let summary = try getAgent(id: normalizedAgentID)
        let configFile = try readAgentConfigFile(for: summary, availableModels: availableModels)
        let selectedModel = configFile.selectedModel ?? ""
        let documents = try readAgentDocuments(agentID: normalizedAgentID)
        let heartbeatStatus = try readHeartbeatStatus(agentID: normalizedAgentID, isSystem: summary.isSystem)

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            selectedModel: selectedModel,
            availableModels: availableModels,
            documents: documents,
            heartbeat: configFile.heartbeat ?? AgentHeartbeatSettings(),
            channelSessions: configFile.channelSessions ?? AgentChannelSessionSettings(),
            heartbeatStatus: heartbeatStatus
        )
    }

    func updateAgentConfig(
        agentID: String,
        request: AgentConfigUpdateRequest,
        availableModels: [ProviderModelOption]
    ) throws -> AgentConfigDetail {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }

        let summary = try getAgent(id: normalizedAgentID)

        let selectedModel = request.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else {
            throw StoreError.invalidModel
        }

        let allowedModelIDs = Set(availableModels.map(\.id))
        guard allowedModelIDs.contains(selectedModel) else {
            throw StoreError.invalidModel
        }

        let normalizedDocuments = AgentDocumentBundle(
            userMarkdown: normalizedDocumentText(request.documents.userMarkdown),
            agentsMarkdown: normalizedDocumentText(request.documents.agentsMarkdown),
            soulMarkdown: normalizedDocumentText(request.documents.soulMarkdown),
            identityMarkdown: normalizedDocumentText(request.documents.identityMarkdown),
            heartbeatMarkdown: normalizedHeartbeatText(request.documents.heartbeatMarkdown)
        )

        guard !normalizedDocuments.userMarkdown.isEmpty,
              !normalizedDocuments.agentsMarkdown.isEmpty,
              !normalizedDocuments.soulMarkdown.isEmpty,
              !normalizedDocuments.identityMarkdown.isEmpty
        else {
            throw StoreError.invalidPayload
        }

        let heartbeat = request.heartbeat
        if heartbeat.enabled && heartbeat.intervalMinutes < 1 {
            throw StoreError.invalidPayload
        }
        let channelSessions = request.channelSessions
        if channelSessions.autoCloseEnabled && channelSessions.autoCloseAfterMinutes < 1 {
            throw StoreError.invalidPayload
        }

        do {
            try writeAgentConfigFile(
                AgentConfigFile(
                    id: summary.id,
                    displayName: summary.displayName,
                    role: summary.role,
                    createdAt: summary.createdAt,
                    selectedModel: selectedModel,
                    heartbeat: heartbeat,
                    channelSessions: channelSessions
                ),
                isSystem: summary.isSystem
            )

            let agentDirectory = agentDirectoryURL(for: normalizedAgentID, isSystem: summary.isSystem)
            try writeTextFile(contents: normalizedDocuments.agentsMarkdown, at: agentDirectory.appendingPathComponent("Agents.md"))
            try writeTextFile(contents: normalizedDocuments.userMarkdown, at: agentDirectory.appendingPathComponent("User.md"))
            try writeTextFile(contents: normalizedDocuments.soulMarkdown, at: agentDirectory.appendingPathComponent("Soul.md"))
            try writeTextFile(contents: normalizedDocuments.identityMarkdown, at: agentDirectory.appendingPathComponent("Identity.md"))
            try writeTextFile(contents: normalizedDocuments.heartbeatMarkdown, at: agentDirectory.appendingPathComponent("HEARTBEAT.md"))

            let legacyIdentity = normalizedIdentityValue(from: normalizedDocuments.identityMarkdown, fallback: summary.id)
            try writeTextFile(contents: legacyIdentity + "\n", at: agentDirectory.appendingPathComponent("Identity.id"))
        } catch {
            throw StoreError.storageFailure
        }

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            selectedModel: selectedModel,
            availableModels: availableModels,
            documents: normalizedDocuments,
            heartbeat: heartbeat,
            channelSessions: channelSessions,
            heartbeatStatus: try readHeartbeatStatus(agentID: normalizedAgentID, isSystem: summary.isSystem)
        )
    }

    func readAgentDocuments(agentID: String) throws -> AgentDocumentBundle {
        guard let normalizedID = self.normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }

        let summary = try getAgent(id: normalizedID)
        let agentDirectory = agentDirectoryURL(for: normalizedID, isSystem: summary.isSystem)
        let userMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("User.md"), fallback: "# User\n")
        let agentsMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("Agents.md"), fallback: "# Agent\n")
        let soulMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("Soul.md"), fallback: "# Soul\n")
        let heartbeatMarkdown = try readHeartbeatFile(agentID: normalizedID, isSystem: summary.isSystem)

        let identityMarkdownPath = agentDirectory.appendingPathComponent("Identity.md")
        let identityLegacyPath = agentDirectory.appendingPathComponent("Identity.id")
        let identityMarkdown = try readIdentityMarkdown(
            markdownURL: identityMarkdownPath,
            legacyURL: identityLegacyPath,
            fallback: normalizedID
        )

        return AgentDocumentBundle(
            userMarkdown: userMarkdown,
            agentsMarkdown: agentsMarkdown,
            soulMarkdown: soulMarkdown,
            identityMarkdown: identityMarkdown,
            heartbeatMarkdown: heartbeatMarkdown
        )
    }

    func getHeartbeatStatus(agentID: String) throws -> AgentHeartbeatStatus {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }
        let summary = try getAgent(id: normalizedAgentID)
        return try readHeartbeatStatus(agentID: normalizedAgentID, isSystem: summary.isSystem)
    }

    func updateHeartbeatStatus(agentID: String, status: AgentHeartbeatStatus) throws {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }
        let summary = try getAgent(id: normalizedAgentID)

        do {
            try writeHeartbeatStatus(status, agentID: normalizedAgentID, isSystem: summary.isSystem)
        } catch {
            throw StoreError.storageFailure
        }
    }

    private func ensureAgentsRootDirectory() throws {
        try fileManager.createDirectory(at: agentsRootURL, withIntermediateDirectories: true)
    }

    private func agentDirectoryURL(for id: String, isSystem: Bool) -> URL {
        let root = isSystem ? systemAgentsRootURL : agentsRootURL
        return root.appendingPathComponent(id, isDirectory: true)
    }

    private func agentMetadataURL(for id: String, isSystem: Bool) -> URL {
        agentDirectoryURL(for: id, isSystem: isSystem).appendingPathComponent("agent.json")
    }

    private func readAgentSummary(id: String, isSystem: Bool) throws -> AgentSummary {
        let metadataURL = agentMetadataURL(for: id, isSystem: isSystem)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw StoreError.notFound
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentSummary.self, from: data)
    }

    private func writeAgentSummary(_ summary: AgentSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(summary) + Data("\n".utf8)
        try payload.write(to: agentMetadataURL(for: summary.id, isSystem: summary.isSystem), options: .atomic)
    }

    private func writeAgentScaffoldFiles(for summary: AgentSummary, availableModels: [ProviderModelOption]) throws {
        let agentDirectory = agentDirectoryURL(for: summary.id, isSystem: summary.isSystem)

        let agentsMarkdown =
            """
            # Agent

            - ID: \(summary.id)
            - Display Name: \(summary.displayName)
            - Role: \(summary.role)

            ## Base behavior
            - Work toward user goals, not just literal instructions.
            - Add your own concrete suggestions when they materially improve outcome.
            - Keep answers actionable and concise.
            - When user references task ids like `#MOBILE-1`, fetch task details first via tool `project.task_get`.
            - When the user needs current web information and tool `web.search` is available, call it with `{"tool":"web.search","arguments":{"query":"...","count":5},"reason":"..."}` before answering.
            - If a request is ambiguous, make a safe assumption and state it.
            """
        try writeTextFile(
            contents: agentsMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("Agents.md")
        )

        let userMarkdown =
            """
            # User

            - Prefers practical, result-oriented responses.
            - Values clear next actions and visible progress.
            - Expects proactive suggestions aligned with current goal.
            """
        try writeTextFile(
            contents: userMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("User.md")
        )

        let soulMarkdown =
            """
            # Soul

            - Prioritize correctness over speed in high-impact decisions.
            - Avoid hallucinations: if uncertain, verify or state uncertainty.
            - Keep collaboration direct, respectful, and technical.
            - Never hide risks; surface constraints early.
            """
        try writeTextFile(
            contents: soulMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("Soul.md")
        )

        try writeTextFile(
            contents: summary.id + "\n",
            at: agentDirectory.appendingPathComponent("Identity.id")
        )
        try writeTextFile(
            contents: "# Identity\n\(summary.id)\n",
            at: agentDirectory.appendingPathComponent("Identity.md")
        )
        try writeTextFile(
            contents: "",
            at: agentDirectory.appendingPathComponent("HEARTBEAT.md")
        )

        try writeAgentConfigFile(
            AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableModels.first?.id,
                heartbeat: AgentHeartbeatSettings(),
                channelSessions: AgentChannelSessionSettings()
            ),
            isSystem: summary.isSystem
        )

        try fileManager.createDirectory(
            at: agentDirectory.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )

        let toolsDirectory = agentDirectory.appendingPathComponent("tools", isDirectory: true)
        try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

        let toolsPolicy = AgentToolsPolicy(
            version: 1,
            defaultPolicy: .allow,
            tools: [:],
            guardrails: .init()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try encoder.encode(toolsPolicy) + Data("\n".utf8)
        try payload.write(to: toolsDirectory.appendingPathComponent("tools.json"), options: .atomic)

        try writeHeartbeatStatus(AgentHeartbeatStatus(), agentID: summary.id, isSystem: summary.isSystem)
    }

    private func agentConfigURL(for id: String, isSystem: Bool) -> URL {
        agentDirectoryURL(for: id, isSystem: isSystem).appendingPathComponent("config.json")
    }

    private func heartbeatStatusURL(for id: String, isSystem: Bool) -> URL {
        agentDirectoryURL(for: id, isSystem: isSystem).appendingPathComponent("heartbeat-status.json")
    }

    private func readAgentConfigFile(for summary: AgentSummary, availableModels: [ProviderModelOption]) throws -> AgentConfigFile {
        let configURL = agentConfigURL(for: summary.id, isSystem: summary.isSystem)
        if !fileManager.fileExists(atPath: configURL.path) {
            let fallback = AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableModels.first?.id,
                heartbeat: AgentHeartbeatSettings(),
                channelSessions: AgentChannelSessionSettings()
            )
            try writeAgentConfigFile(fallback, isSystem: summary.isSystem)
            return fallback
        }

        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded = try decoder.decode(AgentConfigFile.self, from: data)
        let selectedModel = decoded.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableModelIDs = Set(availableModels.map(\.id))
        if selectedModel?.isEmpty ?? true || !(selectedModel.map { availableModelIDs.contains($0) } ?? false) {
            decoded = AgentConfigFile(
                id: decoded.id,
                displayName: decoded.displayName,
                role: decoded.role,
                createdAt: decoded.createdAt,
                selectedModel: availableModels.first?.id,
                heartbeat: decoded.heartbeat ?? AgentHeartbeatSettings(),
                channelSessions: decoded.channelSessions ?? AgentChannelSessionSettings()
            )
            try writeAgentConfigFile(decoded, isSystem: summary.isSystem)
        } else if decoded.heartbeat == nil || decoded.channelSessions == nil {
            decoded = AgentConfigFile(
                id: decoded.id,
                displayName: decoded.displayName,
                role: decoded.role,
                createdAt: decoded.createdAt,
                selectedModel: decoded.selectedModel,
                heartbeat: decoded.heartbeat ?? AgentHeartbeatSettings(),
                channelSessions: decoded.channelSessions ?? AgentChannelSessionSettings()
            )
            try writeAgentConfigFile(decoded, isSystem: summary.isSystem)
        }
        return decoded
    }

    private func writeAgentConfigFile(_ configFile: AgentConfigFile, isSystem: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let configPayload = try encoder.encode(configFile) + Data("\n".utf8)
        try configPayload.write(to: agentConfigURL(for: configFile.id, isSystem: isSystem), options: .atomic)
    }

    private func readTextFile(at url: URL, fallback: String) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            return fallback
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return normalizedDocumentText(text)
    }

    private func readHeartbeatFile(agentID: String, isSystem: Bool) throws -> String {
        let url = agentDirectoryURL(for: agentID, isSystem: isSystem).appendingPathComponent("HEARTBEAT.md")
        if !fileManager.fileExists(atPath: url.path) {
            try writeTextFile(contents: "", at: url)
            return ""
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return normalizedHeartbeatText(text)
    }

    private func readHeartbeatStatus(agentID: String, isSystem: Bool) throws -> AgentHeartbeatStatus {
        let url = heartbeatStatusURL(for: agentID, isSystem: isSystem)
        if !fileManager.fileExists(atPath: url.path) {
            let fallback = AgentHeartbeatStatus()
            try writeHeartbeatStatus(fallback, agentID: agentID, isSystem: isSystem)
            return fallback
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentHeartbeatStatusFile.self, from: data)
        return AgentHeartbeatStatus(
            lastRunAt: decoded.lastRunAt,
            lastSuccessAt: decoded.lastSuccessAt,
            lastFailureAt: decoded.lastFailureAt,
            lastResult: decoded.lastResult,
            lastErrorMessage: decoded.lastErrorMessage,
            lastSessionId: decoded.lastSessionId
        )
    }

    private func readIdentityMarkdown(markdownURL: URL, legacyURL: URL, fallback: String) throws -> String {
        if fileManager.fileExists(atPath: markdownURL.path) {
            return try readTextFile(at: markdownURL, fallback: fallback + "\n")
        }

        if fileManager.fileExists(atPath: legacyURL.path) {
            let legacy = try readTextFile(at: legacyURL, fallback: fallback + "\n")
            return normalizedDocumentText(legacy)
        }

        return fallback + "\n"
    }

    private func writeTextFile(contents: String, at url: URL) throws {
        guard let data = contents.data(using: .utf8) else {
            throw StoreError.invalidPayload
        }
        try data.write(to: url, options: .atomic)
    }

    private func writeHeartbeatStatus(_ status: AgentHeartbeatStatus, agentID: String, isSystem: Bool) throws {
        let payload = AgentHeartbeatStatusFile(
            lastRunAt: status.lastRunAt,
            lastSuccessAt: status.lastSuccessAt,
            lastFailureAt: status.lastFailureAt,
            lastResult: status.lastResult,
            lastErrorMessage: status.lastErrorMessage,
            lastSessionId: status.lastSessionId
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload) + Data("\n".utf8)
        try data.write(to: heartbeatStatusURL(for: agentID, isSystem: isSystem), options: .atomic)
    }

    private func normalizedDocumentText(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") {
            return normalized
        }
        return normalized + "\n"
    }

    private func normalizedHeartbeatText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func normalizedIdentityValue(from markdown: String, fallback: String) -> String {
        let candidates = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        if let first = candidates.first {
            return first
        }
        return fallback
    }

    private func normalizedAgentID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return nil
        }

        guard trimmed.count <= 120 else {
            return nil
        }

        return trimmed
    }
}

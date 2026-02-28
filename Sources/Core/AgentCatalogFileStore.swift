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
    }

    private let fileManager: FileManager
    private var agentsRootURL: URL

    init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL
    }

    func updateAgentsRootURL(_ url: URL) {
        self.agentsRootURL = url
    }

    func listAgents() throws -> [AgentSummary] {
        try ensureAgentsRootDirectory()

        let entries = try fileManager.contentsOfDirectory(
            at: agentsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var agents: [AgentSummary] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                continue
            }

            let agentID = entry.lastPathComponent
            if let summary = try? readAgentSummary(id: agentID) {
                agents.append(summary)
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

        guard fileManager.fileExists(atPath: agentDirectoryURL(for: normalizedID).path) else {
            throw StoreError.notFound
        }

        return try readAgentSummary(id: normalizedID)
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

        let directoryURL = agentDirectoryURL(for: normalizedID)
        if fileManager.fileExists(atPath: directoryURL.path) {
            throw StoreError.alreadyExists
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let summary = AgentSummary(
            id: normalizedID,
            displayName: displayName,
            role: role,
            createdAt: Date()
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
        let selectedModel = try readAgentConfigFile(for: summary, availableModels: availableModels).selectedModel ?? ""
        let documents = try readAgentDocuments(agentID: normalizedAgentID)

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            selectedModel: selectedModel,
            availableModels: availableModels,
            documents: documents
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
            identityMarkdown: normalizedDocumentText(request.documents.identityMarkdown)
        )

        guard !normalizedDocuments.userMarkdown.isEmpty,
              !normalizedDocuments.agentsMarkdown.isEmpty,
              !normalizedDocuments.soulMarkdown.isEmpty,
              !normalizedDocuments.identityMarkdown.isEmpty
        else {
            throw StoreError.invalidPayload
        }

        do {
            try writeAgentConfigFile(
                AgentConfigFile(
                    id: summary.id,
                    displayName: summary.displayName,
                    role: summary.role,
                    createdAt: summary.createdAt,
                    selectedModel: selectedModel
                )
            )

            let agentDirectory = agentDirectoryURL(for: normalizedAgentID)
            try writeTextFile(contents: normalizedDocuments.agentsMarkdown, at: agentDirectory.appendingPathComponent("Agents.md"))
            try writeTextFile(contents: normalizedDocuments.userMarkdown, at: agentDirectory.appendingPathComponent("User.md"))
            try writeTextFile(contents: normalizedDocuments.soulMarkdown, at: agentDirectory.appendingPathComponent("Soul.md"))
            try writeTextFile(contents: normalizedDocuments.identityMarkdown, at: agentDirectory.appendingPathComponent("Identity.md"))

            let legacyIdentity = normalizedIdentityValue(from: normalizedDocuments.identityMarkdown, fallback: summary.id)
            try writeTextFile(contents: legacyIdentity + "\n", at: agentDirectory.appendingPathComponent("Identity.id"))
        } catch {
            throw StoreError.storageFailure
        }

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            selectedModel: selectedModel,
            availableModels: availableModels,
            documents: normalizedDocuments
        )
    }

    func readAgentDocuments(agentID: String) throws -> AgentDocumentBundle {
        let normalizedID: String
        if let normalized = self.normalizedAgentID(agentID) {
            normalizedID = normalized
        } else {
            throw StoreError.invalidID
        }

        let agentDirectory = agentDirectoryURL(for: normalizedID)
        let userMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("User.md"), fallback: "# User\n")
        let agentsMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("Agents.md"), fallback: "# Agent\n")
        let soulMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("Soul.md"), fallback: "# Soul\n")

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
            identityMarkdown: identityMarkdown
        )
    }

    private func ensureAgentsRootDirectory() throws {
        try fileManager.createDirectory(at: agentsRootURL, withIntermediateDirectories: true)
    }

    private func agentDirectoryURL(for id: String) -> URL {
        agentsRootURL.appendingPathComponent(id, isDirectory: true)
    }

    private func agentMetadataURL(for id: String) -> URL {
        agentDirectoryURL(for: id).appendingPathComponent("agent.json")
    }

    private func readAgentSummary(id: String) throws -> AgentSummary {
        let metadataURL = agentMetadataURL(for: id)
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
        try payload.write(to: agentMetadataURL(for: summary.id), options: .atomic)
    }

    private func writeAgentScaffoldFiles(for summary: AgentSummary, availableModels: [ProviderModelOption]) throws {
        let agentDirectory = agentDirectoryURL(for: summary.id)

        let agentsMarkdown =
            """
            # Agent

            - ID: \(summary.id)
            - Display Name: \(summary.displayName)
            - Role: \(summary.role)
            """
        try writeTextFile(
            contents: agentsMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("Agents.md")
        )

        let userMarkdown =
            """
            # User

            Describe the expected user profile, tone, and communication preferences for this agent.
            """
        try writeTextFile(
            contents: userMarkdown + "\n",
            at: agentDirectory.appendingPathComponent("User.md")
        )

        let soulMarkdown =
            """
            # Soul

            Define the core principles, values, and behavioral constraints of this agent.
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
            contents: summary.id + "\n",
            at: agentDirectory.appendingPathComponent("Identity.md")
        )

        try writeAgentConfigFile(
            AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableModels.first?.id
            )
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
    }

    private func agentConfigURL(for id: String) -> URL {
        agentDirectoryURL(for: id).appendingPathComponent("config.json")
    }

    private func readAgentConfigFile(for summary: AgentSummary, availableModels: [ProviderModelOption]) throws -> AgentConfigFile {
        let configURL = agentConfigURL(for: summary.id)
        if !fileManager.fileExists(atPath: configURL.path) {
            let fallback = AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableModels.first?.id
            )
            try writeAgentConfigFile(fallback)
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
                selectedModel: availableModels.first?.id
            )
            try writeAgentConfigFile(decoded)
        }
        return decoded
    }

    private func writeAgentConfigFile(_ configFile: AgentConfigFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let configPayload = try encoder.encode(configFile) + Data("\n".utf8)
        try configPayload.write(to: agentConfigURL(for: configFile.id), options: .atomic)
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

    private func normalizedDocumentText(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") {
            return normalized
        }
        return normalized + "\n"
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

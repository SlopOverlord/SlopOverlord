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
        let runtime: AgentRuntimeConfig?
    }

    private struct AgentPetMetadataFile: Codable {
        let petId: String
        let genomeHex: String
        let parts: AgentPetParts
        let partRarities: AgentPetPartRarities
        let rarity: AgentPetRarityTier
        let baseStats: AgentPetStats
        let transferable: Bool
        let visual: AgentPetVisualSummary?
        let evolution: AgentPetEvolutionSummary?
        let stageAssets: [AgentPetStageAsset]?
    }

    private struct AgentMetadataFile: Codable {
        let id: String
        let displayName: String
        let role: String
        let createdAt: Date
        let isSystem: Bool
        let runtime: AgentRuntimeConfig?
        let pet: AgentPetMetadataFile?
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
        let petDraft: AgentPetDraftRecord?
        if request.isSystem {
            petDraft = nil
        } else {
            petDraft = try readPetDraftIfRequested(request.petDraftId)
        }
        let petRecord = request.isSystem ? nil : (petDraft?.generated ?? AgentPetFactory.makePet())
        let summary = AgentSummary(
            id: normalizedID,
            displayName: displayName,
            role: role,
            createdAt: Date(),
            isSystem: request.isSystem,
            runtime: request.runtime ?? .init(),
            pet: petRecord?.summary
        )

        do {
            try writeAgentSummary(summary)
            if let petRecord {
                try writePetProgressState(
                    petRecord.state,
                    agentID: summary.id,
                    isSystem: summary.isSystem
                )
            }
            if let petDraft {
                try persistPetDraft(petDraft, for: summary)
                try deletePetDraft(id: petDraft.draftId)
            }
            try writeAgentScaffoldFiles(for: summary, availableModels: availableModels)
            return summary
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    func writePetDraft(_ draft: AgentPetDraftRecord) throws {
        guard normalizedPetDraftID(draft.draftId) != nil else {
            throw StoreError.invalidID
        }
        let url = petDraftURL(for: draft.draftId)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft) + Data("\n".utf8)
        try data.write(to: url, options: .atomic)
    }

    func getAgentConfig(
        agentID: String,
        availableModels: [ProviderModelOption],
        persistedModelAllowed: ((String) -> Bool)? = nil
    ) throws -> AgentConfigDetail {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }

        let summary = try getAgent(id: normalizedAgentID)
        let configFile = try readAgentConfigFile(
            for: summary,
            availableModels: availableModels,
            persistedModelAllowed: persistedModelAllowed
        )
        let documents = try readAgentDocuments(agentID: normalizedAgentID)
        let heartbeatStatus = try readHeartbeatStatus(agentID: normalizedAgentID, isSystem: summary.isSystem)

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            role: summary.role,
            selectedModel: configFile.selectedModel,
            availableModels: availableModels,
            documents: documents,
            heartbeat: configFile.heartbeat ?? AgentHeartbeatSettings(),
            channelSessions: configFile.channelSessions ?? AgentChannelSessionSettings(),
            heartbeatStatus: heartbeatStatus,
            runtime: configFile.runtime ?? summary.runtime
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

        let newRole = request.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? summary.role
        guard !newRole.isEmpty else {
            throw StoreError.invalidPayload
        }

        let runtime = request.runtime
        let normalizedSelectedModel = request.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel: String?
        switch runtime.type {
        case .native:
            guard let normalizedSelectedModel, !normalizedSelectedModel.isEmpty else {
                throw StoreError.invalidModel
            }

            guard let canonical = CoreService.resolveCanonicalAgentModelID(
                normalizedSelectedModel,
                availableModels: availableModels
            ) else {
                throw StoreError.invalidModel
            }
            selectedModel = canonical
        case .acp:
            let targetId = runtime.acp?.targetId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !targetId.isEmpty else {
                throw StoreError.invalidPayload
            }
            selectedModel = nil
        }

        let normalizedIdentityMarkdown = normalizedIdentityValue(
            from: request.documents.identityMarkdown,
            fallback: summary.id
        ) + "\n"

        let normalizedDocuments = AgentDocumentBundle(
            userMarkdown: normalizedDocumentText(request.documents.userMarkdown),
            agentsMarkdown: normalizedDocumentText(request.documents.agentsMarkdown),
            soulMarkdown: normalizedDocumentText(request.documents.soulMarkdown),
            identityMarkdown: normalizedIdentityMarkdown,
            heartbeatMarkdown: normalizedHeartbeatText(request.documents.heartbeatMarkdown),
            friendReminderMarkdown: normalizedOptionalDocumentText(request.documents.friendReminderMarkdown),
            memoryMarkdown: normalizedDocumentText(request.documents.memoryMarkdown)
        )

        try AgentMarkdownLimits.validateAgentDocumentBundle(normalizedDocuments)

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
                    role: newRole,
                    createdAt: summary.createdAt,
                    selectedModel: selectedModel,
                    heartbeat: heartbeat,
                    channelSessions: channelSessions,
                    runtime: runtime
                ),
                isSystem: summary.isSystem
            )

            if newRole != summary.role {
                var updatedSummary = summary
                updatedSummary.role = newRole
                try writeAgentSummary(updatedSummary)
            }

            let agentDirectory = agentDirectoryURL(for: normalizedAgentID, isSystem: summary.isSystem)
            try writeTextFile(contents: normalizedDocuments.agentsMarkdown, at: agentDirectory.appendingPathComponent("AGENTS.md"))
            try writeTextFile(contents: normalizedDocuments.userMarkdown, at: agentDirectory.appendingPathComponent("USER.md"))
            try writeTextFile(contents: normalizedDocuments.soulMarkdown, at: agentDirectory.appendingPathComponent("SOUL.md"))
            try writeTextFile(contents: normalizedDocuments.identityMarkdown, at: agentDirectory.appendingPathComponent("IDENTITY.md"))
            try writeTextFile(contents: normalizedDocuments.identityMarkdown, at: agentDirectory.appendingPathComponent("IDENTITY.id"))
            try writeTextFile(contents: normalizedDocuments.heartbeatMarkdown, at: agentDirectory.appendingPathComponent("HEARTBEAT.md"))
            try writeTextFile(contents: normalizedDocuments.friendReminderMarkdown, at: agentDirectory.appendingPathComponent("FRIEND_REMINDER.md"))
            try writeTextFile(contents: normalizedDocuments.memoryMarkdown, at: agentDirectory.appendingPathComponent("MEMORY.md"))
        } catch {
            throw StoreError.storageFailure
        }

        return AgentConfigDetail(
            agentId: normalizedAgentID,
            role: newRole,
            selectedModel: selectedModel,
            availableModels: availableModels,
            documents: normalizedDocuments,
            heartbeat: heartbeat,
            channelSessions: channelSessions,
            heartbeatStatus: try readHeartbeatStatus(agentID: normalizedAgentID, isSystem: summary.isSystem),
            runtime: runtime
        )
    }

    func deleteAgent(id: String) throws {
        guard let normalizedID = normalizedAgentID(id) else {
            throw StoreError.invalidID
        }
        let summary = try getAgent(id: normalizedID)
        guard !summary.isSystem else {
            throw StoreError.invalidPayload
        }
        let dirURL = agentDirectoryURL(for: normalizedID, isSystem: false)
        guard fileManager.fileExists(atPath: dirURL.path) else {
            throw StoreError.notFound
        }
        try fileManager.removeItem(at: dirURL)
    }

    func recordPetInteraction(agentID: String, input: AgentPetProgressionInput) throws -> AgentPetSummary? {
        guard let normalizedAgentID = normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }

        let summary = try getAgent(id: normalizedAgentID)
        guard !summary.isSystem, let pet = summary.pet else {
            return nil
        }

        var state = try readPetProgressState(agentID: normalizedAgentID, isSystem: summary.isSystem, baseStats: pet.baseStats)
        AgentPetProgressionEngine.apply(
            state: &state,
            input: input,
            baseStats: pet.baseStats
        )
        try writePetProgressState(state, agentID: normalizedAgentID, isSystem: summary.isSystem)
        return AgentPetFactory.summary(pet, applying: state)
    }

    func readAgentDocuments(agentID: String) throws -> AgentDocumentBundle {
        guard let normalizedID = self.normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }

        let summary = try getAgent(id: normalizedID)
        let agentDirectory = agentDirectoryURL(for: normalizedID, isSystem: summary.isSystem)
        let userMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("USER.md"), fallback: "# User\n")
        let agentsMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("AGENTS.md"), fallback: "# Agent\n")
        let soulMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("SOUL.md"), fallback: "# Soul\n")
        let heartbeatMarkdown = try readHeartbeatFile(agentID: normalizedID, isSystem: summary.isSystem)
        let friendReminderMarkdown = try readOptionalTextFile(at: agentDirectory.appendingPathComponent("FRIEND_REMINDER.md"), fallback: "")
        let memoryMarkdown = try readTextFile(at: agentDirectory.appendingPathComponent("MEMORY.md"), fallback: "")

        let identityMarkdown = try readIdentityMarkdown(
            markdownURL: agentDirectory.appendingPathComponent("IDENTITY.md"),
            legacyURL: agentDirectory.appendingPathComponent("IDENTITY.id"),
            fallback: normalizedID
        )

        return AgentDocumentBundle(
            userMarkdown: userMarkdown,
            agentsMarkdown: agentsMarkdown,
            soulMarkdown: soulMarkdown,
            identityMarkdown: identityMarkdown,
            heartbeatMarkdown: heartbeatMarkdown,
            friendReminderMarkdown: friendReminderMarkdown,
            memoryMarkdown: memoryMarkdown
        )
    }

    func directoryURL(agentID: String) throws -> URL {
        guard let normalizedID = self.normalizedAgentID(agentID) else {
            throw StoreError.invalidID
        }
        let summary = try getAgent(id: normalizedID)
        return agentDirectoryURL(for: normalizedID, isSystem: summary.isSystem)
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

    private func petStateURL(for id: String, isSystem: Bool) -> URL {
        agentDirectoryURL(for: id, isSystem: isSystem).appendingPathComponent("pet-state.json")
    }

    private var petDraftRootURL: URL {
        agentsRootURL
            .appendingPathComponent(".sloppy", isDirectory: true)
            .appendingPathComponent("pet-drafts", isDirectory: true)
    }

    private func petDraftURL(for id: String) -> URL {
        petDraftRootURL.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func agentPetArchiveURL(for summary: AgentSummary, petId: String) -> URL {
        agentDirectoryURL(for: summary.id, isSystem: summary.isSystem)
            .appendingPathComponent(".sloppy", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
            .appendingPathComponent(petId, isDirectory: true)
    }

    private func readAgentSummary(id: String, isSystem: Bool) throws -> AgentSummary {
        let metadataURL = agentMetadataURL(for: id, isSystem: isSystem)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw StoreError.notFound
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSummary.self, from: data)
        return try hydratePetSummary(decoded, isSystem: isSystem)
    }

    private func writeAgentSummary(_ summary: AgentSummary) throws {
        let petMetadata = summary.pet.map {
            AgentPetMetadataFile(
                petId: $0.petId,
                genomeHex: $0.genomeHex,
                parts: $0.parts,
                partRarities: $0.partRarities,
                rarity: $0.rarity,
                baseStats: $0.baseStats,
                transferable: $0.transferable,
                visual: $0.visual,
                evolution: $0.evolution,
                stageAssets: $0.stageAssets
            )
        }
        let payloadModel = AgentMetadataFile(
            id: summary.id,
            displayName: summary.displayName,
            role: summary.role,
            createdAt: summary.createdAt,
            isSystem: summary.isSystem,
            runtime: summary.runtime,
            pet: petMetadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(payloadModel) + Data("\n".utf8)
        try payload.write(to: agentMetadataURL(for: summary.id, isSystem: summary.isSystem), options: .atomic)
    }

    private func readPetDraftIfRequested(_ rawDraftID: String?) throws -> AgentPetDraftRecord? {
        guard let rawDraftID, !rawDraftID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let draftID = normalizedPetDraftID(rawDraftID) else {
            throw StoreError.invalidPayload
        }
        let url = petDraftURL(for: draftID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.invalidPayload
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentPetDraftRecord.self, from: data)
    }

    private func persistPetDraft(_ draft: AgentPetDraftRecord, for summary: AgentSummary) throws {
        let targetURL = agentPetArchiveURL(for: summary, petId: draft.generated.summary.petId)
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft) + Data("\n".utf8)
        try data.write(to: targetURL.appendingPathComponent("draft.json"), options: .atomic)
    }

    private func deletePetDraft(id: String) throws {
        guard let draftID = normalizedPetDraftID(id) else { return }
        let url = petDraftURL(for: draftID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func normalizedPetDraftID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else {
            return nil
        }
        return trimmed
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
            at: agentDirectory.appendingPathComponent("AGENTS.md")
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
            at: agentDirectory.appendingPathComponent("USER.md")
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
            at: agentDirectory.appendingPathComponent("SOUL.md")
        )

        try writeTextFile(
            contents: summary.id + "\n",
            at: agentDirectory.appendingPathComponent("IDENTITY.md")
        )
        try writeTextFile(
            contents: summary.id + "\n",
            at: agentDirectory.appendingPathComponent("IDENTITY.id")
        )
        try writeTextFile(
            contents: "",
            at: agentDirectory.appendingPathComponent("HEARTBEAT.md")
        )
        try writeTextFile(
            contents: "",
            at: agentDirectory.appendingPathComponent("FRIEND_REMINDER.md")
        )
        try writeTextFile(
            contents: "",
            at: agentDirectory.appendingPathComponent("MEMORY.md")
        )

        try writeAgentConfigFile(
            AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableModels.first?.id,
                heartbeat: AgentHeartbeatSettings(),
                channelSessions: AgentChannelSessionSettings(),
                runtime: summary.runtime
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
            approval: .init(enabled: false),
            preToolsHook: .init(),
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

    private func readAgentConfigFile(
        for summary: AgentSummary,
        availableModels: [ProviderModelOption],
        persistedModelAllowed: ((String) -> Bool)?
    ) throws -> AgentConfigFile {
        let configURL = agentConfigURL(for: summary.id, isSystem: summary.isSystem)
        if !fileManager.fileExists(atPath: configURL.path) {
            let fallback = AgentConfigFile(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                selectedModel: availableModels.first?.id,
                heartbeat: AgentHeartbeatSettings(),
                channelSessions: AgentChannelSessionSettings(),
                runtime: summary.runtime
            )
            try writeAgentConfigFile(fallback, isSystem: summary.isSystem)
            return fallback
        }

        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded = try decoder.decode(AgentConfigFile.self, from: data)
        let selectedModel = decoded.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtime = decoded.runtime ?? summary.runtime
        let resolvedModel = selectedModel.flatMap { raw -> String? in
            if let canonical = CoreService.resolveCanonicalAgentModelID(raw, availableModels: availableModels) {
                return canonical
            }
            if let persistedModelAllowed, persistedModelAllowed(raw) {
                return raw
            }
            return nil
        }
        if let selectedModel, let resolvedModel, resolvedModel != selectedModel {
            decoded = AgentConfigFile(
                id: decoded.id,
                displayName: decoded.displayName,
                role: decoded.role,
                createdAt: decoded.createdAt,
                selectedModel: resolvedModel,
                heartbeat: decoded.heartbeat ?? AgentHeartbeatSettings(),
                channelSessions: decoded.channelSessions ?? AgentChannelSessionSettings(),
                runtime: runtime
            )
            try writeAgentConfigFile(decoded, isSystem: summary.isSystem)
        }
        let requiresDefaultModel = runtime.type == .native
            && (resolvedModel == nil || (selectedModel?.isEmpty ?? true))
        if requiresDefaultModel {
            decoded = AgentConfigFile(
                id: decoded.id,
                displayName: decoded.displayName,
                role: decoded.role,
                createdAt: decoded.createdAt,
                selectedModel: availableModels.first?.id,
                heartbeat: decoded.heartbeat ?? AgentHeartbeatSettings(),
                channelSessions: decoded.channelSessions ?? AgentChannelSessionSettings(),
                runtime: runtime
            )
            try writeAgentConfigFile(decoded, isSystem: summary.isSystem)
        } else if decoded.heartbeat == nil || decoded.channelSessions == nil || decoded.runtime == nil {
            decoded = AgentConfigFile(
                id: decoded.id,
                displayName: decoded.displayName,
                role: decoded.role,
                createdAt: decoded.createdAt,
                selectedModel: runtime.type == .native ? decoded.selectedModel : nil,
                heartbeat: decoded.heartbeat ?? AgentHeartbeatSettings(),
                channelSessions: decoded.channelSessions ?? AgentChannelSessionSettings(),
                runtime: runtime
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

    private func readOptionalTextFile(at url: URL, fallback: String) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            return fallback
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return normalizedOptionalDocumentText(text)
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

    private func hydratePetSummary(_ summary: AgentSummary, isSystem: Bool) throws -> AgentSummary {
        guard !isSystem else {
            return AgentSummary(
                id: summary.id,
                displayName: summary.displayName,
                role: summary.role,
                createdAt: summary.createdAt,
                isSystem: summary.isSystem,
                runtime: summary.runtime,
                pet: nil
            )
        }

        var nextSummary = summary
        if nextSummary.pet == nil {
            let generated = AgentPetFactory.makePet(createdAt: nextSummary.createdAt)
            nextSummary.pet = generated.summary
            try writePetProgressState(generated.state, agentID: nextSummary.id, isSystem: false)
            try writeAgentSummary(nextSummary)
            return nextSummary
        }

        guard let pet = nextSummary.pet else {
            return nextSummary
        }

        let state = try readPetProgressState(agentID: nextSummary.id, isSystem: false, baseStats: pet.baseStats)
        let hydratedPet = AgentPetFactory.summary(pet, applying: state)
        if pet != hydratedPet {
            nextSummary.pet = hydratedPet
            try writeAgentSummary(nextSummary)
        }
        return nextSummary
    }

    private func readPetProgressState(
        agentID: String,
        isSystem: Bool,
        baseStats: AgentPetStats
    ) throws -> AgentPetProgressState {
        let url = petStateURL(for: agentID, isSystem: isSystem)
        if !fileManager.fileExists(atPath: url.path) {
            let fallback = AgentPetProgressState(currentStats: baseStats)
            try writePetProgressState(fallback, agentID: agentID, isSystem: isSystem)
            return fallback
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded = try decoder.decode(AgentPetProgressState.self, from: data)
        decoded.currentStats = AgentPetStats(
            wisdom: max(baseStats.wisdom, decoded.currentStats.wisdom),
            debugging: max(baseStats.debugging, decoded.currentStats.debugging),
            patience: max(baseStats.patience, decoded.currentStats.patience),
            snark: max(baseStats.snark, decoded.currentStats.snark),
            chaos: max(baseStats.chaos, decoded.currentStats.chaos)
        ).clamped()
        return decoded
    }

    private func writePetProgressState(_ state: AgentPetProgressState, agentID: String, isSystem: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state) + Data("\n".utf8)
        try data.write(to: petStateURL(for: agentID, isSystem: isSystem), options: .atomic)
    }

    private func normalizedDocumentText(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") {
            return normalized
        }
        return normalized + "\n"
    }

    private func normalizedOptionalDocumentText(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
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

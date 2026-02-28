import Foundation
import Protocols

final class AgentToolsFileStore {
    enum StoreError: Error {
        case invalidAgentID
        case invalidPayload
        case agentNotFound
        case storageFailure
    }

    private let fileManager: FileManager
    private var agentsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    func updateAgentsRootURL(_ url: URL) {
        self.agentsRootURL = url
    }

    func defaultPolicy() -> AgentToolsPolicy {
        AgentToolsPolicy(
            version: 1,
            defaultPolicy: .allow,
            tools: [:],
            guardrails: .init()
        )
    }

    func getPolicy(agentID: String, knownToolIDs: Set<String>) throws -> AgentToolsPolicy {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let agentDirectory = agentsRootURL.appendingPathComponent(normalizedAgentID, isDirectory: true)
        guard fileManager.fileExists(atPath: agentDirectory.path) else {
            throw StoreError.agentNotFound
        }

        let url = toolsConfigURL(agentID: normalizedAgentID)
        if !fileManager.fileExists(atPath: url.path) {
            let created = defaultPolicy()
            try writePolicy(created, agentID: normalizedAgentID)
            return created
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode(AgentToolsPolicy.self, from: data)
            return try validated(decoded, knownToolIDs: knownToolIDs)
        } catch {
            throw StoreError.invalidPayload
        }
    }

    func updatePolicy(
        agentID: String,
        request: AgentToolsUpdateRequest,
        knownToolIDs: Set<String>
    ) throws -> AgentToolsPolicy {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let agentDirectory = agentsRootURL.appendingPathComponent(normalizedAgentID, isDirectory: true)
        guard fileManager.fileExists(atPath: agentDirectory.path) else {
            throw StoreError.agentNotFound
        }

        let version = request.version ?? 1
        let policy = AgentToolsPolicy(
            version: version,
            defaultPolicy: request.defaultPolicy,
            tools: request.tools,
            guardrails: request.guardrails
        )
        let validated = try validated(policy, knownToolIDs: knownToolIDs)

        do {
            try writePolicy(validated, agentID: normalizedAgentID)
            return validated
        } catch {
            throw StoreError.storageFailure
        }
    }

    func toolsConfigURL(agentID: String) -> URL {
        agentsRootURL
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("tools.json")
    }

    private func writePolicy(_ policy: AgentToolsPolicy, agentID: String) throws {
        let toolsDirectory = agentsRootURL
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("tools", isDirectory: true)
        try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

        let url = toolsDirectory.appendingPathComponent("tools.json")
        let payload = try encoder.encode(policy) + Data("\n".utf8)
        try payload.write(to: url, options: .atomic)
    }

    private func validated(_ policy: AgentToolsPolicy, knownToolIDs: Set<String>) throws -> AgentToolsPolicy {
        guard policy.version == 1 else {
            throw StoreError.invalidPayload
        }

        if policy.guardrails.maxReadBytes <= 0 ||
            policy.guardrails.maxWriteBytes <= 0 ||
            policy.guardrails.execTimeoutMs <= 0 ||
            policy.guardrails.maxExecOutputBytes <= 0 ||
            policy.guardrails.maxProcessesPerSession <= 0 ||
            policy.guardrails.maxToolCallsPerMinute <= 0 ||
            policy.guardrails.webTimeoutMs <= 0 ||
            policy.guardrails.webMaxBytes <= 0 {
            throw StoreError.invalidPayload
        }

        let unknownIDs = Set(policy.tools.keys).subtracting(knownToolIDs)
        if !unknownIDs.isEmpty {
            throw StoreError.invalidPayload
        }

        return policy
    }

    private func normalizedAgentID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidAgentID
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw StoreError.invalidAgentID
        }
        return trimmed
    }
}

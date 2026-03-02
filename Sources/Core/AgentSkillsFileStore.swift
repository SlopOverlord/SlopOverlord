import Foundation
import Protocols

/// Manages storage of skills for agents in the file system.
/// Skills are stored in /workspace/agents/AGENT_ID/skills/
final class AgentSkillsFileStore {
    enum StoreError: Error {
        case invalidAgentID
        case agentNotFound
        case skillAlreadyExists
        case skillNotFound
        case storageFailure
        case manifestReadFailed
        case manifestWriteFailed
        case invalidSkillID
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
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func updateAgentsRootURL(_ url: URL) {
        self.agentsRootURL = url
    }

    // MARK: - Directory Paths

    func skillsDirectoryURL(agentID: String) -> URL {
        agentsRootURL
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    func skillDirectoryURL(agentID: String, skillID: String) -> URL {
        skillsDirectoryURL(agentID: agentID)
            .appendingPathComponent(skillID, isDirectory: true)
    }

    func manifestURL(agentID: String) -> URL {
        skillsDirectoryURL(agentID: agentID)
            .appendingPathComponent("skills.json")
    }

    // MARK: - Manifest Management

    func readManifest(agentID: String) throws -> AgentSkillsManifest {
        let url = manifestURL(agentID: agentID)

        guard fileManager.fileExists(atPath: url.path) else {
            return AgentSkillsManifest()
        }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(AgentSkillsManifest.self, from: data)
        } catch {
            throw StoreError.manifestReadFailed
        }
    }

    func writeManifest(_ manifest: AgentSkillsManifest, agentID: String) throws {
        let directory = skillsDirectoryURL(agentID: agentID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = manifestURL(agentID: agentID)
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Skills Operations

    /// List all installed skills for an agent
    func listSkills(agentID: String) throws -> [InstalledSkill] {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let agentDirectory = agentsRootURL.appendingPathComponent(normalizedAgentID, isDirectory: true)

        guard fileManager.fileExists(atPath: agentDirectory.path) else {
            throw StoreError.agentNotFound
        }

        let manifest = try readManifest(agentID: normalizedAgentID)
        return manifest.installedSkills
    }

    /// Get a specific skill by ID
    func getSkill(agentID: String, skillID: String) throws -> InstalledSkill {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSkillID = try normalizedSkillID(skillID)

        let manifest = try readManifest(agentID: normalizedAgentID)

        guard let skill = manifest.installedSkills.first(where: { $0.id == normalizedSkillID }) else {
            throw StoreError.skillNotFound
        }

        return skill
    }

    /// Install a new skill for an agent
    @discardableResult
    func installSkill(
        agentID: String,
        owner: String,
        repo: String,
        name: String,
        description: String?
    ) throws -> InstalledSkill {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let agentDirectory = agentsRootURL.appendingPathComponent(normalizedAgentID, isDirectory: true)

        guard fileManager.fileExists(atPath: agentDirectory.path) else {
            throw StoreError.agentNotFound
        }

        let skillID = "\(owner)/\(repo)"
        let skillDirectory = skillDirectoryURL(agentID: normalizedAgentID, skillID: skillID)

        // Check if skill already exists
        var manifest = try readManifest(agentID: normalizedAgentID)
        if manifest.installedSkills.contains(where: { $0.id == skillID }) {
            throw StoreError.skillAlreadyExists
        }

        // Create skill directory
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)

        // Create skill entry
        let skill = InstalledSkill(
            id: skillID,
            owner: owner,
            repo: repo,
            name: name,
            description: description,
            localPath: skillDirectory.path
        )

        // Update manifest
        manifest.installedSkills.append(skill)
        try writeManifest(manifest, agentID: normalizedAgentID)

        return skill
    }

    /// Uninstall a skill from an agent
    func uninstallSkill(agentID: String, skillID: String) throws {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSkillID = try normalizedSkillID(skillID)

        // Check skill exists
        var manifest = try readManifest(agentID: normalizedAgentID)
        guard let index = manifest.installedSkills.firstIndex(where: { $0.id == normalizedSkillID }) else {
            throw StoreError.skillNotFound
        }

        // Remove skill directory
        let skillDirectory = skillDirectoryURL(agentID: normalizedAgentID, skillID: normalizedSkillID)
        if fileManager.fileExists(atPath: skillDirectory.path) {
            try fileManager.removeItem(at: skillDirectory)
        }

        // Update manifest
        manifest.installedSkills.remove(at: index)
        try writeManifest(manifest, agentID: normalizedAgentID)
    }

    /// Get the path to a skill directory for external file operations
    func getSkillPath(agentID: String, skillID: String) throws -> String {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let normalizedSkillID = try normalizedSkillID(skillID)

        let skillDirectory = skillDirectoryURL(agentID: normalizedAgentID, skillID: normalizedSkillID)
        return skillDirectory.path
    }

    /// Ensure skills directory exists for an agent (called during agent creation)
    func ensureSkillsDirectory(agentID: String) throws {
        let normalizedAgentID = try normalizedAgentID(agentID)
        let directory = skillsDirectoryURL(agentID: normalizedAgentID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Create empty manifest if it doesn't exist
        let manifestPath = manifestURL(agentID: normalizedAgentID)
        if !fileManager.fileExists(atPath: manifestPath.path) {
            let manifest = AgentSkillsManifest()
            try writeManifest(manifest, agentID: normalizedAgentID)
        }
    }

    // MARK: - Validation

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

    private func normalizedSkillID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidSkillID
        }
        // Allow owner/repo format with alphanumeric, hyphens, underscores
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.-/")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw StoreError.invalidSkillID
        }
        return trimmed
    }
}

import Foundation
import Protocols

/// File-backed store for per-channel chat mode overrides.
/// Persists to: workspace/channel-chat-modes.json
actor ChannelChatModeStore {
    private let fileManager: FileManager
    private var storeURL: URL
    private var modes: [String: AgentChatMode]

    init(workspaceRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storeURL = workspaceRootURL.appendingPathComponent("channel-chat-modes.json")
        self.modes = (try? Self.load(from: storeURL)) ?? [:]
    }

    func updateWorkspaceRootURL(_ url: URL) {
        storeURL = url.appendingPathComponent("channel-chat-modes.json")
        modes = (try? Self.load(from: storeURL)) ?? [:]
    }

    func get(channelId: String) -> AgentChatMode {
        modes[channelId] ?? .ask
    }

    func set(channelId: String, mode: AgentChatMode) {
        modes[channelId] = mode
        try? save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(modes.mapValues(\.rawValue))
        try data.write(to: storeURL, options: .atomic)
    }

    private static func load(from url: URL) throws -> [String: AgentChatMode] {
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        return raw.compactMapValues(AgentChatMode.init(rawValue:))
    }
}

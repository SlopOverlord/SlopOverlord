import Foundation

/// File-backed store for per-channel model overrides.
/// Persists to: workspace/channel-models.json
actor ChannelModelStore {
    private let fileManager: FileManager
    private var storeURL: URL
    private var models: [String: String]

    init(workspaceRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storeURL = workspaceRootURL.appendingPathComponent("channel-models.json")
        self.models = (try? Self.load(from: storeURL)) ?? [:]
    }

    func updateWorkspaceRootURL(_ url: URL) {
        storeURL = url.appendingPathComponent("channel-models.json")
        models = (try? Self.load(from: storeURL)) ?? [:]
    }

    func get(channelId: String) -> String? {
        models[channelId]
    }

    func all() -> [String: String] {
        models
    }

    func set(channelId: String, model: String) {
        models[channelId] = model
        try? save()
    }

    func remove(channelId: String) {
        models.removeValue(forKey: channelId)
        try? save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(models)
        try data.write(to: storeURL, options: .atomic)
    }

    private static func load(from url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

import Foundation
import Protocols

// MARK: - Channel Plugins

extension CoreService {
    // MARK: - Channel Plugins

    public func listChannelPlugins() async -> [ChannelPluginRecord] {
        await store.listChannelPlugins()
    }

    public func getChannelPlugin(id: String) async throws -> ChannelPluginRecord {
        guard let normalized = normalizedPluginID(id) else {
            throw ChannelPluginError.invalidID
        }
        guard let plugin = await store.channelPlugin(id: normalized) else {
            throw ChannelPluginError.notFound
        }
        return plugin
    }

    public func createChannelPlugin(_ request: ChannelPluginCreateRequest) async throws -> ChannelPluginRecord {
        let id: String
        if let requestID = request.id {
            guard let normalized = normalizedPluginID(requestID) else {
                throw ChannelPluginError.invalidID
            }
            if await store.channelPlugin(id: normalized) != nil {
                throw ChannelPluginError.conflict
            }
            id = normalized
        } else {
            id = UUID().uuidString.lowercased()
        }

        let type = request.type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty else {
            throw ChannelPluginError.invalidPayload
        }

        let baseUrl = request.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseUrl.isEmpty else {
            throw ChannelPluginError.invalidPayload
        }

        let now = Date()
        let plugin = ChannelPluginRecord(
            id: id,
            type: type,
            baseUrl: baseUrl,
            channelIds: request.channelIds ?? [],
            config: request.config ?? [:],
            enabled: request.enabled ?? true,
            createdAt: now,
            updatedAt: now
        )
        await store.saveChannelPlugin(plugin)
        return plugin
    }

    public func updateChannelPlugin(id: String, request: ChannelPluginUpdateRequest) async throws -> ChannelPluginRecord {
        guard let normalized = normalizedPluginID(id) else {
            throw ChannelPluginError.invalidID
        }
        guard var plugin = await store.channelPlugin(id: normalized) else {
            throw ChannelPluginError.notFound
        }
        if let type = request.type {
            let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ChannelPluginError.invalidPayload }
            plugin.type = trimmed
        }
        if let baseUrl = request.baseUrl {
            let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ChannelPluginError.invalidPayload }
            plugin.baseUrl = trimmed
        }
        if let channelIds = request.channelIds {
            plugin.channelIds = channelIds
        }
        if let config = request.config {
            plugin.config = config
        }
        if let enabled = request.enabled {
            plugin.enabled = enabled
        }
        plugin.updatedAt = Date()
        await store.saveChannelPlugin(plugin)
        if plugin.deliveryMode == ChannelPluginRecord.DeliveryMode.inProcess {
            if plugin.enabled {
                let sourceURL = pluginsRootURL.appendingPathComponent(plugin.id, isDirectory: true)
                if FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("Package.swift").path) {
                    try await startSourceChannelPluginIfNeeded(record: plugin)
                }
            } else {
                await stopActiveGatewayPlugin(id: plugin.id)
            }
        }
        return plugin
    }

    public func deleteChannelPlugin(id: String) async throws {
        guard let normalized = normalizedPluginID(id) else {
            throw ChannelPluginError.invalidID
        }
        guard await store.channelPlugin(id: normalized) != nil else {
            throw ChannelPluginError.notFound
        }
        await stopActiveGatewayPlugin(id: normalized)
        await store.deleteChannelPlugin(id: normalized)
    }

    public func installSourceChannelPlugin(_ request: ChannelPluginInstallRequest) async throws -> ChannelPluginInstallResponse {
        let installer = PluginPackageInstaller(
            pluginsRootURL: pluginsRootURL,
            cacheRootURL: pluginCacheRootURL,
            logger: logger
        )
        let result = try await installer.install(request)
        let enabled = request.enabled ?? true
        await stopActiveGatewayPlugin(id: result.manifest.name)

        let record: ChannelPluginRecord
        if enabled {
            let loader = PluginLoader(logger: logger)
            guard let plugin = loader.loadDylibGatewayPlugin(
                binaryURL: result.binaryURL,
                manifest: result.manifest,
                inboundReceiver: self
            ) else {
                throw ChannelPluginError.invalidPayload
            }
            await channelDelivery.registerPlugin(plugin)
            do {
                try await plugin.start(inboundReceiver: self)
            } catch {
                await channelDelivery.unregisterPlugin(plugin)
                throw error
            }
            activeGatewayPlugins.append(plugin)

            let now = Date()
            let existing = await store.channelPlugin(id: result.manifest.name)
            record = ChannelPluginRecord(
                id: result.manifest.name,
                type: result.manifest.name,
                baseUrl: "",
                channelIds: plugin.channelIds,
                config: existing?.config ?? [:],
                enabled: true,
                deliveryMode: ChannelPluginRecord.DeliveryMode.inProcess,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
        } else {
            let now = Date()
            let existing = await store.channelPlugin(id: result.manifest.name)
            record = ChannelPluginRecord(
                id: result.manifest.name,
                type: result.manifest.name,
                baseUrl: "",
                channelIds: existing?.channelIds ?? [],
                config: existing?.config ?? [:],
                enabled: false,
                deliveryMode: ChannelPluginRecord.DeliveryMode.inProcess,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
        }

        await store.saveChannelPlugin(record)
        return ChannelPluginInstallResponse(
            plugin: record,
            sourcePath: result.sourceURL.path,
            binaryPath: result.binaryURL.path,
            rebuilt: result.rebuilt
        )
    }

    /// Finds the enabled plugin responsible for a given channel ID.
    public func channelPluginForChannel(channelId: String) async -> ChannelPluginRecord? {
        let plugins = await store.listChannelPlugins()
        return plugins.first { $0.enabled && $0.channelIds.contains(channelId) }
    }

    func normalizedPluginID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        return trimmed
    }

    private func startSourceChannelPluginIfNeeded(record: ChannelPluginRecord) async throws {
        guard activeGatewayPlugins.contains(where: { $0.id == record.id }) == false else {
            return
        }
        let sourceURL = pluginsRootURL.appendingPathComponent(record.id, isDirectory: true)
        let loader = PluginLoader(logger: logger)
        guard let manifest = loader.loadManifest(at: sourceURL),
              manifest.name == record.id,
              manifest.protocol == "gateway",
              let loaded = await loader.loadGatewayPlugin(
                from: sourceURL,
                cacheRootURL: pluginCacheRootURL,
                manifest: manifest,
                inboundReceiver: self
              )
        else {
            throw ChannelPluginError.invalidPayload
        }
        let plugin = loaded.plugin
        await channelDelivery.registerPlugin(plugin)
        do {
            try await plugin.start(inboundReceiver: self)
        } catch {
            await channelDelivery.unregisterPlugin(plugin)
            throw error
        }
        activeGatewayPlugins.append(plugin)
        await seedExternalPluginRecord(
            id: manifest.name,
            type: record.type,
            channelIds: plugin.channelIds,
            enabled: true
        )
    }

    /// Returns actor graph snapshot used by visual canvas board.
}

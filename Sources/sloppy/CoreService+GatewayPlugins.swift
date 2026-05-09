import Foundation
import AgentRuntime
import Protocols
import PluginSDK
import Logging

// MARK: - Gateway Plugin Lifecycle

extension CoreService {
    public func bootstrapChannelPlugins() async {
        await refreshOAuthModelCacheIfNeeded()

        if let telegramConfig = currentConfig.channels.telegram {
            let plugin = builtInGatewayPluginFactory.makeTelegram(
                telegramConfig,
                self as any TelegramModelPickerBridge,
                self as any ToolApprovalBridge
            )
            await startBuiltInPlugin(
                plugin,
                id: "telegram",
                type: "telegram",
                channelIds: Array(Set(telegramConfig.channelChatMap.keys).union(telegramConfig.topicChannelMap.values))
            )
        }

        if let discordConfig = currentConfig.channels.discord {
            let plugin = builtInGatewayPluginFactory.makeDiscord(discordConfig)
            await startBuiltInPlugin(
                plugin,
                id: "discord",
                type: "discord",
                channelIds: Array(discordConfig.channelDiscordChannelMap.keys)
            )
        }

        let pluginsDir = workspaceRootURL.appendingPathComponent("plugins", isDirectory: true)
        let loader = PluginLoader(logger: logger)
        let externalPlugins = await loader.loadGatewayPlugins(
            from: pluginsDir,
            inboundReceiver: self
        )
        for plugin in externalPlugins {
            await channelDelivery.registerPlugin(plugin)
            activeGatewayPlugins.append(plugin)
            do {
                try await plugin.start(inboundReceiver: self)
                logger.info("External gateway plugin \(plugin.id) started.")
            } catch {
                logger.error("Failed to start external gateway plugin \(plugin.id): \(error)")
            }
        }

        // Initialize periodic visor scheduler from config.
        if visorScheduler == nil {
            visorScheduler = VisorScheduler(
                config: buildVisorSchedulerConfig(),
                logger: logger
            ) { [weak self] in
                guard let self else { return }
                _ = await self.triggerVisorBulletin()
            }
        }
        if currentConfig.visor.scheduler.enabled {
            await visorScheduler?.start()
        }
        
        if cronRunner == nil {
            cronRunner = CronRunner(
                store: self.store,
                runtime: self.runtime,
                notificationService: self.notificationService,
                logger: self.logger
            )
        }
        await cronRunner?.start()

        if heartbeatRunner == nil {
            heartbeatRunner = HeartbeatRunner(
                logger: Logger(label: "sloppy.core.heartbeat")
            ) { [weak self] in
                guard let self else {
                    return []
                }
                return await self.listHeartbeatSchedules()
            } executor: { [weak self] agentID in
                guard let self else {
                    return
                }
                await self.runAgentHeartbeat(agentID: agentID)
            }
        }
        await heartbeatRunner?.start()

        await runtime.startVisorSupervision(
            tickIntervalSeconds: currentConfig.visor.tickIntervalSeconds,
            workerTimeoutSeconds: currentConfig.visor.workerTimeoutSeconds,
            branchTimeoutSeconds: currentConfig.visor.branchTimeoutSeconds,
            maintenanceIntervalSeconds: currentConfig.visor.maintenanceIntervalSeconds,
            decayRatePerDay: currentConfig.visor.decayRatePerDay,
            pruneImportanceThreshold: currentConfig.visor.pruneImportanceThreshold,
            pruneMinAgeDays: currentConfig.visor.pruneMinAgeDays,
            channelDegradedFailureCount: currentConfig.visor.channelDegradedFailureCount,
            channelDegradedWindowSeconds: currentConfig.visor.channelDegradedWindowSeconds,
            idleThresholdSeconds: currentConfig.visor.idleThresholdSeconds,
            mergeEnabled: currentConfig.visor.mergeEnabled,
            mergeSimilarityThreshold: currentConfig.visor.mergeSimilarityThreshold,
            mergeMaxPerRun: currentConfig.visor.mergeMaxPerRun
        )
    }

    /// Stops all active in-process gateway plugins and visor scheduler. Called on shutdown.
    public func shutdownChannelPlugins() async {
        for plugin in activeGatewayPlugins {
            await plugin.stop()
        }
        activeGatewayPlugins.removeAll()

        await visorScheduler?.stop()
        await runtime.stopVisorSupervision()
        await memoryOutboxIndexer?.stop()
        await cronRunner?.stop()
        await heartbeatRunner?.stop()
        await acpSessionManager.shutdown()
    }

    func seedBuiltInPluginRecord(
        id pluginId: String,
        type: String,
        channelIds: [String]
    ) async {
        let existing = await store.channelPlugin(id: pluginId)
        let now = Date()
        let record = ChannelPluginRecord(
            id: pluginId,
            type: type,
            baseUrl: "",
            channelIds: channelIds,
            config: [:],
            enabled: true,
            deliveryMode: ChannelPluginRecord.DeliveryMode.inProcess,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        await store.saveChannelPlugin(record)
    }

    /// Accepts a user channel message and returns routing decision.
    func startBuiltInPlugin(
        _ plugin: any GatewayPlugin,
        id: String,
        type: String,
        channelIds: [String]
    ) async {
        await channelDelivery.registerPlugin(plugin)
        activeGatewayPlugins.append(plugin)
        await seedBuiltInPluginRecord(id: id, type: type, channelIds: channelIds)

        do {
            try await plugin.start(inboundReceiver: self)
            logger.info("\(type.capitalized) gateway plugin started.")
        } catch {
            logger.error("Failed to start \(type) gateway plugin: \(error)")
        }
    }

    func reloadBuiltInPlugin(
        id: String,
        type: String,
        newPlugin: (any GatewayPlugin)?,
        channelIds: [String],
        removedBecauseEmptyToken: Bool
    ) async {
        if let existing = activeGatewayPlugins.first(where: { $0.id == id }) {
            logger.info("\(type.capitalized) config changed — stopping existing plugin.")
            await existing.stop()
            await channelDelivery.unregisterPlugin(existing)
            activeGatewayPlugins.removeAll { $0.id == id }
        }

        guard let newPlugin else {
            let reason = removedBecauseEmptyToken ? "empty token" : "no config"
            await store.deleteChannelPlugin(id: id)
            logger.info("\(type.capitalized) plugin removed (\(reason)).")
            return
        }

        logger.info("\(type.capitalized) config changed — starting new plugin.")
        await startBuiltInPlugin(newPlugin, id: id, type: type, channelIds: channelIds)
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await memoryOutboxIndexer?.stop()
    }



    struct TaskDelegation {
        let actorID: String?
        let agentID: String?
        let channelID: String
    }

}

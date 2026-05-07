import Foundation
import AnyLanguageModel
import AgentRuntime
import Protocols
import PluginSDK

// MARK: - Config

extension CoreService {
    public func updateConfig(_ config: CoreConfig) async throws -> CoreConfig {
        let previousOnboardingCompleted = currentConfig.onboarding.completed
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encoded = try encoder.encode(config)
        let payload = encoded + Data("\n".utf8)
        let url = URL(fileURLWithPath: configPath)
        try payload.write(to: url, options: .atomic)

        let previousChannels = currentConfig.channels
        currentConfig = config
        let refreshedStore = persistenceBuilder.makeStore(config: config)
        store = refreshedStore
        workspaceRootURL = config
            .resolvedWorkspaceRootURL(currentDirectory: workspaceCurrentDirectory)
        agentsRootURL = workspaceRootURL
            .appendingPathComponent("agents", isDirectory: true)
        agentCatalogStore.updateAgentsRootURL(agentsRootURL)
        sessionStore.updateAgentsRootURL(agentsRootURL)
        actorBoardStore.updateWorkspaceRootURL(workspaceRootURL)
        await channelModelStore.updateWorkspaceRootURL(workspaceRootURL)
        await channelChatModeStore.updateWorkspaceRootURL(workspaceRootURL)
        await sessionOrchestrator.updateAgentsRootURL(agentsRootURL)
        await toolsAuthorization.updateAgentsRootURL(agentsRootURL)
        await mcpRegistry.updateConfig(config.mcp)
        await acpSessionManager.updateConfig(
            config.acp,
            workspaceRootURL: workspaceRootURL,
            agentsRootURL: agentsRootURL
        )
        await toolExecution.updateLSPConfig(config.lsp)
        await toolsAuthorization.invalidateCachedPolicies()
        toolExecution.updateWorkspaceRootURL(workspaceRootURL)
        await toolExecution.updateBrowserConfig(config.browser)
        toolExecution.updateStore(refreshedStore)
        systemLogStore.updateWorkspaceRootURL(workspaceRootURL)
        await channelDelivery.updateStore(refreshedStore)
        await recoveryManager.updateStore(refreshedStore)
        await searchProviderService.updateConfig(config.searchTools)
        let oauthSvc = self.openAIOAuthService
        let anthropicOAuthSvc = self.anthropicOAuthService
        let workspaceRootURL = self.workspaceRootURL
        let anthropicSettingsProvider: @Sendable () -> ClaudeSettingsEnvironment = {
            ClaudeSettingsEnvironment.load(workspaceRootURL: workspaceRootURL)
        }
        let hasOAuth = oauthSvc.currentAccessToken() != nil
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(
            config: config,
            hasOAuthCredentials: hasOAuth
        )
        let modelProvider = CoreModelProviderFactory.buildModelProvider(
            config: config,
            resolvedModels: resolvedModels,
            tools: ToolRegistry.makeDefault().allTools,
            oauthTokenProvider: { oauthSvc.currentAccessToken() },
            oauthAccountId: oauthSvc.currentAccountId(),
            oauthTokenRefresh: { try await oauthSvc.ensureValidToken() },
            oauthTokenForceRefresh: { try await oauthSvc.ensureValidToken(forceRefresh: true) },
            anthropicOAuthTokenProvider: { anthropicOAuthSvc.currentAccessToken() },
            anthropicOAuthTokenRefresh: { try await anthropicOAuthSvc.ensureValidToken() },
            anthropicSettingsProvider: anthropicSettingsProvider,
            systemInstructions: "You are Sloppy core channel assistant.",
            proxySession: ProxySessionFactory.makeSession(proxy: config.proxy)
        )
        let defaultModel = modelProvider?.supportedModels.first ?? resolvedModels.first
        self.modelProvider = modelProvider
        await runtime.updateModelProvider(modelProvider: modelProvider, defaultModel: defaultModel)
        await sessionOrchestrator.updateAvailableModels(availableAgentModels())
        await sessionOrchestrator.updatePersistedModelContext(
            config: config,
            hasOAuthCredentials: hasOAuth
        )

        if previousChannels.telegram != config.channels.telegram {
            var plugin: (any GatewayPlugin)?
            if let telegramConfig = config.channels.telegram {
                let token = telegramConfig.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    plugin = builtInGatewayPluginFactory.makeTelegram(
                        telegramConfig,
                        self as any TelegramModelPickerBridge,
                        self as any ToolApprovalBridge
                    )
                }
            }
            let channelIds = config.channels.telegram.map { Array(Set($0.channelChatMap.keys).union($0.topicChannelMap.values)) } ?? []
            await reloadBuiltInPlugin(
                id: "telegram",
                type: "telegram",
                newPlugin: plugin,
                channelIds: channelIds,
                removedBecauseEmptyToken: config.channels.telegram?.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            )
        }

        if previousChannels.discord != config.channels.discord {
            var plugin: (any GatewayPlugin)?
            if let discordConfig = config.channels.discord {
                let token = discordConfig.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    plugin = builtInGatewayPluginFactory.makeDiscord(discordConfig)
                }
            }
            let channelIds = config.channels.discord.map { Array($0.channelDiscordChannelMap.keys) } ?? []
            await reloadBuiltInPlugin(
                id: "discord",
                type: "discord",
                newPlugin: plugin,
                channelIds: channelIds,
                removedBecauseEmptyToken: config.channels.discord?.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            )
        }

        if previousOnboardingCompleted != config.onboarding.completed {
            logger.info(
                "onboarding.config.updated",
                metadata: [
                    "completed": .stringConvertible(config.onboarding.completed),
                    "models_count": .stringConvertible(config.models.count),
                    "primary_model": .string(config.models.first?.model ?? "")
                ]
            )
        } else if !config.onboarding.completed {
            logger.info(
                "onboarding.config.saved_draft",
                metadata: [
                    "models_count": .stringConvertible(config.models.count),
                    "primary_model": .string(config.models.first?.model ?? "")
                ]
            )
        }

        return currentConfig
    }
    public func getConfig() -> CoreConfig {
        currentConfig
    }

    public func runWorkspaceGitSyncNow() async throws -> WorkspaceGitSyncResponse {
        try await workspaceGitSyncService.syncNow(
            config: currentConfig.gitSync,
            workspaceRootURL: workspaceRootURL
        )
    }

    /// Lists all persisted agents from workspace `/agents`.
}

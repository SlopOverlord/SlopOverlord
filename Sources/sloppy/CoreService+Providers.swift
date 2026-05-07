import Foundation
import AnyLanguageModel
import Protocols

// MARK: - Providers, OAuth, GitHub

extension CoreService {
    public func probeACPTarget(request: ACPTargetProbeRequest) async throws -> ACPTargetProbeResponse {
        try await acpSessionManager.probeTarget(request.target)
    }

    /// Returns OpenAI model catalog using API key auth or environment fallback.
    public func listOpenAIModels(request: OpenAIProviderModelsRequest) async -> OpenAIProviderModelsResponse {
        if request.authMethod == .deeplink {
            do {
                let models = try await openAIOAuthService.fetchModels()
                if !models.isEmpty {
                    cacheOAuthModels(models)
                }
                return OpenAIProviderModelsResponse(
                    provider: "openai",
                    authMethod: request.authMethod,
                    usedEnvironmentKey: false,
                    source: "remote",
                    warning: models.isEmpty ? "OpenAI OAuth returned no Codex models." : nil,
                    models: models
                )
            } catch {
                return OpenAIProviderModelsResponse(
                    provider: "openai",
                    authMethod: request.authMethod,
                    usedEnvironmentKey: false,
                    source: "fallback",
                    warning: error.localizedDescription,
                    models: []
                )
            }
        }

        return await openAIProviderCatalog.listModels(config: currentConfig, request: request)
    }

    /// Returns OpenAI provider key availability without fetching remote model catalog.
    public func openAIProviderStatus() -> OpenAIProviderStatusResponse {
        let apiStatus = openAIProviderCatalog.status(config: currentConfig)
        let oauthStatus = openAIOAuthService.status()
        return OpenAIProviderStatusResponse(
            provider: apiStatus.provider,
            hasEnvironmentKey: apiStatus.hasEnvironmentKey,
            hasConfiguredKey: apiStatus.hasConfiguredKey,
            hasAnyKey: apiStatus.hasAnyKey,
            hasOAuthCredentials: oauthStatus.hasCredentials,
            oauthAccountId: oauthStatus.accountId,
            oauthPlanType: oauthStatus.planType,
            oauthExpiresAt: oauthStatus.expiresAt
        )
    }

    public func anthropicProviderStatus() -> AnthropicProviderStatusResponse {
        let primaryConfig = currentConfig.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("anthropic:") == true
                && isAnthropicOAuthEntry($0)
        }
        let configuredKey = (primaryConfig?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let envOAuthKey = ProcessInfo.processInfo.environment["ANTHROPIC_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envClaudeCodeKey = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envAuthToken = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let settingsKey = anthropicOAuthService.claudeSettingsEnvironment().authToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let oauthStatus = anthropicOAuthService.status()
        let hasEnvironmentKey = !envOAuthKey.isEmpty || !envClaudeCodeKey.isEmpty || !envAuthToken.isEmpty || !settingsKey.isEmpty

        return AnthropicProviderStatusResponse(
            provider: "anthropic",
            hasEnvironmentKey: hasEnvironmentKey,
            hasConfiguredKey: !configuredKey.isEmpty,
            hasAnyKey: !configuredKey.isEmpty || hasEnvironmentKey,
            hasOAuthCredentials: oauthStatus.hasCredentials,
            oauthSource: oauthStatus.source,
            oauthExpiresAt: oauthStatus.expiresAt,
            oauthRefreshable: oauthStatus.refreshable
        )
    }

    /// Probes provider connectivity and returns remote model options on success.
    public func probeProvider(request: ProviderProbeRequest) async -> ProviderProbeResponse {
        if request.providerId == .openAIOAuth {
            let result = await openAIOAuthService.probe()
            if result.ok {
                cacheOAuthModels(result.models)
            }
            return result
        }
        if request.providerId == .anthropicOAuth {
            let primaryConfig = currentConfig.models.first {
                CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("anthropic:") == true
                    && isAnthropicOAuthEntry($0)
            }
            let baseURL = CoreModelProviderFactory.parseURL(request.apiUrl)
                ?? CoreModelProviderFactory.parseURL(primaryConfig?.apiUrl)
                ?? anthropicOAuthService.claudeSettingsEnvironment().baseURL
                ?? URL(string: "https://api.anthropic.com")
            guard let baseURL else {
                return ProviderProbeResponse(
                    providerId: .anthropicOAuth,
                    ok: false,
                    usedEnvironmentKey: false,
                    message: "Anthropic API URL is invalid.",
                    models: []
                )
            }
            return await anthropicOAuthService.probe(
                apiURL: baseURL,
                manualToken: request.apiKey
            )
        }
        return await providerProbeService.probe(config: currentConfig, request: request)
    }

    /// Generates text using the specified model and prompt, for one-shot completion tasks.
    public func generateText(request: GenerateTextRequest) async throws -> GenerateTextResponse {
        let config = currentConfig
        let oauthService = openAIOAuthService
        let anthropicOAuthService = self.anthropicOAuthService
        let workspaceRootURL = self.workspaceRootURL
        let hasOAuth = oauthService.currentAccessToken() != nil
        let resolvedModels = CoreModelProviderFactory.resolveModelIdentifiers(
            config: config,
            hasOAuthCredentials: hasOAuth
        )
        guard let modelProvider = CoreModelProviderFactory.buildModelProvider(
            config: config,
            resolvedModels: resolvedModels,
            oauthTokenProvider: { oauthService.currentAccessToken() },
            oauthAccountId: oauthService.currentAccountId(),
            oauthTokenRefresh: { try await oauthService.ensureValidToken() },
            oauthTokenForceRefresh: { try await oauthService.ensureValidToken(forceRefresh: true) },
            anthropicOAuthTokenProvider: { anthropicOAuthService.currentAccessToken() },
            anthropicOAuthTokenRefresh: { try await anthropicOAuthService.ensureValidToken() },
            anthropicSettingsProvider: { ClaudeSettingsEnvironment.load(workspaceRootURL: workspaceRootURL) },
            proxySession: ProxySessionFactory.makeSession(proxy: config.proxy)
        ) else {
            throw GenerateError.noModelProvider
        }

        let modelId = request.model.isEmpty ? (modelProvider.supportedModels.first ?? resolvedModels.first ?? "") : request.model
        guard !modelId.isEmpty else {
            throw GenerateError.noModelAvailable
        }

        let languageModel = try await modelProvider.createLanguageModel(for: modelId)
        let session = LanguageModelSession(model: languageModel, tools: [])
        let options = modelProvider.generationOptions(for: modelId, maxTokens: 4096, reasoningEffort: nil)
        let response = try await session.respond(to: request.prompt, options: options)
        return GenerateTextResponse(text: response.content, model: modelId)
    }

    public func startOpenAIOAuth(request: OpenAIOAuthStartRequest) throws -> OpenAIOAuthStartResponse {
        try openAIOAuthService.startLogin(redirectURI: request.redirectURI)
    }

    public func completeOpenAIOAuth(request: OpenAIOAuthCompleteRequest) async throws -> OpenAIOAuthCompleteResponse {
        try await openAIOAuthService.completeLogin(request: request)
    }

    public func importOpenAICodexCredentials() async throws -> OpenAIOAuthImportCodexResponse {
        try await openAIOAuthService.importCodexCredentials()
    }

    public func startOpenAIDeviceCode() async throws -> OpenAIDeviceCodeStartResponse {
        try await openAIOAuthService.startDeviceCode()
    }

    public func pollOpenAIDeviceCode(request: OpenAIDeviceCodePollRequest) async throws -> OpenAIDeviceCodePollResponse {
        try await openAIOAuthService.pollDeviceToken(deviceAuthId: request.deviceAuthId, userCode: request.userCode)
    }

    public func disconnectOpenAIOAuth() throws {
        try openAIOAuthService.disconnect()
        oauthModelCache.removeAll()
    }

    public func startAnthropicOAuth(request: AnthropicOAuthStartRequest) throws -> AnthropicOAuthStartResponse {
        try anthropicOAuthService.startLogin(redirectURI: request.redirectURI)
    }

    public func completeAnthropicOAuth(request: AnthropicOAuthCompleteRequest) async throws -> AnthropicOAuthCompleteResponse {
        try await anthropicOAuthService.completeLogin(request: request)
    }

    public func importAnthropicClaudeCredentials() async throws -> AnthropicOAuthImportClaudeResponse {
        try await anthropicOAuthService.importClaudeCodeCredentials()
    }

    public func disconnectAnthropicOAuth() throws {
        try anthropicOAuthService.disconnect()
    }

    public func gitHubAuthStatus() -> GitHubAuthStatusResponse {
        let status = githubAuthService.status()
        return GitHubAuthStatusResponse(
            connected: status.connected,
            username: status.username,
            connectedAt: status.connectedAt
        )
    }

    public func connectGitHub(request: GitHubConnectRequest) async throws -> GitHubConnectResponse {
        try await githubAuthService.connect(token: request.token)
    }

    public func disconnectGitHub() throws {
        try githubAuthService.disconnect()
    }

    /// Returns search provider key availability for configured web search providers.
    public func searchProviderStatus() async -> SearchToolsStatusResponse {
        await searchProviderService.status()
    }

    /// Returns latest persisted system logs from `/workspace/logs/*.log`.
    public func getUpdateStatus() async -> UpdateStatus {
        await updateChecker.status()
    }

    public func forceUpdateCheck() async -> UpdateStatus {
        await updateChecker.forceCheck()
    }

    public func getSystemLogs(limit: Int = 1500) throws -> SystemLogsResponse {
        do {
            return try systemLogStore.readRecentEntries(limit: limit)
        } catch {
            throw SystemLogsError.storageFailure
        }
    }

    /// Executes one tool call in session context and persists tool_call/tool_result events.
    func availableAgentModels() -> [ProviderModelOption] {
        let hasOAuth = openAIOAuthService.currentAccessToken() != nil
        let base = Self.availableAgentModels(config: currentConfig, hasOAuthCredentials: hasOAuth)
        guard hasOAuth, !oauthModelCache.isEmpty else { return base }

        var seen = Set<String>()
        var options: [ProviderModelOption] = base.map { option in
            seen.insert(option.id)
            guard let cached = oauthModelCache[option.id] ?? oauthModelCache[stripProviderPrefix(option.id)] else {
                return option
            }
            return ProviderModelOption(
                id: option.id,
                title: cached.title.isEmpty ? option.title : cached.title,
                contextWindow: cached.contextWindow ?? option.contextWindow,
                capabilities: cached.capabilities.isEmpty ? option.capabilities : cached.capabilities
            )
        }

        for cached in oauthModelCache.values.sorted(by: { $0.id < $1.id }) {
            let id = cached.id.hasPrefix("openai:") ? cached.id : "openai:\(cached.id)"
            guard seen.insert(id).inserted else { continue }
            options.append(
                ProviderModelOption(
                    id: id,
                    title: cached.title,
                    contextWindow: cached.contextWindow,
                    capabilities: cached.capabilities
                )
            )
        }

        return options
    }

    func stripProviderPrefix(_ id: String) -> String {
        guard let idx = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: idx)...])
    }

    func cacheOAuthModels(_ models: [ProviderModelOption]) {
        for model in models {
            oauthModelCache[model.id] = model
        }
    }

    func refreshOAuthModelCacheIfNeeded() async {
        guard openAIOAuthService.currentAccessToken() != nil else { return }
        do {
            let models = try await openAIOAuthService.fetchModels()
            cacheOAuthModels(models)
        } catch {
            logger.debug(
                "oauth_model_cache.refresh_failed",
                metadata: ["error": "\(error.localizedDescription)"]
            )
        }
    }

    private func isAnthropicOAuthEntry(_ model: CoreConfig.ModelConfig) -> Bool {
        let catalog = model.providerCatalogId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if catalog == "anthropic-oauth" {
            return true
        }
        return model.title.lowercased().contains("anthropic-oauth")
    }

    static func availableAgentModels(config: CoreConfig, hasOAuthCredentials: Bool = false) -> [ProviderModelOption] {
        var seen: Set<String> = []
        var options: [ProviderModelOption] = []

        let candidates = CoreModelProviderFactory.resolveModelIdentifiers(
            config: config,
            hasOAuthCredentials: hasOAuthCredentials
        ) + config.models.filter { !$0.disabled }.map(\.model)
        for raw in candidates {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }

            if seen.insert(value).inserted {
                options.append(Self.providerModelOption(for: value))
            }
        }

        if options.isEmpty {
            options.append(Self.providerModelOption(for: "openai:gpt-5.4-mini"))
        }

        return options
    }

    /// Resolves a dashboard- or CLI-entered model string to a canonical id present in `availableModels`.
    ///
    /// Accepts the full prefixed id (e.g. `openrouter:google/gemma-4-2-26b-a4b-it:free`) or the portion after the
    /// **first** colon in an allowed id when that suffix matches exactly one catalog entry. This allows OpenRouter
    /// slugs that contain additional colons (`:free`) to validate and save correctly.
    /// True when `modelID` is a non-empty `provider:slug` string and that provider is configured (same rules as model factories).
    nonisolated static func isRuntimeRoutableModelID(
        _ modelID: String,
        config: CoreConfig,
        hasOAuthCredentials: Bool
    ) -> Bool {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let prefix = String(trimmed[..<colon])
        let slug = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return false }

        let resolved = CoreModelProviderFactory.resolveModelIdentifiers(
            config: config,
            hasOAuthCredentials: hasOAuthCredentials
        )
        let knowsProvider = resolved.contains { $0.hasPrefix("\(prefix):") }

        switch prefix {
        case "openrouter":
            let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !env.isEmpty { return true }
            guard knowsProvider else { return false }
            return openRouterHasApiKey(config: config)
        case "openai":
            let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !env.isEmpty { return true }
            if hasOAuthCredentials, knowsProvider { return true }
            guard knowsProvider else { return false }
            return openAIHasApiKey(config: config)
        case "ollama":
            return knowsProvider
        case "gemini":
            guard knowsProvider else { return false }
            let env = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
                .compactMap { ProcessInfo.processInfo.environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            if !env.isEmpty { return true }
            return geminiHasApiKey(config: config)
                || GeminiOAuthCredentials.load()?.isUsableForGenerativeLanguageAPI == true
        case "anthropic":
            guard knowsProvider else { return false }
            let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !env.isEmpty { return true }
            let envAuthToken = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !envAuthToken.isEmpty { return true }
            let workspaceRootURL = config.resolvedWorkspaceRootURL(currentDirectory: FileManager.default.currentDirectoryPath)
            if ClaudeSettingsEnvironment.load(workspaceRootURL: workspaceRootURL).hasAuthToken { return true }
            return anthropicHasApiKey(config: config)
        default:
            return false
        }
    }

    nonisolated private static func openRouterHasApiKey(config: CoreConfig) -> Bool {
        let primary = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("openrouter:") == true
        }
        return !(primary?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func openAIHasApiKey(config: CoreConfig) -> Bool {
        let primary = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("openai:") == true
        }
        return !(primary?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func geminiHasApiKey(config: CoreConfig) -> Bool {
        let primary = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("gemini:") == true
        }
        return !(primary?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func anthropicHasApiKey(config: CoreConfig) -> Bool {
        let primary = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("anthropic:") == true
        }
        return !(primary?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func resolveCanonicalAgentModelID(_ raw: String, availableModels: [ProviderModelOption]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowedIDs = Set(availableModels.map(\.id))
        if allowedIDs.contains(trimmed) {
            return trimmed
        }
        var suffixMatches: [String] = []
        for option in availableModels {
            guard let colon = option.id.firstIndex(of: ":") else { continue }
            let suffix = String(option.id[option.id.index(after: colon)...])
            if suffix == trimmed {
                suffixMatches.append(option.id)
            }
        }
        if suffixMatches.count == 1 {
            return suffixMatches[0]
        }
        return nil
    }

    static func providerModelOption(for identifier: String) -> ProviderModelOption {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID: String
        if let separatorIndex = trimmed.firstIndex(of: ":") {
            modelID = String(trimmed[trimmed.index(after: separatorIndex)...])
        } else {
            modelID = trimmed
        }

        let lowered = modelID.lowercased()
        var capabilities: [String] = []
        var contextWindow: String?

        if lowered.hasPrefix("gpt-5.4") {
            capabilities.append("tools")
            contextWindow = "1.0M"
        } else if lowered.hasPrefix("gpt-4o") {
            capabilities.append("tools")
            contextWindow = "128K"
        } else if lowered.hasPrefix("o4") || lowered.hasPrefix("o3") {
            capabilities.append(contentsOf: ["reasoning", "tools"])
            contextWindow = "200K"
        } else if lowered.hasPrefix("o1") {
            capabilities.append(contentsOf: ["reasoning", "tools"])
            contextWindow = "128K"
        }

        return ProviderModelOption(
            id: trimmed,
            title: trimmed,
            contextWindow: contextWindow,
            capabilities: capabilities
        )
    }

}

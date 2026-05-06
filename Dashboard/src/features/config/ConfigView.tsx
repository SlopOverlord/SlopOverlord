import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  completeAnthropicOAuth,
  disconnectAnthropicOAuth,
  disconnectOpenAIOAuth,
  fetchAnthropicProviderStatus,
  fetchOpenAIModels,
  fetchOpenAIProviderStatus,
  fetchRuntimeConfig,
  fetchSearchProviderStatus,
  importAnthropicClaudeCredentials,
  importOpenAICodexCredentials,
  probeProvider,
  startAnthropicOAuth,
  startOpenAIDeviceCode,
  pollOpenAIDeviceCode,
  updateRuntimeConfig,
  fetchGitHubAuthStatus,
  connectGitHub,
  disconnectGitHub,
  runWorkspaceGitSync
} from "../../api";
import { collectAggregatedProviderModels, filterModelsByQuery } from "../agents/utils/aggregateProviderModels";
import { NodeHostEditor } from "./components/NodeHostEditor";
import { MCPEditor } from "./components/MCPEditor";
import { PluginEditor } from "./components/PluginEditor";
import { ProviderEditor } from "./components/ProviderEditor";
import { SearchToolsEditor } from "./components/SearchToolsEditor";
import { SettingsMainHeader } from "./components/SettingsMainHeader";
import { SettingsPlaceholder } from "./components/SettingsPlaceholder";
import { SettingsSidebar } from "./components/SettingsSidebar";
import { TelegramEditor } from "./components/TelegramEditor";
import { DiscordEditor } from "./components/DiscordEditor";
import { ApprovalsView } from "./components/ApprovalsView";
import { ConfigRawView } from "./components/ConfigRawView";
import { ProxyEditor } from "./components/ProxyEditor";
import { BrowserEditor } from "./components/BrowserEditor";
import { ACPEditor } from "./components/ACPEditor";
import { UIEditor } from "./components/UIEditor";
import { VisorEditor } from "./components/VisorEditor";
import { AggregatedModelPicker } from "./components/AggregatedModelPicker";
import { ClientConnectView } from "./components/ClientConnectView";
import { UpdatesView } from "../updates/UpdatesView";
import { useUpdateCheck } from "../updates/useUpdateCheck";

const SETTINGS_ITEMS = [
  { id: "providers", title: "Providers", icon: "hub" },
  { id: "search-tools", title: "Search Tools", icon: "travel_explore" },
  { id: "model-routing", title: "Model routing", icon: "linear_scale" },
  { id: "channels", title: "Channels", icon: "forum" },
  { id: "approvals", title: "Approvals", icon: "fact_check" },
  { id: "plugins", title: "Plugins", icon: "extension" },
  { id: "mcp", title: "MCP", icon: "account_tree" },
  { id: "browser", title: "Browser", icon: "open_in_browser" },
  { id: "ui", title: "UI", icon: "palette" },
  { id: "nodehost", title: "NodeHost", icon: "dns" },
  // { id: "bindings", title: "Bindings", icon: "cable" },
  // { id: "broadcast", title: "Broadcast", icon: "cell_tower" },
  // { id: "audio", title: "Audio", icon: "volume_up" },
  // { id: "media", title: "Media", icon: "perm_media" },
  // { id: "session", title: "Session", icon: "manage_accounts" },
  { id: "visor", title: "Visor", icon: "visibility" },
  { id: "acp", title: "ACP", icon: "smart_toy" },
  { id: "proxy", title: "Proxy", icon: "vpn_key" },
  { id: "git-sync", title: "Git Sync", icon: "sync" },
  { id: "connect-client", title: "Connect Client", icon: "qr_code" },
  { id: "config", title: "Config", icon: "edit_document" },
  { id: "updates", title: "Updates", icon: "system_update" },
  // { id: "logging", title: "Logging", icon: "description" }
];

const GIT_SYNC_FREQUENCIES = new Set(["manual", "daily", "weekdays"]);
const GIT_SYNC_CONFLICT_STRATEGIES = new Set(["remote_wins", "local_wins", "manual"]);

const PROVIDER_CATALOG = [
  {
    id: "openai-api",
    brandProviderKey: "openai",
    title: "OpenAI API",
    description: "OpenAI via API key authentication.",
    modelHint: "gpt-5.4-mini",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openai-api",
      apiKey: "",
      apiUrl: "https://api.openai.com/v1",
      model: "gpt-5.4-mini",
      disabled: false,
      providerCatalogId: "openai-api"
    }
  },
  {
    id: "openai-oauth",
    brandProviderKey: "openai",
    title: "OpenAI Codex",
    description: "ChatGPT/Codex login via OpenAI OAuth.",
    modelHint: "gpt-5.3-codex",
    authMethod: "deeplink",
    requiresApiKey: false,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openai-oauth",
      apiKey: "",
      apiUrl: "https://chatgpt.com/backend-api",
      model: "gpt-5.3-codex",
      disabled: false,
      providerCatalogId: "openai-oauth"
    }
  },
  {
    id: "openrouter",
    brandProviderKey: null,
    title: "OpenRouter",
    description: "Unified API for many models (OpenAI-compatible Chat Completions).",
    modelHint: "openai/gpt-4o-mini",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openrouter",
      apiKey: "",
      apiUrl: "https://openrouter.ai/api/v1",
      model: "openai/gpt-4o-mini",
      disabled: false,
      providerCatalogId: "openrouter"
    }
  },
  {
    id: "anthropic",
    brandProviderKey: "anthropic",
    title: "Anthropic",
    description: "Claude models via Anthropic API key.",
    modelHint: "claude-sonnet-4-6",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "anthropic",
      apiKey: "",
      apiUrl: "https://api.anthropic.com",
      model: "claude-sonnet-4-6",
      disabled: false,
      providerCatalogId: "anthropic"
    }
  },
  {
    id: "anthropic-oauth",
    brandProviderKey: "anthropic",
    title: "Anthropic",
    description: "Claude via Anthropic OAuth, Claude Code credentials, or API token.",
    modelHint: "claude-sonnet-4-6",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "anthropic-oauth",
      apiKey: "",
      apiUrl: "https://api.anthropic.com",
      model: "claude-sonnet-4-6",
      disabled: false,
      providerCatalogId: "anthropic-oauth"
    }
  },
  {
    id: "gemini",
    brandProviderKey: "gemini",
    title: "Google Gemini",
    description: "Google Gemini models via API key.",
    modelHint: "gemini-2.5-flash",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: false,
    defaultEntry: {
      title: "gemini",
      apiKey: "",
      apiUrl: "https://generativelanguage.googleapis.com",
      model: "gemini-2.5-flash",
      disabled: false,
      providerCatalogId: "gemini"
    }
  },
  {
    id: "ollama",
    brandProviderKey: "ollama",
    title: "Ollama",
    description: "Local provider using Ollama’s HTTP API (/api/tags). LM Studio and similar tools speak OpenAI-compatible /v1 — use OpenAI API with base URL http://host:port/v1 instead.",
    modelHint: "qwen3",
    authMethod: "none",
    requiresApiKey: false,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "ollama-local",
      apiKey: "",
      apiUrl: "http://127.0.0.1:11434",
      model: "qwen3",
      disabled: false,
      providerCatalogId: "ollama"
    }
  }
];

/** UI presets only: hide Anthropic Console API key; OAuth preset remains. Full `PROVIDER_CATALOG` is still used for metadata and existing `anthropic` rows. */
const PROVIDER_CATALOG_UI = PROVIDER_CATALOG.filter((p) => p.id !== "anthropic");

function emptyModel() {
  return {
    title: "openai-api",
    apiKey: "",
    apiUrl: "https://api.openai.com/v1",
    model: "gpt-5.4-mini",
    disabled: false,
    providerCatalogId: "openai-api"
  };
}

function emptyPlugin() {
  return {
    title: "new-plugin",
    apiKey: "",
    apiUrl: "",
    plugin: ""
  };
}

function emptyMCPServer() {
  return {
    id: "new-mcp-server",
    transport: "stdio",
    command: "npx",
    arguments: [],
    cwd: "",
    endpoint: "",
    headers: {},
    timeoutMs: 15000,
    enabled: true,
    exposeTools: true,
    exposeResources: true,
    exposePrompts: true,
    toolPrefix: ""
  };
}

const EMPTY_CONFIG = {
  listen: { host: "0.0.0.0", port: 25101 },
  workspace: { name: ".sloppy", basePath: "~" },
  auth: { token: "dev-token" },
  onboarding: { completed: false },
  models: [emptyModel()],
  memory: {
    backend: "sqlite-local-vectors",
    provider: {
      mode: "local",
      endpoint: "",
      mcpServer: "",
      mcpTools: {
        upsert: "memory_upsert",
        query: "memory_query",
        delete: "memory_delete",
        health: "memory_health"
      },
      timeoutMs: 2500,
      apiKeyEnv: ""
    },
    retrieval: {
      topK: 8,
      semanticWeight: 0.55,
      keywordWeight: 0.35,
      graphWeight: 0.1
    },
    retention: {
      episodicDays: 90,
      todoCompletedDays: 30,
      bulletinDays: 180
    },
    embedding: {
      enabled: false,
      model: "text-embedding-3-small",
      dimensions: 1536,
      endpoint: "",
      apiKeyEnv: ""
    }
  },
  nodes: ["local"],
  gateways: [],
  mcp: {
    servers: []
  },
  plugins: [],
  channels: { telegram: null, discord: null, channelInactivityDays: 2 },
  searchTools: {
    activeProvider: "perplexity",
    providers: {
      brave: {
        apiKey: ""
      },
      perplexity: {
        apiKey: ""
      }
    }
  },
  gitSync: {
    enabled: false,
    authToken: "",
    repository: "",
    branch: "main",
    schedule: {
      frequency: "daily",
      time: "18:00"
    },
    conflictStrategy: "remote_wins"
  },
  acp: {
    enabled: false,
    targets: []
  },
  proxy: {
    enabled: false,
    type: "socks5",
    host: "",
    port: 1080,
    username: "",
    password: ""
  },
  browser: {
    enabled: false,
    executablePath: "",
    cdpEndpoint: "",
    profileName: "default",
    profilePath: "",
    headless: false,
    startupTimeoutMs: 10000,
    additionalArguments: []
  },
  visor: {
    scheduler: {
      enabled: true,
      intervalSeconds: 300,
      jitterSeconds: 60
    },
    bootstrapBulletin: true,
    model: null,
    bulletinMaxWords: 300,
    tickIntervalSeconds: 30,
    workerTimeoutSeconds: 600,
    branchTimeoutSeconds: 60,
    maintenanceIntervalSeconds: 3600,
    decayRatePerDay: 0.05,
    pruneImportanceThreshold: 0.1,
    pruneMinAgeDays: 30,
    channelDegradedFailureCount: 3,
    channelDegradedWindowSeconds: 600,
    idleThresholdSeconds: 1800,
    webhookURLs: [],
    mergeEnabled: false,
    mergeSimilarityThreshold: 0.80,
    mergeMaxPerRun: 10
  },
  ui: {
    dashboardAuth: {
      enabled: false,
      token: ""
    },
    dashboardTerminal: {
      enabled: false,
      localOnly: true
    }
  },
  toolHooks: {
    preTools: {
      enabled: false,
      command: "",
      arguments: [],
      timeoutMs: 2000,
      maxOutputBytes: 65536,
      failurePolicy: "block"
    }
  },
  modelRouting: {},
  sqlitePath: "core.sqlite"
};

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function normalizeModel(item, index) {
  if (typeof item === "string") {
    const [provider, name] = item.includes(":") ? item.split(":", 2) : ["", item];
    const apiUrlMap = {
      openai: "https://api.openai.com/v1",
      openrouter: "https://openrouter.ai/api/v1",
      ollama: "http://127.0.0.1:11434",
      gemini: "https://generativelanguage.googleapis.com",
      anthropic: "https://api.anthropic.com"
    };
    return {
      title: provider ? `${provider}-${name}` : name || `model-${index + 1}`,
      apiKey: "",
      apiUrl: apiUrlMap[provider] || "",
      model: name || item,
      disabled: false,
      providerCatalogId: null
    };
  }

  const catalogRaw = item?.providerCatalogId;
  const providerCatalogId =
    typeof catalogRaw === "string" && catalogRaw.trim() ? catalogRaw.trim() : null;

  return {
    title: item?.title || `model-${index + 1}`,
    apiKey: item?.apiKey || "",
    apiUrl: item?.apiUrl || "",
    model: item?.model || "",
    disabled: Boolean(item?.disabled),
    providerCatalogId
  };
}

function inferModelProvider(model) {
  const apiUrl = String(model?.apiUrl || "").toLowerCase();
  const title = String(model?.title || "").toLowerCase();
  const modelName = String(model?.model || "").toLowerCase();

  if (
    apiUrl.includes("openai") ||
    title.includes("openai") ||
    modelName.startsWith("gpt-") ||
    /^o\d/.test(modelName)
  ) {
    return "openai";
  }

  if (apiUrl.includes("openrouter") || title.includes("openrouter")) {
    return "openrouter";
  }

  if (/:1234(\/|$)/i.test(apiUrl)) {
    return "openai";
  }

  if (apiUrl.includes("ollama") || apiUrl.includes("11434") || title.includes("ollama")) {
    return "ollama";
  }

  if (apiUrl.includes("generativelanguage.googleapis.com") || title.includes("gemini") || modelName.startsWith("gemini")) {
    return "gemini";
  }

  if (apiUrl.includes("anthropic") || title.includes("anthropic") || modelName.startsWith("claude")) {
    return "anthropic";
  }

  return "custom";
}

function inferCatalogIdForEntry(entry) {
  const raw = entry?.providerCatalogId;
  if (typeof raw === "string" && raw.trim()) {
    const id = raw.trim();
    if (PROVIDER_CATALOG.some((p) => p.id === id)) {
      return id;
    }
  }
  const p = inferModelProvider(entry);
  if (p === "openai") {
    return isOpenAIOAuthEntry(entry) ? "openai-oauth" : "openai-api";
  }
  if (p === "anthropic") {
    return isAnthropicOAuthCatalogEntry(entry) ? "anthropic-oauth" : "anthropic";
  }
  const map = {
    openrouter: "openrouter",
    ollama: "ollama",
    gemini: "gemini"
  };
  return map[p] || null;
}

function isOpenAIOAuthEntry(model) {
  const title = String(model?.title || "").toLowerCase();
  return title.includes("oauth") || title.includes("deeplink");
}

function isAnthropicOAuthCatalogEntry(entry) {
  const id = String(entry?.providerCatalogId || "").trim();
  if (id === "anthropic-oauth") {
    return true;
  }
  const title = String(entry?.title || "").toLowerCase();
  return title.includes("anthropic-oauth");
}

function findProviderModelIndex(models, providerId) {
  const direct = models.findIndex((m) => m.providerCatalogId === providerId);
  if (direct >= 0) {
    return direct;
  }
  return models.findIndex((item) => {
    if (item.providerCatalogId) {
      return false;
    }
    if (providerId === "openai-api") {
      return inferModelProvider(item) === "openai" && !isOpenAIOAuthEntry(item);
    }
    if (providerId === "openai-oauth") {
      return inferModelProvider(item) === "openai" && isOpenAIOAuthEntry(item);
    }
    if (providerId === "ollama") {
      return inferModelProvider(item) === "ollama";
    }
    if (providerId === "gemini") {
      return inferModelProvider(item) === "gemini";
    }
    if (providerId === "anthropic") {
      return inferModelProvider(item) === "anthropic" && !isAnthropicOAuthCatalogEntry(item);
    }
    if (providerId === "anthropic-oauth") {
      return inferModelProvider(item) === "anthropic" && isAnthropicOAuthCatalogEntry(item);
    }
    if (providerId === "openrouter") {
      return inferModelProvider(item) === "openrouter";
    }
    return false;
  });
}

function getProviderDefinition(providerId) {
  return PROVIDER_CATALOG.find((provider) => provider.id === providerId) || PROVIDER_CATALOG[0];
}

function getProviderEntry(models, providerId) {
  const index = findProviderModelIndex(models, providerId);
  if (index < 0) {
    return null;
  }
  return { index, entry: models[index] };
}

function providerIsConfigured(provider, entry) {
  if (!entry) {
    return false;
  }
  const hasModel = Boolean(String(entry.model || "").trim());
  const hasURL = Boolean(String(entry.apiUrl || "").trim());
  if (provider.id === "anthropic") {
    return hasModel && Boolean(String(entry.apiKey || "").trim());
  }
  if (provider.requiresApiKey) {
    return hasModel && hasURL && Boolean(String(entry.apiKey || "").trim());
  }
  return hasModel && hasURL;
}

function normalizePlugin(item, index) {
  if (typeof item === "string") {
    return {
      title: item || `plugin-${index + 1}`,
      apiKey: "",
      apiUrl: "",
      plugin: item || ""
    };
  }

  return {
    title: item?.title || `plugin-${index + 1}`,
    apiKey: item?.apiKey || "",
    apiUrl: item?.apiUrl || "",
    plugin: item?.plugin || ""
  };
}

function normalizeMCPServer(item, index) {
  const base = emptyMCPServer();
  const transport = String(item?.transport || base.transport).trim().toLowerCase();
  const headers = item?.headers && typeof item.headers === "object" && !Array.isArray(item.headers)
    ? Object.fromEntries(
      Object.entries(item.headers).map(([key, value]) => [String(key), String(value)])
    )
    : {};

  return {
    ...base,
    id: String(item?.id || `mcp-server-${index + 1}`),
    transport: transport === "http" ? "http" : "stdio",
    command: String(item?.command || ""),
    arguments: Array.isArray(item?.arguments) ? item.arguments.map((arg) => String(arg)) : [],
    cwd: String(item?.cwd || ""),
    endpoint: String(item?.endpoint || ""),
    headers,
    timeoutMs: parseInteger(item?.timeoutMs ?? base.timeoutMs, base.timeoutMs),
    enabled: item?.enabled == null ? true : Boolean(item.enabled),
    exposeTools: item?.exposeTools == null ? true : Boolean(item.exposeTools),
    exposeResources: item?.exposeResources == null ? true : Boolean(item.exposeResources),
    exposePrompts: item?.exposePrompts == null ? true : Boolean(item.exposePrompts),
    toolPrefix: String(item?.toolPrefix || "")
  };
}

function normalizeConfig(config) {
  const normalized = clone(EMPTY_CONFIG);

  normalized.listen.host = config?.listen?.host || normalized.listen.host;
  normalized.listen.port = parseInteger(config?.listen?.port ?? normalized.listen.port, normalized.listen.port);
  normalized.workspace.name = config?.workspace?.name || normalized.workspace.name;
  normalized.workspace.basePath = config?.workspace?.basePath || normalized.workspace.basePath;
  normalized.auth.token = config?.auth?.token || normalized.auth.token;
  normalized.onboarding.completed = Boolean(config?.onboarding?.completed);
  normalized.memory.backend = config?.memory?.backend || normalized.memory.backend;
  normalized.memory.provider.mode = String(config?.memory?.provider?.mode || normalized.memory.provider.mode);
  normalized.memory.provider.endpoint = String(config?.memory?.provider?.endpoint || "");
  normalized.memory.provider.mcpServer = String(config?.memory?.provider?.mcpServer || "");
  normalized.memory.provider.mcpTools.upsert = String(config?.memory?.provider?.mcpTools?.upsert || normalized.memory.provider.mcpTools.upsert);
  normalized.memory.provider.mcpTools.query = String(config?.memory?.provider?.mcpTools?.query || normalized.memory.provider.mcpTools.query);
  normalized.memory.provider.mcpTools.delete = String(config?.memory?.provider?.mcpTools?.delete || normalized.memory.provider.mcpTools.delete);
  normalized.memory.provider.mcpTools.health = String(config?.memory?.provider?.mcpTools?.health || normalized.memory.provider.mcpTools.health);
  normalized.memory.provider.timeoutMs = parseInteger(
    config?.memory?.provider?.timeoutMs ?? normalized.memory.provider.timeoutMs,
    normalized.memory.provider.timeoutMs
  );
  normalized.memory.provider.apiKeyEnv = String(config?.memory?.provider?.apiKeyEnv || "");

  normalized.memory.retrieval.topK = parseInteger(
    config?.memory?.retrieval?.topK ?? normalized.memory.retrieval.topK,
    normalized.memory.retrieval.topK
  );
  normalized.memory.retrieval.semanticWeight = parseNumber(
    config?.memory?.retrieval?.semanticWeight ?? normalized.memory.retrieval.semanticWeight,
    normalized.memory.retrieval.semanticWeight
  );
  normalized.memory.retrieval.keywordWeight = parseNumber(
    config?.memory?.retrieval?.keywordWeight ?? normalized.memory.retrieval.keywordWeight,
    normalized.memory.retrieval.keywordWeight
  );
  normalized.memory.retrieval.graphWeight = parseNumber(
    config?.memory?.retrieval?.graphWeight ?? normalized.memory.retrieval.graphWeight,
    normalized.memory.retrieval.graphWeight
  );

  normalized.memory.retention.episodicDays = parseInteger(
    config?.memory?.retention?.episodicDays ?? normalized.memory.retention.episodicDays,
    normalized.memory.retention.episodicDays
  );
  normalized.memory.retention.todoCompletedDays = parseInteger(
    config?.memory?.retention?.todoCompletedDays ?? normalized.memory.retention.todoCompletedDays,
    normalized.memory.retention.todoCompletedDays
  );
  normalized.memory.retention.bulletinDays = parseInteger(
    config?.memory?.retention?.bulletinDays ?? normalized.memory.retention.bulletinDays,
    normalized.memory.retention.bulletinDays
  );
  normalized.memory.embedding.enabled = Boolean(config?.memory?.embedding?.enabled);
  normalized.memory.embedding.model = String(config?.memory?.embedding?.model || normalized.memory.embedding.model);
  normalized.memory.embedding.dimensions = parseInteger(
    config?.memory?.embedding?.dimensions ?? normalized.memory.embedding.dimensions,
    normalized.memory.embedding.dimensions
  );
  normalized.memory.embedding.endpoint = String(config?.memory?.embedding?.endpoint || "");
  normalized.memory.embedding.apiKeyEnv = String(config?.memory?.embedding?.apiKeyEnv || "");
  normalized.sqlitePath = config?.sqlitePath || normalized.sqlitePath;
  normalized.ui.dashboardAuth.enabled = Boolean(config?.ui?.dashboardAuth?.enabled);
  normalized.ui.dashboardAuth.token = String(config?.ui?.dashboardAuth?.token || "");
  normalized.ui.dashboardTerminal.enabled = Boolean(config?.ui?.dashboardTerminal?.enabled);
  normalized.ui.dashboardTerminal.localOnly =
    config?.ui?.dashboardTerminal?.localOnly == null ? true : Boolean(config?.ui?.dashboardTerminal?.localOnly);
  normalized.toolHooks.preTools.enabled = Boolean(config?.toolHooks?.preTools?.enabled);
  normalized.toolHooks.preTools.command = String(config?.toolHooks?.preTools?.command || "");
  normalized.toolHooks.preTools.arguments = Array.isArray(config?.toolHooks?.preTools?.arguments)
    ? config.toolHooks.preTools.arguments.map((item) => String(item || ""))
    : [];
  normalized.toolHooks.preTools.timeoutMs = parseInteger(
    config?.toolHooks?.preTools?.timeoutMs ?? normalized.toolHooks.preTools.timeoutMs,
    normalized.toolHooks.preTools.timeoutMs
  );
  normalized.toolHooks.preTools.maxOutputBytes = parseInteger(
    config?.toolHooks?.preTools?.maxOutputBytes ?? normalized.toolHooks.preTools.maxOutputBytes,
    normalized.toolHooks.preTools.maxOutputBytes
  );
  normalized.toolHooks.preTools.failurePolicy =
    String(config?.toolHooks?.preTools?.failurePolicy || "block") === "allow" ? "allow" : "block";

  const mr = config?.modelRouting;
  normalized.modelRouting = {};
  if (mr && typeof mr === "object" && !Array.isArray(mr)) {
    for (const [k, v] of Object.entries(mr)) {
      const key = String(k).trim();
      const val = String(v ?? "").trim();
      if (key && val) {
        normalized.modelRouting[key] = val;
      }
    }
  }

  normalized.gitSync.enabled = Boolean(config?.gitSync?.enabled);
  normalized.gitSync.authToken = String(config?.gitSync?.authToken || "");
  normalized.gitSync.repository = String(config?.gitSync?.repository || "");
  normalized.gitSync.branch = String(config?.gitSync?.branch || normalized.gitSync.branch);
  normalized.gitSync.schedule.frequency = normalizeGitSyncFrequency(
    config?.gitSync?.schedule?.frequency,
    normalized.gitSync.schedule.frequency
  );
  normalized.gitSync.schedule.time = normalizeTimeValue(
    config?.gitSync?.schedule?.time,
    normalized.gitSync.schedule.time
  );
  normalized.gitSync.conflictStrategy = normalizeGitSyncConflictStrategy(
    config?.gitSync?.conflictStrategy,
    normalized.gitSync.conflictStrategy
  );

  normalized.nodes = Array.isArray(config?.nodes) ? config.nodes.filter(Boolean) : [];
  normalized.gateways = Array.isArray(config?.gateways) ? config.gateways.filter(Boolean) : [];
  normalized.mcp.servers = Array.isArray(config?.mcp?.servers)
    ? config.mcp.servers.map((server, index) => normalizeMCPServer(server, index))
    : [];

  const models = Array.isArray(config?.models) ? config.models : [];
  normalized.models = models.map(normalizeModel);
  if (normalized.models.length === 0) {
    normalized.models.push(clone(PROVIDER_CATALOG[0].defaultEntry));
  }

  const plugins = Array.isArray(config?.plugins) ? config.plugins : [];
  normalized.plugins = plugins.map(normalizePlugin);

  const tg = config?.channels?.telegram;
  const dc = config?.channels?.discord;

  normalized.channels = {
    telegram: tg && typeof tg === "object"
      ? {
        botToken: String(tg.botToken || ""),
        channelChatMap: tg.channelChatMap && typeof tg.channelChatMap === "object" ? tg.channelChatMap : {},
        topicChannelMap: tg.topicChannelMap && typeof tg.topicChannelMap === "object" ? tg.topicChannelMap : {},
        allowedUserIds: Array.isArray(tg.allowedUserIds) ? tg.allowedUserIds : [],
        allowedChatIds: Array.isArray(tg.allowedChatIds) ? tg.allowedChatIds : []
      }
      : null,
    discord: dc && typeof dc === "object"
      ? {
        botToken: String(dc.botToken || ""),
        guildId: String(dc.guildId || ""),
        channelAgentMap: dc.channelAgentMap && typeof dc.channelAgentMap === "object" ? dc.channelAgentMap : {}
      }
      : null,
    channelInactivityDays: parseInteger(config?.channels?.channelInactivityDays ?? 2, 2)
  };

  normalized.searchTools.activeProvider =
    String(config?.searchTools?.activeProvider || normalized.searchTools.activeProvider).trim().toLowerCase() === "brave"
      ? "brave"
      : "perplexity";
  normalized.searchTools.providers.brave.apiKey = String(config?.searchTools?.providers?.brave?.apiKey || "");
  normalized.searchTools.providers.perplexity.apiKey = String(config?.searchTools?.providers?.perplexity?.apiKey || "");

  normalized.acp.enabled = Boolean(config?.acp?.enabled);
  normalized.acp.targets = Array.isArray(config?.acp?.targets) ? config.acp.targets : [];

  normalized.proxy.enabled = Boolean(config?.proxy?.enabled);
  normalized.proxy.type = normalizeProxyType(config?.proxy?.type);
  normalized.proxy.host = String(config?.proxy?.host || "");
  normalized.proxy.port = parseInteger(config?.proxy?.port ?? 1080, 1080);
  normalized.proxy.username = String(config?.proxy?.username || "");
  normalized.proxy.password = String(config?.proxy?.password || "");

  normalized.browser.enabled = Boolean(config?.browser?.enabled);
  normalized.browser.executablePath = String(config?.browser?.executablePath || "");
  normalized.browser.cdpEndpoint = String(config?.browser?.cdpEndpoint || "");
  normalized.browser.profileName = String(config?.browser?.profileName || "default").trim() || "default";
  normalized.browser.profilePath = String(config?.browser?.profilePath || "");
  normalized.browser.headless = Boolean(config?.browser?.headless);
  normalized.browser.startupTimeoutMs = parseInteger(config?.browser?.startupTimeoutMs ?? 10000, 10000);
  normalized.browser.additionalArguments = Array.isArray(config?.browser?.additionalArguments)
    ? config.browser.additionalArguments.map((arg) => String(arg)).filter(Boolean)
    : [];

  const vc = config?.visor;
  normalized.visor.scheduler.enabled = vc?.scheduler?.enabled !== false;
  normalized.visor.scheduler.intervalSeconds = parseInteger(vc?.scheduler?.intervalSeconds ?? 300, 300);
  normalized.visor.scheduler.jitterSeconds = parseInteger(vc?.scheduler?.jitterSeconds ?? 60, 60);
  normalized.visor.bootstrapBulletin = vc?.bootstrapBulletin !== false;
  normalized.visor.model = vc?.model ? String(vc.model) : null;
  normalized.visor.bulletinMaxWords = parseInteger(vc?.bulletinMaxWords ?? 300, 300);
  normalized.visor.tickIntervalSeconds = parseInteger(vc?.tickIntervalSeconds ?? 30, 30);
  normalized.visor.workerTimeoutSeconds = parseInteger(vc?.workerTimeoutSeconds ?? 600, 600);
  normalized.visor.branchTimeoutSeconds = parseInteger(vc?.branchTimeoutSeconds ?? 60, 60);
  normalized.visor.maintenanceIntervalSeconds = parseInteger(vc?.maintenanceIntervalSeconds ?? 3600, 3600);
  normalized.visor.decayRatePerDay = parseNumber(vc?.decayRatePerDay ?? 0.05, 0.05);
  normalized.visor.pruneImportanceThreshold = parseNumber(vc?.pruneImportanceThreshold ?? 0.1, 0.1);
  normalized.visor.pruneMinAgeDays = parseInteger(vc?.pruneMinAgeDays ?? 30, 30);
  normalized.visor.channelDegradedFailureCount = parseInteger(vc?.channelDegradedFailureCount ?? 3, 3);
  normalized.visor.channelDegradedWindowSeconds = parseInteger(vc?.channelDegradedWindowSeconds ?? 600, 600);
  normalized.visor.idleThresholdSeconds = parseInteger(vc?.idleThresholdSeconds ?? 1800, 1800);
  normalized.visor.webhookURLs = Array.isArray(vc?.webhookURLs) ? vc.webhookURLs.filter(Boolean) : [];
  normalized.visor.mergeEnabled = Boolean(vc?.mergeEnabled);
  normalized.visor.mergeSimilarityThreshold = parseNumber(vc?.mergeSimilarityThreshold ?? 0.80, 0.80);
  normalized.visor.mergeMaxPerRun = parseInteger(vc?.mergeMaxPerRun ?? 10, 10);

  return normalized;
}

/** JSON.stringify ignores key order; server round-trips and UI mutations can reorder keys while staying semantically equal. */
function stableConfigStringify(value) {
  if (value === null || typeof value !== "object") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableConfigStringify(item)).join(",")}]`;
  }
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableConfigStringify(value[k])}`).join(",")}}`;
}

function parseLines(value) {
  return value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

function parseInteger(value, fallback) {
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseNumber(value, fallback) {
  const parsed = Number.parseFloat(String(value));
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeGitSyncFrequency(value, fallback = "daily") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  return GIT_SYNC_FREQUENCIES.has(normalized) ? normalized : fallback;
}

function normalizeGitSyncConflictStrategy(value, fallback = "remote_wins") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  return GIT_SYNC_CONFLICT_STRATEGIES.has(normalized) ? normalized : fallback;
}

function normalizeTimeValue(value, fallback = "18:00") {
  const normalized = String(value || "").trim();
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(normalized) ? normalized : fallback;
}

const PROXY_TYPES = new Set(["socks5", "http", "https"]);

function normalizeProxyType(value, fallback = "socks5") {
  const normalized = String(value || "").trim().toLowerCase();
  return PROXY_TYPES.has(normalized) ? normalized : fallback;
}

function isSettingsSection(id) {
  return SETTINGS_ITEMS.some((item) => item.id === id);
}

const DRAFT_CONFIG_KEY = "sloppy_draft_config";

export function ConfigView({
  sectionId = "providers",
  onSectionChange = null,
  onRuntimeConfigUpdated = null
}: {
  sectionId?: string;
  onSectionChange?: ((nextSectionId: string) => void) | null;
  onRuntimeConfigUpdated?: ((nextConfig: Record<string, unknown>) => void) | null;
}) {
  const initialSectionId = isSettingsSection(sectionId) ? sectionId : "providers";
  const [query, setQuery] = useState("");
  const [selectedSettings, setSelectedSettings] = useState(initialSectionId);
  const { status: updateStatus, isChecking: isUpdateChecking, forceCheck: forceUpdateCheck } = useUpdateCheck();
  const [draftConfig, setDraftConfig] = useState(clone(EMPTY_CONFIG));
  const [savedConfig, setSavedConfig] = useState(clone(EMPTY_CONFIG));
  const [rawConfig, setRawConfig] = useState(JSON.stringify(EMPTY_CONFIG, null, 2));
  const [statusText, setStatusText] = useState("Loading config...");
  const [selectedPluginIndex, setSelectedPluginIndex] = useState(0);
  const [selectedMCPServerIndex, setSelectedMCPServerIndex] = useState(0);
  const [providerModalId, setProviderModalId] = useState(null);
  const [providerModalIndex, setProviderModalIndex] = useState(null);
  const [providerForm, setProviderForm] = useState(null);
  const [configDeviceCode, setConfigDeviceCode] = useState(null);
  const [configDeviceCodePolling, setConfigDeviceCodePolling] = useState(false);
  const [configDeviceCodeCopied, setConfigDeviceCodeCopied] = useState(false);
  const configDeviceCodePollingRef = useRef(false);
  const [pendingOAuthDisconnect, setPendingOAuthDisconnect] = useState(false);
  const [pendingAnthropicOAuthDisconnect, setPendingAnthropicOAuthDisconnect] = useState(false);
  const [providerModelOptions, setProviderModelOptions] = useState({});
  const [providerModelStatus, setProviderModelStatus] = useState({});
  const [providerProbeTesting, setProviderProbeTesting] = useState({});
  const [providerModelMenuOpen, setProviderModelMenuOpen] = useState(false);
  const [providerModelMenuRect, setProviderModelMenuRect] = useState(null);
  const [openAIProviderStatus, setOpenAIProviderStatus] = useState({
    hasEnvironmentKey: false,
    hasConfiguredKey: false,
    hasAnyKey: false,
    hasOAuthCredentials: false,
    oauthAccountId: "",
    oauthPlanType: "",
    oauthExpiresAt: ""
  });
  const [anthropicProviderStatus, setAnthropicProviderStatus] = useState({
    hasEnvironmentKey: false,
    hasConfiguredKey: false,
    hasAnyKey: false,
    hasOAuthCredentials: false,
    oauthSource: "",
    oauthExpiresAt: "",
    oauthRefreshable: false
  });
  const [gitHubAuthStatus, setGitHubAuthStatus] = useState({ connected: false, username: null, connectedAt: null });
  const [gitHubToken, setGitHubToken] = useState("");
  const [gitHubStatusText, setGitHubStatusText] = useState("");
  const [gitHubConnecting, setGitHubConnecting] = useState(false);
  const [gitSyncRunning, setGitSyncRunning] = useState(false);
  const [gitSyncStatusText, setGitSyncStatusText] = useState("");
  const [modelRoutingCatalog, setModelRoutingCatalog] = useState([]);
  const [modelRoutingCatalogStatus, setModelRoutingCatalogStatus] = useState("");

  const [searchProviderStatus, setSearchProviderStatus] = useState({
    activeProvider: "perplexity",
    brave: { hasEnvironmentKey: false, hasConfiguredKey: false, hasAnyKey: false },
    perplexity: { hasEnvironmentKey: false, hasConfiguredKey: false, hasAnyKey: false }
  });
  const providerModelLoadTimerRef = useRef(null);
  const providerModelLoadTokenRef = useRef(0);
  const providerAutoSaveTimerRef = useRef(null);
  const providerAutoSaveTokenRef = useRef(0);
  const providerModelPickerRef = useRef(null);
  const providerModelMenuRef = useRef(null);
  const anthropicOAuthPopupRef = useRef(null);
  const [anthropicOAuthAuthorizationURL, setAnthropicOAuthAuthorizationURL] = useState("");

  useEffect(() => {
    loadConfig().catch(() => {
      setStatusText("Failed to load config");
    });
  }, []);

  const providerModelsProbeKey = useMemo(
    () => JSON.stringify(draftConfig?.models ?? []),
    [draftConfig.models]
  );

  useEffect(() => {
    if (selectedSettings !== "model-routing") {
      return;
    }
    let cancelled = false;
    (async () => {
      setModelRoutingCatalogStatus("Loading model catalog...");
      try {
        const catalog = await collectAggregatedProviderModels(draftConfig);
        if (cancelled) {
          return;
        }
        setModelRoutingCatalog(catalog.models);
        if (catalog.models.length === 0) {
          const hasModelEntries = Array.isArray(draftConfig.models) && draftConfig.models.length > 0;
          setModelRoutingCatalogStatus(
            hasModelEntries
              ? "No models returned from providers. Check API keys and probe status under Providers."
              : "Add at least one provider under Providers to list models."
          );
        } else {
          setModelRoutingCatalogStatus("");
        }
      } catch {
        if (!cancelled) {
          setModelRoutingCatalog([]);
          setModelRoutingCatalogStatus("Failed to load provider model catalogs.");
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedSettings, providerModelsProbeKey]);

  useEffect(() => {
    if (selectedPluginIndex >= draftConfig.plugins.length) {
      setSelectedPluginIndex(Math.max(0, draftConfig.plugins.length - 1));
    }
  }, [draftConfig.plugins.length, selectedPluginIndex]);

  useEffect(() => {
    const serverCount = Array.isArray(draftConfig.mcp?.servers) ? draftConfig.mcp.servers.length : 0;
    if (selectedMCPServerIndex >= serverCount) {
      setSelectedMCPServerIndex(Math.max(0, serverCount - 1));
    }
  }, [draftConfig.mcp?.servers?.length, selectedMCPServerIndex]);

  useEffect(() => {
    if (!isSettingsSection(sectionId)) {
      return;
    }
    setSelectedSettings((current) => (current === sectionId ? current : sectionId));
  }, [sectionId]);

  function selectSettings(nextSectionId) {
    if (!isSettingsSection(nextSectionId)) {
      return;
    }
    setSelectedSettings(nextSectionId);
    if (typeof onSectionChange === "function" && nextSectionId !== sectionId) {
      onSectionChange(nextSectionId);
    }
  }

  const filteredSettings = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) {
      return SETTINGS_ITEMS;
    }
    return SETTINGS_ITEMS.filter((item) => item.title.toLowerCase().includes(needle));
  }, [query]);

  const isRawMode = selectedSettings === "config";

  const hasChanges = useMemo(() => {
    if (isRawMode) {
      return rawConfig !== JSON.stringify(savedConfig, null, 2);
    }
    const draftNorm = normalizeConfig(draftConfig);
    const savedNorm = normalizeConfig(savedConfig);
    return stableConfigStringify(draftNorm) !== stableConfigStringify(savedNorm);
  }, [isRawMode, rawConfig, draftConfig, savedConfig]);

  const hasManualChanges = useMemo(() => {
    if (selectedSettings !== "providers" || isRawMode) {
      return hasChanges;
    }
    const draftNorm = normalizeConfig(draftConfig);
    const savedNorm = normalizeConfig(savedConfig);
    draftNorm.models = savedNorm.models;
    return stableConfigStringify(draftNorm) !== stableConfigStringify(savedNorm);
  }, [selectedSettings, isRawMode, hasChanges, draftConfig, savedConfig]);

  const rawValid = useMemo(() => {
    try {
      JSON.parse(rawConfig);
      return true;
    } catch {
      return false;
    }
  }, [rawConfig]);

  const providerModalMeta = useMemo(() => {
    if (!providerModalId) {
      return null;
    }
    return getProviderDefinition(providerModalId);
  }, [providerModalId]);

  const customModelsCount = useMemo(
    () => draftConfig.models.filter((entry) => !inferCatalogIdForEntry(entry)).length,
    [draftConfig.models]
  );

  const configuredProviderRows = useMemo(
    () =>
      draftConfig.models.map((entry, index) => {
        const catalogId = inferCatalogIdForEntry(entry);
        return {
          index,
          entry,
          catalogId,
          meta: catalogId ? getProviderDefinition(catalogId) : null
        };
      }),
    [draftConfig.models]
  );

  async function loadConfig() {
    const config = await fetchRuntimeConfig();
    if (!config) {
      setStatusText("Failed to load config");
      return;
    }

    const normalized = normalizeConfig(config);
    setSavedConfig(normalized);

    const savedDraft = localStorage.getItem(DRAFT_CONFIG_KEY);
    if (savedDraft) {
      try {
        const parsedDraft = normalizeConfig(JSON.parse(savedDraft));
        setDraftConfig(parsedDraft);
        setRawConfig(JSON.stringify(parsedDraft, null, 2));
        setStatusText("Config loaded (with local draft)");
      } catch {
        setDraftConfig(normalized);
        setRawConfig(JSON.stringify(normalized, null, 2));
        setStatusText("Config loaded (draft corrupted)");
      }
    } else {
      setDraftConfig(normalized);
      setRawConfig(JSON.stringify(normalized, null, 2));
      setStatusText("Config loaded");
    }

    setProviderModalId(null);
    setProviderModalIndex(null);
    setProviderForm(null);
    setProviderModelOptions({});
    setProviderModelStatus({});
    await loadOpenAIProviderStatus();
    await loadAnthropicProviderStatus();
    await loadSearchProviderStatus();
    await loadGitHubAuthStatus();
  }

  async function cancelChanges() {
    localStorage.removeItem(DRAFT_CONFIG_KEY);
    const normalized = clone(savedConfig);
    setDraftConfig(normalized);
    setRawConfig(JSON.stringify(normalized, null, 2));
    setPendingOAuthDisconnect(false);
    setPendingAnthropicOAuthDisconnect(false);
    setStatusText("Changes cancelled");
  }

  async function persistConfig(payload) {
    try {
      const response = await updateRuntimeConfig(payload);

      if (pendingOAuthDisconnect) {
        await disconnectOpenAIOAuth();
        setPendingOAuthDisconnect(false);
      }
      if (pendingAnthropicOAuthDisconnect) {
        await disconnectAnthropicOAuth();
        setPendingAnthropicOAuthDisconnect(false);
      }

      localStorage.removeItem(DRAFT_CONFIG_KEY);
      const normalized = normalizeConfig(response);

      setDraftConfig(normalized);
      setSavedConfig(normalized);
      setRawConfig(JSON.stringify(normalized, null, 2));
      if (typeof onRuntimeConfigUpdated === "function") {
        onRuntimeConfigUpdated(response as Record<string, unknown>);
      }
      await loadOpenAIProviderStatus();
      await loadAnthropicProviderStatus();
      await loadSearchProviderStatus();
      await loadGitHubAuthStatus();
      setStatusText("Config saved");
      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to save config";
      setStatusText(message);
      return false;
    }
  }

  async function saveConfig() {
    try {
      const payload = isRawMode ? normalizeConfig(JSON.parse(rawConfig)) : draftConfig;
      await persistConfig(payload);
    } catch {
      setStatusText("Invalid raw JSON");
    }
  }

  async function runGitSyncNow() {
    if (gitSyncRunning) return;
    setGitSyncRunning(true);
    setGitSyncStatusText("Syncing workspace...");
    try {
      if (hasChanges) {
        const payload = isRawMode ? normalizeConfig(JSON.parse(rawConfig)) : draftConfig;
        const saved = await persistConfig(payload);
        if (!saved) {
          setGitSyncStatusText("Save config before syncing.");
          return;
        }
      }
      const response = await runWorkspaceGitSync();
      const ok = Boolean(response?.ok);
      const message = String(response?.message || (ok ? "Workspace synced." : "Workspace sync failed."));
      setGitSyncStatusText(message);
      setStatusText(message);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Workspace sync failed.";
      setGitSyncStatusText(message);
      setStatusText(message);
    } finally {
      setGitSyncRunning(false);
    }
  }

  async function loadOpenAIProviderStatus() {
    const response = await fetchOpenAIProviderStatus();
    if (!response) {
      return;
    }

    const payload = response as any;
    setOpenAIProviderStatus({
      hasEnvironmentKey: Boolean(payload.hasEnvironmentKey),
      hasConfiguredKey: Boolean(payload.hasConfiguredKey),
      hasAnyKey: Boolean(payload.hasAnyKey),
      hasOAuthCredentials: Boolean(payload.hasOAuthCredentials),
      oauthAccountId: String(payload.oauthAccountId || ""),
      oauthPlanType: String(payload.oauthPlanType || ""),
      oauthExpiresAt: String(payload.oauthExpiresAt || "")
    });
  }

  async function loadAnthropicProviderStatus() {
    const response = await fetchAnthropicProviderStatus();
    if (!response) {
      return;
    }

    const payload = response as any;
    setAnthropicProviderStatus({
      hasEnvironmentKey: Boolean(payload.hasEnvironmentKey),
      hasConfiguredKey: Boolean(payload.hasConfiguredKey),
      hasAnyKey: Boolean(payload.hasAnyKey),
      hasOAuthCredentials: Boolean(payload.hasOAuthCredentials),
      oauthSource: String(payload.oauthSource || ""),
      oauthExpiresAt: String(payload.oauthExpiresAt || ""),
      oauthRefreshable: Boolean(payload.oauthRefreshable)
    });
  }

  async function loadGitHubAuthStatus() {
    const response = await fetchGitHubAuthStatus();
    if (!response) return;
    const payload = response as any;
    setGitHubAuthStatus({
      connected: Boolean(payload.connected),
      username: payload.username || null,
      connectedAt: payload.connectedAt || null
    });
  }

  async function handleGitHubConnect() {
    const token = gitHubToken.trim();
    if (!token) return;
    setGitHubConnecting(true);
    setGitHubStatusText("Validating token...");
    const response = await connectGitHub({ token }) as any;
    setGitHubConnecting(false);
    if (response?.ok) {
      setGitHubStatusText(response.message || "Connected.");
      setGitHubToken("");
      await loadGitHubAuthStatus();
    } else {
      setGitHubStatusText(response?.message || "Failed to connect GitHub.");
    }
  }

  async function handleGitHubDisconnect() {
    await disconnectGitHub();
    setGitHubStatusText("Disconnected.");
    await loadGitHubAuthStatus();
  }

  async function loadSearchProviderStatus() {
    const response = await fetchSearchProviderStatus();
    if (!response) {
      return;
    }

    const payload = response as any;
    setSearchProviderStatus({
      activeProvider: String(payload.activeProvider || "perplexity"),
      brave: {
        hasEnvironmentKey: Boolean(payload.brave?.hasEnvironmentKey),
        hasConfiguredKey: Boolean(payload.brave?.hasConfiguredKey),
        hasAnyKey: Boolean(payload.brave?.hasAnyKey)
      },
      perplexity: {
        hasEnvironmentKey: Boolean(payload.perplexity?.hasEnvironmentKey),
        hasConfiguredKey: Boolean(payload.perplexity?.hasConfiguredKey),
        hasAnyKey: Boolean(payload.perplexity?.hasAnyKey)
      }
    });
  }

  function mutateDraft(mutator) {
    setDraftConfig((previous) => {
      const next = clone(previous);
      mutator(next);
      const json = JSON.stringify(next, null, 2);
      setRawConfig(json);
      localStorage.setItem(DRAFT_CONFIG_KEY, json);
      return next;
    });
  }

  function writeProviderDraft(nextConfig) {
    const json = JSON.stringify(nextConfig, null, 2);
    setDraftConfig(nextConfig);
    setRawConfig(json);
  }

  async function runProviderConfigSave(payload, token, successMessage) {
    setStatusText("Saving provider changes...");
    try {
      const response = await updateRuntimeConfig(payload);
      if (providerAutoSaveTokenRef.current !== token) {
        return true;
      }

      localStorage.removeItem(DRAFT_CONFIG_KEY);
      const normalized = normalizeConfig(response);
      setDraftConfig(normalized);
      setSavedConfig(normalized);
      setRawConfig(JSON.stringify(normalized, null, 2));
      if (typeof onRuntimeConfigUpdated === "function") {
        onRuntimeConfigUpdated(response as Record<string, unknown>);
      }
      await loadOpenAIProviderStatus();
      await loadAnthropicProviderStatus();
      await loadSearchProviderStatus();
      await loadGitHubAuthStatus();
      setStatusText(successMessage);
      return true;
    } catch (err) {
      if (providerAutoSaveTokenRef.current === token) {
        const message = err instanceof Error ? err.message : "Failed to save provider changes";
        setStatusText(message);
      }
      return false;
    }
  }

  function scheduleProviderConfigSave(nextConfig, options: { debounce?: boolean; successMessage?: string } = {}) {
    const debounce = options.debounce !== false;
    const successMessage = options.successMessage || "Provider changes saved";
    const payload = normalizeConfig(nextConfig);
    const token = providerAutoSaveTokenRef.current + 1;
    providerAutoSaveTokenRef.current = token;

    if (providerAutoSaveTimerRef.current) {
      clearTimeout(providerAutoSaveTimerRef.current);
      providerAutoSaveTimerRef.current = null;
    }

    if (!debounce) {
      return runProviderConfigSave(payload, token, successMessage);
    }

    setStatusText("Provider changes save automatically...");
    providerAutoSaveTimerRef.current = setTimeout(() => {
      providerAutoSaveTimerRef.current = null;
      runProviderConfigSave(payload, token, successMessage).catch(() => {
        // runProviderConfigSave reports errors in the header.
      });
    }, 650);
    return Promise.resolve(true);
  }

  async function openOpenAIPlatform() {
    setProviderStatus("openai-oauth", "Checking for local Codex credentials...");
    setConfigDeviceCode(null);
    setConfigDeviceCodeCopied(false);
    configDeviceCodePollingRef.current = false;

    const imported = await importOpenAICodexCredentials();
    if (imported?.ok) {
      setProviderStatus("openai-oauth", String(imported.message || "Codex credentials imported."));
      setStatusText("OpenAI OAuth connected");
      await loadOpenAIProviderStatus();
      await loadProviderModels("openai-oauth", providerForm || getProviderDefinition("openai-oauth").defaultEntry);
      return;
    }

    setProviderStatus("openai-oauth", "Codex credentials were not found locally. Requesting device code from OpenAI...");
    const response = await startOpenAIDeviceCode();
    if (!response || typeof response.deviceAuthId !== "string") {
      const message = imported?.message
        ? `Failed to start device code flow. ${String(imported.message)}`
        : "Failed to start device code flow.";
      setProviderStatus("openai-oauth", message);
      return;
    }

    const info = {
      deviceAuthId: String(response.deviceAuthId),
      userCode: String(response.userCode),
      verificationURL: String(response.verificationURL || "https://auth.openai.com/codex/device")
    };
    setConfigDeviceCode(info);
    setProviderStatus("openai-oauth", "Copy the code below, then open the login page to authorize.");

    configDeviceCodePollingRef.current = true;
    setConfigDeviceCodePolling(true);

    let interval = 5000;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (!configDeviceCodePollingRef.current) break;
      await new Promise((r) => setTimeout(r, interval));
      if (!configDeviceCodePollingRef.current) break;

      const result = await pollOpenAIDeviceCode({
        deviceAuthId: info.deviceAuthId,
        userCode: info.userCode
      });

      if (!result) {
        setProviderStatus("openai-oauth", "Polling failed. Try again.");
        break;
      }

      const status = String(result.status || "");
      if (status === "approved" && result.ok) {
        setConfigDeviceCode(null);
        setProviderStatus("openai-oauth", String(result.message || "Connected via device code."));
        setStatusText("OpenAI OAuth connected");
        await loadOpenAIProviderStatus();
        await loadProviderModels("openai-oauth", providerForm || getProviderDefinition("openai-oauth").defaultEntry);
        break;
      }
      if (status === "slow_down") {
        interval = Math.min(interval + 2000, 15000);
      }
      if (status === "error") {
        setProviderStatus("openai-oauth", String(result.message || "Device code authorization failed."));
        break;
      }
    }

    configDeviceCodePollingRef.current = false;
    setConfigDeviceCodePolling(false);
  }

  function copyConfigDeviceCode() {
    if (!configDeviceCode) return;
    navigator.clipboard.writeText(configDeviceCode.userCode).then(() => {
      setConfigDeviceCodeCopied(true);
    }).catch(() => {
      setConfigDeviceCodeCopied(true);
    });
  }

  function openConfigDeviceCodeLoginPage() {
    if (!configDeviceCode) return;
    const width = 640;
    const height = 860;
    const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2));
    const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2));
    const popup = window.open(
      configDeviceCode.verificationURL,
      "sloppy-openai-device-code",
      `popup=yes,width=${width},height=${height},left=${left},top=${top}`
    );
    if (!popup) {
      setProviderStatus("openai-oauth", "Login window was blocked. Allow popups or open the login page in a new tab.");
      return;
    }
    setConfigDeviceCodeCopied(true);
  }

  function cancelConfigDeviceCodePolling() {
    configDeviceCodePollingRef.current = false;
    setConfigDeviceCodePolling(false);
    setConfigDeviceCode(null);
    setConfigDeviceCodeCopied(false);
    setProviderStatus("openai-oauth", "Device code authorization cancelled.");
  }

  function waitForAnthropicOAuthCallback(popup, redirectURI) {
    return new Promise((resolve, reject) => {
      const startedAt = Date.now();
      const interval = window.setInterval(() => {
        if (!popup || popup.closed) {
          window.clearInterval(interval);
          reject(new Error("Anthropic OAuth window was closed."));
          return;
        }

        if (Date.now() - startedAt > 5 * 60 * 1000) {
          window.clearInterval(interval);
          try {
            popup.close();
          } catch {
            // ignore
          }
          reject(new Error("Anthropic OAuth timed out. Try again."));
          return;
        }

        try {
          const href = popup.location.href;
          if (href && href.startsWith(redirectURI)) {
            window.clearInterval(interval);
            try {
              popup.close();
            } catch {
              // ignore
            }
            resolve(href);
          }
        } catch {
          // Cross-origin until the popup returns to our redirect URI.
        }
      }, 500);
    });
  }

  async function openAnthropicOAuthPopup() {
    const redirectURI = `${window.location.origin}${window.location.pathname}`;
    setProviderStatus("anthropic-oauth", "Checking for local Claude Code credentials...");
    setAnthropicOAuthAuthorizationURL("");

    const imported = await importAnthropicClaudeCredentials();
    if (imported?.ok) {
      setProviderStatus("anthropic-oauth", String(imported.message || "Claude Code credentials imported."));
      setStatusText("Anthropic OAuth imported");
      await loadAnthropicProviderStatus();
      await loadProviderModels("anthropic-oauth", providerForm || getProviderDefinition("anthropic-oauth").defaultEntry);
      return;
    }

    setProviderStatus("anthropic-oauth", "Claude Code credentials were not found locally. Requesting Anthropic OAuth URL...");

    const response = await startAnthropicOAuth({ redirectURI });
    if (!response || typeof response.authorizationURL !== "string") {
      const message = imported?.message
        ? `Failed to start Anthropic OAuth. ${String(imported.message)}`
        : "Failed to start Anthropic OAuth.";
      setProviderStatus("anthropic-oauth", message);
      return;
    }
    setAnthropicOAuthAuthorizationURL(String(response.authorizationURL));

    const width = 640;
    const height = 860;
    const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2));
    const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2));
    const popup = window.open(
      String(response.authorizationURL),
      "sloppy-anthropic-oauth",
      `popup=yes,width=${width},height=${height},left=${left},top=${top}`
    );
    anthropicOAuthPopupRef.current = popup;
    if (!popup) {
      setProviderStatus("anthropic-oauth", "Popup was blocked. Allow popups, use the QR code, or open the browser login again.");
      return;
    }

    setProviderStatus("anthropic-oauth", "Waiting for Anthropic sign-in confirmation...");

    try {
      const callbackURL = await waitForAnthropicOAuthCallback(popup, redirectURI);
      const completion = await completeAnthropicOAuth({ callbackURL });
      if (!completion?.ok) {
        setProviderStatus("anthropic-oauth", String(completion?.message || "Anthropic OAuth failed."));
        return;
      }

      setProviderStatus("anthropic-oauth", String(completion.message || "Anthropic OAuth connected."));
      setStatusText("Anthropic OAuth connected");
      setAnthropicOAuthAuthorizationURL("");
      await loadAnthropicProviderStatus();
      await loadProviderModels("anthropic-oauth", providerForm || getProviderDefinition("anthropic-oauth").defaultEntry);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Anthropic OAuth failed.";
      setProviderStatus("anthropic-oauth", message);
    } finally {
      anthropicOAuthPopupRef.current = null;
    }
  }

  async function importClaudeCredentialsForAnthropic() {
    setProviderStatus("anthropic-oauth", "Importing Claude Code credentials...");
    setAnthropicOAuthAuthorizationURL("");
    const response = await importAnthropicClaudeCredentials();
    if (!response?.ok) {
      setProviderStatus("anthropic-oauth", String(response?.message || "Failed to import Claude Code credentials."));
      return;
    }

    setProviderStatus("anthropic-oauth", String(response.message || "Claude Code credentials imported."));
    setStatusText("Anthropic OAuth imported");
    await loadAnthropicProviderStatus();
    await loadProviderModels("anthropic-oauth", providerForm || getProviderDefinition("anthropic-oauth").defaultEntry);
  }

  async function handleAnthropicOAuthDisconnect() {
    const ok = await disconnectAnthropicOAuth();
    if (!ok) {
      setProviderStatus("anthropic-oauth", "Failed to disconnect Anthropic OAuth.");
      return;
    }

    setProviderStatus("anthropic-oauth", "Anthropic OAuth disconnected.");
    setAnthropicOAuthAuthorizationURL("");
    setStatusText("Anthropic OAuth disconnected");
    setProviderModelOptions((previous) => ({
      ...previous,
      ["anthropic-oauth"]: []
    }));
    await loadAnthropicProviderStatus();
  }

  function setProviderStatus(providerId, message) {
    setProviderModelStatus((previous) => ({
      ...previous,
      [providerId]: message
    }));
  }

  function openProviderModalAtIndex(index) {
    const entry = draftConfig.models[index];
    if (!entry) {
      return;
    }
    const catalogId = inferCatalogIdForEntry(entry) || "openai-api";
    const provider = getProviderDefinition(catalogId);
    setProviderModalIndex(index);
    setProviderModalId(catalogId);
    setProviderForm({
      apiKey: entry.apiKey ?? "",
      apiUrl: entry.apiUrl ?? "",
      model: entry.model ?? "",
      title: entry.title || provider.defaultEntry.title,
      disabled: Boolean(entry.disabled)
    });
    setProviderModelMenuOpen(false);
  }

  function appendProviderAndOpenModal(catalogId) {
    const provider = getProviderDefinition(catalogId);
    const base = clone(provider.defaultEntry);
    const next = clone(draftConfig);
    next.models.push({
      ...base,
      title: base.title,
      disabled: false,
      providerCatalogId: catalogId
    });
    const idx = next.models.length - 1;
    const entry = next.models[idx];
    writeProviderDraft(next);
    setProviderModalIndex(idx);
    setProviderModalId(catalogId);
    setProviderForm({
      apiKey: entry.apiKey ?? "",
      apiUrl: entry.apiUrl ?? "",
      model: entry.model ?? "",
      title: entry.title || provider.defaultEntry.title,
      disabled: false
    });
    setProviderModelMenuOpen(false);
    scheduleProviderConfigSave(next, {
      debounce: false,
      successMessage: "Provider added"
    });
  }

  /** @deprecated prefer appendProviderAndOpenModal / openProviderModalAtIndex */
  function openProviderModal(catalogId) {
    const idx = findProviderModelIndex(draftConfig.models, catalogId);
    if (idx >= 0) {
      openProviderModalAtIndex(idx);
    } else {
      appendProviderAndOpenModal(catalogId);
    }
  }

  function closeProviderModal() {
    if (providerModelLoadTimerRef.current) {
      clearTimeout(providerModelLoadTimerRef.current);
      providerModelLoadTimerRef.current = null;
    }
    setProviderModalId(null);
    setProviderModalIndex(null);
    setProviderForm(null);
    setProviderModelMenuOpen(false);
    setProviderModelMenuRect(null);
  }

  function providerEntryFromForm(provider, form) {
    const isAnthropic = provider.id === "anthropic" || provider.id === "anthropic-oauth";
    return {
      title: String(form.title || "").trim() || provider.defaultEntry.title,
      apiKey: provider.requiresApiKey ? String(form.apiKey || "").trim() : "",
      apiUrl: isAnthropic
        ? String(form.apiUrl || "").trim()
        : String(form.apiUrl || "").trim() || provider.defaultEntry.apiUrl,
      model: String(form.model || "").trim() || provider.defaultEntry.model,
      disabled: Boolean(form.disabled),
      providerCatalogId: provider.id
    };
  }

  function configWithProviderForm(provider, form) {
    const nextConfig = clone(draftConfig);
    const nextEntry = providerEntryFromForm(provider, form);
    const index =
      providerModalIndex != null ? providerModalIndex : findProviderModelIndex(nextConfig.models, provider.id);
    if (index >= 0) {
      nextConfig.models[index] = nextEntry;
    } else {
      nextConfig.models.push(nextEntry);
      setProviderModalIndex(nextConfig.models.length - 1);
    }
    return nextConfig;
  }

  function updateProviderForm(field, value) {
    if (!providerModalMeta || !providerForm) {
      return;
    }

    const nextForm = {
      ...providerForm,
      [field]: value
    };
    setProviderForm(nextForm);

    const nextConfig = configWithProviderForm(providerModalMeta, nextForm);
    writeProviderDraft(nextConfig);
    scheduleProviderConfigSave(nextConfig, {
      successMessage: "Provider changes saved"
    });

    if (field === "model") {
      setProviderModelMenuOpen(true);
    }
  }

  function selectAnthropicAuthMode(mode) {
    if (!providerForm) {
      return;
    }
    const nextProviderId = mode === "api-token" ? "anthropic" : "anthropic-oauth";
    if (providerModalId === nextProviderId) {
      return;
    }

    const provider = getProviderDefinition(nextProviderId);
    const currentTitle = String(providerForm.title || "").trim();
    const nextTitle =
      currentTitle === "anthropic" || currentTitle === "anthropic-oauth" || !currentTitle
        ? provider.defaultEntry.title
        : currentTitle;
    const nextForm = {
      ...providerForm,
      title: nextTitle,
      apiUrl: providerForm.apiUrl ?? provider.defaultEntry.apiUrl,
      model: providerForm.model || provider.defaultEntry.model
    };

    setProviderModalId(nextProviderId);
    setProviderForm(nextForm);
    setProviderModelMenuOpen(false);
    setProviderStatus(nextProviderId, "");

    const nextConfig = configWithProviderForm(provider, nextForm);
    writeProviderDraft(nextConfig);
    scheduleProviderConfigSave(nextConfig, {
      successMessage: "Provider changes saved"
    });
  }

  async function loadProviderModels(providerId, entryOverride = null) {
    const provider = getProviderDefinition(providerId);
    if (!provider.supportsModelCatalog) {
      return;
    }

    const entryFromConfig =
      providerModalIndex != null
        ? draftConfig.models[providerModalIndex]
        : getProviderEntry(draftConfig.models, provider.id)?.entry || provider.defaultEntry;
    const entry = entryOverride || entryFromConfig;
    setProviderStatus(provider.id, "Loading provider models...");

    let payload;
    if (provider.id === "openrouter" || provider.id === "ollama" || provider.id === "anthropic" || provider.id === "anthropic-oauth") {
      const probe = await probeProvider({
        providerId: provider.id,
        apiKey: String(entry.apiKey || "").trim() || undefined,
        apiUrl: entry.apiUrl || (provider.id === "anthropic" || provider.id === "anthropic-oauth" ? "" : provider.defaultEntry.apiUrl)
      });
      if (!probe) {
        setProviderStatus(provider.id, "Failed to load models from sloppy");
        return;
      }
      payload = {
        models: Array.isArray(probe.models) ? probe.models : [],
        warning: probe.ok ? undefined : String(probe.message || ""),
        source: probe.ok ? "remote" : "fallback",
        usedEnvironmentKey: Boolean(probe.usedEnvironmentKey)
      };
    } else {
      const response = await fetchOpenAIModels({
        authMethod: provider.authMethod,
        apiKey: provider.authMethod === "api_key" ? entry.apiKey : undefined,
        apiUrl: entry.apiUrl || provider.defaultEntry.apiUrl
      });

      if (!response) {
        setProviderStatus(provider.id, "Failed to load models from sloppy");
        return;
      }
      payload = response;
    }

    payload = payload as any;
    const models = Array.isArray(payload.models) ? payload.models : [];

    setProviderModelOptions((previous) => ({
      ...previous,
      [provider.id]: models
    }));

    if (payload.warning) {
      setProviderStatus(provider.id, payload.warning);
    } else if (payload.source === "remote") {
      const label =
        provider.id === "openrouter"
          ? "OpenRouter"
          : provider.id === "ollama"
            ? "Ollama"
            : provider.id === "anthropic-oauth" || provider.id === "anthropic"
              ? "Anthropic"
            : "OpenAI";
      setProviderStatus(provider.id, `Loaded ${models.length} models from ${label}`);
    } else {
      setProviderStatus(provider.id, `Loaded fallback catalog (${models.length} models)`);
    }

    if (provider.id === "openai-api" || provider.id === "openai-oauth") {
      setOpenAIProviderStatus((previous) => (
        provider.id === "openai-api"
          ? {
            ...previous,
            hasEnvironmentKey: Boolean(payload.usedEnvironmentKey),
            hasAnyKey: previous.hasConfiguredKey || Boolean(payload.usedEnvironmentKey)
          }
          : previous
      ));
    }
    if (provider.id === "anthropic-oauth") {
      await loadAnthropicProviderStatus();
    }
  }

  async function testProviderConnection(providerId) {
    const provider = getProviderDefinition(providerId);
    if (!provider) {
      return;
    }

    if (providerModelLoadTimerRef.current) {
      clearTimeout(providerModelLoadTimerRef.current);
      providerModelLoadTimerRef.current = null;
    }
    providerModelLoadTokenRef.current += 1;

    setProviderProbeTesting((previous) => ({ ...previous, [provider.id]: true }));
    try {
      if (provider.supportsModelCatalog) {
        await loadProviderModels(provider.id, providerForm);
      } else {
        setProviderStatus(provider.id, "This provider does not support a connection test.");
      }
    } catch {
      setProviderStatus(provider.id, "Failed to reach provider.");
    } finally {
      setProviderProbeTesting((previous) => ({ ...previous, [provider.id]: false }));
    }
  }

  useEffect(() => {
    if (!providerModalMeta || !providerForm || !providerModalMeta.supportsModelCatalog) {
      return;
    }

    const provider = providerModalMeta;
    const hasEnvironmentKeyForOpenAI = provider.id === "openai-api" && openAIProviderStatus.hasEnvironmentKey;
    const hasOAuthCredentialsForOpenAI = provider.id === "openai-oauth" && openAIProviderStatus.hasOAuthCredentials;
    const hasOAuthCredentialsForAnthropic = provider.id === "anthropic-oauth" && anthropicProviderStatus.hasOAuthCredentials;
    const requiresApiKey = provider.authMethod === "api_key";
    const hasKey = Boolean(String(providerForm.apiKey || "").trim())
      || hasEnvironmentKeyForOpenAI
      || (provider.id === "anthropic-oauth" && anthropicProviderStatus.hasEnvironmentKey);

    if (requiresApiKey && !hasKey) {
      setProviderStatus(provider.id, "Set API Key to load models.");
      setProviderModelOptions((previous) => ({
        ...previous,
        [provider.id]: []
      }));
      return;
    }

    if (
      provider.id === "anthropic-oauth" &&
      !hasOAuthCredentialsForAnthropic &&
      !anthropicProviderStatus.hasEnvironmentKey &&
      !String(providerForm.apiKey || "").trim()
    ) {
      setProviderStatus(provider.id, "Connect Anthropic OAuth, import Claude Code credentials, or set ANTHROPIC_AUTH_TOKEN.");
      setProviderModelOptions((previous) => ({
        ...previous,
        [provider.id]: []
      }));
      return;
    }

    if (provider.id === "openai-oauth" && !hasOAuthCredentialsForOpenAI) {
      setProviderStatus(provider.id, "Connect OpenAI OAuth to load Codex models.");
      setProviderModelOptions((previous) => ({
        ...previous,
        [provider.id]: []
      }));
      return;
    }

    if (providerModelLoadTimerRef.current) {
      clearTimeout(providerModelLoadTimerRef.current);
      providerModelLoadTimerRef.current = null;
    }

    const token = providerModelLoadTokenRef.current + 1;
    providerModelLoadTokenRef.current = token;
    providerModelLoadTimerRef.current = setTimeout(() => {
      if (providerModelLoadTokenRef.current !== token) {
        return;
      }
      loadProviderModels(provider.id, providerForm).catch(() => {
        setProviderStatus(provider.id, "Failed to load models from sloppy");
      });
    }, 450);

    return () => {
      if (providerModelLoadTimerRef.current) {
        clearTimeout(providerModelLoadTimerRef.current);
        providerModelLoadTimerRef.current = null;
      }
    };
  }, [
    providerModalMeta,
    providerModalIndex,
    providerForm?.apiKey,
    providerForm?.apiUrl,
    openAIProviderStatus.hasEnvironmentKey,
    openAIProviderStatus.hasOAuthCredentials,
    anthropicProviderStatus.hasEnvironmentKey,
    anthropicProviderStatus.hasOAuthCredentials
  ]);

  useEffect(() => {
    return () => {
      configDeviceCodePollingRef.current = false;
      if (providerAutoSaveTimerRef.current) {
        clearTimeout(providerAutoSaveTimerRef.current);
        providerAutoSaveTimerRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    if (!providerModelMenuOpen) {
      return;
    }

    function syncProviderModelMenuRect() {
      const picker = providerModelPickerRef.current;
      if (!picker) {
        return;
      }
      const rect = picker.getBoundingClientRect();
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight;
      const viewportPadding = 10;
      const menuGap = 6;
      const defaultMaxHeight = 260;
      const minMaxHeight = 140;
      const spaceBelow = viewportHeight - rect.bottom - viewportPadding;
      const spaceAbove = rect.top - viewportPadding;

      let maxHeight = Math.max(minMaxHeight, Math.min(defaultMaxHeight, spaceBelow));
      let top = rect.bottom + menuGap;
      if (spaceBelow < minMaxHeight && spaceAbove > spaceBelow) {
        maxHeight = Math.max(minMaxHeight, Math.min(defaultMaxHeight, spaceAbove - menuGap));
        top = rect.top - menuGap - maxHeight;
      }
      top = Math.max(viewportPadding, Math.round(top));

      setProviderModelMenuRect({
        top,
        left: Math.round(rect.left),
        width: Math.round(rect.width),
        maxHeight: Math.round(maxHeight)
      });
    }

    function handlePointerDown(event) {
      const target = event.target;
      const pickerContainsTarget = providerModelPickerRef.current?.contains(target);
      const menuContainsTarget = providerModelMenuRef.current?.contains(target);
      if (!pickerContainsTarget && !menuContainsTarget) {
        setProviderModelMenuOpen(false);
        setProviderModelMenuRect(null);
      }
    }

    syncProviderModelMenuRect();
    window.addEventListener("resize", syncProviderModelMenuRect);
    window.addEventListener("scroll", syncProviderModelMenuRect, true);
    window.addEventListener("pointerdown", handlePointerDown);
    return () => {
      window.removeEventListener("resize", syncProviderModelMenuRect);
      window.removeEventListener("scroll", syncProviderModelMenuRect, true);
      window.removeEventListener("pointerdown", handlePointerDown);
    };
  }, [providerModelMenuOpen, providerModalMeta?.id]);

  async function saveProviderFromModal() {
    if (!providerModalMeta || !providerForm) {
      return;
    }

    const nextConfig = configWithProviderForm(providerModalMeta, providerForm);
    writeProviderDraft(nextConfig);
    closeProviderModal();
    await scheduleProviderConfigSave(nextConfig, {
      debounce: false,
      successMessage: "Provider changes saved"
    });
  }

  async function closeProviderModalWithAutosave() {
    if (!providerModalMeta || !providerForm) {
      closeProviderModal();
      return;
    }
    await saveProviderFromModal();
  }

  async function removeProviderFromModal() {
    if (!providerModalMeta) {
      return;
    }

    const provider = providerModalMeta;
    const disconnectOpenAI = provider.id === "openai-oauth";
    const disconnectAnthropic = provider.id === "anthropic-oauth";

    const nextConfig = clone(draftConfig);
    const index =
      providerModalIndex != null ? providerModalIndex : findProviderModelIndex(nextConfig.models, provider.id);
    if (index >= 0) {
      nextConfig.models.splice(index, 1);
    }

    writeProviderDraft(nextConfig);
    closeProviderModal();
    const saved = await scheduleProviderConfigSave(nextConfig, {
      debounce: false,
      successMessage: "Provider removed"
    });
    if (saved && disconnectOpenAI) {
      await disconnectOpenAIOAuth();
      await loadOpenAIProviderStatus();
    }
    if (saved && disconnectAnthropic) {
      await disconnectAnthropicOAuth();
      await loadAnthropicProviderStatus();
    }
  }

  function setProviderRowDisabled(index, disabled) {
    const nextConfig = clone(draftConfig);
    if (!nextConfig.models[index]) {
      return;
    }
    nextConfig.models[index].disabled = disabled;
    writeProviderDraft(nextConfig);
    scheduleProviderConfigSave(nextConfig, {
      debounce: false,
      successMessage: "Provider changes saved"
    });
  }

  function renderSettingsContent() {
    if (selectedSettings === "providers") {
      return (
        <>
          <ProviderEditor
            providerCatalog={PROVIDER_CATALOG_UI}
            configuredProviderRows={configuredProviderRows}
            customModelsCount={customModelsCount}
            openAIProviderStatus={openAIProviderStatus}
            anthropicProviderStatus={anthropicProviderStatus}
            providerModalMeta={providerModalMeta}
            providerForm={providerForm}
            providerModelStatus={providerModelStatus}
            providerModelOptions={providerModelOptions}
            providerModelMenuOpen={providerModelMenuOpen}
            providerModelMenuRect={providerModelMenuRect}
            providerModelPickerRef={providerModelPickerRef}
            providerModelMenuRef={providerModelMenuRef}
            modalActiveEntry={providerModalIndex != null ? draftConfig.models[providerModalIndex] : null}
            onOpenProviderAtIndex={openProviderModalAtIndex}
            onAppendProvider={appendProviderAndOpenModal}
            onSetProviderRowDisabled={setProviderRowDisabled}
            onCloseProviderModal={closeProviderModalWithAutosave}
            onUpdateProviderForm={updateProviderForm}
            onSelectAnthropicAuthMode={selectAnthropicAuthMode}
            onOpenOAuth={openOpenAIPlatform}
            onOpenAnthropicOAuth={openAnthropicOAuthPopup}
            onImportAnthropicClaudeCredentials={importClaudeCredentialsForAnthropic}
            onDisconnectAnthropicOAuth={handleAnthropicOAuthDisconnect}
            anthropicOAuthAuthorizationURL={anthropicOAuthAuthorizationURL}
            onCancelDeviceCode={cancelConfigDeviceCodePolling}
            onCopyDeviceCode={copyConfigDeviceCode}
            onOpenDeviceCodeLoginPage={openConfigDeviceCodeLoginPage}
            deviceCode={configDeviceCode}
            deviceCodeCopied={configDeviceCodeCopied}
            isDeviceCodePolling={configDeviceCodePolling}
            onRemoveProvider={removeProviderFromModal}
            onSaveProvider={saveProviderFromModal}
            onTestProviderConnection={testProviderConnection}
            providerProbeTesting={providerProbeTesting}
            onSetProviderModelMenuOpen={setProviderModelMenuOpen}
            onSetProviderModelMenuRect={setProviderModelMenuRect}
            providerIsConfigured={providerIsConfigured}
            filterProviderModels={filterModelsByQuery}
          />
          <section className="entry-editor-card providers-intro-card" style={{ marginTop: 0 }}>
            <h3>GitHub Access</h3>
            <p className="placeholder-text">
              Connect a GitHub Personal Access Token to clone private repositories and download private skills.
              The token is stored locally in the workspace.{" "}
              <a href="https://github.com/settings/tokens/new?scopes=repo&description=Sloppy" target="_blank" rel="noreferrer">
                Create a token
              </a>
              .
            </p>
            {gitHubAuthStatus.connected ? (
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                <div className="onboarding-provider-badge" style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span className="material-symbols-rounded" aria-hidden="true" style={{ color: "var(--color-success, #22c55e)" }}>check_circle</span>
                  <span>
                    Connected{gitHubAuthStatus.username ? ` as @${gitHubAuthStatus.username}` : ""}
                  </span>
                </div>
                <div>
                  <button type="button" className="btn btn-secondary btn-sm" onClick={handleGitHubDisconnect}>
                    Disconnect
                  </button>
                </div>
              </div>
            ) : (
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                <label style={{ marginBottom: 0 }}>
                  Personal Access Token
                  <input
                    type="password"
                    value={gitHubToken}
                    onChange={(e) => setGitHubToken(e.target.value)}
                    placeholder="ghp_..."
                    autoComplete="off"
                    onKeyDown={(e) => { if (e.key === "Enter") handleGitHubConnect(); }}
                  />
                </label>
                <div>
                  <button
                    type="button"
                    className="btn btn-primary btn-sm"
                    onClick={handleGitHubConnect}
                    disabled={gitHubConnecting || !gitHubToken.trim()}
                  >
                    {gitHubConnecting ? "Connecting..." : "Connect"}
                  </button>
                </div>
              </div>
            )}
            {gitHubStatusText ? (
              <p className="placeholder-text" style={{ marginTop: 8, marginBottom: 0 }}>{gitHubStatusText}</p>
            ) : null}
          </section>
        </>
      );
    }
    if (selectedSettings === "plugins") {
      return (
        <PluginEditor
          draftConfig={draftConfig}
          selectedPluginIndex={selectedPluginIndex}
          onSelectPluginIndex={setSelectedPluginIndex}
          mutateDraft={mutateDraft}
          emptyPlugin={emptyPlugin}
        />
      );
    }
    if (selectedSettings === "mcp") {
      return (
        <MCPEditor
          draftConfig={draftConfig}
          selectedMCPServerIndex={selectedMCPServerIndex}
          onSelectMCPServerIndex={setSelectedMCPServerIndex}
          mutateDraft={mutateDraft}
          emptyMCPServer={emptyMCPServer}
          parseLines={parseLines}
        />
      );
    }
    if (selectedSettings === "nodehost") {
      return <NodeHostEditor draftConfig={draftConfig} mutateDraft={mutateDraft} parseLines={parseLines} />;
    }
    if (selectedSettings === "channels") {
      return (
        <div className="tg-settings-shell">
          <section className="entry-editor-card providers-intro-card">
            <h3>Channels</h3>
            <p className="placeholder-text">
              Connect messaging platforms to route incoming messages to agents.
            </p>
          </section>
          <section className="entry-editor-card">
            <h3>Channel Lifetime</h3>
            <div className="entry-form-grid">
              <label style={{ gridColumn: "1 / -1" }}>
                Close inactive channels after (days)
                <input
                  type="number"
                  min="0"
                  step="1"
                  value={draftConfig.channels.channelInactivityDays}
                  onChange={(event) =>
                    mutateDraft((draft) => {
                      draft.channels.channelInactivityDays = parseInteger(event.target.value, 2);
                    })
                  }
                />
                <span className="entry-form-hint">
                  Channels with no activity for this many days will be closed automatically. Set to 0 to disable.
                </span>
              </label>
            </div>
          </section>
          <TelegramEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />
          <DiscordEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />
        </div>
      );
    }
    if (selectedSettings === "search-tools") {
      return (
        <SearchToolsEditor
          draftConfig={draftConfig}
          searchProviderStatus={searchProviderStatus}
          mutateDraft={mutateDraft}
        />
      );
    }
    if (selectedSettings === "git-sync") {
      const gitSyncEnabled = Boolean(draftConfig.gitSync?.enabled);
      const syncFrequency = normalizeGitSyncFrequency(draftConfig.gitSync?.schedule?.frequency);
      const conflictStrategy = normalizeGitSyncConflictStrategy(draftConfig.gitSync?.conflictStrategy);

      return (
        <section className="entry-editor-card">
          <h3>Workspace Git Sync</h3>
          <div className="entry-form-grid">
            <label style={{ gridColumn: "1 / -1" }}>
              Enable Sync
              <select
                value={gitSyncEnabled ? "enabled" : "disabled"}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.gitSync.enabled = event.target.value === "enabled";
                  })
                }
              >
                <option value="disabled">Disabled</option>
                <option value="enabled">Enabled</option>
              </select>
            </label>
            <label style={{ gridColumn: "1 / -1" }}>
              Git Auth Token
              <input
                type="password"
                autoComplete="new-password"
                placeholder="ghp_xxx"
                value={draftConfig.gitSync.authToken}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.gitSync.authToken = event.target.value;
                  })
                }
              />
              <span className="entry-form-hint">Stored in runtime config and used for authenticated sync against the target repo.</span>
            </label>
            <label>
              Repository
              <input
                placeholder="owner/repo or https://github.com/owner/repo.git"
                value={draftConfig.gitSync.repository}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.gitSync.repository = event.target.value;
                  })
                }
              />
            </label>
            <label>
              Push Branch
              <input
                placeholder="main"
                value={draftConfig.gitSync.branch}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.gitSync.branch = event.target.value;
                  })
                }
              />
            </label>
            <label>
              Sync Schedule
              <select
                value={syncFrequency}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.gitSync.schedule.frequency = normalizeGitSyncFrequency(event.target.value);
                  })
                }
              >
                <option value="manual">Manual only</option>
                <option value="daily">Every day</option>
                <option value="weekdays">Weekdays</option>
              </select>
            </label>
            <label>
              Sync Time
              <input
                type="time"
                disabled={syncFrequency === "manual"}
                value={normalizeTimeValue(draftConfig.gitSync.schedule.time)}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.gitSync.schedule.time = normalizeTimeValue(event.target.value, "18:00");
                  })
                }
              />
            </label>
            <label style={{ gridColumn: "1 / -1" }}>
              Conflict Strategy
              <select
                value={conflictStrategy}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.gitSync.conflictStrategy = normalizeGitSyncConflictStrategy(event.target.value);
                  })
                }
              >
                <option value="remote_wins">Remote wins (overwrite local workspace)</option>
                <option value="local_wins">Keep local changes</option>
                <option value="manual">Stop and resolve manually</option>
              </select>
              <span className="entry-form-hint">
                Default policy keeps remote as the source of truth and rewrites local workspace state on conflict.
              </span>
            </label>
            <div style={{ gridColumn: "1 / -1", display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
              <button
                type="button"
                className="btn btn-secondary btn-sm"
                onClick={runGitSyncNow}
                disabled={gitSyncRunning || !gitSyncEnabled}
              >
                {gitSyncRunning ? "Syncing..." : "Sync now"}
              </button>
              {gitSyncStatusText ? <span className="entry-form-hint">{gitSyncStatusText}</span> : null}
            </div>
          </div>
        </section>
      );
    }

    if (selectedSettings === "acp") {
      return <ACPEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />;
    }

    if (selectedSettings === "ui") {
      return <UIEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />;
    }

    if (selectedSettings === "proxy") {
      return <ProxyEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />;
    }

    if (selectedSettings === "browser") {
      return <BrowserEditor draftConfig={draftConfig} mutateDraft={mutateDraft} parseLines={parseLines} />;
    }

    if (selectedSettings === "visor") {
      return <VisorEditor draftConfig={draftConfig} mutateDraft={mutateDraft} parseLines={parseLines} />;
    }

    if (selectedSettings === "model-routing") {
      const routing = draftConfig.modelRouting || {};
      const fast = routing.fast ?? "";
      const heavy = routing.heavy ?? "";
      return (
        <section className="entry-editor-card">
          <h3>Model aliases</h3>
          <p className="placeholder-text">
            Optional shortcuts for <code>model:</code> in skill <code>SKILL.md</code> frontmatter and for{" "}
            <code>workers.spawn</code> with <code>skillId</code>. Pick a model from your configured providers (same
            catalog as agent default model). Clear removes the alias.
          </p>
          {modelRoutingCatalogStatus ? (
            <p className="placeholder-text" style={{ marginBottom: 12 }}>
              {modelRoutingCatalogStatus}
            </p>
          ) : null}
          <div className="entry-form-grid" style={{ maxWidth: 640 }}>
            <AggregatedModelPicker
              label={
                <>
                  Alias <code>fast</code> → model
                </>
              }
              value={fast}
              onChange={(id) =>
                mutateDraft((draft) => {
                  if (!draft.modelRouting) draft.modelRouting = {};
                  const v = String(id || "").trim();
                  if (!v) {
                    delete draft.modelRouting.fast;
                  } else {
                    draft.modelRouting.fast = v;
                  }
                })
              }
              aggregatedModels={modelRoutingCatalog}
            />
            <AggregatedModelPicker
              label={
                <>
                  Alias <code>heavy</code> → model
                </>
              }
              value={heavy}
              onChange={(id) =>
                mutateDraft((draft) => {
                  if (!draft.modelRouting) draft.modelRouting = {};
                  const v = String(id || "").trim();
                  if (!v) {
                    delete draft.modelRouting.heavy;
                  } else {
                    draft.modelRouting.heavy = v;
                  }
                })
              }
              aggregatedModels={modelRoutingCatalog}
            />
          </div>
          <p className="placeholder-text" style={{ marginTop: 12 }}>
            Advanced: add more keys by editing the JSON in the <strong>Config</strong> raw view — <code>modelRouting</code>{" "}
            is a flat string map.
          </p>
        </section>
      );
    }

    if (selectedSettings === "approvals") {
      return <ApprovalsView />;
    }

    if (selectedSettings === "updates") {
      return (
        <UpdatesView
          status={updateStatus}
          isChecking={isUpdateChecking}
          onForceCheck={forceUpdateCheck}
        />
      );
    }

    if (selectedSettings === "connect-client") {
      return <ClientConnectView listenPort={draftConfig.listen.port} />;
    }

    if (selectedSettings === "config") {
      return (
        <ConfigRawView
          rawConfig={rawConfig}
          savedConfig={savedConfig}
          onChange={(val) => {
            setRawConfig(val);
            try {
              const parsed = JSON.parse(val);
              const normalized = normalizeConfig(parsed);
              setDraftConfig(normalized);
              localStorage.setItem(DRAFT_CONFIG_KEY, JSON.stringify(normalized, null, 2));
            } catch {
              // keep rawConfig state even if JSON invalid
            }
          }}
        />
      );
    }

    const section = SETTINGS_ITEMS.find((item) => item.id === selectedSettings);
    return <SettingsPlaceholder title={section?.title} />;
  }

  return (
    <main className="settings-shell">
      <SettingsSidebar
        rawValid={isRawMode ? rawValid : true}
        query={query}
        onQueryChange={setQuery}
        filteredSettings={filteredSettings}
        selectedSettings={selectedSettings}
        onSelectSettings={selectSettings}
      />

      <section className="settings-main">
        <SettingsMainHeader
          hasChanges={hasManualChanges}
          statusText={statusText}
          onReload={cancelChanges}
          onSave={saveConfig}
        />

        {renderSettingsContent()}
      </section>
    </main>
  );
}

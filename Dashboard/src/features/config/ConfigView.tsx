import React, { useEffect, useMemo, useRef, useState } from "react";
import { fetchOpenAIModels, fetchOpenAIProviderStatus, fetchRuntimeConfig, updateRuntimeConfig } from "../../api";
import { NodeHostEditor } from "./components/NodeHostEditor";
import { PluginEditor } from "./components/PluginEditor";
import { ProviderEditor } from "./components/ProviderEditor";
import { SettingsMainHeader } from "./components/SettingsMainHeader";
import { SettingsPlaceholder } from "./components/SettingsPlaceholder";
import { SettingsSidebar } from "./components/SettingsSidebar";
import { TelegramEditor } from "./components/TelegramEditor";

const SETTINGS_ITEMS = [
  { id: "providers", title: "Providers", icon: "hub" },
  { id: "channels", title: "Channels", icon: "forum" },
  { id: "approvals", title: "Approvals", icon: "fact_check" },
  { id: "plugins", title: "Plugins", icon: "extension" },
  { id: "browser", title: "Browser", icon: "open_in_browser" },
  { id: "ui", title: "UI", icon: "palette" },
  { id: "nodehost", title: "NodeHost", icon: "dns" },
  { id: "bindings", title: "Bindings", icon: "cable" },
  { id: "broadcast", title: "Broadcast", icon: "cell_tower" },
  { id: "audio", title: "Audio", icon: "volume_up" },
  { id: "media", title: "Media", icon: "perm_media" },
  { id: "session", title: "Session", icon: "manage_accounts" },
  { id: "git-sync", title: "Git Sync", icon: "sync" },
  { id: "logging", title: "Logging", icon: "description" }
];

const GIT_SYNC_FREQUENCIES = new Set(["manual", "daily", "weekdays"]);
const GIT_SYNC_CONFLICT_STRATEGIES = new Set(["remote_wins", "local_wins", "manual"]);

const PROVIDER_CATALOG = [
  {
    id: "openai-api",
    title: "OpenAI API",
    description: "OpenAI via API key authentication.",
    modelHint: "gpt-4.1-mini",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openai-api",
      apiKey: "",
      apiUrl: "https://api.openai.com/v1",
      model: "gpt-4.1-mini"
    }
  },
  {
    id: "openai-oauth",
    title: "OpenAI OAuth",
    description: "OpenAI via OAuth/Codex deeplink.",
    modelHint: "gpt-4.1-mini",
    authMethod: "deeplink",
    requiresApiKey: false,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openai-oauth",
      apiKey: "",
      apiUrl: "https://api.openai.com/v1",
      model: "gpt-4.1-mini"
    }
  },
  {
    id: "ollama",
    title: "Ollama",
    description: "Local provider served by Ollama.",
    modelHint: "qwen3",
    authMethod: "none",
    requiresApiKey: false,
    supportsModelCatalog: false,
    defaultEntry: {
      title: "ollama-local",
      apiKey: "",
      apiUrl: "http://127.0.0.1:11434",
      model: "qwen3"
    }
  }
];

function emptyModel() {
  return {
    title: "openai-api",
    apiKey: "",
    apiUrl: "https://api.openai.com/v1",
    model: "gpt-4.1-mini"
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

const EMPTY_CONFIG = {
  listen: { host: "0.0.0.0", port: 25101 },
  workspace: { name: "workspace", basePath: "~" },
  auth: { token: "dev-token" },
  models: [emptyModel()],
  memory: {
    backend: "sqlite-local-vectors",
    provider: {
      mode: "local",
      endpoint: "",
      mcpServer: "",
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
    }
  },
  nodes: ["local"],
  gateways: [],
  plugins: [],
  channels: { telegram: null },
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
  sqlitePath: "core.sqlite"
};

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function normalizeModel(item, index) {
  if (typeof item === "string") {
    const [provider, name] = item.includes(":") ? item.split(":", 2) : ["", item];
    return {
      title: provider ? `${provider}-${name}` : name || `model-${index + 1}`,
      apiKey: "",
      apiUrl: provider === "openai" ? "https://api.openai.com/v1" : provider === "ollama" ? "http://127.0.0.1:11434" : "",
      model: name || item
    };
  }

  return {
    title: item?.title || `model-${index + 1}`,
    apiKey: item?.apiKey || "",
    apiUrl: item?.apiUrl || "",
    model: item?.model || ""
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

  if (apiUrl.includes("ollama") || apiUrl.includes("11434") || title.includes("ollama")) {
    return "ollama";
  }

  return "custom";
}

function isOpenAIOAuthEntry(model) {
  const title = String(model?.title || "").toLowerCase();
  return title.includes("oauth") || title.includes("deeplink");
}

function findProviderModelIndex(models, providerId) {
  if (providerId === "openai-api") {
    return models.findIndex((item) => inferModelProvider(item) === "openai" && !isOpenAIOAuthEntry(item));
  }
  if (providerId === "openai-oauth") {
    return models.findIndex((item) => inferModelProvider(item) === "openai" && isOpenAIOAuthEntry(item));
  }
  if (providerId === "ollama") {
    return models.findIndex((item) => inferModelProvider(item) === "ollama");
  }
  return -1;
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

function normalizeConfig(config) {
  const normalized = clone(EMPTY_CONFIG);

  normalized.listen.host = config?.listen?.host || normalized.listen.host;
  normalized.listen.port = parseInteger(config?.listen?.port ?? normalized.listen.port, normalized.listen.port);
  normalized.workspace.name = config?.workspace?.name || normalized.workspace.name;
  normalized.workspace.basePath = config?.workspace?.basePath || normalized.workspace.basePath;
  normalized.auth.token = config?.auth?.token || normalized.auth.token;
  normalized.memory.backend = config?.memory?.backend || normalized.memory.backend;
  normalized.memory.provider.mode = String(config?.memory?.provider?.mode || normalized.memory.provider.mode);
  normalized.memory.provider.endpoint = String(config?.memory?.provider?.endpoint || "");
  normalized.memory.provider.mcpServer = String(config?.memory?.provider?.mcpServer || "");
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
  normalized.sqlitePath = config?.sqlitePath || normalized.sqlitePath;
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

  const models = Array.isArray(config?.models) ? config.models : [];
  normalized.models = models.map(normalizeModel);
  if (normalized.models.length === 0) {
    normalized.models.push(clone(PROVIDER_CATALOG[0].defaultEntry));
  }

  const plugins = Array.isArray(config?.plugins) ? config.plugins : [];
  normalized.plugins = plugins.map(normalizePlugin);

  const tg = config?.channels?.telegram;
  if (tg && typeof tg === "object") {
    normalized.channels = {
      telegram: {
        botToken: String(tg.botToken || ""),
        channelChatMap: tg.channelChatMap && typeof tg.channelChatMap === "object" ? tg.channelChatMap : {},
        allowedUserIds: Array.isArray(tg.allowedUserIds) ? tg.allowedUserIds : [],
        allowedChatIds: Array.isArray(tg.allowedChatIds) ? tg.allowedChatIds : []
      }
    };
  } else {
    normalized.channels = { telegram: null };
  }

  return normalized;
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

function isSettingsSection(id) {
  return SETTINGS_ITEMS.some((item) => item.id === id);
}

function normalizeSearch(value) {
  return String(value || "").trim().toLowerCase();
}

function filterProviderModels(models, query) {
  const needle = normalizeSearch(query);
  if (!needle) {
    return models;
  }

  return [...models]
    .map((model) => {
      const id = normalizeSearch(model?.id);
      const title = normalizeSearch(model?.title);
      const idIndex = id.indexOf(needle);
      const titleIndex = title.indexOf(needle);
      const rank = Math.min(idIndex >= 0 ? idIndex : Number.MAX_SAFE_INTEGER, titleIndex >= 0 ? titleIndex : Number.MAX_SAFE_INTEGER);
      return { model, rank };
    })
    .filter((item) => item.rank !== Number.MAX_SAFE_INTEGER)
    .sort((left, right) => {
      if (left.rank !== right.rank) {
        return left.rank - right.rank;
      }
      return String(left.model?.id || "").localeCompare(String(right.model?.id || ""));
    })
    .map((item) => item.model);
}

export function ConfigView({ sectionId = "providers", onSectionChange = null }) {
  const initialSectionId = isSettingsSection(sectionId) ? sectionId : "providers";
  const [mode, setMode] = useState("form");
  const [query, setQuery] = useState("");
  const [selectedSettings, setSelectedSettings] = useState(initialSectionId);
  const [draftConfig, setDraftConfig] = useState(clone(EMPTY_CONFIG));
  const [savedConfig, setSavedConfig] = useState(clone(EMPTY_CONFIG));
  const [rawConfig, setRawConfig] = useState(JSON.stringify(EMPTY_CONFIG, null, 2));
  const [statusText, setStatusText] = useState("Loading config...");
  const [selectedPluginIndex, setSelectedPluginIndex] = useState(0);
  const [providerModalId, setProviderModalId] = useState(null);
  const [providerForm, setProviderForm] = useState(null);
  const [providerModelOptions, setProviderModelOptions] = useState({});
  const [providerModelStatus, setProviderModelStatus] = useState({});
  const [providerModelMenuOpen, setProviderModelMenuOpen] = useState(false);
  const [providerModelMenuRect, setProviderModelMenuRect] = useState(null);
  const [openAIProviderStatus, setOpenAIProviderStatus] = useState({
    hasEnvironmentKey: false,
    hasConfiguredKey: false,
    hasAnyKey: false
  });
  const providerModelLoadTimerRef = useRef(null);
  const providerModelLoadTokenRef = useRef(0);
  const providerModelPickerRef = useRef(null);
  const providerModelMenuRef = useRef(null);

  useEffect(() => {
    loadConfig().catch(() => {
      setStatusText("Failed to load config");
    });
  }, []);

  useEffect(() => {
    if (selectedPluginIndex >= draftConfig.plugins.length) {
      setSelectedPluginIndex(Math.max(0, draftConfig.plugins.length - 1));
    }
  }, [draftConfig.plugins.length, selectedPluginIndex]);

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

  const hasChanges = useMemo(() => {
    if (mode === "raw") {
      return rawConfig !== JSON.stringify(savedConfig, null, 2);
    }
    return JSON.stringify(draftConfig) !== JSON.stringify(savedConfig);
  }, [mode, rawConfig, draftConfig, savedConfig]);

  const rawValid = useMemo(() => {
    if (mode !== "raw") {
      return true;
    }
    try {
      JSON.parse(rawConfig);
      return true;
    } catch {
      return false;
    }
  }, [mode, rawConfig]);

  const providerModalMeta = useMemo(() => {
    if (!providerModalId) {
      return null;
    }
    return getProviderDefinition(providerModalId);
  }, [providerModalId]);

  const customModelsCount = useMemo(() => {
    const providerIndexes = new Set(
      PROVIDER_CATALOG.map((provider) => findProviderModelIndex(draftConfig.models, provider.id)).filter((index) => index >= 0)
    );
    return draftConfig.models.filter((_, index) => !providerIndexes.has(index)).length;
  }, [draftConfig.models]);

  async function loadConfig() {
    const config = await fetchRuntimeConfig();
    if (!config) {
      setStatusText("Failed to load config");
      return;
    }

    const normalized = normalizeConfig(config);

    setDraftConfig(normalized);
    setSavedConfig(normalized);
    setRawConfig(JSON.stringify(normalized, null, 2));
    setProviderModalId(null);
    setProviderForm(null);
    setProviderModelOptions({});
    setProviderModelStatus({});
    await loadOpenAIProviderStatus();
    setStatusText("Config loaded");
  }

  async function saveConfig() {
    try {
      const payload = mode === "raw" ? normalizeConfig(JSON.parse(rawConfig)) : draftConfig;
      const response = await updateRuntimeConfig(payload);
      if (!response) {
        setStatusText("Failed to save config");
        return;
      }

      const normalized = normalizeConfig(response);

      setDraftConfig(normalized);
      setSavedConfig(normalized);
      setRawConfig(JSON.stringify(normalized, null, 2));
      await loadOpenAIProviderStatus();
      setStatusText("Config saved");
    } catch {
      setStatusText("Invalid raw JSON");
    }
  }

  async function loadOpenAIProviderStatus() {
    const response = await fetchOpenAIProviderStatus();
    if (!response) {
      return;
    }

    setOpenAIProviderStatus({
      hasEnvironmentKey: Boolean(response.hasEnvironmentKey),
      hasConfiguredKey: Boolean(response.hasConfiguredKey),
      hasAnyKey: Boolean(response.hasAnyKey)
    });
  }

  function mutateDraft(mutator) {
    setDraftConfig((previous) => {
      const next = clone(previous);
      mutator(next);
      setRawConfig(JSON.stringify(next, null, 2));
      return next;
    });
  }

  function openCodexOpenAIDeepLink() {
    window.location.href = "codex://auth/openai?source=sloppy";
    setProviderStatus("openai-oauth", "Codex deeplink opened. Complete auth there; model catalog will update automatically.");
  }

  function setProviderStatus(providerId, message) {
    setProviderModelStatus((previous) => ({
      ...previous,
      [providerId]: message
    }));
  }

  function openProviderModal(providerId) {
    const provider = getProviderDefinition(providerId);
    const existing = getProviderEntry(draftConfig.models, provider.id)?.entry;
    const initial = existing ? clone(existing) : clone(provider.defaultEntry);

    setProviderModalId(provider.id);
    setProviderForm({
      apiKey: initial.apiKey,
      apiUrl: initial.apiUrl,
      model: initial.model
    });
    setProviderModelMenuOpen(false);
  }

  function closeProviderModal() {
    if (providerModelLoadTimerRef.current) {
      clearTimeout(providerModelLoadTimerRef.current);
      providerModelLoadTimerRef.current = null;
    }
    setProviderModalId(null);
    setProviderForm(null);
    setProviderModelMenuOpen(false);
    setProviderModelMenuRect(null);
  }

  function updateProviderForm(field, value) {
    setProviderForm((previous) => {
      if (!previous) {
        return previous;
      }
      return {
        ...previous,
        [field]: value
      };
    });

    if (field === "model") {
      setProviderModelMenuOpen(true);
    }
  }

  async function loadProviderModels(providerId, entryOverride = null) {
    const provider = getProviderDefinition(providerId);
    if (!provider.supportsModelCatalog) {
      return;
    }

    const entryFromConfig = getProviderEntry(draftConfig.models, provider.id)?.entry || provider.defaultEntry;
    const entry = entryOverride || entryFromConfig;
    setProviderStatus(provider.id, "Loading provider models...");

    const response = await fetchOpenAIModels({
      authMethod: provider.authMethod,
      apiKey: provider.authMethod === "api_key" ? entry.apiKey : undefined,
      apiUrl: entry.apiUrl || provider.defaultEntry.apiUrl
    });

    if (!response) {
      setProviderStatus(provider.id, "Failed to load models from Core");
      return;
    }

    const payload = response as any;
    const models = Array.isArray(payload.models) ? payload.models : [];

    setProviderModelOptions((previous) => ({
      ...previous,
      [provider.id]: models
    }));

    if (payload.warning) {
      setProviderStatus(provider.id, payload.warning);
    } else if (payload.source === "remote") {
      setProviderStatus(provider.id, `Loaded ${models.length} models from OpenAI`);
    } else {
      setProviderStatus(provider.id, `Loaded fallback catalog (${models.length} models)`);
    }

    if (provider.id === "openai-api" || provider.id === "openai-oauth") {
      setOpenAIProviderStatus((previous) => ({
        ...previous,
        hasEnvironmentKey: Boolean(payload.usedEnvironmentKey),
        hasAnyKey: previous.hasConfiguredKey || Boolean(payload.usedEnvironmentKey)
      }));
    }
  }

  useEffect(() => {
    if (!providerModalMeta || !providerForm || !providerModalMeta.supportsModelCatalog) {
      return;
    }

    const provider = providerModalMeta;
    const hasEnvironmentKeyForOpenAI = provider.id === "openai-api" && openAIProviderStatus.hasEnvironmentKey;
    const requiresApiKey = provider.authMethod === "api_key";
    const hasKey = Boolean(String(providerForm.apiKey || "").trim()) || hasEnvironmentKeyForOpenAI;

    if (requiresApiKey && !hasKey) {
      setProviderStatus(provider.id, "Set API Key to load models.");
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
        setProviderStatus(provider.id, "Failed to load models from Core");
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
    providerForm?.apiKey,
    providerForm?.apiUrl,
    openAIProviderStatus.hasEnvironmentKey
  ]);

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

  function saveProviderFromModal() {
    if (!providerModalMeta || !providerForm) {
      return;
    }

    const provider = providerModalMeta;
    const nextEntry = {
      title: provider.defaultEntry.title,
      apiKey: provider.requiresApiKey ? providerForm.apiKey.trim() : "",
      apiUrl: providerForm.apiUrl.trim() || provider.defaultEntry.apiUrl,
      model: providerForm.model.trim() || provider.defaultEntry.model
    };

    mutateDraft((draft) => {
      const index = findProviderModelIndex(draft.models, provider.id);
      if (index >= 0) {
        draft.models[index] = nextEntry;
      } else {
        draft.models.push(nextEntry);
      }
    });

    setStatusText(`${provider.title} updated in draft`);
    closeProviderModal();
  }

  function removeProviderFromModal() {
    if (!providerModalMeta) {
      return;
    }

    const provider = providerModalMeta;
    mutateDraft((draft) => {
      const index = findProviderModelIndex(draft.models, provider.id);
      if (index >= 0) {
        draft.models.splice(index, 1);
      }
    });

    setStatusText(`${provider.title} removed from draft`);
    closeProviderModal();
  }

  function renderSettingsContent() {
    if (selectedSettings === "providers") {
      return (
        <ProviderEditor
          providerCatalog={PROVIDER_CATALOG}
          draftConfig={draftConfig}
          customModelsCount={customModelsCount}
          openAIProviderStatus={openAIProviderStatus}
          providerModalMeta={providerModalMeta}
          providerForm={providerForm}
          providerModelStatus={providerModelStatus}
          providerModelOptions={providerModelOptions}
          providerModelMenuOpen={providerModelMenuOpen}
          providerModelMenuRect={providerModelMenuRect}
          providerModelPickerRef={providerModelPickerRef}
          providerModelMenuRef={providerModelMenuRef}
          onOpenProviderModal={openProviderModal}
          onCloseProviderModal={closeProviderModal}
          onUpdateProviderForm={updateProviderForm}
          onOpenOAuth={openCodexOpenAIDeepLink}
          onRemoveProvider={removeProviderFromModal}
          onSaveProvider={saveProviderFromModal}
          onSetProviderModelMenuOpen={setProviderModelMenuOpen}
          onSetProviderModelMenuRect={setProviderModelMenuRect}
          getProviderEntry={getProviderEntry}
          providerIsConfigured={providerIsConfigured}
          filterProviderModels={filterProviderModels}
        />
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
    if (selectedSettings === "nodehost") {
      return <NodeHostEditor draftConfig={draftConfig} mutateDraft={mutateDraft} parseLines={parseLines} />;
    }
    if (selectedSettings === "channels") {
      return (
        <div className="tg-settings-shell">
          <TelegramEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />
        </div>
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
          </div>
        </section>
      );
    }

    const section = SETTINGS_ITEMS.find((item) => item.id === selectedSettings);
    return <SettingsPlaceholder title={section?.title} />;
  }

  return (
    <main className="settings-shell">
      <SettingsSidebar
        rawValid={rawValid}
        query={query}
        onQueryChange={setQuery}
        filteredSettings={filteredSettings}
        selectedSettings={selectedSettings}
        onSelectSettings={selectSettings}
        mode={mode}
        onModeChange={setMode}
      />

      <section className="settings-main">
        <SettingsMainHeader hasChanges={hasChanges} statusText={statusText} onReload={loadConfig} onSave={saveConfig} />

        {mode === "raw" ? (
          <textarea className="settings-raw-editor" value={rawConfig} onChange={(event) => setRawConfig(event.target.value)} />
        ) : (
          renderSettingsContent()
        )}
      </section>
    </main>
  );
}

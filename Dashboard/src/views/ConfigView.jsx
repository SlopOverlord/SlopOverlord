import React, { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { fetchOpenAIModels, fetchOpenAIProviderStatus, fetchRuntimeConfig, updateRuntimeConfig } from "../api";

const SETTINGS_ITEMS = [
  { id: "logging", title: "Logging", icon: "LG" },
  { id: "browser", title: "Browser", icon: "BR" },
  { id: "ui", title: "Ui", icon: "UI" },
  { id: "providers", title: "Providers", icon: "PR" },
  { id: "nodehost", title: "NodeHost", icon: "NH" },
  { id: "bindings", title: "Bindings", icon: "BD" },
  { id: "broadcast", title: "Broadcast", icon: "BC" },
  { id: "audio", title: "Audio", icon: "AU" },
  { id: "media", title: "Media", icon: "ME" },
  { id: "approvals", title: "Approvals", icon: "AP" },
  { id: "session", title: "Session", icon: "SS" },
  { id: "plugins", title: "Plugins", icon: "PL" }
];

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
  memory: { backend: "sqlite-local-vectors" },
  nodes: ["local"],
  gateways: [],
  plugins: [],
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
  normalized.listen.port = Number.parseInt(String(config?.listen?.port ?? normalized.listen.port), 10) || normalized.listen.port;
  normalized.workspace.name = config?.workspace?.name || normalized.workspace.name;
  normalized.workspace.basePath = config?.workspace?.basePath || normalized.workspace.basePath;
  normalized.auth.token = config?.auth?.token || normalized.auth.token;
  normalized.memory.backend = config?.memory?.backend || normalized.memory.backend;
  normalized.sqlitePath = config?.sqlitePath || normalized.sqlitePath;

  normalized.nodes = Array.isArray(config?.nodes) ? config.nodes.filter(Boolean) : [];
  normalized.gateways = Array.isArray(config?.gateways) ? config.gateways.filter(Boolean) : [];

  const models = Array.isArray(config?.models) ? config.models : [];
  normalized.models = models.map(normalizeModel);
  if (normalized.models.length === 0) {
    normalized.models.push(clone(PROVIDER_CATALOG[0].defaultEntry));
  }

  const plugins = Array.isArray(config?.plugins) ? config.plugins : [];
  normalized.plugins = plugins.map(normalizePlugin);

  return normalized;
}

function parseLines(value) {
  return value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
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

  useEffect(() => {
    if (typeof onSectionChange !== "function") {
      return;
    }
    if (selectedSettings !== sectionId) {
      onSectionChange(selectedSettings);
    }
  }, [onSectionChange, selectedSettings, sectionId]);

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
    window.location.href = "codex://auth/openai?source=slopoverlord";
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

    setProviderModelOptions((previous) => ({
      ...previous,
      [provider.id]: Array.isArray(response.models) ? response.models : []
    }));

    if (response.warning) {
      setProviderStatus(provider.id, response.warning);
    } else if (response.source === "remote") {
      setProviderStatus(provider.id, `Loaded ${response.models.length} models from OpenAI`);
    } else {
      setProviderStatus(provider.id, `Loaded fallback catalog (${response.models.length} models)`);
    }

    if (provider.id === "openai-api" || provider.id === "openai-oauth") {
      setOpenAIProviderStatus((previous) => ({
        ...previous,
        hasEnvironmentKey: Boolean(response.usedEnvironmentKey),
        hasAnyKey: previous.hasConfiguredKey || Boolean(response.usedEnvironmentKey)
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

  function renderProviderEditor() {
    const activeProviderStatus = providerModalMeta ? providerModelStatus[providerModalMeta.id] : "";
    const activeProviderModels = providerModalMeta ? providerModelOptions[providerModalMeta.id] || [] : [];
    const activeProviderEntry = providerModalMeta ? getProviderEntry(draftConfig.models, providerModalMeta.id) : null;
    const filteredProviderModels = filterProviderModels(activeProviderModels, providerForm?.model);

    return (
      <div className="providers-shell">
        <section className="entry-editor-card">
          <h3>Providers</h3>
          <p className="placeholder-text">Choose a provider to configure API key and model in a modal dialog.</p>
          {customModelsCount > 0 ? (
            <p className="placeholder-text">
              Config has {customModelsCount} custom model entries. They are preserved and available in raw mode.
            </p>
          ) : null}
        </section>

        <section className="providers-grid">
          {PROVIDER_CATALOG.map((provider) => {
            const providerEntry = getProviderEntry(draftConfig.models, provider.id)?.entry;
            const entryModel = String(providerEntry?.model || provider.defaultEntry.model || "").trim();
            const entryURL = String(providerEntry?.apiUrl || provider.defaultEntry.apiUrl || "").trim();
            const configuredViaEnvironment =
              provider.id === "openai-api" &&
              openAIProviderStatus.hasEnvironmentKey &&
              !Boolean(String(providerEntry?.apiKey || "").trim()) &&
              Boolean(entryModel && entryURL);
            const configured = configuredViaEnvironment || providerIsConfigured(provider, providerEntry);
            const actionText = configured ? "Configure" : provider.requiresApiKey ? "Add Key" : "Setup";
            const configuredBadgeText = configuredViaEnvironment ? "env" : configured ? "configured" : "not set";

            return (
              <button
                key={provider.id}
                type="button"
                className={`provider-card ${configured ? "configured" : ""}`}
                onClick={() => openProviderModal(provider.id)}
              >
                <div className="provider-card-head">
                  <h4>{provider.title}</h4>
                  <span className={`provider-state ${configured ? "on" : "off"}`}>{configuredBadgeText}</span>
                </div>
                <p>{provider.description}</p>
                <span className="provider-model-line">
                  Model: {providerEntry?.model || provider.modelHint}
                </span>
                <span className="provider-card-action">{actionText}</span>
              </button>
            );
          })}
        </section>

        {providerModalMeta && providerForm ? (
          <div className="provider-modal-overlay" onClick={closeProviderModal}>
            <section className="provider-modal-card" onClick={(event) => event.stopPropagation()}>
              <div className="provider-modal-head">
                <h3>{providerModalMeta.title}</h3>
                <button type="button" className="provider-close-button" onClick={closeProviderModal}>
                  x
                </button>
              </div>
              <p className="placeholder-text">{providerModalMeta.description}</p>

              <div className="provider-modal-form">
                {providerModalMeta.requiresApiKey ? (
                  <label>
                    API Key
                    <input
                      type="password"
                      value={providerForm.apiKey}
                      onChange={(event) => updateProviderForm("apiKey", event.target.value)}
                      placeholder="sk-..."
                    />
                    {providerModalMeta.id === "openai-api" && openAIProviderStatus.hasEnvironmentKey ? (
                      <span className="placeholder-text">Using OPENAI_API_KEY from Core environment.</span>
                    ) : null}
                  </label>
                ) : null}

                <label>
                  API URL
                  <input value={providerForm.apiUrl} onChange={(event) => updateProviderForm("apiUrl", event.target.value)} />
                </label>

                <label>
                  Model
                  <div ref={providerModelPickerRef} className="provider-model-picker">
                    <input
                      value={providerForm.model}
                      onFocus={() => setProviderModelMenuOpen(true)}
                      onClick={() => setProviderModelMenuOpen(true)}
                      onChange={(event) => updateProviderForm("model", event.target.value)}
                      placeholder="Select model id..."
                    />
                  </div>
                </label>
              </div>

              {providerModalMeta.supportsModelCatalog ? (
                <div className="provider-modal-catalog">
                  <p className="placeholder-text">{activeProviderStatus || "Model catalog is loading automatically."}</p>
                  {providerModalMeta.id === "openai-oauth" ? (
                    <div className="provider-modal-actions">
                      <button type="button" onClick={openCodexOpenAIDeepLink}>
                        Open OAuth in Codex
                      </button>
                    </div>
                  ) : null}
                </div>
              ) : null}
              <div className="provider-modal-footer">
                {activeProviderEntry ? (
                  <button type="button" className="danger" onClick={removeProviderFromModal}>
                    Remove Provider
                  </button>
                ) : (
                  <span />
                )}
                <div className="provider-modal-footer-actions">
                  <button type="button" onClick={closeProviderModal}>
                    Cancel
                  </button>
                  <button type="button" onClick={saveProviderFromModal}>
                    Save Provider
                  </button>
                </div>
              </div>
            </section>
          </div>
        ) : null}
        {providerModalMeta && providerForm && providerModelMenuOpen && filteredProviderModels.length > 0 && providerModelMenuRect
          ? createPortal(
              <div
                ref={providerModelMenuRef}
                className="provider-model-picker-menu provider-model-picker-menu-floating"
                style={{
                  top: `${providerModelMenuRect.top}px`,
                  left: `${providerModelMenuRect.left}px`,
                  width: `${providerModelMenuRect.width}px`
                }}
              >
                <div className="provider-model-picker-group">{providerModalMeta.title}</div>
                <div className="provider-model-options" style={{ maxHeight: `${providerModelMenuRect.maxHeight}px` }}>
                  {filteredProviderModels.map((model) => (
                    <button
                      key={model.id}
                      type="button"
                      className={`provider-model-option ${providerForm.model === model.id ? "active" : ""}`}
                      onMouseDown={(event) => event.preventDefault()}
                      onClick={() => {
                        updateProviderForm("model", model.id);
                        setProviderModelMenuOpen(false);
                        setProviderModelMenuRect(null);
                      }}
                    >
                      <div className="provider-model-option-main">
                        <strong>{model.title || model.id}</strong>
                        {model.contextWindow ? <span className="provider-model-context">{model.contextWindow}</span> : null}
                      </div>
                      <span>{model.id}</span>
                      {Array.isArray(model.capabilities) && model.capabilities.length > 0 ? (
                        <div className="provider-model-capabilities">
                          {model.capabilities.map((capability) => (
                            <span key={`${model.id}-${capability}`}>{capability}</span>
                          ))}
                        </div>
                      ) : null}
                    </button>
                  ))}
                </div>
              </div>,
              document.body
            )
          : null}
      </div>
    );
  }

  function renderPluginEditor() {
    const current = draftConfig.plugins[selectedPluginIndex] || emptyPlugin();

    return (
      <div className="entry-editor-layout">
        <div className="entry-list">
          <div className="entry-list-head">
            <h4>Plugin entries</h4>
            <button
              type="button"
              onClick={() => {
                mutateDraft((draft) => {
                  draft.plugins.push(emptyPlugin());
                });
                setSelectedPluginIndex(draftConfig.plugins.length);
              }}
            >
              + Add Entry
            </button>
          </div>
          <div className="entry-list-scroll">
            {draftConfig.plugins.map((item, index) => (
              <button
                key={`${item.title}-${index}`}
                type="button"
                className={`entry-list-item ${index === selectedPluginIndex ? "active" : ""}`}
                onClick={() => setSelectedPluginIndex(index)}
              >
                {item.title || `plugin-${index + 1}`}
              </button>
            ))}
          </div>
        </div>

        <section className="entry-editor-card">
          <div className="entry-editor-head">
            <h3>{current.title || "Plugin entry"}</h3>
            <button
              type="button"
              className="danger"
              onClick={() => {
                mutateDraft((draft) => {
                  draft.plugins.splice(selectedPluginIndex, 1);
                });
              }}
            >
              Delete
            </button>
          </div>

          <div className="entry-form-grid">
            <label>
              Title
              <input
                value={current.title}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    if (!draft.plugins[selectedPluginIndex]) {
                      draft.plugins[selectedPluginIndex] = emptyPlugin();
                    }
                    draft.plugins[selectedPluginIndex].title = event.target.value;
                  })
                }
              />
            </label>
            <label>
              Plugin
              <input
                value={current.plugin}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    if (!draft.plugins[selectedPluginIndex]) {
                      draft.plugins[selectedPluginIndex] = emptyPlugin();
                    }
                    draft.plugins[selectedPluginIndex].plugin = event.target.value;
                  })
                }
              />
            </label>
            <label>
              API URL
              <input
                value={current.apiUrl}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    if (!draft.plugins[selectedPluginIndex]) {
                      draft.plugins[selectedPluginIndex] = emptyPlugin();
                    }
                    draft.plugins[selectedPluginIndex].apiUrl = event.target.value;
                  })
                }
              />
            </label>
            <label>
              API Key
              <input
                value={current.apiKey}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    if (!draft.plugins[selectedPluginIndex]) {
                      draft.plugins[selectedPluginIndex] = emptyPlugin();
                    }
                    draft.plugins[selectedPluginIndex].apiKey = event.target.value;
                  })
                }
              />
            </label>
          </div>
        </section>
      </div>
    );
  }

  function renderNodeHostEditor() {
    return (
      <section className="entry-editor-card">
        <h3>NodeHost & Runtime</h3>
        <div className="entry-form-grid">
          <label>
            Listen Host
            <input
              value={draftConfig.listen.host}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.listen.host = event.target.value;
                })
              }
            />
          </label>
          <label>
            Listen Port
            <input
              value={String(draftConfig.listen.port)}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.listen.port = Number.parseInt(event.target.value, 10) || 25101;
                })
              }
            />
          </label>
          <label>
            Workspace Name
            <input
              value={draftConfig.workspace.name}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.workspace.name = event.target.value;
                })
              }
            />
          </label>
          <label>
            Workspace Base Path
            <input
              value={draftConfig.workspace.basePath}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.workspace.basePath = event.target.value;
                })
              }
            />
          </label>
          <label>
            Auth Token
            <input
              value={draftConfig.auth.token}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.auth.token = event.target.value;
                })
              }
            />
          </label>
          <label>
            Memory Backend
            <input
              value={draftConfig.memory.backend}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.memory.backend = event.target.value;
                })
              }
            />
          </label>
          <label>
            SQLite Path
            <input
              value={draftConfig.sqlitePath}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.sqlitePath = event.target.value;
                })
              }
            />
          </label>
          <label>
            Nodes (one per line)
            <textarea
              rows={4}
              value={draftConfig.nodes.join("\n")}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.nodes = parseLines(event.target.value);
                })
              }
            />
          </label>
          <label>
            Gateways (one per line)
            <textarea
              rows={4}
              value={draftConfig.gateways.join("\n")}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.gateways = parseLines(event.target.value);
                })
              }
            />
          </label>
        </div>
      </section>
    );
  }

  function renderSettingsContent() {
    if (selectedSettings === "providers") {
      return renderProviderEditor();
    }
    if (selectedSettings === "plugins") {
      return renderPluginEditor();
    }
    if (selectedSettings === "nodehost") {
      return renderNodeHostEditor();
    }

    const section = SETTINGS_ITEMS.find((item) => item.id === selectedSettings);
    return (
      <section className="entry-editor-card">
        <h3>{section?.title || "Settings section"}</h3>
        <p className="placeholder-text">
          This section is wired in the config navigation and can be implemented incrementally with dedicated view logic.
        </p>
      </section>
    );
  }

  return (
    <main className="settings-shell">
      <aside className="settings-side">
        <div className="settings-title-row">
          <h2>Settings</h2>
          <span className={`settings-valid ${rawValid ? "ok" : "bad"}`}>{rawValid ? "valid" : "invalid"}</span>
        </div>

        <input
          className="settings-search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search settings..."
        />

        <div className="settings-nav">
          {filteredSettings.map((item) => (
            <button
              key={item.id}
              type="button"
              className={`settings-nav-item ${selectedSettings === item.id ? "active" : ""}`}
              onClick={() => setSelectedSettings(item.id)}
            >
              <span>{item.icon}</span>
              <span>{item.title}</span>
            </button>
          ))}
        </div>

        <div className="settings-mode-switch">
          <button type="button" className={mode === "form" ? "active" : ""} onClick={() => setMode("form")}>
            Form
          </button>
          <button type="button" className={mode === "raw" ? "active" : ""} onClick={() => setMode("raw")}>
            Raw
          </button>
        </div>
      </aside>

      <section className="settings-main">
        <header className="settings-main-head">
          <div className="settings-main-status">
            <strong>{hasChanges ? "Unsaved changes" : "No changes"}</strong>
            <span>{statusText}</span>
          </div>

          <div className="settings-main-actions">
            <button type="button" onClick={() => loadConfig()}>
              Reload
            </button>
            <button type="button" onClick={() => saveConfig()}>
              Save
            </button>
            <button type="button" onClick={() => saveConfig()}>
              Apply
            </button>
            <button type="button" onClick={() => loadConfig()}>
              Update
            </button>
          </div>
        </header>

        {mode === "raw" ? (
          <textarea className="settings-raw-editor" value={rawConfig} onChange={(event) => setRawConfig(event.target.value)} />
        ) : (
          renderSettingsContent()
        )}
      </section>
    </main>
  );
}

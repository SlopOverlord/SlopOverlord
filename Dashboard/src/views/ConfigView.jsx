import React, { useEffect, useMemo, useState } from "react";
import { fetchRuntimeConfig, updateRuntimeConfig } from "../api";

const SETTINGS_ITEMS = [
  { id: "logging", title: "Logging", icon: "LG" },
  { id: "browser", title: "Browser", icon: "BR" },
  { id: "ui", title: "Ui", icon: "UI" },
  { id: "models", title: "Models", icon: "MD" },
  { id: "nodehost", title: "NodeHost", icon: "NH" },
  { id: "bindings", title: "Bindings", icon: "BD" },
  { id: "broadcast", title: "Broadcast", icon: "BC" },
  { id: "audio", title: "Audio", icon: "AU" },
  { id: "media", title: "Media", icon: "ME" },
  { id: "approvals", title: "Approvals", icon: "AP" },
  { id: "session", title: "Session", icon: "SS" },
  { id: "plugins", title: "Plugins", icon: "PL" }
];

function emptyModel() {
  return {
    title: "new-model",
    apiKey: "",
    apiUrl: "",
    model: ""
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
  auth: { token: "dev-token" },
  models: [emptyModel()],
  memory: { backend: "sqlite-local-vectors" },
  nodes: ["local"],
  gateways: [],
  plugins: [],
  sqlitePath: "./.data/core.sqlite"
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
  normalized.auth.token = config?.auth?.token || normalized.auth.token;
  normalized.memory.backend = config?.memory?.backend || normalized.memory.backend;
  normalized.sqlitePath = config?.sqlitePath || normalized.sqlitePath;

  normalized.nodes = Array.isArray(config?.nodes) ? config.nodes.filter(Boolean) : [];
  normalized.gateways = Array.isArray(config?.gateways) ? config.gateways.filter(Boolean) : [];

  const models = Array.isArray(config?.models) ? config.models : [];
  normalized.models = models.map(normalizeModel);
  if (normalized.models.length === 0) {
    normalized.models.push(emptyModel());
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

export function ConfigView() {
  const [mode, setMode] = useState("form");
  const [query, setQuery] = useState("");
  const [selectedSettings, setSelectedSettings] = useState("models");
  const [draftConfig, setDraftConfig] = useState(clone(EMPTY_CONFIG));
  const [savedConfig, setSavedConfig] = useState(clone(EMPTY_CONFIG));
  const [rawConfig, setRawConfig] = useState(JSON.stringify(EMPTY_CONFIG, null, 2));
  const [statusText, setStatusText] = useState("Loading config...");
  const [selectedModelIndex, setSelectedModelIndex] = useState(0);
  const [selectedPluginIndex, setSelectedPluginIndex] = useState(0);

  useEffect(() => {
    loadConfig().catch(() => {
      setStatusText("Failed to load config");
    });
  }, []);

  useEffect(() => {
    if (selectedModelIndex >= draftConfig.models.length) {
      setSelectedModelIndex(Math.max(0, draftConfig.models.length - 1));
    }
  }, [draftConfig.models.length, selectedModelIndex]);

  useEffect(() => {
    if (selectedPluginIndex >= draftConfig.plugins.length) {
      setSelectedPluginIndex(Math.max(0, draftConfig.plugins.length - 1));
    }
  }, [draftConfig.plugins.length, selectedPluginIndex]);

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
      setStatusText("Config saved");
    } catch {
      setStatusText("Invalid raw JSON");
    }
  }

  function mutateDraft(mutator) {
    setDraftConfig((previous) => {
      const next = clone(previous);
      mutator(next);
      setRawConfig(JSON.stringify(next, null, 2));
      return next;
    });
  }

  function renderModelEditor() {
    const current = draftConfig.models[selectedModelIndex] || emptyModel();

    return (
      <div className="entry-editor-layout">
        <div className="entry-list">
          <div className="entry-list-head">
            <h4>Custom entries</h4>
            <button
              type="button"
              onClick={() => {
                mutateDraft((draft) => {
                  draft.models.push(emptyModel());
                });
                setSelectedModelIndex(draftConfig.models.length);
              }}
            >
              + Add Entry
            </button>
          </div>
          <div className="entry-list-scroll">
            {draftConfig.models.map((item, index) => (
              <button
                key={`${item.title}-${index}`}
                type="button"
                className={`entry-list-item ${index === selectedModelIndex ? "active" : ""}`}
                onClick={() => setSelectedModelIndex(index)}
              >
                {item.title || `model-${index + 1}`}
              </button>
            ))}
          </div>
        </div>

        <section className="entry-editor-card">
          <div className="entry-editor-head">
            <h3>{current.title || "Model entry"}</h3>
            <button
              type="button"
              className="danger"
              onClick={() => {
                mutateDraft((draft) => {
                  draft.models.splice(selectedModelIndex, 1);
                  if (draft.models.length === 0) {
                    draft.models.push(emptyModel());
                  }
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
                    draft.models[selectedModelIndex].title = event.target.value;
                  })
                }
              />
            </label>
            <label>
              Model
              <input
                value={current.model}
                onChange={(event) =>
                  mutateDraft((draft) => {
                    draft.models[selectedModelIndex].model = event.target.value;
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
                    draft.models[selectedModelIndex].apiUrl = event.target.value;
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
                    draft.models[selectedModelIndex].apiKey = event.target.value;
                  })
                }
              />
            </label>
          </div>
        </section>
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
    if (selectedSettings === "models") {
      return renderModelEditor();
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

import React from "react";

function ensurePlugin(draft, index, emptyPlugin) {
  if (!Array.isArray(draft.plugins)) {
    draft.plugins = [];
  }
  if (!draft.plugins[index]) {
    draft.plugins[index] = emptyPlugin();
  }
  return draft.plugins[index];
}

function pluginStatus(plugin) {
  const hasPlugin = Boolean(String(plugin?.plugin || "").trim());
  const hasURL = Boolean(String(plugin?.apiUrl || "").trim());
  if (hasPlugin && hasURL) {
    return { label: "configured", tone: "on" };
  }
  if (hasPlugin || hasURL || Boolean(String(plugin?.apiKey || "").trim())) {
    return { label: "incomplete", tone: "off" };
  }
  return { label: "missing", tone: "off" };
}

export function PluginEditor({
  draftConfig,
  selectedPluginIndex,
  onSelectPluginIndex,
  mutateDraft,
  emptyPlugin
}) {
  const plugins = Array.isArray(draftConfig.plugins) ? draftConfig.plugins : [];
  const current = plugins[selectedPluginIndex] || emptyPlugin();
  const currentStatus = pluginStatus(current);

  return (
    <div className="entry-editor-layout config-integration-layout">
      <div className="entry-list config-integration-list">
        <div className="entry-list-head">
          <h4>Plugin entries</h4>
          <button
            type="button"
            className="config-integration-add-button"
            onClick={() => {
              mutateDraft((draft) => {
                if (!Array.isArray(draft.plugins)) {
                  draft.plugins = [];
                }
                draft.plugins.push(emptyPlugin());
              });
              onSelectPluginIndex(plugins.length);
            }}
          >
            <span className="material-symbols-rounded" aria-hidden>
              add
            </span>
            <span>Add</span>
          </button>
        </div>
        <div className="entry-list-scroll">
          {plugins.length === 0 ? (
            <p className="entry-editor-empty config-integration-empty">No plugin entries configured.</p>
          ) : null}
          {plugins.map((item, index) => {
            const status = pluginStatus(item);
            return (
              <button
                key={`${item.title || item.plugin || "plugin"}-${index}`}
                type="button"
                className={`entry-list-item config-integration-list-item ${index === selectedPluginIndex ? "active" : ""}`}
                onClick={() => onSelectPluginIndex(index)}
              >
                <span className="providers-cli-card-icon material-symbols-rounded" aria-hidden>
                  extension
                </span>
                <span className="config-integration-list-main">
                  <span className="config-integration-list-title">{item.title || `plugin-${index + 1}`}</span>
                  <span className="config-integration-list-subtitle">{item.plugin || "No plugin id"}</span>
                  <span className={`provider-state ${status.tone}`}>{status.label}</span>
                </span>
              </button>
            );
          })}
        </div>
      </div>

      <section className="entry-editor-card config-integration-card">
        <div className="entry-editor-head config-integration-head">
          <div className="config-integration-title-row">
            <span className="provider-list-icon" aria-hidden="true">
              <span className="material-symbols-rounded">extension</span>
            </span>
            <div className="config-integration-heading">
              <h3>{current.title || "Plugin entry"}</h3>
              <span className="provider-model-line">
                {current.plugin || "No plugin id"}{current.apiUrl ? ` · ${current.apiUrl}` : ""}
              </span>
            </div>
            <span className={`provider-state ${currentStatus.tone}`}>{currentStatus.label}</span>
          </div>
          <button
            type="button"
            className="danger"
            disabled={plugins.length === 0}
            onClick={() => {
              mutateDraft((draft) => {
                if (!Array.isArray(draft.plugins)) {
                  return;
                }
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
                  ensurePlugin(draft, selectedPluginIndex, emptyPlugin).title = event.target.value;
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
                  ensurePlugin(draft, selectedPluginIndex, emptyPlugin).plugin = event.target.value;
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
                  ensurePlugin(draft, selectedPluginIndex, emptyPlugin).apiUrl = event.target.value;
                })
              }
            />
          </label>
          <label>
            API Key
            <input
              type="password"
              value={current.apiKey}
              onChange={(event) =>
                mutateDraft((draft) => {
                  ensurePlugin(draft, selectedPluginIndex, emptyPlugin).apiKey = event.target.value;
                })
              }
            />
          </label>
        </div>
      </section>
    </div>
  );
}

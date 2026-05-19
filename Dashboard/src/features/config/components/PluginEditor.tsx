import React, { useState } from "react";

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

function isLocalPluginSource(value) {
  const source = String(value || "").trim();
  return source.startsWith("/") || source.startsWith("~") || source.startsWith("file://") || /^[A-Za-z]:[\\/]/.test(source);
}

function fileUriToPath(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "file:") {
      return "";
    }
    let pathname = decodeURIComponent(url.pathname || "");
    if (/^\/[A-Za-z]:/.test(pathname)) {
      pathname = pathname.slice(1);
    }
    return pathname;
  } catch {
    return "";
  }
}

function pathBasename(value) {
  return String(value || "")
    .replace(/\/+$/, "")
    .split(/[\\/]/)
    .filter(Boolean)
    .pop() || "plugin";
}

function droppedDirectoryPayload(dataTransfer) {
  const uriList = dataTransfer.getData("text/uri-list");
  const fileUri = String(uriList || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith("#") && line.startsWith("file://"));
  if (fileUri) {
    const path = fileUriToPath(fileUri);
    if (path) {
      return { path, name: pathBasename(path), hasDirectory: true };
    }
  }

  let directoryName = "";
  for (const item of Array.from(dataTransfer.items || []) as DataTransferItem[]) {
    const entry = (item as any).webkitGetAsEntry?.();
    if (entry?.isDirectory) {
      directoryName = entry.name || directoryName;
      const file = item.getAsFile?.();
      const filePath = (file as any)?.path || "";
      if (filePath) {
        return { path: filePath, name: entry.name || pathBasename(filePath), hasDirectory: true };
      }
    }
  }

  for (const file of Array.from(dataTransfer.files || []) as File[]) {
    const filePath = (file as any)?.path || "";
    if (filePath) {
      return { path: filePath, name: file.name || pathBasename(filePath), hasDirectory: true };
    }
  }

  return { path: "", name: directoryName, hasDirectory: Boolean(directoryName) };
}

export function PluginEditor({
  draftConfig,
  selectedPluginIndex,
  onSelectPluginIndex,
  mutateDraft,
  emptyPlugin,
  selectDirectory,
  installPlugin
}) {
  const plugins = Array.isArray(draftConfig.plugins) ? draftConfig.plugins : [];
  const current = plugins[selectedPluginIndex] || emptyPlugin();
  const currentStatus = pluginStatus(current);
  const [pluginSource, setPluginSource] = useState("");
  const [installStatus, setInstallStatus] = useState("");
  const [isInstalling, setIsInstalling] = useState(false);
  const [forceInstall, setForceInstall] = useState(true);
  const [isDraggingPlugin, setIsDraggingPlugin] = useState(false);

  async function choosePluginDirectory() {
    setInstallStatus("");
    const result = await selectDirectory?.();
    const path = typeof result?.path === "string" ? result.path : "";
    if (!path) {
      setInstallStatus("No folder selected.");
      return;
    }
    setPluginSource(path);
    setInstallStatus(`${pathBasename(path)} ready.`);
  }

  async function handleInstallPlugin() {
    const source = pluginSource.trim();
    if (!source) {
      setInstallStatus("Choose a plugin source first.");
      return;
    }
    setIsInstalling(true);
    setInstallStatus("Installing...");
    try {
      const result = await installPlugin?.({
        sourceUrl: source,
        force: forceInstall,
        enabled: true,
        localDirectory: isLocalPluginSource(source)
      });
      const record = result?.plugin || {};
      const pluginId = String(record.id || record.type || pathBasename(source)).trim();
      const title = String(record.type || pluginId || pathBasename(source)).trim();
      let nextIndex = plugins.findIndex((item) => item.plugin === pluginId);
      if (nextIndex < 0) {
        nextIndex = plugins.length;
      }
      mutateDraft((draft) => {
        if (!Array.isArray(draft.plugins)) {
          draft.plugins = [];
        }
        const nextEntry = {
          title,
          apiKey: "",
          apiUrl: String(record.baseUrl || ""),
          plugin: pluginId
        };
        if (draft.plugins[nextIndex]) {
          draft.plugins[nextIndex] = {
            ...draft.plugins[nextIndex],
            ...nextEntry
          };
        } else {
          draft.plugins.push(nextEntry);
        }
      });
      onSelectPluginIndex(nextIndex);
      setInstallStatus(`${pluginId} installed.`);
    } catch (error) {
      setInstallStatus(error?.message || "Plugin install failed.");
    } finally {
      setIsInstalling(false);
    }
  }

  function handleDrop(event) {
    event.preventDefault();
    setIsDraggingPlugin(false);
    const payload = droppedDirectoryPayload(event.dataTransfer);
    if (payload.path) {
      setPluginSource(payload.path);
      setInstallStatus(`${payload.name || pathBasename(payload.path)} ready.`);
      return;
    }
    if (payload.hasDirectory) {
      setInstallStatus("Folder detected, but the browser hid its path. Use Choose folder.");
      return;
    }
    setInstallStatus("Drop a plugin folder or paste a Git URL.");
  }

  return (
    <div className="entry-editor-layout config-integration-layout config-plugin-layout">
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

      <div className="config-plugin-main">
        <section className="entry-editor-card config-plugin-install-panel">
          <div className="config-plugin-install-head">
            <div>
              <h3>Install plugin</h3>
              <span>{plugins.length} configured entries</span>
            </div>
            <button type="button" onClick={choosePluginDirectory}>
              <span className="material-symbols-rounded" aria-hidden>
                folder_open
              </span>
              <span>Choose folder</span>
            </button>
          </div>
          <div
            className={`config-plugin-dropzone ${isDraggingPlugin ? "active" : ""}`}
            onDragEnter={(event) => {
              event.preventDefault();
              setIsDraggingPlugin(true);
            }}
            onDragOver={(event) => {
              event.preventDefault();
              event.dataTransfer.dropEffect = "copy";
              setIsDraggingPlugin(true);
            }}
            onDragLeave={(event) => {
              event.preventDefault();
              if (event.currentTarget === event.target) {
                setIsDraggingPlugin(false);
              }
            }}
            onDrop={handleDrop}
          >
            <span className="material-symbols-rounded config-plugin-drop-icon" aria-hidden>
              deployed_code
            </span>
            <div className="config-plugin-drop-copy">
              <strong>Drop plugin directory</strong>
              <span>{pluginSource || "Local path or Git URL"}</span>
            </div>
          </div>
          <div className="config-plugin-source-row">
            <label>
              Source
              <input
                value={pluginSource}
                placeholder="/Users/me/plugin or https://github.com/org/plugin.git"
                onChange={(event) => {
                  setPluginSource(event.target.value);
                  setInstallStatus("");
                }}
              />
            </label>
            <div className="config-plugin-source-actions">
              <label className="settings-checkbox config-plugin-force">
                <input
                  type="checkbox"
                  checked={forceInstall}
                  onChange={(event) => setForceInstall(event.target.checked)}
                />
                <span>Replace existing</span>
              </label>
              <button
                type="button"
                className="config-plugin-install-button"
                onClick={handleInstallPlugin}
                disabled={isInstalling || !pluginSource.trim()}
              >
                <span className="material-symbols-rounded" aria-hidden>
                  download
                </span>
                <span>{isInstalling ? "Installing" : "Install"}</span>
              </button>
            </div>
          </div>
          {installStatus ? <p className="config-plugin-install-status">{installStatus}</p> : null}
        </section>

        <section className="entry-editor-card config-integration-card config-plugin-detail-card">
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
    </div>
  );
}

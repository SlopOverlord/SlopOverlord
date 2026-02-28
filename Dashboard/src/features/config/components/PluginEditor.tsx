import React from "react";

export function PluginEditor({
  draftConfig,
  selectedPluginIndex,
  onSelectPluginIndex,
  mutateDraft,
  emptyPlugin
}) {
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
              onSelectPluginIndex(draftConfig.plugins.length);
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
              onClick={() => onSelectPluginIndex(index)}
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

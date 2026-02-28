import React from "react";

export function NodeHostEditor({ draftConfig, mutateDraft, parseLines }) {
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

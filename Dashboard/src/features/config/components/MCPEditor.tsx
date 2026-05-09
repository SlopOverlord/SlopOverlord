import React from "react";

function parseHeaders(value) {
  const headers = {};
  String(value || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .forEach((line) => {
      const separator = line.indexOf(":");
      if (separator <= 0) {
        return;
      }
      const key = line.slice(0, separator).trim();
      const headerValue = line.slice(separator + 1).trim();
      if (key) {
        headers[key] = headerValue;
      }
    });
  return headers;
}

function formatHeaders(headers) {
  return Object.entries(headers || {})
    .map(([key, value]) => `${key}: ${value}`)
    .join("\n");
}

function ensureMCPServer(draft, index, emptyMCPServer) {
  if (!draft.mcp) {
    draft.mcp = { servers: [] };
  }
  if (!Array.isArray(draft.mcp.servers)) {
    draft.mcp.servers = [];
  }
  if (!draft.mcp.servers[index]) {
    draft.mcp.servers[index] = emptyMCPServer();
  }
  return draft.mcp.servers[index];
}

function serverStatus(server) {
  if (!server?.enabled) {
    return { label: "disabled", tone: "off" };
  }
  if (server.transport === "http") {
    return Boolean(String(server.endpoint || "").trim())
      ? { label: "enabled", tone: "on" }
      : { label: "missing endpoint", tone: "off" };
  }
  return Boolean(String(server.command || "").trim())
    ? { label: "enabled", tone: "on" }
    : { label: "missing command", tone: "off" };
}

function CapabilitySwitch({ label, checked, onChange }) {
  return (
    <label className="config-capability-toggle">
      <span>{label}</span>
      <span className="agent-tools-switch">
        <input
          type="checkbox"
          checked={checked}
          onChange={(event) => onChange(event.target.checked)}
        />
        <span className="agent-tools-switch-track" />
      </span>
    </label>
  );
}

export function MCPEditor({
  draftConfig,
  selectedMCPServerIndex,
  onSelectMCPServerIndex,
  mutateDraft,
  emptyMCPServer,
  parseLines
}) {
  const servers = Array.isArray(draftConfig.mcp?.servers) ? draftConfig.mcp.servers : [];
  const current = servers[selectedMCPServerIndex] || emptyMCPServer();
  const isHTTP = current.transport === "http";
  const currentStatus = serverStatus(current);

  return (
    <div className="entry-editor-layout config-integration-layout">
      <div className="entry-list config-integration-list">
        <div className="entry-list-head">
          <h4>MCP servers</h4>
          <button
            type="button"
            className="config-integration-add-button"
            onClick={() => {
              mutateDraft((draft) => {
                if (!draft.mcp) {
                  draft.mcp = { servers: [] };
                }
                if (!Array.isArray(draft.mcp.servers)) {
                  draft.mcp.servers = [];
                }
                draft.mcp.servers.push(emptyMCPServer());
              });
              onSelectMCPServerIndex(servers.length);
            }}
          >
            <span className="material-symbols-rounded" aria-hidden>
              add
            </span>
            <span>Add</span>
          </button>
        </div>
        <div className="entry-list-scroll">
          {servers.length === 0 ? (
            <p className="entry-editor-empty config-integration-empty">No MCP servers configured.</p>
          ) : null}
          {servers.map((item, index) => {
            const status = serverStatus(item);
            return (
              <button
                key={`${item.id || "mcp-server"}-${index}`}
                type="button"
                className={`entry-list-item config-integration-list-item ${index === selectedMCPServerIndex ? "active" : ""}`}
                onClick={() => onSelectMCPServerIndex(index)}
              >
                <span className="providers-cli-card-icon material-symbols-rounded" aria-hidden>
                  account_tree
                </span>
                <span className="config-integration-list-main">
                  <span className="config-integration-list-title">{item.id || `mcp-server-${index + 1}`}</span>
                  <span className="config-integration-list-subtitle">
                    {item.transport === "http" ? item.endpoint || "HTTP endpoint" : item.command || "stdio command"}
                  </span>
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
              <span className="material-symbols-rounded">account_tree</span>
            </span>
            <div className="config-integration-heading">
              <h3>{current.id || "MCP server"}</h3>
              <span className="provider-model-line">
                {isHTTP ? current.endpoint || "HTTP endpoint" : current.command || "stdio command"}
              </span>
            </div>
            <span className={`provider-state ${currentStatus.tone}`}>{currentStatus.label}</span>
          </div>
          <button
            type="button"
            className="danger"
            disabled={servers.length === 0}
            onClick={() => {
              mutateDraft((draft) => {
                if (!Array.isArray(draft.mcp?.servers)) {
                  return;
                }
                draft.mcp.servers.splice(selectedMCPServerIndex, 1);
              });
            }}
          >
            Delete
          </button>
        </div>

        <section className="entry-editor-block config-integration-note">
          <p className="entry-editor-empty">
            MCP servers add external tools, resources, and prompts for agents. Use stdio for local commands like
            npx packages, or HTTP for hosted MCP endpoints.
          </p>
        </section>

        <div className="entry-form-grid">
          <label>
            Server ID
            <input
              placeholder="filesystem"
              value={current.id}
              onChange={(event) =>
                mutateDraft((draft) => {
                  ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).id = event.target.value;
                })
              }
            />
          </label>
          <label>
            Transport
            <div className="provider-auth-mode-segmented config-segmented" role="tablist" aria-label="MCP transport">
              <button
                type="button"
                role="tab"
                aria-selected={!isHTTP}
                className={!isHTTP ? "active" : ""}
                onClick={() =>
                  mutateDraft((draft) => {
                    ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).transport = "stdio";
                  })
                }
              >
                stdio
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={isHTTP}
                className={isHTTP ? "active" : ""}
                onClick={() =>
                  mutateDraft((draft) => {
                    ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).transport = "http";
                  })
                }
              >
                http
              </button>
            </div>
          </label>
          {isHTTP ? (
            <>
              <label style={{ gridColumn: "1 / -1" }}>
                HTTP Endpoint
                <input
                  placeholder="https://mcp.example.com/v1"
                  value={current.endpoint || ""}
                  onChange={(event) =>
                    mutateDraft((draft) => {
                      ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).endpoint = event.target.value;
                    })
                  }
                />
              </label>
              <label style={{ gridColumn: "1 / -1" }}>
                Headers
                <textarea
                  rows={4}
                  placeholder="Authorization: Bearer token"
                  value={formatHeaders(current.headers)}
                  onChange={(event) =>
                    mutateDraft((draft) => {
                      ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).headers = parseHeaders(event.target.value);
                    })
                  }
                />
                <span className="entry-form-hint">One header per line, formatted as <code>Name: value</code>.</span>
              </label>
            </>
          ) : (
            <>
              <label>
                Command
                <input
                  placeholder="npx"
                  value={current.command || ""}
                  onChange={(event) =>
                    mutateDraft((draft) => {
                      ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).command = event.target.value;
                    })
                  }
                />
              </label>
              <label>
                Working Directory
                <input
                  placeholder="/tmp/workspace"
                  value={current.cwd || ""}
                  onChange={(event) =>
                    mutateDraft((draft) => {
                      ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).cwd = event.target.value;
                    })
                  }
                />
              </label>
              <label style={{ gridColumn: "1 / -1" }}>
                Arguments (one per line)
                <textarea
                  rows={5}
                  placeholder={"-y\n@modelcontextprotocol/server-filesystem\n/tmp/workspace"}
                  value={(current.arguments || []).join("\n")}
                  onChange={(event) =>
                    mutateDraft((draft) => {
                      ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).arguments = parseLines(event.target.value);
                    })
                  }
                />
              </label>
            </>
          )}
          <label>
            Timeout (ms)
            <input
              type="number"
              min="250"
              step="250"
              value={String(current.timeoutMs ?? 15000)}
              onChange={(event) =>
                mutateDraft((draft) => {
                  const parsed = Number.parseInt(event.target.value, 10);
                  ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).timeoutMs = Number.isFinite(parsed)
                    ? Math.max(250, parsed)
                    : 15000;
                })
              }
            />
          </label>
          <label>
            Tool Prefix
            <input
              placeholder="mcp.filesystem"
              value={current.toolPrefix || ""}
              onChange={(event) =>
                mutateDraft((draft) => {
                  ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).toolPrefix = event.target.value;
                })
              }
            />
          </label>
          <label>
            Runtime
            <div className="config-field-toggle">
              <span>{current.enabled ? "Enabled" : "Disabled"}</span>
              <span className="agent-tools-switch">
                <input
                  type="checkbox"
                  checked={Boolean(current.enabled)}
                  onChange={(event) =>
                    mutateDraft((draft) => {
                      ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).enabled = event.target.checked;
                    })
                  }
                />
                <span className="agent-tools-switch-track" />
              </span>
            </div>
          </label>
          <div className="config-capability-grid">
            <CapabilitySwitch
              label="Expose tools"
              checked={Boolean(current.exposeTools)}
              onChange={(checked) =>
                mutateDraft((draft) => {
                  ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).exposeTools = checked;
                })
              }
            />
            <CapabilitySwitch
              label="Expose resources"
              checked={Boolean(current.exposeResources)}
              onChange={(checked) =>
                mutateDraft((draft) => {
                  ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).exposeResources = checked;
                })
              }
            />
            <CapabilitySwitch
              label="Expose prompts"
              checked={Boolean(current.exposePrompts)}
              onChange={(checked) =>
                mutateDraft((draft) => {
                  ensureMCPServer(draft, selectedMCPServerIndex, emptyMCPServer).exposePrompts = checked;
                })
              }
            />
          </div>
        </div>
      </section>
    </div>
  );
}

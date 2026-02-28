import React, { useEffect, useMemo, useState } from "react";
import { fetchAgentToolsCatalog, fetchAgentToolsPolicy, updateAgentToolsPolicy } from "../../../api";

function defaultDraft() {
  return {
    version: 1,
    defaultPolicy: "allow",
    tools: {},
    guardrails: {
      maxReadBytes: 524288,
      maxWriteBytes: 524288,
      execTimeoutMs: 15000,
      maxExecOutputBytes: 262144,
      maxProcessesPerSession: 3,
      maxToolCallsPerMinute: 120,
      deniedCommandPrefixes: ["rm", "shutdown", "reboot", "mkfs", "dd", "killall", "launchctl"],
      allowedWriteRoots: [],
      allowedExecRoots: [],
      webTimeoutMs: 10000,
      webMaxBytes: 524288,
      webBlockPrivateNetworks: true
    }
  };
}

function parseList(value) {
  if (Array.isArray(value)) {
    return value.map((item) => String(item || "").trim()).filter(Boolean);
  }
  return String(value || "")
    .split("\n")
    .map((item) => item.trim())
    .filter(Boolean);
}

const NUMERIC_GUARDRAILS = [
  {
    key: "maxReadBytes",
    label: "Max Read Bytes",
    hint: "Maximum bytes a single read operation can return.",
    unit: "bytes"
  },
  {
    key: "maxWriteBytes",
    label: "Max Write Bytes",
    hint: "Maximum bytes allowed per write operation.",
    unit: "bytes"
  },
  {
    key: "execTimeoutMs",
    label: "Exec Timeout",
    hint: "Maximum run time for one command execution.",
    unit: "ms"
  },
  {
    key: "maxExecOutputBytes",
    label: "Max Exec Output",
    hint: "Cap for captured stdout and stderr output.",
    unit: "bytes"
  },
  {
    key: "maxProcessesPerSession",
    label: "Max Processes / Session",
    hint: "Maximum concurrently tracked child processes.",
    unit: ""
  },
  {
    key: "maxToolCallsPerMinute",
    label: "Max Tool Calls / Minute",
    hint: "Rate limit across all tool invocations.",
    unit: ""
  },
  {
    key: "webTimeoutMs",
    label: "Web Timeout",
    hint: "Timeout for each web request from tools.",
    unit: "ms"
  },
  {
    key: "webMaxBytes",
    label: "Web Max Bytes",
    hint: "Maximum bytes accepted from a web response.",
    unit: "bytes"
  }
] as const;

export function AgentToolsTab({ agentId }) {
  const [catalog, setCatalog] = useState([]);
  const [draft, setDraft] = useState(defaultDraft);
  const [statusText, setStatusText] = useState("Loading tools policy...");
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setIsLoading(true);
      setStatusText("Loading tools policy...");
      const [catalogResponse, policyResponse] = await Promise.all([
        fetchAgentToolsCatalog(agentId),
        fetchAgentToolsPolicy(agentId)
      ]);
      if (cancelled) {
        return;
      }

      if (!catalogResponse || !policyResponse) {
        setCatalog([]);
        setDraft(defaultDraft());
        setStatusText("Failed to load tools policy.");
        setIsLoading(false);
        return;
      }

      const policy = policyResponse as any;
      setCatalog(Array.isArray(catalogResponse) ? catalogResponse : []);
      setDraft({
        version: Number(policy.version || 1),
        defaultPolicy: String(policy.defaultPolicy || "allow"),
        tools: typeof policy.tools === "object" && policy.tools ? policy.tools : {},
        guardrails: {
          ...defaultDraft().guardrails,
          ...(policy.guardrails || {})
        }
      });
      setStatusText("Tools policy loaded.");
      setIsLoading(false);
    }

    load().catch(() => {
      if (!cancelled) {
        setStatusText("Failed to load tools policy.");
        setIsLoading(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [agentId]);

  const groupedCatalog = useMemo(() => {
    const groups = new Map();
    for (const item of catalog) {
      const domain = String(item?.domain || "other");
      if (!groups.has(domain)) {
        groups.set(domain, []);
      }
      groups.get(domain).push(item);
    }
    return Array.from(groups.entries()).sort((left, right) => left[0].localeCompare(right[0]));
  }, [catalog]);

  function updateGuardrail(field, value) {
    setDraft((previous) => ({
      ...previous,
      guardrails: {
        ...previous.guardrails,
        [field]: value
      }
    }));
  }

  function isToolEnabled(toolId, state = draft) {
    const explicitlyEnabled = state.tools?.[toolId];
    if (typeof explicitlyEnabled === "boolean") {
      return explicitlyEnabled;
    }
    return state.defaultPolicy === "allow";
  }

  function toggleTool(toolId) {
    setDraft((previous) => ({
      ...previous,
      tools: (() => {
        const effective = isToolEnabled(toolId, previous);
        const nextValue = !effective;
        const defaultEnabled = previous.defaultPolicy === "allow";
        const nextTools = {
          ...previous.tools
        };

        if (nextValue === defaultEnabled) {
          delete nextTools[toolId];
        } else {
          nextTools[toolId] = nextValue;
        }
        return nextTools;
      })()
    }));
  }

  async function savePolicy(event) {
    event.preventDefault();
    if (isSaving) {
      return;
    }

    setIsSaving(true);
    const payload = {
      version: 1,
      defaultPolicy: draft.defaultPolicy === "deny" ? "deny" : "allow",
      tools: draft.tools,
      guardrails: {
        maxReadBytes: Number(draft.guardrails.maxReadBytes),
        maxWriteBytes: Number(draft.guardrails.maxWriteBytes),
        execTimeoutMs: Number(draft.guardrails.execTimeoutMs),
        maxExecOutputBytes: Number(draft.guardrails.maxExecOutputBytes),
        maxProcessesPerSession: Number(draft.guardrails.maxProcessesPerSession),
        maxToolCallsPerMinute: Number(draft.guardrails.maxToolCallsPerMinute),
        deniedCommandPrefixes: parseList(draft.guardrails.deniedCommandPrefixes),
        allowedWriteRoots: parseList(draft.guardrails.allowedWriteRoots),
        allowedExecRoots: parseList(draft.guardrails.allowedExecRoots),
        webTimeoutMs: Number(draft.guardrails.webTimeoutMs),
        webMaxBytes: Number(draft.guardrails.webMaxBytes),
        webBlockPrivateNetworks: Boolean(draft.guardrails.webBlockPrivateNetworks)
      }
    };

    const response = await updateAgentToolsPolicy(agentId, payload);
    if (!response) {
      setStatusText("Failed to save tools policy.");
      setIsSaving(false);
      return;
    }

    setStatusText("Tools policy saved.");
    setIsSaving(false);
  }

  return (
    <section className="agent-config-shell agent-tools-shell">
      <div className="agent-config-head agent-tools-head">
        <div className="agent-tools-head-copy">
          <h3>Tools Policy</h3>
          <p className="placeholder-text">Control catalog overrides and runtime guardrails for tool execution.</p>
        </div>
        <span className="agent-tools-status">{statusText}</span>
      </div>

      {isLoading ? (
        <p className="placeholder-text">Loading...</p>
      ) : (
        <form className="agent-tools-form" onSubmit={savePolicy}>
          <section className="agent-tools-panel">
            <div className="agent-tools-panel-head">
              <h4>Baseline Policy</h4>
              <p>Default behavior for tools that are not explicitly overridden.</p>
            </div>
            <label className="agent-tools-field">
              <span>Default Policy</span>
              <select
                value={draft.defaultPolicy}
                onChange={(event) => setDraft((previous) => ({ ...previous, defaultPolicy: event.target.value }))}
              >
                <option value="allow">allow</option>
                <option value="deny">deny</option>
              </select>
            </label>
          </section>

          <section className="agent-tools-panel">
            <div className="agent-tools-panel-head">
              <h4>Catalog Overrides</h4>
              <p>Enable or disable specific tools per catalog domain.</p>
            </div>
            {groupedCatalog.length === 0 ? (
              <p className="placeholder-text">No tools available in the catalog.</p>
            ) : (
              <div className="agent-tools-domain-grid">
                {groupedCatalog.map(([domain, items]) => (
                  <fieldset key={domain} className="agent-tools-domain">
                    <legend>{domain}</legend>
                    {items.map((item) => {
                      const id = String(item?.id || "");
                      const checked = isToolEnabled(id);
                      return (
                        <label key={id} className="agent-tools-tool-row">
                          <span className="agent-tools-tool-copy">
                            <strong>{item.title || id}</strong>
                            <small>
                              {id} · {item.status || "unknown"}
                            </small>
                          </span>
                          <span className="agent-tools-switch">
                            <input type="checkbox" checked={checked} onChange={() => toggleTool(id)} />
                            <span className="agent-tools-switch-track" />
                          </span>
                        </label>
                      );
                    })}
                  </fieldset>
                ))}
              </div>
            )}
          </section>

          <section className="agent-tools-panel">
            <div className="agent-tools-panel-head">
              <h4>Guardrails</h4>
              <p>Execution, process, filesystem, and network boundaries for tools.</p>
            </div>

            <div className="agent-tools-guardrail-grid">
              {NUMERIC_GUARDRAILS.map((field) => (
                <label key={field.key} className="agent-tools-guardrail">
                  <span className="agent-tools-guardrail-title">{field.label}</span>
                  <span className="agent-tools-guardrail-note">{field.hint}</span>
                  <div className="agent-tools-number">
                    <input
                      type="number"
                      value={draft.guardrails[field.key]}
                      onChange={(event) => updateGuardrail(field.key, event.target.value)}
                    />
                    {field.unit ? <span className="agent-tools-unit">{field.unit}</span> : null}
                  </div>
                </label>
              ))}

              <label className="agent-tools-guardrail agent-tools-guardrail-toggle">
                <span className="agent-tools-guardrail-copy">
                  <span className="agent-tools-guardrail-title">Block Private Networks</span>
                  <span className="agent-tools-guardrail-note">Reject loopback and private web addresses.</span>
                </span>
                <span className="agent-tools-switch">
                  <input
                    type="checkbox"
                    checked={Boolean(draft.guardrails.webBlockPrivateNetworks)}
                    onChange={(event) => updateGuardrail("webBlockPrivateNetworks", event.target.checked)}
                  />
                  <span className="agent-tools-switch-track" />
                </span>
              </label>
            </div>

            <div className="agent-tools-textarea-grid">
              <label className="agent-tools-field">
                <span>Denied Command Prefixes</span>
                <small>One prefix per line.</small>
                <textarea
                  rows={5}
                  value={Array.isArray(draft.guardrails.deniedCommandPrefixes)
                    ? draft.guardrails.deniedCommandPrefixes.join("\n")
                    : String(draft.guardrails.deniedCommandPrefixes || "")}
                  onChange={(event) => updateGuardrail("deniedCommandPrefixes", event.target.value)}
                />
              </label>
              <label className="agent-tools-field">
                <span>Allowed Write Roots</span>
                <small>Absolute paths, one root per line.</small>
                <textarea
                  rows={5}
                  value={Array.isArray(draft.guardrails.allowedWriteRoots)
                    ? draft.guardrails.allowedWriteRoots.join("\n")
                    : String(draft.guardrails.allowedWriteRoots || "")}
                  onChange={(event) => updateGuardrail("allowedWriteRoots", event.target.value)}
                />
              </label>
              <label className="agent-tools-field">
                <span>Allowed Exec Roots</span>
                <small>Absolute paths, one root per line.</small>
                <textarea
                  rows={5}
                  value={Array.isArray(draft.guardrails.allowedExecRoots)
                    ? draft.guardrails.allowedExecRoots.join("\n")
                    : String(draft.guardrails.allowedExecRoots || "")}
                  onChange={(event) => updateGuardrail("allowedExecRoots", event.target.value)}
                />
              </label>
            </div>
          </section>

          <div className="agent-config-actions agent-tools-actions">
            <button type="submit" disabled={isSaving}>
              {isSaving ? "Saving..." : "Save Tools Policy"}
            </button>
          </div>
        </form>
      )}
    </section>
  );
}

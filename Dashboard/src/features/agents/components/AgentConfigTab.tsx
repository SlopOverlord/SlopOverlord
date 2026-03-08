import React, { useEffect, useState } from "react";
import { fetchAgentConfig, updateAgentConfig } from "../../../api";

function emptyAgentConfigDraft(agentId) {
  return {
    agentId,
    selectedModel: "",
    availableModels: [],
    documents: {
      userMarkdown: "",
      agentsMarkdown: "",
      soulMarkdown: "",
      identityMarkdown: "",
      heartbeatMarkdown: ""
    },
    heartbeat: {
      enabled: false,
      intervalMinutes: 5
    },
    heartbeatStatus: {
      lastRunAt: null,
      lastSuccessAt: null,
      lastFailureAt: null,
      lastResult: "",
      lastErrorMessage: "",
      lastSessionId: ""
    }
  };
}

function normalizeConfigDraft(agentId, config) {
  return {
    agentId: config.agentId || agentId,
    selectedModel: config.selectedModel || "",
    availableModels: Array.isArray(config.availableModels) ? config.availableModels : [],
    documents: {
      userMarkdown: String(config.documents?.userMarkdown || ""),
      agentsMarkdown: String(config.documents?.agentsMarkdown || ""),
      soulMarkdown: String(config.documents?.soulMarkdown || ""),
      identityMarkdown: String(config.documents?.identityMarkdown || ""),
      heartbeatMarkdown: String(config.documents?.heartbeatMarkdown || "")
    },
    heartbeat: {
      enabled: Boolean(config.heartbeat?.enabled),
      intervalMinutes: Number.parseInt(String(config.heartbeat?.intervalMinutes ?? 5), 10) || 5
    },
    heartbeatStatus: {
      lastRunAt: config.heartbeatStatus?.lastRunAt || null,
      lastSuccessAt: config.heartbeatStatus?.lastSuccessAt || null,
      lastFailureAt: config.heartbeatStatus?.lastFailureAt || null,
      lastResult: String(config.heartbeatStatus?.lastResult || ""),
      lastErrorMessage: String(config.heartbeatStatus?.lastErrorMessage || ""),
      lastSessionId: String(config.heartbeatStatus?.lastSessionId || "")
    }
  };
}

function formatDateTime(value) {
  if (!value) {
    return "Never";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "Never";
  }

  return date.toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  });
}

function statusValue(value, fallback = "None") {
  const normalized = String(value || "").trim();
  return normalized || fallback;
}

export function AgentConfigTab({ agentId }) {
  const [draft, setDraft] = useState(() => emptyAgentConfigDraft(agentId));
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [statusText, setStatusText] = useState("Loading agent config...");

  useEffect(() => {
    let isCancelled = false;

    async function load() {
      setIsLoading(true);
      setStatusText("Loading agent config...");
      const response = await fetchAgentConfig(agentId);
      if (isCancelled) {
        return;
      }

      if (!response) {
        setDraft(emptyAgentConfigDraft(agentId));
        setStatusText("Failed to load config.");
        setIsLoading(false);
        return;
      }

      setDraft(normalizeConfigDraft(agentId, response));
      setStatusText("Config loaded.");
      setIsLoading(false);
    }

    load().catch(() => {
      if (!isCancelled) {
        setStatusText("Failed to load config.");
        setIsLoading(false);
      }
    });

    return () => {
      isCancelled = true;
    };
  }, [agentId]);

  function updateField(field, value) {
    setDraft((previous) => ({
      ...previous,
      [field]: value
    }));
  }

  function updateDocumentField(field, value) {
    setDraft((previous) => ({
      ...previous,
      documents: {
        ...previous.documents,
        [field]: value
      }
    }));
  }

  function updateHeartbeatField(field, value) {
    setDraft((previous) => ({
      ...previous,
      heartbeat: {
        ...previous.heartbeat,
        [field]: value
      }
    }));
  }

  async function saveConfig(event) {
    event.preventDefault();
    if (isSaving) {
      return;
    }

    const selectedModel = String(draft.selectedModel || "").trim();
    if (!selectedModel) {
      setStatusText("Model is required.");
      return;
    }

    const intervalMinutes = Number.parseInt(String(draft.heartbeat.intervalMinutes || 0), 10);
    if (draft.heartbeat.enabled && (!Number.isFinite(intervalMinutes) || intervalMinutes < 1)) {
      setStatusText("Heartbeat interval must be at least 1 minute.");
      return;
    }

    const payload = {
      selectedModel,
      documents: {
        userMarkdown: String(draft.documents.userMarkdown || ""),
        agentsMarkdown: String(draft.documents.agentsMarkdown || ""),
        soulMarkdown: String(draft.documents.soulMarkdown || ""),
        identityMarkdown: String(draft.documents.identityMarkdown || ""),
        heartbeatMarkdown: String(draft.documents.heartbeatMarkdown || "")
      },
      heartbeat: {
        enabled: Boolean(draft.heartbeat.enabled),
        intervalMinutes: intervalMinutes || 5
      }
    };

    setIsSaving(true);
    const response = await updateAgentConfig(agentId, payload);
    if (!response) {
      setStatusText("Failed to save config.");
      setIsSaving(false);
      return;
    }

    setDraft(normalizeConfigDraft(agentId, response));
    setStatusText("Config saved.");
    setIsSaving(false);
  }

  return (
    <section className="agent-config-shell">
      <div className="agent-config-head">
        <h3>Agent Config</h3>
        <span className="placeholder-text">{statusText}</span>
      </div>

      {isLoading ? (
        <p className="placeholder-text">Loading...</p>
      ) : (
        <form className="agent-config-form" onSubmit={saveConfig}>
          <label>
            Model
            <select
              value={draft.selectedModel}
              onChange={(event) => updateField("selectedModel", event.target.value)}
            >
              {draft.availableModels.map((model) => (
                <option key={model.id} value={model.id}>
                  {model.title}
                </option>
              ))}
            </select>
          </label>

          <div className="agent-config-docs">
            <label>
              User.md
              <textarea
                rows={8}
                value={draft.documents.userMarkdown}
                onChange={(event) => updateDocumentField("userMarkdown", event.target.value)}
              />
            </label>
            <label>
              Agents.md
              <textarea
                rows={8}
                value={draft.documents.agentsMarkdown}
                onChange={(event) => updateDocumentField("agentsMarkdown", event.target.value)}
              />
            </label>
            <label>
              Soul.md
              <textarea
                rows={8}
                value={draft.documents.soulMarkdown}
                onChange={(event) => updateDocumentField("soulMarkdown", event.target.value)}
              />
            </label>
            <label>
              Identity.md
              <textarea
                rows={8}
                value={draft.documents.identityMarkdown}
                onChange={(event) => updateDocumentField("identityMarkdown", event.target.value)}
              />
            </label>
          </div>

          <section className="agent-config-heartbeat">
            <div className="agent-config-head">
              <div className="agent-tools-head-copy">
                <h4>Heartbeat</h4>
                <p className="placeholder-text">
                  Runs `HEARTBEAT.md` on a timer and expects exactly `SLOPPY_ACTION_OK` on success.
                </p>
              </div>
            </div>

            <label className="cron-form-toggle">
              <span>Enabled</span>
              <span className="agent-tools-switch">
                <input
                  type="checkbox"
                  checked={draft.heartbeat.enabled}
                  onChange={(event) => updateHeartbeatField("enabled", event.target.checked)}
                />
                <span className="agent-tools-switch-track" />
              </span>
            </label>

            <label>
              Interval (minutes)
              <input
                type="number"
                min="1"
                step="1"
                value={draft.heartbeat.intervalMinutes}
                onChange={(event) => updateHeartbeatField("intervalMinutes", event.target.value)}
              />
            </label>

            <label>
              HEARTBEAT.md
              <textarea
                rows={10}
                value={draft.documents.heartbeatMarkdown}
                onChange={(event) => updateDocumentField("heartbeatMarkdown", event.target.value)}
                placeholder="Describe what the automated heartbeat should verify."
              />
            </label>

            <div className="agent-config-heartbeat-status">
              <div>
                <strong>Last run:</strong> {formatDateTime(draft.heartbeatStatus.lastRunAt)}
              </div>
              <div>
                <strong>Last success:</strong> {formatDateTime(draft.heartbeatStatus.lastSuccessAt)}
              </div>
              <div>
                <strong>Last failure:</strong> {formatDateTime(draft.heartbeatStatus.lastFailureAt)}
              </div>
              <div>
                <strong>Last result:</strong> {statusValue(draft.heartbeatStatus.lastResult)}
              </div>
              <div>
                <strong>Last session:</strong> {statusValue(draft.heartbeatStatus.lastSessionId)}
              </div>
              <div>
                <strong>Last error:</strong> {statusValue(draft.heartbeatStatus.lastErrorMessage)}
              </div>
            </div>
          </section>

          <div className="agent-config-actions">
            <button type="submit" disabled={isSaving}>
              {isSaving ? "Saving..." : "Save Config"}
            </button>
          </div>
        </form>
      )}
    </section>
  );
}

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
      identityMarkdown: ""
    }
  };
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

      const config = response as any;
      setDraft({
        agentId: config.agentId || agentId,
        selectedModel: config.selectedModel || "",
        availableModels: Array.isArray(config.availableModels) ? config.availableModels : [],
        documents: {
          userMarkdown: String(config.documents?.userMarkdown || ""),
          agentsMarkdown: String(config.documents?.agentsMarkdown || ""),
          soulMarkdown: String(config.documents?.soulMarkdown || ""),
          identityMarkdown: String(config.documents?.identityMarkdown || "")
        }
      });
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

    const payload = {
      selectedModel,
      documents: {
        userMarkdown: String(draft.documents.userMarkdown || ""),
        agentsMarkdown: String(draft.documents.agentsMarkdown || ""),
        soulMarkdown: String(draft.documents.soulMarkdown || ""),
        identityMarkdown: String(draft.documents.identityMarkdown || "")
      }
    };

    setIsSaving(true);
    const response = await updateAgentConfig(agentId, payload);
    if (!response) {
      setStatusText("Failed to save config.");
      setIsSaving(false);
      return;
    }

    const config = response as any;
    setDraft({
      agentId: config.agentId || agentId,
      selectedModel: config.selectedModel || "",
      availableModels: Array.isArray(config.availableModels) ? config.availableModels : [],
      documents: {
        userMarkdown: String(config.documents?.userMarkdown || ""),
        agentsMarkdown: String(config.documents?.agentsMarkdown || ""),
        soulMarkdown: String(config.documents?.soulMarkdown || ""),
        identityMarkdown: String(config.documents?.identityMarkdown || "")
      }
    });
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

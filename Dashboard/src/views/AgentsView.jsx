import React, { useEffect, useMemo, useState } from "react";
import { createAgent as createAgentRequest, fetchAgent, fetchAgents } from "../api";

const AGENT_TABS = [
  { id: "overview", title: "Overview" },
  { id: "chat", title: "Chat" },
  { id: "memories", title: "Memories" },
  { id: "tasks", title: "Tasks" },
  { id: "skills", title: "Skills" },
  { id: "cron", title: "Cron" },
  { id: "config", title: "Config" }
];
const AGENT_TAB_SET = new Set(AGENT_TABS.map((tab) => tab.id));

function emptyAgentForm() {
  return {
    id: "",
    displayName: "",
    role: ""
  };
}

function normalizeAgent(item, index = 0) {
  const id = String(item?.id || `agent-${index + 1}`).trim();
  return {
    id,
    displayName: String(item?.displayName || id).trim() || id,
    role: String(item?.role || "").trim(),
    createdAt: item?.createdAt || new Date().toISOString()
  };
}

function mergeAgent(previousAgents, incomingAgent) {
  const normalized = normalizeAgent(incomingAgent);
  const withoutOld = previousAgents.filter((item) => item.id !== normalized.id);
  return [...withoutOld, normalized].sort((left, right) =>
    left.displayName.localeCompare(right.displayName, undefined, { sensitivity: "base" })
  );
}

function tabTitle(tabId) {
  return AGENT_TABS.find((tab) => tab.id === tabId)?.title || "Overview";
}

export function AgentsView({ routeAgentId = null, routeTab = "overview", onRouteChange = null }) {
  const [agents, setAgents] = useState([]);
  const [isLoadingAgents, setIsLoadingAgents] = useState(true);
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false);
  const [form, setForm] = useState(emptyAgentForm);
  const [createError, setCreateError] = useState("");
  const [statusText, setStatusText] = useState("Loading agents...");

  const activeAgent = useMemo(
    () => agents.find((agent) => agent.id === routeAgentId) || null,
    [agents, routeAgentId]
  );

  const activeTab = useMemo(() => {
    if (!activeAgent) {
      return "overview";
    }
    if (AGENT_TAB_SET.has(String(routeTab || "").toLowerCase())) {
      return String(routeTab).toLowerCase();
    }
    return "overview";
  }, [activeAgent, routeTab]);

  useEffect(() => {
    refreshAgents().catch(() => {
      setStatusText("Failed to load agents from Core");
      setIsLoadingAgents(false);
    });
  }, []);

  useEffect(() => {
    if (!routeAgentId) {
      return;
    }
    if (agents.some((agent) => agent.id === routeAgentId)) {
      return;
    }

    fetchAgent(routeAgentId).then((agent) => {
      if (!agent) {
        return;
      }
      setAgents((previous) => mergeAgent(previous, agent));
    });
  }, [routeAgentId, agents]);

  async function refreshAgents() {
    setIsLoadingAgents(true);
    const response = await fetchAgents();
    if (!Array.isArray(response)) {
      setStatusText("Failed to load agents from Core");
      setIsLoadingAgents(false);
      return;
    }

    const normalized = response
      .map((item, index) => normalizeAgent(item, index))
      .filter((item) => item.id.length > 0)
      .sort((left, right) => left.displayName.localeCompare(right.displayName, undefined, { sensitivity: "base" }));

    setAgents(normalized);
    setIsLoadingAgents(false);
    setStatusText(normalized.length > 0 ? `Loaded ${normalized.length} agents from Core` : "No agents yet. Create one.");
  }

  function navigateToAgent(agentId, tab = "overview") {
    if (typeof onRouteChange === "function") {
      onRouteChange(agentId, tab);
    }
  }

  function navigateToAgentList() {
    if (typeof onRouteChange === "function") {
      onRouteChange(null, null);
    }
  }

  function updateForm(field, value) {
    setForm((previous) => ({
      ...previous,
      [field]: value
    }));
  }

  function openCreateModal() {
    setForm(emptyAgentForm());
    setCreateError("");
    setIsCreateModalOpen(true);
  }

  function closeCreateModal() {
    setCreateError("");
    setIsCreateModalOpen(false);
  }

  async function createAgent(event) {
    event.preventDefault();

    const rawId = String(form.id || "").trim();
    const normalizedId = rawId.replace(/\s+/g, "-");
    const displayName = String(form.displayName || "").trim();
    const role = String(form.role || "").trim();

    if (!normalizedId) {
      setCreateError("Agent ID is required.");
      return;
    }

    const response = await createAgentRequest({
      id: normalizedId,
      displayName: displayName || normalizedId,
      role: role || "General-purpose assistant"
    });

    if (!response) {
      setCreateError("Failed to create agent in Core. Check ID format and duplicates.");
      return;
    }

    setAgents((previous) => mergeAgent(previous, response));
    setForm(emptyAgentForm());
    setStatusText(`Agent ${response.id} created in Core`);
    setIsCreateModalOpen(false);
  }

  function renderAgentTabContent(agent, tab) {
    if (tab === "overview") {
      return (
        <section className="entry-editor-card agent-content-card">
          <h3>Overview</h3>
          <p className="placeholder-text">Display Name: {agent.displayName}</p>
          <p className="placeholder-text">Agent ID: {agent.id}</p>
          <p className="placeholder-text">Role: {agent.role}</p>
        </section>
      );
    }

    if (tab === "chat") {
      return (
        <section className="entry-editor-card agent-content-card">
          <h3>Chat</h3>
          <p className="placeholder-text">Agent chat UI will be connected here.</p>
        </section>
      );
    }

    if (tab === "memories") {
      return (
        <section className="entry-editor-card agent-content-card">
          <h3>Memories</h3>
          <p className="placeholder-text">Memory timeline and storage controls for this agent.</p>
        </section>
      );
    }

    if (tab === "tasks") {
      return (
        <section className="entry-editor-card agent-content-card">
          <h3>Tasks</h3>
          <p className="placeholder-text">Task queue and execution state will appear here.</p>
        </section>
      );
    }

    if (tab === "skills") {
      return (
        <section className="entry-editor-card agent-content-card">
          <h3>Skills</h3>
          <p className="placeholder-text">Attach and configure skills for this agent.</p>
        </section>
      );
    }

    if (tab === "cron") {
      return (
        <section className="entry-editor-card agent-content-card">
          <h3>Cron</h3>
          <p className="placeholder-text">Scheduled jobs for this agent will be managed here.</p>
        </section>
      );
    }

    return (
      <section className="entry-editor-card agent-content-card">
        <h3>Config</h3>
        <p className="placeholder-text">Agent-specific runtime config and provider overrides.</p>
      </section>
    );
  }

  if (routeAgentId && !activeAgent) {
    return (
      <main className="agents-shell">
        <section className="entry-editor-card">
          <h2>{isLoadingAgents ? "Loading agent..." : "Agent Not Found"}</h2>
          <p className="placeholder-text">
            {isLoadingAgents ? "Synchronizing agent data from Core." : `Agent with id ${routeAgentId} does not exist in Core.`}
          </p>
          <div className="agent-inline-actions">
            <button type="button" onClick={navigateToAgentList}>
              Back To Agents
            </button>
          </div>
        </section>
      </main>
    );
  }

  if (!activeAgent) {
    return (
      <main className="agents-shell">
        <section className="agents-index">
          <header className="agents-index-head">
            <h2>Agents</h2>
            {agents.length > 0 && !isLoadingAgents ? (
              <button type="button" onClick={openCreateModal}>
                Create Agent
              </button>
            ) : null}
          </header>

          {isLoadingAgents ? (
            <div className="agents-empty-stage">
              <p className="placeholder-text">Loading agents from Core...</p>
            </div>
          ) : agents.length === 0 ? (
            <div className="agents-empty-stage">
              <p className="placeholder-text">Create your first agent to start work</p>
              <button type="button" className="agent-empty-create" onClick={openCreateModal}>
                Create Agent
              </button>
            </div>
          ) : (
            <div className="agent-list">
              {agents.map((agent) => (
                <button key={agent.id} type="button" className="agent-list-item" onClick={() => navigateToAgent(agent.id)}>
                  <strong>{agent.displayName}</strong>
                  <span>{agent.id}</span>
                  <p>{agent.role}</p>
                </button>
              ))}
            </div>
          )}
          {agents.length > 0 || statusText.startsWith("Failed") ? (
            <p className="agent-status-line placeholder-text">{statusText}</p>
          ) : null}
        </section>

        {isCreateModalOpen ? (
          <div className="agent-modal-overlay" onClick={closeCreateModal}>
            <section className="agent-modal-card" onClick={(event) => event.stopPropagation()}>
              <div className="agent-modal-head">
                <h3>Create Agent</h3>
                <button type="button" className="provider-close-button" onClick={closeCreateModal}>
                  ×
                </button>
              </div>
              <form className="agent-form" onSubmit={createAgent}>
                <label>
                  Agent ID
                  <input
                    value={form.id}
                    onChange={(event) => updateForm("id", event.target.value)}
                    placeholder="e.g. research_support_dev"
                  />
                  <span className="agent-field-note">Lowercase letters, numbers, hyphens, and underscores only.</span>
                </label>
                <label>
                  Display Name <span className="agent-field-optional">optional</span>
                  <input
                    value={form.displayName}
                    onChange={(event) => updateForm("displayName", event.target.value)}
                    placeholder="e.g. Research Agent"
                  />
                </label>
                <label>
                  Role <span className="agent-field-optional">optional</span>
                  <input
                    value={form.role}
                    onChange={(event) => updateForm("role", event.target.value)}
                    placeholder="e.g. Handles tier 1 support tickets"
                  />
                </label>
                {createError ? <p className="agent-create-error">{createError}</p> : null}
                <div className="agent-modal-actions">
                  <button type="button" onClick={closeCreateModal}>
                    Cancel
                  </button>
                  <button type="submit" className="agent-create-confirm">
                    Create
                  </button>
                </div>
              </form>
            </section>
          </div>
        ) : null}
      </main>
    );
  }

  return (
    <main className="agents-shell">
      <section className="entry-editor-card agent-header-card">
        <div className="agent-header-top">
          <button type="button" onClick={navigateToAgentList}>
            All Agents
          </button>
          <span className="placeholder-text">{activeAgent.id}</span>
        </div>
        <h2>{activeAgent.displayName}</h2>
        <p className="placeholder-text">{activeAgent.role}</p>
      </section>

      <section className="agent-tabs" aria-label="Agent sections">
        {AGENT_TABS.map((tab) => (
          <button
            key={tab.id}
            type="button"
            className={`agent-tab ${activeTab === tab.id ? "active" : ""}`}
            onClick={() => navigateToAgent(activeAgent.id, tab.id)}
          >
            {tab.title}
          </button>
        ))}
      </section>

      <section className="agent-content-shell">
        <div className="agent-content-header">
          <h3>{tabTitle(activeTab)}</h3>
          <span className="placeholder-text">/agents/{activeAgent.id}{activeTab === "overview" ? "" : `/${activeTab}`}</span>
        </div>
        {renderAgentTabContent(activeAgent, activeTab)}
      </section>
    </main>
  );
}

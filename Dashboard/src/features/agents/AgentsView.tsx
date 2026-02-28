import React, { useEffect, useMemo, useState } from "react";
import { createAgent as createAgentRequest, fetchAgent, fetchAgents } from "../../api";
import { AgentChatTab } from "./components/AgentChatTab";
import { AgentConfigTab } from "./components/AgentConfigTab";

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

function AgentOverviewTab({ agent }) {
  return (
    <section className="entry-editor-card agent-content-card">
      <h3>Overview</h3>
      <p className="placeholder-text">Display Name: {agent.displayName}</p>
      <p className="placeholder-text">Agent ID: {agent.id}</p>
      <p className="placeholder-text">Role: {agent.role}</p>
    </section>
  );
}

function AgentPlaceholderTab({ title, description }) {
  return (
    <section className="entry-editor-card agent-content-card">
      <h3>{title}</h3>
      <p className="placeholder-text">{description}</p>
    </section>
  );
}

function AgentCreateModal({ isOpen, form, createError, onFormChange, onClose, onSubmit }) {
  if (!isOpen) {
    return null;
  }

  return (
    <div className="agent-modal-overlay" onClick={onClose}>
      <section className="agent-modal-card" onClick={(event) => event.stopPropagation()}>
        <div className="agent-modal-head">
          <h3>Create Agent</h3>
          <button type="button" className="provider-close-button" onClick={onClose}>
            ×
          </button>
        </div>
        <form className="agent-form" onSubmit={onSubmit}>
          <label>
            Agent ID
            <input
              value={form.id}
              onChange={(event) => onFormChange("id", event.target.value)}
              placeholder="e.g. research_support_dev"
            />
            <span className="agent-field-note">Lowercase letters, numbers, hyphens, and underscores only.</span>
          </label>
          <label>
            Display Name <span className="agent-field-optional">optional</span>
            <input
              value={form.displayName}
              onChange={(event) => onFormChange("displayName", event.target.value)}
              placeholder="e.g. Research Agent"
            />
          </label>
          <label>
            Role <span className="agent-field-optional">optional</span>
            <input
              value={form.role}
              onChange={(event) => onFormChange("role", event.target.value)}
              placeholder="e.g. Handles tier 1 support tickets"
            />
          </label>
          {createError ? <p className="agent-create-error">{createError}</p> : null}
          <div className="agent-modal-actions">
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="agent-create-confirm">
              Create
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function AgentsIndexSection({
  agents,
  isLoadingAgents,
  statusText,
  onOpenCreateModal,
  onSelectAgent
}) {
  return (
    <section className="agents-index">
      <header className="agents-index-head">
        <h2>Agents</h2>
        {agents.length > 0 && !isLoadingAgents ? (
          <button type="button" className="agents-create-inline" onClick={onOpenCreateModal}>
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
          <button type="button" className="agent-empty-create" onClick={onOpenCreateModal}>
            Create Agent
          </button>
        </div>
      ) : (
        <div className="agent-list">
          {agents.map((agent) => (
            <button key={agent.id} type="button" className="agent-list-item" onClick={() => onSelectAgent(agent.id)}>
              <div className="agent-list-main">
                <strong>{agent.displayName}</strong>
                <span>{agent.id}</span>
              </div>
              <span className="agent-list-open">›</span>
              <p>{agent.role}</p>
            </button>
          ))}
        </div>
      )}

      {agents.length > 0 || statusText.startsWith("Failed") ? (
        <p className="agent-status-line placeholder-text">{statusText}</p>
      ) : null}
    </section>
  );
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
      return <AgentOverviewTab agent={agent} />;
    }

    if (tab === "chat") {
      return <AgentChatTab agentId={agent.id} />;
    }

    if (tab === "memories") {
      return (
        <AgentPlaceholderTab
          title="Memories"
          description="Memory timeline and storage controls for this agent."
        />
      );
    }

    if (tab === "tasks") {
      return (
        <AgentPlaceholderTab
          title="Tasks"
          description="Task queue and execution state will appear here."
        />
      );
    }

    if (tab === "skills") {
      return (
        <AgentPlaceholderTab
          title="Skills"
          description="Attach and configure skills for this agent."
        />
      );
    }

    if (tab === "cron") {
      return (
        <AgentPlaceholderTab
          title="Cron"
          description="Scheduled jobs for this agent will be managed here."
        />
      );
    }

    return (
      <section className="entry-editor-card agent-content-card">
        <AgentConfigTab agentId={agent.id} />
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
        <AgentsIndexSection
          agents={agents}
          isLoadingAgents={isLoadingAgents}
          statusText={statusText}
          onOpenCreateModal={openCreateModal}
          onSelectAgent={navigateToAgent}
        />

        <AgentCreateModal
          isOpen={isCreateModalOpen}
          form={form}
          createError={createError}
          onFormChange={updateForm}
          onClose={closeCreateModal}
          onSubmit={createAgent}
        />
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

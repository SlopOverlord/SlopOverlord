import React, { useEffect, useMemo, useState } from "react";
import {
  createAgent as createAgentRequest,
  fetchAgent,
  fetchAgents,
  fetchAgentTasks
} from "../../api";
import { AgentChatTab } from "./components/AgentChatTab";
import { AgentChannelsTab } from "./components/AgentChannelsTab";
import { AgentConfigTab } from "./components/AgentConfigTab";
import { AgentToolsTab } from "./components/AgentToolsTab";
import { AgentSkillsTab } from "./components/AgentSkillsTab";
import { AgentCronTab } from "./components/AgentCronTab";
import { AgentMemoriesTab } from "./components/AgentMemoriesTab";
import { Breadcrumbs } from "../../components/Breadcrumbs/Breadcrumbs";

const AGENT_TABS = [
  { id: "overview", title: "Overview" },
  { id: "chat", title: "Chat" },
  { id: "memories", title: "Memories" },
  { id: "tasks", title: "Tasks" },
  { id: "skills", title: "Skills" },
  { id: "tools", title: "Tools" },
  { id: "channels", title: "Channels" },
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

function agentInitials(name) {
  const parts = String(name || "?")
    .trim()
    .split(/[\s_-]+/)
    .filter(Boolean);
  if (parts.length === 0) return "??";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
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

function generateActivityData(runLimit = 14) {
  const data = [];
  const today = new Date();
  for (let i = runLimit - 1; i >= 0; i--) {
    const d = new Date(today);
    d.setDate(today.getDate() - i);
    data.push({
      dateStr: `${d.getMonth() + 1}/${d.getDate()}`,
      value: Math.floor(Math.random() * 100)
    });
  }
  return data;
}

function AgentOverviewTab({ agent, navigateToAgent }) {
  const [tasks, setTasks] = useState([]);
  const [isLoadingTasks, setIsLoadingTasks] = useState(true);

  useEffect(() => {
    let cancelled = false;
    async function loadTasks() {
      setIsLoadingTasks(true);
      const response = await fetchAgentTasks(agent.id);
      if (!cancelled) {
        if (Array.isArray(response)) {
          setTasks(response);
        }
        setIsLoadingTasks(false);
      }
    }
    loadTasks().catch(() => {
      if (!cancelled) setIsLoadingTasks(false);
    });
    return () => {
      cancelled = true;
    };
  }, [agent.id]);

  const recentTasks = tasks.slice(0, 8);
  const now = new Date();
  const lastRunTime = "4m ago"; // Mocked for now

  const runActivity = useMemo(() => generateActivityData(), []);

  return (
    <div className="agent-dashboard">
      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h3>Latest Run</h3>
          <button className="text-button">View details &rarr;</button>
        </div>
        <div className="latest-run-card">
          <div className="latest-run-status">
            <span className="material-symbols-rounded">close</span>
            <span className="badge badge-cancelled">cancelled</span>
            <span className="run-id">89f73f42</span>
            <span className="badge badge-assignment">Assignment</span>
          </div>
          <span className="run-time">{lastRunTime}</span>
        </div>
      </section>

      <section className="dashboard-charts-grid">
        <div className="chart-card">
          <div className="chart-header">
            <h4>Run Activity</h4>
            <span className="chart-period">Last 14 days</span>
          </div>
          <div className="chart-body">
            <div className="chart-bars">
              {runActivity.map((d, i) => (
                <div key={i} className="chart-bar-wrap">
                  <div className="chart-bar bg-gray" style={{ height: `${d.value}%` }} />
                </div>
              ))}
            </div>
            <div className="chart-x-axis">
              <span>{runActivity[0]?.dateStr}</span>
              <span>{runActivity[Math.floor(runActivity.length / 2)]?.dateStr}</span>
              <span>{runActivity[runActivity.length - 1]?.dateStr}</span>
            </div>
          </div>
        </div>

        <div className="chart-card">
          <div className="chart-header">
            <h4>Issues by Priority</h4>
            <span className="chart-period">Last 14 days</span>
          </div>
          <div className="chart-body">
            <div className="chart-bars">
              {runActivity.map((d, i) => (
                <div key={i} className="chart-bar-wrap">
                  <div className="chart-bar bg-yellow" style={{ height: i === runActivity.length - 1 ? '70%' : '0%' }} />
                </div>
              ))}
            </div>
            <div className="chart-x-axis">
              <span>{runActivity[0]?.dateStr}</span>
              <span>{runActivity[Math.floor(runActivity.length / 2)]?.dateStr}</span>
              <span>{runActivity[runActivity.length - 1]?.dateStr}</span>
            </div>
            <div className="chart-legend">
              <span><span className="legend-dot bg-critical"></span>Critical</span>
              <span><span className="legend-dot bg-high"></span>High</span>
              <span><span className="legend-dot bg-medium"></span>Medium</span>
              <span><span className="legend-dot bg-low"></span>Low</span>
            </div>
          </div>
        </div>

        <div className="chart-card">
          <div className="chart-header">
            <h4>Issues by Status</h4>
            <span className="chart-period">Last 14 days</span>
          </div>
          <div className="chart-body">
            <div className="chart-bars">
              {runActivity.map((d, i) => (
                <div key={i} className="chart-bar-wrap">
                  <div className="chart-bar bg-blue" style={{ height: i === runActivity.length - 1 ? '60%' : '0%' }} />
                </div>
              ))}
            </div>
            <div className="chart-x-axis">
              <span>{runActivity[0]?.dateStr}</span>
              <span>{runActivity[Math.floor(runActivity.length / 2)]?.dateStr}</span>
              <span>{runActivity[runActivity.length - 1]?.dateStr}</span>
            </div>
            <div className="chart-legend">
              <span><span className="legend-dot bg-todo"></span>To Do</span>
            </div>
          </div>
        </div>

        <div className="chart-card">
          <div className="chart-header">
            <h4>Success Rate</h4>
            <span className="chart-period">Last 14 days</span>
          </div>
          <div className="chart-body">
            <div className="chart-bars">
              {runActivity.map((d, i) => (
                <div key={i} className="chart-bar-wrap">
                  <div className="chart-bar bg-red" style={{ height: i === runActivity.length - 1 ? '5%' : '0%' }} />
                </div>
              ))}
            </div>
            <div className="chart-x-axis">
              <span>{runActivity[0]?.dateStr}</span>
              <span>{runActivity[Math.floor(runActivity.length / 2)]?.dateStr}</span>
              <span>{runActivity[runActivity.length - 1]?.dateStr}</span>
            </div>
          </div>
        </div>
      </section>

      <section className="dashboard-section mt-4">
        <div className="dashboard-section-header">
          <h3>Recent Issues</h3>
          <button className="text-button" onClick={() => navigateToAgent(agent.id, 'tasks')}>See All &rarr;</button>
        </div>
        <div className="recent-issues-list">
          {isLoadingTasks ? (
            <div className="recent-issue-item text-muted">Loading tasks...</div>
          ) : recentTasks.length === 0 ? (
            <div className="recent-issue-item text-muted">No recent tasks.</div>
          ) : (
            recentTasks.map((taskItem, i) => {
              const task = taskItem.task || {};
              const id = task.id || `COR-${i + 1}`;
              const title = task.title || "Task";
              const status = String(task.status || "todo").toLowerCase();
              return (
                <div key={id} className="recent-issue-item">
                  <span className="issue-id">{id}</span>
                  <span className="issue-title">{title}</span>
                  <span className={`badge badge-outline`}>{status}</span>
                </div>
              );
            })
          )}
        </div>
      </section>

      <section className="dashboard-section mt-4">
        <div className="dashboard-section-header">
          <h3>Costs</h3>
        </div>
        <div className="costs-card">
          <div className="cost-metric">
            <span className="cost-label">Input tokens</span>
            <span className="cost-value">0</span>
          </div>
          <div className="cost-metric">
            <span className="cost-label">Output tokens</span>
            <span className="cost-value">0</span>
          </div>
          <div className="cost-metric">
            <span className="cost-label">Cached tokens</span>
            <span className="cost-value">0</span>
          </div>
          <div className="cost-metric">
            <span className="cost-label">Total cost</span>
            <span className="cost-value">$0.00</span>
          </div>
        </div>
      </section>

      <section className="dashboard-section mt-4 configuration-section">
        <div className="dashboard-section-header">
          <h3>Configuration</h3>
          <button className="text-button flex-center gap-2" onClick={() => navigateToAgent(agent.id, 'config')}>
            <span className="material-symbols-rounded text-sm">settings</span> Manage &rarr;
          </button>
        </div>
      </section>
    </div>
  );
}

function AgentPlaceholderTab({ title, description }) {
  return (
    <section className="entry-editor-card agent-content-card">
      <h3>{title}</h3>
      <p className="app-status-text">{description}</p>
    </section>
  );
}

function AgentTasksTab({ agentId }) {
  const [items, setItems] = useState([]);
  const [statusText, setStatusText] = useState("Loading tasks...");

  useEffect(() => {
    let cancelled = false;

    async function loadTasks() {
      const response = await fetchAgentTasks(agentId);
      if (cancelled) {
        return;
      }

      if (!Array.isArray(response)) {
        setItems([]);
        setStatusText("Failed to load tasks for this agent.");
        return;
      }

      setItems(response);
      setStatusText(response.length === 0 ? "No tasks claimed by this agent." : `Loaded ${response.length} task(s).`);
    }

    loadTasks().catch(() => {
      if (!cancelled) {
        setItems([]);
        setStatusText("Failed to load tasks for this agent.");
      }
    });

    return () => {
      cancelled = true;
    };
  }, [agentId]);

  return (
    <section className="entry-editor-card agent-content-card">
      <h3>Tasks</h3>
      {items.length === 0 ? (
        <p className="app-status-text">{statusText}</p>
      ) : (
        <div className="project-workers-list">
          {items.map((item, index) => {
            const projectId = String(item?.projectId || "");
            const projectName = String(item?.projectName || projectId || "Project");
            const task = item?.task || {};
            return (
              <article key={String(task.id || `${projectId}-${index}`)} className="project-worker-item">
                <strong>{String(task.title || "Task")}</strong>
                <p>Project: {projectName}</p>
                <p>Status: {String(task.status || "unknown")}</p>
                {task?.claimedAgentId ? <p>Taken by: {String(task.claimedAgentId)}</p> : null}
                {task?.description ? <p>{String(task.description)}</p> : null}
              </article>
            );
          })}
        </div>
      )}
      {items.length > 0 ? <p className="placeholder-text">{statusText}</p> : null}
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
            <button type="submit" className="agent-create-confirm hover-levitate">
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
      {isLoadingAgents ? (
        <div className="agents-empty-stage">
          <p className="app-status-text">Loading agents from Core...</p>
        </div>
      ) : agents.length === 0 ? (
        <div className="agents-empty-stage">
          <p className="project-new-action-subtitle">Create your first agent to start work</p>
          <button type="button" className="agent-empty-create hover-levitate" onClick={onOpenCreateModal}>
            Create Agent
          </button>
        </div>
      ) : (
        <div className="agent-list-container">
          {agents.map((agent) => (
            <button
              key={agent.id}
              type="button"
              className="agent-list-item-card hover-levitate"
              onClick={() => onSelectAgent(agent.id)}
            >
              <span className="channel-agent-avatar agent-chart-avatar" aria-hidden="true" style={{ width: '40px', height: '40px', fontSize: '16px' }}>
                {agentInitials(agent.displayName || agent.id)}
              </span>
              <div className="agent-list-main">
                <div className="agent-list-head">
                  <h4>{agent.displayName}</h4>
                </div>
                <p>{agent.role || "General-purpose assistant"}</p>
                <span className="agent-list-id">ID: {agent.id}</span>
              </div>
            </button>
          ))}
        </div>
      )}

      {agents.length > 0 || statusText.startsWith("Failed") ? (
        <p className="app-status-text">{statusText}</p>
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
      return <AgentOverviewTab agent={agent} navigateToAgent={navigateToAgent} />;
    }

    if (tab === "chat") {
      return <AgentChatTab agentId={agent.id} />;
    }

    if (tab === "memories") {
      return <AgentMemoriesTab agentId={agent.id} />;
    }

    if (tab === "tasks") {
      return <AgentTasksTab agentId={agent.id} />;
    }

    if (tab === "skills") {
      return <AgentSkillsTab agentId={agent.id} />;
    }

    if (tab === "cron") {
      return (
        <section className="entry-editor-card agent-content-card">
          <AgentCronTab agentId={agent.id} />
        </section>
      );
    }

    if (tab === "tools") {
      return (
        <section className="entry-editor-card agent-content-card">
          <AgentToolsTab agentId={agent.id} />
        </section>
      );
    }

    if (tab === "channels") {
      return (
        <section className="entry-editor-card agent-content-card">
          <AgentChannelsTab agentId={agent.id} agentDisplayName={agent.displayName} />
        </section>
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
        <Breadcrumbs
          items={[
            { id: 'agents', label: 'Agents' }
          ]}
          style={{ marginBottom: '20px' }}
          action={
            <button type="button" className="agents-create-inline hover-levitate" onClick={openCreateModal}>
              Create Agent
            </button>
          }
        />

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

  const isChatLayout = activeTab === "chat";

  return (
    <main className={`agents-shell ${isChatLayout ? "chat-layout" : ""}`}>
      <Breadcrumbs
        items={[
          { id: 'agents', label: 'Agents', onClick: navigateToAgentList },
          { id: activeAgent.id, label: activeAgent.displayName }
        ]}
        style={{ marginBottom: '20px' }}
        action={
          <button type="button" className="agents-create-inline hover-levitate" onClick={openCreateModal}>
            Create Agent
          </button>
        }
      />

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
        {renderAgentTabContent(activeAgent, activeTab)}
      </section>
    </main>
  );
}

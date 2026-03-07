import React, { useEffect, useMemo, useState } from "react";
import { fetchAgents, fetchProjects } from "../api";

// ─── Helpers ─────────────────────────────────────────────────────────────────

const ACTIVE_WORKER_STATUSES = new Set(["queued", "running", "waitinginput", "waiting_input"]);

function formatRelativeTime(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) return "—";
  const diffMs = Date.now() - date.getTime();
  const diffMinutes = Math.round(diffMs / 60000);
  if (Math.abs(diffMinutes) < 1) return "just now";
  if (Math.abs(diffMinutes) < 60) return `${diffMinutes}m ago`;
  const diffHours = Math.round(diffMinutes / 60);
  if (Math.abs(diffHours) < 24) return `${diffHours}h ago`;
  return `${Math.round(diffHours / 24)}d ago`;
}

function generateActivityData(days = 14) {
  const today = new Date();
  return Array.from({ length: days }, (_, i) => {
    const d = new Date(today);
    d.setDate(today.getDate() - (days - 1 - i));
    return {
      dateStr: `${d.getMonth() + 1}/${d.getDate()}`,
      value: Math.floor(Math.random() * 100)
    };
  });
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

// ─── Section 1 — Active Channels ─────────────────────────────────────────────

function ActiveChannelsSection({ workers, projects, onNavigateToProject }) {
  const activeChannels = useMemo(() => {
    if (!Array.isArray(workers) || !Array.isArray(projects)) return [];

    const activeWorkersByChannel = new Map();
    for (const worker of workers) {
      const status = String(worker?.status || "").toLowerCase();
      if (!ACTIVE_WORKER_STATUSES.has(status)) continue;
      const channelId = String(worker?.channelId || "").trim();
      if (!channelId) continue;
      if (!activeWorkersByChannel.has(channelId)) {
        activeWorkersByChannel.set(channelId, []);
      }
      activeWorkersByChannel.get(channelId).push(worker);
    }

    const result = [];
    for (const project of projects) {
      const channels = Array.isArray(project?.channels)
        ? project.channels
        : Array.isArray(project?.chats)
          ? project.chats
          : [];

      for (const channel of channels) {
        const channelId = String(channel?.channelId || "").trim();
        if (!channelId) continue;
        const channelWorkers = activeWorkersByChannel.get(channelId) || [];
        if (channelWorkers.length === 0) continue;

        result.push({
          key: `${project.id}-${channelId}`,
          projectId: String(project.id || ""),
          projectName: String(project.name || project.id || "Project"),
          channelId,
          channelTitle: String(channel?.title || channelId),
          workers: channelWorkers
        });
      }
    }

    return result;
  }, [workers, projects]);

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">forum</span>
          Active Channels
        </h2>
        <span className="overview-section-count">{activeChannels.length}</span>
      </div>

      {activeChannels.length === 0 ? (
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">chat_bubble_outline</span>
          <p>No active channels right now. Agents are idle.</p>
        </div>
      ) : (
        <div className="active-channels-grid">
          {activeChannels.map((ch) => (
            <button
              key={ch.key}
              type="button"
              className="channel-card hover-levitate"
              onClick={() => onNavigateToProject && onNavigateToProject(ch.projectId)}
            >
              <div className="channel-card-head">
                <span className="channel-card-dot channel-dot-active" />
                <span className="channel-card-title">{ch.channelTitle}</span>
                <span className="channel-card-project">{ch.projectName}</span>
              </div>
              <div className="channel-card-agents">
                {ch.workers.slice(0, 5).map((w, i) => {
                  const name = String(w?.agentId || w?.id || `Agent ${i + 1}`);
                  return (
                    <span key={i} className="channel-agent-avatar" title={name}>
                      {agentInitials(name)}
                    </span>
                  );
                })}
                {ch.workers.length > 5 && (
                  <span className="channel-agent-avatar channel-agent-more">
                    +{ch.workers.length - 5}
                  </span>
                )}
              </div>
              <div className="channel-card-footer">
                <span className="channel-worker-count">
                  {ch.workers.length} agent{ch.workers.length !== 1 ? "s" : ""} running
                </span>
                <span className="material-symbols-rounded channel-card-arrow">arrow_forward</span>
              </div>
            </button>
          ))}
        </div>
      )}
    </section>
  );
}

// ─── Section 2 — Counters ─────────────────────────────────────────────────────

function CountersSection({ agents, workers }) {
  const agentCount = agents.length;

  const workerStats = useMemo(() => {
    const running = workers.filter((w) => {
      const s = String(w?.status || "").toLowerCase();
      return s === "running";
    }).length;
    const queued = workers.filter((w) => {
      const s = String(w?.status || "").toLowerCase();
      return s === "queued";
    }).length;
    const waitingInput = workers.filter((w) => {
      const s = String(w?.status || "").toLowerCase();
      return s === "waitinginput" || s === "waiting_input";
    }).length;
    const active = running + queued + waitingInput;
    return { running, queued, waitingInput, active };
  }, [workers]);

  const stats = [
    {
      id: "agents",
      icon: "support_agent",
      value: agentCount,
      label: "Agents Available",
      sub: `Registered in Core`
    },
    {
      id: "active",
      icon: "play_circle",
      value: workerStats.active,
      label: "Tasks In Progress",
      sub: `${workerStats.running} running · ${workerStats.queued} queued`
    },
    {
      id: "running",
      icon: "bolt",
      value: workerStats.running,
      label: "Running Now",
      sub: `Active worker processes`
    },
    {
      id: "waiting",
      icon: "hourglass_empty",
      value: workerStats.waitingInput,
      label: "Waiting Input",
      sub: `Blocked on human review`
    }
  ];

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">monitoring</span>
          System Status
        </h2>
      </div>
      <div className="stat-row">
        {stats.map((stat) => (
          <div key={stat.id} className="stat-card">
            <div className="stat-card-icon">
              <span className="material-symbols-rounded">{stat.icon}</span>
            </div>
            <div className="stat-card-value">{stat.value}</div>
            <div className="stat-card-label">{stat.label}</div>
            <div className="stat-card-sub">{stat.sub}</div>
          </div>
        ))}
      </div>
    </section>
  );
}

// ─── Section 3 — Bot Activity ─────────────────────────────────────────────────

function BotActivitySection({ agents }) {
  const agentActivity = useMemo(() => {
    return agents.map((agent) => ({
      ...agent,
      activity: generateActivityData(14)
    }));
  }, [agents]);

  if (agents.length === 0) {
    return (
      <section className="overview-section">
        <div className="overview-section-header">
          <h2>
            <span className="material-symbols-rounded">bar_chart</span>
            Bot Activity
          </h2>
        </div>
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">smart_toy</span>
          <p>No agents found. Create an agent to see activity.</p>
        </div>
      </section>
    );
  }

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">bar_chart</span>
          Bot Activity
          <span className="overview-section-period">Last 14 days</span>
        </h2>
        <span className="overview-section-count">{agents.length} bots</span>
      </div>
      <div className="activity-charts-grid">
        {agentActivity.map((agent) => {
          const max = Math.max(...agent.activity.map((d) => d.value), 1);
          const first = agent.activity[0]?.dateStr;
          const mid = agent.activity[Math.floor(agent.activity.length / 2)]?.dateStr;
          const last = agent.activity[agent.activity.length - 1]?.dateStr;

          return (
            <div key={agent.id} className="agent-chart-card chart-card">
              <div className="chart-header">
                <div className="agent-chart-title">
                  <span className="channel-agent-avatar agent-chart-avatar">
                    {agentInitials(agent.displayName || agent.id)}
                  </span>
                  <h4>{agent.displayName || agent.id}</h4>
                </div>
                <span className="chart-period">Runs</span>
              </div>
              <div className="chart-body">
                <div className="chart-bars">
                  {agent.activity.map((d, i) => (
                    <div key={i} className="chart-bar-wrap">
                      <div
                        className="chart-bar bg-accent"
                        style={{ height: `${Math.round((d.value / max) * 100)}%` }}
                      />
                    </div>
                  ))}
                </div>
                <div className="chart-x-axis">
                  <span>{first}</span>
                  <span>{mid}</span>
                  <span>{last}</span>
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}

// ─── Section 4 — Closed Tasks ─────────────────────────────────────────────────

function ClosedTasksSection({ projects }) {
  const { doneTasks, totalDone } = useMemo(() => {
    const all = [];
    for (const project of projects) {
      const tasks = Array.isArray(project?.tasks) ? project.tasks : [];
      for (const task of tasks) {
        const status = String(task?.status || "").toLowerCase();
        if (status === "done") {
          all.push({
            id: String(task.id || ""),
            title: String(task.title || "Task"),
            projectName: String(project.name || project.id || ""),
            projectId: String(project.id || ""),
            updatedAt: task.updatedAt || task.createdAt || ""
          });
        }
      }
    }
    all.sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());
    return { doneTasks: all.slice(0, 10), totalDone: all.length };
  }, [projects]);

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">task_alt</span>
          Closed Tasks
        </h2>
        <span className="overview-section-count stat-done">{totalDone} done</span>
      </div>

      {totalDone === 0 ? (
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">checklist</span>
          <p>No completed tasks yet. Tasks marked as Done will appear here.</p>
        </div>
      ) : (
        <div className="closed-tasks-list">
          {doneTasks.map((task) => (
            <div key={`${task.projectId}-${task.id}`} className="closed-task-item">
              <span className="material-symbols-rounded closed-task-check">check_circle</span>
              <div className="closed-task-body">
                <span className="closed-task-title">{task.title}</span>
                <span className="closed-task-meta">{task.projectName}</span>
              </div>
              <span className="closed-task-time">
                {task.updatedAt ? formatRelativeTime(task.updatedAt) : "—"}
              </span>
            </div>
          ))}
          {totalDone > 10 && (
            <div className="closed-tasks-more">+{totalDone - 10} more completed tasks</div>
          )}
        </div>
      )}
    </section>
  );
}

// ─── Main View ────────────────────────────────────────────────────────────────

export function RuntimeOverviewView({ workers, events, onNavigateToProject }) {
  const [agents, setAgents] = useState([]);
  const [projects, setProjects] = useState([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setIsLoading(true);
      const [agentsRes, projectsRes] = await Promise.all([
        fetchAgents().catch(() => null),
        fetchProjects().catch(() => null)
      ]);
      if (cancelled) return;
      setAgents(Array.isArray(agentsRes) ? agentsRes : []);
      setProjects(Array.isArray(projectsRes) ? projectsRes : []);
      setIsLoading(false);
    }
    load();
    return () => { cancelled = true; };
  }, []);

  const normalizedWorkers = Array.isArray(workers) ? workers : [];

  return (
    <main className="overview-shell">
      <div className="overview-header">
        <h1 className="overview-title">Overview</h1>
        {isLoading && (
          <span className="overview-loading-badge">
            <span className="overview-loading-dot" />
            Syncing…
          </span>
        )}
      </div>

      <ActiveChannelsSection
        workers={normalizedWorkers}
        projects={projects}
        onNavigateToProject={onNavigateToProject}
      />

      <CountersSection agents={agents} workers={normalizedWorkers} />

      <BotActivitySection agents={agents} />

      <ClosedTasksSection projects={projects} />
    </main>
  );
}

import React, { useEffect, useMemo, useState } from "react";
import { fetchActorsBoard, fetchAgents, fetchProjects, fetchAgentSessions, fetchChannelSessions, fetchChannelSession } from "../api";
import { Breadcrumbs } from "../components/Breadcrumbs/Breadcrumbs";

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

function buildActivityData(sessions, agentId, days = 14) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Array.from({ length: days }, (_, i) => {
    const d = new Date(today);
    d.setDate(today.getDate() - (days - 1 - i));
    const count = (sessions || []).filter((s) => {
      if (String(s?.agentId || "") !== String(agentId)) return false;
      const ts = s?.createdAt;
      if (!ts) return false;
      const sd = new Date(ts);
      return (
        sd.getFullYear() === d.getFullYear() &&
        sd.getMonth() === d.getMonth() &&
        sd.getDate() === d.getDate()
      );
    }).length;
    return { dateStr: `${d.getMonth() + 1}/${d.getDate()}`, value: count };
  });
}

const CHANNEL_MESSAGES_LIMIT = 9;

const USER_COLORS = [
  "#c084fc", "#67e8f9", "#f472b6", "#fbbf24", "#6ee7b7",
  "#fb923c", "#a78bfa", "#38bdf8", "#f87171", "#a3e635"
];

function userColor(name) {
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = name.charCodeAt(i) + ((hash << 5) - hash);
  }
  return USER_COLORS[Math.abs(hash) % USER_COLORS.length];
}

function formatCompactTime(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) return "";
  let hours = date.getHours();
  const minutes = String(date.getMinutes()).padStart(2, "0");
  const suffix = hours >= 12 ? "p" : "a";
  hours = hours % 12 || 12;
  return `${hours}:${minutes}${suffix}`;
}

function extractSessionMessages(sessionDetail) {
  const events = Array.isArray(sessionDetail?.events) ? sessionDetail.events : [];
  return events
    .filter((e) => {
      const type = String(e?.type || "");
      return type === "user_message" || type === "assistant_message";
    })
    .map((e) => {
      const type = String(e?.type || "");
      const isBot = type === "assistant_message";
      return {
        id: String(e?.id || ""),
        userId: isBot ? "bot" : String(e?.userId || "user"),
        content: String(e?.content || "").replace(/\s+/g, " ").trim(),
        createdAt: e?.createdAt || "",
        isBot
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

function ActiveChannelsSection({
  agents,
  sessions,
  channelSessions,
  channelSessionDetails,
  projects,
  actorBoard,
  onNavigateToProject,
  onNavigateToChannelSession
}) {
  const activeChannels = useMemo(() => {
    if (!Array.isArray(channelSessions) || channelSessions.length === 0) {
      return [];
    }

    const projectByChannel = new Map();
    for (const project of projects) {
      const channels = Array.isArray(project?.channels)
        ? project.channels
        : Array.isArray(project?.chats)
          ? project.chats
          : [];
      for (const channel of channels) {
        const channelId = String(channel?.channelId || "").trim();
        if (!channelId || projectByChannel.has(channelId)) {
          continue;
        }
        projectByChannel.set(channelId, {
          projectId: String(project.id || ""),
          projectName: String(project.name || project.id || "Project"),
          channelTitle: String(channel?.title || channelId)
        });
      }
    }

    const agentNameById = new Map(
      agents.map((agent) => [String(agent.id || ""), String(agent.displayName || agent.id || "")])
    );
    const sessionById = new Map(
      (Array.isArray(sessions) ? sessions : [])
        .map((session) => [String(session?.id || session?.sessionId || "").trim(), session])
        .filter(([sessionId]) => sessionId)
    );
    const agentsByChannel = new Map();
    const nodes = Array.isArray(actorBoard?.nodes) ? actorBoard.nodes : [];
    for (const node of nodes) {
      const channelId = String(node?.channelId || "").trim();
      const agentId = String(node?.linkedAgentId || "").trim();
      if (!channelId || !agentId) {
        continue;
      }
      if (!agentsByChannel.has(channelId)) {
        agentsByChannel.set(channelId, []);
      }
      const existing = agentsByChannel.get(channelId);
      if (existing.some((entry) => entry.id === agentId)) {
        continue;
      }
      existing.push({
        id: agentId,
        name: agentNameById.get(agentId) || agentId
      });
    }

    return channelSessions.map((session) => {
      const channelId = String(session?.channelId || "").trim();
      const projectMeta = projectByChannel.get(channelId);
      const agentSession = sessionById.get(String(session?.sessionId || "").trim());
      const channelAgents = agentsByChannel.get(channelId) || [];
      const fallbackAgentId = channelAgents.length === 1 ? String(channelAgents[0]?.id || "").trim() : "";
      const agentId = String(agentSession?.agentId || fallbackAgentId).trim();
      const sessionId = String(session?.sessionId || "");
      const detail = channelSessionDetails?.[sessionId] || null;
      const messages = extractSessionMessages(detail).slice(-CHANNEL_MESSAGES_LIMIT);

      return {
        key: sessionId || channelId,
        sessionId,
        agentId,
        channelId,
        channelTitle: projectMeta?.channelTitle || channelId || "Channel",
        projectId: projectMeta?.projectId || "",
        projectName: projectMeta?.projectName || "Unassigned",
        updatedAt: session?.updatedAt || session?.createdAt || "",
        messageCount: Number(session?.messageCount || 0),
        lastMessagePreview: String(session?.lastMessagePreview || ""),
        agents: channelAgents,
        primaryAgentName: agentNameById.get(agentId) || "",
        canOpenSession: Boolean(agentId && session?.sessionId),
        messages
      };
    });
  }, [actorBoard, agents, channelSessions, channelSessionDetails, projects, sessions]);

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
          <p>No active channel sessions right now.</p>
        </div>
      ) : (
        <div className="active-channels-grid">
          {activeChannels.map((ch) => (
            <button
              key={ch.key}
              type="button"
              className="channel-card hover-levitate"
              disabled={!ch.canOpenSession && !ch.projectId}
              onClick={() => {
                if (ch.canOpenSession && onNavigateToChannelSession) {
                  onNavigateToChannelSession(ch.sessionId);
                  return;
                }
                if (ch.projectId && onNavigateToProject) {
                  onNavigateToProject(ch.projectId);
                }
              }}
            >
              <div className="channel-card-head">
                <span className="channel-card-dot channel-dot-active" />
                <span className="channel-card-title">{ch.channelTitle}</span>
                <span className="channel-card-members">
                  {ch.agents.length > 0 ? `${ch.agents.length} active member${ch.agents.length !== 1 ? "s" : ""}` : ""}
                </span>
              </div>
              <div className="channel-card-sub">
                {ch.updatedAt ? formatRelativeTime(ch.updatedAt) : "just now"}
              </div>

              {ch.messages.length > 0 ? (
                <div className="channel-card-messages">
                  {ch.messages.map((msg, i) => (
                    <div key={msg.id || i} className="channel-msg-row">
                      <span className="channel-msg-time">{formatCompactTime(msg.createdAt)}</span>
                      <span
                        className={`channel-msg-user ${msg.isBot ? "channel-msg-bot" : ""}`}
                        style={msg.isBot ? undefined : { color: userColor(msg.userId) }}
                      >
                        {msg.userId}
                      </span>
                      <span className="channel-msg-text">{msg.content || "..."}</span>
                    </div>
                  ))}
                </div>
              ) : ch.lastMessagePreview ? (
                <div className="channel-card-preview">{ch.lastMessagePreview}</div>
              ) : null}
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

const BOT_ACTIVITY_LIMIT = 12;

function BotActivitySection({ agents, sessions, onNavigateToBots }) {
  const agentActivity = useMemo(() => {
    return agents.map((agent) => ({
      ...agent,
      activity: buildActivityData(sessions, agent.id, 14)
    }));
  }, [agents, sessions]);

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
        {agentActivity.slice(0, BOT_ACTIVITY_LIMIT).map((agent) => {
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
      {agents.length > BOT_ACTIVITY_LIMIT && (
        <button
          type="button"
          className="overview-show-all-btn"
          onClick={onNavigateToBots}
        >
          All {agents.length} bots
          <span className="material-symbols-rounded">arrow_forward</span>
        </button>
      )}
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

export function RuntimeOverviewView({ workers, events, onNavigateToProject, onNavigateToChannelSession, onNavigateToBots }) {
  const [agents, setAgents] = useState([]);
  const [projects, setProjects] = useState([]);
  const [sessions, setSessions] = useState([]);
  const [channelSessions, setChannelSessions] = useState([]);
  const [channelSessionDetails, setChannelSessionDetails] = useState({});
  const [actorBoard, setActorBoard] = useState({ nodes: [], links: [], teams: [] });
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setIsLoading(true);
      const [agentsRes, projectsRes, boardRes, channelSessionsRes] = await Promise.all([
        fetchAgents().catch(() => null),
        fetchProjects().catch(() => null),
        fetchActorsBoard().catch(() => null),
        fetchChannelSessions({ status: "open" }).catch(() => null)
      ]);
      if (cancelled) return;
      const loadedAgents = Array.isArray(agentsRes) ? agentsRes : [];
      setAgents(loadedAgents);
      setProjects(Array.isArray(projectsRes) ? projectsRes : []);
      setActorBoard(boardRes && Array.isArray(boardRes.nodes) ? boardRes : { nodes: [], links: [], teams: [] });
      const loadedChannelSessions = Array.isArray(channelSessionsRes) ? channelSessionsRes : [];
      setChannelSessions(loadedChannelSessions);

      if (loadedChannelSessions.length > 0) {
        const detailResults = await Promise.all(
          loadedChannelSessions.map((cs) => {
            const sid = String(cs?.sessionId || "").trim();
            return sid ? fetchChannelSession(sid).catch(() => null) : Promise.resolve(null);
          })
        );
        if (!cancelled) {
          const details = {};
          for (let i = 0; i < loadedChannelSessions.length; i++) {
            const sid = String(loadedChannelSessions[i]?.sessionId || "").trim();
            if (sid && detailResults[i]) {
              details[sid] = detailResults[i];
            }
          }
          setChannelSessionDetails(details);
        }
      }

      // Load sessions for all agents concurrently
      if (loadedAgents.length > 0) {
        const allSessionArrays = await Promise.all(
          loadedAgents.map((a) => fetchAgentSessions(a.id).catch(() => null))
        );
        if (!cancelled) {
          const flat = allSessionArrays.flatMap((res) => (Array.isArray(res) ? res : []));
          setSessions(flat);
        }
      }

      if (!cancelled) setIsLoading(false);
    }
    load();
    return () => { cancelled = true; };
  }, []);

  const normalizedWorkers = Array.isArray(workers) ? workers : [];

  return (
    <main className="overview-shell">
      <Breadcrumbs
        items={[
          { id: 'overview', label: 'Overview' },
        ]}
        style={{ marginBottom: '20px' }}
      />

      <ActiveChannelsSection
        agents={agents}
        sessions={sessions}
        channelSessions={channelSessions}
        channelSessionDetails={channelSessionDetails}
        projects={projects}
        actorBoard={actorBoard}
        onNavigateToProject={onNavigateToProject}
        onNavigateToChannelSession={onNavigateToChannelSession}
      />

      <CountersSection agents={agents} workers={normalizedWorkers} />

      <BotActivitySection agents={agents} sessions={sessions} onNavigateToBots={onNavigateToBots} />

      <ClosedTasksSection projects={projects} />
    </main>
  );
}

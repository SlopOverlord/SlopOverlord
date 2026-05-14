import React, { useEffect, useMemo, useState } from "react";
import { fetchActorsBoard, fetchChannelSessions, refreshProjectContext, subscribeProjectChangeStream } from "../../api";
import { gatewayBindingChannelId, sessionChannelMatchesBinding } from "../../shared/channelGatewayScope";

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
  const recentMessages = Array.isArray(sessionDetail?.recentMessages) ? sessionDetail.recentMessages : [];
  if (recentMessages.length > 0) {
    return recentMessages.map((msg) => ({
      id: String(msg?.id || ""),
      userId: msg?.isBot ? "bot" : String(msg?.userId || "user"),
      content: String(msg?.content || "").replace(/\s+/g, " ").trim(),
      createdAt: msg?.createdAt || "",
      isBot: Boolean(msg?.isBot)
    }));
  }

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

function normalizeId(raw) {
  return String(raw || "").trim();
}

function resolveProjectParticipants({ project, board }) {
  const nodes = Array.isArray(board?.nodes) ? board.nodes : [];
  const teams = Array.isArray(board?.teams) ? board.teams : [];
  const projectActors = Array.isArray(project?.actors) ? project.actors : [];
  const projectTeams = Array.isArray(project?.teams) ? project.teams : [];

  const nodesById = new Map(nodes.map((n) => [normalizeId(n?.id), n]));

  const nodeMatches = (node, raw) => {
    const value = normalizeId(raw).toLowerCase();
    if (!value) return false;
    return (
      normalizeId(node?.id).toLowerCase() === value ||
      normalizeId(node?.displayName).toLowerCase() === value ||
      normalizeId(node?.linkedAgentId).toLowerCase() === value
    );
  };

  const actorNodes = [];
  for (const raw of projectActors) {
    const value = normalizeId(raw);
    if (!value) continue;
    const direct = nodesById.get(value);
    if (direct) {
      actorNodes.push(direct);
      continue;
    }
    const match = nodes.find((n) => nodeMatches(n, value));
    if (match) actorNodes.push(match);
  }

  const resolvedTeams = [];
  const teamMemberNodes = [];
  for (const rawTeam of projectTeams) {
    const value = normalizeId(rawTeam).toLowerCase();
    if (!value) continue;
    const team = teams.find((t) => {
      return normalizeId(t?.id).toLowerCase() === value || normalizeId(t?.name).toLowerCase() === value;
    });
    if (!team) continue;
    resolvedTeams.push(team);
    const memberIds = Array.isArray(team.memberActorIds) ? team.memberActorIds : [];
    for (const memberId of memberIds) {
      const node = nodesById.get(normalizeId(memberId));
      if (node) teamMemberNodes.push(node);
    }
  }

  const uniqueNodes = new Map();
  for (const n of [...actorNodes, ...teamMemberNodes]) {
    const id = normalizeId(n?.id);
    if (!id) continue;
    uniqueNodes.set(id, n);
  }

  const participants = Array.from(uniqueNodes.values()).sort((a, b) => {
    const an = normalizeId(a?.displayName).toLowerCase();
    const bn = normalizeId(b?.displayName).toLowerCase();
    return an.localeCompare(bn);
  });

  return { participants, resolvedTeams };
}

export function ProjectChatTab({ project, onNavigateToChannelSession, onAddChannel }) {
  const [board, setBoard] = useState(null);
  const [channelSessions, setChannelSessions] = useState([]);
  const [sessionDetails, setSessionDetails] = useState({});
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [refreshStatus, setRefreshStatus] = useState("");
  const [changeBatches, setChangeBatches] = useState([]);

  const projectChannelIds = useMemo(() => {
    const chats = Array.isArray(project?.chats) ? project.chats : [];
    return new Set(chats.map((ch) => normalizeId(ch?.channelId)).filter(Boolean));
  }, [project]);

  const channelTitleById = useMemo(() => {
    const map = new Map();
    const chats = Array.isArray(project?.chats) ? project.chats : [];
    for (const ch of chats) {
      const channelId = normalizeId(ch?.channelId);
      if (channelId) {
        map.set(channelId, normalizeId(ch?.title) || channelId);
      }
    }
    return map;
  }, [project]);

  const { participants, resolvedTeams } = useMemo(() => {
    return resolveProjectParticipants({ project, board });
  }, [project, board]);

  useEffect(() => {
    let cancelled = false;
    async function loadBoard() {
      const res = await fetchActorsBoard().catch(() => null);
      if (cancelled) return;
      setBoard(res);
    }
    loadBoard();
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    let cancelled = false;
    async function loadSessions() {
      setIsLoading(true);
      const allSessions = await fetchChannelSessions({ status: "open", recentMessagesLimit: CHANNEL_MESSAGES_LIMIT }).catch(() => null);
      if (cancelled) return;

      const sessions = (Array.isArray(allSessions) ? allSessions : []).filter((s) => {
        const channelId = normalizeId(s?.channelId);
        if (!channelId) {
          return false;
        }
        for (const bindingId of projectChannelIds) {
          if (sessionChannelMatchesBinding(channelId, bindingId)) {
            return true;
          }
        }
        return false;
      });
      setChannelSessions(sessions);
      if (!cancelled) {
        setSessionDetails({});
        setIsLoading(false);
      }
    }
    loadSessions();
    return () => { cancelled = true; };
  }, [projectChannelIds]);

  useEffect(() => {
    const projectId = normalizeId(project?.id);
    if (!projectId) {
      setChangeBatches([]);
      return undefined;
    }
    return subscribeProjectChangeStream(projectId, {
      onBatch: (batch) => {
        setChangeBatches((prev) => [batch, ...prev].slice(0, 5));
      }
    });
  }, [project?.id]);

  const cards = useMemo(() => {
    return channelSessions.map((session) => {
      const channelId = normalizeId(session?.channelId);
      const sessionId = normalizeId(session?.sessionId);
      const detail = sessionDetails[sessionId] || session;
      const messages = extractSessionMessages(detail).slice(-CHANNEL_MESSAGES_LIMIT);

      return {
        key: sessionId || channelId,
        sessionId,
        channelId,
        channelTitle:
          channelTitleById.get(channelId) ||
          channelTitleById.get(gatewayBindingChannelId(channelId)) ||
          channelId ||
          "Channel",
        updatedAt: session?.updatedAt || session?.createdAt || "",
        messageCount: Number(session?.messageCount || 0),
        lastMessagePreview: normalizeId(session?.lastMessagePreview),
        canOpenSession: Boolean(sessionId),
        messages
      };
    });
  }, [channelSessions, sessionDetails, channelTitleById]);

  if (isLoading) {
    return (
      <section className="project-tab-layout">
        <p className="placeholder-text">Loading chat…</p>
      </section>
    );
  }

  return (
    <section className="project-tab-layout">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">groups</span>
          Project Participants
        </h2>
        <span className="overview-section-count">{participants.length}</span>
      </div>

      <div className="project-chat-actions">
        <button
          type="button"
          className="project-chat-refresh-btn hover-levitate"
          onClick={() => onAddChannel?.()}
        >
          <span className="material-symbols-rounded" aria-hidden="true">add</span>
          Add Channel
        </button>
        <button
          type="button"
          className="project-chat-refresh-btn hover-levitate"
          disabled={isRefreshing || !normalizeId(project?.repoPath)}
          title={!normalizeId(project?.repoPath) ? "Set repoPath in project settings to enable context loading." : "Refresh project context"}
          onClick={async () => {
            if (isRefreshing) return;
            setIsRefreshing(true);
            setRefreshStatus("");
            const res = await refreshProjectContext(normalizeId(project?.id)).catch(() => null);
            if (res) {
              const docs = Array.isArray(res.loadedDocPaths) ? res.loadedDocPaths.length : 0;
              const skills = Array.isArray(res.loadedSkillPaths) ? res.loadedSkillPaths.length : 0;
              const truncated = Boolean(res.truncated);
              setRefreshStatus(`Context applied (${docs} docs, ${skills} skills${truncated ? ", truncated" : ""}).`);
            } else {
              setRefreshStatus("Failed to refresh project context.");
            }
            setIsRefreshing(false);
          }}
        >
          <span className="material-symbols-rounded" aria-hidden="true">refresh</span>
          {isRefreshing ? "Refreshing…" : "Refresh Context"}
        </button>
        {refreshStatus ? <span className="project-chat-refresh-status">{refreshStatus}</span> : null}
      </div>

      {resolvedTeams.length > 0 ? (
        <p className="app-status-text" style={{ marginTop: 0 }}>
          Teams: {resolvedTeams.map((t) => normalizeId(t?.name) || normalizeId(t?.id)).filter(Boolean).join(", ")}
        </p>
      ) : null}

      {changeBatches.length > 0 ? (
        <div className="project-workspace-change-feed">
          {changeBatches.map((batch, index) => {
            const changes = Array.isArray(batch?.changes) ? batch.changes : [];
            return (
              <div key={`${batch?.createdAt || index}-${index}`} className="project-workspace-change-card">
                <div className="project-workspace-change-head">
                  <span className="material-symbols-rounded" aria-hidden="true">folder_code</span>
                  <strong>Workspace changes</strong>
                  <span>{changes.length}</span>
                </div>
                <div className="project-workspace-change-list">
                  {changes.slice(0, 6).map((change, i) => (
                    <span key={`${change?.path || i}-${i}`}>
                      {normalizeId(change?.kind) || "modified"}: {normalizeId(change?.path)}
                    </span>
                  ))}
                  {changes.length > 6 ? <span>and {changes.length - 6} more</span> : null}
                </div>
              </div>
            );
          })}
        </div>
      ) : null}

      {participants.length === 0 ? (
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">person_off</span>
          <p>No actors/teams assigned to this project yet.</p>
        </div>
      ) : (
        <div className="project-participants-grid">
          {participants.map((node) => {
            const id = normalizeId(node?.id);
            const name = normalizeId(node?.displayName) || id;
            const agentId = normalizeId(node?.linkedAgentId);
            const channelId = normalizeId(node?.channelId);
            return (
              <div key={id} className="project-participant-card">
                <div className="project-participant-head">
                  <span className="project-participant-name">{name}</span>
                  {agentId ? <span className="project-participant-agent">{agentId}</span> : null}
                </div>
                <div className="project-participant-meta">
                  <span className="project-participant-id">{id}</span>
                  {channelId ? <span className="project-participant-channel">#{channelId}</span> : null}
                </div>
              </div>
            );
          })}
        </div>
      )}

      <div className="overview-section-header" style={{ marginTop: 20 }}>
        <h2>
          <span className="material-symbols-rounded">forum</span>
          Active Channels
        </h2>
        <span className="overview-section-count">{cards.length}</span>
      </div>

      {cards.length === 0 ? (
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">chat_bubble_outline</span>
          <p>No active channel sessions for this project right now.</p>
        </div>
      ) : (
        <div className="active-channels-grid">
          {cards.map((ch) => (
            <button
              key={ch.key}
              type="button"
              className="channel-card hover-levitate"
              disabled={!ch.canOpenSession}
              onClick={() => {
                if (ch.canOpenSession && onNavigateToChannelSession) {
                  onNavigateToChannelSession(ch.sessionId);
                }
              }}
            >
              <div className="channel-card-head">
                <span className="channel-card-dot channel-dot-active" />
                <span className="channel-card-title">{ch.channelTitle}</span>
              </div>
              <div className="channel-card-sub">
                {ch.updatedAt ? formatRelativeTime(ch.updatedAt) : "just now"}
                {ch.messageCount > 0 ? ` · ${ch.messageCount} messages` : ""}
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

import React, { useEffect, useMemo, useState } from "react";
import {
  createActorNode,
  deleteActorNode,
  fetchAccessUsers,
  fetchActorsBoard,
  fetchAgentConfig,
  fetchChannelPlugins,
  fetchChannelSessions,
  updateAgentConfig
} from "../../../api";
import { ChannelModelSelector } from "./ChannelModelSelector";

const CHANNEL_MESSAGES_LIMIT = 9;

const USER_COLORS = [
  "#c084fc", "#67e8f9", "#f472b6", "#fbbf24", "#6ee7b7",
  "#fb923c", "#a78bfa", "#38bdf8", "#f87171", "#a3e635"
];

function slugify(value: string) {
  return value
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9\-_:]/g, "");
}

function userColor(name: string) {
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = name.charCodeAt(i) + ((hash << 5) - hash);
  }
  return USER_COLORS[Math.abs(hash) % USER_COLORS.length];
}

function formatRelativeTime(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "just now";
  }
  const diffMinutes = Math.max(0, Math.round((Date.now() - date.getTime()) / 60000));
  if (diffMinutes < 1) {
    return "just now";
  }
  if (diffMinutes < 60) {
    return `${diffMinutes}m ago`;
  }
  const diffHours = Math.round(diffMinutes / 60);
  if (diffHours < 24) {
    return `${diffHours}h ago`;
  }
  return `${Math.round(diffHours / 24)}d ago`;
}

function formatCompactTime(dateValue: string) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) return "";
  let hours = date.getHours();
  const minutes = String(date.getMinutes()).padStart(2, "0");
  const suffix = hours >= 12 ? "p" : "a";
  hours = hours % 12 || 12;
  return `${hours}:${minutes}${suffix}`;
}

function extractSessionMessages(sessionDetail: any) {
  const recentMessages = Array.isArray(sessionDetail?.recentMessages) ? sessionDetail.recentMessages : [];
  if (recentMessages.length > 0) {
    return recentMessages.map((msg: any) => ({
      id: String(msg?.id || ""),
      userId: msg?.isBot ? "bot" : String(msg?.userId || "user"),
      content: String(msg?.content || "").replace(/\s+/g, " ").trim(),
      createdAt: msg?.createdAt || "",
      isBot: Boolean(msg?.isBot)
    }));
  }

  const events = Array.isArray(sessionDetail?.events) ? sessionDetail.events : [];
  return events
    .filter((e: any) => {
      const type = String(e?.type || "");
      return type === "user_message" || type === "assistant_message";
    })
    .map((e: any) => {
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

function uniqueIds(values: string[]) {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const trimmed = String(value || "").trim();
    if (!trimmed || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    result.push(trimmed);
  }
  return result;
}

function channelSettings(config: any) {
  return {
    autoCloseEnabled: Boolean(config?.channelSessions?.autoCloseEnabled),
    autoCloseAfterMinutes: Number.parseInt(String(config?.channelSessions?.autoCloseAfterMinutes ?? 30), 10) || 30,
    inboundActivation: config?.channelSessions?.inboundActivation === "mention_or_reply" ? "mention_or_reply" : "all",
    allowedChannelIds: Array.isArray(config?.channelSessions?.allowedChannelIds)
      ? uniqueIds(config.channelSessions.allowedChannelIds)
      : [],
    excludedChannelIds: Array.isArray(config?.channelSessions?.excludedChannelIds)
      ? uniqueIds(config.channelSessions.excludedChannelIds)
      : []
  };
}

export function AgentChannelsTab({ agentId, agentDisplayName, onNavigateToChannelSession = null }) {
  const [nodes, setNodes] = useState([]);
  const [activeSessions, setActiveSessions] = useState([]);
  const [sessionDetails, setSessionDetails] = useState<Record<string, any>>({});
  const [agentConfig, setAgentConfig] = useState<any | null>(null);
  const [accessUsers, setAccessUsers] = useState<any[]>([]);
  const [channelPlugins, setChannelPlugins] = useState<any[]>([]);
  const [statusText, setStatusText] = useState("Loading channels...");
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [newChannelId, setNewChannelId] = useState("");
  const [channelDropdownOpen, setChannelDropdownOpen] = useState(false);
  const [formError, setFormError] = useState("");

  const settings = useMemo(() => channelSettings(agentConfig), [agentConfig]);

  const configuredRows = useMemo(() => {
    const byChannel = new Map<string, any>();
    for (const node of nodes) {
      const channelId = String(node?.channelId || "").trim();
      if (!channelId) {
        continue;
      }
      byChannel.set(channelId, { channelId, node, source: "actor node" });
    }
    for (const channelId of settings.allowedChannelIds) {
      if (!byChannel.has(channelId)) {
        byChannel.set(channelId, { channelId, node: null, source: "config allow" });
      }
    }
    for (const channelId of settings.excludedChannelIds) {
      if (!byChannel.has(channelId)) {
        byChannel.set(channelId, { channelId, node: null, source: "config exclude" });
      }
    }
    return Array.from(byChannel.values()).map((row) => ({
      ...row,
      isAllowed: settings.allowedChannelIds.includes(row.channelId) || Boolean(row.node),
      isExcluded: settings.excludedChannelIds.includes(row.channelId)
    }));
  }, [nodes, settings.allowedChannelIds, settings.excludedChannelIds]);

  const channelSuggestions = useMemo(() => {
    const suggestions = new Map<string, { value: string; label: string; meta: string }>();
    function addSuggestion(value: string, label: string, meta: string) {
      const trimmed = String(value || "").trim();
      if (!trimmed || suggestions.has(trimmed)) {
        return;
      }
      suggestions.set(trimmed, { value: trimmed, label, meta });
    }

    for (const node of nodes) {
      const channelId = String(node?.channelId || "").trim();
      addSuggestion(channelId, channelId, "linked channel");
    }
    for (const plugin of channelPlugins) {
      const pluginId = String(plugin?.id || plugin?.type || "plugin");
      const ids = Array.isArray(plugin?.channelIds) ? plugin.channelIds : [];
      for (const channelId of ids) {
        addSuggestion(String(channelId), String(channelId), `${pluginId} channel`);
      }
    }
    for (const session of activeSessions) {
      const channelId = String(session?.channelId || "").trim();
      addSuggestion(channelId, channelId, "active session");
      const detail = sessionDetails[String(session?.sessionId || "")] || session;
      for (const msg of extractSessionMessages(detail)) {
        if (!msg.isBot) {
          addSuggestion(msg.userId, msg.userId, `user in ${channelId || "session"}`);
        }
      }
    }
    for (const user of accessUsers) {
      const platform = String(user?.platform || "").trim();
      const platformUserId = String(user?.platformUserId || "").trim();
      const displayName = String(user?.displayName || "").trim();
      if (platformUserId) {
        addSuggestion(platformUserId, displayName || platformUserId, `${platform || "channel"} user`);
      }
    }

    const query = newChannelId.trim().toLowerCase();
    return Array.from(suggestions.values())
      .filter((item) => {
        if (!query) {
          return true;
        }
        return item.value.toLowerCase().includes(query) || item.label.toLowerCase().includes(query) || item.meta.toLowerCase().includes(query);
      })
      .slice(0, 12);
  }, [accessUsers, activeSessions, channelPlugins, newChannelId, nodes, sessionDetails]);

  function updateStatusText(channelCount: number, sessionCount: number) {
    setStatusText(
      `${channelCount} channel${channelCount !== 1 ? "s" : ""} · ` +
      `${sessionCount} active session${sessionCount !== 1 ? "s" : ""}`
    );
  }

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setIsLoading(true);
      const [board, sessions, config, users, plugins] = await Promise.all([
        fetchActorsBoard(),
        fetchChannelSessions({ status: "open", agentId, recentMessagesLimit: CHANNEL_MESSAGES_LIMIT }),
        fetchAgentConfig(agentId).catch(() => null),
        fetchAccessUsers().catch(() => null),
        fetchChannelPlugins().catch(() => null)
      ]);
      if (cancelled) {
        return;
      }
      if (!board || !Array.isArray(board.nodes)) {
        setNodes([]);
        setActiveSessions([]);
        setSessionDetails({});
        setAgentConfig(null);
        setAccessUsers([]);
        setChannelPlugins([]);
        setStatusText("Failed to load channels.");
        setIsLoading(false);
        return;
      }
      const agentNodes = board.nodes.filter((n) => n.linkedAgentId === agentId);
      const nextConfig = config || null;
      setNodes(agentNodes);
      setAgentConfig(nextConfig);
      setAccessUsers(Array.isArray(users) ? users : []);
      setChannelPlugins(Array.isArray(plugins) ? plugins : []);
      const nextSessions = Array.isArray(sessions) ? sessions : [];
      setActiveSessions(nextSessions);
      updateStatusText(
        uniqueIds([
          ...agentNodes.map((n) => String(n?.channelId || "")),
          ...channelSettings(nextConfig).allowedChannelIds,
          ...channelSettings(nextConfig).excludedChannelIds
        ]).length,
        nextSessions.length
      );
      setSessionDetails({});
      if (!cancelled) setIsLoading(false);
    }

    load().catch(() => {
      if (!cancelled) {
        setNodes([]);
        setActiveSessions([]);
        setSessionDetails({});
        setAgentConfig(null);
        setAccessUsers([]);
        setChannelPlugins([]);
        setStatusText("Failed to load channels.");
        setIsLoading(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [agentId]);

  async function refreshData() {
    const [board, sessions, config, users, plugins] = await Promise.all([
      fetchActorsBoard(),
      fetchChannelSessions({ status: "open", agentId, recentMessagesLimit: CHANNEL_MESSAGES_LIMIT }),
      fetchAgentConfig(agentId).catch(() => null),
      fetchAccessUsers().catch(() => null),
      fetchChannelPlugins().catch(() => null)
    ]);
    if (!board || !Array.isArray(board.nodes)) {
      return;
    }
    const agentNodes = board.nodes.filter((n) => n.linkedAgentId === agentId);
    const nextConfig = config || agentConfig;
    setNodes(agentNodes);
    setAgentConfig(nextConfig);
    setAccessUsers(Array.isArray(users) ? users : []);
    setChannelPlugins(Array.isArray(plugins) ? plugins : []);
    const nextSessions = Array.isArray(sessions) ? sessions : [];
    setActiveSessions(nextSessions);
    updateStatusText(
      uniqueIds([
        ...agentNodes.map((n) => String(n?.channelId || "")),
        ...channelSettings(nextConfig).allowedChannelIds,
        ...channelSettings(nextConfig).excludedChannelIds
      ]).length,
      nextSessions.length
    );
    setSessionDetails({});
  }

  async function saveChannelSessionSettings(nextSettings: any) {
    const config = agentConfig || await fetchAgentConfig(agentId);
    if (!config) {
      return false;
    }
    const payload = {
      role: String(config.role || ""),
      selectedModel: config.selectedModel ?? null,
      documents: config.documents,
      heartbeat: config.heartbeat,
      channelSessions: nextSettings,
      runtime: config.runtime || { type: "native" }
    };
    const updated = await updateAgentConfig(agentId, payload);
    setAgentConfig(updated);
    return true;
  }

  async function addChannel() {
    const channelId = slugify(newChannelId);
    if (!channelId) {
      setFormError("Channel ID is required.");
      return;
    }
    const alreadyExists = configuredRows.some((row) => row.channelId === channelId && row.isAllowed && !row.isExcluded);
    if (alreadyExists) {
      setFormError("A channel with this ID is already linked to this agent.");
      return;
    }

    setIsSaving(true);
    setFormError("");

    const nextSettings = {
      ...settings,
      allowedChannelIds: uniqueIds([...settings.allowedChannelIds, channelId]),
      excludedChannelIds: settings.excludedChannelIds.filter((id) => id !== channelId)
    };
    const saved = await saveChannelSessionSettings(nextSettings).catch(() => false);
    if (!saved) {
      setIsSaving(false);
      setFormError("Failed to save channel allow list.");
      return;
    }

    const nodeId = `actor:${agentId}:${channelId}`;
    const payload = {
      id: nodeId,
      displayName: agentDisplayName || agentId,
      kind: "agent",
      linkedAgentId: agentId,
      channelId,
      positionX: 120 + nodes.length * 220,
      positionY: 120,
      createdAt: new Date().toISOString()
    };

    const hasNode = nodes.some((n) => n.id === nodeId || n.channelId === channelId);
    const result = hasNode ? true : await createActorNode(payload);
    setIsSaving(false);

    if (!result) {
      setFormError("Allow list saved, but the actor board link could not be created.");
      return;
    }

    await refreshData();
    setNewChannelId("");
    setShowForm(false);
  }

  async function excludeChannel() {
    const channelId = slugify(newChannelId);
    if (!channelId) {
      setFormError("Channel ID is required.");
      return;
    }
    setIsSaving(true);
    setFormError("");
    const nextSettings = {
      ...settings,
      allowedChannelIds: settings.allowedChannelIds.filter((id) => id !== channelId),
      excludedChannelIds: uniqueIds([...settings.excludedChannelIds, channelId])
    };
    const saved = await saveChannelSessionSettings(nextSettings).catch(() => false);
    setIsSaving(false);
    if (!saved) {
      setFormError("Failed to save channel exclude list.");
      return;
    }
    await refreshData();
    setNewChannelId("");
    setShowForm(false);
  }

  async function removeChannel(nodeId) {
    const row = configuredRows.find((entry) => entry.node?.id === nodeId || entry.channelId === nodeId);
    const node = row?.node || null;
    const channelId = row?.channelId || "";
    const ok = node ? await deleteActorNode(node.id) : true;
    if (!ok || !channelId) {
      return;
    }
    const nextSettings = {
      ...settings,
      allowedChannelIds: settings.allowedChannelIds.filter((id) => id !== channelId),
      excludedChannelIds: settings.excludedChannelIds.filter((id) => id !== channelId)
    };
    await saveChannelSessionSettings(nextSettings).catch(() => null);
    setNodes((previous) => {
      const next = previous.filter((n) => n.id !== node?.id);
      const nextChannelCount = Math.max(0, configuredRows.length - 1);
      setStatusText(
        `${nextChannelCount} channel${nextChannelCount !== 1 ? "s" : ""} · ` +
        `${activeSessions.length} active session${activeSessions.length !== 1 ? "s" : ""}`
      );
      return next;
    });
    await refreshData();
  }

  async function toggleExcluded(channelId: string) {
    const isExcluded = settings.excludedChannelIds.includes(channelId);
    const nextSettings = {
      ...settings,
      excludedChannelIds: isExcluded
        ? settings.excludedChannelIds.filter((id) => id !== channelId)
        : uniqueIds([...settings.excludedChannelIds, channelId])
    };
    setIsSaving(true);
    const saved = await saveChannelSessionSettings(nextSettings).catch(() => false);
    setIsSaving(false);
    if (saved) {
      await refreshData();
    }
  }

  function handleFormKeyDown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      void addChannel();
    }
    if (event.key === "Escape") {
      setShowForm(false);
      setNewChannelId("");
      setFormError("");
    }
  }

  return (
    <section className="agent-config-shell agent-channels-shell">
      <div className="agent-config-head">
        <div className="agent-tools-head-copy">
          <h3>Channels</h3>
          <p className="placeholder-text">Channel IDs this agent is available in for receiving messages.</p>
        </div>
        <span className="agent-tools-status">{statusText}</span>
      </div>

      {isLoading ? (
        <p className="placeholder-text">Loading...</p>
      ) : (
        <>
          {configuredRows.length === 0 && !showForm ? (
            <div className="agent-channels-empty">
              <p className="placeholder-text">No channels configured. Add a channel ID to connect this agent to incoming messages.</p>
            </div>
          ) : (
            <div className="agent-channels-list">
              {configuredRows.map((row) => {
                const channelId = row.channelId;
                return (
                  <div key={channelId} className={`agent-channel-row ${row.isExcluded ? "is-excluded" : ""}`}>
                    <div className="agent-channel-info">
                      <span className="agent-channel-id">
                        <span className="material-symbols-rounded agent-channel-icon">forum</span>
                        {channelId}
                        {row.isExcluded ? <span className="agent-channel-badge danger">excluded</span> : null}
                        {row.source === "config allow" ? <span className="agent-channel-badge">config</span> : null}
                      </span>
                      <span className="agent-channel-node-id">
                        {row.node ? `actor node · ${row.node.id}` : row.source}
                      </span>
                    </div>
                    <div className="agent-channel-actions">
                      <ChannelModelSelector channelId={channelId} />
                      <button
                        type="button"
                        className={`agent-channel-exclude ${row.isExcluded ? "active" : ""}`}
                        onClick={() => void toggleExcluded(channelId)}
                        title={row.isExcluded ? "Remove from exclude list" : "Exclude this channel for this agent"}
                        disabled={isSaving}
                      >
                        <span className="material-symbols-rounded">{row.isExcluded ? "block" : "do_not_disturb_on"}</span>
                      </button>
                      <button
                        type="button"
                        className="agent-channel-remove"
                        onClick={() => void removeChannel(channelId)}
                        title="Remove channel"
                        disabled={isSaving}
                      >
                        <span className="material-symbols-rounded">delete</span>
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}

          <section className="agent-channel-sessions-panel">
            <div className="agent-config-head">
              <div className="agent-tools-head-copy">
                <h4>Active Sessions</h4>
                <p className="placeholder-text">Open incoming channel sessions that have not been auto-closed yet.</p>
              </div>
              <span className="agent-tools-status">
                {activeSessions.length} active
              </span>
            </div>

            {activeSessions.length === 0 ? (
              <div className="agent-channels-empty">
                <p className="placeholder-text">No active channel sessions right now.</p>
              </div>
            ) : (
              <div className="active-channels-grid">
                {activeSessions.map((session) => {
                  const sessionId = String(session.sessionId || "");
                  const detail = sessionDetails[sessionId] || session;
                  const messages = extractSessionMessages(detail).slice(-CHANNEL_MESSAGES_LIMIT);
                  const messageCount = Number(session.messageCount || 0);

                  const canOpen = Boolean(sessionId && onNavigateToChannelSession);

                  return (
                    <button
                      key={session.sessionId || session.channelId}
                      type="button"
                      className="channel-card hover-levitate"
                      disabled={!canOpen}
                      onClick={() => {
                        if (canOpen) {
                          onNavigateToChannelSession(sessionId);
                        }
                      }}
                    >
                      <div className="channel-card-head">
                        <span className="channel-card-dot channel-dot-active" />
                        <span className="channel-card-title">{session.channelId}</span>
                      </div>
                      <div className="channel-card-sub">
                        {formatRelativeTime(String(session.updatedAt || session.createdAt || ""))}
                        {messageCount > 0 ? ` · ${messageCount} messages` : ""}
                      </div>

                      {messages.length > 0 ? (
                        <div className="channel-card-messages">
                          {messages.map((msg, i) => (
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
                      ) : session.lastMessagePreview ? (
                        <div className="channel-card-preview">{session.lastMessagePreview}</div>
                      ) : null}
                    </button>
                  );
                })}
              </div>
            )}
          </section>

          {showForm ? (
            <div className="agent-channel-form">
              <label className="agent-channel-form-label">
                Channel or User ID
                <span className="agent-channel-form-hint">Pick an existing channel/user ID, or type a new lowercase ID with letters, numbers, hyphens, underscores, and colons.</span>
                <div className="actor-team-search-wrap">
                  <input
                    className="actor-team-search"
                    value={newChannelId}
                    onChange={(event) => {
                      setNewChannelId(event.target.value);
                      setChannelDropdownOpen(true);
                    }}
                    onFocus={() => setChannelDropdownOpen(true)}
                    onBlur={() => setTimeout(() => setChannelDropdownOpen(false), 150)}
                    onKeyDown={handleFormKeyDown}
                    placeholder="e.g. support, general, tg:my-group"
                    autoComplete="off"
                    autoFocus
                  />
                  {channelDropdownOpen ? (
                    <ul className="actor-team-dropdown">
                      {channelSuggestions.length === 0 ? (
                        <li className="actor-team-dropdown-empty">No known channels or users.</li>
                      ) : (
                        channelSuggestions.map((suggestion) => (
                          <li
                            key={suggestion.value}
                            className={`actor-team-dropdown-item ${slugify(newChannelId) === slugify(suggestion.value) ? "selected" : ""}`}
                            onMouseDown={(event) => {
                              event.preventDefault();
                              setNewChannelId(suggestion.value);
                              setChannelDropdownOpen(false);
                            }}
                          >
                            <span className="actor-team-dropdown-name">{suggestion.label}</span>
                            <span className="actor-team-dropdown-id">{suggestion.value}</span>
                            <span className="actor-team-dropdown-id">{suggestion.meta}</span>
                          </li>
                        ))
                      )}
                    </ul>
                  ) : null}
                </div>
              </label>
              {formError ? <p className="agent-create-error">{formError}</p> : null}
              <div className="agent-channel-form-actions">
                <button
                  type="button"
                  onClick={() => {
                    setShowForm(false);
                    setNewChannelId("");
                    setFormError("");
                  }}
                >
                  Cancel
                </button>
                <button type="button" disabled={isSaving} onClick={() => void excludeChannel()}>
                  {isSaving ? "Saving..." : "Exclude"}
                </button>
                <button type="button" className="agent-create-confirm hover-levitate" disabled={isSaving} onClick={() => void addChannel()}>
                  {isSaving ? "Adding..." : "Add Channel"}
                </button>
              </div>
            </div>
          ) : (
            <button type="button" className="agent-channels-add-btn" onClick={() => setShowForm(true)}>
              <span className="material-symbols-rounded">add</span>
              Add Channel
            </button>
          )}
        </>
      )}
    </section>
  );
}

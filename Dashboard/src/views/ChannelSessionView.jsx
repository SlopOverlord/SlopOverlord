import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  fetchAgent,
  fetchAgentSession,
  fetchActorsBoard,
  fetchChannelSessions,
  fetchProjects,
  subscribeAgentSessionStream
} from "../api";
import { Breadcrumbs } from "../components/Breadcrumbs/Breadcrumbs";

function formatRelativeTime(value) {
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

function formatDateTime(value) {
  if (!value) {
    return "—";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "—";
  }
  return date.toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  });
}

function formatEventTime(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function agentInitials(name) {
  const parts = String(name || "?")
    .trim()
    .split(/[\s_-]+/)
    .filter(Boolean);
  if (parts.length === 0) {
    return "??";
  }
  if (parts.length === 1) {
    return parts[0].slice(0, 2).toUpperCase();
  }
  return `${parts[0][0]}${parts[1][0]}`.toUpperCase();
}

function previewText(value, fallback = "No details") {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  if (!normalized) {
    return fallback;
  }
  if (normalized.length > 120) {
    return `${normalized.slice(0, 120)}...`;
  }
  return normalized;
}

function formatStructuredData(value) {
  if (value == null) {
    return "";
  }
  if (typeof value === "string") {
    return value;
  }
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function extractEventKey(event, index) {
  return event?.id || `${event?.type || "event"}-${index}`;
}

function segmentsToPlainText(segments) {
  return (segments || [])
    .map((segment) => {
      if (segment.kind === "text") {
        return String(segment.text || "").trim();
      }
      if (segment.kind === "attachment" && segment.attachment?.name) {
        return `[Attachment: ${segment.attachment.name}]`;
      }
      return "";
    })
    .filter(Boolean)
    .join("\n")
    .trim();
}

function latestRunStatusFromEvents(events) {
  return [...(Array.isArray(events) ? events : [])]
    .reverse()
    .find((eventItem) => eventItem?.type === "run_status" && eventItem?.runStatus)?.runStatus;
}

function getSessionDisplayLabel(session) {
  const title = String(session?.title || "").trim();
  const preview = String(session?.lastMessagePreview || "").trim();
  const isDefaultTitle = /^Session\s+session-/i.test(title);
  if (isDefaultTitle && preview) {
    return preview.length > 80 ? `${preview.slice(0, 80)}...` : preview;
  }
  return title || preview || "Session";
}

function buildTechnicalRecord(eventItem, index) {
  const eventKey = extractEventKey(eventItem, index);

  if (eventItem?.type === "run_status" && eventItem.runStatus) {
    const stage = String(eventItem.runStatus.stage || "").toLowerCase();
    if (stage === "responding" || stage === "done") {
      return null;
    }

    const label = eventItem.runStatus.label || eventItem.runStatus.stage || "Status";
    const summary = eventItem.runStatus.details || eventItem.runStatus.expandedText || label;
    const detailParts = [];
    if (eventItem.runStatus.stage) {
      detailParts.push(`Stage: ${eventItem.runStatus.stage}`);
    }
    if (eventItem.runStatus.details) {
      detailParts.push(eventItem.runStatus.details);
    }
    if (eventItem.runStatus.expandedText) {
      detailParts.push(eventItem.runStatus.expandedText);
    }

    return {
      id: `${eventKey}-run-status`,
      title: label,
      summary: previewText(summary, label),
      detail: detailParts.join("\n\n"),
      createdAt: eventItem.createdAt || eventItem.runStatus.createdAt,
      isActive: stage === "thinking" || stage === "searching"
    };
  }

  if (eventItem?.type === "run_control" && eventItem.runControl) {
    const action = eventItem.runControl.action || "control";
    return {
      id: `${eventKey}-run-control`,
      title: `Control: ${action}`,
      summary: previewText(eventItem.runControl.reason, action),
      detail: [
        `Action: ${action}`,
        `Requested by: ${eventItem.runControl.requestedBy || "unknown"}`,
        eventItem.runControl.reason ? `Reason: ${eventItem.runControl.reason}` : ""
      ]
        .filter(Boolean)
        .join("\n"),
      createdAt: eventItem.createdAt
    };
  }

  if (eventItem?.type === "tool_call" && eventItem.toolCall) {
    const reason = String(eventItem.toolCall.reason || "").trim();
    const argumentsText = formatStructuredData(eventItem.toolCall.arguments);
    return {
      id: `${eventKey}-tool-call`,
      title: `Tool call: ${eventItem.toolCall.tool || "tool"}`,
      summary: previewText(reason || argumentsText, "Tool call"),
      detail: `${reason ? `Reason: ${reason}\n\n` : ""}Arguments:\n${argumentsText || "{}"}`,
      createdAt: eventItem.createdAt
    };
  }

  if (eventItem?.type === "tool_result" && eventItem.toolResult) {
    const statusText = eventItem.toolResult.ok ? "success" : "failed";
    const dataText = formatStructuredData(eventItem.toolResult.data);
    const errorText = formatStructuredData(eventItem.toolResult.error);
    const parts = [`Status: ${statusText}`];
    if (Number.isFinite(eventItem.toolResult.durationMs)) {
      parts.push(`Duration: ${eventItem.toolResult.durationMs} ms`);
    }
    if (dataText) {
      parts.push(`Data:\n${dataText}`);
    }
    if (errorText) {
      parts.push(`Error:\n${errorText}`);
    }

    return {
      id: `${eventKey}-tool-result`,
      title: `Tool result: ${eventItem.toolResult.tool || "tool"}`,
      summary: previewText(errorText || dataText, `Result: ${statusText}`),
      detail: parts.join("\n\n"),
      createdAt: eventItem.createdAt
    };
  }

  if (eventItem?.type === "sub_session" && eventItem.subSession) {
    const childSessionId = String(eventItem.subSession.childSessionId || "").trim();
    const title = eventItem.subSession.title || "Sub-session";
    return {
      id: `${eventKey}-sub-session`,
      title,
      summary: previewText(childSessionId, "Session created"),
      detail: `Session: ${childSessionId}\nTitle: ${title}`,
      createdAt: eventItem.createdAt,
      childSessionId
    };
  }

  return null;
}

function SessionExpandable({ recordId, title, summary, children, isExpanded, onToggle }) {
  return (
    <section className={`agent-chat-expandable ${isExpanded ? "open" : ""}`}>
      <button
        type="button"
        className="agent-chat-expandable-toggle"
        onClick={() => onToggle(recordId)}
        aria-expanded={isExpanded}
      >
        <span className="agent-chat-expandable-left">
          <span className="material-symbols-rounded" aria-hidden="true">
            psychology_alt
          </span>
          <span className="agent-chat-expandable-copy">
            <strong>{title}</strong>
            {summary ? <small>{summary}</small> : null}
          </span>
        </span>
        <span className="material-symbols-rounded agent-chat-expandable-chevron" aria-hidden="true">
          expand_more
        </span>
      </button>
      {isExpanded ? <div className="agent-chat-expandable-body">{children}</div> : null}
    </section>
  );
}

export function ChannelSessionView({ agentId, sessionId, onNavigateBack, onOpenSession }) {
  const [agent, setAgent] = useState(null);
  const [sessionDetail, setSessionDetail] = useState(null);
  const [projects, setProjects] = useState([]);
  const [actorBoard, setActorBoard] = useState({ nodes: [], links: [], teams: [] });
  const [channelSummary, setChannelSummary] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [errorText, setErrorText] = useState("");
  const [expandedRecordIds, setExpandedRecordIds] = useState({});
  const syncStateRef = useRef({ timerId: null, inflight: false, queued: false });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      if (!agentId || !sessionId) {
        setErrorText("Session route is incomplete.");
        setIsLoading(false);
        return;
      }

      setIsLoading(true);
      setErrorText("");

      const [detail, agentResponse, projectsResponse, boardResponse, openSessions, closedSessions] = await Promise.all([
        fetchAgentSession(agentId, sessionId).catch(() => null),
        fetchAgent(agentId).catch(() => null),
        fetchProjects().catch(() => null),
        fetchActorsBoard().catch(() => null),
        fetchChannelSessions({ status: "open" }).catch(() => null),
        fetchChannelSessions({ status: "closed" }).catch(() => null)
      ]);

      if (cancelled) {
        return;
      }

      if (!detail) {
        setSessionDetail(null);
        setErrorText("Failed to load session.");
        setIsLoading(false);
        return;
      }

      const allChannelSessions = [
        ...(Array.isArray(openSessions) ? openSessions : []),
        ...(Array.isArray(closedSessions) ? closedSessions : [])
      ];
      const matchedChannelSession =
        allChannelSessions.find((item) => String(item?.sessionId || "") === String(sessionId || "")) || null;

      setAgent(agentResponse);
      setSessionDetail(detail);
      setProjects(Array.isArray(projectsResponse) ? projectsResponse : []);
      setActorBoard(boardResponse && Array.isArray(boardResponse.nodes) ? boardResponse : { nodes: [], links: [], teams: [] });
      setChannelSummary(matchedChannelSession);
      setIsLoading(false);
    }

    load().catch(() => {
      if (!cancelled) {
        setSessionDetail(null);
        setErrorText("Failed to load session.");
        setIsLoading(false);
      }
    });

    return () => {
      cancelled = true;
      const syncState = syncStateRef.current;
      if (syncState.timerId) {
        window.clearTimeout(syncState.timerId);
      }
      syncStateRef.current = { timerId: null, inflight: false, queued: false };
    };
  }, [agentId, sessionId]);

  useEffect(() => {
    if (!agentId || !sessionId) {
      return undefined;
    }

    async function syncSessionDetail() {
      const detail = await fetchAgentSession(agentId, sessionId).catch(() => null);
      if (detail) {
        setSessionDetail(detail);
      }
    }

    function scheduleSessionSync(delayMs = 120) {
      const state = syncStateRef.current;
      if (state.timerId) {
        window.clearTimeout(state.timerId);
      }

      state.timerId = window.setTimeout(async () => {
        state.timerId = null;

        if (state.inflight) {
          state.queued = true;
          return;
        }

        state.inflight = true;
        try {
          await syncSessionDetail();
        } finally {
          state.inflight = false;
          if (state.queued) {
            state.queued = false;
            scheduleSessionSync(0);
          }
        }
      }, delayMs);
    }

    function handleSessionStreamUpdate(update) {
      if (!update || typeof update !== "object") {
        return;
      }

      const kind = String(update.kind || "");
      const summary = update.summary && typeof update.summary === "object" ? update.summary : null;
      const streamEvent = update.event && typeof update.event === "object" ? update.event : null;

      if (summary?.id === sessionId) {
        setSessionDetail((previous) => {
          if (!previous?.summary) {
            return previous;
          }
          return {
            ...previous,
            summary: {
              ...previous.summary,
              ...summary
            }
          };
        });
      }

      if (streamEvent?.id && streamEvent?.sessionId === sessionId) {
        setSessionDetail((previous) => {
          if (!previous) {
            return previous;
          }
          const existingEvents = Array.isArray(previous.events) ? previous.events : [];
          if (existingEvents.some((item) => item?.id === streamEvent.id)) {
            return previous;
          }
          return {
            ...previous,
            events: [...existingEvents, streamEvent]
          };
        });
      }

      if (kind === "session_ready" || kind === "session_event" || kind === "heartbeat" || kind === "session_delta") {
        scheduleSessionSync(kind === "heartbeat" ? 200 : 0);
      }
    }

    const disconnect = subscribeAgentSessionStream(agentId, sessionId, {
      onUpdate: handleSessionStreamUpdate
    });

    return () => {
      disconnect();
      const state = syncStateRef.current;
      if (state.timerId) {
        window.clearTimeout(state.timerId);
      }
      syncStateRef.current = { timerId: null, inflight: false, queued: false };
    };
  }, [agentId, sessionId]);

  const channelMeta = useMemo(() => {
    const channelId = String(channelSummary?.channelId || "").trim();
    const nodes = Array.isArray(actorBoard?.nodes) ? actorBoard.nodes : [];
    const linkedNode = nodes.find(
      (node) => String(node?.linkedAgentId || "") === String(agentId || "") && String(node?.channelId || "") === channelId
    );
    const fallbackNode = nodes.find((node) => String(node?.linkedAgentId || "") === String(agentId || ""));

    const projectByChannel = new Map();
    for (const project of Array.isArray(projects) ? projects : []) {
      const channels = Array.isArray(project?.channels)
        ? project.channels
        : Array.isArray(project?.chats)
          ? project.chats
          : [];
      for (const channel of channels) {
        const currentChannelId = String(channel?.channelId || "").trim();
        if (!currentChannelId || projectByChannel.has(currentChannelId)) {
          continue;
        }
        projectByChannel.set(currentChannelId, {
          projectId: String(project?.id || ""),
          projectName: String(project?.name || project?.id || "Project"),
          channelTitle: String(channel?.title || currentChannelId)
        });
      }
    }

    const resolvedChannelId = channelId || String(linkedNode?.channelId || fallbackNode?.channelId || "").trim();
    const projectMeta = projectByChannel.get(resolvedChannelId);

    return {
      channelId: resolvedChannelId,
      channelTitle: projectMeta?.channelTitle || resolvedChannelId || "Channel",
      projectId: projectMeta?.projectId || "",
      projectName: projectMeta?.projectName || "",
      actorNodeId: String(linkedNode?.id || fallbackNode?.id || "")
    };
  }, [actorBoard, agentId, channelSummary, projects]);

  const events = Array.isArray(sessionDetail?.events) ? sessionDetail.events : [];
  const latestRunStatus = latestRunStatusFromEvents(events);
  const timelineItems = useMemo(() => {
    const nextTimeline = [];
    for (let index = 0; index < events.length; index += 1) {
      const eventItem = events[index];
      if (eventItem?.type === "message" && eventItem.message) {
        nextTimeline.push({
          id: extractEventKey(eventItem, index),
          kind: "message",
          event: eventItem
        });
      }

      const technicalRecord = buildTechnicalRecord(eventItem, index);
      if (technicalRecord) {
        nextTimeline.push({
          id: technicalRecord.id,
          kind: "technical",
          record: technicalRecord
        });
      }
    }
    return nextTimeline;
  }, [events]);

  const agentName = String(agent?.displayName || agent?.id || agentId || "Agent");
  const summary = sessionDetail?.summary || null;
  const sessionLabel = getSessionDisplayLabel(summary);

  function toggleRecord(recordId) {
    setExpandedRecordIds((previous) => ({
      ...previous,
      [recordId]: !previous[recordId]
    }));
  }

  const breadcrumbItems = [
    { id: "overview", label: "Overview", onClick: onNavigateBack },
    { id: "session", label: channelMeta.channelTitle || sessionLabel }
  ];

  if (isLoading) {
    return (
      <main className="channel-session-shell">
        <Breadcrumbs items={breadcrumbItems} style={{ marginBottom: "20px" }} />
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">hourglass_empty</span>
          <p>Loading channel session...</p>
        </div>
      </main>
    );
  }

  if (errorText || !summary) {
    return (
      <main className="channel-session-shell">
        <Breadcrumbs items={breadcrumbItems} style={{ marginBottom: "20px" }} />
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">error</span>
          <p>{errorText || "Session not found."}</p>
        </div>
      </main>
    );
  }

  return (
    <main className="channel-session-shell">
      <Breadcrumbs items={breadcrumbItems} style={{ marginBottom: "20px" }} />

      <section className="channel-session-hero">
        <div className="channel-session-titlebar">
          <div className="channel-session-avatar">{agentInitials(agentName)}</div>
          <div className="channel-session-copy">
            <h1>{channelMeta.channelTitle || "Channel Session"}</h1>
            <p>
              {agentName}
              {channelMeta.projectName ? ` · ${channelMeta.projectName}` : ""}
            </p>
          </div>
        </div>
        <div className="channel-session-badges">
          {channelMeta.channelId ? <span className="channel-session-badge">{channelMeta.channelId}</span> : null}
          <span className="channel-session-badge">{summary.kind || "chat"}</span>
          <span className="channel-session-badge">Updated {formatRelativeTime(summary.updatedAt)}</span>
        </div>
      </section>

      <div className="channel-session-layout">
        <aside className="channel-session-sidebar">
          <section className="channel-session-panel">
            <div className="overview-section-header">
              <h2>
                <span className="material-symbols-rounded">info</span>
                Session
              </h2>
            </div>
            <dl className="channel-session-meta-list">
              <div>
                <dt>Title</dt>
                <dd>{sessionLabel}</dd>
              </div>
              <div>
                <dt>Session ID</dt>
                <dd>{summary.id}</dd>
              </div>
              <div>
                <dt>Agent</dt>
                <dd>{agentName}</dd>
              </div>
              <div>
                <dt>Messages</dt>
                <dd>{summary.messageCount || 0}</dd>
              </div>
              <div>
                <dt>Created</dt>
                <dd>{formatDateTime(summary.createdAt)}</dd>
              </div>
              <div>
                <dt>Updated</dt>
                <dd>{formatDateTime(summary.updatedAt)}</dd>
              </div>
              {channelMeta.projectName ? (
                <div>
                  <dt>Project</dt>
                  <dd>{channelMeta.projectName}</dd>
                </div>
              ) : null}
              {channelMeta.actorNodeId ? (
                <div>
                  <dt>Actor Node</dt>
                  <dd>{channelMeta.actorNodeId}</dd>
                </div>
              ) : null}
              {latestRunStatus?.label || latestRunStatus?.stage ? (
                <div>
                  <dt>Status</dt>
                  <dd>{latestRunStatus.label || latestRunStatus.stage}</dd>
                </div>
              ) : null}
            </dl>
          </section>

          {summary.lastMessagePreview ? (
            <section className="channel-session-panel">
              <div className="overview-section-header">
                <h2>
                  <span className="material-symbols-rounded">notes</span>
                  Preview
                </h2>
              </div>
              <p className="channel-session-preview">{summary.lastMessagePreview}</p>
            </section>
          ) : null}
        </aside>

        <section className="channel-session-main">
          <div className="overview-section-header">
            <h2>
              <span className="material-symbols-rounded">article</span>
              Full Session
            </h2>
            <span className="overview-section-count">{timelineItems.length}</span>
          </div>

          <div className="channel-session-transcript-panel">
            <div className="agent-chat-events channel-session-events">
              {timelineItems.length === 0 ? (
                <p className="placeholder-text">No transcript available yet.</p>
              ) : (
                timelineItems.map((timelineItem, index) => {
                  if (timelineItem.kind === "technical" && timelineItem.record) {
                    const record = timelineItem.record;
                    const isExpanded = Boolean(expandedRecordIds[record.id]);
                    const isLatestActive =
                      latestRunStatus &&
                      record.isActive &&
                      record.id.includes(latestRunStatus.id || "");

                    return (
                      <div key={timelineItem.id || `tech-${index}`} className="agent-chat-tech-entry">
                        <button
                          type="button"
                          className={`agent-chat-tech-trigger ${isExpanded ? "expanded" : ""} ${isLatestActive ? "shimmer" : ""}`}
                          onClick={() => toggleRecord(record.id)}
                          aria-expanded={isExpanded}
                        >
                          <span className="channel-session-technical-copy">
                            <span className="agent-chat-tech-trigger-label">{record.title || "Technical event"}</span>
                            <small>{record.createdAt ? formatEventTime(record.createdAt) : record.summary}</small>
                          </span>
                          <span className="material-symbols-rounded agent-chat-tech-trigger-arrow" aria-hidden="true">
                            chevron_right
                          </span>
                        </button>
                        {isExpanded ? (
                          <article className="agent-chat-technical">
                            <div className="agent-chat-technical-body">
                              <pre className="agent-chat-expandable-pre">{record.detail || "No details."}</pre>
                              {record.childSessionId ? (
                                <button
                                  type="button"
                                  className="agent-chat-technical-link"
                                  onClick={() => onOpenSession && onOpenSession(agentId, record.childSessionId)}
                                >
                                  Open sub-session
                                </button>
                              ) : null}
                            </div>
                          </article>
                        ) : null}
                      </div>
                    );
                  }

                  const eventItem = timelineItem.event;
                  const eventKey = timelineItem.id || extractEventKey(eventItem, index);
                  const role = String(eventItem?.message?.role || "system");
                  const segments = Array.isArray(eventItem?.message?.segments) ? eventItem.message.segments : [];
                  const thinkingSegments = segments
                    .map((segment, segmentIndex) => ({ ...segment, segmentIndex }))
                    .filter((segment) => segment.kind === "thinking");
                  const visibleSegments = segments.filter((segment) => segment.kind !== "thinking");

                  return (
                    <article key={eventKey} className={`agent-chat-message ${role} channel-session-message`}>
                      <div className="agent-chat-message-head">
                        <strong>{role}</strong>
                        <span>{formatEventTime(eventItem?.message?.createdAt || eventItem?.createdAt)}</span>
                      </div>
                      <div className="agent-chat-message-body">
                        {thinkingSegments.map((segment) => {
                          const thoughtId = `${eventKey}-thinking-${segment.segmentIndex}`;
                          const thoughtText = String(segment.text || "").trim();
                          return (
                            <SessionExpandable
                              key={thoughtId}
                              recordId={thoughtId}
                              title="Thinking"
                              summary={previewText(thoughtText, "No details")}
                              isExpanded={Boolean(expandedRecordIds[thoughtId])}
                              onToggle={toggleRecord}
                            >
                              <p className="agent-chat-expandable-text">{thoughtText || "No details."}</p>
                            </SessionExpandable>
                          );
                        })}

                        {visibleSegments.map((segment, segmentIndex) => {
                          const key = `${eventKey}-segment-${segmentIndex}`;
                          if (segment.kind === "attachment" && segment.attachment) {
                            return (
                              <div key={key} className="agent-chat-attachment">
                                <strong>{segment.attachment.name}</strong>
                                <span>{segment.attachment.mimeType}</span>
                              </div>
                            );
                          }

                          return <p key={key}>{segment.text || ""}</p>;
                        })}

                        {visibleSegments.length === 0 && segmentsToPlainText(segments).length === 0 ? (
                          <p>No message content.</p>
                        ) : null}
                      </div>
                    </article>
                  );
                })
              )}
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}

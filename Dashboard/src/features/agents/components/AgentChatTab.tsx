import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  createAgentSession,
  deleteAgentSession,
  fetchAgentSession,
  fetchAgentSessions,
  postAgentSessionControl,
  postAgentSessionMessage
} from "../../../api";

const INLINE_ATTACHMENT_MAX_BYTES = 2 * 1024 * 1024;

function formatEventTime(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

async function encodeFileBase64(file) {
  const buffer = await file.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";
  for (let index = 0; index < bytes.length; index += chunkSize) {
    const chunk = bytes.subarray(index, index + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

function sortSessionsByUpdate(list) {
  return [...list].sort((left, right) => {
    const leftDate = new Date(left?.updatedAt || 0).getTime();
    const rightDate = new Date(right?.updatedAt || 0).getTime();
    return rightDate - leftDate;
  });
}

function extractEventKey(event, index) {
  return event?.id || `${event?.type || "event"}-${index}`;
}

function previewText(value, fallback = "No details") {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  if (!normalized) {
    return fallback;
  }
  if (normalized.length > 100) {
    return `${normalized.slice(0, 100)}...`;
  }
  return normalized;
}

function sortByNewest(list) {
  return [...list].sort((left, right) => {
    const leftDate = new Date(left?.createdAt || 0).getTime();
    const rightDate = new Date(right?.createdAt || 0).getTime();
    return rightDate - leftDate;
  });
}

function AgentChatEvents({
  isLoadingSession,
  isSending,
  chatMessages,
  latestRunStatus,
  onOpenThinkingPanel
}) {
  const scrollRef = useRef(null);

  useEffect(() => {
    if (!scrollRef.current) {
      return;
    }
    scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [chatMessages, isLoadingSession, isSending, latestRunStatus?.id]);

  return (
    <div className="agent-chat-events" ref={scrollRef}>
      {isLoadingSession ? (
        <p className="placeholder-text">Loading session...</p>
      ) : chatMessages.length === 0 && !isSending ? (
        <p className="placeholder-text">No messages yet.</p>
      ) : (
        <>
          {latestRunStatus ? (
            <p className="placeholder-text">
              Status: {latestRunStatus.label}
              {latestRunStatus.details ? ` - ${latestRunStatus.details}` : ""}
            </p>
          ) : null}

          {chatMessages.map((eventItem, index) => {
            const role = eventItem.message.role || "system";
            const eventKey = extractEventKey(eventItem, index);
            const segments = Array.isArray(eventItem.message?.segments) ? eventItem.message.segments : [];
            const thinkingSegments = segments
              .map((segment, segmentIndex) => ({ ...segment, segmentIndex }))
              .filter((segment) => segment.kind === "thinking");
            const visibleSegments = segments.filter((segment) => segment.kind !== "thinking");

            return (
              <article key={eventKey} className={`agent-chat-message ${role}`}>
                <div className="agent-chat-message-head">
                  <strong>{role}</strong>
                  <span>{formatEventTime(eventItem.message.createdAt || eventItem.createdAt)}</span>
                </div>
                <div className="agent-chat-message-body">
                  {thinkingSegments.length > 0 ? (
                    <button
                      type="button"
                      className="agent-chat-thinking-link"
                      onClick={() => onOpenThinkingPanel(`${eventKey}-thinking-${thinkingSegments[0].segmentIndex}`)}
                    >
                      <span className="material-symbols-rounded" aria-hidden="true">
                        psychology_alt
                      </span>
                      Thinking &gt;
                    </button>
                  ) : null}

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
                </div>
                {role === "assistant" ? (
                  <div className="agent-chat-message-actions">
                    <button type="button" className="agent-chat-action-button" title="Copy">
                      <span className="material-symbols-rounded" aria-hidden="true">
                        content_copy
                      </span>
                    </button>
                    <button type="button" className="agent-chat-action-button" title="Like">
                      <span className="material-symbols-rounded" aria-hidden="true">
                        thumb_up
                      </span>
                    </button>
                    <button type="button" className="agent-chat-action-button" title="Dislike">
                      <span className="material-symbols-rounded" aria-hidden="true">
                        thumb_down
                      </span>
                    </button>
                    <button type="button" className="agent-chat-action-button" title="Reply">
                      <span className="material-symbols-rounded" aria-hidden="true">
                        reply
                      </span>
                    </button>
                    <button type="button" className="agent-chat-action-button" title="Regenerate">
                      <span className="material-symbols-rounded" aria-hidden="true">
                        refresh
                      </span>
                    </button>
                    <button type="button" className="agent-chat-action-button" title="More">
                      <span className="material-symbols-rounded" aria-hidden="true">
                        more_horiz
                      </span>
                    </button>
                  </div>
                ) : null}
              </article>
            );
          })}
        </>
      )}
    </div>
  );
}

function AgentChatComposer({
  inputText,
  onInputTextChange,
  isSending,
  onSend,
  onStop,
  pendingFiles,
  onRemovePendingFile,
  onAddFiles,
  fileInputRef
}) {
  const canSend = String(inputText || "").trim().length > 0 || pendingFiles.length > 0;

  return (
    <form className="agent-chat-compose" onSubmit={onSend}>
      <input
        ref={fileInputRef}
        type="file"
        multiple
        className="agent-chat-file-input"
        onChange={(event) => {
          onAddFiles(event.target.files);
          event.target.value = "";
        }}
        disabled={isSending}
      />

      {pendingFiles.length > 0 ? (
        <div className="agent-chat-pending-files">
          {pendingFiles.map((file, index) => (
            <button key={`${file.name}-${index}`} type="button" onClick={() => onRemovePendingFile(index)}>
              <span>{file.name}</span>
              <span className="material-symbols-rounded" aria-hidden="true">
                close
              </span>
            </button>
          ))}
        </div>
      ) : null}

      <div className="agent-chat-compose-row">
        <button
          type="button"
          className="agent-chat-icon-button"
          onClick={() => fileInputRef.current?.click()}
          disabled={isSending}
          title="Attach files"
        >
          <span className="material-symbols-rounded" aria-hidden="true">
            add
          </span>
        </button>

        <textarea
          rows={1}
          className="agent-chat-compose-input"
          value={inputText}
          onChange={(event) => onInputTextChange(event.target.value)}
          disabled={isSending}
          onKeyDown={(event) => {
            if (event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) {
              return;
            }
            event.preventDefault();
            if (!isSending && canSend) {
              onSend();
            }
          }}
          placeholder="Чем я могу помочь вам сегодня?"
        />

        <div className="agent-chat-compose-right">
          <button type="button" className="agent-chat-mode-button" disabled={isSending}>
            Автоматический
            <span className="material-symbols-rounded" aria-hidden="true">
              expand_more
            </span>
          </button>

          <button
            type="button"
            className="agent-chat-icon-button muted"
            disabled
            title="Voice input is not available yet"
          >
            <span className="material-symbols-rounded" aria-hidden="true">
              mic
            </span>
          </button>

          {isSending ? (
            <button type="button" className="agent-chat-icon-button agent-chat-send-button danger" onClick={onStop}>
              <span className="material-symbols-rounded" aria-hidden="true">
                stop
              </span>
            </button>
          ) : (
            <button
              type="submit"
              className="agent-chat-icon-button agent-chat-send-button"
              disabled={!canSend}
              title="Send"
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                arrow_upward
              </span>
            </button>
          )}
        </div>
      </div>
    </form>
  );
}

function AgentChatInspector({
  isOpen,
  records,
  selectedRecordId,
  onSelectRecord,
  onClose,
  onOpenSession
}) {
  const selectedRecord = records.find((record) => record.id === selectedRecordId) || null;

  function groupLabel(group) {
    if (group === "thinking") {
      return "Thinking";
    }
    if (group === "sub_session") {
      return "Sub-session";
    }
    return "Log";
  }

  return (
    <aside className={`agent-chat-inspector ${isOpen ? "open" : ""}`} aria-hidden={!isOpen}>
      <div className="agent-chat-inspector-head">
        <h4>Thinking</h4>
        <button type="button" className="agent-chat-icon-button" onClick={onClose} aria-label="Close panel">
          <span className="material-symbols-rounded" aria-hidden="true">
            close
          </span>
        </button>
      </div>

      <div className="agent-chat-inspector-content">
        {records.length === 0 ? (
          <p className="placeholder-text">No process details yet.</p>
        ) : (
          <div className="agent-chat-inspector-list">
            {records.map((item) => (
              <button
                key={item.id}
                type="button"
                className={`agent-chat-inspector-item ${selectedRecordId === item.id ? "active" : ""}`}
                onClick={() => onSelectRecord(item.id)}
              >
                <div className="agent-chat-inspector-item-head">
                  <strong>{item.title}</strong>
                  <span>{formatEventTime(item.createdAt)}</span>
                </div>
                <p>{item.preview}</p>
                <small>{groupLabel(item.group)}</small>
              </button>
            ))}
          </div>
        )}
      </div>

      {selectedRecord ? (
        <article className="agent-chat-inspector-details">
          <div className="agent-chat-inspector-item-head">
            <strong>{selectedRecord.title}</strong>
            <span>{formatEventTime(selectedRecord.createdAt)}</span>
          </div>
          <pre>{selectedRecord.text}</pre>
          {selectedRecord.group === "sub_session" && selectedRecord.childSessionId ? (
            <button type="button" onClick={() => onOpenSession(selectedRecord.childSessionId)}>
              Open sub-session
            </button>
          ) : null}
        </article>
      ) : null}
    </aside>
  );
}

export function AgentChatTab({ agentId }) {
  const [sessions, setSessions] = useState([]);
  const [activeSessionId, setActiveSessionId] = useState(null);
  const [activeSession, setActiveSession] = useState(null);
  const [isLoadingSessions, setIsLoadingSessions] = useState(true);
  const [isLoadingSession, setIsLoadingSession] = useState(false);
  const [isSending, setIsSending] = useState(false);
  const [isDragOver, setIsDragOver] = useState(false);
  const [inputText, setInputText] = useState("");
  const [pendingFiles, setPendingFiles] = useState([]);
  const [statusText, setStatusText] = useState("Loading sessions...");
  const [optimisticUserEvent, setOptimisticUserEvent] = useState(null);
  const [optimisticAssistantText, setOptimisticAssistantText] = useState("");
  const [isInspectorOpen, setIsInspectorOpen] = useState(false);
  const [selectedInspectorRecordId, setSelectedInspectorRecordId] = useState(null);
  const fileInputRef = useRef(null);
  const runStateRef = useRef({ watcherId: 0, sessionId: null, abortController: null });

  useEffect(() => {
    document.body.classList.add("agent-chat-no-page-scroll");
    return () => {
      document.body.classList.remove("agent-chat-no-page-scroll");
    };
  }, []);

  useEffect(() => {
    let isCancelled = false;

    async function bootstrap() {
      setIsLoadingSessions(true);
      setActiveSessionId(null);
      setActiveSession(null);
      setPendingFiles([]);
      setInputText("");
      setOptimisticUserEvent(null);
      setOptimisticAssistantText("");
      setIsInspectorOpen(false);
      setSelectedInspectorRecordId(null);
      setIsSending(false);
      runStateRef.current.watcherId += 1;
      runStateRef.current.abortController?.abort();
      runStateRef.current.sessionId = null;
      runStateRef.current.abortController = null;

      const response = await fetchAgentSessions(agentId);
      if (isCancelled) {
        return;
      }

      const nextSessions = Array.isArray(response) ? sortSessionsByUpdate(response) : [];
      setSessions(nextSessions);
      setIsLoadingSessions(false);

      if (!Array.isArray(response)) {
        setStatusText("Failed to load sessions.");
        return;
      }

      if (nextSessions.length === 0) {
        setStatusText("No sessions yet. Create one.");
        return;
      }

      setStatusText(`Loaded ${nextSessions.length} sessions`);
      const nextSessionID = nextSessions[0].id;
      setActiveSessionId(nextSessionID);
      await openSession(nextSessionID, isCancelled);
    }

    bootstrap().catch(() => {
      if (!isCancelled) {
        setStatusText("Failed to initialize chat.");
        setIsLoadingSessions(false);
      }
    });

    return () => {
      isCancelled = true;
      runStateRef.current.watcherId += 1;
      runStateRef.current.abortController?.abort();
      runStateRef.current.sessionId = null;
      runStateRef.current.abortController = null;
    };
  }, [agentId]);

  async function openSession(sessionId, isCancelled = false) {
    if (!sessionId) {
      return;
    }
    setIsLoadingSession(true);
    const detail = await fetchAgentSession(agentId, sessionId);
    if (!isCancelled) {
      if (detail) {
        setActiveSession(detail);
        setActiveSessionId(sessionId);
      } else {
        setStatusText("Failed to load session.");
      }
      setIsLoadingSession(false);
    }
  }

  async function refreshSessions(preferredSessionId = null) {
    const response = await fetchAgentSessions(agentId);
    if (!Array.isArray(response)) {
      setStatusText("Failed to refresh sessions.");
      return;
    }

    const nextSessions = sortSessionsByUpdate(response);
    setSessions(nextSessions);

    if (nextSessions.length === 0) {
      setActiveSessionId(null);
      setActiveSession(null);
      setStatusText("No sessions yet. Create one.");
      return;
    }

    const targetId =
      preferredSessionId && nextSessions.some((item) => item.id === preferredSessionId)
        ? preferredSessionId
        : nextSessions[0].id;
    setActiveSessionId(targetId);
    await openSession(targetId);
  }

  async function createSession(parentSessionId = null) {
    const response = await createAgentSession(agentId, parentSessionId ? { parentSessionId } : {});
    if (!response) {
      setStatusText("Failed to create session.");
      return null;
    }

    setSessions((previous) => sortSessionsByUpdate([response, ...previous.filter((item) => item.id !== response.id)]));
    setActiveSessionId(response.id);
    await openSession(response.id);
    setStatusText(`Session ${response.id} created`);
    return response;
  }

  function latestRunStatusFromEvents(events) {
    return [...events]
      .reverse()
      .find((eventItem) => eventItem.type === "run_status" && eventItem.runStatus)?.runStatus;
  }

  function latestRespondingTextFromEvents(events) {
    const responding = [...events].reverse().find(
      (eventItem) =>
        eventItem.type === "run_status" &&
        eventItem.runStatus?.stage === "responding" &&
        eventItem.runStatus?.expandedText
    )?.runStatus;
    return String(responding?.expandedText || "");
  }

  async function watchSessionWhileRunning(sessionId, watcherId) {
    while (runStateRef.current.watcherId === watcherId) {
      const detail = await fetchAgentSession(agentId, sessionId);
      if (runStateRef.current.watcherId !== watcherId) {
        return;
      }

      if (detail && Array.isArray(detail.events)) {
        const events = detail.events;
        const latestStatus = latestRunStatusFromEvents(events);
        const respondingText = latestRespondingTextFromEvents(events);
        if (respondingText) {
          setOptimisticAssistantText(respondingText);
        }

        if (latestStatus) {
          setStatusText(
            `Status: ${latestStatus.label}${latestStatus.details ? ` - ${latestStatus.details}` : ""}`
          );
        }
      }

      await new Promise((resolve) => {
        setTimeout(resolve, 280);
      });
    }
  }

  function addFiles(fileList) {
    const next = Array.from(fileList || []);
    if (next.length === 0) {
      return;
    }
    setPendingFiles((previous) => [...previous, ...next]);
    setStatusText(`${next.length} file(s) attached`);
  }

  function removePendingFile(index) {
    setPendingFiles((previous) => previous.filter((_, itemIndex) => itemIndex !== index));
  }

  async function handleSend(event) {
    event?.preventDefault?.();
    if (isSending) {
      return;
    }

    const trimmed = String(inputText || "").trim();
    if (!trimmed && pendingFiles.length === 0) {
      return;
    }

    let sessionId = activeSessionId;
    if (!sessionId) {
      const created = await createSession();
      if (!created) {
        return;
      }
      sessionId = created.id;
    }

    const localMessageSegments = [];
    if (trimmed) {
      localMessageSegments.push({ kind: "text", text: trimmed });
    }
    localMessageSegments.push(
      ...pendingFiles.map((file) => ({
        kind: "attachment",
        attachment: {
          id: `local-${file.name}-${file.size}-${file.lastModified}`,
          name: file.name,
          mimeType: file.type || "application/octet-stream"
        }
      }))
    );
    setOptimisticUserEvent({
      id: `local-user-${Date.now()}`,
      createdAt: new Date().toISOString(),
      type: "message",
      message: {
        role: "user",
        createdAt: new Date().toISOString(),
        segments: localMessageSegments
      }
    });
    setOptimisticAssistantText("");
    setIsSending(true);
    setStatusText("Thinking...");

    let oversizedCount = 0;
    const uploads = await Promise.all(
      pendingFiles.map(async (file) => {
        const mimeType = file.type || "application/octet-stream";
        if (file.size > INLINE_ATTACHMENT_MAX_BYTES) {
          oversizedCount += 1;
          return {
            name: file.name,
            mimeType,
            sizeBytes: file.size,
            contentBase64: null
          };
        }

        try {
          const contentBase64 = await encodeFileBase64(file);
          return {
            name: file.name,
            mimeType,
            sizeBytes: file.size,
            contentBase64
          };
        } catch {
          return {
            name: file.name,
            mimeType,
            sizeBytes: file.size,
            contentBase64: null
          };
        }
      })
    );

    const watcherId = runStateRef.current.watcherId + 1;
    runStateRef.current.watcherId = watcherId;
    runStateRef.current.sessionId = sessionId;
    runStateRef.current.abortController = new AbortController();
    watchSessionWhileRunning(sessionId, watcherId);

    try {
      const response = await postAgentSessionMessage(
        agentId,
        sessionId,
        {
          userId: "dashboard",
          content: trimmed,
          attachments: uploads,
          spawnSubSession: false
        },
        { signal: runStateRef.current.abortController.signal }
      );

      if (!response) {
        setStatusText("Failed to send message.");
        return;
      }

      setInputText("");
      setPendingFiles([]);
      await refreshSessions(sessionId);

      if (oversizedCount > 0) {
        setStatusText(`Message sent. ${oversizedCount} file(s) saved without inline preview (size limit).`);
      } else {
        setStatusText("Message sent.");
      }
    } catch (error) {
      if (error?.name !== "AbortError") {
        setStatusText("Failed to send message.");
      }
    } finally {
      if (runStateRef.current.watcherId === watcherId) {
        runStateRef.current.watcherId += 1;
      }
      runStateRef.current.abortController = null;
      runStateRef.current.sessionId = null;
      setOptimisticUserEvent(null);
      setOptimisticAssistantText("");
      setIsSending(false);
    }
  }

  async function handleStop() {
    if (!isSending) {
      return;
    }

    const sessionId = runStateRef.current.sessionId || activeSessionId;
    runStateRef.current.watcherId += 1;
    runStateRef.current.abortController?.abort();
    runStateRef.current.abortController = null;
    runStateRef.current.sessionId = null;
    setStatusText("Stopping...");

    if (sessionId) {
      const response = await postAgentSessionControl(agentId, sessionId, {
        action: "interrupt",
        requestedBy: "dashboard",
        reason: "Stopped by user"
      });
      await refreshSessions(sessionId);
      if (response) {
        setStatusText("Interrupted.");
      } else {
        setStatusText("Failed to interrupt.");
      }
    }

    setOptimisticUserEvent(null);
    setOptimisticAssistantText("");
    setIsSending(false);
  }

  async function handleDeleteActiveSession() {
    if (!activeSessionId) {
      return;
    }
    if (!window.confirm("Delete this session?")) {
      return;
    }

    const success = await deleteAgentSession(agentId, activeSessionId);
    if (!success) {
      setStatusText("Failed to delete session.");
      return;
    }
    await refreshSessions(null);
    setStatusText("Session deleted.");
  }

  const events = Array.isArray(activeSession?.events) ? activeSession.events : [];
  const persistedMessages = events.filter(
    (eventItem) =>
      eventItem.type === "message" &&
      eventItem.message &&
      (eventItem.message.role === "user" || eventItem.message.role === "assistant")
  );
  const chatMessages = [...persistedMessages];
  if (optimisticUserEvent) {
    chatMessages.push(optimisticUserEvent);
  }
  if (isSending || optimisticAssistantText) {
    chatMessages.push({
      id: "local-assistant-stream",
      createdAt: new Date().toISOString(),
      type: "message",
      message: {
        role: "assistant",
        createdAt: new Date().toISOString(),
        segments: [
          {
            kind: "text",
            text: optimisticAssistantText || "Thinking..."
          }
        ]
      }
    });
  }
  const latestRunStatus = latestRunStatusFromEvents(events);

  const thinkingRecords = useMemo(() => {
    const list = chatMessages.flatMap((eventItem, index) => {
      const eventKey = extractEventKey(eventItem, index);
      const createdAt = eventItem.message?.createdAt || eventItem.createdAt;
      const thinkingSegments = (eventItem.message?.segments || [])
        .map((segment, segmentIndex) => ({ ...segment, segmentIndex }))
        .filter((segment) => segment.kind === "thinking");

      return thinkingSegments.map((segment) => {
        const text = String(segment.text || "").trim();
        return {
          id: `${eventKey}-thinking-${segment.segmentIndex}`,
          group: "thinking",
          sourceEventKey: eventKey,
          createdAt,
          title: thinkingSegments.length > 1 ? `Thought #${segment.segmentIndex + 1}` : "Thought",
          preview: previewText(text),
          text: text || "No details"
        };
      });
    });

    return sortByNewest(list);
  }, [chatMessages]);

  const subSessionRecords = useMemo(() => {
    const list = events
      .filter((eventItem) => eventItem.type === "sub_session" && eventItem.subSession)
      .map((eventItem, index) => ({
        id: `sub-session-${eventItem.id || index}`,
        group: "sub_session",
        createdAt: eventItem.createdAt,
        title: eventItem.subSession.title || "Sub-session",
        preview: previewText(eventItem.subSession.childSessionId, "Session created"),
        text: `Session: ${eventItem.subSession.childSessionId}\nTitle: ${eventItem.subSession.title || "-"}`,
        childSessionId: eventItem.subSession.childSessionId
      }));

    return sortByNewest(list);
  }, [events]);

  const logRecords = useMemo(() => {
    const statusItems = events
      .filter((eventItem) => eventItem.type === "run_status" && eventItem.runStatus)
      .map((eventItem, index) => {
        const label = eventItem.runStatus.label || eventItem.runStatus.stage || "Status";
        const details = [eventItem.runStatus.details, eventItem.runStatus.expandedText].filter(Boolean).join("\n\n");
        return {
          id: `run-status-${eventItem.id || index}`,
          group: "log",
          createdAt: eventItem.createdAt || eventItem.runStatus.createdAt,
          title: label,
          preview: previewText(eventItem.runStatus.details || eventItem.runStatus.expandedText, label),
          text: details || label
        };
      });

    const controlItems = events
      .filter((eventItem) => eventItem.type === "run_control" && eventItem.runControl)
      .map((eventItem, index) => {
        const label = `Control: ${eventItem.runControl.action}`;
        return {
          id: `run-control-${eventItem.id || index}`,
          group: "log",
          createdAt: eventItem.createdAt,
          title: label,
          preview: previewText(eventItem.runControl.reason, label),
          text: `Action: ${eventItem.runControl.action}\nRequested by: ${eventItem.runControl.requestedBy}${
            eventItem.runControl.reason ? `\nReason: ${eventItem.runControl.reason}` : ""
          }`
        };
      });

    return sortByNewest([...statusItems, ...controlItems]);
  }, [events]);

  const inspectorRecords = useMemo(
    () => [...thinkingRecords, ...subSessionRecords, ...logRecords],
    [thinkingRecords, subSessionRecords, logRecords]
  );

  const hasInspectorRecords = inspectorRecords.length > 0;

  useEffect(() => {
    if (!hasInspectorRecords) {
      setSelectedInspectorRecordId(null);
      return;
    }
    if (!inspectorRecords.some((item) => item.id === selectedInspectorRecordId)) {
      setSelectedInspectorRecordId(inspectorRecords[0].id);
    }
  }, [hasInspectorRecords, inspectorRecords, selectedInspectorRecordId]);

  function openInspector(recordId = null) {
    if (!hasInspectorRecords) {
      return;
    }
    setIsInspectorOpen(true);

    if (recordId && inspectorRecords.some((item) => item.id === recordId)) {
      setSelectedInspectorRecordId(recordId);
      return;
    }

    setSelectedInspectorRecordId((previous) => {
      if (previous && inspectorRecords.some((item) => item.id === previous)) {
        return previous;
      }
      return inspectorRecords[0].id;
    });
  }

  function handleOpenThinkingPanel(recordId) {
    openInspector(recordId);
  }

  return (
    <section
      className={`agent-chat-main ${isDragOver ? "drag-over" : ""}`}
      onDragOver={(event) => {
        event.preventDefault();
        setIsDragOver(true);
      }}
      onDragLeave={(event) => {
        const relatedTarget = event.relatedTarget;
        if (!(relatedTarget instanceof Node) || !event.currentTarget.contains(relatedTarget)) {
          setIsDragOver(false);
        }
      }}
      onDrop={(event) => {
        event.preventDefault();
        setIsDragOver(false);
        addFiles(event.dataTransfer?.files);
      }}
    >
      <div className="agent-chat-main-head">
        <div className="agent-chat-session-controls">
          <select
            className="agent-chat-session-select"
            value={activeSessionId || ""}
            onChange={(event) => openSession(event.target.value)}
            disabled={isLoadingSessions || isSending || sessions.length === 0}
          >
            {sessions.length === 0 ? (
              <option value="">{isLoadingSessions ? "Loading sessions..." : "No sessions"}</option>
            ) : null}
            {sessions.map((session) => (
              <option key={session.id} value={session.id}>
                {session.title}
              </option>
            ))}
          </select>
          <button type="button" className="agent-chat-icon-button" onClick={() => createSession()} disabled={isSending} title="New session">
            <span className="material-symbols-rounded" aria-hidden="true">
              add
            </span>
          </button>
        </div>
        <div className="agent-chat-actions">
          <button
            type="button"
            className="agent-chat-icon-button"
            onClick={() => openInspector()}
            disabled={!hasInspectorRecords}
            title="Thinking"
          >
            <span className="material-symbols-rounded" aria-hidden="true">
              more_horiz
            </span>
          </button>
          <button
            type="button"
            className="agent-chat-icon-button danger"
            onClick={handleDeleteActiveSession}
            disabled={!activeSessionId || isSending}
            title="Delete session"
          >
            <span className="material-symbols-rounded" aria-hidden="true">
              delete
            </span>
          </button>
        </div>
      </div>

      <div className={`agent-chat-workspace ${isInspectorOpen ? "inspector-open" : ""}`}>
        <div className="agent-chat-thread">
          <AgentChatEvents
            isLoadingSession={isLoadingSession}
            isSending={isSending}
            chatMessages={chatMessages}
            latestRunStatus={latestRunStatus}
            onOpenThinkingPanel={handleOpenThinkingPanel}
          />

          <AgentChatComposer
            inputText={inputText}
            onInputTextChange={setInputText}
            isSending={isSending}
            onSend={handleSend}
            onStop={handleStop}
            pendingFiles={pendingFiles}
            onRemovePendingFile={removePendingFile}
            onAddFiles={addFiles}
            fileInputRef={fileInputRef}
          />

          <p className="agent-chat-status-line placeholder-text">{statusText}</p>
        </div>

        {isInspectorOpen ? (
          <button
            type="button"
            className="agent-chat-inspector-overlay"
            onClick={() => setIsInspectorOpen(false)}
            aria-label="Close process panel"
          />
        ) : null}

        <AgentChatInspector
          isOpen={isInspectorOpen}
          records={inspectorRecords}
          selectedRecordId={selectedInspectorRecordId}
          onSelectRecord={setSelectedInspectorRecordId}
          onClose={() => setIsInspectorOpen(false)}
          onOpenSession={openSession}
        />
      </div>
    </section>
  );
}

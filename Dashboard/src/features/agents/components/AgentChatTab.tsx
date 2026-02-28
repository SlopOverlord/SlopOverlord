import React, { useEffect, useRef, useState } from "react";
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

function AgentChatSessionPanel({
  sessions,
  activeSessionId,
  isLoadingSessions,
  isSending,
  onCreateSession,
  onOpenSession
}) {
  return (
    <aside className="agent-chat-sessions">
      <div className="agent-chat-sessions-head">
        <h4>Sessions</h4>
        <button type="button" onClick={onCreateSession} disabled={isSending}>
          New
        </button>
      </div>

      {isLoadingSessions ? (
        <p className="placeholder-text">Loading...</p>
      ) : sessions.length === 0 ? (
        <div className="agent-chat-empty-sessions">
          <p className="placeholder-text">No sessions</p>
          <button type="button" onClick={onCreateSession} disabled={isSending}>
            Create Session
          </button>
        </div>
      ) : (
        <div className="agent-chat-session-list">
          {sessions.map((session) => (
            <button
              key={session.id}
              type="button"
              className={`agent-chat-session-item ${activeSessionId === session.id ? "active" : ""}`}
              onClick={() => onOpenSession(session.id)}
              disabled={isSending}
            >
              <strong>{session.title}</strong>
              <span>{session.messageCount} msg</span>
              <p>{session.lastMessagePreview || session.id}</p>
            </button>
          ))}
        </div>
      )}
    </aside>
  );
}

function AgentChatEvents({ isLoadingSession, isSending, chatMessages, latestRunStatus }) {
  return (
    <div className="agent-chat-events">
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
            return (
              <article key={extractEventKey(eventItem, index)} className={`agent-chat-message ${role}`}>
                <div className="agent-chat-message-head">
                  <strong>{role}</strong>
                  <span>{formatEventTime(eventItem.message.createdAt || eventItem.createdAt)}</span>
                </div>
                <div className="agent-chat-message-body">
                  {(eventItem.message.segments || []).map((segment, segmentIndex) => {
                    const key = `${extractEventKey(eventItem, index)}-segment-${segmentIndex}`;
                    if (segment.kind === "thinking") {
                      return (
                        <details key={key} className="agent-chat-thinking">
                          <summary>Thinking</summary>
                          <pre>{segment.text || ""}</pre>
                        </details>
                      );
                    }

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
  return (
    <form className="agent-chat-compose" onSubmit={onSend}>
      <textarea
        rows={3}
        value={inputText}
        onChange={(event) => onInputTextChange(event.target.value)}
        disabled={isSending}
        onKeyDown={(event) => {
          if (event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) {
            return;
          }
          event.preventDefault();
          if (!isSending) {
            onSend();
          }
        }}
        placeholder="Type a message to your agent..."
      />

      {pendingFiles.length > 0 ? (
        <div className="agent-chat-pending-files">
          {pendingFiles.map((file, index) => (
            <button key={`${file.name}-${index}`} type="button" onClick={() => onRemovePendingFile(index)}>
              {file.name}
            </button>
          ))}
        </div>
      ) : null}

      <div className="agent-chat-compose-actions">
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
        <button type="button" onClick={() => fileInputRef.current?.click()} disabled={isSending}>
          Attach Files
        </button>
        {isSending ? (
          <button type="button" className="danger" onClick={onStop}>
            Stop
          </button>
        ) : (
          <button type="submit">Send</button>
        )}
      </div>
    </form>
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
  const fileInputRef = useRef(null);
  const runStateRef = useRef({ watcherId: 0, sessionId: null, abortController: null });

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

  const activeSummary = activeSession?.summary || sessions.find((item) => item.id === activeSessionId) || null;
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

  return (
    <section className="agent-chat-shell">
      <AgentChatSessionPanel
        sessions={sessions}
        activeSessionId={activeSessionId}
        isLoadingSessions={isLoadingSessions}
        isSending={isSending}
        onCreateSession={() => createSession()}
        onOpenSession={openSession}
      />

      <div
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
          <div>
            <h4>{activeSummary?.title || "Chat"}</h4>
            <p className="placeholder-text">{activeSummary?.id || "Select or create a session"}</p>
          </div>
          <div className="agent-chat-actions">
            {activeSummary?.parentSessionId ? (
              <button type="button" onClick={() => openSession(activeSummary.parentSessionId)} disabled={isSending}>
                Back To Parent
              </button>
            ) : null}
            <button
              type="button"
              className="danger"
              onClick={handleDeleteActiveSession}
              disabled={!activeSessionId || isSending}
            >
              Delete
            </button>
          </div>
        </div>

        <AgentChatEvents
          isLoadingSession={isLoadingSession}
          isSending={isSending}
          chatMessages={chatMessages}
          latestRunStatus={latestRunStatus}
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
    </section>
  );
}

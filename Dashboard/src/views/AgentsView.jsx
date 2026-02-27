import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  createAgent as createAgentRequest,
  createAgentSession,
  deleteAgentSession,
  fetchAgent,
  fetchAgentConfig,
  fetchAgentSession,
  fetchAgentSessions,
  fetchAgents,
  postAgentSessionMessage,
  updateAgentConfig
} from "../api";

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

function AgentChatTab({ agentId }) {
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
  const fileInputRef = useRef(null);

  useEffect(() => {
    let isCancelled = false;

    async function bootstrap() {
      setIsLoadingSessions(true);
      setActiveSessionId(null);
      setActiveSession(null);
      setPendingFiles([]);
      setInputText("");

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
    event.preventDefault();
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

    setIsSending(true);
    setStatusText("Sending message...");

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

    const response = await postAgentSessionMessage(agentId, sessionId, {
      userId: "dashboard",
      content: trimmed,
      attachments: uploads,
      spawnSubSession: false
    });

    if (!response) {
      setStatusText("Failed to send message.");
      setIsSending(false);
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
  const chatMessages = events.filter(
    (eventItem) =>
      eventItem.type === "message" &&
      eventItem.message &&
      (eventItem.message.role === "user" || eventItem.message.role === "assistant")
  );
  const latestRunStatus = [...events]
    .reverse()
    .find((eventItem) => eventItem.type === "run_status" && eventItem.runStatus)?.runStatus;

  return (
    <section className="agent-chat-shell">
      <aside className="agent-chat-sessions">
        <div className="agent-chat-sessions-head">
          <h4>Sessions</h4>
          <button type="button" onClick={() => createSession()}>
            New
          </button>
        </div>

        {isLoadingSessions ? (
          <p className="placeholder-text">Loading...</p>
        ) : sessions.length === 0 ? (
          <div className="agent-chat-empty-sessions">
            <p className="placeholder-text">No sessions</p>
            <button type="button" onClick={() => createSession()}>
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
                onClick={() => openSession(session.id)}
              >
                <strong>{session.title}</strong>
                <span>{session.messageCount} msg</span>
                <p>{session.lastMessagePreview || session.id}</p>
              </button>
            ))}
          </div>
        )}
      </aside>

      <div
        className={`agent-chat-main ${isDragOver ? "drag-over" : ""}`}
        onDragOver={(event) => {
          event.preventDefault();
          setIsDragOver(true);
        }}
        onDragLeave={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget)) {
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
              <button type="button" onClick={() => openSession(activeSummary.parentSessionId)}>
                Back To Parent
              </button>
            ) : null}
            <button type="button" className="danger" onClick={handleDeleteActiveSession} disabled={!activeSessionId}>
              Delete
            </button>
          </div>
        </div>

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

        <form className="agent-chat-compose" onSubmit={handleSend}>
          <textarea
            rows={3}
            value={inputText}
            onChange={(event) => setInputText(event.target.value)}
            placeholder="Type a message to your agent..."
          />

          {pendingFiles.length > 0 ? (
            <div className="agent-chat-pending-files">
              {pendingFiles.map((file, index) => (
                <button key={`${file.name}-${index}`} type="button" onClick={() => removePendingFile(index)}>
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
                addFiles(event.target.files);
                event.target.value = "";
              }}
            />
            <button type="button" onClick={() => fileInputRef.current?.click()}>
              Attach Files
            </button>
            <button type="submit" disabled={isSending}>
              {isSending ? "Sending..." : "Send"}
            </button>
          </div>
        </form>

        <p className="agent-chat-status-line placeholder-text">{statusText}</p>
      </div>
    </section>
  );
}

function emptyAgentConfigDraft(agentId) {
  return {
    agentId,
    selectedModel: "",
    availableModels: [],
    documents: {
      userMarkdown: "",
      agentsMarkdown: "",
      soulMarkdown: "",
      identityMarkdown: ""
    }
  };
}

function AgentConfigTab({ agentId }) {
  const [draft, setDraft] = useState(() => emptyAgentConfigDraft(agentId));
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [statusText, setStatusText] = useState("Loading agent config...");

  useEffect(() => {
    let isCancelled = false;

    async function load() {
      setIsLoading(true);
      setStatusText("Loading agent config...");
      const response = await fetchAgentConfig(agentId);
      if (isCancelled) {
        return;
      }

      if (!response) {
        setDraft(emptyAgentConfigDraft(agentId));
        setStatusText("Failed to load config.");
        setIsLoading(false);
        return;
      }

      setDraft({
        agentId: response.agentId || agentId,
        selectedModel: response.selectedModel || "",
        availableModels: Array.isArray(response.availableModels) ? response.availableModels : [],
        documents: {
          userMarkdown: String(response.documents?.userMarkdown || ""),
          agentsMarkdown: String(response.documents?.agentsMarkdown || ""),
          soulMarkdown: String(response.documents?.soulMarkdown || ""),
          identityMarkdown: String(response.documents?.identityMarkdown || "")
        }
      });
      setStatusText("Config loaded.");
      setIsLoading(false);
    }

    load().catch(() => {
      if (!isCancelled) {
        setStatusText("Failed to load config.");
        setIsLoading(false);
      }
    });

    return () => {
      isCancelled = true;
    };
  }, [agentId]);

  function updateField(field, value) {
    setDraft((previous) => ({
      ...previous,
      [field]: value
    }));
  }

  function updateDocumentField(field, value) {
    setDraft((previous) => ({
      ...previous,
      documents: {
        ...previous.documents,
        [field]: value
      }
    }));
  }

  async function saveConfig(event) {
    event.preventDefault();
    if (isSaving) {
      return;
    }

    const selectedModel = String(draft.selectedModel || "").trim();
    if (!selectedModel) {
      setStatusText("Model is required.");
      return;
    }

    const payload = {
      selectedModel,
      documents: {
        userMarkdown: String(draft.documents.userMarkdown || ""),
        agentsMarkdown: String(draft.documents.agentsMarkdown || ""),
        soulMarkdown: String(draft.documents.soulMarkdown || ""),
        identityMarkdown: String(draft.documents.identityMarkdown || "")
      }
    };

    setIsSaving(true);
    const response = await updateAgentConfig(agentId, payload);
    if (!response) {
      setStatusText("Failed to save config.");
      setIsSaving(false);
      return;
    }

    setDraft({
      agentId: response.agentId || agentId,
      selectedModel: response.selectedModel || "",
      availableModels: Array.isArray(response.availableModels) ? response.availableModels : [],
      documents: {
        userMarkdown: String(response.documents?.userMarkdown || ""),
        agentsMarkdown: String(response.documents?.agentsMarkdown || ""),
        soulMarkdown: String(response.documents?.soulMarkdown || ""),
        identityMarkdown: String(response.documents?.identityMarkdown || "")
      }
    });
    setStatusText("Config saved.");
    setIsSaving(false);
  }

  return (
    <section className="agent-config-shell">
      <div className="agent-config-head">
        <h3>Agent Config</h3>
        <span className="placeholder-text">{statusText}</span>
      </div>

      {isLoading ? (
        <p className="placeholder-text">Loading...</p>
      ) : (
        <form className="agent-config-form" onSubmit={saveConfig}>
          <label>
            Model
            <select
              value={draft.selectedModel}
              onChange={(event) => updateField("selectedModel", event.target.value)}
            >
              {draft.availableModels.map((model) => (
                <option key={model.id} value={model.id}>
                  {model.title}
                </option>
              ))}
            </select>
          </label>

          <div className="agent-config-docs">
            <label>
              User.md
              <textarea
                rows={8}
                value={draft.documents.userMarkdown}
                onChange={(event) => updateDocumentField("userMarkdown", event.target.value)}
              />
            </label>
            <label>
              Agents.md
              <textarea
                rows={8}
                value={draft.documents.agentsMarkdown}
                onChange={(event) => updateDocumentField("agentsMarkdown", event.target.value)}
              />
            </label>
            <label>
              Soul.md
              <textarea
                rows={8}
                value={draft.documents.soulMarkdown}
                onChange={(event) => updateDocumentField("soulMarkdown", event.target.value)}
              />
            </label>
            <label>
              Identity.md
              <textarea
                rows={8}
                value={draft.documents.identityMarkdown}
                onChange={(event) => updateDocumentField("identityMarkdown", event.target.value)}
              />
            </label>
          </div>

          <div className="agent-config-actions">
            <button type="submit" disabled={isSaving}>
              {isSaving ? "Saving..." : "Save Config"}
            </button>
          </div>
        </form>
      )}
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
          <AgentChatTab agentId={agent.id} />
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
        <section className="agents-index">
          <header className="agents-index-head">
            <h2>Agents</h2>
            {agents.length > 0 && !isLoadingAgents ? (
              <button type="button" className="agents-create-inline" onClick={openCreateModal}>
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

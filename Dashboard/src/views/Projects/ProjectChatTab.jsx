import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { fetchAgents } from "../../api";
import { AgentChatTab } from "../../features/agents/components/AgentChatTab";

const PROJECT_CHAT_LAST_AGENT_STORAGE_PREFIX = "sloppy.projectChat.lastAgent:";

function storageKeyProjectChatAgent(projectId) {
  return `${PROJECT_CHAT_LAST_AGENT_STORAGE_PREFIX}${encodeURIComponent(projectId)}`;
}

function readStoredAgentIdForProject(projectId) {
  if (typeof window === "undefined") {
    return null;
  }
  try {
    const raw = window.localStorage.getItem(storageKeyProjectChatAgent(projectId));
    const s = typeof raw === "string" ? raw.trim() : "";
    return s || null;
  } catch {
    return null;
  }
}

function writeStoredAgentIdForProject(projectId, agentId) {
  if (typeof window === "undefined") {
    return;
  }
  const id = String(agentId || "").trim();
  if (!id) {
    return;
  }
  try {
    window.localStorage.setItem(storageKeyProjectChatAgent(projectId), id);
  } catch {
    // quota / private mode
  }
}

function normalizeId(value) {
  return String(value || "").trim();
}

function normalizeAgent(item, index) {
  const id = normalizeId(item?.id) || `agent-${index + 1}`;
  return {
    id,
    displayName: normalizeId(item?.displayName) || id
  };
}

function projectInitials(name, id) {
  const raw = normalizeId(name) || normalizeId(id) || "?";
  const parts = raw.split(/[\s_-]+/).filter(Boolean);
  if (parts.length === 0) return "??";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

export function ProjectChatTab({
  project,
  chatAgentId = null,
  chatSessionId = null,
  onChatRouteChange = null
}) {
  const projectId = normalizeId(project?.id);
  const [agents, setAgents] = useState([]);
  const [agentSearch, setAgentSearch] = useState("");
  const [agentDropdownOpen, setAgentDropdownOpen] = useState(false);
  const [localAgentId, setLocalAgentId] = useState("");
  const [localSessionId, setLocalSessionId] = useState("");
  const agentSearchRef = useRef(null);

  const activeAgentId = normalizeId(chatAgentId) || localAgentId;
  const activeSessionId = activeAgentId === normalizeId(chatAgentId)
    ? normalizeId(chatSessionId)
    : localSessionId;

  useEffect(() => {
    setLocalAgentId("");
    setLocalSessionId("");
    setAgentSearch("");
  }, [projectId]);

  const updateProjectChatRoute = useCallback(
    (nextAgentId, nextSessionId = null) => {
      const agentId = normalizeId(nextAgentId);
      const sessionId = agentId ? normalizeId(nextSessionId) : "";
      if (typeof onChatRouteChange === "function") {
        onChatRouteChange(agentId || null, sessionId || null);
        return;
      }
      setLocalAgentId(agentId);
      setLocalSessionId(sessionId);
    },
    [onChatRouteChange]
  );

  useEffect(() => {
    let cancelled = false;
    fetchAgents()
      .then((list) => {
        if (cancelled || !Array.isArray(list)) {
          return;
        }
        setAgents(list.map((item, index) => normalizeAgent(item, index)));
      })
      .catch(() => {
        if (!cancelled) {
          setAgents([]);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const selected = agents.find((agent) => agent.id === activeAgentId);
    if (selected) {
      setAgentSearch(selected.displayName || selected.id);
    } else if (!activeAgentId) {
      setAgentSearch("");
    }
  }, [activeAgentId, agents]);

  useEffect(() => {
    if (!projectId || !activeAgentId) {
      return;
    }
    writeStoredAgentIdForProject(projectId, activeAgentId);
  }, [activeAgentId, projectId]);

  useEffect(() => {
    if (!projectId || agents.length === 0 || activeAgentId) {
      return;
    }
    const stored = readStoredAgentIdForProject(projectId);
    if (!stored || !agents.some((agent) => agent.id === stored)) {
      return;
    }
    updateProjectChatRoute(stored, null);
  }, [activeAgentId, agents, projectId, updateProjectChatRoute]);

  const onActiveSessionIdChange = useCallback(
    (sessionId) => {
      if (!activeAgentId) {
        return;
      }
      updateProjectChatRoute(activeAgentId, sessionId);
    },
    [activeAgentId, updateProjectChatRoute]
  );

  const filteredAgents = useMemo(() => {
    const q = agentSearch.toLowerCase();
    return agents.filter((agent) => {
      return agent.displayName.toLowerCase().includes(q) || agent.id.toLowerCase().includes(q);
    });
  }, [agentSearch, agents]);

  if (!projectId) {
    return (
      <section className="project-tab-layout">
        <p className="app-status-text">Select a project to open project chat.</p>
      </section>
    );
  }

  return (
    <section className="project-tab-layout project-chats-shell" data-testid="project-chats-view">
      <header className="project-chats-head">
        <div className="project-chats-title-row">
          <span className="project-chats-avatar" aria-hidden="true">
            {projectInitials(project?.name, projectId)}
          </span>
          <div>
            <h1 className="project-chats-title">{normalizeId(project?.name) || projectId}</h1>
            <p className="project-chats-sub">{projectId}</p>
          </div>
        </div>

        <label className="project-chats-agent-label">
          <span className="project-chats-agent-label-text">Agent</span>
          <div className="actor-team-search-wrap project-chats-agent-search">
            <input
              ref={agentSearchRef}
              className="actor-team-search"
              value={agentSearch}
              onChange={(event) => {
                setAgentSearch(event.target.value);
                setAgentDropdownOpen(true);
              }}
              onFocus={() => setAgentDropdownOpen(true)}
              onBlur={() => setTimeout(() => setAgentDropdownOpen(false), 150)}
              placeholder="Search agents..."
              autoComplete="off"
            />
            {agentDropdownOpen ? (
              <ul className="actor-team-dropdown">
                {filteredAgents.map((agent) => {
                  const isSelected = activeAgentId === agent.id;
                  return (
                    <li
                      key={agent.id}
                      className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                      onMouseDown={(event) => {
                        event.preventDefault();
                        setAgentSearch(agent.displayName || agent.id);
                        setAgentDropdownOpen(false);
                        updateProjectChatRoute(agent.id, null);
                      }}
                    >
                      <span className="actor-team-dropdown-name">{agent.displayName || agent.id}</span>
                      <span className="actor-team-dropdown-id">{agent.id}</span>
                      {isSelected ? (
                        <span className="material-symbols-rounded actor-team-dropdown-check">check</span>
                      ) : null}
                    </li>
                  );
                })}
                {filteredAgents.length === 0 ? (
                  <li className="actor-team-dropdown-empty">No agents found</li>
                ) : null}
              </ul>
            ) : null}
          </div>
        </label>
      </header>

      {activeAgentId ? (
        <AgentChatTab
          key={`${projectId}:${activeAgentId}`}
          agentId={activeAgentId}
          initialSessionId={activeSessionId || null}
          projectId={projectId}
          onActiveSessionIdChange={onActiveSessionIdChange}
          modeStorageScope={`project-chat:${projectId}:${activeAgentId}`}
        />
      ) : (
        <p className="app-status-text">Choose an agent to load sessions and chat.</p>
      )}
    </section>
  );
}

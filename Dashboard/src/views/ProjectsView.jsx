import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  fetchActorsBoard,
  fetchChannelState,
  fetchProjects as fetchProjectsRequest,
  createProject as createProjectRequest,
  updateProject as updateProjectRequest,
  deleteProject as deleteProjectRequest,
  createProjectChannel as createProjectChannelRequest,
  deleteProjectChannel as deleteProjectChannelRequest,
  createProjectTask as createProjectTaskRequest,
  updateProjectTask as updateProjectTaskRequest,
  deleteProjectTask as deleteProjectTaskRequest
} from "../api";

const ACTIVE_WORKER_STATUSES = new Set(["queued", "running", "waitinginput", "waiting_input"]);

const PROJECT_TABS = [
  { id: "overview", title: "Overview" },
  { id: "tasks", title: "Tasks" },
  { id: "workers", title: "Workers" },
  { id: "memories", title: "Memories" },
  { id: "visor", title: "Visor" },
  { id: "settings", title: "Settings" }
];

const TASK_STATUSES = [
  { id: "backlog", title: "Backlog" },
  { id: "ready", title: "Ready to work" },
  { id: "in_progress", title: "In progress" },
  { id: "done", title: "Done" }
];

const TASK_PRIORITIES = ["low", "medium", "high"];
const TASK_PRIORITY_LABELS = {
  low: "Low",
  medium: "Medium",
  high: "High"
};

const PROJECT_TAB_SET = new Set(PROJECT_TABS.map((tab) => tab.id));
const TASK_STATUS_SET = new Set(TASK_STATUSES.map((status) => status.id));
const TASK_PRIORITY_SET = new Set(TASK_PRIORITIES);

function createId(prefix) {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
}

function toSlug(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

function emptyTaskDraft(initialStatus = "backlog") {
  return {
    title: "",
    description: "",
    priority: "medium",
    status: TASK_STATUS_SET.has(initialStatus) ? initialStatus : "backlog"
  };
}

function normalizeChat(chat, index = 0) {
  const fallback = `channel-${index + 1}`;
  return {
    id: String(chat?.id || createId("chat")).trim(),
    title: String(chat?.title || `Channel ${index + 1}`).trim(),
    channelId: String(chat?.channelId || fallback).trim() || fallback
  };
}

function normalizeTask(task, index = 0) {
  const status = String(task?.status || "backlog").trim().toLowerCase();
  const priority = String(task?.priority || "medium").trim().toLowerCase();

  return {
    id: String(task?.id || createId("task")).trim() || createId(`task-${index + 1}`),
    title: String(task?.title || `Task ${index + 1}`).trim(),
    description: String(task?.description || "").trim(),
    status: TASK_STATUS_SET.has(status) ? status : "backlog",
    priority: TASK_PRIORITY_SET.has(priority) ? priority : "medium",
    createdAt: String(task?.createdAt || new Date().toISOString()),
    updatedAt: String(task?.updatedAt || task?.createdAt || new Date().toISOString())
  };
}

function normalizeProject(project, index = 0) {
  const id = String(project?.id || createId("project")).trim() || createId(`project-${index + 1}`);
  const fallbackName = `Project ${index + 1}`;
  const name = String(project?.name || fallbackName).trim() || fallbackName;
  const channelsSource = Array.isArray(project?.channels) ? project.channels : project?.chats;

  const chats = Array.isArray(channelsSource)
    ? channelsSource.map((chat, chatIndex) => normalizeChat(chat, chatIndex)).filter((chat) => chat.channelId.length > 0)
    : [];

  const tasks = Array.isArray(project?.tasks)
    ? project.tasks.map((task, taskIndex) => normalizeTask(task, taskIndex)).filter((task) => task.title.length > 0)
    : [];

  return {
    id,
    name,
    description: String(project?.description || "").trim(),
    createdAt: String(project?.createdAt || new Date().toISOString()),
    updatedAt: String(project?.updatedAt || project?.createdAt || new Date().toISOString()),
    chats,
    tasks
  };
}

function sortTasksByDate(tasks) {
  return [...tasks].sort((left, right) => {
    return new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime();
  });
}

function workersForProject(project, workers) {
  if (!project) {
    return [];
  }

  const projectChannels = new Set(project.chats.map((chat) => String(chat.channelId || "").trim()));
  return (Array.isArray(workers) ? workers : []).filter((worker) => {
    const channelId = String(worker?.channelId || "").trim();
    return channelId.length > 0 && projectChannels.has(channelId);
  });
}

function activeWorkersForProject(project, workers) {
  return workersForProject(project, workers).filter((worker) => {
    const status = String(worker?.status || "").trim().toLowerCase();
    return ACTIVE_WORKER_STATUSES.has(status);
  });
}

function buildTaskCounts(tasks) {
  const counts = { total: tasks.length };
  for (const status of TASK_STATUSES) {
    counts[status.id] = tasks.filter((task) => task.status === status.id).length;
  }
  return counts;
}

function formatRelativeTime(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) {
    return "just now";
  }

  const diffMs = Date.now() - date.getTime();
  const diffMinutes = Math.round(diffMs / 60000);
  if (Math.abs(diffMinutes) < 1) {
    return "just now";
  }

  if (Math.abs(diffMinutes) < 60) {
    return `${diffMinutes}m ago`;
  }

  const diffHours = Math.round(diffMinutes / 60);
  if (Math.abs(diffHours) < 24) {
    return `${diffHours}h ago`;
  }

  const diffDays = Math.round(diffHours / 24);
  return `${diffDays}d ago`;
}

function extractCreatedItems(project, snapshotsByChannel) {
  const result = [];
  const seen = new Set();

  for (const chat of project.chats) {
    const snapshot = snapshotsByChannel[chat.channelId];
    const messages = Array.isArray(snapshot?.messages) ? snapshot.messages : [];

    for (const message of messages) {
      const content = String(message?.content || "");
      if (!content) {
        continue;
      }

      const artifactRegex = /\bartifact\s+([a-f0-9-]{8,})/gi;
      let artifactMatch = artifactRegex.exec(content);
      while (artifactMatch) {
        const artifactId = artifactMatch[1];
        const key = `artifact:${artifactId}`;
        if (!seen.has(key)) {
          seen.add(key);
          result.push({
            key,
            type: "artifact",
            value: artifactId,
            channelId: chat.channelId
          });
        }
        artifactMatch = artifactRegex.exec(content);
      }

      const fileRegex = /(?:^|[\s"'`])((?:\.?\/?[\w-]+(?:\/[\w.-]+)*)\.[a-zA-Z0-9]{1,8})(?=$|[\s"'`])/g;
      let fileMatch = fileRegex.exec(content);
      while (fileMatch) {
        const filePath = fileMatch[1];
        if (filePath.length < 3) {
          fileMatch = fileRegex.exec(content);
          continue;
        }

        const key = `file:${filePath}`;
        if (!seen.has(key)) {
          seen.add(key);
          result.push({
            key,
            type: "file",
            value: filePath,
            channelId: chat.channelId
          });
        }
        fileMatch = fileRegex.exec(content);
      }
    }
  }

  return result.slice(0, 24);
}

function normalizeProjectIdentifier(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-_.]+/g, "-")
    .replace(/^[-_.]+|[-_.]+$/g, "");
}

function parseListInput(value) {
  if (typeof value !== "string") {
    return [];
  }
  const unique = new Set();
  const parsed = [];
  for (const rawItem of value.split(/[\n,]+/g)) {
    const item = rawItem.trim();
    if (!item || unique.has(item.toLowerCase())) {
      continue;
    }
    unique.add(item.toLowerCase());
    parsed.push(item);
  }
  return parsed;
}

function buildProjectChannels(projectId, actors = [], teams = []) {
  const base = normalizeProjectIdentifier(projectId) || "project";
  const channels = [{ title: "Main channel", channelId: `${base}-main` }];
  const used = new Set(channels.map((channel) => channel.channelId));

  for (const actor of actors) {
    const actorSlug = toSlug(actor);
    const channelId = `${base}-actor-${actorSlug || createId("actor")}`;
    if (!used.has(channelId)) {
      used.add(channelId);
      channels.push({
        title: `Actor · ${actor}`,
        channelId
      });
    }
  }

  for (const team of teams) {
    const teamSlug = toSlug(team);
    const channelId = `${base}-team-${teamSlug || createId("team")}`;
    if (!used.has(channelId)) {
      used.add(channelId);
      channels.push({
        title: `Team · ${team}`,
        channelId
      });
    }
  }

  return channels;
}

function emptyProjectDraft(index = 1) {
  return {
    projectId: `project-${index}`,
    displayName: `Project ${index}`,
    description: "",
    actors: "",
    teams: ""
  };
}

function ProjectCreateModal({ isOpen, draft, onChange, onClose, onCreate, actors = [], teams = [] }) {
  const [actorSearch, setActorSearch] = useState("");
  const [actorDropdownOpen, setActorDropdownOpen] = useState(false);
  const actorSearchRef = useRef(null);
  const [teamSearch, setTeamSearch] = useState("");
  const [teamDropdownOpen, setTeamDropdownOpen] = useState(false);
  const teamSearchRef = useRef(null);

  const selectedActorIds = parseListInput(draft?.actors ?? "");
  const q = actorSearch.trim().toLowerCase();
  const filtered = actors.filter(
    (node) =>
      node.displayName.toLowerCase().includes(q) || node.id.toLowerCase().includes(q)
  );
  const listToShow = q && filtered.length > 0 ? filtered : actors;

  const selectedTeamIds = parseListInput(draft?.teams ?? "");
  const tq = teamSearch.trim().toLowerCase();
  const filteredTeams = teams.filter(
    (team) =>
      team.name.toLowerCase().includes(tq) || team.id.toLowerCase().includes(tq)
  );
  const listToShowTeams = tq && filteredTeams.length > 0 ? filteredTeams : teams;

  if (!isOpen) {
    return null;
  }

  function addActor(node) {
    const next = selectedActorIds.includes(node.id)
      ? selectedActorIds
      : [...selectedActorIds, node.id];
    onChange("actors", next.join(", "));
    setActorSearch("");
  }

  function removeActor(actorId) {
    onChange(
      "actors",
      selectedActorIds.filter((id) => id !== actorId).join(", ")
    );
  }

  function addTeam(team) {
    const next = selectedTeamIds.includes(team.id)
      ? selectedTeamIds
      : [...selectedTeamIds, team.id];
    onChange("teams", next.join(", "));
    setTeamSearch("");
  }

  function removeTeam(teamId) {
    onChange(
      "teams",
      selectedTeamIds.filter((id) => id !== teamId).join(", ")
    );
  }

  return (
    <div className="project-modal-overlay" onClick={onClose}>
      <section className="project-modal" onClick={(event) => event.stopPropagation()}>
        <div className="project-modal-head">
          <h3>New Project</h3>
          <button type="button" className="project-modal-close" aria-label="Close" onClick={onClose}>
            ×
          </button>
        </div>

        <form className="project-task-form" onSubmit={onCreate}>
          <label>
            Project ID
            <input
              value={draft.projectId}
              onChange={(event) => onChange("projectId", event.target.value)}
              placeholder="project-alpha"
              autoFocus
            />
          </label>

          <label>
            Display Name
            <input
              value={draft.displayName}
              onChange={(event) => onChange("displayName", event.target.value)}
              placeholder="Project Alpha"
            />
          </label>

          <label>
            Description
            <textarea
              value={draft.description}
              onChange={(event) => onChange("description", event.target.value)}
              rows={3}
              placeholder="What this project is about..."
            />
          </label>

          <div className="project-task-form-grid">
            <label>
              Actors
              <div className="actor-team-members-picker">
                <div className="actor-team-search-wrap">
                  <input
                    ref={actorSearchRef}
                    className="actor-team-search"
                    value={actorSearch}
                    onChange={(event) => {
                      setActorSearch(event.target.value);
                      setActorDropdownOpen(true);
                    }}
                    onFocus={() => setActorDropdownOpen(true)}
                    onBlur={() => setTimeout(() => setActorDropdownOpen(false), 150)}
                    placeholder="Search actors…"
                    autoComplete="off"
                  />
                  {actorDropdownOpen ? (
                    <ul className="actor-team-dropdown">
                      {listToShow.length === 0 ? (
                        <li className="actor-team-dropdown-empty">No actors</li>
                      ) : (
                        listToShow.map((node) => {
                          const isSelected = selectedActorIds.includes(node.id);
                          return (
                            <li
                              key={node.id}
                              className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                              onMouseDown={(event) => {
                                event.preventDefault();
                                addActor(node);
                              }}
                            >
                              <span className="actor-team-dropdown-name">{node.displayName}</span>
                              <span className="actor-team-dropdown-id">{node.id}</span>
                              {isSelected ? (
                                <span className="actor-team-dropdown-check">✓</span>
                              ) : null}
                            </li>
                          );
                        })
                      )}
                    </ul>
                  ) : null}
                </div>
                {selectedActorIds.length > 0 ? (
                  <div className="actor-team-tags">
                    {selectedActorIds.map((id) => {
                      const node = actors.find((n) => n.id === id);
                      const label = node ? node.displayName : id;
                      return (
                        <span key={id} className="actor-team-tag">
                          {label}
                          <button
                            type="button"
                            className="actor-team-tag-remove"
                            aria-label={`Remove ${label}`}
                            onMouseDown={(e) => {
                              e.preventDefault();
                              removeActor(id);
                            }}
                          >
                            ×
                          </button>
                        </span>
                      );
                    })}
                  </div>
                ) : null}
              </div>
            </label>

            <label>
              Teams
              <div className="actor-team-members-picker">
                <div className="actor-team-search-wrap">
                  <input
                    ref={teamSearchRef}
                    className="actor-team-search"
                    value={teamSearch}
                    onChange={(event) => {
                      setTeamSearch(event.target.value);
                      setTeamDropdownOpen(true);
                    }}
                    onFocus={() => setTeamDropdownOpen(true)}
                    onBlur={() => setTimeout(() => setTeamDropdownOpen(false), 150)}
                    placeholder="Search teams…"
                    autoComplete="off"
                  />
                  {teamDropdownOpen ? (
                    <ul className="actor-team-dropdown">
                      {listToShowTeams.length === 0 ? (
                        <li className="actor-team-dropdown-empty">No teams</li>
                      ) : (
                        listToShowTeams.map((team) => {
                          const isSelected = selectedTeamIds.includes(team.id);
                          return (
                            <li
                              key={team.id}
                              className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                              onMouseDown={(event) => {
                                event.preventDefault();
                                addTeam(team);
                              }}
                            >
                              <span className="actor-team-dropdown-name">{team.name}</span>
                              <span className="actor-team-dropdown-id">{team.id}</span>
                              {isSelected ? (
                                <span className="actor-team-dropdown-check">✓</span>
                              ) : null}
                            </li>
                          );
                        })
                      )}
                    </ul>
                  ) : null}
                </div>
                {selectedTeamIds.length > 0 ? (
                  <div className="actor-team-tags">
                    {selectedTeamIds.map((id) => {
                      const team = teams.find((t) => t.id === id);
                      const label = team ? team.name : id;
                      return (
                        <span key={id} className="actor-team-tag">
                          {label}
                          <button
                            type="button"
                            className="actor-team-tag-remove"
                            aria-label={`Remove ${label}`}
                            onMouseDown={(e) => {
                              e.preventDefault();
                              removeTeam(id);
                            }}
                          >
                            ×
                          </button>
                        </span>
                      );
                    })}
                  </div>
                ) : null}
              </div>
            </label>
          </div>

          <div className="project-modal-actions">
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="project-primary" disabled={!draft.displayName.trim()}>
              Create Project
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function ProjectTaskCreateModal({ isOpen, draft, onChange, onClose, onCreate }) {
  if (!isOpen) {
    return null;
  }

  return (
    <div className="project-modal-overlay" onClick={onClose}>
      <section className="project-modal" onClick={(event) => event.stopPropagation()}>
        <div className="project-modal-head">
          <h3>Create Task</h3>
          <button type="button" className="project-modal-close" aria-label="Close" onClick={onClose}>
            ×
          </button>
        </div>

        <form className="project-task-form" onSubmit={onCreate}>
          <label>
            Title
            <input
              value={draft.title}
              onChange={(event) => onChange("title", event.target.value)}
              placeholder="Task title..."
              autoFocus
            />
          </label>

          <label>
            Description
            <textarea
              value={draft.description}
              onChange={(event) => onChange("description", event.target.value)}
              rows={4}
              placeholder="Optional description..."
            />
          </label>

          <div className="project-task-form-grid">
            <label>
              Priority
              <select value={draft.priority} onChange={(event) => onChange("priority", event.target.value)}>
                {TASK_PRIORITIES.map((priority) => (
                  <option key={priority} value={priority}>
                    {TASK_PRIORITY_LABELS[priority]}
                  </option>
                ))}
              </select>
            </label>

            <label>
              Initial Status
              <select value={draft.status} onChange={(event) => onChange("status", event.target.value)}>
                {TASK_STATUSES.map((status) => (
                  <option key={status.id} value={status.id}>
                    {status.title}
                  </option>
                ))}
              </select>
            </label>
          </div>

          <div className="project-modal-actions">
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="project-primary" disabled={!draft.title.trim()}>
              Create
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function ProjectTaskEditModal({ isOpen, task, draft, onChange, onClose, onSave, onDelete }) {
  if (!isOpen || !task) {
    return null;
  }

  return (
    <div className="project-modal-overlay" onClick={onClose}>
      <section className="project-modal" onClick={(event) => event.stopPropagation()}>
        <div className="project-modal-head">
          <h3>Edit Task</h3>
          <button type="button" className="project-modal-close" aria-label="Close" onClick={onClose}>
            ×
          </button>
        </div>

        <form
          className="project-task-form"
          onSubmit={(event) => {
            event.preventDefault();
            onSave();
          }}
        >
          <label>
            Title
            <input
              value={draft.title}
              onChange={(event) => onChange("title", event.target.value)}
              placeholder="Task title..."
              autoFocus
            />
          </label>

          <label>
            Description
            <textarea
              value={draft.description}
              onChange={(event) => onChange("description", event.target.value)}
              rows={4}
              placeholder="Optional description..."
            />
          </label>

          <div className="project-task-form-grid">
            <label>
              Priority
              <select value={draft.priority} onChange={(event) => onChange("priority", event.target.value)}>
                {TASK_PRIORITIES.map((priority) => (
                  <option key={priority} value={priority}>
                    {TASK_PRIORITY_LABELS[priority]}
                  </option>
                ))}
              </select>
            </label>

            <label>
              Status
              <select value={draft.status} onChange={(event) => onChange("status", event.target.value)}>
                {TASK_STATUSES.map((status) => (
                  <option key={status.id} value={status.id}>
                    {status.title}
                  </option>
                ))}
              </select>
            </label>
          </div>

          <div className="project-modal-actions">
            <button type="button" className="danger" onClick={onDelete}>
              Delete task
            </button>
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="project-primary" disabled={!draft.title.trim()}>
              Save
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function ProjectTabPlaceholder({ title, text }) {
  return (
    <section className="project-pane">
      <h4>{title}</h4>
      <p className="placeholder-text">{text}</p>
    </section>
  );
}

export function ProjectsView({
  channelState,
  workers,
  bulletins = [],
  routeProjectId = null,
  onRouteProjectChange = () => {}
}) {
  const [projects, setProjects] = useState([]);
  const [isLoadingProjects, setIsLoadingProjects] = useState(true);
  const [statusText, setStatusText] = useState("Loading projects...");
  const [selectedTab, setSelectedTab] = useState("overview");
  const [chatSnapshots, setChatSnapshots] = useState({});
  const [isCreateProjectModalOpen, setIsCreateProjectModalOpen] = useState(false);
  const [projectDraft, setProjectDraft] = useState(() => emptyProjectDraft(1));
  const [isCreateTaskModalOpen, setIsCreateTaskModalOpen] = useState(false);
  const [taskDraft, setTaskDraft] = useState(emptyTaskDraft);
  const [editingTask, setEditingTask] = useState(null);
  const [editDraft, setEditDraft] = useState(emptyTaskDraft);
  const [projectNameDraft, setProjectNameDraft] = useState("");
  const [createModalActors, setCreateModalActors] = useState([]);
  const [createModalTeams, setCreateModalTeams] = useState([]);

  const selectedProject = useMemo(
    () => projects.find((project) => project.id === routeProjectId) || null,
    [projects, routeProjectId]
  );

  useEffect(() => {
    loadProjects().catch(() => {
      setStatusText("Failed to load projects from Core.");
      setIsLoadingProjects(false);
    });
  }, []);

  useEffect(() => {
    if (!isCreateProjectModalOpen) {
      return;
    }
    let isCancelled = false;
    (async () => {
      const raw = await fetchActorsBoard();
      if (isCancelled || !raw) {
        return;
      }
      const nodes = Array.isArray(raw.nodes)
        ? raw.nodes.map((n) => ({
            id: String(n?.id ?? ""),
            displayName: String(n?.displayName ?? n?.id ?? "")
          }))
        : [];
      const teamList = Array.isArray(raw.teams)
        ? raw.teams.map((t) => ({
            id: String(t?.id ?? ""),
            name: String(t?.name ?? t?.id ?? "")
          }))
        : [];
      setCreateModalActors(nodes);
      setCreateModalTeams(teamList);
    })();
    return () => {
      isCancelled = true;
    };
  }, [isCreateProjectModalOpen]);

  useEffect(() => {
    if (!selectedProject) {
      setProjectNameDraft("");
      setSelectedTab("overview");
      return;
    }

    setProjectNameDraft(selectedProject.name);
    if (!PROJECT_TAB_SET.has(selectedTab)) {
      setSelectedTab("overview");
    }
  }, [selectedProject?.id, selectedProject?.name, selectedTab]);

  useEffect(() => {
    if (isLoadingProjects || !routeProjectId) {
      return;
    }
    if (!selectedProject) {
      onRouteProjectChange(null);
      setStatusText("Project not found.");
    }
  }, [isLoadingProjects, routeProjectId, selectedProject, onRouteProjectChange]);

  useEffect(() => {
    if (!selectedProject) {
      setChatSnapshots({});
      return;
    }

    let isCancelled = false;

    async function loadSnapshots() {
      const entries = await Promise.all(
        selectedProject.chats.map(async (chat) => {
          if (channelState?.channelId === chat.channelId && channelState) {
            return [chat.channelId, channelState];
          }
          const snapshot = await fetchChannelState(chat.channelId);
          return [chat.channelId, snapshot];
        })
      );

      if (isCancelled) {
        return;
      }

      const next = {};
      for (const [channelId, snapshot] of entries) {
        if (snapshot) {
          next[channelId] = snapshot;
        }
      }
      setChatSnapshots(next);
    }

    loadSnapshots().catch(() => {
      if (!isCancelled) {
        setChatSnapshots({});
      }
    });

    return () => {
      isCancelled = true;
    };
  }, [selectedProject, channelState]);

  async function loadProjects() {
    setIsLoadingProjects(true);
    const response = await fetchProjectsRequest();
    if (!Array.isArray(response)) {
      setStatusText("Failed to load projects from Core.");
      setIsLoadingProjects(false);
      return;
    }

    const normalized = response.map((project, index) => normalizeProject(project, index));

    setProjects(normalized);
    setStatusText(normalized.length > 0 ? `Loaded ${normalized.length} projects from Core` : "No projects yet.");
    setIsLoadingProjects(false);
    if (routeProjectId && !normalized.some((project) => project.id === routeProjectId)) {
      onRouteProjectChange(null);
    }
  }

  function replaceProjectInState(rawProject) {
    if (!rawProject) {
      return;
    }

    const normalized = normalizeProject(rawProject);
    setProjects((previous) => {
      const withoutCurrent = previous.filter((project) => project.id !== normalized.id);
      return [...withoutCurrent, normalized].sort((left, right) =>
        left.name.localeCompare(right.name, undefined, { sensitivity: "base" })
      );
    });
  }

  function openProject(projectId) {
    onRouteProjectChange(projectId);
    setSelectedTab("overview");
  }

  function closeProject() {
    onRouteProjectChange(null);
    setSelectedTab("overview");
  }

  function openCreateProjectModal() {
    setProjectDraft(emptyProjectDraft(projects.length + 1));
    setIsCreateProjectModalOpen(true);
  }

  function closeCreateProjectModal() {
    setIsCreateProjectModalOpen(false);
    setProjectDraft(emptyProjectDraft(projects.length + 1));
  }

  function updateProjectDraft(field, value) {
    setProjectDraft((previous) => ({
      ...previous,
      [field]: value
    }));
  }

  async function createProject(event) {
    event.preventDefault();

    const displayName = String(projectDraft.displayName || "").trim();
    if (!displayName) {
      return;
    }

    const nextIndex = projects.length + 1;
    const projectId =
      normalizeProjectIdentifier(projectDraft.projectId) ||
      normalizeProjectIdentifier(toSlug(displayName)) ||
      `project-${nextIndex}`;
    const actorIds = parseListInput(projectDraft.actors);
    const teamIds = parseListInput(projectDraft.teams);
    const actors = actorIds.map(
      (id) => createModalActors.find((a) => a.id === id)?.displayName ?? id
    );
    const teams = teamIds.map(
      (id) => createModalTeams.find((t) => t.id === id)?.name ?? id
    );

    const created = await createProjectRequest({
      id: projectId,
      name: displayName,
      description: String(projectDraft.description || "").trim(),
      channels: buildProjectChannels(projectId, actors, teams),
      actors,
      teams
    });

    if (!created) {
      setStatusText("Failed to create project in Core.");
      return;
    }

    replaceProjectInState(created);
    onRouteProjectChange(String(created.id || ""));
    closeCreateProjectModal();
    setStatusText(`Project ${displayName} created.`);
  }

  async function renameProject(projectId, explicitName = null) {
    const project = projects.find((item) => item.id === projectId);
    if (!project) {
      return;
    }

    const input = explicitName == null ? window.prompt("Project name", project.name) : explicitName;
    if (input == null) {
      return;
    }

    const nextName = String(input).trim();
    if (!nextName) {
      return;
    }

    const updated = await updateProjectRequest(projectId, { name: nextName });
    if (!updated) {
      setStatusText("Failed to rename project in Core.");
      return;
    }

    replaceProjectInState(updated);
    setStatusText(`Project renamed to ${nextName}.`);
  }

  async function deleteProject(projectId) {
    const project = projects.find((item) => item.id === projectId);
    if (!project) {
      return;
    }

    const accepted = window.confirm(`Delete project "${project.name}"?`);
    if (!accepted) {
      return;
    }

    const ok = await deleteProjectRequest(projectId);
    if (!ok) {
      setStatusText("Failed to delete project in Core.");
      return;
    }

    setProjects((previous) => previous.filter((candidate) => candidate.id !== projectId));
    if (routeProjectId === projectId) {
      onRouteProjectChange(null);
    }
    setStatusText(`Project ${project.name} deleted.`);
  }

  function updateTaskDraft(field, value) {
    setTaskDraft((previous) => ({
      ...previous,
      [field]: value
    }));
  }

  function openCreateTaskModal(initialStatus = "backlog") {
    setTaskDraft(emptyTaskDraft(initialStatus));
    setIsCreateTaskModalOpen(true);
  }

  function closeCreateTaskModal() {
    setTaskDraft(emptyTaskDraft());
    setIsCreateTaskModalOpen(false);
  }

  function openEditTaskModal(task) {
    setEditingTask(task);
    setEditDraft({
      title: task.title,
      description: task.description || "",
      priority: task.priority,
      status: task.status
    });
  }

  function closeEditTaskModal() {
    setEditingTask(null);
    setEditDraft(emptyTaskDraft());
  }

  function updateEditDraft(field, value) {
    setEditDraft((prev) => ({ ...prev, [field]: value }));
  }

  async function saveTaskEdit() {
    if (!selectedProject || !editingTask) {
      return;
    }
    const title = String(editDraft.title || "").trim();
    if (!title) {
      return;
    }
    const updated = await updateProjectTaskRequest(selectedProject.id, editingTask.id, {
      title,
      description: String(editDraft.description || "").trim(),
      priority: editDraft.priority,
      status: editDraft.status
    });
    if (!updated) {
      setStatusText("Failed to update task in Core.");
      return;
    }
    replaceProjectInState(updated);
    closeEditTaskModal();
    setStatusText("Task updated.");
  }

  async function deleteTaskFromModal() {
    if (!editingTask) {
      return;
    }
    const accepted = window.confirm("Delete this task?");
    if (!accepted) {
      return;
    }
    if (!selectedProject) {
      return;
    }
    const updated = await deleteProjectTaskRequest(selectedProject.id, editingTask.id);
    if (!updated) {
      setStatusText("Failed to delete task.");
      return;
    }
    replaceProjectInState(updated);
    closeEditTaskModal();
    setStatusText("Task deleted.");
  }

  async function createTask(event) {
    event.preventDefault();

    if (!selectedProject) {
      return;
    }

    const title = String(taskDraft.title || "").trim();
    if (!title) {
      return;
    }

    const updated = await createProjectTaskRequest(selectedProject.id, {
      title,
      description: String(taskDraft.description || "").trim(),
      priority: taskDraft.priority,
      status: taskDraft.status
    });

    if (!updated) {
      setStatusText("Failed to create task in Core.");
      return;
    }

    replaceProjectInState(updated);
    closeCreateTaskModal();
    setStatusText("Task created.");
  }

  async function moveTask(taskId, nextStatus) {
    if (!selectedProject || !TASK_STATUS_SET.has(nextStatus)) {
      return;
    }

    const updated = await updateProjectTaskRequest(selectedProject.id, taskId, { status: nextStatus });
    if (!updated) {
      setStatusText("Failed to update task status.");
      return;
    }

    replaceProjectInState(updated);
  }

  async function deleteTask(taskId) {
    if (!selectedProject) {
      return;
    }

    const accepted = window.confirm("Delete this task?");
    if (!accepted) {
      return;
    }

    const updated = await deleteProjectTaskRequest(selectedProject.id, taskId);
    if (!updated) {
      setStatusText("Failed to delete task.");
      return;
    }

    replaceProjectInState(updated);
    setStatusText("Task deleted.");
  }

  async function addProjectChannel() {
    if (!selectedProject) {
      return;
    }

    const titleInput = window.prompt("Channel title", "New channel");
    if (titleInput == null) {
      return;
    }

    const channelIdInput = window.prompt("Channel id", `${toSlug(selectedProject.name)}-${selectedProject.chats.length + 1}`);
    if (channelIdInput == null) {
      return;
    }

    const title = String(titleInput || "").trim() || "New channel";
    const channelId = String(channelIdInput || "").trim();
    if (!channelId) {
      return;
    }

    const updated = await createProjectChannelRequest(selectedProject.id, { title, channelId });
    if (!updated) {
      setStatusText("Failed to add channel to project.");
      return;
    }

    replaceProjectInState(updated);
    setStatusText("Channel added.");
  }

  async function removeProjectChannel(chatId) {
    if (!selectedProject) {
      return;
    }

    const accepted = window.confirm("Delete this channel from project?");
    if (!accepted) {
      return;
    }

    const updated = await deleteProjectChannelRequest(selectedProject.id, chatId);
    if (!updated) {
      setStatusText("Failed to remove channel from project.");
      return;
    }

    replaceProjectInState(updated);
    setStatusText("Channel removed.");
  }

  async function saveProjectSettings() {
    if (!selectedProject) {
      return;
    }

    const nextName = String(projectNameDraft || "").trim();
    if (!nextName) {
      return;
    }

    const updated = await updateProjectRequest(selectedProject.id, { name: nextName });
    if (!updated) {
      setStatusText("Failed to save project settings.");
      return;
    }

    replaceProjectInState(updated);
    setStatusText("Project settings saved.");
  }

  function renderProjectList() {
    if (isLoadingProjects) {
      return (
        <section className="project-board-list">
          <article className="project-board-card">
            <p className="placeholder-text">Loading projects from Core...</p>
          </article>
        </section>
      );
    }

    if (projects.length === 0) {
      return (
        <section className="project-board-list project-board-list--empty">
          <article className="project-board-empty">
            <div className="project-board-empty-actions">
              <p className="project-new-action project-new-action--hero" onClick={openCreateProjectModal}>
                Start your first project!
              </p>
              <button type="button" className="project-new-action" onClick={openCreateProjectModal}>
                New Projects
              </button>
            </div>
          </article>
        </section>
      );
    }

    return (
      <section className="project-board-list">
        {projects.map((project) => {
          const relatedWorkers = workersForProject(project, workers);
          const activeWorkers = activeWorkersForProject(project, workers);
          const taskCounts = buildTaskCounts(project.tasks);

          return (
            <article
              key={project.id}
              className="project-board-card project-board-card--clickable"
              role="button"
              tabIndex={0}
              onClick={() => openProject(project.id)}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  openProject(project.id);
                }
              }}
            >
              <div className="project-board-card-head">
                <h3>{project.name}</h3>
                <span className="project-board-updated">{formatRelativeTime(project.updatedAt)}</span>
              </div>

              <p className="project-board-description placeholder-text">
                {project.description || "No description"}
              </p>

              <div className="project-board-stats">
                <span className="project-badge project-badge--tasks">{taskCounts.total} tasks</span>
                <span className="project-badge project-badge--progress">{taskCounts.in_progress} in progress</span>
                <span className="project-badge project-badge--active">{activeWorkers.length} active workers</span>
                <span className="project-badge project-badge--workers">{relatedWorkers.length} workers total</span>
              </div>
            </article>
          );
        })}
      </section>
    );
  }

  function renderOverviewTab(project) {
    const relatedWorkers = workersForProject(project, workers);
    const activeWorkers = activeWorkersForProject(project, workers);
    const taskCounts = buildTaskCounts(project.tasks);
    const createdItems = extractCreatedItems(project, chatSnapshots);

    return (
      <section className="project-tab-layout">
        <section className="project-overview-metrics">
          <article className="project-metric-card">
            <p>Total tasks</p>
            <strong>{taskCounts.total}</strong>
          </article>
          <article className="project-metric-card">
            <p>In progress</p>
            <strong>{taskCounts.in_progress}</strong>
          </article>
          <article className="project-metric-card">
            <p>Active agents</p>
            <strong>{activeWorkers.length}</strong>
          </article>
          <article className="project-metric-card">
            <p>Channels</p>
            <strong>{project.chats.length}</strong>
          </article>
        </section>

        <section className="project-pane">
          <div className="project-pane-head">
            <h4>Working Agents</h4>
          </div>

          {activeWorkers.length === 0 ? (
            <p className="placeholder-text">No active workers for this project right now.</p>
          ) : (
            <div className="project-workers-list">
              {activeWorkers.map((worker, index) => (
                <article key={String(worker?.workerId || `worker-${index}`)} className="project-worker-item">
                  <strong>{String(worker?.workerId || "worker")}</strong>
                  <p>Task: {String(worker?.taskId || "unknown")}</p>
                  <p>Status: {String(worker?.status || "unknown")}</p>
                  <p>Mode: {String(worker?.mode || "unknown")}</p>
                  {worker?.latestReport ? <p>Report: {String(worker.latestReport)}</p> : null}
                </article>
              ))}
            </div>
          )}

          {activeWorkers.length === 0 && relatedWorkers.length > 0 ? (
            <p className="placeholder-text">Workers exist, but none are currently active.</p>
          ) : null}
        </section>

        <section className="project-pane">
          <div className="project-pane-head">
            <h4>Created Files / Artifacts</h4>
          </div>

          {createdItems.length === 0 ? (
            <p className="placeholder-text">No files or artifacts detected in project runtime messages yet.</p>
          ) : (
            <div className="project-created-list">
              {createdItems.map((item) => (
                <article key={item.key} className="project-created-item">
                  <strong>{item.type === "artifact" ? "Artifact" : "File"}</strong>
                  <p>{item.value}</p>
                  <p className="placeholder-text">Channel: {item.channelId}</p>
                </article>
              ))}
            </div>
          )}
        </section>
      </section>
    );
  }

  function renderTasksTab(project) {
    const taskCounts = buildTaskCounts(project.tasks);

    return (
      <section className="project-tab-layout">
        <section className="project-pane project-kanban-pane">
          <div className="project-kanban-head">
            <div className="project-kanban-summary">
              <span>{taskCounts.total} task{taskCounts.total === 1 ? "" : "s"}</span>
              <span>{taskCounts.in_progress} in progress</span>
            </div>
            <button type="button" className="project-primary" onClick={() => openCreateTaskModal("backlog")}>
              Create Task
            </button>
          </div>

          <div className="project-kanban-board">
            {TASK_STATUSES.map((column) => {
              const tasks = sortTasksByDate(project.tasks.filter((task) => task.status === column.id));

              return (
                <section
                  key={column.id}
                  className="project-kanban-column"
                  onDragOver={(event) => event.preventDefault()}
                  onDrop={(event) => {
                    event.preventDefault();
                    const taskId = event.dataTransfer.getData("text/project-task-id");
                    if (taskId) {
                      moveTask(taskId, column.id);
                    }
                  }}
                >
                  <header className={`project-kanban-column-head project-kanban-column-head--${column.id}`}>
                    <span>{column.title}</span>
                    <strong>{tasks.length}</strong>
                  </header>

                  <div className="project-kanban-column-body">
                    {tasks.length === 0 ? (
                      <p className="placeholder-text">No tasks</p>
                    ) : (
                      tasks.map((task) => (
                        <article
                          key={task.id}
                          className="project-kanban-task project-kanban-task--clickable"
                          role="button"
                          tabIndex={0}
                          draggable
                          onClick={() => openEditTaskModal(task)}
                          onKeyDown={(event) => {
                            if (event.key === "Enter" || event.key === " ") {
                              event.preventDefault();
                              openEditTaskModal(task);
                            }
                          }}
                          onDragStart={(event) => {
                            event.dataTransfer.setData("text/project-task-id", task.id);
                            event.dataTransfer.effectAllowed = "move";
                          }}
                        >
                          <h5>{task.title}</h5>
                          {task.description ? <p>{task.description}</p> : null}

                          <div className="project-task-meta">
                            <span className={`project-priority-badge ${task.priority}`}>
                              {TASK_PRIORITY_LABELS[task.priority] || "Medium"}
                            </span>
                            <span className="project-task-age">{formatRelativeTime(task.createdAt)}</span>
                          </div>

                          <div className="project-task-actions" onClick={(e) => e.stopPropagation()}>
                            <select
                              value={task.status}
                              onChange={(event) => moveTask(task.id, String(event.target.value))}
                              aria-label="Task status"
                            >
                              {TASK_STATUSES.map((status) => (
                                <option key={status.id} value={status.id}>
                                  {status.title}
                                </option>
                              ))}
                            </select>
                            <button type="button" className="danger" onClick={() => deleteTask(task.id)}>
                              Delete
                            </button>
                          </div>
                        </article>
                      ))
                    )}
                  </div>
                </section>
              );
            })}
          </div>
        </section>
      </section>
    );
  }

  function renderWorkersTab(project) {
    const projectWorkers = workersForProject(project, workers);

    if (projectWorkers.length === 0) {
      return <ProjectTabPlaceholder title="Workers" text="No workers are linked to this project yet." />;
    }

    return (
      <section className="project-tab-layout">
        <section className="project-pane">
          <h4>Workers</h4>
          <div className="project-workers-list">
            {projectWorkers.map((worker, index) => (
              <article key={String(worker?.workerId || `worker-${index}`)} className="project-worker-item">
                <strong>{String(worker?.workerId || "worker")}</strong>
                <p>Task: {String(worker?.taskId || "unknown")}</p>
                <p>Status: {String(worker?.status || "unknown")}</p>
                <p>Mode: {String(worker?.mode || "unknown")}</p>
                {Array.isArray(worker?.tools) ? <p>Tools: {worker.tools.join(", ") || "none"}</p> : null}
                {worker?.latestReport ? <p>Report: {String(worker.latestReport)}</p> : null}
              </article>
            ))}
          </div>
        </section>
      </section>
    );
  }

  function renderMemoriesTab(project) {
    return (
      <section className="project-tab-layout">
        <section className="project-pane">
          <h4>Memories</h4>

          {project.chats.map((chat) => {
            const snapshot = chatSnapshots[chat.channelId];
            const messages = Array.isArray(snapshot?.messages) ? snapshot.messages : [];
            const recent = messages.slice(-5).reverse();

            return (
              <article key={chat.id} className="project-memory-channel">
                <header>
                  <strong>{chat.title}</strong>
                  <span className="placeholder-text">{chat.channelId}</span>
                </header>

                {recent.length === 0 ? (
                  <p className="placeholder-text">No messages in this channel yet.</p>
                ) : (
                  <div className="project-memory-messages">
                    {recent.map((message, index) => (
                      <div key={String(message?.id || `message-${chat.id}-${index}`)} className="project-memory-message">
                        <strong>{String(message?.userId || "user")}</strong>
                        <p>{String(message?.content || "")}</p>
                      </div>
                    ))}
                  </div>
                )}
              </article>
            );
          })}
        </section>
      </section>
    );
  }

  function renderVisorTab(project) {
    const decisions = project.chats
      .map((chat) => ({
        chat,
        decision: chatSnapshots[chat.channelId]?.lastDecision || null
      }))
      .filter((entry) => entry.decision);

    return (
      <section className="project-tab-layout">
        <section className="project-pane">
          <h4>Visor</h4>

          {decisions.length === 0 ? (
            <p className="placeholder-text">No channel decisions available yet.</p>
          ) : (
            <div className="project-created-list">
              {decisions.map((entry) => (
                <article key={entry.chat.id} className="project-created-item">
                  <strong>{entry.chat.title}</strong>
                  <p>Action: {String(entry.decision.action || "unknown")}</p>
                  <p>Reason: {String(entry.decision.reason || "unknown")}</p>
                  <p>
                    Confidence:{" "}
                    {typeof entry.decision.confidence === "number"
                      ? entry.decision.confidence.toFixed(2)
                      : String(entry.decision.confidence || "n/a")}
                  </p>
                </article>
              ))}
            </div>
          )}
        </section>

        <section className="project-pane">
          <h4>Bulletins</h4>
          {Array.isArray(bulletins) && bulletins.length > 0 ? (
            <div className="project-created-list">
              {bulletins.slice(0, 8).map((bulletin, index) => (
                <article key={String(bulletin?.id || `bulletin-${index}`)} className="project-created-item">
                  <strong>{String(bulletin?.headline || "Runtime bulletin")}</strong>
                  <p>{String(bulletin?.digest || "")}</p>
                </article>
              ))}
            </div>
          ) : (
            <p className="placeholder-text">No bulletins available.</p>
          )}
        </section>
      </section>
    );
  }

  function renderSettingsTab(project) {
    return (
      <section className="project-tab-layout">
        <section className="project-pane">
          <h4>Project Settings</h4>

          <form
            className="project-settings-form"
            onSubmit={(event) => {
              event.preventDefault();
              saveProjectSettings();
            }}
          >
            <label>
              Project name
              <input value={projectNameDraft} onChange={(event) => setProjectNameDraft(event.target.value)} />
            </label>

            <div className="project-settings-actions">
              <button type="submit" className="project-primary">
                Save Name
              </button>
              <button type="button" className="danger" onClick={() => deleteProject(project.id)}>
                Delete Project
              </button>
            </div>
          </form>
        </section>

        <section className="project-pane">
          <div className="project-pane-head">
            <h4>Channels</h4>
            <button type="button" onClick={addProjectChannel}>
              Add Channel
            </button>
          </div>

          <div className="project-created-list">
            {project.chats.map((chat) => (
              <article key={chat.id} className="project-created-item">
                <strong>{chat.title}</strong>
                <p>{chat.channelId}</p>
                <div className="project-settings-actions">
                  <button
                    type="button"
                    className="danger"
                    disabled={project.chats.length <= 1}
                    onClick={() => removeProjectChannel(chat.id)}
                  >
                    Remove
                  </button>
                </div>
              </article>
            ))}
          </div>
        </section>
      </section>
    );
  }

  function renderProjectTab(project) {
    if (selectedTab === "overview") {
      return renderOverviewTab(project);
    }

    if (selectedTab === "tasks") {
      return renderTasksTab(project);
    }

    if (selectedTab === "workers") {
      return renderWorkersTab(project);
    }

    if (selectedTab === "memories") {
      return renderMemoriesTab(project);
    }

    if (selectedTab === "visor") {
      return renderVisorTab(project);
    }

    return renderSettingsTab(project);
  }

  function renderProjectDetails(project) {
    return (
      <section className="project-workspace">
        <header className="project-workspace-head">
          <button type="button" className="project-back-link" onClick={closeProject}>
            <span className="material-symbols-rounded" aria-hidden="true">
              arrow_back
            </span>
            Back to projects
          </button>
          <div className="project-workspace-meta">
            <h3>{project.name}</h3>
            <p className="placeholder-text">{project.description || "Project dashboard"}</p>
          </div>
        </header>

        <section className="agent-tabs" aria-label="Project sections">
          {PROJECT_TABS.map((tab) => (
            <button
              key={tab.id}
              type="button"
              className={`agent-tab ${selectedTab === tab.id ? "active" : ""}`}
              onClick={() => setSelectedTab(tab.id)}
            >
              {tab.title}
            </button>
          ))}
        </section>

        {renderProjectTab(project)}
      </section>
    );
  }

  return (
    <main className="projects-shell">
      {projects.length > 0 && (
        <div className="projects-head">
          <button type="button" className="project-new-action" onClick={openCreateProjectModal}>
            New Project
          </button>
        </div>
      )}

      {selectedProject ? renderProjectDetails(selectedProject) : renderProjectList()}

      {statusText && statusText !== "No projects yet." && statusText !== "Loading projects..." && (
        <p className="placeholder-text">{statusText}</p>
      )}

      <ProjectCreateModal
        isOpen={isCreateProjectModalOpen}
        draft={projectDraft}
        onChange={updateProjectDraft}
        onClose={closeCreateProjectModal}
        onCreate={createProject}
        actors={createModalActors}
        teams={createModalTeams}
      />

      <ProjectTaskCreateModal
        isOpen={isCreateTaskModalOpen}
        draft={taskDraft}
        onChange={updateTaskDraft}
        onClose={closeCreateTaskModal}
        onCreate={createTask}
      />

      <ProjectTaskEditModal
        isOpen={Boolean(editingTask)}
        task={editingTask}
        draft={editDraft}
        onChange={updateEditDraft}
        onClose={closeEditTaskModal}
        onSave={saveTaskEdit}
        onDelete={deleteTaskFromModal}
      />
    </main>
  );
}

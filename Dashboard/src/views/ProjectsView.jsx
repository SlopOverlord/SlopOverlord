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
import { Breadcrumbs } from "../components/Breadcrumbs/Breadcrumbs";

import {
  ACTIVE_WORKER_STATUSES,
  PROJECT_TABS,
  TASK_STATUSES,
  TASK_PRIORITIES,
  TASK_PRIORITY_LABELS,
  PROJECT_TAB_SET,
  TASK_STATUS_SET,
  TASK_PRIORITY_SET,
  createId,
  toSlug,
  emptyTaskDraft,
  normalizeChat,
  normalizeTask,
  normalizeProject,
  sortTasksByDate,
  buildTaskReference,
  resolveTaskByReference,
  workersForProject,
  activeWorkersForProject,
  buildTaskCounts,
  buildSwarmGroups,
  formatRelativeTime,
  extractCreatedItems,
  normalizeProjectIdentifier,
  parseListInput,
  buildProjectChannels,
  emptyProjectDraft
} from "./Projects/utils";
import { ProjectOverviewTab } from "./Projects/ProjectOverviewTab";
import { ProjectTasksTab } from "./Projects/ProjectTasksTab";
import { ProjectWorkersTab } from "./Projects/ProjectWorkersTab";
import { ProjectMemoriesTab } from "./Projects/ProjectMemoriesTab";
import { ProjectVisorTab } from "./Projects/ProjectVisorTab";
import { ProjectSettingsTab } from "./Projects/ProjectSettingsTab";
import { ProjectList } from "./Projects/ProjectList";

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
            <button type="submit" className="project-primary hover-levitate" disabled={!draft.displayName.trim()}>
              Create Project
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function ProjectTaskCreateModal({ isOpen, draft, onChange, onClose, onCreate, actors = [], teams = [] }) {
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

          <div className="project-task-form-grid">
            <label>
              Assign Actor
              <select value={draft.actorId || ""} onChange={(event) => onChange("actorId", event.target.value)}>
                <option value="">Unassigned</option>
                {actors.map((actor) => (
                  <option key={actor.id} value={actor.id}>
                    {actor.displayName} ({actor.id})
                  </option>
                ))}
              </select>
            </label>

            <label>
              Assign Team
              <select value={draft.teamId || ""} onChange={(event) => onChange("teamId", event.target.value)}>
                <option value="">Unassigned</option>
                {teams.map((team) => (
                  <option key={team.id} value={team.id}>
                    {team.name} ({team.id})
                  </option>
                ))}
              </select>
            </label>
          </div>

          <div className="project-modal-actions">
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="project-primary hover-levitate" disabled={!draft.title.trim()}>
              Create
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function AddChannelModal({ isOpen, projectChannels, availableChannels, draft, onChange, onClose, onAdd }) {
  const [channelSearch, setChannelSearch] = useState("");
  const [dropdownOpen, setDropdownOpen] = useState(false);
  const searchRef = useRef(null);

  const projectChannelIds = useMemo(() => new Set(projectChannels.map((ch) => ch.channelId)), [projectChannels]);

  const filteredChannels = useMemo(() => {
    const q = channelSearch.trim().toLowerCase();
    return availableChannels.filter((ch) => {
      if (projectChannelIds.has(ch.channelId)) {
        return false;
      }
      if (!q) {
        return true;
      }
      return (
        ch.channelId.toLowerCase().includes(q) ||
        ch.displayName.toLowerCase().includes(q)
      );
    });
  }, [availableChannels, projectChannelIds, channelSearch]);

  if (!isOpen) {
    return null;
  }

  function selectChannel(channel) {
    onChange("channelId", channel.channelId);
    setChannelSearch("");
    setDropdownOpen(false);
  }

  function clearSelection() {
    onChange("channelId", "");
    setChannelSearch("");
  }

  const selectedChannel = availableChannels.find((ch) => ch.channelId === draft.channelId);

  return (
    <div className="project-modal-overlay" onClick={onClose}>
      <section className="project-modal" onClick={(event) => event.stopPropagation()}>
        <div className="project-modal-head">
          <h3>Add Channel</h3>
          <button type="button" className="project-modal-close" aria-label="Close" onClick={onClose}>
            ×
          </button>
        </div>

        <form
          className="project-task-form"
          onSubmit={(event) => {
            event.preventDefault();
            onAdd();
          }}
        >
          <label>
            Channel Title
            <input
              value={draft.title}
              onChange={(event) => onChange("title", event.target.value)}
              placeholder="Channel title..."
              autoFocus
            />
          </label>

          <label>
            Channel ID
            <div className="actor-team-members-picker">
              {draft.channelId ? (
                <div className="actor-team-tags">
                  <span className="actor-team-tag">
                    {selectedChannel ? selectedChannel.displayName : draft.channelId}
                    <button
                      type="button"
                      className="actor-team-tag-remove"
                      aria-label="Remove channel"
                      onClick={clearSelection}
                    >
                      ×
                    </button>
                  </span>
                </div>
              ) : null}
              <div className="actor-team-search-wrap">
                <input
                  ref={searchRef}
                  className="actor-team-search"
                  value={channelSearch}
                  onChange={(event) => {
                    setChannelSearch(event.target.value);
                    setDropdownOpen(true);
                  }}
                  onFocus={() => setDropdownOpen(true)}
                  onBlur={() => setTimeout(() => setDropdownOpen(false), 150)}
                  placeholder="Search channels..."
                  autoComplete="off"
                />
                {dropdownOpen ? (
                  <ul className="actor-team-dropdown">
                    {filteredChannels.length === 0 ? (
                      <li className="actor-team-dropdown-empty">
                        {availableChannels.length === 0 ? "No channels available" : "No matching channels"}
                      </li>
                    ) : (
                      filteredChannels.map((ch) => (
                        <li
                          key={ch.channelId}
                          className="actor-team-dropdown-item"
                          onMouseDown={(event) => {
                            event.preventDefault();
                            selectChannel(ch);
                          }}
                        >
                          <span className="actor-team-dropdown-name">{ch.displayName}</span>
                          <span className="actor-team-dropdown-id">{ch.channelId}</span>
                        </li>
                      ))
                    )}
                  </ul>
                ) : null}
              </div>
            </div>
          </label>

          <div className="project-modal-actions">
            <button type="button" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="project-primary hover-levitate" disabled={!draft.channelId.trim()}>
              Add Channel
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
  routeProjectTab = "overview",
  routeProjectTaskReference = null,
  onRouteProjectChange = () => { }
}) {
  const [projects, setProjects] = useState([]);
  const [isLoadingProjects, setIsLoadingProjects] = useState(true);
  const [statusText, setStatusText] = useState("Loading projects...");
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
  const [isAddChannelModalOpen, setIsAddChannelModalOpen] = useState(false);
  const [addChannelDraft, setAddChannelDraft] = useState({ title: "", channelId: "" });
  const [availableChannels, setAvailableChannels] = useState([]);
  const [isTaskDetailFullscreen, setIsTaskDetailFullscreen] = useState(false);

  const selectedProject = useMemo(() => {
    if (routeProjectId) {
      return projects.find((project) => project.id === routeProjectId) || null;
    }
    if (!routeProjectTaskReference) {
      return null;
    }
    return (
      projects.find((project) => resolveTaskByReference(project.id, project.tasks, routeProjectTaskReference)) || null
    );
  }, [projects, routeProjectId, routeProjectTaskReference]);
  const selectedTab = useMemo(() => {
    if (!selectedProject) {
      return "overview";
    }
    const candidate = String(routeProjectTab || "").trim().toLowerCase();
    return PROJECT_TAB_SET.has(candidate) ? candidate : "overview";
  }, [selectedProject, routeProjectTab]);
  const selectedTask = useMemo(() => {
    if (!selectedProject || selectedTab !== "tasks") {
      return null;
    }
    return resolveTaskByReference(selectedProject.id, selectedProject.tasks, routeProjectTaskReference);
  }, [selectedProject, selectedTab, routeProjectTaskReference]);

  useEffect(() => {
    loadProjects().catch(() => {
      setStatusText("Failed to load projects from Core.");
      setIsLoadingProjects(false);
    });
  }, []);

  useEffect(() => {
    const shouldLoadAssignments =
      isCreateProjectModalOpen ||
      isCreateTaskModalOpen ||
      Boolean(editingTask) ||
      selectedTab === "settings" ||
      selectedTab === "tasks";

    if (!shouldLoadAssignments) {
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
  }, [isCreateProjectModalOpen, isCreateTaskModalOpen, editingTask, selectedTab]);

  useEffect(() => {
    if (!selectedProject) {
      setProjectNameDraft("");
      return;
    }

    setProjectNameDraft(selectedProject.name);
  }, [selectedProject?.id, selectedProject?.name]);

  useEffect(() => {
    if (isLoadingProjects || !routeProjectId) {
      return;
    }
    if (!selectedProject) {
      onRouteProjectChange(null, null);
      setStatusText("Project not found.");
    }
  }, [isLoadingProjects, routeProjectId, selectedProject, onRouteProjectChange]);

  useEffect(() => {
    if (isLoadingProjects || routeProjectId || !routeProjectTaskReference) {
      return;
    }
    if (!selectedProject) {
      onRouteProjectChange(null, null, null);
      setStatusText("Task not found.");
      setIsTaskDetailFullscreen(false);
      closeEditTaskModal();
    }
  }, [isLoadingProjects, routeProjectId, routeProjectTaskReference, selectedProject, onRouteProjectChange]);

  useEffect(() => {
    if (!selectedProject || selectedTab !== "tasks") {
      setIsTaskDetailFullscreen(false);
      return;
    }
    if (!routeProjectTaskReference) {
      return;
    }
    if (!selectedTask) {
      onRouteProjectChange(selectedProject.id, "tasks", null);
      setStatusText("Task not found.");
      setIsTaskDetailFullscreen(false);
      closeEditTaskModal();
    }
  }, [selectedProject, selectedTab, routeProjectTaskReference, selectedTask, onRouteProjectChange]);

  useEffect(() => {
    if (!selectedTask) {
      setEditingTask(null);
      setEditDraft(emptyTaskDraft());
      return;
    }
    const resolvedActorId = selectedTask.claimedActorId || selectedTask.actorId || "";
    setEditingTask(selectedTask);
    setEditDraft({
      title: selectedTask.title,
      description: selectedTask.description || "",
      priority: selectedTask.priority,
      status: selectedTask.status,
      actorId: resolvedActorId,
      teamId: selectedTask.teamId || ""
    });
  }, [
    selectedTask?.id,
    selectedTask?.updatedAt,
    selectedTask?.title,
    selectedTask?.description,
    selectedTask?.priority,
    selectedTask?.status,
    selectedTask?.actorId,
    selectedTask?.teamId,
    selectedTask?.claimedActorId
  ]);

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
      onRouteProjectChange(null, null);
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

  function openProject(projectId, projectTab = "overview") {
    closeEditTaskModal();
    onRouteProjectChange(projectId, projectTab, null);
  }

  function closeProject() {
    closeEditTaskModal();
    onRouteProjectChange(null, null, null);
    setIsTaskDetailFullscreen(false);
  }

  function openTaskDetails(task) {
    if (!selectedProject || !task) {
      return;
    }
    openEditTaskModal(task);
    const taskReference = String(task.id || "").trim();
    onRouteProjectChange(selectedProject.id, "tasks", taskReference);
  }

  function closeTaskDetails() {
    if (!selectedProject) {
      return;
    }
    closeEditTaskModal();
    onRouteProjectChange(selectedProject.id, "tasks", null);
    setIsTaskDetailFullscreen(false);
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
    onRouteProjectChange(String(created.id || ""), "overview");
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
      onRouteProjectChange(null, null);
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
    const resolvedActorId = task.claimedActorId || task.actorId || "";
    setEditingTask(task);
    setEditDraft({
      title: task.title,
      description: task.description || "",
      priority: task.priority,
      status: task.status,
      actorId: resolvedActorId,
      teamId: task.teamId || ""
    });
  }

  function closeEditTaskModal() {
    setEditingTask(null);
    setEditDraft(emptyTaskDraft());
  }

  function updateEditDraft(field, value) {
    setEditDraft((prev) => ({ ...prev, [field]: value }));
  }

  function updateDetailAssignee(nextValue) {
    const token = String(nextValue || "").trim();
    if (!token) {
      setEditDraft((prev) => ({ ...prev, actorId: "", teamId: "" }));
      return;
    }
    if (token.startsWith("actor:")) {
      const actorId = token.slice("actor:".length).trim();
      setEditDraft((prev) => ({ ...prev, actorId, teamId: "" }));
      return;
    }
    if (token.startsWith("team:")) {
      const teamId = token.slice("team:".length).trim();
      setEditDraft((prev) => ({ ...prev, actorId: "", teamId }));
      return;
    }
  }

  async function saveTaskEdit() {
    const taskToUpdate = editingTask || selectedTask;
    if (!selectedProject || !taskToUpdate) {
      return;
    }
    const title = String(editDraft.title || "").trim();
    if (!title) {
      return;
    }
    const updated = await updateProjectTaskRequest(selectedProject.id, taskToUpdate.id, {
      title,
      description: String(editDraft.description || "").trim(),
      priority: editDraft.priority,
      status: editDraft.status,
      actorId: String(editDraft.actorId || "").trim() || null,
      teamId: String(editDraft.teamId || "").trim() || null
    });
    if (!updated) {
      setStatusText("Failed to update task in Core.");
      return;
    }
    replaceProjectInState(updated);
    setEditingTask(taskToUpdate);
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
    const deletedTaskId = String(editingTask.id || "").trim();
    const updated = await deleteProjectTaskRequest(selectedProject.id, editingTask.id);
    if (!updated) {
      setStatusText("Failed to delete task.");
      return;
    }
    replaceProjectInState(updated);
    if (selectedTask && String(selectedTask.id || "").trim() === deletedTaskId) {
      onRouteProjectChange(selectedProject.id, "tasks", null);
      setIsTaskDetailFullscreen(false);
    }
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
      status: taskDraft.status,
      actorId: String(taskDraft.actorId || "").trim() || null,
      teamId: String(taskDraft.teamId || "").trim() || null
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

  async function openAddChannelModal() {
    if (!selectedProject) {
      return;
    }

    const board = await fetchActorsBoard();
    const channels = [];
    if (board && Array.isArray(board.nodes)) {
      for (const node of board.nodes) {
        if (node.channelId) {
          channels.push({
            channelId: String(node.channelId),
            displayName: String(node.displayName || node.channelId)
          });
        }
      }
    }

    const uniqueChannels = [];
    const seen = new Set();
    for (const ch of channels) {
      if (!seen.has(ch.channelId)) {
        seen.add(ch.channelId);
        uniqueChannels.push(ch);
      }
    }

    setAvailableChannels(uniqueChannels);
    setAddChannelDraft({
      title: "New channel",
      channelId: ""
    });
    setIsAddChannelModalOpen(true);
  }

  function closeAddChannelModal() {
    setIsAddChannelModalOpen(false);
    setAddChannelDraft({ title: "", channelId: "" });
  }

  function updateAddChannelDraft(field, value) {
    setAddChannelDraft((previous) => ({
      ...previous,
      [field]: value
    }));
  }

  async function submitAddChannel() {
    if (!selectedProject) {
      return;
    }

    const title = String(addChannelDraft.title || "").trim() || "New channel";
    const channelId = String(addChannelDraft.channelId || "").trim();
    if (!channelId) {
      setStatusText("Channel ID is required.");
      return;
    }

    const updated = await createProjectChannelRequest(selectedProject.id, { title, channelId });
    if (!updated) {
      setStatusText("Failed to add channel to project.");
      return;
    }

    replaceProjectInState(updated);
    setStatusText("Channel added.");
    closeAddChannelModal();
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

  async function saveProjectMembers(actors, teams) {
    if (!selectedProject) {
      return;
    }

    const updated = await updateProjectRequest(selectedProject.id, { actors, teams });
    if (!updated) {
      setStatusText("Failed to save project members.");
      return;
    }

    replaceProjectInState(updated);
    setStatusText("Project members saved.");
  }

  function renderProjectTab(project) {
    if (selectedTab === "overview") {
      const relatedWorkers = workersForProject(project, workers);
      const activeWorkers = activeWorkersForProject(project, workers);
      const taskCounts = buildTaskCounts(project.tasks);
      const createdItems = extractCreatedItems(project, chatSnapshots);

      return (
        <ProjectOverviewTab
          project={project}
          taskCounts={taskCounts}
          activeWorkers={activeWorkers}
          relatedWorkers={relatedWorkers}
          createdItems={createdItems}
        />
      );
    }

    if (selectedTab === "tasks") {
      return (
        <ProjectTasksTab
          project={project}
          selectedTask={selectedTask}
          editDraft={editDraft}
          isTaskDetailFullscreen={isTaskDetailFullscreen}
          updateEditDraft={updateEditDraft}
          saveTaskEdit={saveTaskEdit}
          setIsTaskDetailFullscreen={setIsTaskDetailFullscreen}
          closeTaskDetails={closeTaskDetails}
          updateDetailAssignee={updateDetailAssignee}
          deleteTaskFromModal={deleteTaskFromModal}
          openTaskDetails={openTaskDetails}
          openCreateTaskModal={openCreateTaskModal}
          moveTask={moveTask}
          createModalActors={createModalActors}
          createModalTeams={createModalTeams}
        />
      );
    }

    if (selectedTab === "workers") {
      return <ProjectWorkersTab project={project} workers={workers} />;
    }

    if (selectedTab === "memories") {
      return <ProjectMemoriesTab project={project} chatSnapshots={chatSnapshots} />;
    }

    if (selectedTab === "visor") {
      return <ProjectVisorTab project={project} chatSnapshots={chatSnapshots} bulletins={bulletins} />;
    }

    return (
      <ProjectSettingsTab
        project={project}
        onUpdateProject={async (payload) => {
          const updated = await updateProjectRequest(project.id, payload);
          if (!updated) {
            return null;
          }
          replaceProjectInState(updated);
          return updated;
        }}
        deleteProject={deleteProject}
        openAddChannelModal={openAddChannelModal}
        removeProjectChannel={removeProjectChannel}
      />
    );
  }

  function renderProjectDetails(project) {
    return (
      <section className="project-workspace">
        <section className="agent-tabs" aria-label="Project sections">
          {PROJECT_TABS.map((tab) => (
            <button
              key={tab.id}
              type="button"
              className={`agent-tab ${selectedTab === tab.id ? "active" : ""}`}
              onClick={() => openProject(project.id, tab.id)}
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
        <Breadcrumbs
          items={[
            { id: 'projects', label: 'Projects', onClick: closeProject },
            ...(selectedProject ? [{ id: selectedProject.id, label: selectedProject.name }] : [])
          ]}
          style={{ marginBottom: '20px' }}
          action={
            <button type="button" className="agents-create-inline hover-levitate" onClick={openCreateProjectModal}>
              New Project
            </button>
          }
        />
      )}

      {selectedProject ? renderProjectDetails(selectedProject) : <ProjectList
        projects={projects}
        isLoadingProjects={isLoadingProjects}
        openProject={openProject}
        openCreateProjectModal={openCreateProjectModal}
        workers={workers}
      />}

      {statusText && statusText !== "No projects yet." && statusText !== "Loading projects..." && (
        <p className="app-status-text">{statusText}</p>
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
        actors={createModalActors}
        teams={createModalTeams}
      />

      <AddChannelModal
        isOpen={isAddChannelModalOpen}
        projectChannels={selectedProject?.chats || []}
        availableChannels={availableChannels}
        draft={addChannelDraft}
        onChange={updateAddChannelDraft}
        onClose={closeAddChannelModal}
        onAdd={submitAddChannel}
      />
    </main>
  );
}

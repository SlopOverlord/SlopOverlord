import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  fetchActorsBoard,
  fetchChannelState,
  fetchChannelSessions,
  fetchProjects as fetchProjectsRequest,
  createProject as createProjectRequest,
  updateProject as updateProjectRequest,
  deleteProject as deleteProjectRequest,
  linkProjectChannel as linkProjectChannelRequest,
  deleteProjectChannel as deleteProjectChannelRequest,
  createProjectTask as createProjectTaskRequest,
  updateProjectTask as updateProjectTaskRequest,
  deleteProjectTask as deleteProjectTaskRequest,
  fetchAgentSessions
} from "../api";
import { useKanbanSocket } from "./Projects/useKanbanSocket";
import { Breadcrumbs } from "../components/Breadcrumbs/Breadcrumbs";

import {
  ACTIVE_WORKER_STATUSES,
  PROJECT_TABS,
  TASK_STATUSES,
  TASK_PRIORITIES,
  TASK_PRIORITY_LABELS,
  TASK_STATUS_COLORS,
  TASK_PRIORITY_ICONS,
  TASK_KINDS,
  LOOP_MODES,
  PROJECT_TAB_SET,
  TASK_STATUS_SET,
  TASK_PRIORITY_SET,
  createId,
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
  displayNameToProjectId,
  parseListInput,
  buildProjectChannels,
  emptyProjectDraft,
  parseAgentWorkerChannelId
} from "./Projects/utils";
import { ProjectOverviewTab } from "./Projects/ProjectOverviewTab";
import { ProjectTasksTab } from "./Projects/ProjectTasksTab";
import { ProjectWorkersTab } from "./Projects/ProjectWorkersTab";
import { ProjectVisorTab } from "./Projects/ProjectVisorTab";
import { ProjectChatTab } from "./Projects/ProjectChatTab";
import { ProjectSettingsTab } from "./Projects/ProjectSettingsTab";
import { ProjectFilesTab } from "./Projects/ProjectFilesTab";
import { ProjectMemoryTab } from "./Projects/ProjectMemoryTab";
import { ProjectAnalyticsTab } from "./Projects/ProjectAnalyticsTab";
import { ProjectList } from "./Projects/ProjectList";
import { TaskReviewView } from "./Projects/TaskReviewView";

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

  const canCreateProject =
    draft.sourceType === "open"
      ? draft.displayName.trim() && draft.repoPath.trim()
      : draft.displayName.trim();

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
          <div className="onboarding-provider-grid">
            <button
              type="button"
              className={`onboarding-provider-card ${draft.sourceType === "empty" ? "active" : ""}`}
              onClick={() => onChange("sourceType", "empty")}
            >
              <span className="material-symbols-rounded" aria-hidden="true">folder_open</span>
              <strong>Empty project</strong>
              <span>Start with a blank workspace directory.</span>
            </button>
            <button
              type="button"
              className={`onboarding-provider-card ${draft.sourceType === "git" ? "active" : ""}`}
              onClick={() => onChange("sourceType", "git")}
            >
              <span className="material-symbols-rounded" aria-hidden="true">source</span>
              <strong>Clone from GitHub</strong>
              <span>Clone a git repository including submodules.</span>
            </button>
            <button
              type="button"
              className={`onboarding-provider-card ${draft.sourceType === "open" ? "active" : ""}`}
              onClick={() => onChange("sourceType", "open")}
            >
              <span className="material-symbols-rounded" aria-hidden="true">drive_folder_upload</span>
              <strong>Open Project</strong>
              <span>Attach an existing local directory and keep working in place.</span>
            </button>
          </div>

          {draft.sourceType === "git" ? (
            <label>
              GitHub repo URL
              <input
                value={draft.repoUrl}
                onChange={(event) => onChange("repoUrl", event.target.value)}
                placeholder="https://github.com/org/repo"
                autoFocus
              />
            </label>
          ) : null}

          {draft.sourceType === "open" ? (
            <label>
              Local project path
              <input
                value={draft.repoPath}
                onChange={(event) => onChange("repoPath", event.target.value)}
                placeholder="/Users/name/work/project or file:///Users/name/work/project"
                autoFocus
              />
              <span className="project-path-hint">
                Any local folder is allowed. Git features become available automatically when this directory is a repository.
              </span>
            </label>
          ) : null}

          <label>
            Display Name
            <input
              value={draft.displayName}
              onChange={(event) => onChange("displayName", event.target.value)}
              placeholder="Project Alpha"
              autoFocus={draft.sourceType === "empty"}
            />
            {draft.displayName.trim() ? (
              <span className="project-id-preview">
                ID: {displayNameToProjectId(draft.displayName) || "—"}
              </span>
            ) : null}
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
            <button type="submit" className="project-primary hover-levitate" disabled={!canCreateProject}>
              Create Project
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

function TaskCreateDropdown({ label, icon, color, isOpen, onToggle, children }) {
  const ref = useRef(null);

  useEffect(() => {
    if (!isOpen) return;
    function handleClickOutside(e) {
      if (ref.current && !ref.current.contains(e.target)) {
        onToggle(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [isOpen, onToggle]);

  return (
    <div className="tcm-dropdown-wrap" ref={ref}>
      <button
        type="button"
        className={`tcm-selector-btn ${isOpen ? "active" : ""}`}
        onClick={() => onToggle(!isOpen)}
      >
        {color ? (
          <span className="tcm-status-dot" style={{ background: color }} />
        ) : icon ? (
          <span className="material-symbols-rounded tcm-selector-icon">{icon}</span>
        ) : null}
        <span>{label}</span>
      </button>
      {isOpen && (
        <ul className="tcm-dropdown-list">
          {children}
        </ul>
      )}
    </div>
  );
}

function ProjectTaskCreateModal({ isOpen, draft, onChange, onClose, onCreate, actors = [], teams = [], creating = false }) {
  const [openDropdown, setOpenDropdown] = useState(null);

  if (!isOpen) {
    return null;
  }

  function toggle(name) {
    return (open) => setOpenDropdown(open ? name : null);
  }

  const currentStatus = TASK_STATUSES.find((s) => s.id === draft.status) || TASK_STATUSES[0];
  const currentPriorityLabel = TASK_PRIORITY_LABELS[draft.priority] || "Priority";
  const currentActor = actors.find((a) => a.id === draft.actorId);
  const currentTeam = teams.find((t) => t.id === draft.teamId);

  const assigneeLabel = currentActor
    ? currentActor.displayName
    : currentTeam
      ? currentTeam.name
      : "Assignee";

  return (
    <div className="project-modal-overlay" onClick={onClose}>
      <section className="tcm-modal" onClick={(event) => event.stopPropagation()}>
        <form onSubmit={onCreate}>
          <div className="tcm-body">
            <input
              className="tcm-title-input"
              value={draft.title}
              onChange={(event) => onChange("title", event.target.value)}
              placeholder="Task title"
              autoFocus
            />
            <textarea
              className="tcm-desc-input"
              value={draft.description}
              onChange={(event) => onChange("description", event.target.value)}
              placeholder="Add description..."
              rows={6}
            />
          </div>

          <div className="tcm-toolbar">
            <div className="tcm-selectors">
              <TaskCreateDropdown
                label={currentStatus.title}
                color={TASK_STATUS_COLORS[currentStatus.id]}
                isOpen={openDropdown === "status"}
                onToggle={toggle("status")}
              >
                {TASK_STATUSES.map((status) => (
                  <li
                    key={status.id}
                    className={`tcm-dropdown-item ${draft.status === status.id ? "selected" : ""}`}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      onChange("status", status.id);
                      setOpenDropdown(null);
                    }}
                  >
                    <span className="tcm-status-dot" style={{ background: TASK_STATUS_COLORS[status.id] }} />
                    <span>{status.title}</span>
                    {draft.status === status.id && <span className="tcm-dropdown-check">✓</span>}
                  </li>
                ))}
              </TaskCreateDropdown>

              <TaskCreateDropdown
                label={currentPriorityLabel}
                icon={TASK_PRIORITY_ICONS[draft.priority] || "remove"}
                isOpen={openDropdown === "priority"}
                onToggle={toggle("priority")}
              >
                {TASK_PRIORITIES.map((priority) => (
                  <li
                    key={priority}
                    className={`tcm-dropdown-item ${draft.priority === priority ? "selected" : ""}`}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      onChange("priority", priority);
                      setOpenDropdown(null);
                    }}
                  >
                    <span className="material-symbols-rounded tcm-dropdown-item-icon">{TASK_PRIORITY_ICONS[priority]}</span>
                    <span>{TASK_PRIORITY_LABELS[priority]}</span>
                    {draft.priority === priority && <span className="tcm-dropdown-check">✓</span>}
                  </li>
                ))}
              </TaskCreateDropdown>

              <TaskCreateDropdown
                label={assigneeLabel}
                icon="person"
                isOpen={openDropdown === "assignee"}
                onToggle={toggle("assignee")}
              >
                <li
                  className={`tcm-dropdown-item ${!draft.actorId && !draft.teamId ? "selected" : ""}`}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    onChange("actorId", "");
                    onChange("teamId", "");
                    setOpenDropdown(null);
                  }}
                >
                  <span className="material-symbols-rounded tcm-dropdown-item-icon">person_off</span>
                  <span>Unassigned</span>
                  {!draft.actorId && !draft.teamId && <span className="tcm-dropdown-check">✓</span>}
                </li>
                {actors.length > 0 && <li className="tcm-dropdown-divider-label">Actors</li>}
                {actors.map((actor) => (
                  <li
                    key={actor.id}
                    className={`tcm-dropdown-item ${draft.actorId === actor.id ? "selected" : ""}`}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      onChange("actorId", actor.id);
                      onChange("teamId", "");
                      setOpenDropdown(null);
                    }}
                  >
                    <span className="material-symbols-rounded tcm-dropdown-item-icon">person</span>
                    <span>{actor.displayName}</span>
                    <span className="tcm-dropdown-item-id">{actor.id}</span>
                    {draft.actorId === actor.id && <span className="tcm-dropdown-check">✓</span>}
                  </li>
                ))}
                {teams.length > 0 && <li className="tcm-dropdown-divider-label">Teams</li>}
                {teams.map((team) => (
                  <li
                    key={team.id}
                    className={`tcm-dropdown-item ${draft.teamId === team.id ? "selected" : ""}`}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      onChange("actorId", "");
                      onChange("teamId", team.id);
                      setOpenDropdown(null);
                    }}
                  >
                    <span className="material-symbols-rounded tcm-dropdown-item-icon">groups</span>
                    <span>{team.name}</span>
                    <span className="tcm-dropdown-item-id">{team.id}</span>
                    {draft.teamId === team.id && <span className="tcm-dropdown-check">✓</span>}
                  </li>
                ))}
              </TaskCreateDropdown>

              <TaskCreateDropdown
                label={TASK_KINDS.find((k) => k.id === draft.kind)?.title || "Kind"}
                icon="category"
                isOpen={openDropdown === "kind"}
                onToggle={toggle("kind")}
              >
                <li
                  className={`tcm-dropdown-item ${!draft.kind ? "selected" : ""}`}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    onChange("kind", "");
                    setOpenDropdown(null);
                  }}
                >
                  <span>None</span>
                  {!draft.kind && <span className="tcm-dropdown-check">✓</span>}
                </li>
                {TASK_KINDS.map((kind) => (
                  <li
                    key={kind.id}
                    className={`tcm-dropdown-item ${draft.kind === kind.id ? "selected" : ""}`}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      onChange("kind", kind.id);
                      setOpenDropdown(null);
                    }}
                  >
                    <span>{kind.title}</span>
                    {draft.kind === kind.id && <span className="tcm-dropdown-check">✓</span>}
                  </li>
                ))}
              </TaskCreateDropdown>

              <TaskCreateDropdown
                label={LOOP_MODES.find((m) => m.id === draft.loopModeOverride)?.title || "Loop mode"}
                icon="sync"
                isOpen={openDropdown === "loopMode"}
                onToggle={toggle("loopMode")}
              >
                <li
                  className={`tcm-dropdown-item ${!draft.loopModeOverride ? "selected" : ""}`}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    onChange("loopModeOverride", "");
                    setOpenDropdown(null);
                  }}
                >
                  <span>Project default</span>
                  {!draft.loopModeOverride && <span className="tcm-dropdown-check">✓</span>}
                </li>
                {LOOP_MODES.map((mode) => (
                  <li
                    key={mode.id}
                    className={`tcm-dropdown-item ${draft.loopModeOverride === mode.id ? "selected" : ""}`}
                    onMouseDown={(e) => {
                      e.preventDefault();
                      onChange("loopModeOverride", mode.id);
                      setOpenDropdown(null);
                    }}
                  >
                    <span>{mode.title}</span>
                    {draft.loopModeOverride === mode.id && <span className="tcm-dropdown-check">✓</span>}
                  </li>
                ))}
              </TaskCreateDropdown>
            </div>

            <div className="tcm-actions">
              <button type="button" className="tcm-discard-btn" onClick={onClose} disabled={creating}>
                Discard
              </button>
              <button type="submit" className="tcm-create-btn hover-levitate" disabled={!draft.title.trim() || creating}>
                {creating ? "Creating…" : "Create Task"}
              </button>
            </div>
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
                  value={draft.channelId}
                  onChange={(event) => {
                    const value = event.target.value;
                    onChange("channelId", value);
                    setChannelSearch(value);
                    setDropdownOpen(true);
                  }}
                  onFocus={() => setDropdownOpen(true)}
                  onBlur={() => setTimeout(() => setDropdownOpen(false), 150)}
                  placeholder="Search active sessions or paste channel ID..."
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
  onRouteProjectChange = () => { },
  onSidebarProjectsListChanged = () => { },
  onNavigateToChannelSession = (_sessionId) => { },
  onNavigateToAgentChatSession = null
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
  const [creatingTask, setCreatingTask] = useState(false);
  const [isAddChannelModalOpen, setIsAddChannelModalOpen] = useState(false);
  const [addChannelDraft, setAddChannelDraft] = useState({ title: "", channelId: "" });
  const [availableChannels, setAvailableChannels] = useState([]);
  const [isTaskDetailFullscreen, setIsTaskDetailFullscreen] = useState(false);
  const [showArchived, setShowArchived] = useState(false);

  useKanbanSocket(routeProjectId, (event) => {
    setProjects((prev) => {
      const projectIndex = prev.findIndex((p) => p.id === event.projectId);
      if (projectIndex === -1) {
        if (event.type === "project_updated" || event.type === "task_created") {
          // If project not found, we might need to re-fetch all projects
          // but for now, we only handle existing projects to avoid loops
          return prev;
        }
        return prev;
      }

      const next = [...prev];
      const project = { ...next[projectIndex] };
      const tasks = [...project.tasks];
      const normalizedEventTask = event.task ? normalizeTask(event.task) : null;

      switch (event.type) {
        case "task_created":
          if (normalizedEventTask && !tasks.some((t) => t.id === normalizedEventTask.id)) {
            tasks.push(normalizedEventTask);
          }
          break;
        case "task_updated":
          if (normalizedEventTask) {
            const taskIndex = tasks.findIndex((t) => t.id === normalizedEventTask.id);
            if (taskIndex !== -1) {
              tasks[taskIndex] = normalizedEventTask;
            } else {
              tasks.push(normalizedEventTask);
            }
          }
          break;
        case "task_deleted":
          if (event.taskId) {
            const taskIndex = tasks.findIndex((t) => t.id === event.taskId);
            if (taskIndex !== -1) {
              tasks.splice(taskIndex, 1);
            }
          }
          break;
        case "project_updated":
          // For project updates, we might need a full re-fetch or just update meta
          // Re-fetching specific project is safer
          loadProjects();
          return prev;
      }

      project.tasks = tasks;
      next[projectIndex] = project;
      return next;
    });
  });

  const activeProjects = useMemo(() => projects.filter((p) => !p.isArchived), [projects]);
  const archivedProjects = useMemo(() => projects.filter((p) => p.isArchived), [projects]);

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

  const reviewTask = useMemo(() => {
    if (!selectedProject || selectedTab !== "review" || !routeProjectTaskReference) {
      return null;
    }
    return resolveTaskByReference(selectedProject.id, selectedProject.tasks, routeProjectTaskReference);
  }, [selectedProject, selectedTab, routeProjectTaskReference]);

  useEffect(() => {
    loadProjects().catch(() => {
      setStatusText("Failed to load projects from Sloppy.");
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
          displayName: String(n?.displayName ?? n?.id ?? ""),
          linkedAgentId: n?.linkedAgentId || null
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
      kind: selectedTask.kind || "",
      loopModeOverride: selectedTask.loopModeOverride || "",
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
    selectedTask?.kind,
    selectedTask?.loopModeOverride,
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
      setStatusText("Failed to load projects from Sloppy.");
      setIsLoadingProjects(false);
      return;
    }

    const normalized = response.map((project, index) => normalizeProject(project, index));

    setProjects(normalized);
    setStatusText(normalized.length > 0 ? `Loaded ${normalized.length} projects from Sloppy` : "No projects yet.");
    setIsLoadingProjects(false);
    if (routeProjectId && !normalized.some((project) => project.id === routeProjectId)) {
      onRouteProjectChange(null, null);
    }
  }

  function replaceProjectInState(rawProject, syncSidebar = false) {
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
    if (syncSidebar) {
      onSidebarProjectsListChanged();
    }
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

  function openReview(task) {
    if (!selectedProject || !task) return;
    onRouteProjectChange(selectedProject.id, "review", String(task.id || "").trim());
  }

  function closeReview() {
    if (!selectedProject) return;
    onRouteProjectChange(selectedProject.id, "tasks", null);
  }

  async function watchAgentTaskSession(project, task, channelId) {
    const channel = String(channelId || "").trim();
    const parsed = channel ? parseAgentWorkerChannelId(channel) : null;
    let agentId = parsed?.agentId ? String(parsed.agentId).trim() : "";
    if (!agentId) {
      agentId = String(task.claimedAgentId || "").trim();
    }
    if (!agentId) {
      setStatusText("Cannot resolve agent for this task.");
      return;
    }
    let sessionId = parsed?.sessionId ? String(parsed.sessionId).trim() : "";
    if (!sessionId) {
      try {
        const sessions = await fetchAgentSessions(agentId);
        const workerTitle = `task-${task.id}`;
        const commentTitle = `task-comment:${project.id}:${task.id}`;
        const match = Array.isArray(sessions)
          ? sessions.find((s) => { const t = String(s.title || ""); return t === workerTitle || t === commentTitle; })
          : null;
        sessionId = match?.id ? String(match.id) : "";
      } catch {
        sessionId = "";
      }
    }
    if (!sessionId) {
      setStatusText("No agent task session found for this task yet.");
      return;
    }
    if (typeof onNavigateToAgentChatSession === "function") {
      onNavigateToAgentChatSession(agentId, sessionId);
    } else {
      setStatusText("Navigation to agent session is not available.");
    }
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

    if (projectDraft.sourceType === "open" && !String(projectDraft.repoPath || "").trim()) {
      return;
    }

    const nextIndex = projects.length + 1;
    const projectId =
      displayNameToProjectId(displayName) ||
      `project-${nextIndex}`;
    const actorIds = parseListInput(projectDraft.actors);
    const teamIds = parseListInput(projectDraft.teams);
    const actors = actorIds.map(
      (id) => createModalActors.find((a) => a.id === id)?.displayName ?? id
    );
    const teams = teamIds.map(
      (id) => createModalTeams.find((t) => t.id === id)?.name ?? id
    );

    const outcome = await createProjectRequest({
      id: projectId,
      name: displayName,
      description: String(projectDraft.description || "").trim(),
      channels: buildProjectChannels(projectId, actors, teams),
      actors,
      teams,
      ...(projectDraft.sourceType === "git" && String(projectDraft.repoUrl || "").trim()
        ? { repoUrl: String(projectDraft.repoUrl).trim() }
        : {}),
      ...(projectDraft.sourceType === "open" && String(projectDraft.repoPath || "").trim()
        ? { repoPath: String(projectDraft.repoPath).trim() }
        : {})
    });

    if (!outcome?.project) {
      setStatusText("Failed to create project in Sloppy.");
      return;
    }

    const created = outcome.project;
    replaceProjectInState(created, true);
    onRouteProjectChange(String(created.id || ""), "overview");
    closeCreateProjectModal();
    if (outcome.repoCloneSucceeded === false) {
      setStatusText(`Project ${displayName} was created, but the Git repository could not be copied into the workspace. Check the notification bell or server logs.`);
    } else {
      setStatusText(`Project ${displayName} created.`);
    }
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
      setStatusText("Failed to rename project in Sloppy.");
      return;
    }

    replaceProjectInState(updated, true);
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
      setStatusText("Failed to delete project in Sloppy.");
      return;
    }

    setProjects((previous) => previous.filter((candidate) => candidate.id !== projectId));
    onSidebarProjectsListChanged();
    if (routeProjectId === projectId) {
      onRouteProjectChange(null, null);
    }
    setStatusText(`Project ${project.name} deleted.`);
  }

  async function archiveProject(projectId, archive) {
    const updated = await updateProjectRequest(projectId, { isArchived: archive });
    if (!updated) {
      setStatusText(`Failed to ${archive ? "archive" : "unarchive"} project.`);
      return;
    }
    replaceProjectInState(updated, true);
    if (archive && routeProjectId === projectId) {
      onRouteProjectChange(null, null, null);
    }
    setStatusText(archive ? "Project archived." : "Project unarchived.");
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
      kind: task.kind || "",
      loopModeOverride: task.loopModeOverride || "",
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

  function revertTaskEdit() {
    const task = editingTask || selectedTask;
    if (!task) {
      return;
    }
    const resolvedActorId = task.claimedActorId || task.actorId || "";
    setEditDraft({
      title: task.title,
      description: task.description || "",
      priority: task.priority,
      status: task.status,
      kind: task.kind || "",
      loopModeOverride: task.loopModeOverride || "",
      actorId: resolvedActorId,
      teamId: task.teamId || ""
    });
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
      kind: String(editDraft.kind || "").trim() || null,
      loopModeOverride: String(editDraft.loopModeOverride || "").trim() || null,
      actorId: String(editDraft.actorId || "").trim() || null,
      teamId: String(editDraft.teamId || "").trim() || null,
      changedBy: "user"
    });
    if (!updated) {
      setStatusText("Failed to update task in Sloppy.");
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

    setCreatingTask(true);

    const updated = await createProjectTaskRequest(selectedProject.id, {
      title,
      description: String(taskDraft.description || "").trim(),
      priority: taskDraft.priority,
      status: taskDraft.status,
      kind: String(taskDraft.kind || "").trim() || null,
      loopModeOverride: String(taskDraft.loopModeOverride || "").trim() || null,
      actorId: String(taskDraft.actorId || "").trim() || null,
      teamId: String(taskDraft.teamId || "").trim() || null
    });

    setCreatingTask(false);

    if (!updated) {
      setStatusText("Failed to create task in Sloppy.");
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

    const currentTask = Array.isArray(selectedProject.tasks)
      ? selectedProject.tasks.find((task) => String(task?.id || "").trim() === String(taskId || "").trim())
      : null;
    const updated = await updateProjectTaskRequest(selectedProject.id, taskId, { status: nextStatus, changedBy: "user" });
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

    const [sessions, board] = await Promise.all([
      fetchChannelSessions({ status: "open" }).catch(() => null),
      fetchActorsBoard().catch(() => null)
    ]);
    const allProjectChannels = new Map();
    for (const project of projects) {
      if (project.id === selectedProject.id || project.isArchived) {
        continue;
      }
      const chats = Array.isArray(project.chats) ? project.chats : [];
      for (const chat of chats) {
        const channelId = String(chat?.channelId || "").trim();
        if (channelId) {
          allProjectChannels.set(channelId, project.name || project.id);
        }
      }
    }

    function isLinkedElsewhere(channelId) {
      for (const bindingId of allProjectChannels.keys()) {
        if (channelId === bindingId) {
          return true;
        }
      }
      return false;
    }

    const channels = [];
    if (Array.isArray(sessions)) {
      for (const session of sessions) {
        const channelId = String(session?.channelId || "").trim();
        if (!channelId || isLinkedElsewhere(channelId)) {
          continue;
        }
        const preview = String(session?.lastMessagePreview || "").trim();
        channels.push({
          channelId,
          displayName: preview ? `${channelId} · ${preview}` : channelId
        });
      }
    }
    if (board && Array.isArray(board.nodes)) {
      for (const node of board.nodes) {
        const channelId = String(node?.channelId || "").trim();
        if (channelId && !isLinkedElsewhere(channelId)) {
          channels.push({
            channelId,
            displayName: String(node.displayName || channelId)
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

    const result = await linkProjectChannelRequest(selectedProject.id, { title, channelId, ensureSession: true });
    if (!result || !result.project) {
      const owner = result?.ownerProjectName ? ` Already linked to ${result.ownerProjectName}.` : "";
      setStatusText(`Failed to add channel to project.${owner}`);
      return;
    }

    replaceProjectInState(result.project);
    setStatusText(result.status === "existing" ? "Channel already linked." : "Channel added.");
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
    if (selectedTab === "review") {
      return (
        <TaskReviewView
          project={project}
          task={reviewTask}
          onClose={closeReview}
          onProjectRefresh={loadProjects}
        />
      );
    }

    if (selectedTab === "overview") {
      const activeWorkers = activeWorkersForProject(project, workers);
      const taskCounts = buildTaskCounts(project.tasks);
      const createdItems = extractCreatedItems(project, chatSnapshots);

      return (
        <ProjectOverviewTab
          project={project}
          taskCounts={taskCounts}
          activeWorkers={activeWorkers}
          chatSnapshots={chatSnapshots}
          createdItems={createdItems}
          onOpenTab={(tabId) => openProject(project.id, tabId)}
          onOpenTask={openTaskDetails}
        />
      );
    }

    if (selectedTab === "chat") {
      return (
        <ProjectChatTab
          project={project}
          onNavigateToChannelSession={onNavigateToChannelSession}
          onAddChannel={openAddChannelModal}
        />
      );
    }

    if (selectedTab === "files") {
      return <ProjectFilesTab project={project} />;
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
          revertTaskEdit={revertTaskEdit}
          setIsTaskDetailFullscreen={setIsTaskDetailFullscreen}
          closeTaskDetails={closeTaskDetails}
          updateDetailAssignee={updateDetailAssignee}
          deleteTaskFromModal={deleteTaskFromModal}
          openTaskDetails={openTaskDetails}
          openCreateTaskModal={openCreateTaskModal}
          moveTask={moveTask}
          createModalActors={createModalActors}
          createModalTeams={createModalTeams}
          onOpenReview={openReview}
          workers={workers}
          onWatchAgentTaskSession={watchAgentTaskSession}
        />
      );
    }

    if (selectedTab === "analytics") {
      return (
        <ProjectAnalyticsTab
          project={project}
          onOpenTab={(tabId) => openProject(project.id, tabId)}
        />
      );
    }

    if (selectedTab === "workers") {
      return <ProjectWorkersTab project={project} workers={workers} />;
    }

    if (selectedTab === "visor") {
      return <ProjectVisorTab project={project} chatSnapshots={chatSnapshots} bulletins={bulletins} />;
    }

    if (selectedTab === "memory") {
      return <ProjectMemoryTab projectId={project.id} />;
    }

    return (
      <ProjectSettingsTab
        project={project}
        onUpdateProject={async (payload) => {
          const updated = await updateProjectRequest(project.id, payload);
          if (!updated) {
            return null;
          }
          replaceProjectInState(updated, true);
          return updated;
        }}
        onReplaceProject={(updated) => replaceProjectInState(updated, true)}
        deleteProject={deleteProject}
        onArchiveProject={archiveProject}
        openAddChannelModal={openAddChannelModal}
        removeProjectChannel={removeProjectChannel}
        availableActors={createModalActors}
        availableTeams={createModalTeams}
      />
    );
  }

  function renderProjectDetails(project) {
    const isReviewMode = selectedTab === "review";
    return (
      <section className="project-workspace" data-testid={`project-workspace-${project.id}`}>
        {!isReviewMode && (
          <section className="agent-tabs" aria-label="Project sections">
            {PROJECT_TABS.filter((tab) => tab.id !== "review").map((tab) => (
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
        )}

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
        projects={showArchived ? archivedProjects : activeProjects}
        isLoadingProjects={isLoadingProjects}
        openProject={openProject}
        openCreateProjectModal={openCreateProjectModal}
        workers={workers}
        showArchived={showArchived}
        archivedCount={archivedProjects.length}
        onToggleArchived={() => setShowArchived((v) => !v)}
        onUnarchiveProject={(projectId) => archiveProject(projectId, false)}
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
        creating={creatingTask}
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

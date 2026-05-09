import React, { useState, useMemo, useEffect, useRef } from "react";
import {
    fetchProjectTaskSync,
    linkProjectTaskSync,
    unlinkProjectTaskSync,
    syncProjectTasksNow,
    fetchProjectTaskSyncToken,
    setProjectTaskSyncToken,
    clearProjectTaskSyncToken
} from "../../api";

const SETTINGS_TABS = [
    { id: "general", title: "General", icon: "settings" },
    { id: "actors", title: "Actors", icon: "group" },
    { id: "loop", title: "Task Loop Mode", icon: "sync" },
    { id: "review", title: "Git Worktree & Review", icon: "rate_review" },
    { id: "task_sync", title: "Task Sync", icon: "sync_alt" }
];

const APPROVAL_MODES = [
    {
        id: "human",
        label: "Human Approve",
        icon: "person_check",
        description: "Notify the dashboard and task creator. Requires manual approval."
    },
    {
        id: "auto",
        label: "Auto Approve",
        icon: "check_circle",
        description: "Automatically merge and mark as done when the task reaches review."
    },
    {
        id: "agent",
        label: "Agent Approve",
        icon: "smart_toy",
        description: "Delegate review to the actor with the Reviewer system role in the team."
    }
];

const AUTONOMOUS_MODES = [
    {
        id: "off",
        label: "Off",
        icon: "block",
        description: "Manual task management only."
    },
    {
        id: "sequential",
        label: "Sequential",
        icon: "view_agenda",
        description: "Pick and execute one task from backlog at a time."
    },
    {
        id: "parallel",
        label: "Parallel",
        icon: "view_quilt",
        description: "Pick and execute multiple backlog tasks in parallel."
    }
];

const PROJECT_ICONS = [
    "folder", "rocket_launch", "code", "terminal", "science",
    "deployed_code", "bug_report", "psychology", "smart_toy", "extension",
    "database", "cloud", "language", "brush", "analytics",
    "school", "build", "architecture", "api", "hub",
    "storage", "monitoring", "security", "memory", "web"
];

const LOOP_MODE_OPTIONS = [
    {
        id: "human",
        label: "Human in the Loop",
        icon: "person",
        description: "When an agent needs input, the question is routed to the dashboard or source channel for a human to answer."
    },
    {
        id: "agent",
        label: "Agent in the Loop",
        icon: "smart_toy",
        description: "When an agent needs input, the question is routed to the project manager actor or the assigned team for autonomous resolution."
    }
];

function cloneDraft(project) {
    return {
        name: project?.name ?? "",
        icon: project?.icon ?? "",
        models: Array.isArray(project?.models) ? [...project.models] : [],
        agentFiles: Array.isArray(project?.agentFiles) ? [...project.agentFiles] : [],
        heartbeat: {
            enabled: Boolean(project?.heartbeat?.enabled),
            intervalMinutes: Number.isFinite(Number(project?.heartbeat?.intervalMinutes))
                ? Number(project.heartbeat.intervalMinutes)
                : 5
        },
        repoPath: project?.repoPath ?? "",
        reviewSettings: {
            enabled: Boolean(project?.reviewSettings?.enabled),
            approvalMode: project?.reviewSettings?.approvalMode ?? "human",
            autonomousMode: project?.reviewSettings?.autonomousMode ?? "off"
        },
        taskLoopMode: project?.taskLoopMode ?? "human",
        actors: Array.isArray(project?.actors) ? [...project.actors] : [],
        teams: Array.isArray(project?.teams) ? [...project.teams] : []
    };
}

function cloneTaskSyncDraft(project) {
    const settings = project?.taskSyncSettings || {};
    return {
        enabled: Boolean(settings.enabled),
        providerId: settings.providerId || "github",
        projectURL: settings.projectURL || "",
        projectNodeId: settings.projectNodeId || "",
        defaultRepo: settings.defaultRepo || "",
        tokenMode: settings.tokenMode || "inherit",
        statusMappingsText: Object.entries(settings.statusMappings || {})
            .map(([key, value]) => `${key}=${value}`)
            .join("\n"),
        health: settings.health || {},
        webhook: settings.webhook || {}
    };
}

export function ProjectSettingsTab({
    project,
    onUpdateProject,
    deleteProject,
    onArchiveProject,
    onReplaceProject,
    openAddChannelModal,
    removeProjectChannel,
    availableActors = [],
    availableTeams = []
}) {
    const [selectedSettings, setSelectedSettings] = useState("general");
    const [draft, setDraft] = useState(() => cloneDraft(project));
    const [statusText, setStatusText] = useState("");
    const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false);
    const [deleteConfirmText, setDeleteConfirmText] = useState("");
    const [actorSearch, setActorSearch] = useState("");
    const [actorDropdownOpen, setActorDropdownOpen] = useState(false);
    const actorSearchRef = useRef(null);
    const [teamSearch, setTeamSearch] = useState("");
    const [teamDropdownOpen, setTeamDropdownOpen] = useState(false);
    const teamSearchRef = useRef(null);
    const [taskSyncDraft, setTaskSyncDraft] = useState(() => cloneTaskSyncDraft(project));
    const [taskSyncToken, setTaskSyncToken] = useState("");
    const [taskSyncTokenStatus, setTaskSyncTokenStatus] = useState(null);
    const [taskSyncBusy, setTaskSyncBusy] = useState(false);

    useEffect(() => {
        setDraft(cloneDraft(project));
        setTaskSyncDraft(cloneTaskSyncDraft(project));
    }, [project?.id, project?.updatedAt]);

    useEffect(() => {
        let cancelled = false;
        async function loadTaskSync() {
            const [settings, tokenStatus] = await Promise.all([
                fetchProjectTaskSync(project.id),
                fetchProjectTaskSyncToken(project.id, "github")
            ]);
            if (cancelled) return;
            if (settings) setTaskSyncDraft((prev) => ({ ...prev, ...cloneTaskSyncDraft({ taskSyncSettings: settings }) }));
            if (tokenStatus) setTaskSyncTokenStatus(tokenStatus);
        }
        loadTaskSync();
        return () => { cancelled = true; };
    }, [project.id, project.updatedAt]);

    const hasChanges = useMemo(() => {
        const saved = cloneDraft(project);
        return JSON.stringify(draft) !== JSON.stringify(saved);
    }, [draft, project]);

    function mutateDraft(mutator) {
        setDraft((prev) => {
            const next = JSON.parse(JSON.stringify(prev));
            mutator(next);
            return next;
        });
    }

    function mutateTaskSync(mutator) {
        setTaskSyncDraft((prev) => {
            const next = JSON.parse(JSON.stringify(prev));
            mutator(next);
            return next;
        });
    }

    function parseStatusMappings(text) {
        return String(text || "")
            .split("\n")
            .map((line) => line.trim())
            .filter(Boolean)
            .reduce((acc, line) => {
                const idx = line.indexOf("=");
                if (idx <= 0) return acc;
                const key = line.slice(0, idx).trim();
                const value = line.slice(idx + 1).trim();
                if (key && value) acc[key] = value;
                return acc;
            }, {});
    }

    async function saveSettings() {
        const result = await onUpdateProject({
            name: draft.name.trim() || undefined,
            icon: draft.icon.trim() || null,
            models: draft.models,
            agentFiles: draft.agentFiles,
            heartbeat: draft.heartbeat,
            repoPath: draft.repoPath.trim() || null,
            reviewSettings: draft.reviewSettings,
            taskLoopMode: draft.taskLoopMode,
            actors: draft.actors,
            teams: draft.teams
        });
        if (result) {
            setStatusText("Settings saved");
        } else {
            setStatusText("Failed to save settings");
        }
    }

    function cancelChanges() {
        setDraft(cloneDraft(project));
        setStatusText("Changes cancelled");
    }

    function renderGeneral() {
        const workspacePath = draft.repoPath.trim();
        return (
            <>
                <section className="entry-editor-card">
                    <h3>Project Identity</h3>
                    <div className="entry-form-grid">
                        <label style={{ gridColumn: "1 / -1" }}>
                            Project Name
                            <input
                                type="text"
                                value={draft.name}
                                onChange={(e) => mutateDraft((d) => { d.name = e.target.value; })}
                                placeholder="My Project"
                            />
                        </label>
                    </div>

                    <div style={{ marginTop: 16 }}>
                        <p className="settings-general-label">Project Icon</p>
                        <div className="settings-icon-grid">
                            {PROJECT_ICONS.map((iconName) => {
                                const active = draft.icon === iconName;
                                return (
                                    <button
                                        key={iconName}
                                        type="button"
                                        className={`settings-icon-option ${active ? "active" : ""}`}
                                        onClick={() => mutateDraft((d) => { d.icon = active ? "" : iconName; })}
                                        title={iconName}
                                    >
                                        <span className="material-symbols-rounded">{iconName}</span>
                                    </button>
                                );
                            })}
                        </div>
                        {draft.icon && (
                            <div className="settings-icon-preview">
                                <span className="material-symbols-rounded" style={{ fontSize: "2rem" }}>{draft.icon}</span>
                                <span>{draft.icon}</span>
                            </div>
                        )}
                    </div>
                </section>

                <section className="entry-editor-card">
                    <h3>Workspace Path</h3>
                    <div className="entry-form-grid">
                        <label style={{ gridColumn: "1 / -1" }}>
                            Project workspace / repository path
                            <input
                                type="text"
                                placeholder="e.g. /Users/me/Developer/my-project"
                                value={draft.repoPath}
                                onChange={(e) => mutateDraft((d) => { d.repoPath = e.target.value; })}
                            />
                            <span className="entry-form-hint">
                                {workspacePath
                                    ? <>Agents, file tools, and review worktrees will use <code>{workspacePath}</code>.</>
                                    : "Set the absolute path to the project workspace so agents use the correct directory."}
                            </span>
                        </label>
                    </div>
                </section>

                <section className="entry-editor-card">
                    <h3>Archive</h3>
                    <div className="settings-danger-block">
                        <div className="settings-danger-info">
                            {project.isArchived ? (
                                <>
                                    <strong>Unarchive this project</strong>
                                    <p>Restore this project to the active projects list.</p>
                                </>
                            ) : (
                                <>
                                    <strong>Archive this project</strong>
                                    <p>Hide this project from the main list. You can restore it at any time from the Archived view.</p>
                                </>
                            )}
                        </div>
                        <button
                            type="button"
                            className="hover-levitate"
                            onClick={() => onArchiveProject(project.id, !project.isArchived)}
                        >
                            <span className="material-symbols-rounded" style={{ fontSize: "1rem", verticalAlign: "middle", marginRight: 4 }}>
                                {project.isArchived ? "unarchive" : "archive"}
                            </span>
                            {project.isArchived ? "Unarchive Project" : "Archive Project"}
                        </button>
                    </div>
                </section>

                <section className="entry-editor-card settings-danger-zone">
                    <h3 style={{ color: "var(--danger, #ef4444)" }}>Danger Zone</h3>
                    <div className="settings-danger-block">
                        <div className="settings-danger-info">
                            <strong>Delete this project</strong>
                            <p>
                                Once you delete a project, there is no going back. All tasks will be cancelled and all project data will be permanently removed.
                            </p>
                        </div>
                        {!deleteConfirmOpen ? (
                            <button
                                type="button"
                                className="danger hover-levitate"
                                onClick={() => {
                                    setDeleteConfirmOpen(true);
                                    setDeleteConfirmText("");
                                }}
                            >
                                Delete Project
                            </button>
                        ) : (
                            <div className="settings-danger-confirm">
                                <p className="settings-danger-warning">
                                    <span className="material-symbols-rounded" style={{ fontSize: "1rem", verticalAlign: "middle" }}>warning</span>
                                    {" "}This action is irreversible. All jobs for this project will be cancelled.
                                </p>
                                <label>
                                    Type <strong>{project.name}</strong> to confirm
                                    <input
                                        type="text"
                                        value={deleteConfirmText}
                                        onChange={(e) => setDeleteConfirmText(e.target.value)}
                                        placeholder={project.name}
                                        autoFocus
                                    />
                                </label>
                                <div className="settings-danger-confirm-actions">
                                    <button
                                        type="button"
                                        onClick={() => {
                                            setDeleteConfirmOpen(false);
                                            setDeleteConfirmText("");
                                        }}
                                    >
                                        Cancel
                                    </button>
                                    <button
                                        type="button"
                                        className="danger hover-levitate"
                                        disabled={deleteConfirmText.trim() !== project.name}
                                        onClick={() => deleteProject(project.id)}
                                    >
                                        I understand, delete this project
                                    </button>
                                </div>
                            </div>
                        )}
                    </div>
                </section>
            </>
        );
    }

    function renderActors() {
        const projectActors = draft.actors;
        const projectTeams = draft.teams;
        const actorNameById = new Map(availableActors.map((n) => [String(n?.id || ""), String(n?.displayName || "").trim()]));
        const teamNameById = new Map(availableTeams.map((t) => [String(t?.id || ""), String(t?.name || "").trim()]));

        const actorQ = actorSearch.trim().toLowerCase();
        const filteredActors = availableActors.filter(
            (node) =>
                node.displayName.toLowerCase().includes(actorQ) || node.id.toLowerCase().includes(actorQ)
        );
        const actorsToShow = actorQ && filteredActors.length > 0 ? filteredActors : availableActors;

        const teamQ = teamSearch.trim().toLowerCase();
        const filteredTeams = availableTeams.filter(
            (team) =>
                team.name.toLowerCase().includes(teamQ) || team.id.toLowerCase().includes(teamQ)
        );
        const teamsToShow = teamQ && filteredTeams.length > 0 ? filteredTeams : availableTeams;

        function addActor(node) {
            mutateDraft((d) => {
                const actorId = String(node?.id || "").trim();
                if (!actorId) return;
                if (!d.actors.includes(actorId)) {
                    d.actors.push(actorId);
                }
            });
            setActorSearch("");
        }

        function removeActor(actorId) {
            mutateDraft((d) => {
                d.actors = d.actors.filter((a) => a !== actorId);
            });
        }

        function addTeam(team) {
            mutateDraft((d) => {
                const teamId = String(team?.id || "").trim();
                if (!teamId) return;
                if (!d.teams.includes(teamId)) {
                    d.teams.push(teamId);
                }
            });
            setTeamSearch("");
        }

        function removeTeam(teamId) {
            mutateDraft((d) => {
                d.teams = d.teams.filter((t) => t !== teamId);
            });
        }

        return (
            <section className="entry-editor-card">
                <h3>Actors</h3>
                <p style={{ margin: "0 0 12px", fontSize: "0.85rem", color: "var(--muted)" }}>
                    Choose which actors can interact with this project. Actors will be able to receive tasks and work within this project scope.
                </p>

                <div className="actor-team-members-picker">
                    <div className="actor-team-search-wrap">
                        <input
                            ref={actorSearchRef}
                            className="actor-team-search"
                            value={actorSearch}
                            onChange={(e) => {
                                setActorSearch(e.target.value);
                                setActorDropdownOpen(true);
                            }}
                            onFocus={() => setActorDropdownOpen(true)}
                            onBlur={() => setTimeout(() => setActorDropdownOpen(false), 150)}
                            placeholder="Search actors…"
                            autoComplete="off"
                        />
                        {actorDropdownOpen && (
                            <ul className="actor-team-dropdown">
                                {actorsToShow.length === 0 ? (
                                    <li className="actor-team-dropdown-empty">No actors available</li>
                                ) : (
                                    actorsToShow.map((node) => {
                                        const isSelected = projectActors.includes(node.id);
                                        return (
                                            <li
                                                key={node.id}
                                                className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                                                onMouseDown={(e) => {
                                                    e.preventDefault();
                                                    if (isSelected) {
                                                        removeActor(node.id);
                                                    } else {
                                                        addActor(node);
                                                    }
                                                }}
                                            >
                                                <span className="actor-team-dropdown-name">{node.displayName}</span>
                                                <span className="actor-team-dropdown-id">{node.id}</span>
                                                {isSelected && (
                                                    <span className="actor-team-dropdown-check">✓</span>
                                                )}
                                            </li>
                                        );
                                    })
                                )}
                            </ul>
                        )}
                    </div>
                </div>

                {projectActors.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {projectActors.map((actorId) => (
                            <article key={actorId} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                                    <span className="material-symbols-rounded" style={{ fontSize: "1.1rem", color: "var(--accent)" }}>person</span>
                                    <strong>{actorNameById.get(actorId) || actorId}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => removeActor(actorId)}
                                >
                                    <span className="material-symbols-rounded">close</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}

                {projectActors.length === 0 && (
                    <p className="placeholder-text" style={{ marginTop: 12 }}>No actors assigned to this project.</p>
                )}

                <h3 style={{ marginTop: 24 }}>Teams</h3>
                <p style={{ margin: "0 0 12px", fontSize: "0.85rem", color: "var(--muted)" }}>
                    Assign entire teams to this project. All members of the team will be able to work within this project scope.
                </p>

                <div className="actor-team-members-picker">
                    <div className="actor-team-search-wrap">
                        <input
                            ref={teamSearchRef}
                            className="actor-team-search"
                            value={teamSearch}
                            onChange={(e) => {
                                setTeamSearch(e.target.value);
                                setTeamDropdownOpen(true);
                            }}
                            onFocus={() => setTeamDropdownOpen(true)}
                            onBlur={() => setTimeout(() => setTeamDropdownOpen(false), 150)}
                            placeholder="Search teams…"
                            autoComplete="off"
                        />
                        {teamDropdownOpen && (
                            <ul className="actor-team-dropdown">
                                {teamsToShow.length === 0 ? (
                                    <li className="actor-team-dropdown-empty">No teams available</li>
                                ) : (
                                    teamsToShow.map((team) => {
                                        const isSelected = projectTeams.includes(team.id);
                                        return (
                                            <li
                                                key={team.id}
                                                className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                                                onMouseDown={(e) => {
                                                    e.preventDefault();
                                                    if (isSelected) {
                                                        removeTeam(team.id);
                                                    } else {
                                                        addTeam(team);
                                                    }
                                                }}
                                            >
                                                <span className="actor-team-dropdown-name">{team.name}</span>
                                                <span className="actor-team-dropdown-id">{team.id}</span>
                                                {isSelected && (
                                                    <span className="actor-team-dropdown-check">✓</span>
                                                )}
                                            </li>
                                        );
                                    })
                                )}
                            </ul>
                        )}
                    </div>
                </div>

                {projectTeams.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {projectTeams.map((teamId) => (
                            <article key={teamId} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                                    <span className="material-symbols-rounded" style={{ fontSize: "1.1rem", color: "var(--accent)" }}>groups</span>
                                    <strong>{teamNameById.get(teamId) || teamId}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => removeTeam(teamId)}
                                >
                                    <span className="material-symbols-rounded">close</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}

                {projectTeams.length === 0 && (
                    <p className="placeholder-text" style={{ marginTop: 12 }}>No teams assigned to this project.</p>
                )}
            </section>
        );
    }

    function renderModels() {
        return (
            <section className="entry-editor-card">
                <h3>Models</h3>
                <div className="entry-form-grid">
                    <label style={{ gridColumn: "1 / -1" }}>
                        Model identifiers
                        <textarea
                            rows={5}
                            placeholder={"gpt-5.4-mini\nopenai:gpt-5.4\nollama:qwen3"}
                            value={draft.models.join("\n")}
                            onChange={(e) => {
                                mutateDraft((d) => {
                                    d.models = e.target.value
                                        .split("\n")
                                        .map((s) => s.trim())
                                        .filter(Boolean);
                                });
                            }}
                        />
                        <span className="entry-form-hint">
                            One model per line. These models will be available for agents in this project.
                        </span>
                    </label>
                </div>

                {draft.models.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {draft.models.map((model, idx) => (
                            <article key={idx} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div>
                                    <strong>{model}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => {
                                        mutateDraft((d) => {
                                            d.models.splice(idx, 1);
                                        });
                                    }}
                                >
                                    <span className="material-symbols-rounded">delete</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}
            </section>
        );
    }

    function renderAgentFiles() {
        return (
            <section className="entry-editor-card">
                <h3>Agent Files</h3>
                <div className="entry-form-grid">
                    <label style={{ gridColumn: "1 / -1" }}>
                        File paths
                        <textarea
                            rows={5}
                            placeholder={"docs/spec.md\nREADME.md\nsrc/prompts/system.txt"}
                            value={draft.agentFiles.join("\n")}
                            onChange={(e) => {
                                mutateDraft((d) => {
                                    d.agentFiles = e.target.value
                                        .split("\n")
                                        .map((s) => s.trim())
                                        .filter(Boolean);
                                });
                            }}
                        />
                        <span className="entry-form-hint">
                            One file path per line. These files will be included as context for agents working on this project.
                        </span>
                    </label>
                </div>

                {draft.agentFiles.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {draft.agentFiles.map((file, idx) => (
                            <article key={idx} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div>
                                    <strong>{file}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => {
                                        mutateDraft((d) => {
                                            d.agentFiles.splice(idx, 1);
                                        });
                                    }}
                                >
                                    <span className="material-symbols-rounded">delete</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}
            </section>
        );
    }

    function renderChannels() {
        return (
            <section className="entry-editor-card">
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <h3>Channels</h3>
                    <button type="button" className="hover-levitate" onClick={openAddChannelModal}>
                        Add Channel
                    </button>
                </div>

                {project.chats.length > 0 ? (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {project.chats.map((chat) => (
                            <article key={chat.id} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div>
                                    <strong>{chat.title}</strong>
                                    <p style={{ margin: 0, fontSize: "0.85rem", color: "var(--muted)" }}>{chat.channelId}</p>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    disabled={project.chats.length <= 1}
                                    onClick={() => removeProjectChannel(chat.id)}
                                >
                                    <span className="material-symbols-rounded">delete</span>
                                </button>
                            </article>
                        ))}
                    </div>
                ) : (
                    <p className="placeholder-text" style={{ marginTop: 12 }}>No channels configured.</p>
                )}
            </section>
        );
    }

    function renderHeartbeat() {
        return (
            <section className="entry-editor-card">
                <h3>Heartbeat</h3>
                <div className="entry-form-grid">
                    <label>
                        Enable Heartbeat
                        <select
                            value={draft.heartbeat.enabled ? "enabled" : "disabled"}
                            onChange={(e) =>
                                mutateDraft((d) => {
                                    d.heartbeat.enabled = e.target.value === "enabled";
                                })
                            }
                        >
                            <option value="disabled">Disabled</option>
                            <option value="enabled">Enabled</option>
                        </select>
                    </label>
                    <label>
                        Interval (minutes)
                        <input
                            type="number"
                            min={1}
                            disabled={!draft.heartbeat.enabled}
                            value={draft.heartbeat.intervalMinutes}
                            onChange={(e) =>
                                mutateDraft((d) => {
                                    const val = parseInt(e.target.value, 10);
                                    d.heartbeat.intervalMinutes = Number.isFinite(val) && val > 0 ? val : 5;
                                })
                            }
                        />
                        <span className="entry-form-hint">
                            How often agents in this project will run heartbeat checks.
                        </span>
                    </label>
                </div>
            </section>
        );
    }

    function renderLoop() {
        const isEnabled = draft.reviewSettings.enabled;
        return (
            <section className="entry-editor-card">
                <h3>Task Loop Mode</h3>
                <p style={{ margin: "0 0 16px", fontSize: "0.85rem", color: "var(--muted)" }}>
                    Choose how clarification questions from agents are handled. Individual tasks can override this default.
                </p>
                <div className="review-approval-options">
                    {LOOP_MODE_OPTIONS.map((mode) => {
                        const active = draft.taskLoopMode === mode.id;
                        return (
                            <button
                                key={mode.id}
                                type="button"
                                className={`review-approval-option ${active ? "active" : ""}`}
                                onClick={() => mutateDraft((d) => { d.taskLoopMode = mode.id; })}
                            >
                                <span className="material-symbols-rounded review-approval-icon">{mode.icon}</span>
                                <strong className="review-approval-name">{mode.label}</strong>
                                <span className="review-approval-desc">{mode.description}</span>
                                {active && (
                                    <span className="material-symbols-rounded review-approval-check">check_circle</span>
                                )}
                            </button>
                        );
                    })}
                </div>

                <div className="review-toggle-row" style={{ marginTop: 24 }}>
                    <div className="review-toggle-label">
                        <span className="material-symbols-rounded review-toggle-icon">robot</span>
                        <div>
                            <strong>Autonomous Execution (VISOR)</strong>
                            <p className="review-toggle-desc">
                                VISOR will automatically pick tasks from the backlog and execute them.
                                Requires Git Worktree &amp; Review to be enabled in the Review tab.
                            </p>
                        </div>
                    </div>
                </div>

                <div className={`review-approval-grid ${!isEnabled ? "disabled" : ""}`}>
                    {AUTONOMOUS_MODES.map((mode) => {
                        const active = draft.reviewSettings.autonomousMode === mode.id;
                        return (
                            <button
                                key={mode.id}
                                type="button"
                                className={`review-approval-option ${active ? "active" : ""}`}
                                onClick={() => mutateDraft((d) => {
                                    d.reviewSettings.autonomousMode = mode.id;
                                    if (mode.id !== "off" && !d.reviewSettings.enabled) {
                                        d.reviewSettings.enabled = true;
                                        if (!String(d.repoPath || "").trim()) {
                                            d.repoPath = `/projects/${project.id}`;
                                        }
                                    }
                                })}
                            >
                                <span className="material-symbols-rounded review-approval-icon">{mode.icon}</span>
                                <strong className="review-approval-name">{mode.label}</strong>
                                <span className="review-approval-desc">{mode.description}</span>
                                {active && (
                                    <span className="material-symbols-rounded review-approval-check">check_circle</span>
                                )}
                            </button>
                        );
                    })}
                </div>
                {!isEnabled ? (
                    <div className="review-agent-hint" style={{ marginTop: 10 }}>
                        <span className="material-symbols-rounded" style={{ fontSize: "1rem", color: "var(--warn)" }}>
                            info
                        </span>
                        <span>
                            Choosing <strong>Sequential</strong> or <strong>Parallel</strong> will automatically enable
                            <strong> Git Worktree &amp; Review</strong> for this project.
                        </span>
                    </div>
                ) : null}
            </section>
        );
    }

    function renderReview() {
        const isEnabled = draft.reviewSettings.enabled;
        const repoPath = draft.repoPath.trim();
        return (
            <section className="entry-editor-card">
                <h3>Git Worktree &amp; Review</h3>

                <div className="review-toggle-row">
                    <div className="review-toggle-label">
                        <span className="material-symbols-rounded review-toggle-icon">account_tree</span>
                        <div>
                            <strong>Git Worktree Isolation</strong>
                            <p className="review-toggle-desc">
                                Each task runs in a dedicated git branch and worktree. Changes go through review before merging into the main branch.
                            </p>
                        </div>
                    </div>
                    <label className="agent-tools-switch">
                        <input
                            type="checkbox"
                            checked={isEnabled}
                            onChange={(e) => mutateDraft((d) => {
                                d.reviewSettings.enabled = e.target.checked;
                                if (e.target.checked && !d.repoPath.trim()) {
                                    d.repoPath = `/projects/${project.id}`;
                                }
                            })}
                        />
                        <span className="agent-tools-switch-track" />
                    </label>
                </div>

                <div className="entry-form-grid" style={{ marginTop: 16 }}>
                    <label style={{ gridColumn: "1 / -1" }}>
                        Review repository path
                        <input
                            type="text"
                            placeholder="e.g. /home/user/my-project"
                            value={draft.repoPath}
                            onChange={(e) => mutateDraft((d) => { d.repoPath = e.target.value; })}
                        />
                        <span className="entry-form-hint">
                            {repoPath
                                ? <>Worktrees will be created at <code>{repoPath}/.sloppy-worktrees/</code>.</>
                                : "Uses the workspace path above. Leave empty to disable worktree isolation."}
                        </span>
                    </label>
                </div>

                <div className="review-section-divider" />
                <div className="review-approval-section">
                    <p className="review-approval-title">Approval mode</p>
                    <p className="review-approval-subtitle">
                        Choose how tasks are approved when they reach the Review stage.
                    </p>
                    <div className="review-approval-options">
                        {APPROVAL_MODES.map((mode) => {
                            const active = draft.reviewSettings.approvalMode === mode.id;
                            return (
                                <button
                                    key={mode.id}
                                    type="button"
                                    className={`review-approval-option ${active ? "active" : ""}`}
                                    onClick={() => mutateDraft((d) => { d.reviewSettings.approvalMode = mode.id; })}
                                >
                                    <span className="material-symbols-rounded review-approval-icon">{mode.icon}</span>
                                    <strong className="review-approval-name">{mode.label}</strong>
                                    <span className="review-approval-desc">{mode.description}</span>
                                    {active && (
                                        <span className="material-symbols-rounded review-approval-check">check_circle</span>
                                    )}
                                </button>
                            );
                        })}
                    </div>
                </div>

                {draft.reviewSettings.approvalMode === "agent" && (
                    <div className="review-agent-hint">
                        <span className="material-symbols-rounded" style={{ fontSize: "1rem", color: "var(--accent)" }}>info</span>
                        <span>
                            Add an actor with the <strong>Reviewer</strong> system role to the team in the Actor Board. The task will be handed off to that actor for review.
                        </span>
                    </div>
                )}
            </section>
        );
    }

    async function runTaskSyncAction(action) {
        setTaskSyncBusy(true);
        setStatusText("");
        const result = await action();
        if (result?.project && onReplaceProject) {
            onReplaceProject(result.project);
        }
        setTaskSyncBusy(false);
        return result;
    }

    function renderTaskSync() {
        const health = taskSyncDraft.health || {};
        const webhook = taskSyncDraft.webhook || {};
        return (
            <section className="entry-editor-card">
                <h3>GitHub Projects</h3>
                <div className="review-toggle-row">
                    <div className="review-toggle-label">
                        <span className="material-symbols-rounded review-toggle-icon">sync_alt</span>
                        <div>
                            <strong>Issue-backed task sync</strong>
                            <p className="review-toggle-desc">
                                Sloppy tasks link to GitHub issues and Project items. GitHub-origin comments stay read-only for agents.
                            </p>
                        </div>
                    </div>
                    <label className="agent-tools-switch">
                        <input
                            type="checkbox"
                            checked={taskSyncDraft.enabled}
                            onChange={(e) => mutateTaskSync((d) => { d.enabled = e.target.checked; })}
                        />
                        <span className="agent-tools-switch-track" />
                    </label>
                </div>

                <div className="entry-form-grid" style={{ marginTop: 16 }}>
                    <label style={{ gridColumn: "1 / -1" }}>
                        GitHub Project URL
                        <input
                            type="text"
                            placeholder="https://github.com/orgs/AdaEngine/projects/2"
                            value={taskSyncDraft.projectURL}
                            onChange={(e) => mutateTaskSync((d) => { d.projectURL = e.target.value; })}
                        />
                    </label>
                    <label>
                        Default repo
                        <input
                            type="text"
                            placeholder="owner/repo"
                            value={taskSyncDraft.defaultRepo}
                            onChange={(e) => mutateTaskSync((d) => { d.defaultRepo = e.target.value; })}
                        />
                    </label>
                    <label>
                        Token mode
                        <div className="review-approval-options" style={{ gridTemplateColumns: "repeat(2, minmax(0, 1fr))" }}>
                            {["inherit", "override"].map((mode) => (
                                <button
                                    key={mode}
                                    type="button"
                                    className={`review-approval-option ${taskSyncDraft.tokenMode === mode ? "active" : ""}`}
                                    onClick={() => mutateTaskSync((d) => { d.tokenMode = mode; })}
                                >
                                    <span className="material-symbols-rounded review-approval-icon">{mode === "inherit" ? "key" : "vpn_key"}</span>
                                    <strong className="review-approval-name">{mode === "inherit" ? "Inherit" : "Override"}</strong>
                                </button>
                            ))}
                        </div>
                    </label>
                    <label style={{ gridColumn: "1 / -1" }}>
                        Status mappings
                        <textarea
                            rows={5}
                            placeholder={"ready=Todo\nin_progress=In Progress\ndone=Done"}
                            value={taskSyncDraft.statusMappingsText}
                            onChange={(e) => mutateTaskSync((d) => { d.statusMappingsText = e.target.value; })}
                        />
                    </label>
                </div>

                <div className="settings-danger-confirm-actions" style={{ marginTop: 16 }}>
                    <button
                        type="button"
                        className="hover-levitate"
                        disabled={taskSyncBusy || !taskSyncDraft.projectURL.trim()}
                        onClick={async () => {
                            const result = await runTaskSyncAction(() => linkProjectTaskSync(project.id, {
                                providerId: "github",
                                projectURL: taskSyncDraft.projectURL.trim(),
                                defaultRepo: taskSyncDraft.defaultRepo.trim() || null,
                                tokenMode: taskSyncDraft.tokenMode,
                                statusMappings: parseStatusMappings(taskSyncDraft.statusMappingsText)
                            }));
                            setStatusText(result ? "Task sync linked" : "Task sync link failed");
                        }}
                    >
                        Link
                    </button>
                    <button
                        type="button"
                        className="hover-levitate"
                        disabled={taskSyncBusy}
                        onClick={async () => {
                            const result = await runTaskSyncAction(() => syncProjectTasksNow(project.id));
                            setStatusText(result ? "Manual sync finished" : "Manual sync failed");
                        }}
                    >
                        Sync Now
                    </button>
                    <button
                        type="button"
                        className="danger hover-levitate"
                        disabled={taskSyncBusy}
                        onClick={async () => {
                            const result = await runTaskSyncAction(() => unlinkProjectTaskSync(project.id));
                            setStatusText(result ? "Task sync unlinked" : "Task sync unlink failed");
                        }}
                    >
                        Unlink
                    </button>
                </div>

                <div className="review-section-divider" />
                <div className="entry-form-grid">
                    <label style={{ gridColumn: "1 / -1" }}>
                        Override token
                        <input
                            type="password"
                            placeholder={taskSyncTokenStatus?.maskedToken || "GitHub token"}
                            value={taskSyncToken}
                            onChange={(e) => setTaskSyncToken(e.target.value)}
                        />
                    </label>
                </div>
                <div className="settings-danger-confirm-actions" style={{ marginTop: 12 }}>
                    <button
                        type="button"
                        className="hover-levitate"
                        disabled={taskSyncBusy || !taskSyncToken.trim()}
                        onClick={async () => {
                            const result = await setProjectTaskSyncToken(project.id, { token: taskSyncToken.trim() }, "github");
                            setTaskSyncToken("");
                            setTaskSyncTokenStatus(result || null);
                            setStatusText(result ? "Override token saved" : "Token save failed");
                        }}
                    >
                        Save Token
                    </button>
                    <button
                        type="button"
                        className="danger hover-levitate"
                        disabled={taskSyncBusy || !taskSyncTokenStatus?.hasOverrideToken}
                        onClick={async () => {
                            const result = await clearProjectTaskSyncToken(project.id, "github");
                            setTaskSyncTokenStatus(result || null);
                            setStatusText(result ? "Override token cleared" : "Token clear failed");
                        }}
                    >
                        Clear Token
                    </button>
                </div>

                <div className="review-agent-hint" style={{ marginTop: 16 }}>
                    <span className="material-symbols-rounded" style={{ fontSize: "1rem", color: "var(--accent)" }}>info</span>
                    <span>
                        Health: <strong>{health.status || "unknown"}</strong>
                        {health.message ? ` - ${health.message}` : ""}
                        {webhook.webhookURL ? ` Webhook: ${webhook.webhookURL}` : ""}
                    </span>
                </div>
            </section>
        );
    }

    function renderSettingsContent() {
        switch (selectedSettings) {
            case "general":
                return renderGeneral();
            case "actors":
                return renderActors();
            case "models":
                return renderModels();
            case "agent_files":
                return renderAgentFiles();
            case "channels":
                return renderChannels();
            case "heartbeat":
                return renderHeartbeat();
            case "loop":
                return renderLoop();
            case "review":
                return renderReview();
            case "task_sync":
                return renderTaskSync();
            default:
                return null;
        }
    }

    return (
        <section className="settings-shell">
            <aside className="settings-side">
                <div className="settings-title-row">
                    <h2>Project Settings</h2>
                </div>

                <div className="settings-nav">
                    {SETTINGS_TABS.map((item) => (
                        <button
                            key={item.id}
                            type="button"
                            className={`settings-nav-item ${selectedSettings === item.id ? "active" : ""}`}
                            onClick={() => setSelectedSettings(item.id)}
                        >
                            <span className="material-symbols-rounded settings-nav-icon">{item.icon}</span>
                            <span>{item.title}</span>
                        </button>
                    ))}
                </div>
            </aside>

            <section className="settings-main">
                <header className="settings-main-head">
                    <div className="settings-main-status">
                        <span>{statusText}</span>
                    </div>
                </header>

                <div className={`settings-toast ${hasChanges ? "settings-toast--visible" : ""}`}>
                    <span className="settings-toast-label">Unsaved changes</span>
                    <div className="settings-toast-actions">
                        <button type="button" className="danger hover-levitate" onClick={cancelChanges}>
                            Cancel
                        </button>
                        <button type="button" className="hover-levitate" onClick={saveSettings}>
                            Apply
                        </button>
                    </div>
                </div>

                {renderSettingsContent()}
            </section>
        </section>
    );
}

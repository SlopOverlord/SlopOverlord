import React, { useState, useRef, useEffect } from "react";
import { parseListInput } from "./utils";

const SETTINGS_TABS = [
    { id: "general", title: "General", icon: "settings" },
    { id: "actors_teams", title: "Actors and Teams", icon: "group" },
    { id: "channels", title: "Channels", icon: "forum" }
];

export function ProjectSettingsTab({
    project,
    projectNameDraft,
    setProjectNameDraft,
    saveProjectSettings,
    saveProjectMembers,
    deleteProject,
    openAddChannelModal,
    removeProjectChannel,
    actors = [],
    teams = []
}) {
    const [selectedSettings, setSelectedSettings] = useState("general");

    const [selectedActorIds, setSelectedActorIds] = useState([]);
    const [selectedTeamIds, setSelectedTeamIds] = useState([]);
    const [actorSearch, setActorSearch] = useState("");
    const [teamSearch, setTeamSearch] = useState("");
    const [actorDropdownOpen, setActorDropdownOpen] = useState(false);
    const [teamDropdownOpen, setTeamDropdownOpen] = useState(false);

    const actorSearchRef = useRef(null);
    const teamSearchRef = useRef(null);

    useEffect(() => {
        if (project) {
            setSelectedActorIds(parseListInput(project.actors));
            setSelectedTeamIds(parseListInput(project.teams));
        }
    }, [project?.id, project?.actors, project?.teams]);

    const q = actorSearch.trim().toLowerCase();
    const filteredActors = actors.filter(
        (node) => node.displayName.toLowerCase().includes(q) || node.id.toLowerCase().includes(q)
    );
    const listToShowActors = q && filteredActors.length > 0 ? filteredActors : actors;

    const tq = teamSearch.trim().toLowerCase();
    const filteredTeams = teams.filter(
        (team) => team.name.toLowerCase().includes(tq) || team.id.toLowerCase().includes(tq)
    );
    const listToShowTeams = tq && filteredTeams.length > 0 ? filteredTeams : teams;

    function addActor(node) {
        if (!selectedActorIds.includes(node.id)) {
            const nextActors = [...selectedActorIds, node.id];
            setSelectedActorIds(nextActors);
            saveProjectMembers(nextActors, selectedTeamIds);
        }
        setActorSearch("");
    }

    function removeActor(actorId) {
        if (window.confirm("Are you sure you want to remove this actor?")) {
            const nextActors = selectedActorIds.filter((id) => id !== actorId);
            setSelectedActorIds(nextActors);
            saveProjectMembers(nextActors, selectedTeamIds);
        }
    }

    function addTeam(team) {
        if (!selectedTeamIds.includes(team.id)) {
            const nextTeams = [...selectedTeamIds, team.id];
            setSelectedTeamIds(nextTeams);
            saveProjectMembers(selectedActorIds, nextTeams);
        }
        setTeamSearch("");
    }

    function removeTeam(teamId) {
        if (window.confirm("Are you sure you want to remove this team?")) {
            const nextTeams = selectedTeamIds.filter((id) => id !== teamId);
            setSelectedTeamIds(nextTeams);
            saveProjectMembers(selectedActorIds, nextTeams);
        }
    }

    function renderSettingsContent() {
        if (selectedSettings === "general") {
            return (
                <section className="project-pane">
                    <h4>General</h4>

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
                            <button type="submit" className="project-primary hover-levitate">
                                Save Name
                            </button>
                            <button type="button" className="danger" onClick={() => deleteProject(project.id)}>
                                Delete Project
                            </button>
                        </div>
                    </form>
                </section>
            );
        }

        if (selectedSettings === "actors_teams") {
            return (
                <section className="project-pane">
                    <h4>Actors and Teams</h4>
                    <p className="placeholder-text" style={{ marginBottom: 12 }}>Manage actors and teams for this project.</p>

                    <div className="project-task-form">
                        <div className="project-task-form-grid" style={{ gridTemplateColumns: "1fr" }}>
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
                                                {listToShowActors.length === 0 ? (
                                                    <li className="actor-team-dropdown-empty">No actors</li>
                                                ) : (
                                                    listToShowActors.map((node) => {
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
                                        <div className="project-created-list" style={{ marginTop: 16 }}>
                                            {selectedActorIds.map((id) => {
                                                const node = actors.find((n) => n.id === id);
                                                const label = node ? node.displayName : id;
                                                return (
                                                    <article key={id} className="project-created-item" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                                                        <div>
                                                            <strong>{label}</strong>
                                                            <p style={{ margin: 0, fontSize: "0.85rem", color: "var(--muted)" }}>{id}</p>
                                                        </div>
                                                        <div className="project-settings-actions">
                                                            <button
                                                                title={`Remove ${label}`}
                                                                type="button"
                                                                className="agent-channel-remove"
                                                                style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                                                onMouseDown={(e) => {
                                                                    e.preventDefault();
                                                                    removeActor(id);
                                                                }}
                                                            >
                                                                <span className="material-symbols-rounded">delete</span>
                                                            </button>
                                                        </div>
                                                    </article>
                                                );
                                            })}
                                        </div>
                                    ) : null}
                                </div>
                            </label>

                            <label style={{ marginTop: 12 }}>
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
                                        <div className="project-created-list" style={{ marginTop: 16 }}>
                                            {selectedTeamIds.map((id) => {
                                                const team = teams.find((t) => t.id === id);
                                                const label = team ? team.name : id;
                                                return (
                                                    <article key={id} className="project-created-item" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                                                        <div>
                                                            <strong>{label}</strong>
                                                            <p style={{ margin: 0, fontSize: "0.85rem", color: "var(--muted)" }}>{id}</p>
                                                        </div>
                                                        <div className="project-settings-actions">
                                                            <button
                                                                title={`Remove ${label}`}
                                                                type="button"
                                                                className="agent-channel-remove"
                                                                style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                                                onMouseDown={(e) => {
                                                                    e.preventDefault();
                                                                    removeTeam(id);
                                                                }}
                                                            >
                                                                <span className="material-symbols-rounded">delete</span>
                                                            </button>
                                                        </div>
                                                    </article>
                                                );
                                            })}
                                        </div>
                                    ) : null}
                                </div>
                            </label>
                        </div>

                    </div>
                </section>
            );
        }

        if (selectedSettings === "channels") {
            return (
                <section className="project-pane">
                    <div className="project-pane-head">
                        <h4>Channels</h4>
                        <button type="button" onClick={openAddChannelModal}>
                            Add Channel
                        </button>
                    </div>

                    <div className="project-created-list">
                        {project.chats.map((chat) => (
                            <article key={chat.id} className="project-created-item" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                                <div>
                                    <strong>{chat.title}</strong>
                                    <p>{chat.channelId}</p>
                                </div>
                                <div className="project-settings-actions">
                                    <button
                                        title="Remove channel"
                                        type="button"
                                        className="agent-channel-remove"
                                        style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                        disabled={project.chats.length <= 1}
                                        onClick={() => removeProjectChannel(chat.id)}
                                    >
                                        <span className="material-symbols-rounded">delete</span>
                                    </button>
                                </div>
                            </article>
                        ))}
                    </div>
                </section>
            );
        }

        return null;
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

            <section className="settings-main" style={{ padding: "14px" }}>
                {renderSettingsContent()}
            </section>
        </section>
    );
}

import React, { useState, useMemo, useEffect } from "react";

const SETTINGS_TABS = [
    { id: "models", title: "Models", icon: "hub" },
    { id: "agent_files", title: "Agent Files", icon: "description" },
    { id: "channels", title: "Channels", icon: "forum" },
    { id: "heartbeat", title: "Heartbeat", icon: "monitor_heart" }
];

function cloneDraft(project) {
    return {
        models: Array.isArray(project?.models) ? [...project.models] : [],
        agentFiles: Array.isArray(project?.agentFiles) ? [...project.agentFiles] : [],
        heartbeat: {
            enabled: Boolean(project?.heartbeat?.enabled),
            intervalMinutes: Number.isFinite(Number(project?.heartbeat?.intervalMinutes))
                ? Number(project.heartbeat.intervalMinutes)
                : 5
        }
    };
}

export function ProjectSettingsTab({
    project,
    onUpdateProject,
    deleteProject,
    openAddChannelModal,
    removeProjectChannel
}) {
    const [selectedSettings, setSelectedSettings] = useState("models");
    const [draft, setDraft] = useState(() => cloneDraft(project));
    const [statusText, setStatusText] = useState("");

    useEffect(() => {
        setDraft(cloneDraft(project));
    }, [project?.id, project?.updatedAt]);

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

    async function saveSettings() {
        const result = await onUpdateProject({
            models: draft.models,
            agentFiles: draft.agentFiles,
            heartbeat: draft.heartbeat
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

    function renderModels() {
        return (
            <section className="entry-editor-card">
                <h3>Models</h3>
                <div className="entry-form-grid">
                    <label style={{ gridColumn: "1 / -1" }}>
                        Model identifiers
                        <textarea
                            rows={5}
                            placeholder={"gpt-4.1-mini\nopenai:gpt-4.1\nollama:qwen3"}
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

    function renderSettingsContent() {
        switch (selectedSettings) {
            case "models":
                return renderModels();
            case "agent_files":
                return renderAgentFiles();
            case "channels":
                return renderChannels();
            case "heartbeat":
                return renderHeartbeat();
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

                <div style={{ marginTop: "auto", padding: "12px 0" }}>
                    <button
                        type="button"
                        className="danger"
                        style={{ width: "100%" }}
                        onClick={() => deleteProject(project.id)}
                    >
                        Delete Project
                    </button>
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

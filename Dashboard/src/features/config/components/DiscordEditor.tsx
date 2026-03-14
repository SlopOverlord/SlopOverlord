import React, { useEffect, useState } from "react";
import { fetchAgents, fetchActorsBoard } from "../../../api";
import { PendingApprovalList } from "./PendingApprovalList";

function DiscordIcon() {
    return (
        <svg className="tg-icon" viewBox="0 0 40 40" fill="none">
            <circle cx="20" cy="20" r="20" fill="#5865F2" />
            <path
                d="M27.3 13.4a18.5 18.5 0 0 0-4.6-1.4c-.2.4-.4.8-.6 1.2a17 17 0 0 0-5.1 0c-.2-.4-.4-.8-.6-1.2a18.5 18.5 0 0 0-4.6 1.4C9 17 8.2 20.5 8.6 24a18.8 18.8 0 0 0 5.7 2.9c.5-.6.9-1.3 1.2-2a12 12 0 0 1-1.9-.9l.5-.3a13.4 13.4 0 0 0 11.5 0l.5.3c-.6.3-1.3.7-1.9.9.4.7.8 1.4 1.3 2A18.7 18.7 0 0 0 31.4 24c.4-4-1-7.4-3.1-10.6zM15.5 22c-1.1 0-2-.9-2-2.1s.9-2.1 2-2.1 2 .9 2 2.1-.9 2.1-2 2.1zm6 0c-1.1 0-2-.9-2-2.1s.9-2.1 2-2.1 2 .9 2 2.1-.9 2.1-2 2.1z"
                fill="white"
            />
        </svg>
    );
}

function ChevronIcon({ up }) {
    return (
        <svg
            className={`tg-chevron${up ? " tg-chevron-up" : ""}`}
            viewBox="0 0 24 24"
            fill="none"
            width="18"
            height="18"
        >
            <path
                d="M6 9L12 15L18 9"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
            />
        </svg>
    );
}

function AddBindingModal({ agents, agentChannels, onClose, onAdd }) {
    const [selectedAgentId, setSelectedAgentId] = useState(agents[0]?.id || "");
    const [discordChannelId, setDiscordChannelId] = useState("");

    const availableChannels = agentChannels.filter((ch) => ch.agentId === selectedAgentId);

    function handleSubmit() {
        if (!selectedAgentId) {
            return;
        }
        const channelId = availableChannels[0]?.channelId || selectedAgentId;
        onAdd({ channelId, discordChannelId: discordChannelId.trim() || null });
    }

    return (
        <div className="tg-modal-overlay" onClick={onClose}>
            <div className="tg-modal" onClick={(e) => e.stopPropagation()}>
                <div className="tg-modal-header">
                    <h3>Add Binding</h3>
                    <button type="button" className="tg-modal-close" onClick={onClose}>
                        <span className="material-symbols-rounded">close</span>
                    </button>
                </div>

                <div className="tg-modal-body">
                    <label className="tg-modal-field">
                        <span className="tg-modal-field-label">Agent</span>
                        <div className="tg-select-wrap">
                            <select value={selectedAgentId} onChange={(e) => setSelectedAgentId(e.target.value)}>
                                {agents.map((agent) => (
                                    <option key={agent.id} value={agent.id}>
                                        {agent.displayName || agent.id}
                                    </option>
                                ))}
                            </select>
                            <span className="material-symbols-rounded tg-select-chevron">expand_more</span>
                        </div>
                    </label>

                    <label className="tg-modal-field">
                        <span className="tg-modal-field-label">Discord Channel ID</span>
                        <input
                            value={discordChannelId}
                            onChange={(e) => setDiscordChannelId(e.target.value)}
                            placeholder="Optional — leave empty for all channels"
                        />
                    </label>
                </div>

                <div className="tg-modal-actions">
                    <button type="button" className="tg-modal-cancel" onClick={onClose}>
                        Cancel
                    </button>
                    <button type="button" className="tg-modal-submit" onClick={handleSubmit}>
                        Add Binding
                    </button>
                </div>
            </div>
        </div>
    );
}

export function DiscordEditor({ draftConfig, mutateDraft }) {
    const [collapsed, setCollapsed] = useState(false);
    const [showToken, setShowToken] = useState(false);
    const [showAddModal, setShowAddModal] = useState(false);
    const [agents, setAgents] = useState([]);
    const [agentChannels, setAgentChannels] = useState([]);

    useEffect(() => {
        let cancelled = false;
        async function load() {
            const [agentsRes, boardRes] = await Promise.all([fetchAgents(), fetchActorsBoard()]);
            if (cancelled) {
                return;
            }
            if (Array.isArray(agentsRes)) {
                setAgents(agentsRes.map((a) => ({ id: a.id, displayName: a.displayName || a.id })));
            }
            if (boardRes && Array.isArray(boardRes.nodes)) {
                const channels = boardRes.nodes
                    .filter((n) => n.linkedAgentId && n.channelId)
                    .map((n) => ({ agentId: n.linkedAgentId, channelId: n.channelId, nodeId: n.id }));
                setAgentChannels(channels);
            }
        }
        load().catch(() => { });
        return () => { cancelled = true; };
    }, []);

    const dc = draftConfig.channels?.discord;
    const enabled = Boolean(dc);
    const bindings = dc ? Object.entries(dc.channelAgentMap || {}) : [];

    function agentForChannel(channelId) {
        const ch = agentChannels.find((c) => c.channelId === channelId);
        if (!ch) {
            return null;
        }
        return agents.find((a) => a.id === ch.agentId) || null;
    }

    function toggleEnabled() {
        mutateDraft((draft) => {
            if (!draft.channels) {
                draft.channels = {};
            }
            if (draft.channels.discord) {
                draft.channels.discord = null;
            } else {
                draft.channels.discord = {
                    botToken: "",
                    guildId: "",
                    channelAgentMap: {}
                };
            }
        });
    }

    function setField(field, value) {
        mutateDraft((draft) => {
            if (!draft.channels?.discord) {
                return;
            }
            draft.channels.discord[field] = value;
        });
    }

    function handleAddBinding({ channelId, discordChannelId }) {
        mutateDraft((draft) => {
            if (!draft.channels?.discord) {
                return;
            }
            const key = discordChannelId || channelId;
            draft.channels.discord.channelAgentMap[key] = channelId;
        });
        setShowAddModal(false);
    }

    function removeBinding(key) {
        mutateDraft((draft) => {
            if (!draft.channels?.discord) {
                return;
            }
            delete draft.channels.discord.channelAgentMap[key];
        });
    }

    function disconnect() {
        mutateDraft((draft) => {
            if (!draft.channels) {
                return;
            }
            draft.channels.discord = null;
        });
    }

    return (
        <div className="tg-card">
            <button
                type="button"
                className="tg-card-header"
                onClick={() => setCollapsed((v) => !v)}
            >
                <div className="tg-card-identity">
                    <DiscordIcon />
                    <div className="tg-card-meta">
                        <div className="tg-card-title-row">
                            <span className="tg-card-title">Discord</span>
                            {enabled && (
                                <span className="tg-status-badge">
                                    <span className="tg-status-dot" />
                                    Active
                                </span>
                            )}
                        </div>
                        <span className="tg-card-subtitle">Discord bot integration</span>
                    </div>
                </div>
                <ChevronIcon up={!collapsed} />
            </button>

            {!collapsed && (
                <div className="tg-card-body">
                    <div className="tg-row">
                        <div className="tg-row-copy">
                            <span className="tg-row-label">Enabled</span>
                            <span className="tg-row-desc">
                                {enabled ? "Discord is receiving messages" : "Enable to start receiving messages"}
                            </span>
                        </div>
                        <label className="agent-tools-switch">
                            <input type="checkbox" checked={enabled} onChange={toggleEnabled} />
                            <span className="agent-tools-switch-track" />
                        </label>
                    </div>

                    {enabled && (
                        <>
                            <div className="tg-section">
                                <div className="tg-section-title">Update Credentials</div>
                                <div className="tg-field">
                                    <span className="tg-field-label">Bot Token</span>
                                    <div className="tg-token-field">
                                        <input
                                            type={showToken ? "text" : "password"}
                                            autoComplete="off"
                                            placeholder="Enter bot token"
                                            value={dc.botToken || ""}
                                            onChange={(event) => setField("botToken", event.target.value)}
                                        />
                                        <button
                                            type="button"
                                            className="tg-token-reveal"
                                            onClick={() => setShowToken((v) => !v)}
                                        >
                                            {showToken ? "Hide" : "Show"}
                                        </button>
                                    </div>
                                    <a
                                        href="https://discord.com/developers/applications"
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        className="tg-help-link"
                                    >
                                        Need help? Open Discord Developer Portal →
                                    </a>
                                </div>
                                <div className="tg-field" style={{ marginTop: 10 }}>
                                    <span className="tg-field-label">Guild ID</span>
                                    <input
                                        placeholder="Your Discord server (guild) ID"
                                        value={dc.guildId || ""}
                                        onChange={(event) => setField("guildId", event.target.value)}
                                    />
                                </div>
                            </div>

                            <div className="tg-section">
                                <div className="tg-section-head">
                                    <span className="tg-section-title">Bindings</span>
                                    <button
                                        type="button"
                                        className="tg-add-btn"
                                        onClick={() => setShowAddModal(true)}
                                        disabled={agents.length === 0}
                                    >
                                        Add
                                    </button>
                                </div>

                                {bindings.length === 0 && (
                                    <p className="tg-empty">
                                        No bindings yet. Add a binding to route Discord messages to an agent.
                                    </p>
                                )}

                                {bindings.map(([discordChannelId, channelId]) => {
                                    const agent = agentForChannel(channelId as string);
                                    return (
                                        <div key={discordChannelId} className="tg-binding-row">
                                            <div className="tg-binding-info">
                                                <span className="tg-binding-name">
                                                    {agent ? agent.displayName : channelId}
                                                </span>
                                                <span className="tg-binding-desc">
                                                    {agent ? `channel: ${channelId}` : "unlinked channel"}
                                                    {discordChannelId ? ` · discord: ${discordChannelId}` : " · all channels"}
                                                </span>
                                            </div>
                                            <div className="tg-binding-actions">
                                                <button type="button" onClick={() => removeBinding(discordChannelId)}>
                                                    Remove
                                                </button>
                                            </div>
                                        </div>
                                    );
                                })}
                            </div>

                            <PendingApprovalList platform="discord" />

                            <div className="tg-footer">
                                <button type="button" className="tg-disconnect-btn" onClick={disconnect}>
                                    Disconnect Discord
                                </button>
                            </div>
                        </>
                    )}
                </div>
            )}

            {showAddModal && (
                <AddBindingModal
                    agents={agents}
                    agentChannels={agentChannels}
                    onClose={() => setShowAddModal(false)}
                    onAdd={handleAddBinding}
                />
            )}
        </div>
    );
}

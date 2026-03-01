import React, { useEffect, useState } from "react";
import { createActorNode, deleteActorNode, fetchActorsBoard } from "../../../api";

function slugify(value: string) {
  return value
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9\-_:]/g, "");
}

export function AgentChannelsTab({ agentId, agentDisplayName }) {
  const [nodes, setNodes] = useState([]);
  const [statusText, setStatusText] = useState("Loading channels...");
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [newChannelId, setNewChannelId] = useState("");
  const [formError, setFormError] = useState("");

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setIsLoading(true);
      const board = await fetchActorsBoard();
      if (cancelled) {
        return;
      }
      if (!board || !Array.isArray(board.nodes)) {
        setNodes([]);
        setStatusText("Failed to load channels.");
        setIsLoading(false);
        return;
      }
      const agentNodes = board.nodes.filter((n) => n.linkedAgentId === agentId);
      setNodes(agentNodes);
      setStatusText(agentNodes.length === 0 ? "No channels yet." : `${agentNodes.length} channel${agentNodes.length !== 1 ? "s" : ""}`);
      setIsLoading(false);
    }

    load().catch(() => {
      if (!cancelled) {
        setNodes([]);
        setStatusText("Failed to load channels.");
        setIsLoading(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [agentId]);

  async function refreshNodes() {
    const board = await fetchActorsBoard();
    if (!board || !Array.isArray(board.nodes)) {
      return;
    }
    const agentNodes = board.nodes.filter((n) => n.linkedAgentId === agentId);
    setNodes(agentNodes);
    setStatusText(`${agentNodes.length} channel${agentNodes.length !== 1 ? "s" : ""}`);
  }

  async function addChannel() {
    const channelId = slugify(newChannelId);
    if (!channelId) {
      setFormError("Channel ID is required.");
      return;
    }
    const alreadyExists = nodes.some((n) => n.channelId === channelId);
    if (alreadyExists) {
      setFormError("A channel with this ID is already linked to this agent.");
      return;
    }

    setIsSaving(true);
    setFormError("");

    const nodeId = `actor:${agentId}:${channelId}`;
    const payload = {
      id: nodeId,
      displayName: agentDisplayName || agentId,
      kind: "agent",
      linkedAgentId: agentId,
      channelId,
      positionX: 120 + nodes.length * 220,
      positionY: 120,
      createdAt: new Date().toISOString()
    };

    const result = await createActorNode(payload);
    setIsSaving(false);

    if (!result) {
      setFormError("Failed to create channel. The ID may already be taken.");
      return;
    }

    await refreshNodes();
    setNewChannelId("");
    setShowForm(false);
  }

  async function removeChannel(nodeId) {
    const ok = await deleteActorNode(nodeId);
    if (!ok) {
      return;
    }
    setNodes((previous) => {
      const next = previous.filter((n) => n.id !== nodeId);
      setStatusText(`${next.length} channel${next.length !== 1 ? "s" : ""}`);
      return next;
    });
  }

  function handleFormKeyDown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      void addChannel();
    }
    if (event.key === "Escape") {
      setShowForm(false);
      setNewChannelId("");
      setFormError("");
    }
  }

  return (
    <section className="agent-config-shell agent-channels-shell">
      <div className="agent-config-head">
        <div className="agent-tools-head-copy">
          <h3>Channels</h3>
          <p className="placeholder-text">Channel IDs this agent is available in for receiving messages.</p>
        </div>
        <span className="agent-tools-status">{statusText}</span>
      </div>

      {isLoading ? (
        <p className="placeholder-text">Loading...</p>
      ) : (
        <>
          {nodes.length === 0 && !showForm ? (
            <div className="agent-channels-empty">
              <p className="placeholder-text">No channels configured. Add a channel ID to connect this agent to incoming messages.</p>
            </div>
          ) : (
            <div className="agent-channels-list">
              {nodes.map((node) => {
                const channelId = node.channelId || node.id;
                return (
                  <div key={node.id} className="agent-channel-row">
                    <div className="agent-channel-info">
                      <span className="agent-channel-id">
                        <span className="material-symbols-rounded agent-channel-icon">forum</span>
                        {channelId}
                      </span>
                      <span className="agent-channel-node-id">actor node · {node.id}</span>
                    </div>
                    <button
                      type="button"
                      className="agent-channel-remove"
                      onClick={() => void removeChannel(node.id)}
                      title="Remove channel"
                    >
                      <span className="material-symbols-rounded">delete</span>
                    </button>
                  </div>
                );
              })}
            </div>
          )}

          {showForm ? (
            <div className="agent-channel-form">
              <label className="agent-channel-form-label">
                Channel ID
                <span className="agent-channel-form-hint">Lowercase letters, numbers, hyphens, underscores, and colons only.</span>
                <input
                  value={newChannelId}
                  onChange={(event) => setNewChannelId(event.target.value)}
                  onKeyDown={handleFormKeyDown}
                  placeholder="e.g. support, general, tg:my-group"
                  autoFocus
                />
              </label>
              {formError ? <p className="agent-create-error">{formError}</p> : null}
              <div className="agent-channel-form-actions">
                <button
                  type="button"
                  onClick={() => {
                    setShowForm(false);
                    setNewChannelId("");
                    setFormError("");
                  }}
                >
                  Cancel
                </button>
                <button type="button" className="agent-create-confirm" disabled={isSaving} onClick={() => void addChannel()}>
                  {isSaving ? "Adding..." : "Add Channel"}
                </button>
              </div>
            </div>
          ) : (
            <button type="button" className="agent-channels-add-btn" onClick={() => setShowForm(true)}>
              <span className="material-symbols-rounded">add</span>
              Add Channel
            </button>
          )}
        </>
      )}
    </section>
  );
}

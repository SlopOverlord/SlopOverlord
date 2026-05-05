import React, { useCallback, useEffect, useMemo, useState } from "react";
import { CoreApi } from "../shared/api/coreApi";

type AnyRecord = Record<string, unknown>;

interface Props {
  coreApi: CoreApi;
}

interface Agent {
  id: string;
  displayName: string;
}

interface Session {
  id: string;
  title: string;
  source: "agent" | "channel";
}

interface DocumentSizes {
  agentsMarkdown: number;
  userMarkdown: number;
  identityMarkdown: number;
  soulMarkdown: number;
  friendReminderMarkdown?: number;
}

interface SessionContextData {
  agentId: string;
  sessionId: string;
  channelId: string;
  bootstrapContent: string | null;
  bootstrapChars: number;
  documentSizes: DocumentSizes;
  skillsCount: number;
  installedSkillIds: string[];
  contextUtilization: number | null;
  channelMessageCount: number | null;
  activeWorkerIds: string[] | null;
  selectedModel: string | null;
  runtimeType: string | null;
  conversationHistoryChars: number | null;
  conversationHistoryMessageCount: number | null;
}

interface ChannelInfo {
  channelId: string;
  messageCount: number;
  contextUtilization: number;
  bootstrapChars: number;
  activeWorkerIds: string[];
}

interface PromptTemplate {
  name: string;
  content: string;
  chars: number;
}

function kilo(n: number) {
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(n);
}

function pct(n: number) {
  return `${(n * 100).toFixed(1)}%`;
}

function UtilBar({ value }: { value: number }) {
  const pctNum = Math.min(1, Math.max(0, value)) * 100;
  const color = pctNum > 80 ? "var(--danger)" : pctNum > 50 ? "var(--warn)" : "var(--success)";
  return (
    <div className="debug-util-bar-track">
      <div className="debug-util-bar-fill" style={{ width: `${pctNum}%`, background: color }} />
      <span className="debug-util-bar-label">{pct(value)}</span>
    </div>
  );
}

function SectionSizeBar({ label, chars, total }: { label: string; chars: number; total: number }) {
  const pctNum = total > 0 ? Math.min(100, (chars / total) * 100) : 0;
  return (
    <div className="debug-section-row">
      <span className="debug-section-label">{label}</span>
      <div className="debug-section-bar-track">
        <div className="debug-section-bar-fill" style={{ width: `${pctNum}%` }} />
      </div>
      <span className="debug-section-chars">{kilo(chars)}c</span>
    </div>
  );
}

function Panel({ title, children, action }: { title: string; children: React.ReactNode; action?: React.ReactNode }) {
  return (
    <section className="debug-panel">
      <header className="debug-panel-header">
        <h3 className="debug-panel-title">{title}</h3>
        {action}
      </header>
      <div className="debug-panel-body">{children}</div>
    </section>
  );
}

function SessionContextPanel({ coreApi }: { coreApi: CoreApi }) {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [selectedAgent, setSelectedAgent] = useState("");
  const [selectedSession, setSelectedSession] = useState("");
  const [data, setData] = useState<SessionContextData | null>(null);
  const [loading, setLoading] = useState(false);
  const [showBootstrap, setShowBootstrap] = useState(false);

  useEffect(() => {
    coreApi.fetchAgents().then((result) => {
      if (!Array.isArray(result)) return;
      setAgents(result.map((a) => ({ id: String(a.id ?? ""), displayName: String(a.displayName ?? a.id ?? "") })));
    });
  }, [coreApi]);

  useEffect(() => {
    if (!selectedAgent) {
      setSessions([]);
      setSelectedSession("");
      setData(null);
      return;
    }
    let cancelled = false;
    Promise.all([
      coreApi.fetchAgentSessions(selectedAgent).catch(() => null),
      coreApi.fetchChannelSessions({ agentId: selectedAgent }).catch(() => null)
    ]).then(([agentSessionsResult, channelSessionsResult]) => {
      if (cancelled) return;
      const dedup = new Map<string, Session>();

      if (Array.isArray(agentSessionsResult)) {
        for (const session of agentSessionsResult) {
          const id = String(session?.id ?? "").trim();
          if (!id) continue;
          dedup.set(id, {
            id,
            title: String(session?.title ?? id),
            source: "agent"
          });
        }
      }

      if (Array.isArray(channelSessionsResult)) {
        for (const channelSession of channelSessionsResult) {
          const id = String(channelSession?.sessionId ?? "").trim();
          if (!id) continue;
          const channelId = String(channelSession?.channelId ?? "").trim();
          const preview = String(channelSession?.lastMessagePreview ?? "").trim();
          const labelParts = [channelId ? `[channel] ${channelId}` : "[channel]", preview].filter(Boolean);
          const title = labelParts.join(" · ") || id;
          const existing = dedup.get(id);
          if (!existing) {
            dedup.set(id, { id, title, source: "channel" });
          } else if (existing.source !== "channel") {
            dedup.set(id, {
              id,
              title: `${existing.title} [channel]`,
              source: existing.source
            });
          }
        }
      }

      const merged = Array.from(dedup.values()).sort((a, b) => a.title.localeCompare(b.title));
      setSessions(merged);
    });
    return () => {
      cancelled = true;
    };
  }, [coreApi, selectedAgent]);

  const load = useCallback(async () => {
    if (!selectedAgent || !selectedSession) return;
    setLoading(true);
    const result = await coreApi.fetchDebugSessionContext(selectedAgent, selectedSession);
    setLoading(false);
    if (!result) return;
    setData(result as unknown as SessionContextData);
  }, [coreApi, selectedAgent, selectedSession]);

  const docTotal = useMemo(() => {
    if (!data) return 0;
    return (
      data.documentSizes.agentsMarkdown +
      data.documentSizes.userMarkdown +
      data.documentSizes.identityMarkdown +
      data.documentSizes.soulMarkdown +
      Number(data.documentSizes.friendReminderMarkdown || 0)
    );
  }, [data]);

  return (
    <Panel
      title="Session Context Inspector"
      action={
        <button type="button" className="hover-levitate" onClick={load} disabled={!selectedAgent || !selectedSession || loading}>
          {loading ? "Loading..." : "Inspect"}
        </button>
      }
    >
      <div className="debug-selectors">
        <label className="debug-select-label">
          <span>Agent</span>
          <select
            value={selectedAgent}
            onChange={(e) => { setSelectedAgent(e.target.value); setSelectedSession(""); setData(null); }}
          >
            <option value="">-- select agent --</option>
            {agents.map((a) => (
              <option key={a.id} value={a.id}>{a.displayName}</option>
            ))}
          </select>
        </label>
        <label className="debug-select-label">
          <span>Session</span>
          <select
            value={selectedSession}
            onChange={(e) => { setSelectedSession(e.target.value); setData(null); }}
            disabled={!selectedAgent}
          >
            <option value="">-- select session --</option>
            {sessions.map((s) => (
              <option key={s.id} value={s.id}>{s.title || s.id}</option>
            ))}
          </select>
        </label>
      </div>

      {data && (
        <div className="debug-context-result">
          <div className="debug-meta-grid">
            <div className="debug-meta-item">
              <span className="debug-meta-key">Channel ID</span>
              <code className="debug-meta-val">{data.channelId}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Model</span>
              <code className="debug-meta-val">{data.selectedModel ?? "—"}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Runtime</span>
              <code className="debug-meta-val">{data.runtimeType ?? "—"}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Skills</span>
              <code className="debug-meta-val">{data.skillsCount}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Channel messages</span>
              <code className="debug-meta-val">{data.channelMessageCount ?? "—"}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">History injected</span>
              <code className="debug-meta-val">
                {data.conversationHistoryMessageCount != null
                  ? `${data.conversationHistoryMessageCount} msgs / ${kilo(data.conversationHistoryChars ?? 0)}c`
                  : "none"}
              </code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Active workers</span>
              <code className="debug-meta-val">{data.activeWorkerIds?.join(", ") || "—"}</code>
            </div>
          </div>

          {data.contextUtilization != null && (
            <div className="debug-util-section">
              <span className="debug-meta-key">Context utilization</span>
              <UtilBar value={data.contextUtilization} />
            </div>
          )}

          <div className="debug-section-breakdown">
            <p className="debug-subsection-title">Document sizes (total {kilo(docTotal)}c)</p>
            <SectionSizeBar label="AGENTS.md" chars={data.documentSizes.agentsMarkdown} total={docTotal} />
            <SectionSizeBar label="USER.md" chars={data.documentSizes.userMarkdown} total={docTotal} />
            <SectionSizeBar label="IDENTITY.md" chars={data.documentSizes.identityMarkdown} total={docTotal} />
            <SectionSizeBar label="SOUL.md" chars={data.documentSizes.soulMarkdown} total={docTotal} />
            <SectionSizeBar label="FRIEND_REMINDER.md" chars={data.documentSizes.friendReminderMarkdown || 0} total={docTotal} />
          </div>

          {data.installedSkillIds.length > 0 && (
            <div className="debug-skills-list">
              <p className="debug-subsection-title">Installed skills</p>
              {data.installedSkillIds.map((id) => (
                <code key={id} className="debug-skill-tag">{id}</code>
              ))}
            </div>
          )}

          <div className="debug-bootstrap-toggle">
            <button
              type="button"
              className="hover-levitate"
              onClick={() => setShowBootstrap((v) => !v)}
              disabled={!data.bootstrapContent}
            >
              {showBootstrap ? "Hide" : "Show"} bootstrap prompt ({kilo(data.bootstrapChars)}c)
            </button>
          </div>

          {showBootstrap && data.bootstrapContent && (
            <pre className="debug-bootstrap-pre">{data.bootstrapContent}</pre>
          )}
        </div>
      )}
    </Panel>
  );
}

function ChannelsPanel({ coreApi }: { coreApi: CoreApi }) {
  const [channels, setChannels] = useState<ChannelInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [selectedChannelId, setSelectedChannelId] = useState("");
  const [statusText, setStatusText] = useState("");

  function parseSessionScopedChannel(channelId: string): { agentId: string; sessionId: string } | null {
    const normalized = String(channelId || "").trim();
    const marker = ":session:";
    if (!normalized.startsWith("agent:") || !normalized.includes(marker)) {
      return null;
    }
    const markerIndex = normalized.indexOf(marker);
    if (markerIndex <= "agent:".length) {
      return null;
    }
    const agentId = normalized.slice("agent:".length, markerIndex).trim();
    const sessionId = normalized.slice(markerIndex + marker.length).trim();
    if (!agentId || !sessionId) {
      return null;
    }
    return { agentId, sessionId };
  }

  const load = useCallback(async () => {
    setLoading(true);
    setStatusText("");
    const result = await coreApi.fetchDebugChannels();
    setLoading(false);
    if (!result || !Array.isArray((result as AnyRecord).channels)) return;
    setChannels((result as AnyRecord).channels as ChannelInfo[]);
  }, [coreApi]);

  useEffect(() => {
    load();
  }, [load]);

  async function deleteSelectedChannel() {
    if (!selectedChannelId) {
      setStatusText("Select a channel first.");
      return;
    }
    const scoped = parseSessionScopedChannel(selectedChannelId);
    if (!scoped) {
      setStatusText("Only session-scoped channels can be deleted from this panel.");
      return;
    }
    const ok = await coreApi.deleteAgentSession(scoped.agentId, scoped.sessionId);
    if (!ok) {
      setStatusText("Failed to delete channel session.");
      return;
    }
    setStatusText(`Deleted session channel ${selectedChannelId}.`);
    setSelectedChannelId("");
    await load();
  }

  return (
    <Panel
      title="Active Channels"
      action={
        <div className="debug-panel-actions">
          <button type="button" className="hover-levitate" onClick={deleteSelectedChannel} disabled={!selectedChannelId || loading}>
            Delete selected
          </button>
          <button type="button" className="hover-levitate" onClick={load} disabled={loading}>
            {loading ? "Loading..." : "Refresh"}
          </button>
        </div>
      }
    >
      {channels.length === 0 ? (
        <p className="placeholder-text">{loading ? "Loading..." : "No active channels."}</p>
      ) : (
        <div className="debug-channels-table">
          <div className="debug-table-head">
            <span>Channel</span>
            <span>Msgs</span>
            <span>Utilization</span>
            <span>Bootstrap</span>
            <span>Workers</span>
            <span>Actions</span>
          </div>
          {channels.map((ch) => (
            <div
              key={ch.channelId}
              className={`debug-table-row ${selectedChannelId === ch.channelId ? "selected" : ""}`}
              onClick={() => setSelectedChannelId(ch.channelId)}
              role="button"
              tabIndex={0}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  setSelectedChannelId(ch.channelId);
                }
              }}
            >
              <code className="debug-channel-id">{ch.channelId}</code>
              <span>{ch.messageCount}</span>
              <UtilBar value={ch.contextUtilization} />
              <span>{kilo(ch.bootstrapChars)}c</span>
              <span>{ch.activeWorkerIds.length > 0 ? ch.activeWorkerIds.join(", ") : "—"}</span>
              <div className="debug-row-actions">
                <button
                  type="button"
                  className="hover-levitate"
                  onClick={(event) => {
                    event.stopPropagation();
                    setSelectedChannelId(ch.channelId);
                  }}
                >
                  {selectedChannelId === ch.channelId ? "Selected" : "Select"}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
      {statusText ? <p className="placeholder-text">{statusText}</p> : null}
      {selectedChannelId ? <p className="placeholder-text">Selected channel: <code>{selectedChannelId}</code></p> : null}
    </Panel>
  );
}

function PromptTemplatesPanel({ coreApi }: { coreApi: CoreApi }) {
  const [templates, setTemplates] = useState<PromptTemplate[]>([]);
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  useEffect(() => {
    setLoading(true);
    coreApi.fetchDebugPromptTemplates().then((result) => {
      setLoading(false);
      if (!result || !Array.isArray((result as AnyRecord).templates)) return;
      setTemplates((result as AnyRecord).templates as PromptTemplate[]);
    });
  }, [coreApi]);

  function toggle(name: string) {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(name)) {
        next.delete(name);
      } else {
        next.add(name);
      }
      return next;
    });
  }

  return (
    <Panel title="Prompt Partials">
      {loading && <p className="placeholder-text">Loading...</p>}
      <div className="debug-templates-list">
        {templates.map((t) => (
          <div key={t.name} className="debug-template-item">
            <button
              type="button"
              className="debug-template-toggle"
              onClick={() => toggle(t.name)}
            >
              <code>{t.name}</code>
              <span className="debug-template-meta">{kilo(t.chars)}c</span>
              <span className="material-symbols-rounded debug-template-chevron" aria-hidden="true">
                {expanded.has(t.name) ? "expand_less" : "expand_more"}
              </span>
            </button>
            {expanded.has(t.name) && (
              <pre className="debug-template-content">{t.content}</pre>
            )}
          </div>
        ))}
      </div>
    </Panel>
  );
}

export function DebugView({ coreApi }: Props) {
  return (
    <main className="grid debug-view">
      <div className="debug-header">
        <h2>Debug</h2>
        <p className="placeholder-text">Dev-only. Inspect session context, channel state, and prompt templates.</p>
      </div>
      <SessionContextPanel coreApi={coreApi} />
      <ChannelsPanel coreApi={coreApi} />
      <PromptTemplatesPanel coreApi={coreApi} />
    </main>
  );
}

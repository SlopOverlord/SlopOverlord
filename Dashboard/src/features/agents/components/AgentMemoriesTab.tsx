import React, { useEffect, useMemo, useState } from "react";
import { fetchAgentMemories, fetchAgentMemoryGraph } from "../../../api";

const PAGE_SIZE = 20;
const GRAPH_NODE_WIDTH = 240;
const GRAPH_NODE_HEIGHT = 112;
const GRAPH_COLUMN_X = {
  left: 32,
  center: 332,
  right: 632
};

type MemoryFilter = "all" | "persistent" | "temporary" | "todo";
type MemoryView = "list" | "graph";

interface MemoryScopeInfo {
  type: string;
  id: string;
  channelId?: string | null;
  projectId?: string | null;
  agentId?: string | null;
}

interface MemorySourceInfo {
  type: string;
  id?: string | null;
}

interface AgentMemoryItem {
  id: string;
  note: string;
  summary?: string | null;
  kind: string;
  memoryClass: string;
  scope: MemoryScopeInfo;
  source?: MemorySourceInfo | null;
  importance: number;
  confidence: number;
  createdAt: string;
  updatedAt: string;
  expiresAt?: string | null;
  derivedCategory: Exclude<MemoryFilter, "all">;
}

interface AgentMemoryListResponse {
  agentId: string;
  items: AgentMemoryItem[];
  total: number;
  limit: number;
  offset: number;
}

interface AgentMemoryEdgeRecord {
  fromMemoryId: string;
  toMemoryId: string;
  relation: string;
  weight: number;
  provenance?: string | null;
  createdAt: string;
}

interface AgentMemoryGraphResponse {
  agentId: string;
  nodes: AgentMemoryItem[];
  edges: AgentMemoryEdgeRecord[];
  seedIds: string[];
  truncated: boolean;
}

function asString(value: unknown, fallback = "") {
  const text = String(value ?? "").trim();
  return text || fallback;
}

function asNumber(value: unknown, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeScope(raw: unknown): MemoryScopeInfo {
  const item = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  return {
    type: asString(item.type, "global"),
    id: asString(item.id, "global"),
    channelId: asString(item.channelId ?? item.channel_id ?? "", "") || null,
    projectId: asString(item.projectId ?? item.project_id ?? "", "") || null,
    agentId: asString(item.agentId ?? item.agent_id ?? "", "") || null
  };
}

function normalizeSource(raw: unknown): MemorySourceInfo | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }

  const item = raw as Record<string, unknown>;
  const type = asString(item.type);
  if (!type) {
    return null;
  }

  return {
    type,
    id: asString(item.id, "") || null
  };
}

function normalizeMemoryItem(raw: unknown, index = 0): AgentMemoryItem | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }

  const item = raw as Record<string, unknown>;
  const id = asString(item.id, `memory-${index + 1}`);
  const note = asString(item.note);
  if (!id || !note) {
    return null;
  }

  const derivedCategory = asString(item.derivedCategory ?? item.derived_category, "temporary");
  const normalizedCategory: Exclude<MemoryFilter, "all"> =
    derivedCategory === "persistent" || derivedCategory === "todo" ? derivedCategory : "temporary";

  return {
    id,
    note,
    summary: asString(item.summary, "") || null,
    kind: asString(item.kind, "fact"),
    memoryClass: asString(item.memoryClass ?? item.memory_class, "semantic"),
    scope: normalizeScope(item.scope),
    source: normalizeSource(item.source),
    importance: asNumber(item.importance, 0),
    confidence: asNumber(item.confidence, 0),
    createdAt: asString(item.createdAt ?? item.created_at, new Date(0).toISOString()),
    updatedAt: asString(item.updatedAt ?? item.updated_at, new Date(0).toISOString()),
    expiresAt: asString(item.expiresAt ?? item.expires_at, "") || null,
    derivedCategory: normalizedCategory
  };
}

function normalizeListResponse(raw: unknown): AgentMemoryListResponse {
  const item = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const items = Array.isArray(item.items) ? item.items.map(normalizeMemoryItem).filter(Boolean) as AgentMemoryItem[] : [];
  return {
    agentId: asString(item.agentId ?? item.agent_id),
    items,
    total: asNumber(item.total, items.length),
    limit: asNumber(item.limit, PAGE_SIZE),
    offset: asNumber(item.offset, 0)
  };
}

function normalizeEdge(raw: unknown): AgentMemoryEdgeRecord | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }

  const item = raw as Record<string, unknown>;
  const fromMemoryId = asString(item.fromMemoryId ?? item.from_memory_id);
  const toMemoryId = asString(item.toMemoryId ?? item.to_memory_id);
  if (!fromMemoryId || !toMemoryId) {
    return null;
  }

  return {
    fromMemoryId,
    toMemoryId,
    relation: asString(item.relation, "about"),
    weight: asNumber(item.weight, 1),
    provenance: asString(item.provenance, "") || null,
    createdAt: asString(item.createdAt ?? item.created_at, new Date(0).toISOString())
  };
}

function normalizeGraphResponse(raw: unknown): AgentMemoryGraphResponse {
  const item = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const rawSeedIds = item.seedIds ?? item.seed_ids;
  return {
    agentId: asString(item.agentId ?? item.agent_id),
    nodes: Array.isArray(item.nodes) ? item.nodes.map(normalizeMemoryItem).filter(Boolean) as AgentMemoryItem[] : [],
    edges: Array.isArray(item.edges) ? item.edges.map(normalizeEdge).filter(Boolean) as AgentMemoryEdgeRecord[] : [],
    seedIds: Array.isArray(rawSeedIds)
      ? rawSeedIds.map((entry: unknown) => asString(entry)).filter(Boolean)
      : [],
    truncated: Boolean(item.truncated)
  };
}

function formatRelativeDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "Unknown time";
  }
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short"
  }).format(date);
}

function formatScore(value: number) {
  return `${Math.round(Math.max(0, Math.min(1, value)) * 100)}%`;
}

function scopeHint(scope: MemoryScopeInfo) {
  if (scope.type === "agent") {
    return `Agent scope · ${scope.agentId || scope.id}`;
  }
  if (scope.type === "channel") {
    return `Session channel · ${scope.channelId || scope.id}`;
  }
  if (scope.type === "project") {
    return `Project scope · ${scope.projectId || scope.id}`;
  }
  return `Global scope · ${scope.id}`;
}

function memoryCardTitle(item: AgentMemoryItem) {
  if (item.summary) {
    return item.summary;
  }
  return item.note.length > 72 ? `${item.note.slice(0, 72)}…` : item.note;
}

function categoryLabel(value: Exclude<MemoryFilter, "all">) {
  if (value === "persistent") return "Persistent";
  if (value === "temporary") return "Temporary";
  return "Todo";
}

function filterLabel(value: MemoryFilter) {
  if (value === "all") return "All";
  return categoryLabel(value);
}

function edgePath(
  fromNode: { x: number; y: number },
  toNode: { x: number; y: number }
) {
  const startX = fromNode.x + GRAPH_NODE_WIDTH / 2;
  const startY = fromNode.y + GRAPH_NODE_HEIGHT / 2;
  const endX = toNode.x + GRAPH_NODE_WIDTH / 2;
  const endY = toNode.y + GRAPH_NODE_HEIGHT / 2;
  const controlOffset = Math.max(60, Math.abs(endX - startX) * 0.35);
  return `M ${startX} ${startY} C ${startX + controlOffset} ${startY}, ${endX - controlOffset} ${endY}, ${endX} ${endY}`;
}

function layoutGraph(nodes: AgentMemoryItem[], seedIds: string[]) {
  const seedSet = new Set(seedIds);
  const seeds = nodes.filter((node) => seedSet.has(node.id));
  const neighbors = nodes.filter((node) => !seedSet.has(node.id));
  const leftColumn: AgentMemoryItem[] = [];
  const rightColumn: AgentMemoryItem[] = [];

  neighbors.forEach((node, index) => {
    if (index % 2 === 0) {
      leftColumn.push(node);
    } else {
      rightColumn.push(node);
    }
  });

  const positions = new Map<string, { x: number; y: number }>();
  const placeColumn = (items: AgentMemoryItem[], x: number) => {
    items.forEach((item, index) => {
      positions.set(item.id, {
        x,
        y: 32 + index * (GRAPH_NODE_HEIGHT + 36)
      });
    });
  };

  placeColumn(leftColumn, GRAPH_COLUMN_X.left);
  placeColumn(seeds, GRAPH_COLUMN_X.center);
  placeColumn(rightColumn, GRAPH_COLUMN_X.right);

  const maxColumnCount = Math.max(leftColumn.length, seeds.length, rightColumn.length, 1);
  return {
    positions,
    width: GRAPH_COLUMN_X.right + GRAPH_NODE_WIDTH + 32,
    height: 32 + maxColumnCount * (GRAPH_NODE_HEIGHT + 36)
  };
}

function MemoryInspector({ item }: { item: AgentMemoryItem | null }) {
  if (!item) {
    return (
      <aside className="agent-memory-inspector">
        <p className="placeholder-text">Select a memory record to inspect its full content.</p>
      </aside>
    );
  }

  return (
    <aside className="agent-memory-inspector">
      <div className="agent-memory-inspector-head">
        <div className="agent-memory-badges">
          <span className={`agent-memory-badge agent-memory-badge-${item.derivedCategory}`}>{categoryLabel(item.derivedCategory)}</span>
          <span className="agent-memory-badge agent-memory-badge-neutral">{item.kind}</span>
          <span className="agent-memory-badge agent-memory-badge-neutral">{item.memoryClass}</span>
        </div>
        <span className="agent-memory-date">{formatRelativeDate(item.createdAt)}</span>
      </div>
      <h4>{memoryCardTitle(item)}</h4>
      <p className="agent-memory-note">{item.note}</p>
      <dl className="agent-memory-inspector-meta">
        <div>
          <dt>Scope</dt>
          <dd>{scopeHint(item.scope)}</dd>
        </div>
        <div>
          <dt>Source</dt>
          <dd>{item.source ? `${item.source.type}${item.source.id ? ` · ${item.source.id}` : ""}` : "None"}</dd>
        </div>
        <div>
          <dt>Importance</dt>
          <dd>{formatScore(item.importance)}</dd>
        </div>
        <div>
          <dt>Confidence</dt>
          <dd>{formatScore(item.confidence)}</dd>
        </div>
        <div>
          <dt>Updated</dt>
          <dd>{formatRelativeDate(item.updatedAt)}</dd>
        </div>
        <div>
          <dt>Expires</dt>
          <dd>{item.expiresAt ? formatRelativeDate(item.expiresAt) : "Never"}</dd>
        </div>
      </dl>
    </aside>
  );
}

export function AgentMemoriesTab({ agentId }: { agentId: string }) {
  const [searchInput, setSearchInput] = useState("");
  const [searchQuery, setSearchQuery] = useState("");
  const [filter, setFilter] = useState<MemoryFilter>("all");
  const [view, setView] = useState<MemoryView>("list");
  const [offset, setOffset] = useState(0);
  const [listResponse, setListResponse] = useState<AgentMemoryListResponse>({
    agentId,
    items: [],
    total: 0,
    limit: PAGE_SIZE,
    offset: 0
  });
  const [graphResponse, setGraphResponse] = useState<AgentMemoryGraphResponse>({
    agentId,
    nodes: [],
    edges: [],
    seedIds: [],
    truncated: false
  });
  const [listStatusText, setListStatusText] = useState("Loading memories...");
  const [graphStatusText, setGraphStatusText] = useState("Loading memory graph...");
  const [isLoadingList, setIsLoadingList] = useState(true);
  const [isLoadingGraph, setIsLoadingGraph] = useState(false);
  const [selectedMemoryId, setSelectedMemoryId] = useState<string | null>(null);

  useEffect(() => {
    const timer = setTimeout(() => setSearchQuery(searchInput.trim()), 300);
    return () => clearTimeout(timer);
  }, [searchInput]);

  useEffect(() => {
    setOffset(0);
  }, [searchQuery, filter]);

  useEffect(() => {
    let cancelled = false;

    async function loadMemories() {
      setIsLoadingList(true);
      const response = await fetchAgentMemories(agentId, {
        search: searchQuery || undefined,
        filter,
        limit: PAGE_SIZE,
        offset
      });

      if (cancelled) {
        return;
      }

      if (!response) {
        setListResponse({
          agentId,
          items: [],
          total: 0,
          limit: PAGE_SIZE,
          offset
        });
        setListStatusText("Failed to load agent memories.");
        setIsLoadingList(false);
        return;
      }

      const normalized = normalizeListResponse(response);
      setListResponse(normalized);
      if (normalized.items.length === 0) {
        setListStatusText(searchQuery || filter !== "all" ? "No memories match the current search." : "No memories stored for this agent.");
      } else {
        const from = normalized.offset + 1;
        const to = normalized.offset + normalized.items.length;
        setListStatusText(`Showing ${from}-${to} of ${normalized.total} memories.`);
      }
      setIsLoadingList(false);
    }

    loadMemories().catch(() => {
      if (!cancelled) {
        setListResponse({
          agentId,
          items: [],
          total: 0,
          limit: PAGE_SIZE,
          offset
        });
        setListStatusText("Failed to load agent memories.");
        setIsLoadingList(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [agentId, searchQuery, filter, offset]);

  useEffect(() => {
    let cancelled = false;

    async function loadGraph() {
      setIsLoadingGraph(true);
      const response = await fetchAgentMemoryGraph(agentId, {
        search: searchQuery || undefined,
        filter
      });

      if (cancelled) {
        return;
      }

      if (!response) {
        setGraphResponse({
          agentId,
          nodes: [],
          edges: [],
          seedIds: [],
          truncated: false
        });
        setGraphStatusText("Failed to load memory graph.");
        setIsLoadingGraph(false);
        return;
      }

      const normalized = normalizeGraphResponse(response);
      setGraphResponse(normalized);
      if (normalized.nodes.length === 0) {
        setGraphStatusText(searchQuery || filter !== "all" ? "No graph nodes match the current search." : "No connected memory available yet.");
      } else if (normalized.truncated) {
        setGraphStatusText(`Graph loaded with ${normalized.nodes.length} nodes. Showing a truncated one-hop neighborhood.`);
      } else {
        setGraphStatusText(`Graph loaded with ${normalized.nodes.length} nodes and ${normalized.edges.length} edges.`);
      }
      setIsLoadingGraph(false);
    }

    loadGraph().catch(() => {
      if (!cancelled) {
        setGraphResponse({
          agentId,
          nodes: [],
          edges: [],
          seedIds: [],
          truncated: false
        });
        setGraphStatusText("Failed to load memory graph.");
        setIsLoadingGraph(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [agentId, searchQuery, filter]);

  const visibleItems = view === "graph" ? graphResponse.nodes : listResponse.items;
  const selectedItem = useMemo(
    () => visibleItems.find((item) => item.id === selectedMemoryId) || null,
    [visibleItems, selectedMemoryId]
  );

  useEffect(() => {
    if (selectedItem) {
      return;
    }

    if (visibleItems.length > 0) {
      setSelectedMemoryId(visibleItems[0].id);
      return;
    }

    setSelectedMemoryId(null);
  }, [selectedItem, visibleItems]);

  const graphLayout = useMemo(
    () => layoutGraph(graphResponse.nodes, graphResponse.seedIds),
    [graphResponse.nodes, graphResponse.seedIds]
  );

  const graphNodePositions = graphLayout.positions;
  const canGoBackward = listResponse.offset > 0;
  const canGoForward = listResponse.offset + listResponse.items.length < listResponse.total;

  return (
    <section className="agent-memories-shell">
      <div className="agent-config-head">
        <div className="agent-tools-head-copy">
          <h3>Memories</h3>
          <p className="placeholder-text">Search, inspect, and visualize what this agent currently remembers.</p>
        </div>
        <span className="agent-tools-status">{view === "graph" ? graphStatusText : listStatusText}</span>
      </div>

      <div className="agent-memories-toolbar">
        <div className="skills-search agent-memories-search">
          <span className="material-symbols-rounded">search</span>
          <input
            type="search"
            value={searchInput}
            onChange={(event) => setSearchInput(event.target.value)}
            placeholder="Search notes, summaries, or memory IDs"
          />
        </div>

        <div className="agent-memory-segmented" role="tablist" aria-label="Memory filter">
          {(["all", "persistent", "temporary", "todo"] as MemoryFilter[]).map((value) => (
            <button
              key={value}
              type="button"
              className={`agent-memory-segment ${filter === value ? "active" : ""}`}
              onClick={() => setFilter(value)}
            >
              {filterLabel(value)}
            </button>
          ))}
        </div>

        <div className="agent-memory-segmented" role="tablist" aria-label="Memory view">
          {(["list", "graph"] as MemoryView[]).map((value) => (
            <button
              key={value}
              type="button"
              className={`agent-memory-segment ${view === value ? "active" : ""}`}
              onClick={() => setView(value)}
            >
              {value === "list" ? "List" : "Graph"}
            </button>
          ))}
        </div>
      </div>

      <div className="agent-memories-body">
        <div className="agent-memories-main">
          {view === "list" ? (
            <div className="agent-memory-list-shell">
              {isLoadingList ? (
                <div className="agent-memories-empty">
                  <p className="placeholder-text">Loading memory records...</p>
                </div>
              ) : listResponse.items.length === 0 ? (
                <div className="agent-memories-empty">
                  <p className="placeholder-text">{listStatusText}</p>
                </div>
              ) : (
                <>
                  <div className="agent-memory-list">
                    {listResponse.items.map((item) => (
                      <button
                        key={item.id}
                        type="button"
                        className={`agent-memory-card ${selectedMemoryId === item.id ? "selected" : ""}`}
                        onClick={() => setSelectedMemoryId(item.id)}
                      >
                        <div className="agent-memory-card-head">
                          <strong>{memoryCardTitle(item)}</strong>
                          <span className="agent-memory-date">{formatRelativeDate(item.createdAt)}</span>
                        </div>
                        <p className="agent-memory-note">{item.note}</p>
                        <div className="agent-memory-badges">
                          <span className={`agent-memory-badge agent-memory-badge-${item.derivedCategory}`}>{categoryLabel(item.derivedCategory)}</span>
                          <span className="agent-memory-badge agent-memory-badge-neutral">{item.kind}</span>
                          <span className="agent-memory-badge agent-memory-badge-neutral">{item.memoryClass}</span>
                        </div>
                        <div className="agent-memory-card-foot">
                          <span>{scopeHint(item.scope)}</span>
                          <span>{item.id}</span>
                        </div>
                      </button>
                    ))}
                  </div>

                  <div className="agent-memory-pagination">
                    <button type="button" disabled={!canGoBackward} onClick={() => setOffset((current) => Math.max(0, current - PAGE_SIZE))}>
                      Previous
                    </button>
                    <span>{listStatusText}</span>
                    <button type="button" disabled={!canGoForward} onClick={() => setOffset((current) => current + PAGE_SIZE)}>
                      Next
                    </button>
                  </div>
                </>
              )}
            </div>
          ) : (
            <div className="agent-memory-graph-shell">
              {isLoadingGraph ? (
                <div className="agent-memories-empty">
                  <p className="placeholder-text">Loading memory graph...</p>
                </div>
              ) : graphResponse.nodes.length === 0 ? (
                <div className="agent-memories-empty">
                  <p className="placeholder-text">{graphStatusText}</p>
                </div>
              ) : (
                <>
                  {graphResponse.truncated ? (
                    <div className="agent-memory-graph-notice">
                      Graph view is truncated to the top matching seeds and their one-hop neighbors.
                    </div>
                  ) : null}
                  <div className="agent-memory-graph-stage">
                    <div
                      className="agent-memory-graph-canvas"
                      style={{ width: graphLayout.width, height: graphLayout.height }}
                    >
                      <svg
                        className="agent-memory-graph-svg"
                        viewBox={`0 0 ${graphLayout.width} ${graphLayout.height}`}
                        role="img"
                        aria-label="Agent memory graph"
                      >
                        {graphResponse.edges.map((edge) => {
                          const fromNode = graphNodePositions.get(edge.fromMemoryId);
                          const toNode = graphNodePositions.get(edge.toMemoryId);
                          if (!fromNode || !toNode) {
                            return null;
                          }

                          return (
                            <path
                              key={`${edge.fromMemoryId}:${edge.toMemoryId}:${edge.relation}`}
                              d={edgePath(fromNode, toNode)}
                              className="agent-memory-graph-edge"
                            />
                          );
                        })}
                      </svg>

                      {graphResponse.nodes.map((item) => {
                        const position = graphNodePositions.get(item.id);
                        if (!position) {
                          return null;
                        }

                        return (
                          <button
                            key={item.id}
                            type="button"
                            className={`agent-memory-graph-node ${selectedMemoryId === item.id ? "selected" : ""} ${graphResponse.seedIds.includes(item.id) ? "seed" : "neighbor"}`}
                            style={{ left: position.x, top: position.y, width: GRAPH_NODE_WIDTH, minHeight: GRAPH_NODE_HEIGHT }}
                            onClick={() => setSelectedMemoryId(item.id)}
                          >
                            <div className="agent-memory-badges">
                              <span className={`agent-memory-badge agent-memory-badge-${item.derivedCategory}`}>{categoryLabel(item.derivedCategory)}</span>
                              <span className="agent-memory-badge agent-memory-badge-neutral">{item.kind}</span>
                            </div>
                            <strong>{memoryCardTitle(item)}</strong>
                            <p>{item.note.length > 120 ? `${item.note.slice(0, 120)}…` : item.note}</p>
                          </button>
                        );
                      })}
                    </div>
                  </div>
                </>
              )}
            </div>
          )}
        </div>

        <MemoryInspector item={selectedItem} />
      </div>
    </section>
  );
}

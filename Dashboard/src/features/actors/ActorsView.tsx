import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  createActorLink,
  createActorNode,
  createActorTeam,
  createAgent as createAgentRequest,
  deleteActorLink,
  deleteActorNode,
  deleteActorTeam,
  fetchActorsBoard,
  fetchAgents,
  resolveActorRoute,
  updateActorsBoard,
  updateActorLink,
  updateActorNode,
  updateActorTeam
} from "../../api";
import { AgentCreateForm, emptyAgentFormValues, resolveSystemRole } from "../agents/components/AgentCreateForm";

const NODE_WIDTH = 180;
const NODE_HEIGHT = 88;
const SOCKETS = ["top", "right", "bottom", "left"];
const RELATIONSHIPS = ["hierarchical", "peer"];

function createEmptyBoard() {
  return {
    nodes: [],
    links: [],
    teams: [],
    updatedAt: new Date().toISOString()
  };
}

function asString(value, fallback = "") {
  const text = String(value ?? "").trim();
  return text || fallback;
}

function asNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeNode(item, index) {
  const id = asString(item?.id, `actor:${index + 1}`);
  const kind = asString(item?.kind, "action");
  const normalizedKind = ["agent", "human", "action"].includes(kind) ? kind : "action";
  const positionX = asNumber(item?.positionX, 120 + (index % 6) * 220);
  const positionY = asNumber(item?.positionY, 120 + Math.floor(index / 6) * 160);

  return {
    id,
    displayName: asString(item?.displayName, id),
    kind: normalizedKind,
    linkedAgentId: asString(item?.linkedAgentId || "", "") || null,
    channelId: asString(item?.channelId || "", "") || null,
    role: asString(item?.role || "", "") || null,
    positionX,
    positionY,
    createdAt: item?.createdAt || new Date().toISOString()
  };
}

function normalizeLink(item, index, nodeIds) {
  const id = asString(item?.id, `link:${index + 1}`);
  const sourceActorId = asString(item?.sourceActorId);
  const targetActorId = asString(item?.targetActorId);
  if (!sourceActorId || !targetActorId || sourceActorId === targetActorId) {
    return null;
  }
  if (!nodeIds.has(sourceActorId) || !nodeIds.has(targetActorId)) {
    return null;
  }

  const direction = asString(item?.direction, "one_way");
  const communicationType = asString(item?.communicationType, "chat");
  const sourceSocket = normalizeSocket(item?.sourceSocket, "right");
  const targetSocket = normalizeSocket(item?.targetSocket, "left");
  const relationshipValue = asString(item?.relationship, "");
  const relationship = RELATIONSHIPS.includes(relationshipValue)
    ? relationshipValue
    : inferRelationshipFromSockets(sourceSocket, targetSocket);
  return {
    id,
    sourceActorId,
    targetActorId,
    direction: direction === "two_way" ? "two_way" : "one_way",
    relationship,
    communicationType: ["chat", "task", "event", "discussion"].includes(communicationType) ? communicationType : "chat",
    sourceSocket,
    targetSocket,
    createdAt: item?.createdAt || new Date().toISOString()
  };
}

const TEAM_COLORS = [
  { bg: "rgba(34, 197, 94, 0.10)", border: "rgba(34, 197, 94, 0.35)", dot: "#22c55e" },
  { bg: "rgba(99, 120, 255, 0.10)", border: "rgba(99, 120, 255, 0.35)", dot: "#6378ff" },
  { bg: "rgba(251, 191, 36, 0.10)", border: "rgba(251, 191, 36, 0.30)", dot: "#fbbf24" },
  { bg: "rgba(236, 72, 153, 0.10)", border: "rgba(236, 72, 153, 0.30)", dot: "#ec4899" },
  { bg: "rgba(139, 92, 246, 0.10)", border: "rgba(139, 92, 246, 0.30)", dot: "#8b5cf6" },
  { bg: "rgba(20, 184, 166, 0.10)", border: "rgba(20, 184, 166, 0.30)", dot: "#14b8a6" }
];
const TEAM_PADDING = 24;

function normalizeTeam(item, index, nodeIds) {
  const id = asString(item?.id, `team:${index + 1}`);
  const members = Array.isArray(item?.memberActorIds)
    ? Array.from(new Set(item.memberActorIds.map((entry) => asString(entry)).filter((entry) => nodeIds.has(entry))))
    : [];

  return {
    id,
    name: asString(item?.name, id),
    memberActorIds: members,
    createdAt: item?.createdAt || new Date().toISOString()
  };
}

function computeTeamBounds(team, nodeMap) {
  const members = team.memberActorIds.map((id) => nodeMap.get(id)).filter(Boolean);
  if (members.length === 0) {
    return null;
  }
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const node of members) {
    minX = Math.min(minX, node.positionX);
    minY = Math.min(minY, node.positionY);
    maxX = Math.max(maxX, node.positionX + NODE_WIDTH);
    maxY = Math.max(maxY, node.positionY + NODE_HEIGHT);
  }
  return {
    x: minX - TEAM_PADDING,
    y: minY - TEAM_PADDING - 28,
    width: maxX - minX + TEAM_PADDING * 2,
    height: maxY - minY + TEAM_PADDING * 2 + 28
  };
}

function normalizeBoard(raw) {
  if (!raw || typeof raw !== "object") {
    return createEmptyBoard();
  }

  const rawNodes = Array.isArray(raw.nodes) ? raw.nodes : [];
  const nodes = rawNodes
    .map(normalizeNode)
    .filter((node, index, list) => list.findIndex((entry) => entry.id === node.id) === index);
  const nodeIds = new Set(nodes.map((node) => node.id));

  const links = (Array.isArray(raw.links) ? raw.links : [])
    .map((item, index) => normalizeLink(item, index, nodeIds))
    .filter(Boolean)
    .filter((item, index, list) => list.findIndex((entry) => entry.id === item.id) === index);

  const teams = (Array.isArray(raw.teams) ? raw.teams : []).map((item, index) => normalizeTeam(item, index, nodeIds));

  return {
    nodes,
    links,
    teams,
    updatedAt: raw.updatedAt || new Date().toISOString()
  };
}

function slugify(value) {
  return String(value || "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function normalizeWheelDelta(delta, deltaMode, pageSize) {
  if (deltaMode === 1) {
    return delta * 16;
  }
  if (deltaMode === 2) {
    return delta * pageSize;
  }
  return delta;
}

function uniqueId(prefix, existing) {
  if (!existing.has(prefix)) {
    return prefix;
  }

  let counter = 2;
  while (existing.has(`${prefix}-${counter}`)) {
    counter += 1;
  }
  return `${prefix}-${counter}`;
}

function isSystemNode(nodeId) {
  return nodeId === "human:admin" || nodeId.startsWith("agent:");
}

function normalizeSocket(value, fallback = "right") {
  const socket = asString(value, fallback);
  return SOCKETS.includes(socket) ? socket : fallback;
}

function inferRelationshipFromSockets(sourceSocket, targetSocket) {
  if (
    (sourceSocket === "bottom" && targetSocket === "top")
    || (sourceSocket === "top" && targetSocket === "bottom")
  ) {
    return "hierarchical";
  }
  return "peer";
}

function socketPoint(node, socket) {
  switch (socket) {
    case "top":
      return { x: node.positionX + NODE_WIDTH / 2, y: node.positionY };
    case "right":
      return { x: node.positionX + NODE_WIDTH, y: node.positionY + NODE_HEIGHT / 2 };
    case "bottom":
      return { x: node.positionX + NODE_WIDTH / 2, y: node.positionY + NODE_HEIGHT };
    case "left":
    default:
      return { x: node.positionX, y: node.positionY + NODE_HEIGHT / 2 };
  }
}

function socketTangent(socket) {
  switch (socket) {
    case "top":
      return { x: 0, y: -1 };
    case "right":
      return { x: 1, y: 0 };
    case "bottom":
      return { x: 0, y: 1 };
    case "left":
    default:
      return { x: -1, y: 0 };
  }
}

function oppositeSocket(socket) {
  switch (socket) {
    case "top":
      return "bottom";
    case "right":
      return "left";
    case "bottom":
      return "top";
    case "left":
    default:
      return "right";
  }
}

function buildBezierPath(source, target, sourceSocket, targetSocket) {
  const sourceTangent = socketTangent(sourceSocket);
  const targetTangent = socketTangent(targetSocket);
  const dx = target.x - source.x;
  const dy = target.y - source.y;
  const distance = Math.hypot(dx, dy);
  const handle = clamp(distance * 0.35, 34, 140);

  const c1 = {
    x: source.x + sourceTangent.x * handle,
    y: source.y + sourceTangent.y * handle
  };
  const c2 = {
    x: target.x + targetTangent.x * handle,
    y: target.y + targetTangent.y * handle
  };
  return `M ${source.x} ${source.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${target.x} ${target.y}`;
}

function isTypingTarget(target) {
  if (!target || typeof target.closest !== "function") {
    return false;
  }
  return Boolean(target.closest("input, textarea, select, [contenteditable='true']"));
}

export function ActorsView() {
  const [board, setBoard] = useState(createEmptyBoard);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [statusText, setStatusText] = useState("Loading actors board...");
  const [selectedNodeId, setSelectedNodeId] = useState(null);
  const [selectedLinkId, setSelectedLinkId] = useState(null);
  const [linkDirection, setLinkDirection] = useState("one_way");
  const [linkRelationship, setLinkRelationship] = useState("peer");
  const [linkCommunicationType, setLinkCommunicationType] = useState("chat");
  const [newActorName, setNewActorName] = useState("");
  const [newActorKind, setNewActorKind] = useState("human");
  const [newActorRole, setNewActorRole] = useState("");
  const [newActorStep, setNewActorStep] = useState("kind-select");
  const [agentsList, setAgentsList] = useState([]);
  const [agentRuntimeMap, setAgentRuntimeMap] = useState({});
  const [selectedAgentId, setSelectedAgentId] = useState(null);
  const [agentSearch, setAgentSearch] = useState("");
  const [agentDropdownOpen, setAgentDropdownOpen] = useState(false);
  const agentSearchRef = useRef(null);
  const [agentMode, setAgentMode] = useState("select");
  const [newAgentForm, setNewAgentForm] = useState(emptyAgentFormValues);
  const [newAgentError, setNewAgentError] = useState("");
  const [teamName, setTeamName] = useState("");
  const [teamMembers, setTeamMembers] = useState([]);
  const [editingTeamId, setEditingTeamId] = useState(null);
  const [teamMemberSearch, setTeamMemberSearch] = useState("");
  const [teamMemberDropdownOpen, setTeamMemberDropdownOpen] = useState(false);
  const teamMemberSearchRef = useRef(null);
  const [nodeDraftName, setNodeDraftName] = useState("");
  const [nodeDraftRole, setNodeDraftRole] = useState("");
  const [nodeDraftChannel, setNodeDraftChannel] = useState("");
  const [dragState, setDragState] = useState(null);
  const [teamGroupDrag, setTeamGroupDrag] = useState(null);
  const [selectedTeamId, setSelectedTeamId] = useState(null);
  const [portDrag, setPortDrag] = useState(null);
  const [hoverInputPort, setHoverInputPort] = useState(null);
  const [linkMenu, setLinkMenu] = useState(null);
  const [showNewActorPopup, setShowNewActorPopup] = useState(false);
  const [showNewTeamPopup, setShowNewTeamPopup] = useState(false);
  const [showHowItWorksPopup, setShowHowItWorksPopup] = useState(false);

  const [viewTransform, setViewTransform] = useState({ x: 0, y: 0, scale: 1 });
  const [panState, setPanState] = useState(null);

  const boardRef = useRef(board);
  const boardCanvasRef = useRef(null);
  const scrollerRef = useRef(null);
  const dragMovedRef = useRef(false);
  const viewTransformRef = useRef(viewTransform);

  function applyViewTransform(next) {
    viewTransformRef.current = next;
    setViewTransform(next);
  }

  useEffect(() => {
    boardRef.current = board;
  }, [board]);

  useEffect(() => {
    viewTransformRef.current = viewTransform;
  }, [viewTransform]);

  function applyBoardResponse(response, successMessage) {
    if (!response) {
      setStatusText("Request failed.");
      return false;
    }

    const normalized = normalizeBoard(response);
    boardRef.current = normalized;
    setBoard(normalized);
    setStatusText(successMessage);
    return true;
  }

  function fitToView(nodes) {
    const el = scrollerRef.current;
    if (!el || nodes.length === 0) {
      return;
    }
    const rect = el.getBoundingClientRect();
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const node of nodes) {
      minX = Math.min(minX, node.positionX);
      minY = Math.min(minY, node.positionY);
      maxX = Math.max(maxX, node.positionX + NODE_WIDTH);
      maxY = Math.max(maxY, node.positionY + NODE_HEIGHT);
    }
    const PAD = 80;
    const cw = maxX - minX + PAD * 2;
    const ch = maxY - minY + PAD * 2;
    const scale = Math.min(rect.width / cw, rect.height / ch, 1.5);
    const x = (rect.width - cw * scale) / 2 - (minX - PAD) * scale;
    const y = (rect.height - ch * scale) / 2 - (minY - PAD) * scale;
    applyViewTransform({ x, y, scale });
  }

  useEffect(() => {
    let isCancelled = false;

    async function loadBoard() {
      setIsLoading(true);
      const [response, agentsResult] = await Promise.all([
        fetchActorsBoard(),
        fetchAgents()
      ]);
      if (isCancelled) {
        return;
      }

      if (Array.isArray(agentsResult)) {
        const rmap = {};
        for (const a of agentsResult) {
          const row = a as { id?: string; runtime?: { type?: string } };
          if (row.runtime?.type && row.id) {
            rmap[row.id] = row.runtime;
          }
        }
        setAgentRuntimeMap(rmap);
      }

      if (!response) {
        setStatusText("Failed to load Actors board from sloppy");
        setIsLoading(false);
        return;
      }

      const normalized = normalizeBoard(response);
      boardRef.current = normalized;
      setBoard(normalized);
      setStatusText(`Loaded ${normalized.nodes.length} actors`);
      setIsLoading(false);
      requestAnimationFrame(() => fitToView(normalized.nodes));
    }

    loadBoard().catch(() => {
      if (!isCancelled) {
        setStatusText("Failed to load Actors board from sloppy");
        setIsLoading(false);
      }
    });

    return () => {
      isCancelled = true;
    };
  }, []);

  useEffect(() => {
    const el = scrollerRef.current;
    if (!el) {
      return undefined;
    }
    function handleWheel(e) {
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const vt = viewTransformRef.current;
      const deltaX = normalizeWheelDelta(e.deltaX, e.deltaMode, rect.width);
      const deltaY = normalizeWheelDelta(e.deltaY, e.deltaMode, rect.height);
      const shouldZoom = e.shiftKey || e.ctrlKey;

      if (!shouldZoom) {
        applyViewTransform({
          ...vt,
          x: vt.x - deltaX,
          y: vt.y - deltaY
        });
        return;
      }

      const dominantDelta = Math.abs(deltaY) >= Math.abs(deltaX) ? deltaY : deltaX;
      if (dominantDelta === 0) {
        return;
      }

      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;
      const factor = dominantDelta < 0 ? 1.08 : 1 / 1.08;
      const nextScale = clamp(vt.scale * factor, 0.1, 5);
      const ratio = nextScale / vt.scale;
      applyViewTransform({
        x: mx - (mx - vt.x) * ratio,
        y: my - (my - vt.y) * ratio,
        scale: nextScale
      });
    }
    el.addEventListener("wheel", handleWheel, { passive: false });
    return () => el.removeEventListener("wheel", handleWheel);
  }, []);

  useEffect(() => {
    if (!panState) {
      return undefined;
    }
    function handleMove(e) {
      applyViewTransform({
        ...viewTransformRef.current,
        x: panState.originX + (e.clientX - panState.originClientX),
        y: panState.originY + (e.clientY - panState.originClientY)
      });
    }
    function handleUp() {
      setPanState(null);
    }
    window.addEventListener("pointermove", handleMove);
    window.addEventListener("pointerup", handleUp);
    return () => {
      window.removeEventListener("pointermove", handleMove);
      window.removeEventListener("pointerup", handleUp);
    };
  }, [panState]);

  /** Persist current board state to server (nodes, links, teams). Use after any user-driven change. */
  async function persistBoard(successMessage = "Board saved") {
    const current = boardRef.current;
    const payload = {
      nodes: current.nodes,
      links: current.links,
      teams: current.teams
    };
    setIsSaving(true);
    const response = await updateActorsBoard(payload);
    setIsSaving(false);
    applyBoardResponse(response, successMessage);
  }

  function toBoardCoordinates(clientX, clientY) {
    const el = scrollerRef.current;
    if (!el) {
      return { x: 0, y: 0 };
    }
    const rect = el.getBoundingClientRect();
    const vt = viewTransformRef.current;
    return {
      x: (clientX - rect.left - vt.x) / vt.scale,
      y: (clientY - rect.top - vt.y) / vt.scale
    };
  }

  useEffect(() => {
    if (!dragState) {
      return undefined;
    }

    function handlePointerMove(event) {
      const scale = viewTransformRef.current.scale;
      const deltaX = (event.clientX - dragState.originClientX) / scale;
      const deltaY = (event.clientY - dragState.originClientY) / scale;
      dragMovedRef.current = true;

      const nextBoard = {
        ...boardRef.current,
        nodes: boardRef.current.nodes.map((node) =>
          node.id === dragState.nodeId
            ? { ...node, positionX: dragState.originNodeX + deltaX, positionY: dragState.originNodeY + deltaY }
            : node
        )
      };
      boardRef.current = nextBoard;
      setBoard(nextBoard);
    }

    function handlePointerUp() {
      const shouldPersist = dragMovedRef.current;
      dragMovedRef.current = false;
      setDragState(null);
      if (shouldPersist) {
        void persistBoard("Board layout saved");
      }
    }

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);
    return () => {
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerUp);
    };
  }, [dragState]);

  useEffect(() => {
    if (!teamGroupDrag) {
      return undefined;
    }

    function handlePointerMove(event) {
      const scale = viewTransformRef.current.scale;
      const deltaX = (event.clientX - teamGroupDrag.originClientX) / scale;
      const deltaY = (event.clientY - teamGroupDrag.originClientY) / scale;
      dragMovedRef.current = true;

      const nextBoard = {
        ...boardRef.current,
        nodes: boardRef.current.nodes.map((node) => {
          const origin = teamGroupDrag.origins[node.id];
          if (!origin) {
            return node;
          }
          return {
            ...node,
            positionX: origin.x + deltaX,
            positionY: origin.y + deltaY
          };
        })
      };
      boardRef.current = nextBoard;
      setBoard(nextBoard);
    }

    function handlePointerUp() {
      const shouldPersist = dragMovedRef.current;
      dragMovedRef.current = false;
      setTeamGroupDrag(null);
      if (shouldPersist) {
        void persistBoard("Board layout saved");
      }
    }

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);
    return () => {
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerUp);
    };
  }, [teamGroupDrag]);

  useEffect(() => {
    if (!portDrag) {
      return undefined;
    }

    function handlePointerMove(event) {
      const nextPointer = toBoardCoordinates(event.clientX, event.clientY);
      setPortDrag((previous) => (previous ? { ...previous, pointerX: nextPointer.x, pointerY: nextPointer.y } : previous));
    }

    function handlePointerUp() {
      setPortDrag(null);
      setHoverInputPort(null);
    }

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);
    return () => {
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerUp);
    };
  }, [portDrag]);

  useEffect(() => {
    const nodeIds = new Set(board.nodes.map((node) => node.id));
    if (selectedNodeId && !nodeIds.has(selectedNodeId)) {
      setSelectedNodeId(null);
    }
    if (teamMembers.some((entry) => !nodeIds.has(entry))) {
      setTeamMembers((previous) => previous.filter((entry) => nodeIds.has(entry)));
    }
  }, [board.nodes, selectedNodeId, teamMembers]);

  useEffect(() => {
    if (!linkMenu) {
      return;
    }
    if (!board.links.some((link) => link.id === linkMenu.linkId)) {
      setLinkMenu(null);
    }
  }, [board.links, linkMenu]);

  useEffect(() => {
    function handleKeyDown(event) {
      if (event.key !== "Backspace" || isTypingTarget(event.target) || isSaving) {
        return;
      }
      const linkId = linkMenu?.linkId || selectedLinkId;
      if (!linkId) {
        return;
      }
      event.preventDefault();
      void deleteSelectedLink(linkId);
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [selectedLinkId, linkMenu, isSaving]);

  const selectedNode = selectedNodeId ? board.nodes.find((node) => node.id === selectedNodeId) || null : null;
  const selectedLink = selectedLinkId ? board.links.find((link) => link.id === selectedLinkId) || null : null;

  useEffect(() => {
    if (!selectedNode) {
      setNodeDraftName("");
      setNodeDraftRole("");
      setNodeDraftChannel("");
      return;
    }

    setNodeDraftName(selectedNode.displayName || "");
    setNodeDraftRole(selectedNode.role || "");
    setNodeDraftChannel(selectedNode.channelId || "");
  }, [selectedNodeId, selectedNode?.id, selectedNode?.displayName, selectedNode?.role, selectedNode?.channelId]);

  useEffect(() => {
    if (!selectedLink) {
      return;
    }
    setLinkDirection(selectedLink.direction);
    setLinkRelationship(selectedLink.relationship || inferRelationshipFromSockets(
      normalizeSocket(selectedLink.sourceSocket, "right"),
      normalizeSocket(selectedLink.targetSocket, "left")
    ));
    setLinkCommunicationType(selectedLink.communicationType);
  }, [selectedLinkId, selectedLink?.id, selectedLink?.direction, selectedLink?.relationship, selectedLink?.communicationType, selectedLink?.sourceSocket, selectedLink?.targetSocket]);

  async function createLink(sourceNodeId, sourceSocket, targetNodeId, targetSocket) {
    if (!sourceNodeId || !targetNodeId || sourceNodeId === targetNodeId) {
      setStatusText("Link requires different source and target.");
      return;
    }

    const normalizedSourceSocket = normalizeSocket(sourceSocket, "right");
    const normalizedTargetSocket = normalizeSocket(targetSocket, "left");
    const relationship = inferRelationshipFromSockets(normalizedSourceSocket, normalizedTargetSocket);
    const duplicate = boardRef.current.links.find(
      (link) =>
        link.sourceActorId === sourceNodeId &&
        link.targetActorId === targetNodeId &&
        link.direction === linkDirection &&
        (link.relationship || inferRelationshipFromSockets(
          normalizeSocket(link.sourceSocket, "right"),
          normalizeSocket(link.targetSocket, "left")
        )) === relationship &&
        link.communicationType === linkCommunicationType &&
        normalizeSocket(link.sourceSocket, "right") === normalizedSourceSocket &&
        normalizeSocket(link.targetSocket, "left") === normalizedTargetSocket
    );
    if (duplicate) {
      setStatusText("This link already exists.");
      return;
    }

    const existingIDs = new Set(boardRef.current.links.map((link) => link.id));
    const nextLinkID = uniqueId(`link:${slugify(sourceNodeId)}:${slugify(targetNodeId)}`, existingIDs);

    setIsSaving(true);
    const response = await createActorLink({
      id: nextLinkID,
      sourceActorId: sourceNodeId,
      targetActorId: targetNodeId,
      direction: linkDirection,
      relationship,
      communicationType: linkCommunicationType,
      sourceSocket: normalizedSourceSocket,
      targetSocket: normalizedTargetSocket,
      createdAt: new Date().toISOString()
    });
    setIsSaving(false);

    if (applyBoardResponse(response, "Link added")) {
      setSelectedLinkId(nextLinkID);
      setSelectedNodeId(null);
      setLinkMenu(null);
    }
  }

  function onNodePointerDown(event, node) {
    const target = event.target;
    if (target && typeof target.closest === "function" && target.closest(".actor-socket")) {
      return;
    }

    if (event.button !== 0) {
      return;
    }

    setSelectedNodeId(node.id);
    setSelectedLinkId(null);
    setLinkMenu(null);
    dragMovedRef.current = false;
    setDragState({
      nodeId: node.id,
      originClientX: event.clientX,
      originClientY: event.clientY,
      originNodeX: node.positionX,
      originNodeY: node.positionY
    });
  }

  function onSocketPointerDown(event, node, socket) {
    event.preventDefault();
    event.stopPropagation();
    const point = socketPoint(node, socket);
    setPortDrag({
      sourceNodeId: node.id,
      sourceSocket: socket,
      pointerX: point.x,
      pointerY: point.y
    });
    setHoverInputPort(null);
    setSelectedNodeId(node.id);
    setSelectedLinkId(null);
    setLinkMenu(null);
  }

  function onSocketPointerEnter(node, socket) {
    if (!portDrag) {
      return;
    }
    setHoverInputPort({
      targetNodeId: node.id,
      targetSocket: socket
    });
  }

  function onSocketPointerLeave(node, socket) {
    if (!hoverInputPort) {
      return;
    }
    if (hoverInputPort.targetNodeId === node.id && hoverInputPort.targetSocket === socket) {
      setHoverInputPort(null);
    }
  }

  function onSocketPointerUp(event, node, socket) {
    if (!portDrag) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    const sourceNodeId = portDrag.sourceNodeId;
    const sourceSocket = portDrag.sourceSocket;
    setPortDrag(null);
    setHoverInputPort(null);
    if (sourceNodeId === node.id && sourceSocket === socket) {
      return;
    }
    void createLink(sourceNodeId, sourceSocket, node.id, socket);
  }

  function resetNewActorModal() {
    setNewActorStep("kind-select");
    setNewActorName("");
    setNewActorKind("human");
    setNewActorRole("");
    setSelectedAgentId(null);
    setAgentSearch("");
    setAgentDropdownOpen(false);
    setAgentMode("select");
    setNewAgentForm(emptyAgentFormValues());
    setNewAgentError("");
  }

  async function createActor(event) {
    event.preventDefault();
    setNewAgentError("");

    let baseName = "";
    let linkedAgentId = null;
    let shouldSetSaving = true;

    if (newActorKind === "agent") {
      if (agentMode === "create") {
        const rawId = String(newAgentForm.id || "").trim().replace(/\s+/g, "-");
        const agentDisplayName = String(newAgentForm.displayName || "").trim();
        const agentRole = String(newAgentForm.role || "").trim();

        if (!rawId) {
          setNewAgentError("Agent ID is required.");
          return;
        }

        setIsSaving(true);
        shouldSetSaving = false;

        const agentResponse = await createAgentRequest({
          id: rawId,
          displayName: agentDisplayName || rawId,
          role: agentRole || "General-purpose assistant",
          systemRole: resolveSystemRole(agentRole) || undefined
        });

        if (!agentResponse) {
          setIsSaving(false);
          setNewAgentError("Failed to create agent. Check ID format and duplicates.");
          return;
        }

        linkedAgentId = agentResponse.id;
        baseName = agentDisplayName || rawId;
      } else {
        if (!selectedAgentId) {
          setStatusText("Select an agent to link.");
          return;
        }
        const agent = agentsList.find((a) => a.id === selectedAgentId);
        baseName = asString(agent?.displayName) || selectedAgentId;
        linkedAgentId = selectedAgentId;
      }
    } else {
      baseName = asString(newActorName);
      if (!baseName) {
        setStatusText("Actor name is required.");
        return;
      }
    }

    const slug = slugify(baseName) || `actor-${Date.now()}`;
    const prefix = `${newActorKind}:${slug}`;
    const nodeIDs = new Set(boardRef.current.nodes.map((node) => node.id));
    const nodeID = uniqueId(prefix, nodeIDs);
    const index = boardRef.current.nodes.length;

    if (shouldSetSaving) {
      setIsSaving(true);
    }
    const response = await createActorNode({
      id: nodeID,
      displayName: baseName,
      kind: newActorKind,
      linkedAgentId,
      channelId: `channel:${slug}`,
      role: asString(newActorRole) || null,
      positionX: 360 + (index % 5) * 190,
      positionY: 220 + Math.floor(index / 5) * 150,
      createdAt: new Date().toISOString()
    });
    setIsSaving(false);

    if (applyBoardResponse(response, "Actor created")) {
      resetNewActorModal();
      setSelectedNodeId(nodeID);
      setSelectedLinkId(null);
      setLinkMenu(null);
      setShowNewActorPopup(false);
    }
  }

  async function saveSelectedNode() {
    if (!selectedNode) {
      return;
    }
    if (isSystemNode(selectedNode.id)) {
      setStatusText("System actors are immutable (except drag position).");
      return;
    }

    setIsSaving(true);
    const response = await updateActorNode(selectedNode.id, {
      ...selectedNode,
      displayName: asString(nodeDraftName, selectedNode.id),
      role: asString(nodeDraftRole || "", "") || null,
      channelId: asString(nodeDraftChannel || "", "") || null
    });
    setIsSaving(false);
    applyBoardResponse(response, "Actor updated");
  }

  async function deleteSelectedNode() {
    if (!selectedNodeId) {
      return;
    }
    if (isSystemNode(selectedNodeId)) {
      setStatusText("System actors (admin/agents) cannot be deleted.");
      return;
    }

    setIsSaving(true);
    const response = await deleteActorNode(selectedNodeId);
    setIsSaving(false);
    if (applyBoardResponse(response, "Actor deleted")) {
      setSelectedNodeId(null);
      setSelectedLinkId(null);
    }
  }

  function openLinkMenuForLink(link, anchorPoint) {
    setSelectedLinkId(link.id);
    setSelectedNodeId(null);
    setLinkMenu({
      linkId: link.id,
      anchorX: anchorPoint.x,
      anchorY: anchorPoint.y,
      direction: link.direction,
      relationship: link.relationship || inferRelationshipFromSockets(
        normalizeSocket(link.sourceSocket, "right"),
        normalizeSocket(link.targetSocket, "left")
      )
    });
  }

  async function updateLinkDirection(newDirection) {
    if (!linkMenu) {
      return;
    }

    const link = boardRef.current.links.find((entry) => entry.id === linkMenu.linkId);
    if (!link) {
      setLinkMenu(null);
      return;
    }

    // Optimistically update UI
    setLinkMenu((previous) => (previous ? { ...previous, direction: newDirection } : previous));
    setLinkDirection(newDirection);

    // Auto-save to server
    setIsSaving(true);
    const response = await updateActorLink(link.id, {
      ...link,
      direction: newDirection
    });
    setIsSaving(false);

    if (response) {
      applyBoardResponse(response, "Link updated");
    }
  }

  async function updateLinkRelationship(newRelationship) {
    if (!linkMenu || !RELATIONSHIPS.includes(newRelationship)) {
      return;
    }

    const link = boardRef.current.links.find((entry) => entry.id === linkMenu.linkId);
    if (!link) {
      setLinkMenu(null);
      return;
    }

    setLinkMenu((previous) => (previous ? { ...previous, relationship: newRelationship } : previous));
    setLinkRelationship(newRelationship);

    setIsSaving(true);
    const response = await updateActorLink(link.id, {
      ...link,
      relationship: newRelationship
    });
    setIsSaving(false);

    if (response) {
      applyBoardResponse(response, "Link updated");
    }
  }

  async function deleteSelectedLink(linkId = selectedLinkId) {
    if (!linkId) {
      return;
    }

    setIsSaving(true);
    const response = await deleteActorLink(linkId);
    setIsSaving(false);
    if (applyBoardResponse(response, "Link deleted")) {
      setSelectedLinkId(null);
      setLinkMenu(null);
    }
  }

  function beginTeamEdit(team) {
    setEditingTeamId(team.id);
    setTeamName(team.name);
    setTeamMembers(team.memberActorIds);
  }

  function resetTeamForm() {
    setEditingTeamId(null);
    setTeamName("");
    setTeamMembers([]);
    setTeamMemberSearch("");
    setTeamMemberDropdownOpen(false);
  }

  async function submitTeam(event) {
    event.preventDefault();
    const name = asString(teamName);
    if (!name) {
      setStatusText("Team name is required.");
      return;
    }

    const payload = {
      id: editingTeamId || `team:${slugify(name) || Date.now()}`,
      name,
      memberActorIds: Array.from(new Set(teamMembers)),
      createdAt: new Date().toISOString()
    };

    setIsSaving(true);
    const response = editingTeamId
      ? await updateActorTeam(editingTeamId, payload)
      : await createActorTeam(payload);
    setIsSaving(false);

    if (applyBoardResponse(response, editingTeamId ? "Team updated" : "Team created")) {
      resetTeamForm();
    }
  }

  async function deleteTeam(teamId) {
    setIsSaving(true);
    const response = await deleteActorTeam(teamId);
    setIsSaving(false);

    if (applyBoardResponse(response, "Team deleted") && editingTeamId === teamId) {
      resetTeamForm();
      setShowNewTeamPopup(false);
    }
  }

  async function previewRoute() {
    if (!selectedNodeId) {
      setStatusText("Select an actor to preview route.");
      return;
    }

    const response = await resolveActorRoute({
      fromActorId: selectedNodeId,
      communicationType: linkCommunicationType
    });
    if (!response || !Array.isArray(response.recipientActorIds)) {
      setStatusText("Failed to resolve route.");
      return;
    }

    const recipients = response.recipientActorIds;
    if (recipients.length === 0) {
      setStatusText("No recipients for current communication type.");
      return;
    }

    setStatusText(`Recipients: ${recipients.join(", ")}`);
  }

  const nodeMap = useMemo(() => {
    const map = new Map();
    for (const node of board.nodes) {
      map.set(node.id, node);
    }
    return map;
  }, [board.nodes]);

  const teamBoundsMap = useMemo(() => {
    const map = new Map();
    board.teams.forEach((team, index) => {
      const bounds = computeTeamBounds(team, nodeMap);
      if (bounds) {
        map.set(team.id, { team, bounds, colorIndex: index % TEAM_COLORS.length });
      }
    });
    return map;
  }, [board.teams, board.nodes, nodeMap]);

  function onTeamGroupPointerDown(event, team) {
    if (event.button !== 0) {
      return;
    }
    event.stopPropagation();
    setSelectedNodeId(null);
    setSelectedLinkId(null);
    setLinkMenu(null);
    setSelectedTeamId(team.id);
    dragMovedRef.current = false;
    const origins = {};
    for (const memberId of team.memberActorIds) {
      const node = nodeMap.get(memberId);
      if (node) {
        origins[memberId] = { x: node.positionX, y: node.positionY };
      }
    }
    setTeamGroupDrag({
      teamId: team.id,
      originClientX: event.clientX,
      originClientY: event.clientY,
      origins
    });
  }

  function openTeamEditor(team) {
    beginTeamEdit(team);
    setShowNewTeamPopup(true);
    setShowNewActorPopup(false);
  }

  let previewLine = null;
  if (portDrag) {
    const sourceNode = nodeMap.get(portDrag.sourceNodeId);
    if (sourceNode) {
      const sourceSocket = normalizeSocket(portDrag.sourceSocket, "right");
      const source = socketPoint(sourceNode, sourceSocket);
      let target = { x: portDrag.pointerX, y: portDrag.pointerY };
      let targetSocket = oppositeSocket(sourceSocket);
      if (hoverInputPort) {
        const targetNode = nodeMap.get(hoverInputPort.targetNodeId);
        if (targetNode) {
          targetSocket = normalizeSocket(hoverInputPort.targetSocket, "left");
          target = socketPoint(targetNode, targetSocket);
        }
      }
      previewLine = {
        source,
        target,
        sourceSocket,
        targetSocket
      };
    }
  }

  const linkMenuPosition = useMemo(() => {
    if (!linkMenu) {
      return null;
    }
    return {
      left: linkMenu.anchorX + 12,
      top: linkMenu.anchorY - 12
    };
  }, [linkMenu]);

  const nodeMenuPosition = useMemo(() => {
    if (!selectedNode) {
      return null;
    }
    return {
      left: selectedNode.positionX + NODE_WIDTH + 14,
      top: selectedNode.positionY
    };
  }, [selectedNode?.positionX, selectedNode?.positionY]);

  return (
    <main className="actors-shell">
      <div className="actors-layout">
        <section className="actors-board-pane">
          <div
            className="actors-board-scroller"
            ref={scrollerRef}
            onPointerDown={(event) => {
              if (event.target !== scrollerRef.current) {
                return;
              }
              setSelectedNodeId(null);
              setSelectedLinkId(null);
              setSelectedTeamId(null);
              setLinkMenu(null);
              if (event.button === 0) {
                const vt = viewTransformRef.current;
                setPanState({
                  originClientX: event.clientX,
                  originClientY: event.clientY,
                  originX: vt.x,
                  originY: vt.y
                });
              }
            }}
          >
            <div
              ref={boardCanvasRef}
              className="actors-board"
              style={{
                transform: `translate(${viewTransform.x}px, ${viewTransform.y}px) scale(${viewTransform.scale})`,
                transformOrigin: "0 0"
              }}
            >
              {Array.from(teamBoundsMap.values()).map(({ team, bounds, colorIndex }) => {
                const color = TEAM_COLORS[colorIndex];
                const isSelected = selectedTeamId === team.id;
                return (
                  <div
                    key={team.id}
                    className={`actor-team-group ${isSelected ? "selected" : ""}`}
                    style={{
                      left: bounds.x,
                      top: bounds.y,
                      width: bounds.width,
                      height: bounds.height,
                      background: color.bg,
                      borderColor: color.border
                    }}
                    onPointerDown={(event) => onTeamGroupPointerDown(event, team)}
                  >
                    <span className="actor-team-group-label" style={{ color: color.dot }}>
                      <span className="actor-team-group-dot" style={{ background: color.dot }} />
                      {team.name}
                    </span>
                    {isSelected ? (
                      <button
                        type="button"
                        className="actor-team-group-edit"
                        style={{ borderColor: color.border, color: color.dot }}
                        onPointerDown={(event) => event.stopPropagation()}
                        onClick={(event) => {
                          event.stopPropagation();
                          openTeamEditor(team);
                        }}
                        title="Edit team"
                      >
                        ✎
                      </button>
                    ) : null}
                  </div>
                );
              })}

              <svg className="actors-links-layer">
                {board.links.map((link) => {
                  const sourceNode = nodeMap.get(link.sourceActorId);
                  const targetNode = nodeMap.get(link.targetActorId);
                  if (!sourceNode || !targetNode) {
                    return null;
                  }

                  const sourceSocket = normalizeSocket(link.sourceSocket, "right");
                  const targetSocket = normalizeSocket(link.targetSocket, "left");
                  const source = socketPoint(sourceNode, sourceSocket);
                  const target = socketPoint(targetNode, targetSocket);
                  const path = buildBezierPath(source, target, sourceSocket, targetSocket);
                  const midX = (source.x + target.x) / 2;
                  const midY = (source.y + target.y) / 2;
                  const isSelected = selectedLinkId === link.id;
                  const relationship = link.relationship || inferRelationshipFromSockets(sourceSocket, targetSocket);

                  return (
                    <g key={link.id}>
                      <path
                        d={path}
                        className="actor-link-hit"
                        onClick={(event) => {
                          event.stopPropagation();
                          const point = toBoardCoordinates(event.clientX, event.clientY);
                          openLinkMenuForLink(link, point);
                        }}
                      />
                      <path
                        d={path}
                        className={`actor-link ${relationship} ${isSelected ? "selected" : ""}`}
                      />
                      <path
                        d={path}
                        className={`actor-link-flow ${relationship}`}
                      />
                      {link.direction === "two_way" ? (
                        <path
                          d={buildBezierPath(target, source, targetSocket, sourceSocket)}
                          className={`actor-link-flow ${relationship}`}
                        />
                      ) : null}
                      <text x={midX} y={midY} className="actor-link-label">
                        {link.communicationType}
                      </text>
                    </g>
                  );
                })}

                {previewLine ? (
                  <path
                    d={buildBezierPath(
                      previewLine.source,
                      previewLine.target,
                      previewLine.sourceSocket,
                      previewLine.targetSocket
                    )}
                    className="actor-link preview"
                  />
                ) : null}
              </svg>

              {board.nodes.map((node) => {
                const isSelected = selectedNodeId === node.id;
                const isDragSource = portDrag?.sourceNodeId === node.id;
                return (
                  <div
                    key={node.id}
                    className={`actor-node ${node.kind} ${isSelected ? "selected" : ""} ${isDragSource ? "drag-source" : ""}`}
                    style={{ left: node.positionX, top: node.positionY }}
                    onPointerDown={(event) => onNodePointerDown(event, node)}
                    onClick={(event) => {
                      event.stopPropagation();
                      setSelectedNodeId(node.id);
                      setSelectedLinkId(null);
                      setSelectedTeamId(null);
                      setLinkMenu(null);
                    }}
                    role="button"
                    tabIndex={0}
                  >
                    {SOCKETS.map((socket) => {
                      const isHover = hoverInputPort?.targetNodeId === node.id && hoverInputPort?.targetSocket === socket;
                      const isSource = portDrag?.sourceNodeId === node.id && portDrag?.sourceSocket === socket;
                      return (
                        <button
                          key={socket}
                          type="button"
                          className={`actor-socket side-${socket} ${isSource ? "source" : ""} ${isHover ? "hover" : ""}`}
                          onPointerDown={(event) => onSocketPointerDown(event, node, socket)}
                          onPointerEnter={() => onSocketPointerEnter(node, socket)}
                          onPointerLeave={() => onSocketPointerLeave(node, socket)}
                          onPointerUp={(event) => onSocketPointerUp(event, node, socket)}
                          title={`Socket ${socket}`}
                        />
                      );
                    })}

                    <strong>{node.displayName}</strong>
                    <span>{node.id}</span>
                    <small>
                      {node.kind}
                      {node.linkedAgentId && agentRuntimeMap[node.linkedAgentId]?.type === "acp" && (
                        <span className="actor-acp-badge">ACP</span>
                      )}
                    </small>
                  </div>
                );
              })}

              {linkMenu && linkMenuPosition ? (
                <div
                  className="actor-link-menu"
                  style={{ left: linkMenuPosition.left, top: linkMenuPosition.top }}
                  onPointerDown={(event) => event.stopPropagation()}
                >
                  <header>
                    <strong>Link Settings</strong>
                  </header>
                  <p className="actor-link-menu-title">
                    {selectedLink ? `${selectedLink.sourceActorId} → ${selectedLink.targetActorId}` : linkMenu.linkId}
                  </p>
                  <div className="actor-link-menu-actions">
                    <button
                      type="button"
                      className={linkMenu.direction === "one_way" ? "active" : ""}
                      onClick={() => void updateLinkDirection("one_way")}
                    >
                      One-Way
                    </button>
                    <button
                      type="button"
                      className={linkMenu.direction === "two_way" ? "active" : ""}
                      onClick={() => void updateLinkDirection("two_way")}
                    >
                      Two-Way
                    </button>
                  </div>
                  <div className="actor-link-menu-actions">
                    <button
                      type="button"
                      className={(linkMenu.relationship || linkRelationship) === "hierarchical" ? "active" : ""}
                      onClick={() => void updateLinkRelationship("hierarchical")}
                    >
                      Hierarchical
                    </button>
                    <button
                      type="button"
                      className={(linkMenu.relationship || linkRelationship) === "peer" ? "active" : ""}
                      onClick={() => void updateLinkRelationship("peer")}
                    >
                      Peer
                    </button>
                  </div>
                </div>
              ) : null}

              {selectedNode && nodeMenuPosition && !linkMenu ? (
                <div
                  className="actor-node-menu"
                  style={{ left: nodeMenuPosition.left, top: nodeMenuPosition.top }}
                  onPointerDown={(event) => event.stopPropagation()}
                >
                  <header>
                    <strong>{selectedNode.displayName}</strong>
                    <button
                      type="button"
                      className="actor-link-menu-close"
                      onClick={() => setSelectedNodeId(null)}
                    >
                      ×
                    </button>
                  </header>
                  <p className="actor-link-menu-title">
                    {selectedNode.id} · <span className="actor-node-menu-kind">{selectedNode.kind}</span>
                    {selectedNode.linkedAgentId && agentRuntimeMap[selectedNode.linkedAgentId]?.type === "acp" && (
                      <span className="actor-acp-badge" style={{ marginLeft: 6 }}>ACP</span>
                    )}
                  </p>
                  {isSystemNode(selectedNode.id) ? (
                    <p className="actor-link-menu-title">System actor — position only</p>
                  ) : (
                    <form
                      className="actor-node-menu-form"
                      onSubmit={(event) => {
                        event.preventDefault();
                        void saveSelectedNode();
                      }}
                    >
                      <label>
                        Name
                        <input
                          value={nodeDraftName}
                          onChange={(event) => setNodeDraftName(event.target.value)}
                        />
                      </label>
                      <label>
                        Role
                        <input
                          value={nodeDraftRole}
                          onChange={(event) => setNodeDraftRole(event.target.value)}
                          placeholder="optional"
                        />
                      </label>
                      <div className="actor-link-menu-footer">
                        <button type="submit" disabled={isSaving}>
                          Save
                        </button>
                        <button
                          type="button"
                          className="danger"
                          disabled={isSaving}
                          onClick={() => void deleteSelectedNode()}
                        >
                          Delete
                        </button>
                      </div>
                    </form>
                  )}
                </div>
              ) : null}
            </div>
          </div>

          <div className="actors-fast-actions" onPointerDown={(event) => event.stopPropagation()}>
            <p className="actors-hint">Drag between handles to link</p>
            <p className="actors-hint">Top/Bottom → Hierarchical</p>
            <p className="actors-hint">Left/Right → Peer</p>
            <button
              type="button"
              className={showNewActorPopup ? "active" : ""}
              onClick={() => {
                setShowNewActorPopup((previous) => {
                  if (!previous) {
                    resetNewActorModal();
                  }
                  return !previous;
                });
                setShowNewTeamPopup(false);
                setShowHowItWorksPopup(false);
              }}
            >
              + New Actor
            </button>
            <button
              type="button"
              className={showNewTeamPopup ? "active" : ""}
              onClick={() => {
                setShowNewTeamPopup((previous) => !previous);
                setShowNewActorPopup(false);
                setShowHowItWorksPopup(false);
              }}
            >
              + New Team
            </button>
            <button
              type="button"
              className={showHowItWorksPopup ? "active" : ""}
              onClick={() => {
                setShowHowItWorksPopup((previous) => !previous);
                setShowNewActorPopup(false);
                setShowNewTeamPopup(false);
              }}
            >
              How it works
            </button>
          </div>

          <div className="actors-board-status">
            {isLoading ? "Loading…" : isSaving ? "Saving…" : statusText}
          </div>

          {showNewActorPopup ? (
            <div
              className="actor-modal-backdrop"
              onPointerDown={(event) => {
                if (event.target === event.currentTarget) {
                  setShowNewActorPopup(false);
                  resetNewActorModal();
                }
              }}
            >
              <div className="actor-modal-card" onPointerDown={(event) => event.stopPropagation()}>
                <header>
                  <strong>
                    {newActorStep === "kind-select" ? "New Actor" : (
                      <>
                        New{" "}
                        {newActorKind === "human" ? "Human" : newActorKind === "agent" ? "Agent" : "Action"}
                      </>
                    )}
                  </strong>
                  <button
                    type="button"
                    className="actor-link-menu-close"
                    onClick={() => {
                      setShowNewActorPopup(false);
                      resetNewActorModal();
                    }}
                  >
                    ×
                  </button>
                </header>

                {newActorStep === "kind-select" ? (
                  <div className="actor-kind-picker">
                    <button
                      type="button"
                      className="actor-kind-card"
                      onClick={() => {
                        setNewActorKind("human");
                        setNewActorStep("form");
                      }}
                    >
                      <span className="actor-kind-card-label">Human</span>
                      <span className="actor-kind-card-desc">A person participating in conversations</span>
                    </button>
                    <button
                      type="button"
                      className="actor-kind-card"
                      onClick={async () => {
                        setNewActorKind("agent");
                        setNewActorStep("form");
                        const result = await fetchAgents();
                        setAgentsList(Array.isArray(result) ? result : []);
                      }}
                    >
                      <span className="actor-kind-card-label">Agent</span>
                      <span className="actor-kind-card-desc">An AI agent linked to an existing agent</span>
                    </button>
                    <button
                      type="button"
                      className="actor-kind-card"
                      onClick={() => {
                        setNewActorKind("action");
                        setNewActorStep("form");
                      }}
                    >
                      <span className="actor-kind-card-label">Action</span>
                      <span className="actor-kind-card-desc">An automated action or integration</span>
                    </button>
                  </div>
                ) : (
                  <>
                    {newActorKind === "agent" ? (
                      <div className="actor-link-menu-actions">
                        <button
                          type="button"
                          className={agentMode === "select" ? "active" : ""}
                          onClick={() => {
                            setAgentMode("select");
                            setNewAgentError("");
                          }}
                        >
                          Select existing
                        </button>
                        <button
                          type="button"
                          className={agentMode === "create" ? "active" : ""}
                          onClick={() => {
                            setAgentMode("create");
                            setNewAgentForm(emptyAgentFormValues());
                            setNewAgentError("");
                          }}
                        >
                          New agent
                        </button>
                      </div>
                    ) : null}

                    {newActorKind === "agent" && agentMode === "create" ? (
                      <AgentCreateForm
                        form={newAgentForm}
                        error={newAgentError}
                        onFormChange={(field, value) =>
                          setNewAgentForm((prev) => ({ ...prev, [field]: value }))
                        }
                        onSubmit={createActor}
                        submitLabel={isSaving ? "Creating…" : "Create Actor"}
                        onCancel={() => {
                          setAgentMode("select");
                          setNewAgentForm(emptyAgentFormValues());
                          setNewAgentError("");
                        }}
                        cancelLabel="Back"
                      />
                    ) : (
                      <form className="actor-node-menu-form" onSubmit={createActor}>
                        {newActorKind === "agent" ? (
                          <label>
                            Agent
                            <div className="actor-team-search-wrap">
                              <input
                                ref={agentSearchRef}
                                className="actor-team-search"
                                value={agentSearch}
                                onChange={(event) => {
                                  setAgentSearch(event.target.value);
                                  setAgentDropdownOpen(true);
                                  if (selectedAgentId) {
                                    setSelectedAgentId(null);
                                    setNewActorName("");
                                  }
                                }}
                                onFocus={() => setAgentDropdownOpen(true)}
                                onBlur={() => setTimeout(() => setAgentDropdownOpen(false), 150)}
                                placeholder="Search agents…"
                                autoComplete="off"
                                autoFocus
                              />
                              {agentDropdownOpen ? (
                                <ul className="actor-team-dropdown">
                                  {agentsList
                                    .filter((agent) => {
                                      const q = agentSearch.toLowerCase();
                                      return (
                                        (agent.displayName || "").toLowerCase().includes(q) ||
                                        agent.id.toLowerCase().includes(q)
                                      );
                                    })
                                    .map((agent) => {
                                      const isSelected = selectedAgentId === agent.id;
                                      return (
                                        <li
                                          key={agent.id}
                                          className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                                          onMouseDown={(event) => {
                                            event.preventDefault();
                                            setSelectedAgentId(agent.id);
                                            setNewActorName(agent.displayName || agent.id);
                                            setAgentSearch(agent.displayName || agent.id);
                                            setAgentDropdownOpen(false);
                                          }}
                                        >
                                          <span className="actor-team-dropdown-name">{agent.displayName || agent.id}</span>
                                          <span className="actor-team-dropdown-id">{agent.id}</span>
                                          {isSelected ? <span className="actor-team-dropdown-check">✓</span> : null}
                                        </li>
                                      );
                                    })}
                                  {agentsList.filter((agent) => {
                                    const q = agentSearch.toLowerCase();
                                    return (
                                      (agent.displayName || "").toLowerCase().includes(q) ||
                                      agent.id.toLowerCase().includes(q)
                                    );
                                  }).length === 0 ? (
                                    <li className="actor-team-dropdown-empty">No agents found</li>
                                  ) : null}
                                </ul>
                              ) : null}
                            </div>
                          </label>
                        ) : (
                          <label>
                            Name
                            <input
                              value={newActorName}
                              onChange={(event) => setNewActorName(event.target.value)}
                              placeholder={newActorKind === "human" ? "e.g. Product Manager" : "e.g. GitHub Webhook"}
                              autoFocus
                            />
                          </label>
                        )}
                        <label>
                          Role
                          <input
                            value={newActorRole}
                            onChange={(event) => setNewActorRole(event.target.value)}
                            placeholder="optional"
                          />
                        </label>
                        <div className="actor-link-menu-footer">
                          <button type="submit" disabled={isSaving}>
                            Create Actor
                          </button>
                          <button
                            type="button"
                            onClick={() => {
                              setNewActorStep("kind-select");
                              setNewActorName("");
                              setNewActorRole("");
                              setSelectedAgentId(null);
                              setAgentSearch("");
                              setAgentMode("select");
                            }}
                          >
                            Back
                          </button>
                        </div>
                      </form>
                    )}
                  </>
                )}
              </div>
            </div>
          ) : null}

          {showNewTeamPopup ? (
            <div
              className="actor-modal-backdrop"
              onPointerDown={(event) => {
                if (event.target === event.currentTarget) {
                  setShowNewTeamPopup(false);
                  resetTeamForm();
                }
              }}
            >
              <div className="actor-modal-card actor-modal-card--wide" onPointerDown={(event) => event.stopPropagation()}>
                <header>
                  <strong>{editingTeamId ? "Edit Team" : "New Team"}</strong>
                  <button
                    type="button"
                    className="actor-link-menu-close"
                    onClick={() => {
                      setShowNewTeamPopup(false);
                      resetTeamForm();
                    }}
                  >
                    ×
                  </button>
                </header>
                <form className="actor-node-menu-form" onSubmit={submitTeam}>
                  <label>
                    Name
                    <input
                      value={teamName}
                      onChange={(event) => setTeamName(event.target.value)}
                      placeholder="e.g. Delivery Team"
                      autoFocus
                    />
                  </label>
                  <div className="actor-team-members-picker">
                    {teamMembers.length > 0 ? (
                      <div className="actor-team-tags">
                        {teamMembers.map((memberId) => {
                          const node = board.nodes.find((n) => n.id === memberId);
                          return (
                            <span key={memberId} className="actor-team-tag">
                              {node ? node.displayName : memberId}
                              <button
                                type="button"
                                className="actor-team-tag-remove"
                                onClick={() => setTeamMembers((previous) => previous.filter((entry) => entry !== memberId))}
                                title="Remove"
                              >
                                ×
                              </button>
                            </span>
                          );
                        })}
                      </div>
                    ) : null}
                    <div className="actor-team-search-wrap">
                      <input
                        ref={teamMemberSearchRef}
                        className="actor-team-search"
                        value={teamMemberSearch}
                        onChange={(event) => {
                          setTeamMemberSearch(event.target.value);
                          setTeamMemberDropdownOpen(true);
                        }}
                        onFocus={() => setTeamMemberDropdownOpen(true)}
                        onBlur={() => setTimeout(() => setTeamMemberDropdownOpen(false), 150)}
                        placeholder="Search actors…"
                        autoComplete="off"
                      />
                      {teamMemberDropdownOpen ? (
                        <ul className="actor-team-dropdown">
                          {board.nodes
                            .filter((node) => {
                              const q = teamMemberSearch.toLowerCase();
                              return node.displayName.toLowerCase().includes(q) || node.id.toLowerCase().includes(q);
                            })
                            .map((node) => {
                              const isMember = teamMembers.includes(node.id);
                              return (
                                <li
                                  key={node.id}
                                  className={`actor-team-dropdown-item ${isMember ? "selected" : ""}`}
                                  onMouseDown={(event) => {
                                    event.preventDefault();
                                    if (isMember) {
                                      setTeamMembers((previous) => previous.filter((entry) => entry !== node.id));
                                    } else {
                                      setTeamMembers((previous) => Array.from(new Set([...previous, node.id])));
                                    }
                                    setTeamMemberSearch("");
                                  }}
                                >
                                  <span className="actor-team-dropdown-name">{node.displayName}</span>
                                  <span className="actor-team-dropdown-id">{node.id}</span>
                                  {isMember ? <span className="actor-team-dropdown-check">✓</span> : null}
                                </li>
                              );
                            })}
                          {board.nodes.filter((node) => {
                            const q = teamMemberSearch.toLowerCase();
                            return node.displayName.toLowerCase().includes(q) || node.id.toLowerCase().includes(q);
                          }).length === 0 ? (
                            <li className="actor-team-dropdown-empty">No actors found</li>
                          ) : null}
                        </ul>
                      ) : null}
                    </div>
                  </div>
                  <div className="actor-link-menu-footer">
                    <button type="submit" disabled={isSaving}>
                      {editingTeamId ? "Save Team" : "Create Team"}
                    </button>
                    {editingTeamId ? (
                      <>
                        <button
                          type="button"
                          className="danger"
                          disabled={isSaving}
                          onClick={() => void deleteTeam(editingTeamId)}
                        >
                          Delete
                        </button>
                      </>
                    ) : null}
                  </div>
                </form>
              </div>
            </div>
          ) : null}

          {showHowItWorksPopup ? (
            <div
              className="actor-modal-backdrop"
              onPointerDown={(event) => {
                if (event.target === event.currentTarget) {
                  setShowHowItWorksPopup(false);
                }
              }}
            >
              <div className="actor-modal-card actor-modal-card--wide" style={{ maxHeight: "80vh", overflowY: "auto" }} onPointerDown={(event) => event.stopPropagation()}>
                <header>
                  <strong>How the Actors Board works</strong>
                  <button
                    type="button"
                    className="actor-link-menu-close"
                    onClick={() => setShowHowItWorksPopup(false)}
                  >
                    ×
                  </button>
                </header>
                <div style={{ padding: "16px", lineHeight: "1.5" }}>
                  <p>The Actors Board defines <strong>who can do what</strong>. Tasks are routed based on the connections (links) you draw between actors.</p>
                  
                  <h3 style={{ marginTop: "16px", marginBottom: "8px" }}>Teams & the Pipeline</h3>
                  <p>Teams group actors together. A team provides several benefits:</p>
                  <ul style={{ paddingLeft: "20px", marginBottom: "16px" }}>
                    <li><strong>Task Scoping:</strong> Assigning a task to a team limits execution exclusively to that team's members.</li>
                    <li><strong>Handoff:</strong> When a team member completes a task, the system automatically follows <code>task</code> links to pass it to the next team member.</li>
                    <li><strong>Retry/Failover:</strong> If an agent fails, the task is given to the next available agent in the team.</li>
                  </ul>

                  <h3 style={{ marginTop: "16px", marginBottom: "8px" }}>Typical Flow (Dev → Reviewer → QA)</h3>
                  <p>Create a Team with your developers, reviewers, and QA agents. Draw <strong>Task</strong> links between them:</p>
                  <p style={{ background: "rgba(0,0,0,0.1)", padding: "8px", borderRadius: "4px", fontFamily: "monospace" }}>[Dev] → (Task Link) → [Reviewer] → (Task Link) → [QA]</p>
                  <p style={{ marginTop: "8px" }}>If a reviewer rejects a task, the system automatically finds a <code>developer</code> role in the same team and reassigns it back to them, moving the task status to <code>ready</code>.</p>

                  <h3 style={{ marginTop: "16px", marginBottom: "8px" }}>Link Sockets</h3>
                  <ul style={{ paddingLeft: "20px", marginBottom: "16px" }}>
                    <li><strong>Peer (Left/Right sockets):</strong> For equal-level collaboration. Used to pass tasks back and forth without decomposition.</li>
                    <li><strong>Hierarchical (Top/Bottom sockets):</strong> Triggers Swarm mode. A task assigned to a manager with hierarchical links to subordinates will be automatically broken into subtasks and delegated in parallel.</li>
                  </ul>

                  <h3 style={{ marginTop: "16px", marginBottom: "8px" }}>Swarm: Parallel Task Decomposition</h3>
                  <p>Swarm mode is activated when a task is assigned to an actor that has <strong>hierarchical task links</strong> to subordinate actors. The LLM planner will read the parent task, create child tasks, and execute them in parallel based on the depth levels of the hierarchy.</p>
                </div>
              </div>
            </div>
          ) : null}
        </section>
      </div>
    </main>
  );
}

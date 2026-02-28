import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  createActorLink,
  createActorNode,
  createActorTeam,
  deleteActorLink,
  deleteActorNode,
  deleteActorTeam,
  fetchActorsBoard,
  resolveActorRoute,
  updateActorsBoard,
  updateActorLink,
  updateActorNode,
  updateActorTeam
} from "../../api";

const BOARD_WIDTH = 1400;
const BOARD_HEIGHT = 840;
const NODE_WIDTH = 180;
const NODE_HEIGHT = 88;
const SOCKETS = ["top", "right", "bottom", "left"];

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
  const positionX = clamp(asNumber(item?.positionX, 120 + (index % 6) * 220), 0, BOARD_WIDTH - NODE_WIDTH);
  const positionY = clamp(asNumber(item?.positionY, 120 + Math.floor(index / 6) * 160), 0, BOARD_HEIGHT - NODE_HEIGHT);

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
  return {
    id,
    sourceActorId,
    targetActorId,
    direction: direction === "two_way" ? "two_way" : "one_way",
    communicationType: ["chat", "task", "event"].includes(communicationType) ? communicationType : "chat",
    sourceSocket: normalizeSocket(item?.sourceSocket, "right"),
    targetSocket: normalizeSocket(item?.targetSocket, "left"),
    createdAt: item?.createdAt || new Date().toISOString()
  };
}

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
  const [linkCommunicationType, setLinkCommunicationType] = useState("chat");
  const [newActorName, setNewActorName] = useState("");
  const [newActorKind, setNewActorKind] = useState("human");
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
  const [portDrag, setPortDrag] = useState(null);
  const [hoverInputPort, setHoverInputPort] = useState(null);
  const [linkMenu, setLinkMenu] = useState(null);
  const [showNewActorPopup, setShowNewActorPopup] = useState(false);
  const [showNewTeamPopup, setShowNewTeamPopup] = useState(false);

  const boardRef = useRef(board);
  const boardCanvasRef = useRef(null);
  const dragMovedRef = useRef(false);

  useEffect(() => {
    boardRef.current = board;
  }, [board]);

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

  useEffect(() => {
    let isCancelled = false;

    async function loadBoard() {
      setIsLoading(true);
      const response = await fetchActorsBoard();
      if (isCancelled) {
        return;
      }

      if (!response) {
        setStatusText("Failed to load Actors board from Core");
        setIsLoading(false);
        return;
      }

      const normalized = normalizeBoard(response);
      boardRef.current = normalized;
      setBoard(normalized);
      setStatusText(`Loaded ${normalized.nodes.length} actors`);
      setIsLoading(false);
    }

    loadBoard().catch(() => {
      if (!isCancelled) {
        setStatusText("Failed to load Actors board from Core");
        setIsLoading(false);
      }
    });

    return () => {
      isCancelled = true;
    };
  }, []);

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
    const boardElement = boardCanvasRef.current;
    if (!boardElement) {
      return { x: 0, y: 0 };
    }

    const rect = boardElement.getBoundingClientRect();
    return {
      x: clamp(clientX - rect.left, 0, BOARD_WIDTH),
      y: clamp(clientY - rect.top, 0, BOARD_HEIGHT)
    };
  }

  useEffect(() => {
    if (!dragState) {
      return undefined;
    }

    function handlePointerMove(event) {
      const deltaX = event.clientX - dragState.originClientX;
      const deltaY = event.clientY - dragState.originClientY;
      dragMovedRef.current = true;

      const nextX = clamp(dragState.originNodeX + deltaX, 0, BOARD_WIDTH - NODE_WIDTH);
      const nextY = clamp(dragState.originNodeY + deltaY, 0, BOARD_HEIGHT - NODE_HEIGHT);

      const nextBoard = {
        ...boardRef.current,
        nodes: boardRef.current.nodes.map((node) =>
          node.id === dragState.nodeId ? { ...node, positionX: nextX, positionY: nextY } : node
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
    setLinkCommunicationType(selectedLink.communicationType);
  }, [selectedLinkId, selectedLink?.id, selectedLink?.direction, selectedLink?.communicationType]);

  async function createLink(sourceNodeId, sourceSocket, targetNodeId, targetSocket) {
    if (!sourceNodeId || !targetNodeId || sourceNodeId === targetNodeId) {
      setStatusText("Link requires different source and target.");
      return;
    }

    const normalizedSourceSocket = normalizeSocket(sourceSocket, "right");
    const normalizedTargetSocket = normalizeSocket(targetSocket, "left");
    const duplicate = boardRef.current.links.find(
      (link) =>
        link.sourceActorId === sourceNodeId &&
        link.targetActorId === targetNodeId &&
        link.direction === linkDirection &&
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

  async function createActor(event) {
    event.preventDefault();
    const baseName = asString(newActorName);
    if (!baseName) {
      setStatusText("Actor name is required.");
      return;
    }

    const slug = slugify(baseName) || `actor-${Date.now()}`;
    const prefix = `${newActorKind}:${slug}`;
    const nodeIDs = new Set(boardRef.current.nodes.map((node) => node.id));
    const nodeID = uniqueId(prefix, nodeIDs);
    const index = boardRef.current.nodes.length;

    setIsSaving(true);
    const response = await createActorNode({
      id: nodeID,
      displayName: baseName,
      kind: newActorKind,
      linkedAgentId: null,
      channelId: `channel:${slug}`,
      role: null,
      positionX: clamp(360 + (index % 5) * 190, 0, BOARD_WIDTH - NODE_WIDTH),
      positionY: clamp(220 + Math.floor(index / 5) * 150, 0, BOARD_HEIGHT - NODE_HEIGHT),
      createdAt: new Date().toISOString()
    });
    setIsSaving(false);

    if (applyBoardResponse(response, "Actor created")) {
      setNewActorName("");
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
      direction: link.direction
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
      memberActorIds: Array.from(new Set(teamMembers)).sort(),
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
    const MENU_WIDTH = 236;
    const MENU_HEIGHT = 158;
    return {
      left: clamp(linkMenu.anchorX + 12, 10, BOARD_WIDTH - MENU_WIDTH - 10),
      top: clamp(linkMenu.anchorY - 12, 10, BOARD_HEIGHT - MENU_HEIGHT - 10)
    };
  }, [linkMenu]);

  const nodeMenuPosition = useMemo(() => {
    if (!selectedNode) {
      return null;
    }
    const MENU_WIDTH = 240;
    const MENU_HEIGHT = 280;
    let left = selectedNode.positionX + NODE_WIDTH + 14;
    if (left + MENU_WIDTH > BOARD_WIDTH - 10) {
      left = selectedNode.positionX - MENU_WIDTH - 14;
    }
    return {
      left: clamp(left, 10, BOARD_WIDTH - MENU_WIDTH - 10),
      top: clamp(selectedNode.positionY, 10, BOARD_HEIGHT - MENU_HEIGHT - 10)
    };
  }, [selectedNode?.positionX, selectedNode?.positionY]);

  return (
    <main className="actors-shell">
      <div className="actors-layout">
        <section className="actors-board-pane">
          <div className="actors-board-scroller">
            <div
              ref={boardCanvasRef}
              className="actors-board"
              style={{ width: BOARD_WIDTH, height: BOARD_HEIGHT }}
              onPointerDown={(event) => {
                if (event.target === event.currentTarget) {
                  setSelectedNodeId(null);
                  setSelectedLinkId(null);
                  setLinkMenu(null);
                }
              }}
            >
              <svg className="actors-links-layer" width={BOARD_WIDTH} height={BOARD_HEIGHT}>
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
                        className={`actor-link ${isSelected ? "selected" : ""}`}
                      />
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
                    <small>{node.kind}</small>
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
                      <label>
                        Channel
                        <input
                          value={nodeDraftChannel}
                          onChange={(event) => setNodeDraftChannel(event.target.value)}
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
                setShowNewActorPopup((previous) => !previous);
                setShowNewTeamPopup(false);
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
              }}
            >
              + New Team
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
                }
              }}
            >
              <div className="actor-modal-card" onPointerDown={(event) => event.stopPropagation()}>
                <header>
                  <strong>New Actor</strong>
                  <button
                    type="button"
                    className="actor-link-menu-close"
                    onClick={() => setShowNewActorPopup(false)}
                  >
                    ×
                  </button>
                </header>
                <form className="actor-node-menu-form" onSubmit={createActor}>
                  <label>
                    Name
                    <input
                      value={newActorName}
                      onChange={(event) => setNewActorName(event.target.value)}
                      placeholder="e.g. Product Manager"
                      autoFocus
                    />
                  </label>
                  <label>
                    Kind
                    <select value={newActorKind} onChange={(event) => setNewActorKind(event.target.value)}>
                      <option value="human">Human</option>
                      <option value="action">Action</option>
                    </select>
                  </label>
                  <button type="submit" disabled={isSaving}>
                    Create Actor
                  </button>
                </form>
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
                    <button type="button" onClick={resetTeamForm}>
                      Cancel
                    </button>
                  ) : null}
                </div>
              </form>
              {board.teams.length > 0 ? (
                <div className="actor-team-list">
                  {board.teams.map((team) => (
                    <article key={team.id}>
                      <strong>{team.name}</strong>
                      <p>{team.memberActorIds.length} members</p>
                      <button type="button" onClick={() => beginTeamEdit(team)}>
                        Edit
                      </button>
                      <button type="button" onClick={() => void deleteTeam(team.id)}>
                        Delete
                      </button>
                    </article>
                  ))}
                </div>
              ) : null}
            </div>
            </div>
          ) : null}
        </section>
      </div>
    </main>
  );
}

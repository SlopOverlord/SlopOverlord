import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  createAgentSession,
  deleteAgentSession,
  fetchAgentConfig,
  fetchAgentTasks,
  fetchProjects,
  fetchAgentSession,
  fetchAgentSessions,
  fetchTaskByReference,
  postAgentMemoryCheckpoint,
  postAgentSessionControl,
  postAgentSessionDirectory,
  postAgentSessionEvents,
  postAgentSessionMessage,
  subscribeAgentSessionStream,
  fetchAgentTokenUsage,
  searchProjectFiles,
  fetchProjectWorkingTreeGit,
  subscribeProjectChangeStream,
  fetchAgentChatSlashCommands,
  fetchPendingToolApprovals,
  approveToolApproval,
  rejectToolApproval,
  answerAgentSessionInputRequest
} from "../../../api";
import { navigateToTaskScreen } from "../../../app/routing/navigateToTaskScreen";
import { ProjectGitDiffPanel } from "./ProjectGitDiffPanel";
import { PlanInputPanel } from "../../../components/PlanInputPanel/PlanInputPanel";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import { oneDark } from "react-syntax-highlighter/dist/esm/styles/prism";
import { filterModelsByQuery } from "../utils/aggregateProviderModels";

const INLINE_ATTACHMENT_MAX_BYTES = 2 * 1024 * 1024;
const ACTIVE_RUN_STATUS_REFRESH_AFTER_MS = 30 * 1000;
const STREAM_TYPING_INTERVAL_MS = 32;
const STREAM_TYPING_CHARS_PER_SECOND = 90;
const STREAM_TYPING_MAX_CATCHUP_MS = 850;
const TASK_TAG_PATTERN = /#([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)/g;
/** e.g. `ID: ADAWEBSITE-5` */
const TASK_ID_LABEL_PATTERN = /\bID\s*:\s*([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)/gi;
/** e.g. session title `task-ADAWEBSITE-5` */
const TASK_TITLE_PREFIX_PATTERN = /\btask-([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)\b/gi;
const TASK_TAG_REMOVE_PATTERN = /(^|\s)#([A-Za-z0-9][A-Za-z0-9._-]*)(\s?)$/;
const TASK_TAG_QUERY_VALUE_PATTERN = /^[A-Za-z0-9._-]*$/;
const DEFAULT_REASONING_EFFORT = "medium";

/** Web-chat-only commands (not in channel plugin list). */
const DASHBOARD_ONLY_SLASH_COMMANDS = [
  { name: "clear", description: "Clear conversation (new session)" },
  { name: "compact", description: "Free up context by summarizing the conversation so far" },
  { name: "add_dir", description: "Add a working directory to this session" },
  { name: "tasks", description: "List tasks linked to this agent" }
];

function pathTailIfAddDirCommand(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed.startsWith("/")) {
    return null;
  }
  const match = trimmed.match(/^\/add[_-]dir(?:\s+([\s\S]*))?$/i);
  if (!match) {
    return null;
  }
  const value = String(match[1] || "").trim();
  if (value.length >= 2) {
    const first = value[0];
    const last = value[value.length - 1];
    if ((first === "\"" && last === "\"") || (first === "'" && last === "'")) {
      return value.slice(1, -1).trim();
    }
  }
  return value;
}

function mergeDashboardSlashCommands(
  server: { commands?: Array<{ name?: string; description?: string }> } | null
): Array<{ name: string; description: string }> {
  const byKey = new Map<string, { name: string; description: string }>();
  const fromServer = server && Array.isArray(server.commands) ? server.commands : [];
  for (const raw of fromServer) {
    const name = String(raw?.name || "").trim();
    if (!name) {
      continue;
    }
    const description = String(raw?.description || "").trim() || name;
    byKey.set(name.toLowerCase(), { name, description });
  }
  for (const extra of DASHBOARD_ONLY_SLASH_COMMANDS) {
    if (!byKey.has(extra.name.toLowerCase())) {
      byKey.set(extra.name.toLowerCase(), extra);
    }
  }
  return Array.from(byKey.values()).sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
}
const SLASH_CMD_INLINE_PATTERN = /\/([a-z][a-z0-9_-]*)/g;
const SLASH_CMD_REMOVE_PATTERN = /(^|\s)(\/[a-z][a-z0-9_-]*)(\s?)$/;
const FILE_REF_INLINE_PATTERN = /@([A-Za-z0-9._/-]+)/g;
const PATH_AT_QUERY_VALUE_PATTERN = /^[A-Za-z0-9._/-]*$/;
const CHAT_MODES = [
  { id: "ask", label: "Ask", icon: "chat_bubble", description: "Ask mode" },
  { id: "build", label: "Build", icon: "code", description: "Build mode" },
  { id: "plan", label: "Plan", icon: "schema", description: "Plan mode" },
  { id: "debug", label: "Debug", icon: "bug_report", description: "Debug mode" }
];
const DEFAULT_CHAT_MODE = "ask";
const CHAT_MODE_STORAGE_PREFIX = "sloppy.agentChat.mode";

/** Must match `CoreService.sloppyProjectsDirectoryScopeID` — file search under workspace `projects/` when the chat is not project-scoped. */
const SLOPPY_PROJECTS_DIRECTORY_SCOPE_ID = "_sloppyProjectsRoot";

const AGENT_CHAT_COMPOSE_DRAFT_PREFIX = "sloppy.agentChat.composeDraft";

function chatModeStorageKey(agentId, projectId, scope) {
  const explicit = String(scope || "").trim();
  if (explicit) {
    return `${CHAT_MODE_STORAGE_PREFIX}:${explicit}`;
  }
  const aid = String(agentId || "").trim() || "_agent";
  const pid = String(projectId || "").trim();
  return `${CHAT_MODE_STORAGE_PREFIX}:${pid ? `project:${pid}:` : ""}agent:${aid}`;
}

function normalizeChatMode(value) {
  const raw = String(value || "").trim().toLowerCase();
  return CHAT_MODES.some((mode) => mode.id === raw) ? raw : DEFAULT_CHAT_MODE;
}

function readStoredChatMode(agentId, projectId, scope) {
  if (typeof window === "undefined") {
    return DEFAULT_CHAT_MODE;
  }
  try {
    return normalizeChatMode(window.localStorage.getItem(chatModeStorageKey(agentId, projectId, scope)));
  } catch {
    return DEFAULT_CHAT_MODE;
  }
}

function writeStoredChatMode(agentId, projectId, scope, mode) {
  if (typeof window === "undefined") {
    return;
  }
  try {
    window.localStorage.setItem(chatModeStorageKey(agentId, projectId, scope), normalizeChatMode(mode));
  } catch {
    // ignore quota / private mode
  }
}

function nextChatMode(current, direction = 1) {
  const normalized = normalizeChatMode(current);
  const index = Math.max(0, CHAT_MODES.findIndex((mode) => mode.id === normalized));
  const nextIndex = (index + direction + CHAT_MODES.length) % CHAT_MODES.length;
  return CHAT_MODES[nextIndex].id;
}

function chatModeMeta(mode) {
  return CHAT_MODES.find((item) => item.id === normalizeChatMode(mode)) || CHAT_MODES[0];
}

function agentChatComposeDraftKey(agentId, sessionId) {
  const aid = String(agentId || "").trim();
  const sid = sessionId && String(sessionId).trim() ? String(sessionId).trim() : "_new";
  return `${AGENT_CHAT_COMPOSE_DRAFT_PREFIX}:${aid}:${sid}`;
}

function readComposeDraftState(agentId, sessionId) {
  if (typeof window === "undefined") {
    return { text: "", gitTags: [] };
  }
  try {
    const raw = window.localStorage.getItem(agentChatComposeDraftKey(agentId, sessionId));
    if (raw == null || raw === "") {
      return { text: "", gitTags: [] };
    }
    if (typeof raw === "string" && raw.startsWith("{")) {
      try {
        const o = JSON.parse(raw);
        if (o && o.v === 2 && typeof o.text === "string") {
          const gitTags = Array.isArray(o.gitTags)
            ? o.gitTags
                .filter(
                  (t) =>
                    t &&
                    typeof t.id === "string" &&
                    typeof t.label === "string" &&
                    typeof t.markdown === "string"
                )
                .map((t) => ({ id: t.id, label: t.label, markdown: t.markdown }))
            : [];
          return { text: o.text, gitTags };
        }
      } catch {
        return { text: raw, gitTags: [] };
      }
    }
    return { text: typeof raw === "string" ? raw : "", gitTags: [] };
  } catch {
    return { text: "", gitTags: [] };
  }
}

function writeComposeDraftState(agentId, sessionId, text, gitTags) {
  if (typeof window === "undefined") {
    return;
  }
  try {
    const key = agentChatComposeDraftKey(agentId, sessionId);
    const t = String(text ?? "");
    const tags = Array.isArray(gitTags) ? gitTags : [];
    const hasTags = tags.length > 0;
    if (!t.trim() && !hasTags) {
      window.localStorage.removeItem(key);
    } else if (hasTags) {
      window.localStorage.setItem(key, JSON.stringify({ v: 2, text: t, gitTags: tags }));
    } else {
      window.localStorage.setItem(key, t);
    }
  } catch {
    // ignore quota / private mode
  }
}

function workspaceChangesMarkdown(batch) {
  const changes = Array.isArray(batch?.changes) ? batch.changes : [];
  const lines = changes
    .map((change) => {
      const kind = String(change?.kind || "modified");
      const path = String(change?.path || "").trim();
      if (!path) return "";
      const size = typeof change?.sizeBytes === "number" ? ` (${change.sizeBytes} bytes)` : "";
      return `- ${kind}: ${path}${size}`;
    })
    .filter(Boolean);
  return [
    "[Workspace changes]",
    `Project: ${String(batch?.projectId || "")}`,
    ...lines
  ].join("\n");
}

function removeAgentChatComposeDraft(agentId, sessionId) {
  if (typeof window === "undefined") {
    return;
  }
  try {
    window.localStorage.removeItem(agentChatComposeDraftKey(agentId, sessionId));
  } catch {
    // ignore
  }
}

function normalizeTaskReference(value) {
  return String(value || "").trim();
}

function normalizeTaskRecord(record) {
  const projectId = String(record?.projectId || "").trim();
  const projectName = String(record?.projectName || projectId || "Project").trim() || "Project";
  const task = record?.task && typeof record.task === "object" ? record.task : {};
  const reference = normalizeTaskReference(task?.id);

  if (!reference) {
    return null;
  }

  const title = String(task?.title || reference).trim() || reference;
  const status = String(task?.status || "unknown").trim() || "unknown";
  const priority = String(task?.priority || "").trim();
  const claimedAgentId = String(task?.claimedAgentId || "").trim();
  const claimedActorId = String(task?.claimedActorId || "").trim();
  const actorId = String(task?.actorId || "").trim();
  const teamId = String(task?.teamId || "").trim();
  const assignee = claimedAgentId || claimedActorId || actorId || teamId || "";
  const description = String(task?.description || "").trim();
  const updatedAt = task?.updatedAt || task?.createdAt || null;
  const searchText = `${reference} ${title} ${projectId} ${projectName} ${status} ${assignee}`.toLowerCase();

  return {
    reference,
    referenceLower: reference.toLowerCase(),
    projectId,
    projectName,
    title,
    status,
    priority,
    assignee,
    description,
    updatedAt,
    searchText
  };
}

function normalizeTaskRecordsFromProjects(projects) {
  if (!Array.isArray(projects)) {
    return [];
  }

  const items = [];
  for (const project of projects) {
    const projectId = String(project?.id || "").trim();
    const projectName = String(project?.name || projectId || "Project").trim() || "Project";
    const tasks = Array.isArray(project?.tasks) ? project.tasks : [];
    for (const task of tasks) {
      const normalized = normalizeTaskRecord({
        projectId,
        projectName,
        task
      });
      if (normalized) {
        items.push(normalized);
      }
    }
  }

  return items;
}

function parseDateValue(value) {
  const date = new Date(value || 0).getTime();
  if (Number.isNaN(date)) {
    return 0;
  }
  return date;
}

function mergeTaskRecords(previous, incoming) {
  const map = new Map();

  for (const item of previous) {
    if (item?.referenceLower) {
      map.set(item.referenceLower, item);
    }
  }
  for (const item of incoming) {
    if (item?.referenceLower) {
      map.set(item.referenceLower, item);
    }
  }

  return [...map.values()].sort((left, right) => {
    const dateDiff = parseDateValue(right.updatedAt) - parseDateValue(left.updatedAt);
    if (dateDiff !== 0) {
      return dateDiff;
    }
    return left.reference.localeCompare(right.reference, undefined, { sensitivity: "base" });
  });
}

function collectTaskLinkSpans(text) {
  const spans = [];

  TASK_TAG_PATTERN.lastIndex = 0;
  let match = TASK_TAG_PATTERN.exec(text);
  while (match) {
    const full = match[0];
    const start = match.index;
    const end = start + full.length;
    const previousChar = start > 0 ? text[start - 1] : "";
    if (!previousChar || !/[A-Za-z0-9_-]/.test(previousChar)) {
      spans.push({
        start,
        end,
        reference: normalizeTaskReference(match[1]),
        value: full
      });
    }
    match = TASK_TAG_PATTERN.exec(text);
  }

  TASK_ID_LABEL_PATTERN.lastIndex = 0;
  match = TASK_ID_LABEL_PATTERN.exec(text);
  while (match) {
    spans.push({
      start: match.index,
      end: match.index + match[0].length,
      reference: normalizeTaskReference(match[1]),
      value: match[0]
    });
    match = TASK_ID_LABEL_PATTERN.exec(text);
  }

  TASK_TITLE_PREFIX_PATTERN.lastIndex = 0;
  match = TASK_TITLE_PREFIX_PATTERN.exec(text);
  while (match) {
    spans.push({
      start: match.index,
      end: match.index + match[0].length,
      reference: normalizeTaskReference(match[1]),
      value: match[0]
    });
    match = TASK_TITLE_PREFIX_PATTERN.exec(text);
  }

  spans.sort((a, b) => a.start - b.start || b.end - b.start - (a.end - a.start));
  const merged = [];
  let coverUntil = -1;
  for (let i = 0; i < spans.length; i += 1) {
    const s = spans[i];
    if (s.start < coverUntil) {
      continue;
    }
    merged.push(s);
    coverUntil = s.end;
  }
  return merged;
}

function splitTextByTaskTags(value) {
  const text = String(value || "");
  if (!text) {
    return [{ kind: "text", value: "" }];
  }

  const spans = collectTaskLinkSpans(text);
  if (spans.length === 0) {
    return [{ kind: "text", value: text }];
  }

  const parts = [];
  let cursor = 0;
  for (let i = 0; i < spans.length; i += 1) {
    const s = spans[i];
    if (s.start > cursor) {
      parts.push({ kind: "text", value: text.slice(cursor, s.start) });
    }
    parts.push({ kind: "task", reference: s.reference, value: s.value });
    cursor = s.end;
  }
  if (cursor < text.length) {
    parts.push({ kind: "text", value: text.slice(cursor) });
  }

  return parts.length > 0 ? parts : [{ kind: "text", value: text }];
}

function getTaskQueryAtCursor(value, caret) {
  const text = String(value || "");
  const safeCaret = Math.max(0, Math.min(Number.isFinite(caret) ? caret : text.length, text.length));
  const hashIndex = text.lastIndexOf("#", Math.max(0, safeCaret - 1));

  if (hashIndex < 0) {
    return null;
  }

  const charBeforeHash = hashIndex > 0 ? text[hashIndex - 1] : "";
  if (charBeforeHash && !/\s|[([{'"`]/.test(charBeforeHash)) {
    return null;
  }

  const queryBeforeCaret = text.slice(hashIndex + 1, safeCaret);
  if (/\s/.test(queryBeforeCaret)) {
    return null;
  }

  let tokenEnd = safeCaret;
  while (tokenEnd < text.length && !/\s/.test(text[tokenEnd])) {
    tokenEnd += 1;
  }

  const fullTokenValue = text.slice(hashIndex + 1, tokenEnd);
  if (!TASK_TAG_QUERY_VALUE_PATTERN.test(fullTokenValue)) {
    return null;
  }

  return {
    start: hashIndex,
    end: tokenEnd,
    query: queryBeforeCaret
  };
}

function getSlashCommandAtCursor(value, caret) {
  const text = String(value || "");
  const safeCaret = Math.max(0, Math.min(Number.isFinite(caret) ? caret : text.length, text.length));
  const slashIndex = text.lastIndexOf("/", Math.max(0, safeCaret - 1));

  if (slashIndex < 0) {
    return null;
  }

  const charBeforeSlash = slashIndex > 0 ? text[slashIndex - 1] : "";
  if (charBeforeSlash && !/\s/.test(charBeforeSlash)) {
    return null;
  }

  const queryBeforeCaret = text.slice(slashIndex + 1, safeCaret);
  if (/\s/.test(queryBeforeCaret)) {
    return null;
  }

  let tokenEnd = safeCaret;
  while (tokenEnd < text.length && !/\s/.test(text[tokenEnd])) {
    tokenEnd += 1;
  }

  const fullTokenValue = text.slice(slashIndex + 1, tokenEnd);
  if (!/^[a-z0-9_-]*$/i.test(fullTokenValue)) {
    return null;
  }

  return {
    start: slashIndex,
    end: tokenEnd,
    query: queryBeforeCaret
  };
}

function getPathQueryAtCursor(value, caret) {
  const text = String(value || "");
  const safeCaret = Math.max(0, Math.min(Number.isFinite(caret) ? caret : text.length, text.length));
  const atIndex = text.lastIndexOf("@", Math.max(0, safeCaret - 1));

  if (atIndex < 0) {
    return null;
  }

  const charBeforeAt = atIndex > 0 ? text[atIndex - 1] : "";
  if (charBeforeAt && !/\s/.test(charBeforeAt)) {
    return null;
  }

  const queryBeforeCaret = text.slice(atIndex + 1, safeCaret);
  if (/\s/.test(queryBeforeCaret)) {
    return null;
  }

  let tokenEnd = safeCaret;
  while (tokenEnd < text.length && !/\s/.test(text[tokenEnd])) {
    tokenEnd += 1;
  }

  const fullTokenValue = text.slice(atIndex + 1, tokenEnd);
  if (!PATH_AT_QUERY_VALUE_PATTERN.test(fullTokenValue)) {
    return null;
  }

  return {
    start: atIndex,
    end: tokenEnd,
    query: queryBeforeCaret
  };
}

function findBackwardTaskTag(value, caret) {
  const text = String(value || "");
  const safeCaret = Math.max(0, Math.min(Number.isFinite(caret) ? caret : text.length, text.length));
  const beforeCaret = text.slice(0, safeCaret);
  const match = beforeCaret.match(TASK_TAG_REMOVE_PATTERN);
  if (!match) {
    return null;
  }

  const prefix = match[1] || "";
  const full = match[0];
  const reference = normalizeTaskReference(match[2]);
  const start = beforeCaret.length - full.length + prefix.length;
  const end = beforeCaret.length;

  return {
    start,
    end,
    reference
  };
}

function findBackwardSlashCommand(value, caret, allowedNames) {
  const text = String(value || "");
  const safeCaret = Math.max(0, Math.min(Number.isFinite(caret) ? caret : text.length, text.length));
  const beforeCaret = text.slice(0, safeCaret);
  const match = beforeCaret.match(SLASH_CMD_REMOVE_PATTERN);
  if (!match) {
    return null;
  }

  const prefix = match[1] || "";
  const full = match[0];
  const commandValue = match[2];
  const name = commandValue.slice(1);
  const allowed =
    allowedNames instanceof Set ? allowedNames : new Set(Array.isArray(allowedNames) ? allowedNames : []);
  if (!allowed.has(name.toLowerCase())) {
    return null;
  }

  const start = beforeCaret.length - full.length + prefix.length;
  const end = beforeCaret.length;

  return { start, end, name };
}

function splitTextBySlashCommands(value, allowedNames) {
  const text = String(value || "");
  if (!text) {
    return [{ kind: "text", value: "" }];
  }

  const parts = [];
  let cursor = 0;
  const allowed =
    allowedNames instanceof Set ? allowedNames : new Set(Array.isArray(allowedNames) ? allowedNames : []);

  SLASH_CMD_INLINE_PATTERN.lastIndex = 0;
  let match = SLASH_CMD_INLINE_PATTERN.exec(text);
  while (match) {
    const full = match[0];
    const name = match[1];
    const start = match.index;
    const end = start + full.length;
    const previousChar = start > 0 ? text[start - 1] : "";

    if (previousChar && !/\s/.test(previousChar)) {
      match = SLASH_CMD_INLINE_PATTERN.exec(text);
      continue;
    }

    if (!allowed.has(name.toLowerCase())) {
      match = SLASH_CMD_INLINE_PATTERN.exec(text);
      continue;
    }

    if (start > cursor) {
      parts.push({ kind: "text", value: text.slice(cursor, start) });
    }

    parts.push({ kind: "command", name, value: full });
    cursor = end;
    match = SLASH_CMD_INLINE_PATTERN.exec(text);
  }

  if (cursor < text.length) {
    parts.push({ kind: "text", value: text.slice(cursor) });
  }

  return parts.length > 0 ? parts : [{ kind: "text", value: text }];
}

function splitTextByFileRefs(value) {
  const text = String(value || "");
  if (!text) {
    return [{ kind: "text", value: "" }];
  }

  const parts = [];
  let cursor = 0;
  FILE_REF_INLINE_PATTERN.lastIndex = 0;
  let match = FILE_REF_INLINE_PATTERN.exec(text);
  while (match) {
    const full = match[0];
    const path = match[1];
    const start = match.index;
    const end = start + full.length;
    const previousChar = start > 0 ? text[start - 1] : "";

    if (previousChar && !/\s|[([{'"`]/.test(previousChar)) {
      match = FILE_REF_INLINE_PATTERN.exec(text);
      continue;
    }

    if (start > cursor) {
      parts.push({ kind: "text", value: text.slice(cursor, start) });
    }
    parts.push({ kind: "file", path, value: full });
    cursor = end;
    match = FILE_REF_INLINE_PATTERN.exec(text);
  }

  if (cursor < text.length) {
    parts.push({ kind: "text", value: text.slice(cursor) });
  }
  return parts.length > 0 ? parts : [{ kind: "text", value: text }];
}

function filterSlashCommandSuggestions(commands, query, limit = 8) {
  const normalizedQuery = String(query || "").trim().toLowerCase();
  return commands
    .filter((cmd) => {
      if (!normalizedQuery) {
        return true;
      }
      return cmd.name.toLowerCase().includes(normalizedQuery);
    })
    .sort((a, b) => {
      if (!normalizedQuery) {
        return 0;
      }
      const aStarts = a.name.toLowerCase().startsWith(normalizedQuery);
      const bStarts = b.name.toLowerCase().startsWith(normalizedQuery);
      if (aStarts && !bStarts) {
        return -1;
      }
      if (!aStarts && bStarts) {
        return 1;
      }
      return a.name.localeCompare(b.name);
    })
    .slice(0, limit);
}

function scoreTaskSuggestion(task, queryLower) {
  if (!queryLower) {
    return 5;
  }

  const referenceLower = task.referenceLower;
  const titleLower = task.title.toLowerCase();
  if (referenceLower === queryLower) {
    return 0;
  }
  if (referenceLower.startsWith(queryLower)) {
    return 1;
  }
  if (referenceLower.includes(queryLower)) {
    return 2;
  }
  if (titleLower.startsWith(queryLower)) {
    return 3;
  }
  if (task.searchText.includes(queryLower)) {
    return 4;
  }
  return 99;
}

function filterTaskSuggestions(tasks, query, limit = 8) {
  const normalizedQuery = String(query || "").trim().toLowerCase();
  return tasks
    .map((task) => ({ task, score: scoreTaskSuggestion(task, normalizedQuery) }))
    .filter((item) => item.score < 99)
    .sort((left, right) => {
      if (left.score !== right.score) {
        return left.score - right.score;
      }
      const dateDiff = parseDateValue(right.task.updatedAt) - parseDateValue(left.task.updatedAt);
      if (dateDiff !== 0) {
        return dateDiff;
      }
      return left.task.reference.localeCompare(right.task.reference, undefined, { sensitivity: "base" });
    })
    .slice(0, limit)
    .map((item) => item.task);
}

function getTaskPreviewPosition(anchorElement) {
  if (!anchorElement || typeof anchorElement.getBoundingClientRect !== "function") {
    return {
      top: 20,
      left: 20
    };
  }

  const rect = anchorElement.getBoundingClientRect();
  const maxWidth = 340;
  const estimatedHeight = 180;
  const viewportWidth = window.innerWidth;
  const viewportHeight = window.innerHeight;
  const preferredTop = rect.bottom + 10;
  const fallbackTop = rect.top - estimatedHeight - 10;
  const top = preferredTop + estimatedHeight < viewportHeight ? preferredTop : Math.max(12, fallbackTop);
  const left = Math.max(12, Math.min(rect.left, viewportWidth - maxWidth - 12));

  return { top, left };
}

function formatEventTime(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function formatEventClockTime(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function formatElapsedSince(value, nowMs = Date.now()) {
  if (!value) {
    return "";
  }
  const startedMs = new Date(value).getTime();
  if (!Number.isFinite(startedMs)) {
    return "";
  }
  const elapsedSeconds = Math.max(0, Math.floor((nowMs - startedMs) / 1000));
  if (elapsedSeconds < 60) {
    return `${elapsedSeconds}s ago`;
  }
  const elapsedMinutes = Math.floor(elapsedSeconds / 60);
  if (elapsedMinutes < 60) {
    return `${elapsedMinutes}m ago`;
  }
  const elapsedHours = Math.floor(elapsedMinutes / 60);
  if (elapsedHours < 24) {
    const remainderMinutes = elapsedMinutes % 60;
    return remainderMinutes > 0 ? `${elapsedHours}h ${remainderMinutes}m ago` : `${elapsedHours}h ago`;
  }
  const elapsedDays = Math.floor(elapsedHours / 24);
  return `${elapsedDays}d ago`;
}

function formatTechnicalEventTime(value, nowMs = Date.now()) {
  const clock = formatEventClockTime(value);
  const elapsed = formatElapsedSince(value, nowMs);
  if (clock && elapsed) {
    return `${clock} · ${elapsed}`;
  }
  return clock || elapsed;
}

function formatFullEventDateTime(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return date.toLocaleString();
}

function latestRespondingTextFromEvents(events) {
  const latest = [...(Array.isArray(events) ? events : [])]
    .reverse()
    .find(
      (eventItem) =>
        eventItem?.type === "run_status" &&
        eventItem?.runStatus?.stage === "responding" &&
        typeof eventItem?.runStatus?.expandedText === "string" &&
        eventItem.runStatus.expandedText.length > 0
    );
  return latest?.runStatus?.expandedText || "";
}

async function encodeFileBase64(file) {
  const buffer = await file.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";
  for (let index = 0; index < bytes.length; index += chunkSize) {
    const chunk = bytes.subarray(index, index + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

function isUserCreatedSession(session) {
  const title = String(session?.title || "").trim();
  return !title.startsWith("task-comment:");
}

/**
 * When scopedProjectId is set (project chat), keep only sessions for that project.
 * If `serverListFromProjectQuery` is true, the list came from GET .../sessions?projectId=…
 * (already filtered server-side) — do not drop rows missing `projectId` on each item.
 */
function sessionMatchesProjectScope(session, scopedProjectId, serverListFromProjectQuery = false) {
  const scope = typeof scopedProjectId === "string" ? scopedProjectId.trim() : "";
  if (!scope) {
    return true;
  }
  if (serverListFromProjectQuery) {
    return true;
  }
  const raw = session?.projectId ?? session?.project_id;
  const pid = typeof raw === "string" ? raw.trim() : String(raw || "").trim();
  if (!pid) {
    return false;
  }
  return pid.toLowerCase() === scope.toLowerCase();
}

function isTaskSession(session) {
  const title = String(session?.title || "").trim();
  return title.startsWith("task-");
}

function sortSessionsByUpdate(list) {
  return [...list].sort((left, right) => {
    const leftDate = new Date(left?.updatedAt || 0).getTime();
    const rightDate = new Date(right?.updatedAt || 0).getTime();
    return rightDate - leftDate;
  });
}

function getSessionDisplayLabel(session) {
  const title = String(session?.title || "").trim();
  const preview = String(session?.lastMessagePreview || "").trim();
  const isDefaultTitle = /^Session\s+session-/i.test(title);
  if (isDefaultTitle && preview) {
    return preview.length > 80 ? `${preview.slice(0, 80)}...` : preview;
  }
  return title || preview || "Session";
}

function sessionMatchesSidebarSearch(session, queryLower) {
  const q = typeof queryLower === "string" ? queryLower.trim().toLowerCase() : "";
  if (!q) {
    return true;
  }
  const label = getSessionDisplayLabel(session);
  const haystack = `${label} ${String(session?.id || "")} ${String(session?.title || "")} ${String(session?.lastMessagePreview || "")}`
    .toLowerCase()
    .replace(/\s+/g, " ");
  const tokens = q.split(/\s+/).filter(Boolean);
  return tokens.every((t) => haystack.includes(t));
}

const SESSION_SIDEBAR_RECENT_DAYS = 3;
const SESSION_SIDEBAR_RECENT_MS = SESSION_SIDEBAR_RECENT_DAYS * 24 * 60 * 60 * 1000;

function getSessionListActivityTime(session) {
  const raw = session?.updatedAt ?? session?.createdAt;
  const ms = new Date(raw || 0).getTime();
  return Number.isFinite(ms) ? ms : 0;
}

function isSessionSidebarRecent(session) {
  const ms = getSessionListActivityTime(session);
  if (!ms) {
    return true;
  }
  return Date.now() - ms < SESSION_SIDEBAR_RECENT_MS;
}

function splitSessionsRecentAndPast(sessions) {
  const recent = [];
  const past = [];
  for (const s of sessions) {
    if (isSessionSidebarRecent(s)) {
      recent.push(s);
    } else {
      past.push(s);
    }
  }
  return { recent, past };
}

function isActiveRunStage(stage) {
  const value = String(stage || "").trim().toLowerCase();
  return value === "thinking" || value === "searching" || value === "responding";
}

function isTerminalRunStage(stage) {
  const value = String(stage || "").trim().toLowerCase();
  return value === "done" || value === "interrupted";
}

function extractEventKey(event, index) {
  return event?.id || `${event?.type || "event"}-${index}`;
}

function previewText(value, fallback = "No details") {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  if (!normalized) {
    return fallback;
  }
  if (normalized.length > 100) {
    return `${normalized.slice(0, 100)}...`;
  }
  return normalized;
}

const OAUTH_ERROR_PATTERNS = [
  "oauth token is invalid",
  "oauth token is expired",
  "oauth token does not have required permissions",
  "oauth authentication error"
];

function containsOAuthError(text) {
  if (!text) {
    return false;
  }
  const lower = String(text).toLowerCase();
  return OAUTH_ERROR_PATTERNS.some((pattern) => lower.includes(pattern));
}

function isToolApprovalRecord(record) {
  const title = String(record?.title || "").toLowerCase();
  const summary = String(record?.summary || "").toLowerCase();
  const detail = String(record?.detail || "").toLowerCase();
  return title.includes("tool approval required") ||
    summary.includes("tool approval required") ||
    detail.includes("tool approval required");
}

function navigateToOAuthSettings() {
  window.history.pushState({}, "", "/config/providers");
  window.dispatchEvent(new PopStateEvent("popstate"));
}

function formatStructuredData(value) {
  if (value == null) {
    return "";
  }
  if (typeof value === "string") {
    return value;
  }
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function findPendingToolCallRecordIds(events) {
  const openCallsByTool = new Map();
  const pendingRecordIds = new Set();

  for (let index = 0; index < (Array.isArray(events) ? events.length : 0); index += 1) {
    const eventItem = events[index];

    if (eventItem?.type === "run_status" && isTerminalRunStage(eventItem.runStatus?.stage)) {
      openCallsByTool.clear();
      pendingRecordIds.clear();
      continue;
    }

    if (eventItem?.type === "tool_call" && eventItem.toolCall) {
      const toolName = String(eventItem.toolCall.tool || "").trim();
      const recordId = `${extractEventKey(eventItem, index)}-tool-call`;
      pendingRecordIds.add(recordId);
      if (!openCallsByTool.has(toolName)) {
        openCallsByTool.set(toolName, []);
      }
      openCallsByTool.get(toolName).push(recordId);
      continue;
    }

    if (eventItem?.type === "tool_result" && eventItem.toolResult) {
      const toolName = String(eventItem.toolResult.tool || "").trim();
      const queue = openCallsByTool.get(toolName) || [];
      const matchedRecordId = queue.shift();
      if (queue.length === 0) {
        openCallsByTool.delete(toolName);
      } else {
        openCallsByTool.set(toolName, queue);
      }
      if (matchedRecordId) {
        pendingRecordIds.delete(matchedRecordId);
      }
    }
  }

  return pendingRecordIds;
}

/**
 * Shimmer on "Executing tool" (run_status stage searching) only while that tool round is still in flight.
 * Stale searching rows stay in the log after newer run_status / tool_result — they must not look active.
 */
function isSearchingRunStatusShimmerActive(events, eventIndex, stage) {
  if (String(stage || "").toLowerCase() !== "searching") {
    return false;
  }
  const safe = Array.isArray(events) ? events : [];
  const currentStatus = safe[eventIndex]?.runStatus;
  if (String(currentStatus?.label || "").toLowerCase() !== "executing tool") {
    return false;
  }
  let lastRunStatusIdx = -1;
  for (let i = safe.length - 1; i >= 0; i -= 1) {
    const ev = safe[i];
    if (ev?.type === "run_status" && ev.runStatus) {
      lastRunStatusIdx = i;
      break;
    }
  }
  if (eventIndex !== lastRunStatusIdx) {
    return false;
  }
  const lastEv = safe[lastRunStatusIdx];
  if (String(lastEv?.runStatus?.stage || "").toLowerCase() !== "searching") {
    return false;
  }
  let sawToolCall = false;
  for (let j = eventIndex + 1; j < safe.length; j += 1) {
    const t = safe[j]?.type;
    if (t === "tool_call") {
      sawToolCall = true;
    } else if (t === "tool_result" && sawToolCall) {
      return false;
    }
  }
  return sawToolCall;
}

function buildTechnicalRecord(
  eventItem,
  index,
  options: { activeToolCallRecordIds?: Set<string>; events?: unknown[] } = {}
) {
  const { activeToolCallRecordIds, events: eventsForActive } = options;
  const eventKey = extractEventKey(eventItem, index);

  if (eventItem?.type === "run_status" && eventItem.runStatus) {
    const stage = String(eventItem.runStatus.stage || "").toLowerCase();
    if (stage === "responding" || stage === "done" || stage === "thinking") {
      return null;
    }

    const label = eventItem.runStatus.label || eventItem.runStatus.stage || "Status";
    const summary = eventItem.runStatus.details || eventItem.runStatus.expandedText || label;
    const detailParts = [];
    if (eventItem.runStatus.stage) {
      detailParts.push(`Stage: ${eventItem.runStatus.stage}`);
    }
    if (eventItem.runStatus.details) {
      detailParts.push(eventItem.runStatus.details);
    }
    if (eventItem.runStatus.expandedText) {
      detailParts.push(eventItem.runStatus.expandedText);
    }

    return {
      id: `${eventKey}-run-status`,
      icon: "progress_activity",
      title: label,
      summary: previewText(summary, label),
      detail: detailParts.join("\n\n"),
      createdAt: eventItem.createdAt || eventItem.runStatus.createdAt,
      isActive: isSearchingRunStatusShimmerActive(eventsForActive, index, stage)
    };
  }

  if (eventItem?.type === "run_control" && eventItem.runControl) {
    const action = eventItem.runControl.action || "control";
    const title = `Control: ${action}`;
    const detail = `Action: ${action}\nRequested by: ${eventItem.runControl.requestedBy || "unknown"}${eventItem.runControl.reason ? `\nReason: ${eventItem.runControl.reason}` : ""
      }`;

    return {
      id: `${eventKey}-run-control`,
      icon: "tune",
      title,
      summary: previewText(eventItem.runControl.reason, title),
      detail,
      createdAt: eventItem.createdAt
    };
  }

  if (eventItem?.type === "tool_call" && eventItem.toolCall) {
    const reason = String(eventItem.toolCall.reason || "").trim();
    const argumentsText = formatStructuredData(eventItem.toolCall.arguments);
    const detail = `${reason ? `Reason: ${reason}\n\n` : ""}Arguments:\n${argumentsText || "{}"}`;

    return {
      id: `${eventKey}-tool-call`,
      icon: "terminal",
      title: `Tool call: ${eventItem.toolCall.tool || "tool"}`,
      summary: previewText(reason || argumentsText, "Tool call"),
      detail,
      createdAt: eventItem.createdAt,
      isActive: activeToolCallRecordIds?.has(`${eventKey}-tool-call`) || false
    };
  }

  if (eventItem?.type === "tool_result" && eventItem.toolResult) {
    const statusText = eventItem.toolResult.ok ? "success" : "failed";
    const dataText = formatStructuredData(eventItem.toolResult.data);
    const errorText = formatStructuredData(eventItem.toolResult.error);
    const parts = [`Status: ${statusText}`];
    if (Number.isFinite(eventItem.toolResult.durationMs)) {
      parts.push(`Duration: ${eventItem.toolResult.durationMs} ms`);
    }
    if (dataText) {
      parts.push(`Data:\n${dataText}`);
    }
    if (errorText) {
      parts.push(`Error:\n${errorText}`);
    }

    return {
      id: `${eventKey}-tool-result`,
      icon: eventItem.toolResult.ok ? "check_circle" : "error",
      title: `Tool result: ${eventItem.toolResult.tool || "tool"}`,
      summary: previewText(errorText || dataText, `Result: ${statusText}`),
      detail: parts.join("\n\n"),
      createdAt: eventItem.createdAt
    };
  }

  if (eventItem?.type === "sub_session" && eventItem.subSession) {
    const childSessionId = String(eventItem.subSession.childSessionId || "").trim();
    const title = eventItem.subSession.title || "Sub-session";
    return {
      id: `${eventKey}-sub-session`,
      icon: "call_split",
      title,
      summary: previewText(childSessionId, "Session created"),
      detail: `Session: ${childSessionId}\nTitle: ${title}`,
      createdAt: eventItem.createdAt,
      childSessionId
    };
  }

  return null;
}

function answeredInputRequestIds(events) {
  return new Set(
    (Array.isArray(events) ? events : [])
      .filter((eventItem) => eventItem?.type === "input_response" && eventItem?.inputResponse?.requestId)
      .map((eventItem) => String(eventItem.inputResponse.requestId))
  );
}

function segmentsToPlainText(segments) {
  return (segments || [])
    .map((segment) => {
      if (segment.kind === "text") {
        return String(segment.text || "").trim();
      }
      if (segment.kind === "attachment" && segment.attachment?.name) {
        return `[Attachment: ${segment.attachment.name}]`;
      }
      return "";
    })
    .filter(Boolean)
    .join("\n")
    .trim();
}

function TaskTaggedText({ text, onTaskTagClick, onTaskTagHoverStart, onTaskTagHoverEnd }) {
  const parts = useMemo(() => splitTextByTaskTags(text), [text]);

  return (
    <>
      {parts.map((part, index) => {
        if (part.kind === "task") {
          return (
            <button
              key={`task-${part.reference}-${index}`}
              type="button"
              className="agent-chat-task-tag"
              onClick={() => onTaskTagClick(part.reference)}
              onMouseEnter={(event) => onTaskTagHoverStart(part.reference, event.currentTarget)}
              onMouseLeave={onTaskTagHoverEnd}
            >
              {part.value}
            </button>
          );
        }
        if (part.kind === "text") {
          const fileParts = splitTextByFileRefs(part.value);
          return (
            <React.Fragment key={`text-${index}`}>
              {fileParts.map((filePart, fileIndex) => {
                if (filePart.kind === "file") {
                  return (
                    <span
                      key={`file-${filePart.path}-${fileIndex}`}
                      className="agent-chat-file-ref"
                      title={filePart.path}
                    >
                      {filePart.value}
                    </span>
                  );
                }
                return (
                  <React.Fragment key={`file-text-${fileIndex}`}>
                    {filePart.value}
                  </React.Fragment>
                );
              })}
            </React.Fragment>
          );
        }
        return (
          <React.Fragment key={`text-${index}`}>
            {part.value}
          </React.Fragment>
        );
      })}
    </>
  );
}

function wrapMarkdownChildrenWithTaskTags(children, handlers) {
  return React.Children.map(children, (child, index) => {
    if (typeof child === "string") {
      return (
        <TaskTaggedText
          key={`mt-${index}`}
          text={child}
          onTaskTagClick={handlers.onTaskTagClick}
          onTaskTagHoverStart={handlers.onTaskTagHoverStart}
          onTaskTagHoverEnd={handlers.onTaskTagHoverEnd}
        />
      );
    }
    if (typeof child === "number" && !Number.isNaN(child)) {
      return (
        <TaskTaggedText
          key={`mtn-${index}`}
          text={String(child)}
          onTaskTagClick={handlers.onTaskTagClick}
          onTaskTagHoverStart={handlers.onTaskTagHoverStart}
          onTaskTagHoverEnd={handlers.onTaskTagHoverEnd}
        />
      );
    }
    if (React.isValidElement(child)) {
      const elType = child.type;
      const typeName = typeof elType === "string" ? elType.toLowerCase() : "";
      if (typeName === "code" || typeName === "pre") {
        return child;
      }
      const nextChildren = child.props?.children;
      if (nextChildren != null && nextChildren !== false) {
        return React.cloneElement(child, {
          ...child.props,
          key: child.key ?? `mw-${index}`,
          children: wrapMarkdownChildrenWithTaskTags(nextChildren, handlers)
        });
      }
    }
    return child;
  });
}

function buildAgentChatMarkdownComponents(handlers) {
  return {
    code(props: any) {
      const { inline, className, children, ...rest } = props;
      const match = /language-(\w+)/.exec(className || "");
      return !inline && match ? (
        <SyntaxHighlighter style={oneDark as any} language={match[1]} PreTag="div" {...rest}>
          {String(children).replace(/\n$/, "")}
        </SyntaxHighlighter>
      ) : (
        <code className={className} {...rest}>
          {children}
        </code>
      );
    },
    p({ children }) {
      return <p>{wrapMarkdownChildrenWithTaskTags(children, handlers)}</p>;
    }
  };
}

const INLINE_TASK_TAG_SELECTOR = ".agent-chat-inline-task-tag";
const INLINE_SLASH_COMMAND_SELECTOR = ".agent-chat-inline-slash-command";
const INLINE_FILE_REF_SELECTOR = ".agent-chat-inline-file-ref";

function isBlockElementNode(node) {
  return node?.nodeType === Node.ELEMENT_NODE && /^(DIV|P)$/i.test(node.tagName || "");
}

function readEditorNodeText(node) {
  if (!node) {
    return "";
  }

  if (node.nodeType === Node.TEXT_NODE) {
    return node.nodeValue || "";
  }

  if (node.nodeType !== Node.ELEMENT_NODE) {
    return "";
  }

  const element = node;
  if (element.matches(INLINE_TASK_TAG_SELECTOR)) {
    return element.dataset.rawValue || element.textContent || "";
  }
  if (element.matches(INLINE_SLASH_COMMAND_SELECTOR)) {
    return element.dataset.rawValue || element.textContent || "";
  }
  if (element.matches(INLINE_FILE_REF_SELECTOR)) {
    return element.dataset.rawValue || element.textContent || "";
  }
  if (element.tagName === "BR") {
    return "\n";
  }

  const children = Array.from(element.childNodes || []);
  let text = "";
  for (let index = 0; index < children.length; index += 1) {
    const child = children[index];
    text += readEditorNodeText(child);
    if (isBlockElementNode(child) && index < children.length - 1) {
      text += "\n";
    }
  }
  return text;
}

function normalizeEditorText(value) {
  return String(value || "").replace(/\u00A0/g, " ");
}

function readEditorTextFromElement(root) {
  return normalizeEditorText(readEditorNodeText(root));
}

function setEditorContentFromText(root, text, slashCommandNames) {
  if (!root) {
    return;
  }

  const fragment = document.createDocumentFragment();
  const parts = splitTextByTaskTags(text);

  for (const part of parts) {
    if (part.kind === "task") {
      const tag = document.createElement("span");
      tag.className = "agent-chat-task-tag agent-chat-inline-task-tag";
      tag.setAttribute("contenteditable", "false");
      tag.dataset.taskReference = part.reference;
      tag.dataset.rawValue = part.value;
      tag.textContent = part.value;
      fragment.appendChild(tag);
    } else if (part.value) {
      const subParts = splitTextBySlashCommands(part.value, slashCommandNames);
      for (const sub of subParts) {
        if (sub.kind === "command") {
          const cmdTag = document.createElement("span");
          cmdTag.className = "agent-chat-inline-slash-command";
          cmdTag.setAttribute("contenteditable", "false");
          cmdTag.dataset.commandName = sub.name;
          cmdTag.dataset.rawValue = sub.value;
          cmdTag.textContent = sub.value;
          fragment.appendChild(cmdTag);
        } else if (sub.value) {
          const fileParts = splitTextByFileRefs(sub.value);
          for (const filePart of fileParts) {
            if (filePart.kind === "file") {
              const fileTag = document.createElement("span");
              fileTag.className = "agent-chat-file-ref agent-chat-inline-file-ref";
              fileTag.setAttribute("contenteditable", "false");
              fileTag.dataset.path = filePart.path;
              fileTag.dataset.rawValue = filePart.value;
              fileTag.textContent = filePart.value;
              fragment.appendChild(fileTag);
            } else if (filePart.value) {
              fragment.appendChild(document.createTextNode(filePart.value));
            }
          }
        }
      }
    }
  }

  root.replaceChildren(fragment);
}

function getCaretOffsetInEditor(root) {
  const selection = window.getSelection?.();
  if (!root || !selection || selection.rangeCount === 0) {
    return 0;
  }

  const range = selection.getRangeAt(0).cloneRange();
  range.selectNodeContents(root);
  const focusNode = selection.focusNode;
  const focusOffset = selection.focusOffset;
  if (!focusNode) {
    return 0;
  }

  try {
    range.setEnd(focusNode, focusOffset);
  } catch {
    return 0;
  }

  return normalizeEditorText(range.toString()).length;
}

function setCaretOffsetInEditor(root, offset) {
  if (!root) {
    return;
  }

  const selection = window.getSelection?.();
  if (!selection) {
    return;
  }

  const range = document.createRange();
  let remaining = Math.max(0, offset);

  function setToEnd() {
    range.selectNodeContents(root);
    range.collapse(false);
  }

  function walk(node) {
    if (!node) {
      return false;
    }

    if (node.nodeType === Node.TEXT_NODE) {
      const length = (node.nodeValue || "").length;
      if (remaining <= length) {
        range.setStart(node, remaining);
        range.collapse(true);
        return true;
      }
      remaining -= length;
      return false;
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return false;
    }

    const element = node;
    if (element.matches(INLINE_TASK_TAG_SELECTOR)) {
      const length = (element.dataset.rawValue || element.textContent || "").length;
      if (remaining <= length) {
        range.setStartAfter(element);
        range.collapse(true);
        return true;
      }
      remaining -= length;
      return false;
    }

    if (element.matches(INLINE_SLASH_COMMAND_SELECTOR)) {
      const length = (element.dataset.rawValue || element.textContent || "").length;
      if (remaining <= length) {
        range.setStartAfter(element);
        range.collapse(true);
        return true;
      }
      remaining -= length;
      return false;
    }

    if (element.tagName === "BR") {
      if (remaining <= 1) {
        range.setStartAfter(element);
        range.collapse(true);
        return true;
      }
      remaining -= 1;
      return false;
    }

    const children = Array.from(element.childNodes || []);
    for (let index = 0; index < children.length; index += 1) {
      const child = children[index];
      if (walk(child)) {
        return true;
      }
      if (isBlockElementNode(child) && index < children.length - 1) {
        if (remaining <= 1) {
          range.setStartAfter(child as Node);
          range.collapse(true);
          return true;
        }
        remaining -= 1;
      }
    }

    return false;
  }

  if (!walk(root)) {
    setToEnd();
  }

  selection.removeAllRanges();
  selection.addRange(range);
}

function AgentChatExpandable({
  recordId,
  icon,
  title,
  summary,
  isExpanded,
  onToggle,
  children
}) {
  return (
    <section className={`agent-chat-expandable ${isExpanded ? "open" : ""}`}>
      <button
        type="button"
        className="agent-chat-expandable-toggle"
        onClick={() => onToggle(recordId)}
        aria-expanded={isExpanded}
      >
        <span className="agent-chat-expandable-left">
          <span className="material-symbols-rounded" aria-hidden="true">
            {icon}
          </span>
          <span className="agent-chat-expandable-copy">
            <strong>{title}</strong>
            {summary ? <small>{summary}</small> : null}
          </span>
        </span>
        <span className="material-symbols-rounded agent-chat-expandable-chevron" aria-hidden="true">
          expand_more
        </span>
      </button>
      {isExpanded ? <div className="agent-chat-expandable-body">{children}</div> : null}
    </section>
  );
}

const TECH_GROUP_THRESHOLD = 3;

function groupTimelineItems(items) {
  const result = [];
  let techBuffer = [];

  function flush(followedByAssistant, isTail = false) {
    if (techBuffer.length === 0) return;
    const shouldGroup = techBuffer.length >= TECH_GROUP_THRESHOLD && (followedByAssistant || isTail);
    if (shouldGroup) {
      result.push({
        kind: "tech-group",
        id: `tech-group-${techBuffer[0]?.id || "g"}`,
        items: [...techBuffer],
        count: techBuffer.length
      });
    } else {
      result.push(...techBuffer);
    }
    techBuffer = [];
  }

  for (const item of items) {
    if (item.kind === "technical") {
      techBuffer.push(item);
    } else {
      const isAssistant = item.kind === "message" && item.event?.message?.role === "assistant";
      flush(isAssistant);
      result.push(item);
    }
  }

  flush(false, true);
  return result;
}

function buildTimelineItems({
  events,
  activeToolCallRecordIds,
  optimisticUserEvent = null,
  optimisticAssistantText = "",
  isSending = false
}) {
  const safeEvents = Array.isArray(events) ? events : [];
  const latestRunStatus = [...safeEvents]
    .reverse()
    .find((eventItem) => eventItem.type === "run_status" && eventItem.runStatus)?.runStatus;
  const persistedMessages = safeEvents.filter(
    (eventItem) =>
      eventItem.type === "message" &&
      eventItem.message &&
      (eventItem.message.role === "user" || eventItem.message.role === "assistant")
  );
  const streamedAssistantText = isSending
    ? optimisticAssistantText
    : optimisticAssistantText || latestRespondingTextFromEvents(safeEvents);
  const latestPersistedAssistantEvent = [...persistedMessages]
    .reverse()
    .find((eventItem) => eventItem?.message?.role === "assistant");
  const latestPersistedAssistantText = latestPersistedAssistantEvent?.message?.segments
    ? segmentsToPlainText(latestPersistedAssistantEvent.message.segments)
    : "";
  const normalizedStreamedAssistantText = String(streamedAssistantText || "").trim();
  const hasDuplicatedPersistedAssistant =
    !isSending &&
    normalizedStreamedAssistantText.length > 0 &&
    normalizedStreamedAssistantText === String(latestPersistedAssistantText || "").trim();
  const isRespondingPhase = isSending || latestRunStatus?.stage === "responding";
  const shouldRenderStreamMessage =
    isRespondingPhase &&
    (normalizedStreamedAssistantText.length > 0 || isSending) &&
    !hasDuplicatedPersistedAssistant;

  const timelineItems = [];
  const answeredInputs = answeredInputRequestIds(safeEvents);
  for (let index = 0; index < safeEvents.length; index += 1) {
    const eventItem = safeEvents[index];
    if (eventItem?.type === "input_request" && eventItem.inputRequest) {
      const requestId = String(eventItem.inputRequest.id || "");
      timelineItems.push({
        id: `${extractEventKey(eventItem, index)}-input-request`,
        kind: "input_request",
        event: eventItem,
        isAnswered: answeredInputs.has(requestId)
      });
      continue;
    }

    const isChatMessage =
      eventItem?.type === "message" &&
      eventItem?.message &&
      (eventItem.message.role === "user" || eventItem.message.role === "assistant");

    if (isChatMessage) {
      timelineItems.push({
        id: extractEventKey(eventItem, index),
        kind: "message",
        event: eventItem
      });
      continue;
    }

    const technicalRecord = buildTechnicalRecord(eventItem, index, {
      activeToolCallRecordIds,
      events: safeEvents
    });
    if (technicalRecord) {
      timelineItems.push({
        id: technicalRecord.id,
        kind: "technical",
        record: technicalRecord
      });
    }
  }

  if (optimisticUserEvent) {
    timelineItems.push({
      id: extractEventKey(optimisticUserEvent, timelineItems.length),
      kind: "message",
      event: optimisticUserEvent
    });
  }

  if (shouldRenderStreamMessage) {
    const hasStreamText = normalizedStreamedAssistantText.length > 0;
    timelineItems.push({
      id: "local-assistant-stream",
      kind: "message",
      isStreaming: true,
      isWaitingForStream: !hasStreamText,
      event: {
        id: "local-assistant-stream",
        createdAt: new Date().toISOString(),
        type: "message",
        message: {
          role: "assistant",
          createdAt: new Date().toISOString(),
          segments: hasStreamText
            ? [{ kind: "text", text: streamedAssistantText }]
            : []
        }
      }
    });
  }

  return {
    timelineItems,
    latestRunStatus
  };
}

function AgentChatEvents({
  isLoadingSession,
  isSending,
  timelineItems,
  latestRunStatus,
  expandedRecordIds,
  onToggleRecord,
  onReplyToMessage,
  onCopyMessage,
  onOpenSubagent,
  getSubagentStatusLabel,
  onAnswerInputRequest,
  onTaskTagClick,
  onTaskTagHoverStart,
  onTaskTagHoverEnd
}) {
  const scrollRef = useRef(null);
  const wasNearBottomRef = useRef(true);
  const [timeNowMs, setTimeNowMs] = useState(() => Date.now());

  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const onScroll = () => {
      wasNearBottomRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    if (!scrollRef.current || !wasNearBottomRef.current) {
      return;
    }
    scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [timelineItems, isLoadingSession, isSending, latestRunStatus?.id]);

  const displayGroups = useMemo(() => groupTimelineItems(timelineItems), [timelineItems]);
  const hasActiveTechnicalRecord = useMemo(
    () => timelineItems.some((item) => item?.kind === "technical" && item?.record?.isActive),
    [timelineItems]
  );

  useEffect(() => {
    const intervalMs = isSending || hasActiveTechnicalRecord ? 1000 : 30000;
    const timer = window.setInterval(() => setTimeNowMs(Date.now()), intervalMs);
    return () => window.clearInterval(timer);
  }, [isSending, hasActiveTechnicalRecord]);

  const hasWaitingStreamIndicator = useMemo(
    () => timelineItems.some((item) => item?.kind === "message" && item?.isWaitingForStream),
    [timelineItems]
  );
  const latestThinkingMessageId = useMemo(() => {
    for (let index = timelineItems.length - 1; index >= 0; index -= 1) {
      const item = timelineItems[index];
      if (item?.kind !== "message" || item?.event?.message?.role !== "assistant") {
        continue;
      }

      const segments = Array.isArray(item.event?.message?.segments) ? item.event.message.segments : [];
      if (segments.some((segment) => segment.kind === "thinking")) {
        return item.id || extractEventKey(item.event, index);
      }
    }

    return null;
  }, [timelineItems]);

  function renderTechEntry(techItem, techIndex) {
    const record = techItem.record;
    if (!record) return null;
    const isExpanded = Boolean(expandedRecordIds[record.id]);
    const isLatestActive = Boolean(record.isActive);
    const eventTimeLabel = formatTechnicalEventTime(record.createdAt, timeNowMs);
    const eventTimeTitle = formatFullEventDateTime(record.createdAt);
    const isToolApproval = isToolApprovalRecord(record);

    if (isToolApproval) {
      return (
        <article key={techItem.id || `tech-${techIndex}`} className="agent-chat-approval-card">
          <span className="material-symbols-rounded" aria-hidden="true">
            approval
          </span>
          <div>
            <strong>{record.title || "Tool approval required"}</strong>
            <p>{record.summary || record.detail || "The upstream ACP runtime requested permission before continuing."}</p>
          </div>
        </article>
      );
    }

    return (
      <div key={techItem.id || `tech-${techIndex}`} className="agent-chat-tech-entry">
        <button
          type="button"
          className={`agent-chat-tech-trigger ${isExpanded ? "expanded" : ""} ${isLatestActive ? "shimmer" : ""}`}
          onClick={() => onToggleRecord(record.id)}
          aria-expanded={isExpanded}
        >
          <span className="agent-chat-tech-trigger-label">{record.title || "Technical event"}</span>
          {eventTimeLabel ? (
            <span className="agent-chat-tech-trigger-time" title={eventTimeTitle || eventTimeLabel}>
              {eventTimeLabel}
            </span>
          ) : null}
          <span className="material-symbols-rounded agent-chat-tech-trigger-arrow" aria-hidden="true">
            chevron_right
          </span>
        </button>
        {isExpanded ? (
          <article className="agent-chat-technical">
            <div className="agent-chat-technical-body">
              <pre className="agent-chat-expandable-pre">{record.detail || "No details."}</pre>
              {record.childSessionId ? (
                <button
                  type="button"
                  className="agent-chat-technical-link"
                  onClick={() => onOpenSubagent(record.childSessionId, record.title)}
                >
                  Open sub-session{getSubagentStatusLabel ? ` (${getSubagentStatusLabel(record.childSessionId)})` : ""}
                </button>
              ) : null}
              {containsOAuthError(record.detail) || containsOAuthError(record.summary) ? (
                <button
                  type="button"
                  className="agent-chat-oauth-reauth-button"
                  onClick={navigateToOAuthSettings}
                >
                  <span className="material-symbols-rounded" aria-hidden="true">
                    login
                  </span>
                  Reconnect OpenAI
                </button>
              ) : null}
            </div>
          </article>
        ) : null}
      </div>
    );
  }

  return (
    <div className="agent-chat-events" ref={scrollRef} data-testid="agent-chat-events">
      {isLoadingSession ? (
        <p className="placeholder-text">Loading session...</p>
      ) : displayGroups.length === 0 && !isSending ? (
        <p className="placeholder-text">No messages yet.</p>
      ) : (
        <>
          {displayGroups.map((timelineItem, index) => {
            if (timelineItem.kind === "tech-group") {
              const groupId = timelineItem.id;
              const isGroupOpen = Boolean(expandedRecordIds[groupId]);
              const isGroupActive = timelineItem.items.some((item) => item.record?.isActive);
              const latestGroupTime = timelineItem.items.reduce((latest, item) => {
                const createdAt = item?.record?.createdAt;
                const ms = createdAt ? new Date(createdAt).getTime() : 0;
                return Number.isFinite(ms) && ms > latest ? ms : latest;
              }, 0);
              const latestGroupTimeLabel = latestGroupTime > 0
                ? formatTechnicalEventTime(new Date(latestGroupTime).toISOString(), timeNowMs)
                : "";
              return (
                <div key={groupId} className="agent-chat-tech-group">
                  <button
                    type="button"
                    className={`agent-chat-tech-trigger ${isGroupOpen ? "expanded" : ""} ${isGroupActive ? "shimmer" : ""}`}
                    onClick={() => onToggleRecord(groupId)}
                    aria-expanded={isGroupOpen}
                  >
                    <span className="agent-chat-tech-trigger-label">
                      {timelineItem.count} steps
                    </span>
                    {latestGroupTimeLabel ? (
                      <span className="agent-chat-tech-trigger-time" title={formatFullEventDateTime(new Date(latestGroupTime).toISOString())}>
                        {latestGroupTimeLabel}
                      </span>
                    ) : null}
                    <span className="material-symbols-rounded agent-chat-tech-trigger-arrow" aria-hidden="true">
                      chevron_right
                    </span>
                  </button>
                  {isGroupOpen ? (
                    <div className="agent-chat-tech-group-body">
                      {timelineItem.items.map((innerItem, innerIdx) => renderTechEntry(innerItem, innerIdx))}
                    </div>
                  ) : null}
                </div>
              );
            }

            if (timelineItem.kind === "technical" && timelineItem.record) {
              return renderTechEntry(timelineItem, index);
            }

            if (timelineItem.kind === "input_request") {
              const request = timelineItem.event?.inputRequest || {};
              return (
                <PlanInputPanel
                  key={timelineItem.id}
                  request={request}
                  disabled={Boolean(timelineItem.isAnswered)}
                  onSubmit={(payload) => onAnswerInputRequest?.(String(request.id || ""), payload)}
                />
              );
            }

            const eventItem = timelineItem.event;
            const role = eventItem?.message?.role || "system";
            const eventKey = timelineItem.id || extractEventKey(eventItem, index);
            const segments = Array.isArray(eventItem?.message?.segments) ? eventItem.message.segments : [];
            const thinkingSegments = segments
              .map((segment, segmentIndex) => ({ ...segment, segmentIndex }))
              .filter((segment) => segment.kind === "thinking");
            const visibleSegments = segments.filter((segment) => segment.kind !== "thinking");
            const messageText = segmentsToPlainText(visibleSegments);
            const isWaitingForStream = Boolean(timelineItem.isWaitingForStream);
            const isStreaming = Boolean(timelineItem.isStreaming);
            const isThinkingActive = latestRunStatus?.stage === "thinking" && latestThinkingMessageId === eventKey;

            return (
              <article key={eventKey} className={`agent-chat-message ${role}${isStreaming ? " streaming" : ""}`} data-testid={`agent-chat-message-${role}-${index}`}>
                <div className="agent-chat-message-head">
                  <strong>{role}</strong>
                  <span>{formatEventTime(eventItem?.message?.createdAt || eventItem?.createdAt)}</span>
                </div>
                <div className="agent-chat-message-body">
                  {isWaitingForStream ? (
                    <div className="agent-chat-stream-indicator">
                      <span className="agent-chat-stream-dot" />
                      <span className="agent-chat-stream-dot" />
                      <span className="agent-chat-stream-dot" />
                    </div>
                  ) : null}
                  {thinkingSegments.map((segment) => {
                    const thoughtId = `${eventKey}-thinking-${segment.segmentIndex}`;
                    const thoughtText = String(segment.text || "").trim();
                    const isThoughtExpanded = Boolean(expandedRecordIds[thoughtId]);
                    return (
                      <div key={thoughtId} className="agent-chat-tech-entry">
                        <button
                          type="button"
                          className={`agent-chat-tech-trigger ${isThoughtExpanded ? "expanded" : ""} ${isThinkingActive ? "shimmer" : ""}`}
                          onClick={() => onToggleRecord(thoughtId)}
                          aria-expanded={isThoughtExpanded}
                        >
                          <span className="agent-chat-tech-trigger-label">Thinking</span>
                          <span className="material-symbols-rounded agent-chat-tech-trigger-arrow" aria-hidden="true">
                            chevron_right
                          </span>
                        </button>
                        {isThoughtExpanded ? (
                          <article className="agent-chat-technical">
                            <div className="agent-chat-technical-body">
                              <div className="markdown-body">
                                <ReactMarkdown
                                  remarkPlugins={[remarkGfm]}
                                  components={buildAgentChatMarkdownComponents({
                                    onTaskTagClick,
                                    onTaskTagHoverStart,
                                    onTaskTagHoverEnd
                                  })}
                                >
                                  {thoughtText || "No details."}
                                </ReactMarkdown>
                              </div>
                            </div>
                          </article>
                        ) : null}
                      </div>
                    );
                  })}

                  {visibleSegments.map((segment, segmentIndex) => {
                    const key = `${eventKey}-segment-${segmentIndex}`;
                    if (segment.kind === "attachment" && segment.attachment) {
                      return (
                        <div key={key} className="agent-chat-attachment">
                          <span className="material-symbols-rounded agent-chat-attachment-icon" aria-hidden="true">
                            attach_file
                          </span>
                          <div className="agent-chat-attachment-meta">
                            <strong>{segment.attachment.name}</strong>
                            <span>{segment.attachment.mimeType}</span>
                          </div>
                        </div>
                      );
                    }

                    return (
                      <div key={key} className="markdown-body">
                        <ReactMarkdown
                          remarkPlugins={[remarkGfm]}
                          components={buildAgentChatMarkdownComponents({
                            onTaskTagClick,
                            onTaskTagHoverStart,
                            onTaskTagHoverEnd
                          })}
                        >
                          {segment.text || ""}
                        </ReactMarkdown>
                      </div>
                    );
                  })}
                </div>
                {role === "assistant" && messageText ? (
                  <div className="agent-chat-message-actions">
                    <button
                      type="button"
                      className="agent-chat-action-button"
                      title="Copy"
                      onClick={() => onCopyMessage(messageText)}
                    >
                      <span className="material-symbols-rounded" aria-hidden="true">
                        content_copy
                      </span>
                    </button>
                    <button
                      type="button"
                      className="agent-chat-action-button"
                      title="Reply"
                      onClick={() =>
                        onReplyToMessage({
                          id: eventItem?.id || eventKey,
                          text: previewText(messageText, "Assistant message")
                        })
                      }
                    >
                      <span className="material-symbols-rounded" aria-hidden="true">
                        reply
                      </span>
                    </button>
                    {containsOAuthError(messageText) ? (
                      <button
                        type="button"
                        className="agent-chat-oauth-reauth-button"
                        onClick={navigateToOAuthSettings}
                      >
                        <span className="material-symbols-rounded" aria-hidden="true">
                          login
                        </span>
                        Reconnect OpenAI
                      </button>
                    ) : null}
                  </div>
                ) : null}
              </article>
            );
          })}
          {(isSending || isActiveRunStage(latestRunStatus?.stage)) && !hasWaitingStreamIndicator ? (
            <div className="agent-chat-stream-indicator" aria-label="Agent is processing">
              <span className="agent-chat-stream-dot" />
              <span className="agent-chat-stream-dot" />
              <span className="agent-chat-stream-dot" />
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}

function formatToolApprovalDate(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function formatToolApprovalArguments(value) {
  if (!value || typeof value !== "object" || Object.keys(value).length === 0) {
    return "{}";
  }
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function AgentChatToolApprovalBanner({
  approvals = [],
  resolvingId = null,
  statusText = "",
  onApprove,
  onApproveForSession,
  onReject
}) {
  if (!Array.isArray(approvals) || approvals.length === 0) {
    return null;
  }

  const approval = approvals[0];
  const isWorking = resolvingId === approval.id;
  const extraCount = Math.max(0, approvals.length - 1);

  return (
    <section className="agent-chat-tool-approval-banner" aria-label="Tool approval required">
      <div className="agent-chat-tool-approval-icon" aria-hidden="true">
        <span className="material-symbols-rounded">approval</span>
      </div>

      <div className="agent-chat-tool-approval-body">
        <div className="agent-chat-tool-approval-head">
          <strong>Tool approval required</strong>
          <span>{approval.tool || "Unknown tool"}</span>
        </div>
        <p>{approval.reason?.trim() || "The agent is waiting for permission before continuing."}</p>
        <details className="agent-chat-tool-approval-details">
          <summary>
            Arguments
            {approval.expiresAt ? ` · expires ${formatToolApprovalDate(approval.expiresAt)}` : ""}
            {extraCount > 0 ? ` · +${extraCount} more` : ""}
          </summary>
          <pre>{formatToolApprovalArguments(approval.arguments)}</pre>
        </details>
        {statusText ? <span className="agent-chat-tool-approval-status">{statusText}</span> : null}
      </div>

      <div className="agent-chat-tool-approval-actions">
        <button type="button" className="agent-chat-tool-approval-reject" onClick={() => onReject?.(approval.id)} disabled={isWorking}>
          Reject
        </button>
        <button type="button" className="agent-chat-tool-approval-session" onClick={() => onApproveForSession?.(approval.id)} disabled={isWorking}>
          Allow for this session
        </button>
        <button type="button" className="agent-chat-tool-approval-approve" onClick={() => onApprove?.(approval.id)} disabled={isWorking}>
          Approve
        </button>
      </div>
    </section>
  );
}

function AgentChatComposer({
  agentId,
  projectId = null,
  inputText,
  onInputTextChange,
  isBusy,
  isStopPending = false,
  onSend,
  onStop,
  pendingFiles,
  onRemovePendingFile,
  onAddFiles,
  gitDiffComposeTags = [],
  onRemoveGitDiffComposeTag,
  fileInputRef,
  textareaRef,
  replyTarget,
  onCancelReply,
  supportsReasoningEffort,
  reasoningEffort,
  onReasoningEffortChange,
  chatMode = DEFAULT_CHAT_MODE,
  onChatModeChange,
  availableTasks = [],
  slashCommands = [],
  onTaskTagClick,
  onTaskTagHoverStart,
  onTaskTagHoverEnd
}) {
  const canSend =
    String(inputText || "").trim().length > 0 || pendingFiles.length > 0 || gitDiffComposeTags.length > 0;
  const [caretIndex, setCaretIndex] = useState(0);
  const [isInputFocused, setIsInputFocused] = useState(false);
  const [activeSuggestionIndex, setActiveSuggestionIndex] = useState(0);
  const [activeSlashIndex, setActiveSlashIndex] = useState(0);
  const [activePathIndex, setActivePathIndex] = useState(0);
  const [pathSuggestions, setPathSuggestions] = useState<Array<{ path: string; type?: string }>>([]);
  const [pathSearchLoading, setPathSearchLoading] = useState(false);
  const [pathSearchError, setPathSearchError] = useState<string | null>(null);
  const activeChatMode = chatModeMeta(chatMode);
  const pathSearchRequestIdRef = useRef(0);
  const pendingCaretOffsetRef = useRef(null);
  const scopedProjectId = projectId && String(projectId).trim() ? String(projectId).trim() : "";
  const pathSearchProjectId = scopedProjectId || SLOPPY_PROJECTS_DIRECTORY_SCOPE_ID;

  const slashCommandNameSet = useMemo(
    () =>
      new Set(
        (Array.isArray(slashCommands) ? slashCommands : [])
          .map((c) => String(c?.name || "").trim().toLowerCase())
          .filter(Boolean)
      ),
    [slashCommands]
  );

  const taskQuery = useMemo(() => getTaskQueryAtCursor(inputText, caretIndex), [inputText, caretIndex]);
  const taskSuggestions = useMemo(
    () => filterTaskSuggestions(availableTasks, taskQuery?.query || ""),
    [availableTasks, taskQuery?.query]
  );
  const isTaskDropdownOpen = isInputFocused && Boolean(taskQuery);

  const pathQuery = useMemo(() => getPathQueryAtCursor(inputText, caretIndex), [inputText, caretIndex]);

  const slashQuery = useMemo(() => getSlashCommandAtCursor(inputText, caretIndex), [inputText, caretIndex]);
  const slashSuggestions = useMemo(
    () => filterSlashCommandSuggestions(slashCommands, slashQuery?.query || ""),
    [slashCommands, slashQuery?.query]
  );

  const isPathDropdownOpen = isInputFocused && Boolean(pathQuery) && !isTaskDropdownOpen;
  const isSlashDropdownOpen =
    isInputFocused && Boolean(slashQuery) && !isTaskDropdownOpen && !isPathDropdownOpen;
  const editorRef = textareaRef;

  useEffect(() => {
    setActiveSuggestionIndex(0);
  }, [taskQuery?.start, taskQuery?.query, taskSuggestions.length]);

  useEffect(() => {
    setActiveSlashIndex(0);
  }, [slashQuery?.start, slashQuery?.query, slashSuggestions.length]);

  useEffect(() => {
    setActivePathIndex(0);
  }, [pathQuery?.start, pathQuery?.query, pathSuggestions.length]);

  useEffect(() => {
    if (!isPathDropdownOpen || !pathQuery) {
      return;
    }
    const q = pathQuery.query ?? "";
    const requestId = pathSearchRequestIdRef.current + 1;
    pathSearchRequestIdRef.current = requestId;
    setPathSearchLoading(true);
    setPathSearchError(null);

    const timer = window.setTimeout(async () => {
      try {
        const rows = await searchProjectFiles(pathSearchProjectId, q, 50);
        if (pathSearchRequestIdRef.current !== requestId) {
          return;
        }
        setPathSuggestions(Array.isArray(rows) ? rows : []);
      } catch {
        if (pathSearchRequestIdRef.current !== requestId) {
          return;
        }
        setPathSearchError("Could not search files");
        setPathSuggestions([]);
      } finally {
        if (pathSearchRequestIdRef.current === requestId) {
          setPathSearchLoading(false);
        }
      }
    }, 200);

    return () => {
      window.clearTimeout(timer);
    };
  }, [isPathDropdownOpen, pathSearchProjectId, pathQuery?.start, pathQuery?.query]);

  useEffect(() => {
    const editor = editorRef.current;
    if (!editor) {
      return;
    }

    const currentText = readEditorTextFromElement(editor);
    if (currentText !== inputText) {
      setEditorContentFromText(editor, inputText, slashCommandNameSet);
    }

    if (pendingCaretOffsetRef.current != null) {
      const nextCaret = pendingCaretOffsetRef.current;
      pendingCaretOffsetRef.current = null;
      editor.focus();
      setCaretOffsetInEditor(editor, nextCaret);
      setCaretIndex(nextCaret);
    }
  }, [editorRef, inputText, slashCommandNameSet]);

  useEffect(() => {
    setCaretIndex((current) => {
      const max = String(inputText || "").length;
      if (current > max) {
        return max;
      }
      return current;
    });
  }, [inputText]);

  function applyInputValue(nextValue, nextCaret) {
    pendingCaretOffsetRef.current = nextCaret;
    onInputTextChange(nextValue);
  }

  function applyTaskSuggestion(task) {
    if (!taskQuery || !task?.reference) {
      return;
    }
    const before = inputText.slice(0, taskQuery.start);
    const after = inputText.slice(taskQuery.end);
    const shouldAddSpace = after.length === 0 || !/^\s/.test(after);
    const replacement = `#${task.reference}${shouldAddSpace ? " " : ""}`;
    const nextValue = `${before}${replacement}${after}`;
    const nextCaret = before.length + replacement.length;
    applyInputValue(nextValue, nextCaret);
  }

  function applySlashCommandSuggestion(command) {
    if (!slashQuery || !command?.name) {
      return;
    }
    const before = inputText.slice(0, slashQuery.start);
    const after = inputText.slice(slashQuery.end);
    const shouldAddSpace = after.length === 0 || !/^\s/.test(after);
    const replacement = `/${command.name}${shouldAddSpace ? " " : ""}`;
    const nextValue = `${before}${replacement}${after}`;
    const nextCaret = before.length + replacement.length;
    applyInputValue(nextValue, nextCaret);
  }

  function applyPathSuggestion(entry) {
    if (!pathQuery || !entry?.path) {
      return;
    }
    const rel = String(entry.path).trim();
    if (!rel) {
      return;
    }
    const before = inputText.slice(0, pathQuery.start);
    const after = inputText.slice(pathQuery.end);
    const shouldAddSpace = after.length === 0 || !/^\s/.test(after);
    const replacement = `@${rel}${shouldAddSpace ? " " : ""}`;
    const nextValue = `${before}${replacement}${after}`;
    const nextCaret = before.length + replacement.length;
    applyInputValue(nextValue, nextCaret);
  }

  function updateCaretFromEditor(target) {
    if (!target) {
      return;
    }
    const nextCaret = getCaretOffsetInEditor(target);
    setCaretIndex(nextCaret);
  }

  function findInlineTaskTagElement(target) {
    if (!(target instanceof Element)) {
      return null;
    }
    return target.closest(INLINE_TASK_TAG_SELECTOR);
  }

  function renderTaskDropdown() {
    if (!isTaskDropdownOpen) {
      return null;
    }

    return (
      <div className="agent-chat-task-dropdown" role="listbox" aria-label="Task suggestions">
        {taskSuggestions.length === 0 ? (
          <p className="agent-chat-task-dropdown-empty">No tasks found</p>
        ) : (
          taskSuggestions.map((task, index) => {
            const isActive = index === activeSuggestionIndex;
            return (
              <button
                key={task.reference}
                ref={isActive ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
                type="button"
                className={`agent-chat-task-dropdown-item ${isActive ? "active" : ""}`}
                onMouseDown={(event) => {
                  event.preventDefault();
                  applyTaskSuggestion(task);
                }}
                onMouseEnter={(event) => {
                  setActiveSuggestionIndex(index);
                  onTaskTagHoverStart(task.reference, event.currentTarget);
                }}
                onMouseLeave={onTaskTagHoverEnd}
              >
                <div className="agent-chat-task-dropdown-row">
                  <strong>#{task.reference}</strong>
                  <span>{task.status}</span>
                </div>
                <p>{task.title}</p>
                <small>
                  {task.projectName}
                  {task.assignee ? ` · ${task.assignee}` : ""}
                </small>
              </button>
            );
          })
        )}
      </div>
    );
  }

  function renderPathDropdown() {
    if (!isPathDropdownOpen) {
      return null;
    }

    return (
      <div className="agent-chat-task-dropdown" role="listbox" aria-label="Project path suggestions">
        {pathSearchError ? (
          <p className="agent-chat-task-dropdown-empty">{pathSearchError}</p>
        ) : pathSearchLoading ? (
          <p className="agent-chat-task-dropdown-empty agent-chat-path-dropdown-status">Loading…</p>
        ) : pathSuggestions.length === 0 ? (
          <p className="agent-chat-task-dropdown-empty">No paths found</p>
        ) : (
          pathSuggestions.map((entry, index) => {
            const isActive = index === activePathIndex;
            const isDir = String(entry?.type || "").toLowerCase() === "directory";
            return (
              <button
                key={`${entry.path}-${index}`}
                ref={isActive ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
                type="button"
                className={`agent-chat-task-dropdown-item ${isActive ? "active" : ""}`}
                onMouseDown={(event) => {
                  event.preventDefault();
                  applyPathSuggestion(entry);
                }}
                onMouseEnter={() => setActivePathIndex(index)}
              >
                <div className="agent-chat-task-dropdown-row agent-chat-path-dropdown-row">
                  <span className="material-symbols-rounded agent-chat-path-type-icon" aria-hidden="true">
                    {isDir ? "folder" : "description"}
                  </span>
                  <strong className="agent-chat-path-suggestion-text">@{entry.path}</strong>
                </div>
              </button>
            );
          })
        )}
      </div>
    );
  }

  function renderSlashDropdown() {
    if (!isSlashDropdownOpen) {
      return null;
    }

    return (
      <div className="agent-chat-task-dropdown" role="listbox" aria-label="Command suggestions">
        {slashSuggestions.length === 0 ? (
          <p className="agent-chat-task-dropdown-empty">No commands found</p>
        ) : (
          slashSuggestions.map((cmd, index) => {
            const isActive = index === activeSlashIndex;
            return (
              <button
                key={cmd.name}
                ref={isActive ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
                type="button"
                className={`agent-chat-task-dropdown-item ${isActive ? "active" : ""}`}
                onMouseDown={(event) => {
                  event.preventDefault();
                  applySlashCommandSuggestion(cmd);
                }}
                onMouseEnter={() => setActiveSlashIndex(index)}
              >
                <div className="agent-chat-task-dropdown-row">
                  <strong>/{cmd.name}</strong>
                </div>
                <p>{cmd.description}</p>
              </button>
            );
          })
        )}
      </div>
    );
  }

  return (
    <>
      {replyTarget ? (
        <div className="agent-chat-reply-target">
          <span className="material-symbols-rounded" aria-hidden="true">
            reply
          </span>
          <p>{replyTarget.text}</p>
          <button type="button" onClick={onCancelReply} aria-label="Cancel reply">
            <span className="material-symbols-rounded" aria-hidden="true">
              close
            </span>
          </button>
        </div>
      ) : null}

      <div className="agent-chat-compose-shell">
        {renderTaskDropdown()}
        {renderPathDropdown()}
        {renderSlashDropdown()}

        <form className="agent-chat-compose" onSubmit={onSend}>
          <input
            ref={fileInputRef}
            type="file"
            multiple
            className="agent-chat-file-input"
            onChange={(event) => {
              onAddFiles(event.target.files);
              event.target.value = "";
            }}
            disabled={isBusy}
          />

          {pendingFiles.length > 0 ? (
            <div className="agent-chat-pending-files">
              {pendingFiles.map((file, index) => (
                <button key={`${file.name}-${index}`} type="button" onClick={() => onRemovePendingFile(index)}>
                  <span className="material-symbols-rounded agent-chat-pending-file-icon" aria-hidden="true">
                    attach_file
                  </span>
                  <span>{file.name}</span>
                  <span className="material-symbols-rounded" aria-hidden="true">
                    close
                  </span>
                </button>
              ))}
            </div>
          ) : null}

          {gitDiffComposeTags.length > 0 ? (
            <div className="agent-chat-git-compose-tags" aria-label="Git diff references">
              {gitDiffComposeTags.map((tag) => (
                <span key={tag.id} className="agent-chat-git-compose-tag" title={tag.markdown}>
                  <span className="material-symbols-rounded" aria-hidden="true">
                    data_object
                  </span>
                  <span className="agent-chat-git-compose-tag__label">{tag.label}</span>
                  <button
                    type="button"
                    className="agent-chat-git-compose-tag__remove"
                    onClick={() => onRemoveGitDiffComposeTag(tag.id)}
                    aria-label="Remove diff reference"
                  >
                    <span className="material-symbols-rounded" aria-hidden="true">
                      close
                    </span>
                  </button>
                </span>
              ))}
            </div>
          ) : null}

          <div className="agent-chat-compose-row">
            <button
              type="button"
              className="agent-chat-icon-button"
              onClick={() => fileInputRef.current?.click()}
              disabled={isBusy}
              title="Attach files"
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                add
              </span>
            </button>

            <div
              ref={editorRef}
              className="agent-chat-compose-input"
              data-testid="agent-chat-compose-input"
              contentEditable={!isBusy}
              suppressContentEditableWarning
              data-placeholder={
                agentId
                  ? `Message ${agentId}… Type @ to search ${scopedProjectId ? "project files" : "files under projects"}`
                  : "Message..."
              }
              role="textbox"
              aria-multiline="true"
              onInput={(event) => {
                const nextText = readEditorTextFromElement(event.currentTarget);
                onInputTextChange(nextText);
                updateCaretFromEditor(event.currentTarget);
              }}
              onClick={(event) => {
                const tagElement = findInlineTaskTagElement(event.target);
                if (tagElement) {
                  event.preventDefault();
                  const reference = normalizeTaskReference((tagElement as HTMLElement).dataset.taskReference);
                  if (reference) {
                    onTaskTagClick(reference);
                  }
                  return;
                }
                updateCaretFromEditor(event.currentTarget);
              }}
              onMouseOver={(event) => {
                const tagElement = findInlineTaskTagElement(event.target);
                if (!tagElement) {
                  return;
                }
                const relatedElement = findInlineTaskTagElement(event.relatedTarget);
                if (relatedElement === tagElement) {
                  return;
                }
                const reference = normalizeTaskReference((tagElement as HTMLElement).dataset.taskReference);
                if (!reference) {
                  return;
                }
                onTaskTagHoverStart(reference, tagElement);
              }}
              onMouseOut={(event) => {
                const tagElement = findInlineTaskTagElement(event.target);
                if (!tagElement) {
                  return;
                }
                const relatedElement = findInlineTaskTagElement(event.relatedTarget);
                if (relatedElement === tagElement) {
                  return;
                }
                onTaskTagHoverEnd();
              }}
              onKeyUp={(event) => updateCaretFromEditor(event.currentTarget)}
              onFocus={(event) => {
                setIsInputFocused(true);
                updateCaretFromEditor(event.currentTarget);
              }}
              onBlur={() => {
                setIsInputFocused(false);
              }}
              onKeyDown={(event) => {
                const target = event.currentTarget;
                const hasSuggestions = taskSuggestions.length > 0;
                const hasPathSuggestions = pathSuggestions.length > 0;
                const hasSlashSuggestions = slashSuggestions.length > 0;

                if (isTaskDropdownOpen) {
                  if (event.key === "ArrowDown" && hasSuggestions) {
                    event.preventDefault();
                    setActiveSuggestionIndex((current) => (current + 1) % taskSuggestions.length);
                    return;
                  }

                  if (event.key === "ArrowUp" && hasSuggestions) {
                    event.preventDefault();
                    setActiveSuggestionIndex((current) => {
                      if (current <= 0) {
                        return taskSuggestions.length - 1;
                      }
                      return current - 1;
                    });
                    return;
                  }

                  if (event.key === "Enter" && hasSuggestions) {
                    event.preventDefault();
                    const selectedTask = taskSuggestions[Math.min(activeSuggestionIndex, taskSuggestions.length - 1)];
                    applyTaskSuggestion(selectedTask);
                    return;
                  }

                  if (event.key === "Tab" && hasSuggestions) {
                    event.preventDefault();
                    const selectedTask = taskSuggestions[Math.min(activeSuggestionIndex, taskSuggestions.length - 1)];
                    applyTaskSuggestion(selectedTask);
                    return;
                  }

                  if (event.key === "Escape") {
                    event.preventDefault();
                    setIsInputFocused(false);
                    target.blur();
                    return;
                  }
                }

                if (isPathDropdownOpen) {
                  if (event.key === "ArrowDown" && hasPathSuggestions && !pathSearchLoading && !pathSearchError) {
                    event.preventDefault();
                    setActivePathIndex((current) => (current + 1) % pathSuggestions.length);
                    return;
                  }

                  if (event.key === "ArrowUp" && hasPathSuggestions && !pathSearchLoading && !pathSearchError) {
                    event.preventDefault();
                    setActivePathIndex((current) => {
                      if (current <= 0) {
                        return pathSuggestions.length - 1;
                      }
                      return current - 1;
                    });
                    return;
                  }

                  if (event.key === "Enter" && hasPathSuggestions && !pathSearchLoading && !pathSearchError) {
                    event.preventDefault();
                    const selected = pathSuggestions[Math.min(activePathIndex, pathSuggestions.length - 1)];
                    applyPathSuggestion(selected);
                    return;
                  }

                  if (event.key === "Tab" && hasPathSuggestions && !pathSearchLoading && !pathSearchError) {
                    event.preventDefault();
                    const selected = pathSuggestions[Math.min(activePathIndex, pathSuggestions.length - 1)];
                    applyPathSuggestion(selected);
                    return;
                  }

                  if (event.key === "Escape") {
                    event.preventDefault();
                    setIsInputFocused(false);
                    target.blur();
                    return;
                  }
                }

                if (isSlashDropdownOpen) {
                  if (event.key === "ArrowDown" && hasSlashSuggestions) {
                    event.preventDefault();
                    setActiveSlashIndex((current) => (current + 1) % slashSuggestions.length);
                    return;
                  }

                  if (event.key === "ArrowUp" && hasSlashSuggestions) {
                    event.preventDefault();
                    setActiveSlashIndex((current) => {
                      if (current <= 0) {
                        return slashSuggestions.length - 1;
                      }
                      return current - 1;
                    });
                    return;
                  }

                  if (event.key === "Enter" && hasSlashSuggestions) {
                    event.preventDefault();
                    const selectedCmd = slashSuggestions[Math.min(activeSlashIndex, slashSuggestions.length - 1)];
                    applySlashCommandSuggestion(selectedCmd);
                    return;
                  }

                  if (event.key === "Tab" && hasSlashSuggestions) {
                    event.preventDefault();
                    const selectedCmd = slashSuggestions[Math.min(activeSlashIndex, slashSuggestions.length - 1)];
                    applySlashCommandSuggestion(selectedCmd);
                    return;
                  }

                  if (event.key === "Escape") {
                    event.preventDefault();
                    setIsInputFocused(false);
                    target.blur();
                    return;
                  }
                }

                if (event.key === "Tab" && !event.ctrlKey && !event.altKey && !event.metaKey) {
                  event.preventDefault();
                  onChatModeChange?.(nextChatMode(chatMode, event.shiftKey ? -1 : 1));
                  return;
                }

                if (
                  event.key === "Backspace" &&
                  !event.altKey &&
                  !event.ctrlKey &&
                  !event.metaKey &&
                  window.getSelection?.()?.isCollapsed
                ) {
                  const resolved = findBackwardTaskTag(inputText, getCaretOffsetInEditor(target));
                  if (resolved) {
                    event.preventDefault();
                    const nextValue = `${inputText.slice(0, resolved.start)}${inputText.slice(resolved.end)}`;
                    applyInputValue(nextValue, resolved.start);
                    return;
                  }
                  const resolvedCmd = findBackwardSlashCommand(
                    inputText,
                    getCaretOffsetInEditor(target),
                    slashCommandNameSet
                  );
                  if (resolvedCmd) {
                    event.preventDefault();
                    const nextValue = `${inputText.slice(0, resolvedCmd.start)}${inputText.slice(resolvedCmd.end)}`;
                    applyInputValue(nextValue, resolvedCmd.start);
                    return;
                  }
                }

                if (event.key === "Enter" && isPathDropdownOpen && pathSearchLoading) {
                  event.preventDefault();
                  return;
                }

                if (event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) {
                  return;
                }
                event.preventDefault();
                if (!isBusy && canSend) {
                  onSend();
                }
              }}
              onPaste={(event) => {
                event.preventDefault();
                const text = event.clipboardData?.getData("text/plain") || "";
                document.execCommand("insertText", false, text);
              }}
            />

            <div className="agent-chat-compose-right">
              <button
                type="button"
                className={`agent-chat-mode-button agent-chat-mode-button--${activeChatMode.id}`}
                onClick={() => onChatModeChange?.(nextChatMode(chatMode))}
                disabled={isBusy}
                title={`Mode: ${activeChatMode.label}. Press Tab to switch.`}
                aria-label={`Chat mode: ${activeChatMode.label}`}
              >
                <span className="material-symbols-rounded" aria-hidden="true">
                  {activeChatMode.icon}
                </span>
                <span>{activeChatMode.label}</span>
              </button>

              {supportsReasoningEffort ? (
                <label className="agent-chat-reasoning-select">
                  <span>Reasoning</span>
                  <select
                    value={reasoningEffort}
                    onChange={(event) => onReasoningEffortChange(event.target.value)}
                    disabled={isBusy}
                    aria-label="Reasoning effort"
                  >
                    <option value="low">Low</option>
                    <option value="medium">Medium</option>
                    <option value="high">High</option>
                  </select>
                </label>
              ) : null}

              <button
                type="button"
                className="agent-chat-icon-button muted"
                disabled
                title="Voice input is not available yet"
              >
                <span className="material-symbols-rounded" aria-hidden="true">
                  mic
                </span>
              </button>

              {isBusy ? (
                <button
                  type="button"
                  className="agent-chat-icon-button agent-chat-send-button danger"
                  onClick={onStop}
                  disabled={isStopPending}
                  title={isStopPending ? "Stopping..." : "Stop"}
                >
                  <span className="material-symbols-rounded" aria-hidden="true">
                    stop
                  </span>
                </button>
              ) : (
                <button
                  type="submit"
                  className="agent-chat-icon-button agent-chat-send-button"
                  data-testid="agent-chat-send"
                  disabled={!canSend}
                  title="Send"
                >
                  <span className="material-symbols-rounded" aria-hidden="true">
                    arrow_upward
                  </span>
                </button>
              )}
            </div>
          </div>
        </form>
      </div>
    </>
  );
}

const AGENT_CHAT_SIDEBAR_NARROW_MQ = "(max-width: 1000px)";

const DEBUG_SESSION_STORAGE_PREFIX = "sloppy.agentChat.debugSession";

function debugSessionStorageKey(agentId, sessionId) {
  return `${DEBUG_SESSION_STORAGE_PREFIX}:${String(agentId || "").trim()}:${String(sessionId || "").trim()}`;
}

const DEBUG_INSTRUCTIONS_APPEND_TEXT = `[Dashboard — debug instructions]
When anything fails, do not silently swallow errors. For each failure, report:
- the exact error message and stack trace if available
- the command or tool invoked and working directory (cwd) if relevant
- minimal steps to reproduce

Prefer actionable logs the user can paste into an issue.`;

const ANALYSIS_PREP_APPEND_TEXT = `[Dashboard — analysis prep]
Prepare for human/code review: list relevant file paths, note key excerpts or symbols, and call out anything suspicious. If you hit errors while gathering this, log them with full detail as above.`;

const ANALYSIS_PREP_AGENT_PROMPT =
  "Prepare this workspace/session for analysis: list the most relevant files for the current problem, give short notes per file, and surface any errors you encounter with full detail (command, cwd, stderr).";

function useTypingInterpolation() {
  const [text, setText] = useState("");
  const displayedRef = useRef("");
  const targetRef = useRef("");
  const timerRef = useRef<number | null>(null);

  const stop = useCallback(() => {
    if (timerRef.current != null && typeof window !== "undefined") {
      window.clearInterval(timerRef.current);
    }
    timerRef.current = null;
  }, []);

  const step = useCallback(() => {
    const current = displayedRef.current;
    const target = targetRef.current;
    if (current === target) {
      stop();
      return;
    }
    if (!target.startsWith(current)) {
      displayedRef.current = target;
      setText(target);
      stop();
      return;
    }

    const remaining = target.length - current.length;
    const baseChars = Math.max(1, Math.ceil((STREAM_TYPING_CHARS_PER_SECOND * STREAM_TYPING_INTERVAL_MS) / 1000));
    const catchupTicks = Math.max(1, Math.ceil(STREAM_TYPING_MAX_CATCHUP_MS / STREAM_TYPING_INTERVAL_MS));
    const catchupChars = Math.max(baseChars, Math.ceil(remaining / catchupTicks));
    const next = target.slice(0, current.length + Math.min(remaining, catchupChars));
    displayedRef.current = next;
    setText(next);
    if (next === target) {
      stop();
    }
  }, [stop]);

  const start = useCallback(() => {
    if (typeof window === "undefined") {
      displayedRef.current = targetRef.current;
      setText(targetRef.current);
      return;
    }
    if (timerRef.current == null) {
      timerRef.current = window.setInterval(step, STREAM_TYPING_INTERVAL_MS);
    }
    step();
  }, [step]);

  const setImmediate = useCallback((value) => {
    const next = String(value || "");
    stop();
    targetRef.current = next;
    displayedRef.current = next;
    setText(next);
  }, [stop]);

  const push = useCallback((value) => {
    const next = String(value || "");
    if (!next) {
      setImmediate("");
      return;
    }

    const displayed = displayedRef.current;
    if (!next.startsWith(displayed) || next.length <= displayed.length) {
      setImmediate(next);
      return;
    }

    targetRef.current = next;
    start();
  }, [setImmediate, start]);

  useEffect(() => stop, [stop]);

  return { text, push, setImmediate };
}

export function AgentChatTab({
  agentId,
  initialSessionId = null,
  projectId = null,
  onActiveSessionIdChange,
  modeStorageScope = null
}: {
  agentId: string;
  initialSessionId?: string | null;
  projectId?: string | null;
  onActiveSessionIdChange?: (sessionId: string | null) => void;
  modeStorageScope?: string | null;
}) {
  const [sessions, setSessions] = useState([]);
  const [activeSessionId, setActiveSessionId] = useState(null);
  const [activeSession, setActiveSession] = useState(null);
  const [selectedModel, setSelectedModel] = useState("");
  const [availableModels, setAvailableModels] = useState([]);
  const [isLoadingSessions, setIsLoadingSessions] = useState(true);
  const [isLoadingSession, setIsLoadingSession] = useState(false);
  const [isSending, setIsSending] = useState(false);
  const [isStopping, setIsStopping] = useState(false);
  const [isDragOver, setIsDragOver] = useState(false);
  const [inputText, setInputText] = useState("");
  const [pendingFiles, setPendingFiles] = useState([]);
  const [gitDiffComposeTags, setGitDiffComposeTags] = useState([]);
  const [statusText, setStatusText] = useState("Loading sessions...");
  const [pendingToolApprovals, setPendingToolApprovals] = useState([]);
  const [toolApprovalStatusText, setToolApprovalStatusText] = useState("");
  const [resolvingToolApprovalId, setResolvingToolApprovalId] = useState(null);
  const [optimisticUserEvent, setOptimisticUserEvent] = useState(null);
  const [replyTarget, setReplyTarget] = useState(null);
  const [reasoningEffort, setReasoningEffort] = useState(DEFAULT_REASONING_EFFORT);
  const [chatMode, setChatMode] = useState(() => readStoredChatMode(agentId, projectId, modeStorageScope));
  const [expandedRecordIds, setExpandedRecordIds] = useState({});
  const [knownTaskRecords, setKnownTaskRecords] = useState([]);
  const [taskPreview, setTaskPreview] = useState(null);
  const [isShareMenuOpen, setIsShareMenuOpen] = useState(false);
  const [isDebugMenuOpen, setIsDebugMenuOpen] = useState(false);
  const [gitPanelOpen, setGitPanelOpen] = useState(false);
  const [gitBadge, setGitBadge] = useState(null);
  const [projectChangeBatch, setProjectChangeBatch] = useState(null);
  const [isMobileSidebarOpen, setIsMobileSidebarOpen] = useState(false);
  const [isDesktopSessionsCollapsed, setIsDesktopSessionsCollapsed] = useState(false);
  const [sessionSidebarSearch, setSessionSidebarSearch] = useState("");
  const [sessionPastTasksOpen, setSessionPastTasksOpen] = useState(false);
  const [sessionPastRegularOpen, setSessionPastRegularOpen] = useState(false);
  const [isModelDropdownOpen, setIsModelDropdownOpen] = useState(false);
  const [modelSearch, setModelSearch] = useState("");
  const [isNarrowChatViewport, setIsNarrowChatViewport] = useState(() =>
    typeof window !== "undefined" ? window.matchMedia(AGENT_CHAT_SIDEBAR_NARROW_MQ).matches : false
  );
  const [isDebugSessionFlagOn, setIsDebugSessionFlagOn] = useState(false);
  const [tasksDirectoryOpen, setTasksDirectoryOpen] = useState(false);
  const [subagentPanel, setSubagentPanel] = useState({
    isOpen: false,
    sessionId: "",
    title: "",
    loading: false,
    error: "",
    status: "idle"
  });
  const [subagentSession, setSubagentSession] = useState(null);
  const [subagentExpandedRecordIds, setSubagentExpandedRecordIds] = useState({});
  const {
    text: optimisticAssistantText,
    push: pushOptimisticAssistantText,
    setImmediate: setOptimisticAssistantTextImmediate
  } = useTypingInterpolation();
  const {
    text: subagentOptimisticAssistantText,
    push: pushSubagentOptimisticAssistantText,
    setImmediate: setSubagentOptimisticAssistantTextImmediate
  } = useTypingInterpolation();
  const fileInputRef = useRef(null);
  const composeInputRef = useRef(null);
  const shareMenuRef = useRef(null);
  const debugMenuRef = useRef(null);
  const modelPickerRef = useRef<HTMLDivElement | null>(null);
  const runStateRef = useRef({ sessionId: null, abortController: null });
  const streamCleanupRef = useRef(() => { });
  const subagentStreamCleanupRef = useRef(() => { });
  const activeSessionIdRef = useRef(null);
  /** Latest session id from route; bootstrap reads this after async fetch without re-running when URL updates. */
  const initialSessionIdRef = useRef(null);
  initialSessionIdRef.current = initialSessionId;
  const prevAgentIdForDraftRef = useRef(agentId);
  const subagentSessionIdRef = useRef("");
  const sessionSyncRef = useRef({ sessionId: null, timerId: null, inflight: false, queued: false });
  const staleRunStatusRefreshRef = useRef("");
  /** Tracks last seen `initialSessionId` from the route so we only follow URL when it actually changes (not on sidebar clicks). */
  const prevRouteInitialSessionIdRef = useRef(undefined);
  const taskRecordCacheRef = useRef(new Map());
  const taskRecordInflightRef = useRef(new Map());
  const activeModelOption = useMemo(
    () => availableModels.find((model) => String(model?.id || "").trim() === selectedModel) || null,
    [availableModels, selectedModel]
  );
  const modelOptions = useMemo(() => {
    const selected = String(selectedModel || "").trim();
    const base = availableModels.slice();
    if (selected && !base.some((m) => m.id === selected)) {
      base.unshift({ id: selected, title: selected });
    }
    return base;
  }, [availableModels, selectedModel]);
  const filteredModelOptions = useMemo(
    () => filterModelsByQuery(modelOptions, modelSearch),
    [modelOptions, modelSearch]
  );

  const [slashCommands, setSlashCommands] = useState(() => mergeDashboardSlashCommands(null));
  const slashCommandNameSet = useMemo(
    () =>
      new Set(slashCommands.map((c) => String(c?.name || "").trim().toLowerCase()).filter(Boolean)),
    [slashCommands]
  );

  useEffect(() => {
    const aid = String(agentId || "").trim();
    if (!aid) {
      setSlashCommands(mergeDashboardSlashCommands(null));
      return;
    }
    let cancelled = false;
    fetchAgentChatSlashCommands(aid)
      .then((res) => {
        if (!cancelled) {
          setSlashCommands(mergeDashboardSlashCommands(res));
        }
      })
      .catch(() => {
        if (!cancelled) {
          setSlashCommands(mergeDashboardSlashCommands(null));
        }
      });
    return () => {
      cancelled = true;
    };
  }, [agentId]);

  const scopedProjectId =
    projectId && String(projectId).trim() ? String(projectId).trim() : "";

  const activePendingToolApprovals = useMemo(() => {
    const currentAgentId = String(agentId || "").trim();
    const currentSessionId = String(activeSessionId || "").trim();
    if (!currentAgentId) {
      return [];
    }
    return pendingToolApprovals.filter((approval) => {
      if (String(approval?.status || "pending") !== "pending") {
        return false;
      }
      if (String(approval?.agentId || "").trim() !== currentAgentId) {
        return false;
      }
      const approvalSessionId = String(approval?.sessionId || "").trim();
      return !currentSessionId || !approvalSessionId || approvalSessionId === currentSessionId;
    });
  }, [agentId, activeSessionId, pendingToolApprovals]);

  const refreshPendingToolApprovals = useCallback(async () => {
    if (!String(agentId || "").trim()) {
      setPendingToolApprovals([]);
      return;
    }
    const list = await fetchPendingToolApprovals();
    setPendingToolApprovals(Array.isArray(list) ? list : []);
  }, [agentId]);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (cancelled) return;
      try {
        await refreshPendingToolApprovals();
      } catch {
        if (!cancelled) {
          setPendingToolApprovals([]);
        }
      }
    }
    void load();
    const timerId = window.setInterval(load, 3_000);
    return () => {
      cancelled = true;
      window.clearInterval(timerId);
    };
  }, [refreshPendingToolApprovals, activeSessionId]);

  async function resolvePendingToolApproval(approvalId, approved, scope = "once") {
    if (!approvalId || resolvingToolApprovalId) {
      return;
    }
    setResolvingToolApprovalId(approvalId);
    setToolApprovalStatusText("");
    const record = approved
      ? await approveToolApproval(approvalId, scope)
      : await rejectToolApproval(approvalId);
    setResolvingToolApprovalId(null);

    if (record) {
      setPendingToolApprovals((prev) => prev.filter((approval) => approval?.id !== approvalId));
      setToolApprovalStatusText(approved && scope === "session" ? "Allowed for this session." : approved ? "Approved." : "Rejected.");
      window.setTimeout(() => setToolApprovalStatusText(""), 1_500);
    } else {
      await refreshPendingToolApprovals().catch(() => {});
      setToolApprovalStatusText("Request not found or already resolved.");
    }
  }

  useEffect(() => {
    if (typeof onActiveSessionIdChange !== "function") {
      return;
    }
    if (isLoadingSessions) {
      return;
    }
    onActiveSessionIdChange(activeSessionId);
  }, [activeSessionId, isLoadingSessions, onActiveSessionIdChange]);
  const supportsReasoningEffort = useMemo(() => {
    const capabilities = Array.isArray(activeModelOption?.capabilities) ? activeModelOption.capabilities : [];
    return capabilities.some((capability) => String(capability || "").toLowerCase() === "reasoning");
  }, [activeModelOption]);

  const taskSessions = useMemo(() => sessions.filter(isTaskSession), [sessions]);
  const regularSessions = useMemo(() => sessions.filter((s) => !isTaskSession(s)), [sessions]);

  const sessionSearchLower = useMemo(() => String(sessionSidebarSearch || "").trim().toLowerCase(), [sessionSidebarSearch]);

  const filteredTaskSessions = useMemo(
    () => taskSessions.filter((s) => sessionMatchesSidebarSearch(s, sessionSearchLower)),
    [taskSessions, sessionSearchLower]
  );
  const filteredRegularSessions = useMemo(
    () => regularSessions.filter((s) => sessionMatchesSidebarSearch(s, sessionSearchLower)),
    [regularSessions, sessionSearchLower]
  );

  const { recent: recentFilteredTaskSessions, past: pastFilteredTaskSessions } = useMemo(
    () => splitSessionsRecentAndPast(filteredTaskSessions),
    [filteredTaskSessions]
  );
  const { recent: recentFilteredRegularSessions, past: pastFilteredRegularSessions } = useMemo(
    () => splitSessionsRecentAndPast(filteredRegularSessions),
    [filteredRegularSessions]
  );

  const hasSidebarPastSessions =
    pastFilteredTaskSessions.length > 0 || pastFilteredRegularSessions.length > 0;

  /** Boolean only — avoids re-running the URL-sync effect on every session list merge (stream/SSE). */
  const urlSessionPresentInList = useMemo(() => {
    const urlRaw =
      initialSessionId != null && String(initialSessionId).trim()
        ? String(initialSessionId).trim()
        : "";
    if (!urlRaw || !agentId) {
      return false;
    }
    return sessions.some(
      (s) =>
        isUserCreatedSession(s) &&
        sessionMatchesProjectScope(s, scopedProjectId, Boolean(scopedProjectId)) &&
        s.id === urlRaw
    );
  }, [sessions, initialSessionId, scopedProjectId, agentId]);

  useEffect(() => {
    if (!scopedProjectId) {
      setGitBadge(null);
      return;
    }
    let cancelled = false;
    async function refreshGit() {
      try {
        const res = await fetchProjectWorkingTreeGit(scopedProjectId);
        if (cancelled || !res) {
          return;
        }
        const isGit = res.isGitRepository === true;
        setGitBadge({
          isGit,
          added: typeof res.linesAdded === "number" ? res.linesAdded : 0,
          deleted: typeof res.linesDeleted === "number" ? res.linesDeleted : 0,
          branch: res.branch ? String(res.branch) : null
        });
      } catch {
        if (!cancelled) {
          setGitBadge(null);
        }
      }
    }
    void refreshGit();
    const timerId = window.setInterval(refreshGit, 45_000);
    return () => {
      cancelled = true;
      window.clearInterval(timerId);
    };
  }, [scopedProjectId]);

  useEffect(() => {
    if (!scopedProjectId) {
      setProjectChangeBatch(null);
      return undefined;
    }
    return subscribeProjectChangeStream(scopedProjectId, {
      onBatch: (batch) => {
        setProjectChangeBatch(batch);
      },
      onError: () => {
        // The periodic git badge still works if the metadata stream disconnects.
      }
    });
  }, [scopedProjectId]);

  useEffect(() => {
    const active = sessions.find((s) => s.id === activeSessionId);
    if (active && isTaskSession(active)) {
      setTasksDirectoryOpen(true);
    }
  }, [activeSessionId, sessions]);

  useEffect(() => {
    document.body.classList.add("agent-chat-no-page-scroll");
    return () => {
      streamCleanupRef.current?.();
      streamCleanupRef.current = () => { };
      subagentStreamCleanupRef.current?.();
      subagentStreamCleanupRef.current = () => { };
      if (sessionSyncRef.current.timerId) {
        window.clearTimeout(sessionSyncRef.current.timerId);
      }
      sessionSyncRef.current = { sessionId: null, timerId: null, inflight: false, queued: false };
      subagentSessionIdRef.current = "";
      document.body.classList.remove("agent-chat-no-page-scroll");
    };
  }, []);

  useEffect(() => {
    if (!isShareMenuOpen) return;
    function handleClickOutside(event) {
      if (shareMenuRef.current && !shareMenuRef.current.contains(event.target)) {
        setIsShareMenuOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [isShareMenuOpen]);

  useEffect(() => {
    if (!isDebugMenuOpen) {
      return;
    }
    function handleClickOutside(event) {
      if (debugMenuRef.current && !debugMenuRef.current.contains(event.target)) {
        setIsDebugMenuOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [isDebugMenuOpen]);

  useEffect(() => {
    if (!isModelDropdownOpen) {
      return;
    }
    function handleClickOutside(event) {
      if (modelPickerRef.current && !modelPickerRef.current.contains(event.target)) {
        setIsModelDropdownOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [isModelDropdownOpen]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const mq = window.matchMedia(AGENT_CHAT_SIDEBAR_NARROW_MQ);
    function updateNarrow() {
      setIsNarrowChatViewport(mq.matches);
    }
    updateNarrow();
    mq.addEventListener("change", updateNarrow);
    return () => mq.removeEventListener("change", updateNarrow);
  }, []);

  useEffect(() => {
    setIsDesktopSessionsCollapsed(false);
    setIsMobileSidebarOpen(false);
    setSessionSidebarSearch("");
    setSessionPastTasksOpen(false);
    setSessionPastRegularOpen(false);
  }, [agentId]);

  useEffect(() => {
    if (sessionSearchLower && filteredTaskSessions.length > 0) {
      setTasksDirectoryOpen(true);
    }
  }, [sessionSearchLower, filteredTaskSessions.length]);

  useEffect(() => {
    if (pastFilteredTaskSessions.some((s) => s.id === activeSessionId)) {
      setSessionPastTasksOpen(true);
    }
    if (pastFilteredRegularSessions.some((s) => s.id === activeSessionId)) {
      setSessionPastRegularOpen(true);
    }
  }, [activeSessionId, pastFilteredTaskSessions, pastFilteredRegularSessions]);

  useEffect(() => {
    if (!agentId || !activeSessionId) {
      setIsDebugSessionFlagOn(false);
      return;
    }
    try {
      const raw = window.localStorage.getItem(debugSessionStorageKey(agentId, activeSessionId));
      setIsDebugSessionFlagOn(raw === "1" || raw === "true");
    } catch {
      setIsDebugSessionFlagOn(false);
    }
  }, [agentId, activeSessionId]);

  useEffect(() => {
    activeSessionIdRef.current = activeSessionId;
  }, [activeSessionId]);

  useEffect(() => {
    if (!activeSessionId) {
      setIsShareMenuOpen(false);
      setIsDebugMenuOpen(false);
    }
  }, [activeSessionId]);

  useLayoutEffect(() => {
    if (!agentId) {
      prevAgentIdForDraftRef.current = agentId;
      setInputText("");
      setGitDiffComposeTags([]);
      return;
    }
    const agentChanged = prevAgentIdForDraftRef.current !== agentId;
    prevAgentIdForDraftRef.current = agentId;
    if (agentChanged) {
      setActiveSessionId(null);
      setActiveSession(null);
      const d = readComposeDraftState(agentId, null);
      setInputText(d.text);
      setGitDiffComposeTags(d.gitTags);
      return;
    }
    const d = readComposeDraftState(agentId, activeSessionId);
    setInputText(d.text);
    setGitDiffComposeTags(d.gitTags);
  }, [agentId, activeSessionId]);

  useEffect(() => {
    if (!agentId) {
      return;
    }
    const timerId = window.setTimeout(() => {
      writeComposeDraftState(agentId, activeSessionId, inputText, gitDiffComposeTags);
    }, 200);
    return () => window.clearTimeout(timerId);
  }, [agentId, activeSessionId, inputText, gitDiffComposeTags]);

  useEffect(() => {
    subagentSessionIdRef.current = subagentPanel.sessionId;
  }, [subagentPanel.sessionId]);

  function cacheTaskRecord(record) {
    if (!record?.referenceLower) {
      return;
    }
    taskRecordCacheRef.current.set(record.referenceLower, record);
  }

  function readCachedTaskRecord(taskReference) {
    const normalizedReference = normalizeTaskReference(taskReference).toLowerCase();
    if (!normalizedReference) {
      return null;
    }
    return taskRecordCacheRef.current.get(normalizedReference) || null;
  }

  async function loadTaskRecord(taskReference) {
    const normalizedReference = normalizeTaskReference(taskReference);
    const cacheKey = normalizedReference.toLowerCase();
    if (!cacheKey) {
      return null;
    }

    const cached = taskRecordCacheRef.current.get(cacheKey);
    if (cached) {
      return cached;
    }

    const pending = taskRecordInflightRef.current.get(cacheKey);
    if (pending) {
      return pending;
    }

    const request = (async () => {
      try {
        const response = await fetchTaskByReference(normalizedReference);
        const normalized = normalizeTaskRecord(response);
        if (!normalized) {
          return null;
        }
        cacheTaskRecord(normalized);
        setKnownTaskRecords((previous) => mergeTaskRecords(previous, [normalized]));
        return normalized;
      } catch {
        return null;
      } finally {
        taskRecordInflightRef.current.delete(cacheKey);
      }
    })();

    taskRecordInflightRef.current.set(cacheKey, request);
    return request;
  }

  function openTaskReference(taskReference) {
    navigateToTaskScreen(taskReference);
  }

  function handleTaskTagHoverStart(taskReference, anchorElement) {
    const normalizedReference = normalizeTaskReference(taskReference);
    if (!normalizedReference) {
      return;
    }

    const position = getTaskPreviewPosition(anchorElement);
    const cached = readCachedTaskRecord(normalizedReference);
    setTaskPreview({
      reference: normalizedReference,
      ...position,
      loading: !cached,
      record: cached
    });

    if (cached) {
      return;
    }

    loadTaskRecord(normalizedReference).then((record) => {
      setTaskPreview((previous) => {
        if (!previous || previous.reference.toLowerCase() !== normalizedReference.toLowerCase()) {
          return previous;
        }
        return {
          ...previous,
          loading: false,
          record: record || null
        };
      });
    });
  }

  function handleTaskTagHoverEnd() {
    setTaskPreview(null);
  }

  useEffect(() => {
    let isCancelled = false;
    taskRecordCacheRef.current = new Map();
    taskRecordInflightRef.current = new Map();
    setKnownTaskRecords([]);
    setTaskPreview(null);

    async function loadKnownTasks() {
      const [agentTasksResponse, projectsResponse] = await Promise.all([fetchAgentTasks(agentId), fetchProjects()]);
      if (isCancelled) {
        return;
      }

      const normalizedFromAgent = Array.isArray(agentTasksResponse)
        ? agentTasksResponse.map((item) => normalizeTaskRecord(item)).filter(Boolean)
        : [];
      const normalizedFromProjects = normalizeTaskRecordsFromProjects(projectsResponse);
      const normalized = mergeTaskRecords(normalizedFromProjects, normalizedFromAgent);

      for (const record of normalized) {
        cacheTaskRecord(record);
      }
      setKnownTaskRecords(mergeTaskRecords([], normalized));
    }

    loadKnownTasks().catch(() => { });

    return () => {
      isCancelled = true;
    };
  }, [agentId]);

  useEffect(() => {
    setReasoningEffort(DEFAULT_REASONING_EFFORT);
  }, [agentId, selectedModel]);

  useEffect(() => {
    setChatMode(readStoredChatMode(agentId, projectId, modeStorageScope));
  }, [agentId, projectId, modeStorageScope]);

  useEffect(() => {
    writeStoredChatMode(agentId, projectId, modeStorageScope, chatMode);
  }, [agentId, projectId, modeStorageScope, chatMode]);

  useEffect(() => {
    let isCancelled = false;

    async function bootstrap() {
      setIsLoadingSessions(true);
      setActiveSessionId(null);
      setActiveSession(null);
      setPendingFiles([]);
      setOptimisticUserEvent(null);
      setOptimisticAssistantTextImmediate("");
      setReplyTarget(null);
      setExpandedRecordIds({});
      setSelectedModel("");
      setAvailableModels([]);
      setReasoningEffort(DEFAULT_REASONING_EFFORT);
      setIsSending(false);
      setIsStopping(false);
      setSubagentPanel({
        isOpen: false,
        sessionId: "",
        title: "",
        loading: false,
        error: "",
        status: "idle"
      });
      setSubagentSession(null);
      setSubagentExpandedRecordIds({});
      setSubagentOptimisticAssistantTextImmediate("");
      streamCleanupRef.current?.();
      streamCleanupRef.current = () => { };
      subagentStreamCleanupRef.current?.();
      subagentStreamCleanupRef.current = () => { };
      if (sessionSyncRef.current.timerId) {
        window.clearTimeout(sessionSyncRef.current.timerId);
      }
      sessionSyncRef.current = { sessionId: null, timerId: null, inflight: false, queued: false };
      runStateRef.current.abortController?.abort();
      runStateRef.current.sessionId = null;
      runStateRef.current.abortController = null;

      const scoped = projectId && String(projectId).trim() ? String(projectId).trim() : "";
      const serverProjectList = Boolean(scoped);
      const sessionOpts = scoped ? { projectId: scoped } : undefined;
      const [sessionsResponse, configResponse] = await Promise.all([
        fetchAgentSessions(agentId, sessionOpts),
        fetchAgentConfig(agentId)
      ]);
      if (isCancelled) {
        return;
      }

      if (configResponse && typeof configResponse === "object") {
        setSelectedModel(String(configResponse.selectedModel || "").trim());
        setAvailableModels(Array.isArray(configResponse.availableModels) ? configResponse.availableModels : []);
      }

      const allSessions = Array.isArray(sessionsResponse) ? sortSessionsByUpdate(sessionsResponse) : [];
      const nextSessions = allSessions.filter(
        (s) => isUserCreatedSession(s) && sessionMatchesProjectScope(s, scoped, serverProjectList)
      );
      setSessions(nextSessions);
      setIsLoadingSessions(false);

      if (!Array.isArray(sessionsResponse)) {
        setStatusText("Failed to load sessions.");
        return;
      }

      if (nextSessions.length === 0) {
        setStatusText(
          scoped ? "No sessions for this project yet. Create one." : "No sessions yet. Create one."
        );
        return;
      }

      const count = nextSessions.length;
      setStatusText(`Loaded ${count} session${count === 1 ? "" : "s"}`);
      const urlSessionRaw = initialSessionIdRef.current;
      const urlSessionId =
        urlSessionRaw && String(urlSessionRaw).trim() ? String(urlSessionRaw).trim() : "";
      const preferredId =
        urlSessionId && nextSessions.some((s) => s.id === urlSessionId)
          ? urlSessionId
          : nextSessions[0]?.id;
      if (!preferredId) {
        setStatusText(
          scoped ? "No sessions for this project yet. Create one." : "No sessions yet. Create one."
        );
        return;
      }
      setActiveSessionId(preferredId);
      await openSession(preferredId, isCancelled);
    }

    bootstrap().catch(() => {
      if (!isCancelled) {
        setStatusText("Failed to initialize chat.");
        setIsLoadingSessions(false);
      }
    });

    return () => {
      isCancelled = true;
      streamCleanupRef.current?.();
      streamCleanupRef.current = () => { };
      subagentStreamCleanupRef.current?.();
      subagentStreamCleanupRef.current = () => { };
      if (sessionSyncRef.current.timerId) {
        window.clearTimeout(sessionSyncRef.current.timerId);
      }
      sessionSyncRef.current = { sessionId: null, timerId: null, inflight: false, queued: false };
      runStateRef.current.abortController?.abort();
      runStateRef.current.sessionId = null;
      runStateRef.current.abortController = null;
    };
  }, [agentId, projectId]);

  useEffect(() => {
    prevRouteInitialSessionIdRef.current = undefined;
  }, [agentId, projectId]);

  /**
   * When the route-provided session id changes (deep link, Watch session, browser history), follow it.
   * Do not depend on `activeSessionId` or re-sync when only the merged session list changes — that used to
   * reset the sidebar selection back to the stale route id after every click.
   */
  useEffect(() => {
    if (isLoadingSessions) {
      return;
    }
    if (!agentId) {
      return;
    }
    const urlRaw =
      initialSessionId != null && String(initialSessionId).trim()
        ? String(initialSessionId).trim()
        : "";
    if (!urlRaw) {
      prevRouteInitialSessionIdRef.current = initialSessionId;
      return;
    }
    if (!urlSessionPresentInList) {
      return;
    }

    const previous = prevRouteInitialSessionIdRef.current;
    prevRouteInitialSessionIdRef.current = initialSessionId;

    // First run after bootstrap: list is ready; bootstrap already picked `initialSessionId` when present.
    if (previous === undefined) {
      return;
    }
    if (previous === initialSessionId) {
      return;
    }

    const current = String(activeSessionIdRef.current ?? "").trim();
    if (current === urlRaw) {
      return;
    }
    setActiveSessionId(urlRaw);
    void openSession(urlRaw);
  }, [agentId, projectId, initialSessionId, isLoadingSessions, urlSessionPresentInList]);

  async function openSession(sessionId, isCancelled = false) {
    if (!sessionId) {
      return;
    }
    const previousSessionId = activeSessionIdRef.current;
    setActiveSessionId(sessionId);
    setIsLoadingSession(true);
    setReplyTarget(null);
    setExpandedRecordIds({});
    const detail = await fetchAgentSession(agentId, sessionId);
    if (!isCancelled) {
      if (detail) {
        setActiveSession(detail);
        setActiveSessionId(sessionId);
      } else {
        setStatusText("Failed to load session.");
        setActiveSessionId(previousSessionId);
      }
      setIsLoadingSession(false);
    }
  }

  async function openSubagentPanel(sessionId, title = "Sub-session") {
    const normalizedSessionId = String(sessionId || "").trim();
    if (!normalizedSessionId) {
      return;
    }

    subagentStreamCleanupRef.current?.();
    subagentStreamCleanupRef.current = () => { };
    setSubagentPanel({
      isOpen: true,
      sessionId: normalizedSessionId,
      title: String(title || "Sub-session").trim() || "Sub-session",
      loading: true,
      error: "",
      status: "loading"
    });
    setSubagentSession(null);
    setSubagentExpandedRecordIds({});
    setSubagentOptimisticAssistantTextImmediate("");

    try {
      const detail = await fetchAgentSession(agentId, normalizedSessionId);
      if (subagentSessionIdRef.current !== normalizedSessionId) {
        return;
      }
      if (!detail) {
        setSubagentPanel((previous) => ({
          ...previous,
          loading: false,
          error: "Failed to load sub-session.",
          status: "disconnected"
        }));
        return;
      }
      setSubagentSession(detail);
      const sessionDetail = detail as { summary?: { title?: string } };
      setSubagentPanel((previous) => ({
        ...previous,
        loading: false,
        error: "",
        status: "live",
        title: String(sessionDetail?.summary?.title || previous.title || title || "Sub-session")
      }));
    } catch {
      if (subagentSessionIdRef.current === normalizedSessionId) {
        setSubagentPanel((previous) => ({
          ...previous,
          loading: false,
          error: "Failed to load sub-session.",
          status: "disconnected"
        }));
      }
    }
  }

  function closeSubagentPanel() {
    subagentStreamCleanupRef.current?.();
    subagentStreamCleanupRef.current = () => { };
    subagentSessionIdRef.current = "";
    setSubagentPanel({
      isOpen: false,
      sessionId: "",
      title: "",
      loading: false,
      error: "",
      status: "idle"
    });
    setSubagentSession(null);
    setSubagentExpandedRecordIds({});
    setSubagentOptimisticAssistantTextImmediate("");
  }

  async function refreshSessions(preferredSessionId = null) {
    const scoped = projectId && String(projectId).trim() ? String(projectId).trim() : "";
    const sessionOpts = scoped ? { projectId: scoped } : undefined;
    const response = await fetchAgentSessions(agentId, sessionOpts);
    if (!Array.isArray(response)) {
      setStatusText("Failed to refresh sessions.");
      return;
    }

    const nextSessions = sortSessionsByUpdate(
      response.filter((s) =>
        isUserCreatedSession(s) && sessionMatchesProjectScope(s, scoped, Boolean(scoped))
      )
    );
    setSessions(nextSessions);

    if (nextSessions.length === 0) {
      setActiveSessionId(null);
      setActiveSession(null);
      setStatusText(
        scoped ? "No sessions for this project yet. Create one." : "No sessions yet. Create one."
      );
      return;
    }

    const targetId =
      preferredSessionId && nextSessions.some((item) => item.id === preferredSessionId)
        ? preferredSessionId
        : nextSessions[0].id;
    setActiveSessionId(targetId);
    await openSession(targetId);
  }

  async function createSession(parentSessionId = null, checkpointSessionId = null) {
    const payload: { parentSessionId?: string; checkpointSessionId?: string; projectId?: string } = {};
    if (parentSessionId) {
      payload.parentSessionId = parentSessionId;
    }
    if (checkpointSessionId) {
      payload.checkpointSessionId = checkpointSessionId;
    }
    const scopedProject = projectId && String(projectId).trim() ? String(projectId).trim() : "";
    if (scopedProject) {
      payload.projectId = scopedProject;
    }
    const response = await createAgentSession(agentId, payload);
    if (!response) {
      setStatusText("Failed to create session.");
      return null;
    }

    setSessions((previous) => sortSessionsByUpdate([response, ...previous.filter((item) => item.id !== response.id)]));
    setActiveSessionId(response.id);
    await openSession(response.id);
    setStatusText(`Session ${response.id} created`);
    return response;
  }

  async function handleModelSwitch(nextModelId) {
    if (isSending) {
      return;
    }
    const normalizedModelId = String(nextModelId || "").trim();
    if (!normalizedModelId || normalizedModelId === selectedModel) {
      setIsModelDropdownOpen(false);
      setModelSearch(String(selectedModel || ""));
      return;
    }
    const previousModelId = String(selectedModel || "").trim();
    setSelectedModel(normalizedModelId);
    setIsModelDropdownOpen(false);
    setStatusText(`Switching model to ${normalizedModelId}...`);

    const previousSessionId = activeSessionIdRef.current;
    const scopedProject = projectId && String(projectId).trim() ? String(projectId).trim() : "";
    const previousTitle = String(activeSession?.summary?.title || "").trim();
    const payload: {
      checkpointSessionId?: string;
      projectId?: string;
      title?: string;
    } = {};
    if (previousSessionId) {
      payload.checkpointSessionId = previousSessionId;
    }
    if (scopedProject) {
      payload.projectId = scopedProject;
    }
    if (previousTitle) {
      payload.title = previousTitle;
    }

    try {
      let replayEvents = [];
      if (previousSessionId) {
        const previousDetail = await fetchAgentSession(agentId, previousSessionId);
        replayEvents = Array.isArray(previousDetail?.events) ? previousDetail.events : [];
      }

      const rebuilt = await createAgentSession(agentId, payload);
      if (!rebuilt?.id) {
        setSelectedModel(previousModelId);
        setStatusText(`Model switched to ${normalizedModelId}, but session rebuild failed.`);
        return;
      }

      let rebuiltSummary = rebuilt;
      if (replayEvents.length > 0) {
        const replayResponse = await postAgentSessionEvents(agentId, rebuilt.id, {
          events: replayEvents
        });
        if (!replayResponse) {
          setSelectedModel(previousModelId);
          await deleteAgentSession(agentId, rebuilt.id).catch(() => false);
          setStatusText("Failed to preserve chat history while switching model.");
          return;
        }
        rebuiltSummary = replayResponse.summary || rebuilt;
      }

      if (previousSessionId && previousSessionId !== rebuilt.id) {
        // Keep project chat visually in one "slot": swap old session with rebuilt one.
        await deleteAgentSession(agentId, previousSessionId).catch(() => false);
      }

      setSessions((previous) =>
        sortSessionsByUpdate([
          rebuiltSummary,
          ...previous.filter((item) => item.id !== rebuilt.id && item.id !== previousSessionId)
        ])
      );
      setActiveSessionId(rebuilt.id);
      await openSession(rebuilt.id);
      setStatusText(`Model switched to ${normalizedModelId}. History and context preserved.`);
    } catch {
      setSelectedModel(previousModelId);
      setStatusText("Failed to switch model and keep chat history.");
    }
  }

  function mergeSessionSummary(summary) {
    if (!summary?.id || !isUserCreatedSession(summary)) {
      return;
    }
    const scoped = projectId && String(projectId).trim() ? String(projectId).trim() : "";
    if (scoped && !sessionMatchesProjectScope(summary, scoped, false)) {
      const sameAsActive =
        String(summary.id || "").trim() === String(activeSessionIdRef.current || "").trim();
      if (!sameAsActive) {
        return;
      }
    }
    setSessions((previous) =>
      sortSessionsByUpdate([summary, ...previous.filter((sessionItem) => sessionItem.id !== summary.id)])
    );
  }

  function applyStreamEvent(summary, streamEvent) {
    if (!streamEvent?.id || !streamEvent?.sessionId) {
      return;
    }

    setActiveSession((previous) => {
      if (!previous?.summary?.id || previous.summary.id !== streamEvent.sessionId) {
        return previous;
      }

      const existingEvents = Array.isArray(previous.events) ? previous.events : [];
      const alreadyExists = existingEvents.some((item) => item?.id === streamEvent.id);
      if (alreadyExists) {
        if (summary?.id === previous.summary.id) {
          return { ...previous, summary };
        }
        return previous;
      }

      return {
        ...previous,
        summary: summary?.id === previous.summary.id ? summary : previous.summary,
        events: [...existingEvents, streamEvent]
      };
    });
  }

  async function syncSessionDetail(sessionId) {
    if (!sessionId) {
      return;
    }

    const detail = await fetchAgentSession(agentId, sessionId);
    if (!detail || activeSessionIdRef.current !== sessionId) {
      return;
    }

    setActiveSession((previous) => {
      if (!previous) return detail;
      const serverEvents = Array.isArray(detail.events) ? detail.events : [];
      const localEvents = Array.isArray(previous.events) ? previous.events : [];
      const serverIds = new Set(serverEvents.map((e) => e?.id).filter(Boolean));
      const localOnly = localEvents.filter(
        (e) => e?.id && !serverIds.has(e.id) && String(e.id).startsWith("cmd-")
      );
      if (localOnly.length === 0) return detail;
      return { ...detail, events: [...serverEvents, ...localOnly] };
    });
    const detailSummary =
      detail.summary && typeof detail.summary === "object"
        ? detail.summary as { id?: string }
        : null;
    if (detailSummary?.id) {
      mergeSessionSummary(detailSummary);
    }
  }

  async function handleAnswerInputRequest(requestId, payload) {
    const sessionId = activeSessionIdRef.current;
    if (!agentId || !sessionId || !requestId) {
      return;
    }
    setStatusText("Submitting plan input...");
    const response = await answerAgentSessionInputRequest(agentId, sessionId, requestId, payload);
    if (!response) {
      setStatusText("Failed to submit plan input.");
      return;
    }
    await syncSessionDetail(sessionId);
    setStatusText("Plan input submitted.");
  }

  function scheduleSessionSync(sessionId, delayMs = 120) {
    if (!sessionId) {
      return;
    }

    const state = sessionSyncRef.current;
    state.sessionId = sessionId;

    if (state.timerId) {
      window.clearTimeout(state.timerId);
    }

    state.timerId = window.setTimeout(async () => {
      state.timerId = null;

      if (state.inflight) {
        state.queued = true;
        return;
      }

      state.inflight = true;
      const requestedSessionId = state.sessionId;

      try {
        await syncSessionDetail(requestedSessionId);
      } finally {
        state.inflight = false;
        if (state.queued && state.sessionId) {
          state.queued = false;
          scheduleSessionSync(state.sessionId, 0);
        }
      }
    }, delayMs);
  }

  function handleSessionStreamUpdate(update) {
    if (!update || typeof update !== "object") {
      return;
    }

    const kind = String(update.kind || "");
    const summary = update.summary && typeof update.summary === "object" ? update.summary : null;
    const streamEvent = update.event && typeof update.event === "object" ? update.event : null;

    if (summary?.id) {
      mergeSessionSummary(summary);
    }

    if (kind === "session_delta") {
      const deltaText = String(update.message || "");
      if (deltaText.trim().length > 0) {
        pushOptimisticAssistantText(deltaText);
      }
      return;
    }

    if (streamEvent) {
      applyStreamEvent(summary, streamEvent);

      if (streamEvent.type === "run_status" && streamEvent.runStatus) {
        const detailsText = streamEvent.runStatus.details ? ` - ${streamEvent.runStatus.details}` : "";
        setStatusText(`Status: ${streamEvent.runStatus.label || streamEvent.runStatus.stage}${detailsText}`);

        if (streamEvent.runStatus.stage === "responding" && streamEvent.runStatus.expandedText) {
          pushOptimisticAssistantText(String(streamEvent.runStatus.expandedText));
        }
        if (isTerminalRunStage(streamEvent.runStatus.stage)) {
          setOptimisticAssistantTextImmediate("");
          setIsStopping(false);
        }
      }

      if (streamEvent.type === "message" && streamEvent.message?.role === "assistant") {
        const streamedText = segmentsToPlainText(streamEvent.message.segments || []);
        if (streamedText) {
          setOptimisticAssistantTextImmediate(streamedText);
        }
      }
      if (streamEvent.type === "message" && streamEvent.message?.role === "user") {
        setOptimisticUserEvent(null);
      }
    }

    if (
      kind === "session_ready" ||
      kind === "session_event" ||
      kind === "heartbeat"
    ) {
      const syncSessionId = String(summary?.id || streamEvent?.sessionId || activeSessionIdRef.current || "").trim();
      if (syncSessionId && syncSessionId === activeSessionIdRef.current) {
        scheduleSessionSync(syncSessionId, kind === "heartbeat" ? 180 : 0);
      }
    }

    if (kind === "session_closed") {
      setIsStopping(false);
      setStatusText(String(update.message || "Session stream closed."));
    } else if (kind === "session_error") {
      setIsStopping(false);
      setStatusText(String(update.message || "Session stream error."));
    }
  }

  useEffect(() => {
    streamCleanupRef.current?.();
    streamCleanupRef.current = () => { };

    if (!activeSessionId) {
      return;
    }

    const disconnect = subscribeAgentSessionStream(agentId, activeSessionId, {
      onUpdate: handleSessionStreamUpdate,
      onError: () => {
        if (activeSessionId) {
          setStatusText((previous) => {
            if (String(previous || "").toLowerCase().includes("status:")) {
              return previous;
            }
            return "Realtime stream reconnecting...";
          });
        }
      }
    });
    streamCleanupRef.current = disconnect;

    return () => {
      disconnect();
      if (streamCleanupRef.current === disconnect) {
        streamCleanupRef.current = () => { };
      }
    };
  }, [agentId, activeSessionId]);

  function applySubagentStreamEvent(summary, streamEvent) {
    if (!streamEvent?.id || !streamEvent?.sessionId) {
      return;
    }

    setSubagentSession((previous) => {
      if (!previous?.summary?.id || previous.summary.id !== streamEvent.sessionId) {
        return previous;
      }

      const existingEvents = Array.isArray(previous.events) ? previous.events : [];
      const alreadyExists = existingEvents.some((item) => item?.id === streamEvent.id);
      if (alreadyExists) {
        if (summary?.id === previous.summary.id) {
          return { ...previous, summary };
        }
        return previous;
      }

      return {
        ...previous,
        summary: summary?.id === previous.summary.id ? summary : previous.summary,
        events: [...existingEvents, streamEvent]
      };
    });
  }

  function handleSubagentStreamUpdate(update) {
    if (!update || typeof update !== "object") {
      return;
    }

    const kind = String(update.kind || "");
    const summary = update.summary && typeof update.summary === "object" ? update.summary : null;
    const streamEvent = update.event && typeof update.event === "object" ? update.event : null;

    if (kind === "session_delta") {
      const deltaText = String(update.message || "");
      if (deltaText.trim().length > 0) {
        pushSubagentOptimisticAssistantText(deltaText);
      }
      return;
    }

    if (streamEvent) {
      applySubagentStreamEvent(summary, streamEvent);
      if (streamEvent.type === "run_status" && streamEvent.runStatus) {
        if (streamEvent.runStatus.stage === "responding" && streamEvent.runStatus.expandedText) {
          pushSubagentOptimisticAssistantText(String(streamEvent.runStatus.expandedText));
        }
        if (streamEvent.runStatus.stage === "done" || streamEvent.runStatus.stage === "interrupted") {
          setSubagentOptimisticAssistantTextImmediate("");
        }
      }
      if (streamEvent.type === "message" && streamEvent.message?.role === "assistant") {
        const streamedText = segmentsToPlainText(streamEvent.message.segments || []);
        if (streamedText) {
          setSubagentOptimisticAssistantTextImmediate(streamedText);
        }
      }
    }

    if (kind === "session_error" || kind === "session_closed") {
      setSubagentPanel((previous) => ({ ...previous, status: "disconnected" }));
    } else if (kind === "session_ready" || kind === "session_event" || kind === "heartbeat") {
      setSubagentPanel((previous) => ({ ...previous, status: "live" }));
    }
  }

  useEffect(() => {
    subagentStreamCleanupRef.current?.();
    subagentStreamCleanupRef.current = () => { };

    if (!subagentPanel.isOpen || !subagentPanel.sessionId) {
      return;
    }

    const disconnect = subscribeAgentSessionStream(agentId, subagentPanel.sessionId, {
      onUpdate: handleSubagentStreamUpdate,
      onError: () => {
        setSubagentPanel((previous) => ({
          ...previous,
          status: "disconnected",
          error: previous.error || "Realtime stream reconnecting..."
        }));
      }
    });
    subagentStreamCleanupRef.current = disconnect;

    return () => {
      disconnect();
      if (subagentStreamCleanupRef.current === disconnect) {
        subagentStreamCleanupRef.current = () => { };
      }
    };
  }, [agentId, subagentPanel.isOpen, subagentPanel.sessionId]);

  function addFiles(fileList) {
    const next = Array.from(fileList || []);
    if (next.length === 0) {
      return;
    }
    setPendingFiles((previous) => [...previous, ...next]);
    setStatusText(`${next.length} file(s) attached`);
  }

  function removePendingFile(index) {
    setPendingFiles((previous) => previous.filter((_, itemIndex) => itemIndex !== index));
  }

  async function persistCommandEvents(commandText, responseText) {
    const sessionId = activeSessionId;
    if (!sessionId) {
      return;
    }

    const now = new Date().toISOString();
    const userEvent = {
      id: `cmd-user-${Date.now()}`,
      agentId,
      sessionId,
      type: "message",
      createdAt: now,
      message: {
        role: "user",
        createdAt: now,
        segments: [{ kind: "text", text: commandText }]
      }
    };
    const assistantEvent = {
      id: `cmd-assistant-${Date.now()}`,
      agentId,
      sessionId,
      type: "message",
      createdAt: now,
      message: {
        role: "assistant",
        createdAt: now,
        segments: [{ kind: "text", text: responseText }]
      }
    };

    setActiveSession((previous) => {
      if (!previous) {
        return previous;
      }
      return {
        ...previous,
        events: [...(Array.isArray(previous.events) ? previous.events : []), userEvent, assistantEvent]
      };
    });

    try {
      const response = await postAgentSessionEvents(agentId, sessionId, {
        events: [userEvent, assistantEvent]
      });
      if (response) {
        await syncSessionDetail(sessionId);
      }
    } catch {
      // Events already shown locally
    }
  }

  async function handleSlashCommand(text) {
    const lower = text.toLowerCase();

    if (lower === "/help") {
      const lines = slashCommands.map((cmd) => `/${cmd.name} — ${cmd.description}`).join("\n");
      await persistCommandEvents(text, `Available commands:\n${lines}\n\nAny other message is forwarded to the agent.`);
      return true;
    }

    if (lower === "/status") {
      const modelLabel = selectedModel || "default";
      const sessionLabel = activeSessionId || "none";
      const stateLabel = isSending ? "Running" : "Idle";
      await persistCommandEvents(text, `Agent: ${agentId}\nSession: ${sessionLabel}\nModel: ${modelLabel}\nState: ${stateLabel}`);
      return true;
    }

    if (lower === "/new" || lower === "/clear") {
      setInputText("");
      const previousSessionId = activeSessionId;
      void createSession(null, previousSessionId || null);
      setStatusText("New session created.");
      return true;
    }

    if (lower === "/abort" || lower === "/stop") {
      handleStop();
      setInputText("");
      return true;
    }

    if (lower === "/model") {
      const modelLabel = selectedModel || "not set";
      const modelsList = availableModels.length > 0
        ? availableModels.map((m) => `  ${m.id === selectedModel ? "▸ " : "  "}${m.id}`).join("\n")
        : "  No models available.";
      await persistCommandEvents(text, `Current model: ${modelLabel}\n\nAvailable models:\n${modelsList}`);
      return true;
    }

    if (lower === "/context") {
      const eventCount = Array.isArray(activeSession?.events) ? activeSession.events.length : 0;
      let usageText = `Session: ${activeSessionId || "none"}\nEvents in session: ${eventCount}`;
      try {
        const usage = await fetchAgentTokenUsage(agentId);
        if (usage) {
          const promptTokens = usage.promptTokens ?? usage.prompt_tokens ?? "—";
          const completionTokens = usage.completionTokens ?? usage.completion_tokens ?? "—";
          const totalTokens = usage.totalTokens ?? usage.total_tokens ?? "—";
          const contextWindow = usage.contextWindow ?? usage.context_window ?? null;
          usageText += `\n\nToken usage:\n  Prompt tokens: ${promptTokens}\n  Completion tokens: ${completionTokens}\n  Total tokens: ${totalTokens}`;
          if (contextWindow) {
            usageText += `\n  Context window: ${contextWindow}`;
          }
        }
      } catch {
        usageText += "\n\n(Token usage data unavailable)";
      }
      await persistCommandEvents(text, usageText);
      return true;
    }

    if (lower === "/compact") {
      if (!activeSessionId) {
        await persistCommandEvents(text, "No active session to compact.");
        return true;
      }
      const response = await postAgentMemoryCheckpoint(agentId, activeSessionId, { reason: "dashboard_compact_command" }).catch(() => null);
      await persistCommandEvents(
        text,
        response ? "Context compacted. Memory checkpoint requested for this session." : "Compact failed."
      );
      return true;
    }

    const addDirPath = pathTailIfAddDirCommand(text);
    if (addDirPath !== null) {
      if (!activeSessionId) {
        await persistCommandEvents(text, "No active session to update.");
        return true;
      }
      if (!addDirPath) {
        await persistCommandEvents(text, "Usage: /add_dir <path>");
        return true;
      }
      const response = await postAgentSessionDirectory(agentId, activeSessionId, { path: addDirPath }).catch(() => null);
      await persistCommandEvents(
        text,
        response?.path ? `Added working directory:\n${response.path}` : "Add directory failed."
      );
      if (response) {
        await syncSessionDetail(activeSessionId);
      }
      return true;
    }

    if (lower === "/tasks") {
      if (knownTaskRecords.length === 0) {
        await persistCommandEvents(text, "No tasks found.");
      } else {
        const lines = knownTaskRecords.slice(0, 15).map(
          (t) => `#${t.reference} — ${t.title} [${t.status}]`
        ).join("\n");
        await persistCommandEvents(text, `Tasks (${knownTaskRecords.length}):\n${lines}`);
      }
      return true;
    }

    // Same as channel plugins: /task … is not a local dashboard command; forward full line to the agent.
    if (lower.startsWith("/task ")) {
      return false;
    }

    if (lower.startsWith("/") && !lower.slice(1).includes(" ")) {
      const cmdName = lower.slice(1);
      if (!slashCommandNameSet.has(cmdName)) {
        await persistCommandEvents(text, "Unknown command. Send /help for available commands.");
        return true;
      }
    }

    return false;
  }

  async function handleSend(event) {
    event?.preventDefault?.();
    if (isSending) {
      return;
    }

    const trimmed = String(inputText || "").trim();
    const tagMarkdown = gitDiffComposeTags.map((t) => t.markdown).join("\n\n");
    const mergedBody = [trimmed, tagMarkdown].filter(Boolean).join("\n\n");

    if (trimmed.startsWith("/") && pendingFiles.length === 0 && !replyTarget && gitDiffComposeTags.length === 0) {
      if (await handleSlashCommand(trimmed)) {
        setInputText("");
        composeInputRef.current?.focus();
        return;
      }
    }

    const replyContext = replyTarget ? `Reply to assistant: "${replyTarget.text}"` : "";
    const contentForSend = mergedBody
      ? replyContext
        ? `${replyContext}\n\n${mergedBody}`
        : mergedBody
      : replyContext;
    if (!contentForSend && pendingFiles.length === 0) {
      return;
    }
    const modeForSend = normalizeChatMode(chatMode);

    let sessionId = activeSessionId;
    if (!sessionId) {
      const created = await createSession();
      if (!created) {
        return;
      }
      sessionId = created.id;
    }

    const localMessageSegments = [];
    const previewLines = [];
    if (trimmed) {
      previewLines.push(trimmed);
    } else if (replyTarget) {
      previewLines.push(`↪ ${replyTarget.text}`);
    }
    if (gitDiffComposeTags.length > 0) {
      previewLines.push(gitDiffComposeTags.map((t) => `· ${t.label}`).join("\n"));
    }
    if (previewLines.length > 0) {
      localMessageSegments.push({ kind: "text", text: previewLines.join("\n\n") });
    }
    localMessageSegments.push(
      ...pendingFiles.map((file) => ({
        kind: "attachment",
        attachment: {
          id: `local-${file.name}-${file.size}-${file.lastModified}`,
          name: file.name,
          mimeType: file.type || "application/octet-stream"
        }
      }))
    );
    setOptimisticUserEvent({
      id: `local-user-${Date.now()}`,
      createdAt: new Date().toISOString(),
      type: "message",
      message: {
        role: "user",
        createdAt: new Date().toISOString(),
        segments: localMessageSegments
      }
    });
    setOptimisticAssistantTextImmediate("");
    setIsSending(true);
    setStatusText("Thinking...");
    setInputText("");
    setGitDiffComposeTags([]);
    setPendingFiles([]);
    setReplyTarget(null);

    let oversizedCount = 0;
    const uploads = await Promise.all(
      pendingFiles.map(async (file) => {
        const mimeType = file.type || "application/octet-stream";
        if (file.size > INLINE_ATTACHMENT_MAX_BYTES) {
          oversizedCount += 1;
          return {
            name: file.name,
            mimeType,
            sizeBytes: file.size,
            contentBase64: null
          };
        }

        try {
          const contentBase64 = await encodeFileBase64(file);
          return {
            name: file.name,
            mimeType,
            sizeBytes: file.size,
            contentBase64
          };
        } catch {
          return {
            name: file.name,
            mimeType,
            sizeBytes: file.size,
            contentBase64: null
          };
        }
      })
    );

    runStateRef.current.sessionId = sessionId;
    runStateRef.current.abortController = new AbortController();

    try {
      const response = await postAgentSessionMessage(
        agentId,
        sessionId,
        {
          userId: "dashboard",
          content: contentForSend,
          attachments: uploads,
          spawnSubSession: false,
          mode: modeForSend,
          reasoningEffort: supportsReasoningEffort ? reasoningEffort : undefined,
          selectedModel: selectedModel || undefined
        },
        { signal: runStateRef.current.abortController.signal }
      );

      if (!response) {
        setStatusText("Failed to send message.");
        return;
      }

      await refreshSessions(sessionId);

      if (oversizedCount > 0) {
        setStatusText(`Message sent. ${oversizedCount} file(s) saved without inline preview (size limit).`);
      } else {
        setStatusText("Message sent.");
      }
    } catch (error) {
      if (error?.name !== "AbortError") {
        setStatusText("Failed to send message.");
      }
    } finally {
      runStateRef.current.abortController = null;
      runStateRef.current.sessionId = null;
      setOptimisticUserEvent(null);
      setOptimisticAssistantTextImmediate("");
      setIsSending(false);
      composeInputRef.current?.focus();
    }
  }

  async function handleStop() {
    if (isStopping) {
      return;
    }

    const sessionId = runStateRef.current.sessionId || activeSessionIdRef.current || activeSessionId;
    if (!sessionId) {
      setStatusText("Nothing to abort.");
      return;
    }

    runStateRef.current.abortController?.abort();
    runStateRef.current.abortController = null;
    runStateRef.current.sessionId = null;
    setIsStopping(true);
    setStatusText("Stopping...");

    try {
      await postAgentMemoryCheckpoint(agentId, sessionId, { reason: "stop_command" }).catch(() => null);
      const response = await postAgentSessionControl(agentId, sessionId, {
        action: "interruptTree",
        requestedBy: "dashboard",
        reason: "Stopped by user"
      });
      if (response) {
        setStatusText("Interrupt requested.");
        void refreshSessions(sessionId);
      } else {
        setStatusText("Failed to interrupt.");
        setIsStopping(false);
      }
    } catch {
      setStatusText("Failed to interrupt.");
      setIsStopping(false);
    }

    setOptimisticUserEvent(null);
    setOptimisticAssistantTextImmediate("");
    setIsSending(false);
  }

  async function handleDeleteActiveSession() {
    if (!activeSessionId) {
      return;
    }
    if (!window.confirm("Delete this session?")) {
      return;
    }

    const deletedSessionId = activeSessionId;
    const success = await deleteAgentSession(agentId, deletedSessionId);
    if (!success) {
      setStatusText("Failed to delete session.");
      return;
    }
    removeAgentChatComposeDraft(agentId, deletedSessionId);
    await refreshSessions(null);
    setStatusText("Session deleted.");
  }

  async function handleCopyMessage(text) {
    const value = String(text || "").trim();
    if (!value) {
      setStatusText("Nothing to copy.");
      return;
    }

    try {
      if (navigator?.clipboard?.writeText) {
        await navigator.clipboard.writeText(value);
      } else {
        const fallbackInput = document.createElement("textarea");
        fallbackInput.value = value;
        fallbackInput.setAttribute("readonly", "");
        fallbackInput.style.position = "absolute";
        fallbackInput.style.left = "-9999px";
        document.body.appendChild(fallbackInput);
        fallbackInput.select();
        document.execCommand("copy");
        document.body.removeChild(fallbackInput);
      }
      setStatusText("Message copied to clipboard.");
    } catch {
      setStatusText("Failed to copy message.");
    }
  }

  function getSessionFilePath() {
    if (!agentId || !activeSessionId) return null;
    return `.sloppy/agents/${agentId}/sessions/${activeSessionId}.jsonl`;
  }

  async function copyActiveSessionFilePath() {
    const path = getSessionFilePath();
    if (!path) {
      setStatusText("No active session.");
      return false;
    }

    try {
      if (navigator?.clipboard?.writeText) {
        await navigator.clipboard.writeText(path);
      } else {
        const fallbackInput = document.createElement("textarea");
        fallbackInput.value = path;
        fallbackInput.setAttribute("readonly", "");
        fallbackInput.style.position = "absolute";
        fallbackInput.style.left = "-9999px";
        document.body.appendChild(fallbackInput);
        fallbackInput.select();
        document.execCommand("copy");
        document.body.removeChild(fallbackInput);
      }
      setStatusText("Session path copied to clipboard.");
      return true;
    } catch {
      setStatusText("Failed to copy session path.");
      return false;
    }
  }

  async function handleCopySessionPath() {
    await copyActiveSessionFilePath();
    setIsShareMenuOpen(false);
  }

  function downloadActiveSessionJson() {
    if (!activeSession || !activeSessionId) {
      setStatusText("No active session to download.");
      return false;
    }

    try {
      const sessionData = {
        summary: activeSession.summary || null,
        events: Array.isArray(activeSession.events) ? activeSession.events : []
      };
      const jsonContent = JSON.stringify(sessionData, null, 2);
      const blob = new Blob([jsonContent], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `${activeSessionId}.json`;
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(url);
      setStatusText("Session downloaded.");
      return true;
    } catch {
      setStatusText("Failed to download session.");
      return false;
    }
  }

  function handleDownloadSession() {
    downloadActiveSessionJson();
    setIsShareMenuOpen(false);
  }

  async function appendSingleDashboardMessageEvent(text) {
    const sessionId = activeSessionId;
    if (!sessionId || !agentId) {
      setStatusText("No active session.");
      return false;
    }
    const now = new Date().toISOString();
    const userEvent = {
      id: `dash-${Date.now()}`,
      agentId,
      sessionId,
      type: "message",
      createdAt: now,
      message: {
        role: "user",
        createdAt: now,
        segments: [{ kind: "text", text }]
      }
    };
    try {
      const response = await postAgentSessionEvents(agentId, sessionId, { events: [userEvent] });
      if (response) {
        await syncSessionDetail(sessionId);
        return true;
      }
    } catch {
      // fall through
    }
    setStatusText("Failed to append session note.");
    return false;
  }

  function toggleDebugSessionFlag() {
    if (!agentId || !activeSessionId) {
      return;
    }
    const key = debugSessionStorageKey(agentId, activeSessionId);
    const next = !isDebugSessionFlagOn;
    try {
      if (next) {
        window.localStorage.setItem(key, "1");
      } else {
        window.localStorage.removeItem(key);
      }
    } catch {
      setStatusText("Could not update debug flag (storage unavailable).");
      return;
    }
    setIsDebugSessionFlagOn(next);
    setStatusText(next ? "Debug mode on for this session." : "Debug mode off for this session.");
    setIsDebugMenuOpen(false);
  }

  async function handleDebugInjectInstructions() {
    if (!activeSessionId || isSending) {
      return;
    }
    setIsDebugMenuOpen(false);
    const ok = await appendSingleDashboardMessageEvent(DEBUG_INSTRUCTIONS_APPEND_TEXT);
    if (ok) {
      setStatusText("Debug instructions added to the transcript.");
    }
  }

  async function handleDebugPrepareToTranscript() {
    if (!activeSessionId || isSending) {
      return;
    }
    setIsDebugMenuOpen(false);
    await copyActiveSessionFilePath();
    downloadActiveSessionJson();
    const ok = await appendSingleDashboardMessageEvent(ANALYSIS_PREP_APPEND_TEXT);
    if (ok) {
      setStatusText("Session JSON exported, path copied, prep note added (no agent run).");
    }
  }

  async function handleDebugPrepareRunAgent() {
    const sessionId = activeSessionId;
    if (!sessionId || !agentId || isSending) {
      return;
    }
    setIsDebugMenuOpen(false);
    setIsSending(true);
    setStatusText("Thinking...");
    setOptimisticAssistantTextImmediate("");
    runStateRef.current.sessionId = sessionId;
    runStateRef.current.abortController = new AbortController();
    setOptimisticUserEvent({
      id: `local-user-${Date.now()}`,
      createdAt: new Date().toISOString(),
      type: "message",
      message: {
        role: "user",
        createdAt: new Date().toISOString(),
        segments: [{ kind: "text", text: ANALYSIS_PREP_AGENT_PROMPT }]
      }
    });
    try {
      const response = await postAgentSessionMessage(
        agentId,
        sessionId,
        {
          userId: "dashboard",
          content: ANALYSIS_PREP_AGENT_PROMPT,
          attachments: [],
          spawnSubSession: false,
          mode: normalizeChatMode(chatMode),
          reasoningEffort: supportsReasoningEffort ? reasoningEffort : undefined,
          selectedModel: selectedModel || undefined
        },
        { signal: runStateRef.current.abortController.signal }
      );
      if (!response) {
        setStatusText("Failed to send analysis prep message.");
        return;
      }
      await refreshSessions(sessionId);
      setStatusText("Analysis prep message sent to the agent.");
    } catch (error) {
      if (error?.name !== "AbortError") {
        setStatusText("Failed to send analysis prep message.");
      }
    } finally {
      runStateRef.current.abortController = null;
      runStateRef.current.sessionId = null;
      setOptimisticUserEvent(null);
      setOptimisticAssistantTextImmediate("");
      setIsSending(false);
    }
  }

  function toggleSessionSidebar() {
    if (isNarrowChatViewport) {
      setIsMobileSidebarOpen((prev) => !prev);
    } else {
      setIsDesktopSessionsCollapsed((prev) => !prev);
    }
  }

  function closeMobileSessionSidebar() {
    setIsMobileSidebarOpen(false);
  }

  function openSessionFromSidebar(sessionId) {
    openSession(sessionId);
    if (isNarrowChatViewport) {
      setIsMobileSidebarOpen(false);
    }
  }

  function handleReplyToMessage(target) {
    if (!target?.id || !target?.text) {
      return;
    }
    setReplyTarget({
      id: target.id,
      text: String(target.text)
    });
    composeInputRef.current?.focus();
  }

  const events = Array.isArray(activeSession?.events) ? activeSession.events : [];
  const activeToolCallRecordIds = useMemo(() => findPendingToolCallRecordIds(events), [events]);
  const { timelineItems, latestRunStatus } = useMemo(
    () =>
      buildTimelineItems({
        events,
        activeToolCallRecordIds,
        optimisticUserEvent,
        optimisticAssistantText,
        isSending
      }),
    [events, activeToolCallRecordIds, optimisticUserEvent, optimisticAssistantText, isSending]
  );
  const subagentEvents = Array.isArray(subagentSession?.events) ? subagentSession.events : [];
  const subagentActiveToolCallRecordIds = useMemo(
    () => findPendingToolCallRecordIds(subagentEvents),
    [subagentEvents]
  );
  const { timelineItems: subagentTimelineItems, latestRunStatus: subagentLatestRunStatus } = useMemo(
    () =>
      buildTimelineItems({
        events: subagentEvents,
        activeToolCallRecordIds: subagentActiveToolCallRecordIds,
        optimisticAssistantText: subagentOptimisticAssistantText,
        isSending: subagentPanel.status === "loading" || subagentPanel.status === "live"
      }),
    [subagentEvents, subagentActiveToolCallRecordIds, subagentOptimisticAssistantText, subagentPanel.status]
  );
  const hasActiveSessionWork =
    isSending || isActiveRunStage(latestRunStatus?.stage) || activeToolCallRecordIds.size > 0;
  const isActiveSessionBusy = isStopping || hasActiveSessionWork;
  const isSubagentBusy =
    subagentPanel.loading ||
    subagentPanel.status === "live" ||
    isActiveRunStage(subagentLatestRunStatus?.stage) ||
    subagentActiveToolCallRecordIds.size > 0;
  useEffect(() => {
    if (!isStopping) {
      return;
    }
    if (isTerminalRunStage(latestRunStatus?.stage) || !hasActiveSessionWork) {
      setIsStopping(false);
    }
  }, [hasActiveSessionWork, isStopping, latestRunStatus?.stage]);
  useEffect(() => {
    if (!activeSessionId || isSending || !isActiveRunStage(latestRunStatus?.stage)) {
      return;
    }

    const createdMs = new Date(latestRunStatus?.createdAt || 0).getTime();
    if (!Number.isFinite(createdMs) || Date.now() - createdMs < ACTIVE_RUN_STATUS_REFRESH_AFTER_MS) {
      return;
    }

    const refreshKey = `${activeSessionId}:${latestRunStatus?.id || ""}:${latestRunStatus?.stage || ""}:${latestRunStatus?.createdAt || ""}`;
    if (staleRunStatusRefreshRef.current === refreshKey) {
      return;
    }

    staleRunStatusRefreshRef.current = refreshKey;
    scheduleSessionSync(activeSessionId, 0);
  }, [activeSessionId, isSending, latestRunStatus?.createdAt, latestRunStatus?.id, latestRunStatus?.stage]);
  const busySessionIds = useMemo(() => {
    const next = new Set();
    if (activeSessionId && isActiveSessionBusy) {
      next.add(activeSessionId);
    }
    if (subagentPanel.sessionId && isSubagentBusy) {
      next.add(subagentPanel.sessionId);
    }
    return next;
  }, [activeSessionId, isActiveSessionBusy, subagentPanel.sessionId, isSubagentBusy]);

  const sessionSearchNoMatches =
    Boolean(sessionSearchLower) &&
    filteredTaskSessions.length === 0 &&
    filteredRegularSessions.length === 0 &&
    sessions.length > 0;
  const sessionSearchTasksEmptyButOthersMatch =
    Boolean(sessionSearchLower) &&
    taskSessions.length > 0 &&
    filteredTaskSessions.length === 0 &&
    filteredRegularSessions.length > 0;

  const anyPastSidebarSectionOpen = sessionPastTasksOpen || sessionPastRegularOpen;

  function togglePastSessionsShortcut() {
    const anyOpen = sessionPastTasksOpen || sessionPastRegularOpen;
    const expand = !anyOpen;
    setSessionPastTasksOpen(expand && pastFilteredTaskSessions.length > 0);
    setSessionPastRegularOpen(expand && pastFilteredRegularSessions.length > 0);
  }

  function renderSessionSidebarRow(session) {
    return (
      <button
        key={session.id}
        type="button"
        className={`agent-chat-session-item ${session.id === activeSessionId ? "active" : ""}`}
        data-testid={`agent-chat-session-${session.id}`}
        onClick={() => openSessionFromSidebar(session.id)}
        disabled={isLoadingSessions || isSending}
      >
        <div className="agent-chat-session-title">
          {busySessionIds.has(session.id) ? <span className="agent-chat-session-active-dot" aria-hidden="true" /> : null}
          {getSessionDisplayLabel(session)}
        </div>
        <div className="agent-chat-session-meta">
          {session.updatedAt
            ? new Date(session.updatedAt).toLocaleDateString([], {
                month: "short",
                day: "numeric",
                hour: "2-digit",
                minute: "2-digit"
              })
            : "No date"}
        </div>
      </button>
    );
  }

  function toggleExpandedRecord(recordId) {
    if (!recordId) {
      return;
    }
    setExpandedRecordIds((previous) => ({
      ...previous,
      [recordId]: !previous[recordId]
    }));
  }

  function toggleSubagentExpandedRecord(recordId) {
    if (!recordId) {
      return;
    }
    setSubagentExpandedRecordIds((previous) => ({
      ...previous,
      [recordId]: !previous[recordId]
    }));
  }

  function getSubagentStatusLabel(sessionId) {
    if (!sessionId) {
      return "open";
    }
    if (subagentPanel.isOpen && subagentPanel.sessionId === sessionId) {
      if (subagentPanel.loading) {
        return "loading";
      }
      if (subagentPanel.status === "disconnected" || subagentPanel.error) {
        return "disconnected";
      }
      return "live";
    }
    return "open";
  }

  const sessionSidebarMenuIcon = isNarrowChatViewport && isMobileSidebarOpen ? "close" : "menu";

  return (
    <section
      className={`agent-chat-main ${isDragOver ? "drag-over" : ""}${isDesktopSessionsCollapsed ? " agent-chat-sessions-collapsed" : ""}`}
      onDragOver={(event) => {
        event.preventDefault();
        setIsDragOver(true);
      }}
      onDragLeave={(event) => {
        const relatedTarget = event.relatedTarget;
        if (!(relatedTarget instanceof Node) || !event.currentTarget.contains(relatedTarget)) {
          setIsDragOver(false);
        }
      }}
      onDrop={(event) => {
        event.preventDefault();
        setIsDragOver(false);
        addFiles(event.dataTransfer?.files);
      }}
    >
      {isNarrowChatViewport && isMobileSidebarOpen ? (
        <button
          type="button"
          className="agent-chat-sidebar-backdrop"
          aria-label="Close sessions list"
          onClick={closeMobileSessionSidebar}
        />
      ) : null}
      <div
        id="agent-chat-session-sidebar"
        className={`agent-chat-sidebar ${isMobileSidebarOpen ? "mobile-open" : ""}`}
      >
        <div className="agent-chat-sidebar-header">
          <h3>Sessions</h3>
          <div className="agent-chat-sidebar-header-actions">
            <button
              type="button"
              className="agent-chat-sidebar-mobile-close"
              aria-label="Close sessions list"
              onClick={closeMobileSessionSidebar}
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                close
              </span>
            </button>
            <button
              type="button"
              className="agent-chat-icon-button agent-chat-new-session-header"
              data-testid={isNarrowChatViewport ? undefined : "agent-chat-new-session"}
              onClick={() => {
                void createSession();
              }}
              disabled={isSending}
              title="New session"
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                add
              </span>
            </button>
          </div>
        </div>
        <div className="agent-chat-session-search">
          <span className="material-symbols-rounded agent-chat-session-search-icon" aria-hidden="true">
            search
          </span>
          <input
            type="search"
            className="agent-chat-session-search-input"
            data-testid="agent-chat-session-search"
            value={sessionSidebarSearch}
            onChange={(e) => setSessionSidebarSearch(e.target.value)}
            placeholder="Filter sessions…"
            autoComplete="off"
            aria-label="Filter sessions"
            disabled={isLoadingSessions || sessions.length === 0}
          />
          {hasSidebarPastSessions ? (
            <button
              type="button"
              className={`agent-chat-session-filter-btn agent-chat-icon-button ${anyPastSidebarSectionOpen ? "active" : ""}`}
              data-testid="agent-chat-session-past-toggle"
              title={
                anyPastSidebarSectionOpen
                  ? "Collapse “Past” (older than 3 days)"
                  : "Expand “Past” (older than 3 days)"
              }
              aria-label={
                anyPastSidebarSectionOpen
                  ? "Collapse sessions older than three days"
                  : "Expand sessions older than three days"
              }
              aria-pressed={anyPastSidebarSectionOpen}
              disabled={isLoadingSessions}
              onClick={togglePastSessionsShortcut}
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                history
              </span>
            </button>
          ) : null}
        </div>
        <div className="agent-chat-session-list" data-testid="agent-chat-session-list">
          {sessions.length === 0 ? (
            <p className="placeholder-text" style={{ padding: "0 12px" }}>
              {isLoadingSessions ? "Loading sessions..." : "No sessions"}
            </p>
          ) : null}
          {sessionSearchNoMatches ? (
            <p className="placeholder-text" style={{ padding: "0 12px" }}>
              No sessions match your search.
            </p>
          ) : null}
          {taskSessions.length > 0 ? (
            <div className="agent-chat-session-directory">
              <button
                type="button"
                className={`agent-chat-session-directory-toggle ${tasksDirectoryOpen ? "open" : ""}`}
                onClick={() => setTasksDirectoryOpen((prev) => !prev)}
              >
                <span className="material-symbols-rounded agent-chat-session-directory-icon" aria-hidden="true">
                  {tasksDirectoryOpen ? "folder_open" : "folder"}
                </span>
                <span className="agent-chat-session-directory-label">Tasks</span>
                <span className="agent-chat-session-directory-count">
                  {sessionSearchLower ? `${filteredTaskSessions.length}/${taskSessions.length}` : taskSessions.length}
                </span>
                <span className={`material-symbols-rounded agent-chat-session-directory-chevron ${tasksDirectoryOpen ? "open" : ""}`} aria-hidden="true">
                  expand_more
                </span>
              </button>
              {tasksDirectoryOpen ? (
                <div className="agent-chat-session-directory-children">
                  {filteredTaskSessions.length === 0 && sessionSearchTasksEmptyButOthersMatch ? (
                    <p className="placeholder-text agent-chat-session-directory-empty">No matching task sessions.</p>
                  ) : null}
                  {recentFilteredTaskSessions.map((session) => renderSessionSidebarRow(session))}
                  {pastFilteredTaskSessions.length > 0 ? (
                    <div className="agent-chat-session-past">
                      <button
                        type="button"
                        className={`agent-chat-session-past-toggle ${sessionPastTasksOpen ? "open" : ""}`}
                        onClick={() => setSessionPastTasksOpen((o) => !o)}
                      >
                        <span className="material-symbols-rounded agent-chat-session-past-icon" aria-hidden="true">
                          history
                        </span>
                        <span className="agent-chat-session-past-label">Past</span>
                        <span className="agent-chat-session-past-hint">3d+</span>
                        <span className="agent-chat-session-directory-count">{pastFilteredTaskSessions.length}</span>
                        <span
                          className={`material-symbols-rounded agent-chat-session-directory-chevron ${sessionPastTasksOpen ? "open" : ""}`}
                          aria-hidden="true"
                        >
                          expand_more
                        </span>
                      </button>
                      {sessionPastTasksOpen ? (
                        <div className="agent-chat-session-past-children">
                          {pastFilteredTaskSessions.map((session) => renderSessionSidebarRow(session))}
                        </div>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              ) : null}
            </div>
          ) : null}
          {recentFilteredRegularSessions.map((session) => renderSessionSidebarRow(session))}
          {pastFilteredRegularSessions.length > 0 ? (
            <div className="agent-chat-session-past agent-chat-session-past--root">
              <button
                type="button"
                className={`agent-chat-session-past-toggle ${sessionPastRegularOpen ? "open" : ""}`}
                onClick={() => setSessionPastRegularOpen((o) => !o)}
              >
                <span className="material-symbols-rounded agent-chat-session-past-icon" aria-hidden="true">
                  history
                </span>
                <span className="agent-chat-session-past-label">Past</span>
                <span className="agent-chat-session-past-hint">3d+</span>
                <span className="agent-chat-session-directory-count">{pastFilteredRegularSessions.length}</span>
                <span
                  className={`material-symbols-rounded agent-chat-session-directory-chevron ${sessionPastRegularOpen ? "open" : ""}`}
                  aria-hidden="true"
                >
                  expand_more
                </span>
              </button>
              {sessionPastRegularOpen ? (
                <div className="agent-chat-session-past-children">
                  {pastFilteredRegularSessions.map((session) => renderSessionSidebarRow(session))}
                </div>
              ) : null}
            </div>
          ) : null}
        </div>
        <button
          type="button"
          className="agent-chat-new-session-fab"
          data-testid={isNarrowChatViewport ? "agent-chat-new-session" : undefined}
          onClick={() => {
            void createSession();
          }}
          disabled={isSending}
          title="New session"
          aria-label="New session"
        >
          <span className="material-symbols-rounded" aria-hidden="true">
            add
          </span>
        </button>
      </div>

      <div className="agent-chat-main-area">
        <div className="agent-chat-main-head">
          <div className="agent-chat-head-title">
            <button
              type="button"
              className="agent-chat-icon-button agent-chat-mobile-menu-btn"
              onClick={toggleSessionSidebar}
              aria-expanded={isNarrowChatViewport ? isMobileSidebarOpen : !isDesktopSessionsCollapsed}
              aria-controls="agent-chat-session-sidebar"
              aria-label={
                isNarrowChatViewport
                  ? (isMobileSidebarOpen ? "Close sessions list" : "Open sessions list")
                  : (isDesktopSessionsCollapsed ? "Expand sessions panel" : "Collapse sessions panel")
              }
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                {sessionSidebarMenuIcon}
              </span>
            </button>
            {activeSession ? getSessionDisplayLabel(activeSession) : "Select a session"}
            {isDebugSessionFlagOn ? <span className="agent-chat-debug-badge">Debug</span> : null}
            <div ref={modelPickerRef} className="agent-chat-model-picker">
              <div className="provider-model-picker">
                <input
                  className="agent-chat-head-model"
                  value={isModelDropdownOpen ? modelSearch : String(selectedModel || "")}
                  onFocus={() => {
                    if (!isModelDropdownOpen) {
                      setModelSearch(String(selectedModel || ""));
                    }
                    setIsModelDropdownOpen(true);
                  }}
                  onClick={() => {
                    if (!isModelDropdownOpen) {
                      setModelSearch(String(selectedModel || ""));
                    }
                    setIsModelDropdownOpen(true);
                  }}
                  onChange={(event) => {
                    setModelSearch(event.target.value);
                    setIsModelDropdownOpen(true);
                  }}
                  placeholder="Select model id..."
                  autoComplete="off"
                  disabled={isSending || availableModels.length === 0}
                  aria-label="Select chat model"
                />
                {isModelDropdownOpen ? (
                  <div className="provider-model-picker-menu agent-chat-model-dropdown">
                    <div className="provider-model-picker-group">Available models</div>
                    <div className="provider-model-options">
                      {filteredModelOptions.length === 0 ? (
                        <div className="placeholder-text" style={{ padding: "10px 12px" }}>
                          No matching models
                        </div>
                      ) : (
                        filteredModelOptions.map((model) => {
                          const modelId = String(model?.id || "").trim();
                          if (!modelId) {
                            return null;
                          }
                          const isSelected = selectedModel === modelId;
                          return (
                            <button
                              key={modelId}
                              type="button"
                              className={`provider-model-option ${isSelected ? "active" : ""}`}
                              onMouseDown={(event) => event.preventDefault()}
                              onClick={() => {
                                setModelSearch(modelId);
                                void handleModelSwitch(modelId);
                              }}
                            >
                              <div className="provider-model-option-main">
                                <strong>{String(model?.title || modelId).trim() || modelId}</strong>
                                {model?.contextWindow ? (
                                  <span className="provider-model-context">{String(model.contextWindow)}</span>
                                ) : null}
                              </div>
                              <span>{modelId}</span>
                              {Array.isArray(model?.capabilities) && model.capabilities.length > 0 ? (
                                <div className="provider-model-capabilities">
                                  {model.capabilities.map((capability) => (
                                    <span key={`${modelId}-${capability}`}>{String(capability)}</span>
                                  ))}
                                </div>
                              ) : null}
                            </button>
                          );
                        })
                      )}
                    </div>
                  </div>
                ) : null}
              </div>
            </div>
          </div>
          <div className="agent-chat-actions">
            {scopedProjectId && gitBadge?.isGit && (gitBadge.added > 0 || gitBadge.deleted > 0) ? (
              <button
                type="button"
                className="agent-chat-git-toolbar-btn"
                onClick={() => setGitPanelOpen(true)}
                title={
                  gitBadge?.isGit
                    ? `Working tree changes (${gitBadge.branch ? `branch ${gitBadge.branch}` : "git"})`
                    : "Open project git diff (folder is not a git repo)"
                }
                data-testid="agent-chat-git-working-tree-btn"
              >
                <span className="material-symbols-rounded" aria-hidden="true">
                  data_object
                </span>
                <span className="agent-chat-git-toolbar-stats">
                  <span className="agent-chat-git-stat-add">+{gitBadge.added}</span>
                  <span className="agent-chat-git-stat-del">−{gitBadge.deleted}</span>
                </span>
              </button>
            ) : null}
            {scopedProjectId && Array.isArray(projectChangeBatch?.changes) && projectChangeBatch.changes.length > 0 ? (
              <button
                type="button"
                className="agent-chat-git-toolbar-btn"
                onClick={() => {
                  setGitDiffComposeTags((prev) => [
                    ...prev,
                    {
                      id: `changes-${Date.now()}-${Math.random().toString(36).slice(2, 11)}`,
                      label: `${projectChangeBatch.changes.length} workspace changes`,
                      markdown: workspaceChangesMarkdown(projectChangeBatch)
                    }
                  ]);
                }}
                title="Attach recent workspace change list to the composer"
                data-testid="agent-chat-workspace-changes-btn"
              >
                <span className="material-symbols-rounded" aria-hidden="true">
                  folder_code
                </span>
                <span className="agent-chat-git-toolbar-stats">
                  {projectChangeBatch.changes.length}
                </span>
              </button>
            ) : null}
            <div className="agent-chat-share-menu-container" ref={shareMenuRef}>
              <button
                type="button"
                className="agent-chat-icon-button"
                onClick={() => setIsShareMenuOpen((prev) => !prev)}
                disabled={!activeSessionId}
                title={activeSessionId ? "Share session" : "Select a session to share"}
              >
                <span className="material-symbols-rounded" aria-hidden="true">
                  share
                </span>
              </button>
              {activeSessionId && isShareMenuOpen ? (
                <div className="agent-chat-share-dropdown">
                  <button type="button" onClick={handleCopySessionPath}>
                    <span className="material-symbols-rounded" aria-hidden="true">
                      content_copy
                    </span>
                    Copy file path
                  </button>
                  <button type="button" onClick={handleDownloadSession}>
                    <span className="material-symbols-rounded" aria-hidden="true">
                      download
                    </span>
                    Download session
                  </button>
                </div>
              ) : null}
            </div>
            <div className="agent-chat-share-menu-container" ref={debugMenuRef}>
              <button
                type="button"
                className="agent-chat-icon-button"
                onClick={() => setIsDebugMenuOpen((prev) => !prev)}
                disabled={!activeSessionId}
                title={activeSessionId ? "Debug" : "Select a session for debug tools"}
              >
                <span className="material-symbols-rounded" aria-hidden="true">
                  bug_report
                </span>
              </button>
              {activeSessionId && isDebugMenuOpen ? (
                <div className="agent-chat-share-dropdown">
                  <button type="button" onClick={toggleDebugSessionFlag}>
                    <span className="material-symbols-rounded" aria-hidden="true">
                      {isDebugSessionFlagOn ? "check_circle" : "radio_button_unchecked"}
                    </span>
                    {isDebugSessionFlagOn ? "Turn off session debug" : "Turn on session debug"}
                  </button>
                  <button type="button" onClick={handleDebugInjectInstructions} disabled={isSending}>
                    <span className="material-symbols-rounded" aria-hidden="true">
                      rule
                    </span>
                    Add debug instructions (transcript only)
                  </button>
                  <button type="button" onClick={handleDebugPrepareToTranscript} disabled={isSending}>
                    <span className="material-symbols-rounded" aria-hidden="true">
                      description
                    </span>
                    Prepare for analysis — export + note (no agent run)
                  </button>
                  <button type="button" onClick={handleDebugPrepareRunAgent} disabled={isSending}>
                    <span className="material-symbols-rounded" aria-hidden="true">
                      play_arrow
                    </span>
                    Prepare for analysis — run agent now
                  </button>
                </div>
              ) : null}
            </div>
            <button
              type="button"
              className="agent-chat-icon-button danger"
              onClick={handleDeleteActiveSession}
              disabled={!activeSessionId || isSending}
              title="Delete session"
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                delete
              </span>
            </button>
          </div>
        </div>

        <div className="agent-chat-workspace">
          {scopedProjectId ? (
            <ProjectGitDiffPanel
              projectId={scopedProjectId}
              open={gitPanelOpen}
              onClose={() => setGitPanelOpen(false)}
              onAddGitComposeTag={(payload) => {
                setGitDiffComposeTags((prev) => [
                  ...prev,
                  {
                    id: `git-${Date.now()}-${Math.random().toString(36).slice(2, 11)}`,
                    label: payload.label,
                    markdown: payload.markdown
                  }
                ]);
              }}
            />
          ) : null}
          <div className={`agent-chat-workspace-inner ${subagentPanel.isOpen ? "has-subagent" : ""}`}>
            <div className="agent-chat-thread">
              <AgentChatEvents
                isLoadingSession={isLoadingSession}
                isSending={isActiveSessionBusy}
                timelineItems={timelineItems}
                latestRunStatus={latestRunStatus}
                expandedRecordIds={expandedRecordIds}
                onToggleRecord={toggleExpandedRecord}
                onReplyToMessage={handleReplyToMessage}
                onCopyMessage={handleCopyMessage}
                onOpenSubagent={openSubagentPanel}
                getSubagentStatusLabel={getSubagentStatusLabel}
                onAnswerInputRequest={handleAnswerInputRequest}
                onTaskTagClick={openTaskReference}
                onTaskTagHoverStart={handleTaskTagHoverStart}
                onTaskTagHoverEnd={handleTaskTagHoverEnd}
              />

              <div className="agent-chat-compose-sticky-wrap">
                <AgentChatToolApprovalBanner
                  approvals={activePendingToolApprovals}
                  resolvingId={resolvingToolApprovalId}
                  statusText={toolApprovalStatusText}
                  onApprove={(approvalId) => void resolvePendingToolApproval(approvalId, true)}
                  onApproveForSession={(approvalId) => void resolvePendingToolApproval(approvalId, true, "session")}
                  onReject={(approvalId) => void resolvePendingToolApproval(approvalId, false)}
                />

                <AgentChatComposer
                  agentId={agentId}
                  projectId={projectId}
                  inputText={inputText}
                  onInputTextChange={setInputText}
                  isBusy={isActiveSessionBusy}
                  isStopPending={isStopping}
                  onSend={handleSend}
                  onStop={handleStop}
                  pendingFiles={pendingFiles}
                  onRemovePendingFile={removePendingFile}
                  onAddFiles={addFiles}
                  gitDiffComposeTags={gitDiffComposeTags}
                  onRemoveGitDiffComposeTag={(tagId) =>
                    setGitDiffComposeTags((prev) => prev.filter((t) => t.id !== tagId))
                  }
                  fileInputRef={fileInputRef}
                  textareaRef={composeInputRef}
                  replyTarget={replyTarget}
                  onCancelReply={() => setReplyTarget(null)}
                  supportsReasoningEffort={supportsReasoningEffort}
                  reasoningEffort={reasoningEffort}
                  onReasoningEffortChange={setReasoningEffort}
                  chatMode={chatMode}
                  onChatModeChange={setChatMode}
                  availableTasks={knownTaskRecords}
                  slashCommands={slashCommands}
                  onTaskTagClick={openTaskReference}
                  onTaskTagHoverStart={handleTaskTagHoverStart}
                  onTaskTagHoverEnd={handleTaskTagHoverEnd}
                />

                <p className="agent-chat-project-path-hint placeholder-text">
                  {projectId && String(projectId).trim() ? (
                    <>
                      Type <kbd className="agent-chat-path-hint-kbd">@</kbd> to search files and folders in this project.
                    </>
                  ) : (
                    <>
                      Type <kbd className="agent-chat-path-hint-kbd">@</kbd> to search files and folders under the workspace{" "}
                      <code className="agent-chat-path-hint-kbd">projects</code> directory.
                    </>
                  )}
                </p>
              </div>
            </div>

            {subagentPanel.isOpen ? (
              <aside className="agent-chat-subagent-panel" data-testid="agent-chat-subagent-panel">
                <div className="agent-chat-subagent-head">
                  <div className="agent-chat-subagent-title-wrap">
                    <strong>{subagentPanel.title || "Sub-session"}</strong>
                    <small>{subagentPanel.sessionId}</small>
                  </div>
                  <button
                    type="button"
                    className="agent-chat-icon-button"
                    onClick={closeSubagentPanel}
                    title="Back to parent"
                  >
                    <span className="material-symbols-rounded" aria-hidden="true">
                      close
                    </span>
                  </button>
                </div>
                {subagentPanel.error ? (
                  <p className="placeholder-text">{subagentPanel.error}</p>
                ) : (
                  <AgentChatEvents
                    isLoadingSession={subagentPanel.loading}
                    isSending={isSubagentBusy}
                    timelineItems={subagentTimelineItems}
                    latestRunStatus={subagentLatestRunStatus}
                    expandedRecordIds={subagentExpandedRecordIds}
                    onToggleRecord={toggleSubagentExpandedRecord}
                    onReplyToMessage={() => { }}
                    onCopyMessage={handleCopyMessage}
                    onOpenSubagent={openSubagentPanel}
                    getSubagentStatusLabel={getSubagentStatusLabel}
                    onTaskTagClick={openTaskReference}
                    onTaskTagHoverStart={handleTaskTagHoverStart}
                    onTaskTagHoverEnd={handleTaskTagHoverEnd}
                  />
                )}
              </aside>
            ) : null}
          </div>
        </div>
      </div>

      {taskPreview ? (
        <aside
          className="agent-chat-task-preview"
          style={{
            top: `${taskPreview.top}px`,
            left: `${taskPreview.left}px`
          }}
          aria-hidden="true"
        >
          {taskPreview.loading ? (
            <p className="agent-chat-task-preview-empty">Loading task...</p>
          ) : taskPreview.record ? (
            <>
              <div className="agent-chat-task-preview-head">
                <strong>#{taskPreview.record.reference}</strong>
                <span>{taskPreview.record.status}</span>
              </div>
              <p className="agent-chat-task-preview-title">{taskPreview.record.title}</p>
              <div className="agent-chat-task-preview-meta">
                <span>{taskPreview.record.projectName}</span>
                <span>{taskPreview.record.assignee || "Unassigned"}</span>
                {taskPreview.record.priority ? <span>{taskPreview.record.priority}</span> : null}
              </div>
              {taskPreview.record.description ? (
                <p className="agent-chat-task-preview-description">{taskPreview.record.description}</p>
              ) : null}
            </>
          ) : (
            <p className="agent-chat-task-preview-empty">Task not found.</p>
          )}
        </aside>
      ) : null}
    </section>
  );
}

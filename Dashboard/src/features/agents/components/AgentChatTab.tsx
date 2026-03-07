import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  createAgentSession,
  deleteAgentSession,
  fetchAgentConfig,
  fetchAgentTasks,
  fetchProjects,
  fetchAgentSession,
  fetchAgentSessions,
  fetchTaskByReference,
  postAgentSessionControl,
  postAgentSessionMessage,
  subscribeAgentSessionStream
} from "../../../api";

const INLINE_ATTACHMENT_MAX_BYTES = 2 * 1024 * 1024;
const TASK_TAG_PATTERN = /#([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)/g;
const TASK_TAG_REMOVE_PATTERN = /(^|\s)#([A-Za-z0-9][A-Za-z0-9._-]*)(\s?)$/;
const TASK_TAG_QUERY_VALUE_PATTERN = /^[A-Za-z0-9._-]*$/;
const DEFAULT_REASONING_EFFORT = "medium";

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

function splitTextByTaskTags(value) {
  const text = String(value || "");
  if (!text) {
    return [{ kind: "text", value: "" }];
  }

  const parts = [];
  let cursor = 0;
  let match;

  TASK_TAG_PATTERN.lastIndex = 0;
  match = TASK_TAG_PATTERN.exec(text);
  while (match) {
    const full = match[0];
    const reference = normalizeTaskReference(match[1]);
    const start = match.index;
    const end = start + full.length;
    const previousChar = start > 0 ? text[start - 1] : "";

    if (previousChar && /[A-Za-z0-9_-]/.test(previousChar)) {
      match = TASK_TAG_PATTERN.exec(text);
      continue;
    }

    if (start > cursor) {
      parts.push({ kind: "text", value: text.slice(cursor, start) });
    }

    parts.push({ kind: "task", reference, value: full });
    cursor = end;
    match = TASK_TAG_PATTERN.exec(text);
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

function buildTechnicalRecord(eventItem, index) {
  const eventKey = extractEventKey(eventItem, index);

  if (eventItem?.type === "run_status" && eventItem.runStatus) {
    const stage = String(eventItem.runStatus.stage || "").toLowerCase();
    if (stage === "responding" || stage === "done") {
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
      isActive: stage === "thinking" || stage === "searching"
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
      createdAt: eventItem.createdAt
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
        return (
          <React.Fragment key={`text-${index}`}>
            {part.value}
          </React.Fragment>
        );
      })}
    </>
  );
}

const INLINE_TASK_TAG_SELECTOR = ".agent-chat-inline-task-tag";

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

function setEditorContentFromText(root, text) {
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
      fragment.appendChild(document.createTextNode(part.value));
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

function AgentChatEvents({
  isLoadingSession,
  isSending,
  timelineItems,
  latestRunStatus,
  expandedRecordIds,
  onToggleRecord,
  onReplyToMessage,
  onCopyMessage,
  onOpenSession,
  onTaskTagClick,
  onTaskTagHoverStart,
  onTaskTagHoverEnd
}) {
  const scrollRef = useRef(null);

  useEffect(() => {
    if (!scrollRef.current) {
      return;
    }
    scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [timelineItems, isLoadingSession, isSending, latestRunStatus?.id]);

  return (
    <div className="agent-chat-events" ref={scrollRef}>
      {isLoadingSession ? (
        <p className="placeholder-text">Loading session...</p>
      ) : timelineItems.length === 0 && !isSending ? (
        <p className="placeholder-text">No messages yet.</p>
      ) : (
        <>
          {latestRunStatus ? (
            <p className="placeholder-text">
              Status: {latestRunStatus.label}
              {latestRunStatus.details ? ` - ${latestRunStatus.details}` : ""}
            </p>
          ) : null}

          {timelineItems.map((timelineItem, index) => {
            if (timelineItem.kind === "technical" && timelineItem.record) {
              const record = timelineItem.record;
              const isExpanded = Boolean(expandedRecordIds[record.id]);
              const isLatestActive =
                latestRunStatus &&
                record.isActive &&
                record.id.includes(latestRunStatus.id || "");

              return (
                <div key={timelineItem.id || `tech-${index}`} className="agent-chat-tech-entry">
                  <button
                    type="button"
                    className={`agent-chat-tech-trigger ${isExpanded ? "expanded" : ""} ${isLatestActive ? "shimmer" : ""}`}
                    onClick={() => onToggleRecord(record.id)}
                    aria-expanded={isExpanded}
                  >
                    <span className="agent-chat-tech-trigger-label">{record.title || "Technical event"}</span>
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
                            onClick={() => onOpenSession(record.childSessionId)}
                          >
                            Open sub-session
                          </button>
                        ) : null}
                      </div>
                    </article>
                  ) : null}
                </div>
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

            return (
              <article key={eventKey} className={`agent-chat-message ${role}`}>
                <div className="agent-chat-message-head">
                  <strong>{role}</strong>
                  <span>{formatEventTime(eventItem?.message?.createdAt || eventItem?.createdAt)}</span>
                </div>
                <div className="agent-chat-message-body">
                  {thinkingSegments.map((segment) => {
                    const thoughtId = `${eventKey}-thinking-${segment.segmentIndex}`;
                    const thoughtText = String(segment.text || "").trim();
                    return (
                      <AgentChatExpandable
                        key={thoughtId}
                        recordId={thoughtId}
                        icon="psychology_alt"
                        title="Thinking"
                        summary={previewText(thoughtText, "No details")}
                        isExpanded={Boolean(expandedRecordIds[thoughtId])}
                        onToggle={onToggleRecord}
                      >
                        <p className="agent-chat-expandable-text">
                          <TaskTaggedText
                            text={thoughtText || "No details."}
                            onTaskTagClick={onTaskTagClick}
                            onTaskTagHoverStart={onTaskTagHoverStart}
                            onTaskTagHoverEnd={onTaskTagHoverEnd}
                          />
                        </p>
                      </AgentChatExpandable>
                    );
                  })}

                  {visibleSegments.map((segment, segmentIndex) => {
                    const key = `${eventKey}-segment-${segmentIndex}`;
                    if (segment.kind === "attachment" && segment.attachment) {
                      return (
                        <div key={key} className="agent-chat-attachment">
                          <strong>{segment.attachment.name}</strong>
                          <span>{segment.attachment.mimeType}</span>
                        </div>
                      );
                    }

                    return (
                      <p key={key}>
                        <TaskTaggedText
                          text={segment.text || ""}
                          onTaskTagClick={onTaskTagClick}
                          onTaskTagHoverStart={onTaskTagHoverStart}
                          onTaskTagHoverEnd={onTaskTagHoverEnd}
                        />
                      </p>
                    );
                  })}
                </div>
                {role === "assistant" ? (
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
                  </div>
                ) : null}
              </article>
            );
          })}
        </>
      )}
    </div>
  );
}

function AgentChatComposer({
  agentId,
  inputText,
  onInputTextChange,
  isSending,
  onSend,
  onStop,
  pendingFiles,
  onRemovePendingFile,
  onAddFiles,
  fileInputRef,
  textareaRef,
  replyTarget,
  onCancelReply,
  supportsReasoningEffort,
  reasoningEffort,
  onReasoningEffortChange,
  availableTasks = [],
  onTaskTagClick,
  onTaskTagHoverStart,
  onTaskTagHoverEnd
}) {
  const canSend = String(inputText || "").trim().length > 0 || pendingFiles.length > 0;
  const [caretIndex, setCaretIndex] = useState(0);
  const [isInputFocused, setIsInputFocused] = useState(false);
  const [activeSuggestionIndex, setActiveSuggestionIndex] = useState(0);
  const pendingCaretOffsetRef = useRef(null);
  const taskQuery = useMemo(() => getTaskQueryAtCursor(inputText, caretIndex), [inputText, caretIndex]);
  const taskSuggestions = useMemo(
    () => filterTaskSuggestions(availableTasks, taskQuery?.query || ""),
    [availableTasks, taskQuery?.query]
  );
  const isTaskDropdownOpen = isInputFocused && Boolean(taskQuery);
  const editorRef = textareaRef;

  useEffect(() => {
    setActiveSuggestionIndex(0);
  }, [taskQuery?.start, taskQuery?.query, taskSuggestions.length]);

  useEffect(() => {
    const editor = editorRef.current;
    if (!editor) {
      return;
    }

    const currentText = readEditorTextFromElement(editor);
    if (currentText !== inputText) {
      setEditorContentFromText(editor, inputText);
    }

    if (pendingCaretOffsetRef.current != null) {
      const nextCaret = pendingCaretOffsetRef.current;
      pendingCaretOffsetRef.current = null;
      editor.focus();
      setCaretOffsetInEditor(editor, nextCaret);
      setCaretIndex(nextCaret);
    }
  }, [editorRef, inputText]);

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
            disabled={isSending}
          />

          {pendingFiles.length > 0 ? (
            <div className="agent-chat-pending-files">
              {pendingFiles.map((file, index) => (
                <button key={`${file.name}-${index}`} type="button" onClick={() => onRemovePendingFile(index)}>
                  <span>{file.name}</span>
                  <span className="material-symbols-rounded" aria-hidden="true">
                    close
                  </span>
                </button>
              ))}
            </div>
          ) : null}

          <div className="agent-chat-compose-row">
            <button
              type="button"
              className="agent-chat-icon-button"
              onClick={() => fileInputRef.current?.click()}
              disabled={isSending}
              title="Attach files"
            >
              <span className="material-symbols-rounded" aria-hidden="true">
                add
              </span>
            </button>

            <div
              ref={editorRef}
              className="agent-chat-compose-input"
              contentEditable={!isSending}
              suppressContentEditableWarning
              data-placeholder={agentId ? `Message ${agentId}...` : "Message..."}
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
                }

                if (event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) {
                  return;
                }
                event.preventDefault();
                if (!isSending && canSend) {
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
              {supportsReasoningEffort ? (
                <label className="agent-chat-reasoning-select">
                  <span>Reasoning</span>
                  <select
                    value={reasoningEffort}
                    onChange={(event) => onReasoningEffortChange(event.target.value)}
                    disabled={isSending}
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

              {isSending ? (
                <button type="button" className="agent-chat-icon-button agent-chat-send-button danger" onClick={onStop}>
                  <span className="material-symbols-rounded" aria-hidden="true">
                    stop
                  </span>
                </button>
              ) : (
                <button
                  type="submit"
                  className="agent-chat-icon-button agent-chat-send-button"
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

export function AgentChatTab({ agentId }) {
  const [sessions, setSessions] = useState([]);
  const [activeSessionId, setActiveSessionId] = useState(null);
  const [activeSession, setActiveSession] = useState(null);
  const [selectedModel, setSelectedModel] = useState("");
  const [availableModels, setAvailableModels] = useState([]);
  const [isLoadingSessions, setIsLoadingSessions] = useState(true);
  const [isLoadingSession, setIsLoadingSession] = useState(false);
  const [isSending, setIsSending] = useState(false);
  const [isDragOver, setIsDragOver] = useState(false);
  const [inputText, setInputText] = useState("");
  const [pendingFiles, setPendingFiles] = useState([]);
  const [statusText, setStatusText] = useState("Loading sessions...");
  const [optimisticUserEvent, setOptimisticUserEvent] = useState(null);
  const [optimisticAssistantText, setOptimisticAssistantText] = useState("");
  const [replyTarget, setReplyTarget] = useState(null);
  const [reasoningEffort, setReasoningEffort] = useState(DEFAULT_REASONING_EFFORT);
  const [expandedRecordIds, setExpandedRecordIds] = useState({});
  const [knownTaskRecords, setKnownTaskRecords] = useState([]);
  const [taskPreview, setTaskPreview] = useState(null);
  const fileInputRef = useRef(null);
  const composeInputRef = useRef(null);
  const runStateRef = useRef({ sessionId: null, abortController: null });
  const streamCleanupRef = useRef(() => { });
  const taskRecordCacheRef = useRef(new Map());
  const taskRecordInflightRef = useRef(new Map());
  const activeModelOption = useMemo(
    () => availableModels.find((model) => String(model?.id || "").trim() === selectedModel) || null,
    [availableModels, selectedModel]
  );
  const supportsReasoningEffort = useMemo(() => {
    const capabilities = Array.isArray(activeModelOption?.capabilities) ? activeModelOption.capabilities : [];
    return capabilities.some((capability) => String(capability || "").toLowerCase() === "reasoning");
  }, [activeModelOption]);

  useEffect(() => {
    document.body.classList.add("agent-chat-no-page-scroll");
    return () => {
      streamCleanupRef.current?.();
      streamCleanupRef.current = () => { };
      document.body.classList.remove("agent-chat-no-page-scroll");
    };
  }, []);

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
    const normalizedReference = normalizeTaskReference(taskReference);
    if (!normalizedReference) {
      return;
    }

    const pathname = `/tasks/${encodeURIComponent(normalizedReference)}`;
    const nextPath = `${pathname}${window.location.search}${window.location.hash}`;
    if (window.location.pathname === pathname) {
      return;
    }
    window.history.pushState({}, "", nextPath);
    window.dispatchEvent(new PopStateEvent("popstate"));
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
    let isCancelled = false;

    async function bootstrap() {
      setIsLoadingSessions(true);
      setActiveSessionId(null);
      setActiveSession(null);
      setPendingFiles([]);
      setInputText("");
      setOptimisticUserEvent(null);
      setOptimisticAssistantText("");
      setReplyTarget(null);
      setExpandedRecordIds({});
      setSelectedModel("");
      setAvailableModels([]);
      setReasoningEffort(DEFAULT_REASONING_EFFORT);
      setIsSending(false);
      streamCleanupRef.current?.();
      streamCleanupRef.current = () => { };
      runStateRef.current.abortController?.abort();
      runStateRef.current.sessionId = null;
      runStateRef.current.abortController = null;

      const [sessionsResponse, configResponse] = await Promise.all([fetchAgentSessions(agentId), fetchAgentConfig(agentId)]);
      if (isCancelled) {
        return;
      }

      if (configResponse && typeof configResponse === "object") {
        setSelectedModel(String(configResponse.selectedModel || "").trim());
        setAvailableModels(Array.isArray(configResponse.availableModels) ? configResponse.availableModels : []);
      }

      const nextSessions = Array.isArray(sessionsResponse) ? sortSessionsByUpdate(sessionsResponse) : [];
      setSessions(nextSessions);
      setIsLoadingSessions(false);

      if (!Array.isArray(sessionsResponse)) {
        setStatusText("Failed to load sessions.");
        return;
      }

      if (nextSessions.length === 0) {
        setStatusText("No sessions yet. Create one.");
        return;
      }

      setStatusText(`Loaded ${nextSessions.length} sessions`);
      const nextSessionID = nextSessions[0].id;
      setActiveSessionId(nextSessionID);
      await openSession(nextSessionID, isCancelled);
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
      runStateRef.current.abortController?.abort();
      runStateRef.current.sessionId = null;
      runStateRef.current.abortController = null;
    };
  }, [agentId]);

  async function openSession(sessionId, isCancelled = false) {
    if (!sessionId) {
      return;
    }
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
      }
      setIsLoadingSession(false);
    }
  }

  async function refreshSessions(preferredSessionId = null) {
    const response = await fetchAgentSessions(agentId);
    if (!Array.isArray(response)) {
      setStatusText("Failed to refresh sessions.");
      return;
    }

    const nextSessions = sortSessionsByUpdate(response);
    setSessions(nextSessions);

    if (nextSessions.length === 0) {
      setActiveSessionId(null);
      setActiveSession(null);
      setStatusText("No sessions yet. Create one.");
      return;
    }

    const targetId =
      preferredSessionId && nextSessions.some((item) => item.id === preferredSessionId)
        ? preferredSessionId
        : nextSessions[0].id;
    setActiveSessionId(targetId);
    await openSession(targetId);
  }

  async function createSession(parentSessionId = null) {
    const response = await createAgentSession(agentId, parentSessionId ? { parentSessionId } : {});
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

  function latestRunStatusFromEvents(events) {
    return [...events]
      .reverse()
      .find((eventItem) => eventItem.type === "run_status" && eventItem.runStatus)?.runStatus;
  }

  function mergeSessionSummary(summary) {
    if (!summary?.id) {
      return;
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
        setOptimisticAssistantText(deltaText);
      }
      return;
    }

    if (streamEvent) {
      applyStreamEvent(summary, streamEvent);

      if (streamEvent.type === "run_status" && streamEvent.runStatus) {
        const detailsText = streamEvent.runStatus.details ? ` - ${streamEvent.runStatus.details}` : "";
        setStatusText(`Status: ${streamEvent.runStatus.label || streamEvent.runStatus.stage}${detailsText}`);

        if (streamEvent.runStatus.stage === "responding" && streamEvent.runStatus.expandedText) {
          setOptimisticAssistantText(String(streamEvent.runStatus.expandedText));
        }
        if (streamEvent.runStatus.stage === "done" || streamEvent.runStatus.stage === "interrupted") {
          setOptimisticAssistantText("");
        }
      }

      if (streamEvent.type === "message" && streamEvent.message?.role === "assistant") {
        const streamedText = segmentsToPlainText(streamEvent.message.segments || []);
        if (streamedText) {
          setOptimisticAssistantText(streamedText);
        }
      }
      if (streamEvent.type === "message" && streamEvent.message?.role === "user") {
        setOptimisticUserEvent(null);
      }
    }

    if (kind === "session_closed") {
      setStatusText(String(update.message || "Session stream closed."));
    } else if (kind === "session_error") {
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

  async function handleSend(event) {
    event?.preventDefault?.();
    if (isSending) {
      return;
    }

    const trimmed = String(inputText || "").trim();
    const replyContext = replyTarget ? `Reply to assistant: "${replyTarget.text}"` : "";
    const contentForSend = trimmed ? (replyContext ? `${replyContext}\n\n${trimmed}` : trimmed) : replyContext;
    if (!contentForSend && pendingFiles.length === 0) {
      return;
    }

    let sessionId = activeSessionId;
    if (!sessionId) {
      const created = await createSession();
      if (!created) {
        return;
      }
      sessionId = created.id;
    }

    const localMessageSegments = [];
    if (trimmed) {
      localMessageSegments.push({ kind: "text", text: trimmed });
    } else if (replyTarget) {
      localMessageSegments.push({ kind: "text", text: `↪ ${replyTarget.text}` });
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
    setOptimisticAssistantText("");
    setIsSending(true);
    setStatusText("Thinking...");
    setInputText("");
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
          reasoningEffort: supportsReasoningEffort ? reasoningEffort : undefined
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
      setOptimisticAssistantText("");
      setIsSending(false);
    }
  }

  async function handleStop() {
    if (!isSending) {
      return;
    }

    const sessionId = runStateRef.current.sessionId || activeSessionId;
    runStateRef.current.abortController?.abort();
    runStateRef.current.abortController = null;
    runStateRef.current.sessionId = null;
    setStatusText("Stopping...");

    if (sessionId) {
      const response = await postAgentSessionControl(agentId, sessionId, {
        action: "interrupt",
        requestedBy: "dashboard",
        reason: "Stopped by user"
      });
      await refreshSessions(sessionId);
      if (response) {
        setStatusText("Interrupted.");
      } else {
        setStatusText("Failed to interrupt.");
      }
    }

    setOptimisticUserEvent(null);
    setOptimisticAssistantText("");
    setIsSending(false);
  }

  async function handleDeleteActiveSession() {
    if (!activeSessionId) {
      return;
    }
    if (!window.confirm("Delete this session?")) {
      return;
    }

    const success = await deleteAgentSession(agentId, activeSessionId);
    if (!success) {
      setStatusText("Failed to delete session.");
      return;
    }
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
  const latestRunStatus = latestRunStatusFromEvents(events);
  const persistedMessages = events.filter(
    (eventItem) =>
      eventItem.type === "message" &&
      eventItem.message &&
      (eventItem.message.role === "user" || eventItem.message.role === "assistant")
  );
  const streamedAssistantText = isSending
    ? optimisticAssistantText
    : optimisticAssistantText || latestRespondingTextFromEvents(events);
  const latestPersistedAssistantEvent = [...persistedMessages]
    .reverse()
    .find((eventItem) => eventItem?.message?.role === "assistant");
  const latestPersistedAssistantText = latestPersistedAssistantEvent?.message?.segments
    ? segmentsToPlainText(latestPersistedAssistantEvent.message.segments)
    : "";
  const normalizedStreamedAssistantText = String(streamedAssistantText || "").trim();
  const hasDuplicatedPersistedAssistant =
    normalizedStreamedAssistantText.length > 0 &&
    normalizedStreamedAssistantText === String(latestPersistedAssistantText || "").trim();
  const shouldRenderStreamMessage =
    (isSending || latestRunStatus?.stage === "responding") &&
    normalizedStreamedAssistantText.length > 0 &&
    !hasDuplicatedPersistedAssistant;
  const timelineItems = [];
  for (let index = 0; index < events.length; index += 1) {
    const eventItem = events[index];
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

    const technicalRecord = buildTechnicalRecord(eventItem, index);
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
    timelineItems.push({
      id: "local-assistant-stream",
      kind: "message",
      event: {
        id: "local-assistant-stream",
        createdAt: new Date().toISOString(),
        type: "message",
        message: {
          role: "assistant",
          createdAt: new Date().toISOString(),
          segments: [
            {
              kind: "text",
              text: streamedAssistantText || "Thinking..."
            }
          ]
        }
      }
    });
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

  return (
    <section
      className={`agent-chat-main ${isDragOver ? "drag-over" : ""}`}
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
      <div className="agent-chat-sidebar">
        <div className="agent-chat-sidebar-header">
          <h3>Sessions</h3>
          <button
            type="button"
            className="agent-chat-icon-button"
            onClick={() => createSession()}
            disabled={isSending}
            title="New session"
          >
            <span className="material-symbols-rounded" aria-hidden="true">
              add
            </span>
          </button>
        </div>
        <div className="agent-chat-session-list">
          {sessions.length === 0 ? (
            <p className="placeholder-text" style={{ padding: "0 12px" }}>
              {isLoadingSessions ? "Loading sessions..." : "No sessions"}
            </p>
          ) : null}
          {sessions.map((session) => (
            <button
              key={session.id}
              type="button"
              className={`agent-chat-session-item ${session.id === activeSessionId ? "active" : ""}`}
              onClick={() => openSession(session.id)}
              disabled={isLoadingSessions || isSending}
            >
              <div className="agent-chat-session-title">
                {getSessionDisplayLabel(session)}
              </div>
              <div className="agent-chat-session-meta">
                {session.updatedAt ? new Date(session.updatedAt).toLocaleDateString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "No date"}
              </div>
            </button>
          ))}
        </div>
      </div>

      <div className="agent-chat-main-area">
        <div className="agent-chat-main-head">
          <div className="agent-chat-head-title">
            {activeSession ? getSessionDisplayLabel(activeSession) : "Select a session"}
          </div>
          <div className="agent-chat-actions">
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
          <div className="agent-chat-thread">
            <AgentChatEvents
              isLoadingSession={isLoadingSession}
              isSending={isSending}
              timelineItems={timelineItems}
              latestRunStatus={latestRunStatus}
              expandedRecordIds={expandedRecordIds}
              onToggleRecord={toggleExpandedRecord}
              onReplyToMessage={handleReplyToMessage}
              onCopyMessage={handleCopyMessage}
              onOpenSession={openSession}
              onTaskTagClick={openTaskReference}
              onTaskTagHoverStart={handleTaskTagHoverStart}
              onTaskTagHoverEnd={handleTaskTagHoverEnd}
            />

            <div className="agent-chat-compose-sticky-wrap">
              <AgentChatComposer
                agentId={agentId}
                inputText={inputText}
                onInputTextChange={setInputText}
                isSending={isSending}
                onSend={handleSend}
                onStop={handleStop}
                pendingFiles={pendingFiles}
                onRemovePendingFile={removePendingFile}
                onAddFiles={addFiles}
                fileInputRef={fileInputRef}
                textareaRef={composeInputRef}
                replyTarget={replyTarget}
                onCancelReply={() => setReplyTarget(null)}
                supportsReasoningEffort={supportsReasoningEffort}
                reasoningEffort={reasoningEffort}
                onReasoningEffortChange={setReasoningEffort}
                availableTasks={knownTaskRecords}
                onTaskTagClick={openTaskReference}
                onTaskTagHoverStart={handleTaskTagHoverStart}
                onTaskTagHoverEnd={handleTaskTagHoverEnd}
              />

              <p className="agent-chat-status-line placeholder-text">{statusText}</p>
            </div>
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

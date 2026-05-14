import { sessionChannelMatchesBinding } from "../../shared/channelGatewayScope";

export const ACTIVE_WORKER_STATUSES = new Set(["queued", "running", "waitinginput", "waiting_input"]);

export const PROJECT_TABS = [
  { id: "overview", title: "Overview" },
  { id: "chat", title: "Chat" },
  { id: "files", title: "Files" },
  { id: "tasks", title: "Tasks" },
  { id: "analytics", title: "Analytics" },
  { id: "workers", title: "Workers" },
  { id: "visor", title: "Visor" },
  { id: "memory", title: "Memory" },
  { id: "settings", title: "Settings" }
];

export const TASK_STATUSES = [
  { id: "backlog", title: "Backlog" },
  { id: "ready", title: "Ready to work" },
  { id: "in_progress", title: "In progress" },
  { id: "waiting_input", title: "Waiting Input" },
  { id: "blocked", title: "Blocked" },
  { id: "needs_review", title: "Needs Review" },
  { id: "done", title: "Done" }
];

export const TASK_KINDS = [
  { id: "planning", title: "Planning" },
  { id: "execution", title: "Execution" },
  { id: "bugfix", title: "Bugfix" }
];

export const LOOP_MODES = [
  { id: "human", title: "Human in the loop" },
  { id: "agent", title: "Agent in the loop" }
];

export const TASK_PRIORITIES = ["low", "medium", "high"];
export const TASK_PRIORITY_LABELS = {
  low: "Low",
  medium: "Medium",
  high: "High"
};

export const TASK_PRIORITY_ORDER = {
  high: 0,
  medium: 1,
  low: 2
};

export const TASK_STATUS_COLORS = {
  backlog: "#94a3b8",
  ready: "#3b82f6",
  in_progress: "#f59e0b",
  waiting_input: "#e879f9",
  blocked: "#ef4444",
  needs_review: "#a78bfa",
  done: "#22c55e"
};

export const TASK_PRIORITY_ICONS = {
  low: "remove",
  medium: "signal_cellular_alt_2_bar",
  high: "signal_cellular_alt"
};

export const PROJECT_TAB_SET = new Set(PROJECT_TABS.map((tab) => tab.id));
export const TASK_STATUS_SET = new Set(TASK_STATUSES.map((status) => status.id));
export const TASK_PRIORITY_SET = new Set(TASK_PRIORITIES);

export function createId(prefix) {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
}

export function toSlug(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

export function emptyTaskDraft(initialStatus = "backlog") {
  return {
    title: "",
    description: "",
    priority: "medium",
    status: TASK_STATUS_SET.has(initialStatus) ? initialStatus : "backlog",
    kind: "",
    loopModeOverride: "",
    actorId: "",
    teamId: ""
  };
}

export function normalizeChat(chat, index = 0) {
  const fallback = `channel-${index + 1}`;
  return {
    id: String(chat?.id || createId("chat")).trim(),
    title: String(chat?.title || `Channel ${index + 1}`).trim(),
    channelId: String(chat?.channelId || fallback).trim() || fallback
  };
}

export function normalizeTask(task, index = 0) {
  const status = String(task?.status || "backlog").trim().toLowerCase();
  const priority = String(task?.priority || "medium").trim().toLowerCase();

  return {
    id: String(task?.id || createId("task")).trim() || createId(`task-${index + 1}`),
    title: String(task?.title || `Task ${index + 1}`).trim(),
    description: String(task?.description || "").trim(),
    status: TASK_STATUS_SET.has(status) ? status : "backlog",
    priority: TASK_PRIORITY_SET.has(priority) ? priority : "medium",
    kind: String(task?.kind || "").trim(),
    loopModeOverride: String(task?.loopModeOverride || "").trim(),
    actorId: String(task?.actorId || "").trim(),
    teamId: String(task?.teamId || "").trim(),
    claimedActorId: String(task?.claimedActorId || "").trim(),
    claimedAgentId: String(task?.claimedAgentId || "").trim(),
    worktreeBranch: String(task?.worktreeBranch || "").trim() || null,
    swarmId: String(task?.swarmId || "").trim(),
    swarmTaskId: String(task?.swarmTaskId || "").trim(),
    swarmParentTaskId: String(task?.swarmParentTaskId || "").trim(),
    swarmDependencyIds: Array.isArray(task?.swarmDependencyIds)
      ? task.swarmDependencyIds.map((id) => String(id).trim()).filter(Boolean)
      : [],
    swarmDepth: Number.isFinite(Number(task?.swarmDepth)) ? Number(task.swarmDepth) : null,
    swarmActorPath: Array.isArray(task?.swarmActorPath)
      ? task.swarmActorPath.map((id) => String(id).trim()).filter(Boolean)
      : [],
    isArchived: Boolean(task?.isArchived),
    tags: Array.isArray(task?.tags)
      ? task.tags.map((tag) => String(tag).trim()).filter(Boolean)
      : [],
    externalMetadata: task?.externalMetadata && typeof task.externalMetadata === "object"
      ? task.externalMetadata
      : null,
    createdAt: String(task?.createdAt || new Date().toISOString()),
    updatedAt: String(task?.updatedAt || task?.createdAt || new Date().toISOString())
  };
}

export function normalizeProject(project, index = 0) {
  const id = String(project?.id || createId("project")).trim() || createId(`project-${index + 1}`);
  const fallbackName = `Project ${index + 1}`;
  const name = String(project?.name || fallbackName).trim() || fallbackName;
  const channelsSource = Array.isArray(project?.channels) ? project.channels : project?.chats;

  const chats = Array.isArray(channelsSource)
    ? channelsSource.map((chat, chatIndex) => normalizeChat(chat, chatIndex)).filter((chat) => chat.channelId.length > 0)
    : [];

  const tasks = Array.isArray(project?.tasks)
    ? project.tasks.map((task, taskIndex) => normalizeTask(task, taskIndex)).filter((task) => task.title.length > 0)
    : [];

  const heartbeatRaw = project?.heartbeat;
  const heartbeat = heartbeatRaw && typeof heartbeatRaw === "object"
    ? {
      enabled: Boolean(heartbeatRaw.enabled),
      intervalMinutes: Number.isFinite(Number(heartbeatRaw.intervalMinutes))
        ? Number(heartbeatRaw.intervalMinutes)
        : 5
    }
    : { enabled: false, intervalMinutes: 5 };

  const reviewSettingsRaw = project?.reviewSettings;
  const reviewSettings = reviewSettingsRaw && typeof reviewSettingsRaw === "object"
    ? {
      enabled: Boolean(reviewSettingsRaw.enabled),
      approvalMode: String(reviewSettingsRaw.approvalMode || "human").trim() || "human",
      autonomousMode: String(reviewSettingsRaw.autonomousMode || "off").trim() || "off"
    }
    : { enabled: false, approvalMode: "human", autonomousMode: "off" };

  return {
    id,
    name,
    description: String(project?.description || "").trim(),
    icon: String(project?.icon || "").trim() || null,
    createdAt: String(project?.createdAt || new Date().toISOString()),
    updatedAt: String(project?.updatedAt || project?.createdAt || new Date().toISOString()),
    chats,
    tasks,
    actors: Array.isArray(project?.actors) ? project.actors : [],
    teams: Array.isArray(project?.teams) ? project.teams : [],
    models: Array.isArray(project?.models) ? project.models : [],
    agentFiles: Array.isArray(project?.agentFiles) ? project.agentFiles : [],
    heartbeat,
    repoPath: String(project?.repoPath || "").trim() || null,
    reviewSettings,
    taskLoopMode: String(project?.taskLoopMode || "human").trim(),
    isArchived: Boolean(project?.isArchived)
  };
}

export function sortTasksByDate(tasks) {
  return [...tasks].sort((left, right) => {
    return new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime();
  });
}

export function buildTaskReference(projectId, taskId) {
  const normalizedProjectId = String(projectId || "").trim();
  const normalizedTaskId = String(taskId || "").trim();
  if (!normalizedProjectId || !normalizedTaskId) {
    return normalizedTaskId;
  }
  return `${normalizedProjectId}-${normalizedTaskId}`;
}

export function resolveTaskByReference(projectId, tasks, taskReference) {
  const normalizedReference = String(taskReference || "").trim();
  if (!normalizedReference) {
    return null;
  }

  const normalizedProjectId = String(projectId || "").trim();
  const projectPrefix = normalizedProjectId ? `${normalizedProjectId}-` : "";
  const taskList = Array.isArray(tasks) ? tasks : [];

  const exact = taskList.find((task) => String(task?.id || "").trim() === normalizedReference);
  if (exact) {
    return exact;
  }

  const prefixed = taskList.find((task) => buildTaskReference(normalizedProjectId, task?.id) === normalizedReference);
  if (prefixed) {
    return prefixed;
  }

  if (projectPrefix && normalizedReference.startsWith(projectPrefix)) {
    const plainTaskId = normalizedReference.slice(projectPrefix.length).trim();
    if (!plainTaskId) {
      return null;
    }
    return taskList.find((task) => String(task?.id || "").trim() === plainTaskId) || null;
  }

  return null;
}

const AGENT_CHANNEL_PREFIX = "agent:";
const AGENT_SESSION_MARKER = ":session:";

export function parseAgentWorkerChannelId(channelId) {
  const raw = String(channelId || "").trim();
  if (!raw.startsWith(AGENT_CHANNEL_PREFIX)) {
    return null;
  }
  const sessionIdx = raw.indexOf(AGENT_SESSION_MARKER);
  if (sessionIdx >= 0) {
    const agentId = raw.slice(AGENT_CHANNEL_PREFIX.length, sessionIdx);
    const sessionId = raw.slice(sessionIdx + AGENT_SESSION_MARKER.length);
    if (agentId && sessionId) {
      return { agentId, sessionId };
    }
    return null;
  }
  const agentId = raw.slice(AGENT_CHANNEL_PREFIX.length);
  if (agentId) {
    return { agentId, sessionId: null };
  }
  return null;
}

export function workersForProject(project, workers) {
  if (!project) {
    return [];
  }

  const bindings = (Array.isArray(project.chats) ? project.chats : [])
    .map((chat) => String(chat.channelId || "").trim())
    .filter(Boolean);
  return (Array.isArray(workers) ? workers : []).filter((worker) => {
    const channelId = String(worker?.channelId || "").trim();
    if (!channelId) {
      return false;
    }
    return bindings.some((binding) => sessionChannelMatchesBinding(channelId, binding));
  });
}

export function activeWorkersForProject(project, workers) {
  return workersForProject(project, workers).filter((worker) => {
    const status = String(worker?.status || "").trim().toLowerCase();
    return ACTIVE_WORKER_STATUSES.has(status);
  });
}

export function buildTaskCounts(tasks) {
  const counts = { total: tasks.length };
  for (const status of TASK_STATUSES) {
    counts[status.id] = tasks.filter((task) => task.status === status.id).length;
  }
  counts.not_done = Math.max(0, counts.total - counts.done);
  return counts;
}

export function buildOverviewMetrics(project, taskCounts, activeWorkers, chatSnapshots) {
  const totalTasks = Number(taskCounts?.total || 0);
  const doneTasks = Number(taskCounts?.done || 0);
  const cancelledTasks = Number(taskCounts?.cancelled || 0);
  const blockedTasks = Number(taskCounts?.blocked || 0);
  const openTasks = Math.max(0, totalTasks - doneTasks);
  const needsAttention = blockedTasks + Number(taskCounts?.needs_review || 0);
  const channelActivity = buildChannelActivity(project, chatSnapshots, activeWorkers);
  const activeChannelCount = channelActivity.filter((channel) => channel.hasActivity).length;
  const relatedChannelCount = Array.isArray(project?.chats) ? project.chats.length : 0;
  const activeWorkerCount = Array.isArray(activeWorkers) ? activeWorkers.length : 0;

  return [
    {
      id: "open",
      label: "Open tasks",
      value: openTasks,
      sublabel: totalTasks > 0 ? `${doneTasks} done` : "No tasks yet",
      tabId: "tasks"
    },
    {
      id: "attention",
      label: "Needs attention",
      value: needsAttention,
      sublabel: `${blockedTasks} blocked / ${Number(taskCounts?.needs_review || 0)} review`,
      tabId: "tasks"
    },
    {
      id: "outcomes",
      label: "Outcomes",
      value: `${doneTasks} / ${blockedTasks} / ${cancelledTasks}`,
      sublabel: "done / blocked / cancelled",
      tabId: "analytics"
    },
    {
      id: "workers",
      label: "Active workers",
      value: activeWorkerCount,
      sublabel: activeWorkerCount > 0 ? "Live execution in progress" : "No active workers",
      tabId: "workers"
    },
    {
      id: "channels",
      label: "Active channels",
      value: activeChannelCount,
      sublabel: relatedChannelCount > 0 ? `${relatedChannelCount} configured` : "No channels",
      tabId: "chat"
    }
  ];
}

export function buildAttentionTasks(tasks) {
  const taskList = Array.isArray(tasks) ? tasks : [];
  return taskList
    .filter((task) => task.status === "blocked" || task.status === "needs_review")
    .sort((left, right) => {
      const leftStatusRank = left.status === "blocked" ? 0 : 1;
      const rightStatusRank = right.status === "blocked" ? 0 : 1;
      if (leftStatusRank !== rightStatusRank) {
        return leftStatusRank - rightStatusRank;
      }

      const leftPriorityRank = TASK_PRIORITY_ORDER[left.priority] ?? TASK_PRIORITY_ORDER.medium;
      const rightPriorityRank = TASK_PRIORITY_ORDER[right.priority] ?? TASK_PRIORITY_ORDER.medium;
      if (leftPriorityRank !== rightPriorityRank) {
        return leftPriorityRank - rightPriorityRank;
      }

      return new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime();
    });
}

function resolveMessageTimestamp(message) {
  const raw = message?.createdAt || message?.updatedAt || message?.ts || null;
  const time = raw ? new Date(raw).getTime() : Number.NaN;
  return Number.isNaN(time) ? 0 : time;
}

export function buildChannelActivity(project, chatSnapshots, activeWorkers) {
  const chats = Array.isArray(project?.chats) ? project.chats : [];
  const activeWorkerCountByChannel = new Map();

  for (const worker of Array.isArray(activeWorkers) ? activeWorkers : []) {
    const channelId = String(worker?.channelId || "").trim();
    if (!channelId) {
      continue;
    }
    activeWorkerCountByChannel.set(channelId, (activeWorkerCountByChannel.get(channelId) || 0) + 1);
  }

  return chats
    .map((chat) => {
      const channelId = String(chat?.channelId || "").trim();
      const snapshot = chatSnapshots?.[channelId];
      const messages = Array.isArray(snapshot?.messages) ? snapshot.messages : [];
      const lastMessage = messages.length > 0 ? messages[messages.length - 1] : null;
      const lastMessageAt = resolveMessageTimestamp(lastMessage);
      const activeWorkerCount = activeWorkerCountByChannel.get(channelId) || 0;
      const lastDecision = snapshot?.lastDecision || null;
      const previewText = lastMessage?.content
        ? String(lastMessage.content).replace(/\s+/g, " ").trim()
        : lastDecision?.reason
          ? String(lastDecision.reason).replace(/\s+/g, " ").trim()
          : "";

      return {
        id: String(chat?.id || channelId),
        channelId,
        title: String(chat?.title || channelId || "Channel"),
        messageCount: messages.length,
        activeWorkerCount,
        lastMessageUserId: String(lastMessage?.userId || "").trim(),
        lastMessageAt: lastMessageAt > 0 ? new Date(lastMessageAt).toISOString() : "",
        lastDecision,
        previewText,
        hasActivity: activeWorkerCount > 0 || messages.length > 0
      };
    })
    .sort((left, right) => {
      if (left.activeWorkerCount !== right.activeWorkerCount) {
        return right.activeWorkerCount - left.activeWorkerCount;
      }
      return new Date(right.lastMessageAt || 0).getTime() - new Date(left.lastMessageAt || 0).getTime();
    });
}

export function buildProjectReadiness(project) {
  const repoPath = String(project?.repoPath || "").trim();
  const reviewEnabled = Boolean(project?.reviewSettings?.enabled);
  const approvalMode = String(project?.reviewSettings?.approvalMode || "human").trim() || "human";
  const heartbeatEnabled = Boolean(project?.heartbeat?.enabled);
  const heartbeatInterval = Number.isFinite(Number(project?.heartbeat?.intervalMinutes))
    ? Number(project.heartbeat.intervalMinutes)
    : 5;
  const modelCount = Array.isArray(project?.models) ? project.models.length : 0;
  const agentFileCount = Array.isArray(project?.agentFiles) ? project.agentFiles.length : 0;

  return [
    {
      id: "repo",
      label: "Repository",
      value: repoPath ? "Connected" : "Missing",
      detail: repoPath || "Attach a repo path in settings"
    },
    {
      id: "review",
      label: "Review flow",
      value: reviewEnabled ? "Enabled" : "Off",
      detail: reviewEnabled ? `Mode: ${approvalMode}` : "Review gate is disabled"
    },
    {
      id: "heartbeat",
      label: "Heartbeat",
      value: heartbeatEnabled ? "On" : "Off",
      detail: heartbeatEnabled ? `Every ${heartbeatInterval} min` : "No scheduled checks"
    },
    {
      id: "models",
      label: "Models",
      value: String(modelCount),
      detail: modelCount > 0 ? "Project model overrides available" : "Using default runtime models"
    },
    {
      id: "files",
      label: "Agent files",
      value: String(agentFileCount),
      detail: agentFileCount > 0 ? "Attached to this project" : "No project-specific files"
    }
  ];
}

export function buildSwarmGroups(tasks) {
  const bySwarmId = new Map();
  for (const task of tasks) {
    if (!task.swarmId) {
      continue;
    }
    if (!bySwarmId.has(task.swarmId)) {
      bySwarmId.set(task.swarmId, []);
    }
    bySwarmId.get(task.swarmId).push(task);
  }

  return Array.from(bySwarmId.entries())
    .sort((left, right) => left[0].localeCompare(right[0]))
    .map(([swarmId, swarmTasks]) => {
      const taskBySwarmTaskId = new Map();
      for (const task of swarmTasks) {
        if (task.swarmTaskId) {
          taskBySwarmTaskId.set(task.swarmTaskId, task);
        }
      }

      const childrenByParent = new Map();
      for (const task of swarmTasks) {
        if (task.swarmTaskId === "root") {
          continue;
        }
        const parentKey = task.swarmParentTaskId && taskBySwarmTaskId.has(task.swarmParentTaskId)
          ? task.swarmParentTaskId
          : "root";
        if (!childrenByParent.has(parentKey)) {
          childrenByParent.set(parentKey, []);
        }
        childrenByParent.get(parentKey).push(task);
      }

      for (const [parentKey, children] of childrenByParent.entries()) {
        childrenByParent.set(parentKey, [...children].sort((left, right) => {
          if ((left.swarmDepth ?? 0) !== (right.swarmDepth ?? 0)) {
            return (left.swarmDepth ?? 0) - (right.swarmDepth ?? 0);
          }
          return new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime();
        }));
      }

      const rootTask = swarmTasks.find((task) => task.swarmTaskId === "root") || null;
      const roots = rootTask ? [rootTask] : (childrenByParent.get("root") || []);

      return {
        swarmId,
        tasks: swarmTasks,
        roots,
        childrenByParent
      };
    });
}

export function formatRelativeTime(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) {
    return "just now";
  }

  const diffMs = Date.now() - date.getTime();
  const diffMinutes = Math.round(diffMs / 60000);
  if (Math.abs(diffMinutes) < 1) {
    return "just now";
  }

  if (Math.abs(diffMinutes) < 60) {
    return `${diffMinutes}m ago`;
  }

  const diffHours = Math.round(diffMinutes / 60);
  if (Math.abs(diffHours) < 24) {
    return `${diffHours}h ago`;
  }

  const diffDays = Math.round(diffHours / 24);
  return `${diffDays}d ago`;
}

export function extractCreatedItems(project, snapshotsByChannel) {
  const result = [];
  const seen = new Set();

  for (const chat of project.chats) {
    const snapshot = snapshotsByChannel[chat.channelId];
    const messages = Array.isArray(snapshot?.messages) ? snapshot.messages : [];

    for (const message of messages) {
      const content = String(message?.content || "");
      if (!content) {
        continue;
      }

      const artifactRegex = /\bartifact\s+([a-f0-9-]{8,})/gi;
      let artifactMatch = artifactRegex.exec(content);
      while (artifactMatch) {
        const artifactId = artifactMatch[1];
        const key = `artifact:${artifactId}`;
        if (!seen.has(key)) {
          seen.add(key);
          result.push({
            key,
            type: "artifact",
            value: artifactId,
            channelId: chat.channelId
          });
        }
        artifactMatch = artifactRegex.exec(content);
      }

      const fileRegex = /(?:^|[\s"'`])((?:\.?\/?[\w-]+(?:\/[\w.-]+)*)\.[a-zA-Z0-9]{1,8})(?=$|[\s"'`])/g;
      let fileMatch = fileRegex.exec(content);
      while (fileMatch) {
        const filePath = fileMatch[1];
        if (filePath.length < 3) {
          fileMatch = fileRegex.exec(content);
          continue;
        }

        const key = `file:${filePath}`;
        if (!seen.has(key)) {
          seen.add(key);
          result.push({
            key,
            type: "file",
            value: filePath,
            channelId: chat.channelId
          });
        }
        fileMatch = fileRegex.exec(content);
      }
    }
  }

  return result.slice(0, 24);
}

export function normalizeProjectIdentifier(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-_.]+/g, "-")
    .replace(/^[-_.]+|[-_.]+$/g, "");
}

const CYRILLIC_MAP = {
  "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
  "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
  "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
  "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
  "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"
};

function transliterate(text) {
  let result = "";
  for (const char of text.toLowerCase()) {
    if (CYRILLIC_MAP[char] !== undefined) {
      result += CYRILLIC_MAP[char];
    } else {
      result += char;
    }
  }
  return result;
}

export function displayNameToProjectId(name) {
  const raw = String(name || "").trim();
  if (!raw) return "";
  const latin = transliterate(raw);
  return latin
    .replace(/\s+/g, "_")
    .replace(/[^a-z0-9_-]/g, "")
    .replace(/_{2,}/g, "_")
    .replace(/^[_-]+|[_-]+$/g, "");
}

export function parseListInput(value) {
  const unique = new Set();
  const parsed = [];
  const rawItems = Array.isArray(value)
    ? value
    : typeof value === "string"
      ? value.split(/[\n,]+/g)
      : [];

  for (const rawItem of rawItems) {
    const item = String(rawItem || "").trim();
    if (!item || unique.has(item.toLowerCase())) {
      continue;
    }
    unique.add(item.toLowerCase());
    parsed.push(item);
  }
  return parsed;
}

export function buildProjectChannels(projectId, actors = [], teams = []) {
  const base = normalizeProjectIdentifier(projectId) || "project";
  const channels = [{ title: "Main channel", channelId: `${base}-main` }];
  const used = new Set(channels.map((channel) => channel.channelId));

  for (const actor of actors) {
    const actorSlug = toSlug(actor);
    const channelId = `${base}-actor-${actorSlug || createId("actor")}`;
    if (!used.has(channelId)) {
      used.add(channelId);
      channels.push({
        title: `Actor · ${actor}`,
        channelId
      });
    }
  }

  for (const team of teams) {
    const teamSlug = toSlug(team);
    const channelId = `${base}-team-${teamSlug || createId("team")}`;
    if (!used.has(channelId)) {
      used.add(channelId);
      channels.push({
        title: `Team · ${team}`,
        channelId
      });
    }
  }

  return channels;
}

export function emptyProjectDraft(index = 1) {
  return {
    displayName: "",
    description: "",
    actors: "",
    teams: "",
    sourceType: "empty",
    repoUrl: "",
    repoPath: ""
  };
}

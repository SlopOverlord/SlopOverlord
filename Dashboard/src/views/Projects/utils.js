export const ACTIVE_WORKER_STATUSES = new Set(["queued", "running", "waitinginput", "waiting_input"]);

export const PROJECT_TABS = [
  { id: "overview", title: "Overview" },
  { id: "tasks", title: "Tasks" },
  { id: "workers", title: "Workers" },
  { id: "memories", title: "Memories" },
  { id: "visor", title: "Visor" },
  { id: "settings", title: "Settings" }
];

export const TASK_STATUSES = [
  { id: "backlog", title: "Backlog" },
  { id: "ready", title: "Ready to work" },
  { id: "in_progress", title: "In progress" },
  { id: "blocked", title: "Blocked" },
  { id: "done", title: "Done" }
];

export const TASK_PRIORITIES = ["low", "medium", "high"];
export const TASK_PRIORITY_LABELS = {
  low: "Low",
  medium: "Medium",
  high: "High"
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
    actorId: String(task?.actorId || "").trim(),
    teamId: String(task?.teamId || "").trim(),
    claimedActorId: String(task?.claimedActorId || "").trim(),
    claimedAgentId: String(task?.claimedAgentId || "").trim(),
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

  return {
    id,
    name,
    description: String(project?.description || "").trim(),
    createdAt: String(project?.createdAt || new Date().toISOString()),
    updatedAt: String(project?.updatedAt || project?.createdAt || new Date().toISOString()),
    chats,
    tasks,
    actors: Array.isArray(project?.actors) ? project.actors : [],
    teams: Array.isArray(project?.teams) ? project.teams : []
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

export function workersForProject(project, workers) {
  if (!project) {
    return [];
  }

  const projectChannels = new Set(project.chats.map((chat) => String(chat.channelId || "").trim()));
  return (Array.isArray(workers) ? workers : []).filter((worker) => {
    const channelId = String(worker?.channelId || "").trim();
    return channelId.length > 0 && projectChannels.has(channelId);
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
  return counts;
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
    projectId: `project-${index}`,
    displayName: `Project ${index}`,
    description: "",
    actors: "",
    teams: ""
  };
}

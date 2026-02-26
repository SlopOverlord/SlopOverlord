import React, { useEffect, useMemo, useState } from "react";
import { fetchChannelState } from "../api";

const STORAGE_KEY = "slopoverlord.dashboard.projects.v1";
const ACTIVE_WORKER_STATUSES = new Set(["queued", "running", "waitingInput"]);

function createId(prefix) {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
}

function defaultProjects() {
  return [
    {
      id: "project-main",
      name: "Main",
      chats: [
        {
          id: "chat-main-general",
          title: "General",
          channelId: "general"
        }
      ],
      tasks: [
        {
          id: "task-main-runtime",
          title: "Runtime stabilization",
          status: "in_progress"
        }
      ]
    }
  ];
}

function normalizeProject(project) {
  return {
    id: project?.id || createId("project"),
    name: project?.name || "New Project",
    chats: Array.isArray(project?.chats)
      ? project.chats.map((chat, index) => ({
          id: chat?.id || createId(`chat-${index + 1}`),
          title: chat?.title || `Chat ${index + 1}`,
          channelId: chat?.channelId || `channel-${index + 1}`
        }))
      : [],
    tasks: Array.isArray(project?.tasks)
      ? project.tasks.map((task, index) => ({
          id: task?.id || createId(`task-${index + 1}`),
          title: task?.title || `Task ${index + 1}`,
          status: task?.status || "todo"
        }))
      : []
  };
}

function hydrateProjects(raw) {
  if (!Array.isArray(raw)) {
    return defaultProjects();
  }

  const projects = raw.map(normalizeProject).filter((project) => project.name.trim().length > 0);
  if (projects.length === 0) {
    return defaultProjects();
  }

  return projects;
}

function projectTaskSummary(project) {
  if (!project.tasks.length) {
    return { done: false, label: "No tasks", tone: "muted" };
  }

  const allDone = project.tasks.every((task) => task.status === "done");
  if (allDone) {
    return { done: true, label: "All tasks done", tone: "ok" };
  }

  return { done: false, label: "Tasks in progress", tone: "warn" };
}

function activeWorkersForProject(project, workers) {
  const channels = new Set(project.chats.map((chat) => chat.channelId));
  return workers.filter((worker) => channels.has(worker.channelId) && ACTIVE_WORKER_STATUSES.has(worker.status));
}

function summarizeChat(chat, snapshot) {
  if (!snapshot) {
    return "No runtime snapshot";
  }

  const messageCount = Array.isArray(snapshot.messages) ? snapshot.messages.length : 0;
  return `${messageCount} messages in channel`;
}

export function ProjectsView({ channelState, workers }) {
  const [projects, setProjects] = useState(() => {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) {
        return defaultProjects();
      }
      return hydrateProjects(JSON.parse(raw));
    } catch {
      return defaultProjects();
    }
  });
  const [selectedProjectId, setSelectedProjectId] = useState(null);
  const [chatSnapshots, setChatSnapshots] = useState({});

  useEffect(() => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(projects));
  }, [projects]);

  const selectedProject = useMemo(
    () => projects.find((project) => project.id === selectedProjectId) || null,
    [projects, selectedProjectId]
  );

  useEffect(() => {
    if (!selectedProject) {
      return;
    }

    let isCancelled = false;

    async function loadSnapshots() {
      const entries = await Promise.all(
        selectedProject.chats.map(async (chat) => [chat.channelId, await fetchChannelState(chat.channelId)])
      );

      if (isCancelled) {
        return;
      }

      const next = {};
      for (const [channelId, snapshot] of entries) {
        if (snapshot) {
          next[channelId] = snapshot;
        }
      }
      setChatSnapshots(next);
    }

    loadSnapshots().catch(() => {
      if (!isCancelled) {
        setChatSnapshots({});
      }
    });

    return () => {
      isCancelled = true;
    };
  }, [selectedProject]);

  function createProject() {
    const baseName = `Project ${projects.length + 1}`;
    const slug = baseName.toLowerCase().replace(/\s+/g, "-");
    const nextProject = {
      id: createId("project"),
      name: baseName,
      chats: [
        {
          id: createId("chat"),
          title: "Main chat",
          channelId: `project-${slug}-main`
        }
      ],
      tasks: []
    };

    setProjects((previous) => [...previous, nextProject]);
    setSelectedProjectId(nextProject.id);
  }

  function renameProject(projectId) {
    const project = projects.find((candidate) => candidate.id === projectId);
    if (!project) {
      return;
    }

    const nextName = window.prompt("Project name", project.name);
    if (!nextName || !nextName.trim()) {
      return;
    }

    setProjects((previous) =>
      previous.map((candidate) =>
        candidate.id === projectId ? { ...candidate, name: nextName.trim() } : candidate
      )
    );
  }

  function deleteProject(projectId) {
    const project = projects.find((candidate) => candidate.id === projectId);
    if (!project) {
      return;
    }

    const accepted = window.confirm(`Delete project "${project.name}"?`);
    if (!accepted) {
      return;
    }

    setProjects((previous) => previous.filter((candidate) => candidate.id !== projectId));
    setSelectedProjectId((previous) => (previous === projectId ? null : previous));
  }

  function renderProjectList() {
    return (
      <section className="projects-list">
        {projects.map((project) => {
          const taskSummary = projectTaskSummary(project);
          const activeWorkers = activeWorkersForProject(project, workers);

          return (
            <article
              key={project.id}
              className="project-card"
              role="button"
              tabIndex={0}
              onClick={() => setSelectedProjectId(project.id)}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  setSelectedProjectId(project.id);
                }
              }}
            >
              <div className="project-card-head">
                <h3>{project.name}</h3>
                <details
                  className="project-menu"
                  onClick={(event) => {
                    event.stopPropagation();
                  }}
                >
                  <summary aria-label="Project actions">...</summary>
                  <div className="project-menu-list">
                    <button type="button" onClick={() => renameProject(project.id)}>
                      Rename
                    </button>
                    <button type="button" className="danger" onClick={() => deleteProject(project.id)}>
                      Delete
                    </button>
                  </div>
                </details>
              </div>

              <div className="project-stats">
                <p>
                  Workers in progress: <strong>{activeWorkers.length}</strong>
                </p>
                <p>
                  Tasks status: <span className={`project-task-pill ${taskSummary.tone}`}>{taskSummary.label}</span>
                </p>
              </div>
            </article>
          );
        })}
      </section>
    );
  }

  function renderProjectDetails(project) {
    const activeWorkers = activeWorkersForProject(project, workers);

    return (
      <section className="project-details">
        <div className="project-details-head">
          <button type="button" className="project-back" onClick={() => setSelectedProjectId(null)}>
            Back to projects
          </button>
          <h3>{project.name}</h3>
        </div>

        <div className="project-details-grid">
          <article className="entry-editor-card">
            <h4>Chats</h4>
            <div className="project-listing">
              {project.chats.map((chat) => (
                <section key={chat.id} className="project-listing-item">
                  <strong>{chat.title}</strong>
                  <p>Channel: {chat.channelId}</p>
                  <p>
                    {summarizeChat(
                      chat,
                      chatSnapshots[chat.channelId] || (channelState?.channelId === chat.channelId ? channelState : null)
                    )}
                  </p>
                </section>
              ))}
            </div>
          </article>

          <article className="entry-editor-card">
            <h4>Active agents</h4>
            {activeWorkers.length === 0 ? (
              <p className="placeholder-text">No active workers right now.</p>
            ) : (
              <div className="project-listing">
                {activeWorkers.map((worker) => (
                  <section key={worker.workerId} className="project-listing-item">
                    <strong>{worker.workerId}</strong>
                    <p>Status: {worker.status}</p>
                    <p>Mode: {worker.mode}</p>
                    <p>Task: {worker.taskId}</p>
                  </section>
                ))}
              </div>
            )}
          </article>
        </div>
      </section>
    );
  }

  return (
    <main className="projects-shell">
      <header className="projects-head">
        <h2>Projects</h2>
        <button type="button" onClick={createProject}>
          New Project
        </button>
      </header>

      {selectedProject ? renderProjectDetails(selectedProject) : renderProjectList()}
    </main>
  );
}

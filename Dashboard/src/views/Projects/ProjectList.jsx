import React, { useEffect, useMemo, useState } from "react";
import { fetchAgents, fetchActorsBoard } from "../../api";
import { ProjectIcon } from "../../components/ProjectIcon";
import { AgentPetIcon } from "../../features/agents/components/AgentPetSprite";
import { workersForProject, activeWorkersForProject, buildTaskCounts, formatRelativeTime } from "./utils";

const MAX_VISIBLE_AGENTS = 4;

function useBoard() {
  const [actorPetByName, setActorPetByName] = useState({});
  const [teamMembersByName, setTeamMembersByName] = useState({});

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const [agentsRes, boardRes] = await Promise.all([
        fetchAgents().catch(() => null),
        fetchActorsBoard().catch(() => null)
      ]);
      if (cancelled) return;

      const agents = Array.isArray(agentsRes) ? agentsRes : [];
      const nodes = Array.isArray(boardRes?.nodes) ? boardRes.nodes : [];
      const teams = Array.isArray(boardRes?.teams) ? boardRes.teams : [];

      const agentById = new Map(agents.map((a) => [String(a.id || ""), a]));
      const nodeById = new Map(nodes.map((n) => [String(n?.id || ""), n]));

      const petMap = {};
      for (const node of nodes) {
        const name = String(node?.displayName || "").trim();
        const agentId = String(node?.linkedAgentId || "").trim();
        if (name && agentId) {
          const agent = agentById.get(agentId);
          if (agent?.pet?.parts) {
            petMap[name] = agent.pet;
          }
        }
      }

      const teamMap = {};
      for (const team of teams) {
        const teamName = String(team?.name || "").trim();
        if (!teamName) continue;
        const memberIds = Array.isArray(team.memberActorIds) ? team.memberActorIds : [];
        teamMap[teamName] = memberIds
          .map((id) => nodeById.get(String(id)))
          .filter(Boolean)
          .map((n) => String(n?.displayName || "").trim())
          .filter(Boolean);
      }

      setActorPetByName(petMap);
      setTeamMembersByName(teamMap);
    }
    load();
    return () => { cancelled = true; };
  }, []);

  return { actorPetByName, teamMembersByName };
}

function AgentStack({ actorNames, teams = [], actorPetByName, teamMembersByName = {} }) {
  const resolved = useMemo(() => {
    const teamActors = teams.flatMap((teamName) => teamMembersByName[teamName] ?? []);
    const allNames = Array.from(new Set([...actorNames, ...teamActors]));
    return allNames.map((name) => ({
      name,
      pet: actorPetByName[name] ?? null
    }));
  }, [actorNames, teams, actorPetByName, teamMembersByName]);

  if (resolved.length === 0) {
    return null;
  }

  const visible = resolved.slice(0, MAX_VISIBLE_AGENTS);
  const overflow = resolved.length - visible.length;

  return (
    <div className="project-agent-stack" aria-hidden="true">
      {visible.map(({ name, pet }) => (
        <div key={name} className="project-agent-icon">
          {pet?.parts ? (
            <AgentPetIcon pet={pet} parts={pet.parts} genomeHex={pet.genomeHex} />
          ) : (
            name.slice(0, 2).toUpperCase()
          )}
        </div>
      ))}
      {overflow > 0 && (
        <div className="project-agent-more">+{overflow}</div>
      )}
    </div>
  );
}

export function ProjectList({
  projects,
  isLoadingProjects,
  openProject,
  openCreateProjectModal,
  workers,
  showArchived = false,
  archivedCount = 0,
  onToggleArchived,
  onUnarchiveProject,
  onToggleFavorite = () => {}
}) {
  const { actorPetByName, teamMembersByName } = useBoard();

  if (isLoadingProjects) {
    return (
      <section className="project-grid-list">
        <article className="project-grid-card">
          <p className="app-status-text">Loading projects from Sloppy...</p>
        </article>
      </section>
    );
  }

  if (projects.length === 0) {
    return (
      <section className="project-board-list project-board-list--empty" data-tour-id="projects-overview">
        <article className="project-board-empty">
          <div className="project-board-empty-actions">
            {showArchived ? (
              <>
                <p className="project-new-action-subtitle">No archived projects.</p>
                <button type="button" className="project-new-action hover-levitate" onClick={onToggleArchived}>
                  Back to Projects
                </button>
              </>
            ) : (
              <>
                <p className="project-new-action-subtitle">Start your first project!</p>
                <button type="button" className="project-new-action hover-levitate" onClick={openCreateProjectModal}>
                  New Project
                </button>
              </>
            )}
          </div>
        </article>
      </section>
    );
  }

  const favoriteProjects = showArchived ? [] : projects.filter((project) => project.isFavorite);
  const regularProjects = showArchived ? projects : projects.filter((project) => !project.isFavorite);
  const sections = showArchived || favoriteProjects.length === 0
    ? [{ id: "projects", title: null, projects }]
    : [
      { id: "favorites", title: "Favorites", projects: favoriteProjects },
      { id: "projects", title: "Projects", projects: regularProjects }
    ].filter((section) => section.projects.length > 0);

  function renderProjectCard(project) {
    const activeWorkers = activeWorkersForProject(project, workers);
    const taskCounts = project.taskCounts || buildTaskCounts(project.tasks);
    const actors = Array.isArray(project.actors) ? project.actors : [];
    const teams = Array.isArray(project.teams) ? project.teams : [];
    const isFavorite = Boolean(project.isFavorite);

    return (
      <article
        key={project.id}
        className={`project-grid-card hover-levitate ${isFavorite ? "project-grid-card--favorite" : ""}`}
        data-testid={`project-list-item-${project.id}`}
        role="button"
        tabIndex={0}
        onClick={() => openProject(project.id)}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            openProject(project.id);
          }
        }}
      >
        {showArchived ? (
          <button
            type="button"
            className="project-unarchive-btn"
            title="Unarchive project"
            style={{ position: "absolute", top: 6, right: 6 }}
            onClick={(e) => {
              e.stopPropagation();
              onUnarchiveProject(project.id);
            }}
          >
            <span className="material-symbols-rounded" style={{ fontSize: "1rem" }}>unarchive</span>
          </button>
        ) : (
          <button
            type="button"
            className={`project-favorite-btn ${isFavorite ? "active" : ""}`}
            title={isFavorite ? "Remove from favorites" : "Add to favorites"}
            aria-label={isFavorite ? "Remove from favorites" : "Add to favorites"}
            aria-pressed={isFavorite}
            onClick={(e) => {
              e.stopPropagation();
              onToggleFavorite(project.id, !isFavorite);
            }}
          >
            <span className="material-symbols-rounded" aria-hidden="true">
              {isFavorite ? "star" : "star"}
            </span>
          </button>
        )}

        <div className="project-grid-body">
          {project.icon ? (
            <ProjectIcon
              icon={project.icon}
              className="project-grid-icon"
              imageClassName="project-grid-icon-image"
            />
          ) : null}
          <p className="project-grid-name">{project.name}</p>
          {project.description ? (
            <p className="project-grid-desc">{project.description}</p>
          ) : null}
        </div>

        <div className="project-grid-footer">
          <div className="project-grid-badges">
            <span className="project-grid-badge">{taskCounts.total} tasks</span>
            <span className="project-grid-badge project-grid-badge--progress">{taskCounts.not_done} not done</span>
            {taskCounts.in_progress > 0 && (
              <span className="project-grid-badge project-grid-badge--progress">{taskCounts.in_progress} in progress</span>
            )}
            {taskCounts.done > 0 && (
              <span className="project-grid-badge project-grid-badge--active">{taskCounts.done} done</span>
            )}
            {activeWorkers.length > 0 && (
              <span className="project-grid-badge project-grid-badge--active">{activeWorkers.length} running</span>
            )}
          </div>
          <AgentStack actorNames={actors} teams={teams} actorPetByName={actorPetByName} teamMembersByName={teamMembersByName} />
        </div>
      </article>
    );
  }

  return (
    <section className="project-grid-list" data-testid="project-list" data-tour-id="projects-overview">
      {showArchived && (
        <div className="project-archive-banner" style={{ gridColumn: "1 / -1" }}>
          <span className="material-symbols-rounded" style={{ fontSize: "1rem" }}>archive</span>
          <span>Archived projects</span>
          <button type="button" className="project-archive-back-btn" onClick={onToggleArchived}>
            <span className="material-symbols-rounded" style={{ fontSize: "1rem" }}>arrow_back</span>
            Back
          </button>
        </div>
      )}

      {sections.map((section) => (
        <React.Fragment key={section.id}>
          {section.title ? (
            <div className="project-grid-section-title">
              <span className="material-symbols-rounded" aria-hidden="true">
                {section.id === "favorites" ? "star" : "folder"}
              </span>
              <span>{section.title}</span>
            </div>
          ) : null}
          {section.projects.map((project) => renderProjectCard(project))}
        </React.Fragment>
      ))}

      {!showArchived && archivedCount > 0 && (
        <button type="button" className="project-archive-toggle-btn" style={{ gridColumn: "1 / -1" }} onClick={onToggleArchived}>
          <span className="material-symbols-rounded" style={{ fontSize: "1rem" }}>archive</span>
          {archivedCount} archived {archivedCount === 1 ? "project" : "projects"}
        </button>
      )}
    </section>
  );
}

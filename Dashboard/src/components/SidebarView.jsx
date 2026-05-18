import React from "react";
import { ProjectIcon } from "./ProjectIcon";

function sidebarProjectInitials(name, id) {
  const raw = String(name || id || "?").trim();
  const parts = raw.split(/[\s_-]+/).filter(Boolean);
  if (parts.length === 0) return "??";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

export function SidebarView({
  items,
  activeItemId,
  isCompact,
  onToggleCompact,
  onSelect,
  isMobileOpen = false,
  onRequestClose = () => { },
  footer = null,
  projectRailProjects = [],
  selectedChatProjectId = null,
  onSelectChatProject = (_projectId) => { }
}) {
  return (
    <aside className={`sidebar ${isCompact ? "compact" : "full"} ${isMobileOpen ? "mobile-open" : ""}`}>
      <div className="sidebar-head">
        {isCompact ? (
          <button className="sidebar-logo-launch" type="button" onClick={onToggleCompact} aria-label="Expand menu">
            <img src="/so_logo.svg" alt="" className="sidebar-logo" aria-hidden="true" />
          </button>
        ) : (
          <>
            <div className="sidebar-brand-wrap">
              <img src="/so_logo.svg" alt="" className="sidebar-logo" aria-hidden="true" />
              <div style={{ display: 'flex', flexDirection: 'column' }}>
                <strong className="sidebar-brand" style={{ textTransform: 'uppercase' }}>&gt; Sloppy</strong>
                <span style={{ fontSize: '10px', color: 'var(--muted)', letterSpacing: '0.05em' }}>SYS.VER // {__APP_VERSION__ || '0.1.0'}</span>
              </div>
            </div>
            <button className="sidebar-toggle" type="button" onClick={onToggleCompact} aria-label="Collapse menu">
              <span className="material-symbols-rounded" aria-hidden="true">
                chevron_left
              </span>
            </button>
          </>
        )}
        <button className="sidebar-mobile-close" type="button" onClick={onRequestClose} aria-label="Close menu">
          <span className="material-symbols-rounded" aria-hidden="true">
            close
          </span>
        </button>
      </div>

      <nav className="sidebar-nav">
        {items.map((item) => (
          <button
            key={item.id}
            type="button"
            className={`sidebar-item ${activeItemId === item.id ? "active" : ""}`}
            data-testid={`sidebar-nav-${item.id}`}
            onClick={() => {
              onSelect(item.id);
              onRequestClose();
            }}
            title={item.label.title}
          >
            <span className="material-symbols-rounded sidebar-icon" aria-hidden="true">
              {item.label.icon}
            </span>
            {!isCompact && <span className="sidebar-label" style={{ textTransform: 'uppercase' }}>[ {item.label.title} ]</span>}
          </button>
        ))}
        {Array.isArray(projectRailProjects) && projectRailProjects.length > 0 ? (
          <div className="sidebar-project-rail" aria-label="Project chats">
            {!isCompact ? <div className="sidebar-project-rail-label">Project chats</div> : null}
            <div className="sidebar-project-rail-icons">
              {projectRailProjects.map((p) => {
                const pid = String(p?.id || "").trim();
                if (!pid) {
                  return null;
                }
                const projectLabel = String(p?.name || pid).trim() || pid;
                return (
                  <button
                    key={pid}
                    type="button"
                    className={`sidebar-project-rail-item ${selectedChatProjectId === pid ? "active" : ""}`}
                    title={projectLabel}
                    data-testid={`sidebar-project-rail-${pid}`}
                    onClick={() => {
                      onSelectChatProject(pid);
                      onRequestClose();
                    }}
                  >
                    <ProjectIcon
                      icon={p?.icon}
                      fallback={sidebarProjectInitials(p?.name, pid)}
                      className="sidebar-project-rail-avatar"
                      imageClassName="sidebar-project-rail-avatar-image"
                    />
                    {!isCompact ? (
                      <span className="sidebar-project-rail-name">{projectLabel}</span>
                    ) : null}
                  </button>
                );
              })}
            </div>
          </div>
        ) : null}
      </nav>
      {footer && <div className="sidebar-footer">{footer}</div>}
    </aside>
  );
}

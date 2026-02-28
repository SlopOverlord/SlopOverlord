import React from "react";

export function SidebarView({
  items,
  activeItemId,
  isCompact,
  onToggleCompact,
  onSelect,
  isMobileOpen = false,
  onRequestClose = () => {}
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
              <strong className="sidebar-brand">SlopOverlord</strong>
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
            onClick={() => {
              onSelect(item.id);
              onRequestClose();
            }}
            title={item.label.title}
          >
            <span className="material-symbols-rounded sidebar-icon" aria-hidden="true">
              {item.label.icon}
            </span>
            {!isCompact && <span className="sidebar-label">{item.label.title}</span>}
          </button>
        ))}
      </nav>
    </aside>
  );
}

import React from "react";

export function SidebarView({ items, activeItemId, isCompact, onToggleCompact, onSelect }) {
  return (
    <aside className={`sidebar ${isCompact ? "compact" : "full"}`}>
      <div className="sidebar-head">
        {!isCompact && <strong className="sidebar-brand">SlopOverlord</strong>}
        <button
          className="sidebar-toggle"
          type="button"
          onClick={onToggleCompact}
          aria-label={isCompact ? "Expand sidebar" : "Collapse sidebar"}
        >
          {isCompact ? ">>" : "<<"}
        </button>
      </div>

      <nav className="sidebar-nav">
        {items.map((item) => (
          <button
            key={item.id}
            type="button"
            className={`sidebar-item ${activeItemId === item.id ? "active" : ""}`}
            onClick={() => onSelect(item.id)}
            title={item.label.title}
          >
            <span className="sidebar-icon">{item.label.icon}</span>
            {!isCompact && <span className="sidebar-label">{item.label.title}</span>}
          </button>
        ))}
      </nav>
    </aside>
  );
}

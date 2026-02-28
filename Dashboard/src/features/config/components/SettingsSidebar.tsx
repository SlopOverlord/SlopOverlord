import React from "react";

export function SettingsSidebar({
  rawValid,
  query,
  onQueryChange,
  filteredSettings,
  selectedSettings,
  onSelectSettings,
  mode,
  onModeChange
}) {
  return (
    <aside className="settings-side">
      <div className="settings-title-row">
        <h2>Settings</h2>
        <span className={`settings-valid ${rawValid ? "ok" : "bad"}`}>{rawValid ? "valid" : "invalid"}</span>
      </div>

      <input
        className="settings-search"
        value={query}
        onChange={(event) => onQueryChange(event.target.value)}
        placeholder="Search settings..."
      />

      <div className="settings-nav">
        {filteredSettings.map((item) => (
          <button
            key={item.id}
            type="button"
            className={`settings-nav-item ${selectedSettings === item.id ? "active" : ""}`}
            onClick={() => onSelectSettings(item.id)}
          >
            <span>{item.icon}</span>
            <span>{item.title}</span>
          </button>
        ))}
      </div>

      <div className="settings-mode-switch">
        <button type="button" className={mode === "form" ? "active" : ""} onClick={() => onModeChange("form")}>
          Form
        </button>
        <button type="button" className={mode === "raw" ? "active" : ""} onClick={() => onModeChange("raw")}>
          Raw
        </button>
      </div>
    </aside>
  );
}

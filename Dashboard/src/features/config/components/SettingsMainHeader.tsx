import React from "react";

export function SettingsMainHeader({ hasChanges, statusText, onReload, onSave }) {
  return (
    <header className="settings-main-head">
      <div className="settings-main-status">
        <strong>{hasChanges ? "Unsaved changes" : "No changes"}</strong>
        <span>{statusText}</span>
      </div>

      <div className="settings-main-actions">
        <button type="button" className="hover-levitate" onClick={onSave}>
          Apply
        </button>
        <button type="button" className="hover-levitate" onClick={onReload}>
          Cancel
        </button>
      </div>
    </header>
  );
}

import React from "react";

export function SettingsMainHeader({ hasChanges, statusText, onReload, onSave }) {
  return (
    <header className="settings-main-head">
      <div className="settings-main-status">
        <strong>{hasChanges ? "Unsaved changes" : "No changes"}</strong>
        <span>{statusText}</span>
      </div>

      <div className="settings-main-actions">
        <button type="button" onClick={onReload}>
          Reload
        </button>
        <button type="button" onClick={onSave}>
          Save
        </button>
        <button type="button" onClick={onSave}>
          Apply
        </button>
        <button type="button" onClick={onReload}>
          Update
        </button>
      </div>
    </header>
  );
}

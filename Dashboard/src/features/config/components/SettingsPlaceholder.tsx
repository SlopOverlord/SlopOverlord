import React from "react";

export function SettingsPlaceholder({ title }) {
  return (
    <section className="entry-editor-card">
      <h3>{title || "Settings section"}</h3>
      <p className="placeholder-text">
        This section is wired in the config navigation and can be implemented incrementally with dedicated view logic.
      </p>
    </section>
  );
}

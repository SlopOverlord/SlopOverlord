import React from "react";

export function PlaceholderView({ title }) {
  return (
    <main className="grid">
      <section className="panel">
        <h2>{title}</h2>
        <p className="placeholder-text">
          This workspace section is reserved for the next milestone. The sidebar route is wired and ready for feature
          modules.
        </p>
      </section>
    </main>
  );
}

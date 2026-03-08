import React from "react";

export function BrowserEditor({ draftConfig, mutateDraft, emptyBrowserProfile }) {
  const browser = draftConfig.browser || {
    browserPath: "/usr/bin/chromium",
    headless: true,
    allowJavaScriptEvaluation: false,
    profiles: []
  };
  const profiles = Array.isArray(browser.profiles) ? browser.profiles : [];

  function updateProfile(index, field, value) {
    mutateDraft((draft) => {
      if (!draft.browser) {
        draft.browser = {
          browserPath: "/usr/bin/chromium",
          headless: true,
          allowJavaScriptEvaluation: false,
          profiles: []
        };
      }
      if (!draft.browser.profiles[index]) {
        draft.browser.profiles[index] = emptyBrowserProfile();
      }
      draft.browser.profiles[index][field] = value;
    });
  }

  function moveProfile(index, direction) {
    mutateDraft((draft) => {
      if (!draft.browser || !Array.isArray(draft.browser.profiles)) {
        return;
      }
      const nextIndex = index + direction;
      if (nextIndex < 0 || nextIndex >= draft.browser.profiles.length) {
        return;
      }
      const [profile] = draft.browser.profiles.splice(index, 1);
      draft.browser.profiles.splice(nextIndex, 0, profile);
    });
  }

  return (
    <div className="entry-editor-layout">
      <div className="entry-list">
        <div className="entry-list-head">
          <h4>Browser Profiles</h4>
          <button
            type="button"
            onClick={() =>
              mutateDraft((draft) => {
                if (!draft.browser) {
                  draft.browser = {
                    browserPath: "/usr/bin/chromium",
                    headless: true,
                    allowJavaScriptEvaluation: false,
                    profiles: []
                  };
                }
                draft.browser.profiles.push(emptyBrowserProfile());
              })
            }
          >
            + Add Profile
          </button>
        </div>

        <div className="entry-list-scroll">
          {profiles.length === 0 ? (
            <p className="placeholder-text">No named profiles. Browser sessions will use an ephemeral workspace profile.</p>
          ) : (
            profiles.map((profile, index) => (
              <div key={`${profile.id || "profile"}-${index}`} className="entry-list-item">
                <strong>{profile.title || profile.id || `profile-${index + 1}`}</strong>
                <small>{profile.userDataDir || "No user data dir configured"}</small>
              </div>
            ))
          )}
        </div>
      </div>

      <section className="entry-editor-card">
        <div className="entry-editor-head">
          <h3>Chromium Browser</h3>
        </div>

        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Browser Path
            <input
              value={browser.browserPath}
              placeholder="/usr/bin/chromium"
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.browser.browserPath = event.target.value;
                })
              }
            />
            <span className="entry-form-hint">Default Linux path is `/usr/bin/chromium`. Override this when the runtime image uses a different executable.</span>
          </label>

          <label>
            Headless Mode
            <select
              value={browser.headless ? "headless" : "headed"}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.browser.headless = event.target.value === "headless";
                })
              }
            >
              <option value="headless">Headless</option>
              <option value="headed">Headed</option>
            </select>
          </label>

          <label>
            JavaScript Evaluation
            <select
              value={browser.allowJavaScriptEvaluation ? "enabled" : "disabled"}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.browser.allowJavaScriptEvaluation = event.target.value === "enabled";
                })
              }
            >
              <option value="disabled">Disabled</option>
              <option value="enabled">Enabled</option>
            </select>
          </label>
        </div>

        <div className="entry-stack">
          {profiles.map((profile, index) => (
            <section key={`${profile.id || "profile"}-editor-${index}`} className="entry-editor-card">
              <div className="entry-editor-head">
                <h3>{profile.title || profile.id || `Profile ${index + 1}`}</h3>
                <div className="entry-inline-actions">
                  <button type="button" onClick={() => moveProfile(index, -1)} disabled={index === 0}>
                    Up
                  </button>
                  <button type="button" onClick={() => moveProfile(index, 1)} disabled={index === profiles.length - 1}>
                    Down
                  </button>
                  <button
                    type="button"
                    className="danger"
                    onClick={() =>
                      mutateDraft((draft) => {
                        draft.browser.profiles.splice(index, 1);
                      })
                    }
                  >
                    Delete
                  </button>
                </div>
              </div>

              <div className="entry-form-grid">
                <label>
                  Profile ID
                  <input value={profile.id} placeholder="work" onChange={(event) => updateProfile(index, "id", event.target.value)} />
                </label>

                <label>
                  Title
                  <input value={profile.title} placeholder="Work Profile" onChange={(event) => updateProfile(index, "title", event.target.value)} />
                </label>

                <label style={{ gridColumn: "1 / -1" }}>
                  User Data Dir
                  <input
                    value={profile.userDataDir}
                    placeholder="~/.config/chromium"
                    onChange={(event) => updateProfile(index, "userDataDir", event.target.value)}
                  />
                </label>

                <label style={{ gridColumn: "1 / -1" }}>
                  Profile Directory
                  <input
                    value={profile.profileDirectory}
                    placeholder="Default"
                    onChange={(event) => updateProfile(index, "profileDirectory", event.target.value || "Default")}
                  />
                </label>
              </div>
            </section>
          ))}
        </div>
      </section>
    </div>
  );
}

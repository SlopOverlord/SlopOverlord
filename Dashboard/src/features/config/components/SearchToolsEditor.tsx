import React from "react";

function providerStatusBadge(status) {
  if (!status) {
    return { tone: "off", text: "not set" };
  }
  if (status.hasEnvironmentKey) {
    return { tone: "on", text: "env" };
  }
  if (status.hasConfiguredKey) {
    return { tone: "on", text: "configured" };
  }
  return { tone: "off", text: "not set" };
}

export function SearchToolsEditor({ draftConfig, searchProviderStatus, mutateDraft }) {
  const activeProvider = String(draftConfig.searchTools?.activeProvider || "perplexity");
  const providers = [
    {
      id: "brave",
      title: "Brave",
      description: "Official Brave Search API for direct web result retrieval."
    },
    {
      id: "perplexity",
      title: "Perplexity",
      description: "Official Perplexity Search API for current web search."
    }
  ];

  return (
    <div className="providers-shell">
      <section className="entry-editor-card providers-intro-card">
        <h3>Search Tools</h3>
        <p className="placeholder-text">
          Configure the provider used by tool <code>web.search</code>. Environment variables override saved config keys at runtime.
        </p>
        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Active Provider
            <select
              value={activeProvider}
              onChange={(event) =>
                mutateDraft((draft) => {
                  draft.searchTools.activeProvider = event.target.value;
                })
              }
            >
              <option value="perplexity">Perplexity</option>
              <option value="brave">Brave</option>
            </select>
          </label>
        </div>
      </section>

      <section className="providers-list">
        {providers.map((provider) => {
          const status = provider.id === "brave" ? searchProviderStatus?.brave : searchProviderStatus?.perplexity;
          const badge = providerStatusBadge(status);
          const apiKey = String(
            provider.id === "brave"
              ? draftConfig.searchTools?.providers?.brave?.apiKey || ""
              : draftConfig.searchTools?.providers?.perplexity?.apiKey || ""
          );

          return (
            <section
              key={provider.id}
              className={`provider-card provider-list-item ${activeProvider === provider.id ? "configured" : ""}`}
            >
              <div className="provider-list-main" style={{ width: "100%" }}>
                <div className="provider-card-head">
                  <h4>{provider.title}</h4>
                  <span className={`provider-state ${badge.tone}`}>{badge.text}</span>
                </div>
                <p>{provider.description}</p>

                <div className="entry-form-grid" style={{ marginTop: 16 }}>
                  <label style={{ gridColumn: "1 / -1" }}>
                    API Key
                    <input
                      type="password"
                      autoComplete="new-password"
                      value={apiKey}
                      placeholder={provider.id === "brave" ? "BSA..." : "pplx_..."}
                      onChange={(event) =>
                        mutateDraft((draft) => {
                          if (provider.id === "brave") {
                            draft.searchTools.providers.brave.apiKey = event.target.value;
                          } else {
                            draft.searchTools.providers.perplexity.apiKey = event.target.value;
                          }
                        })
                      }
                    />
                    {status?.hasEnvironmentKey ? (
                      <span className="entry-form-hint">
                        Using {provider.id === "brave" ? "BRAVE_API_KEY" : "PERPLEXITY_API_KEY"} from Core environment.
                      </span>
                    ) : (
                      <span className="entry-form-hint">Stored in runtime config as fallback when env is missing.</span>
                    )}
                  </label>
                </div>
              </div>
            </section>
          );
        })}
      </section>
    </div>
  );
}

import React from "react";
import { createPortal } from "react-dom";

export function ProviderEditor({
  providerCatalog,
  draftConfig,
  customModelsCount,
  openAIProviderStatus,
  providerModalMeta,
  providerForm,
  providerModelStatus,
  providerModelOptions,
  providerModelMenuOpen,
  providerModelMenuRect,
  providerModelPickerRef,
  providerModelMenuRef,
  onOpenProviderModal,
  onCloseProviderModal,
  onUpdateProviderForm,
  onOpenOAuth,
  onRemoveProvider,
  onSaveProvider,
  onSetProviderModelMenuOpen,
  onSetProviderModelMenuRect,
  getProviderEntry,
  providerIsConfigured,
  filterProviderModels
}) {
  const activeProviderStatus = providerModalMeta ? providerModelStatus[providerModalMeta.id] : "";
  const activeProviderModels = providerModalMeta ? providerModelOptions[providerModalMeta.id] || [] : [];
  const activeProviderEntry = providerModalMeta ? getProviderEntry(draftConfig.models, providerModalMeta.id) : null;
  const filteredProviderModels = filterProviderModels(activeProviderModels, providerForm?.model);

  return (
    <div className="providers-shell">
      <section className="entry-editor-card">
        <h3>Providers</h3>
        <p className="placeholder-text">Choose a provider to configure API key and model in a modal dialog.</p>
        {customModelsCount > 0 ? (
          <p className="placeholder-text">
            Config has {customModelsCount} custom model entries. They are preserved and available in raw mode.
          </p>
        ) : null}
      </section>

      <section className="providers-grid">
        {providerCatalog.map((provider) => {
          const providerEntry = getProviderEntry(draftConfig.models, provider.id)?.entry;
          const entryModel = String(providerEntry?.model || provider.defaultEntry.model || "").trim();
          const entryURL = String(providerEntry?.apiUrl || provider.defaultEntry.apiUrl || "").trim();
          const configuredViaEnvironment =
            provider.id === "openai-api" &&
            openAIProviderStatus.hasEnvironmentKey &&
            !Boolean(String(providerEntry?.apiKey || "").trim()) &&
            Boolean(entryModel && entryURL);
          const configured = configuredViaEnvironment || providerIsConfigured(provider, providerEntry);
          const actionText = configured ? "Configure" : provider.requiresApiKey ? "Add Key" : "Setup";
          const configuredBadgeText = configuredViaEnvironment ? "env" : configured ? "configured" : "not set";

          return (
            <button
              key={provider.id}
              type="button"
              className={`provider-card ${configured ? "configured" : ""}`}
              onClick={() => onOpenProviderModal(provider.id)}
            >
              <div className="provider-card-head">
                <h4>{provider.title}</h4>
                <span className={`provider-state ${configured ? "on" : "off"}`}>{configuredBadgeText}</span>
              </div>
              <p>{provider.description}</p>
              <span className="provider-model-line">
                Model: {providerEntry?.model || provider.modelHint}
              </span>
              <span className="provider-card-action">{actionText}</span>
            </button>
          );
        })}
      </section>

      {providerModalMeta && providerForm ? (
        <div className="provider-modal-overlay" onClick={onCloseProviderModal}>
          <section className="provider-modal-card" onClick={(event) => event.stopPropagation()}>
            <div className="provider-modal-head">
              <h3>{providerModalMeta.title}</h3>
              <button type="button" className="provider-close-button" onClick={onCloseProviderModal}>
                x
              </button>
            </div>
            <p className="placeholder-text">{providerModalMeta.description}</p>

            <div className="provider-modal-form">
              {providerModalMeta.requiresApiKey ? (
                <label>
                  API Key
                  <input
                    type="password"
                    value={providerForm.apiKey}
                    onChange={(event) => onUpdateProviderForm("apiKey", event.target.value)}
                    placeholder="sk-..."
                  />
                  {providerModalMeta.id === "openai-api" && openAIProviderStatus.hasEnvironmentKey ? (
                    <span className="placeholder-text">Using OPENAI_API_KEY from Core environment.</span>
                  ) : null}
                </label>
              ) : null}

              <label>
                API URL
                <input value={providerForm.apiUrl} onChange={(event) => onUpdateProviderForm("apiUrl", event.target.value)} />
              </label>

              <label>
                Model
                <div ref={providerModelPickerRef} className="provider-model-picker">
                  <input
                    value={providerForm.model}
                    onFocus={() => onSetProviderModelMenuOpen(true)}
                    onClick={() => onSetProviderModelMenuOpen(true)}
                    onChange={(event) => onUpdateProviderForm("model", event.target.value)}
                    placeholder="Select model id..."
                  />
                </div>
              </label>
            </div>

            {providerModalMeta.supportsModelCatalog ? (
              <div className="provider-modal-catalog">
                <p className="placeholder-text">{activeProviderStatus || "Model catalog is loading automatically."}</p>
                {providerModalMeta.id === "openai-oauth" ? (
                  <div className="provider-modal-actions">
                    <button type="button" onClick={onOpenOAuth}>
                      Open OAuth in Codex
                    </button>
                  </div>
                ) : null}
              </div>
            ) : null}
            <div className="provider-modal-footer">
              {activeProviderEntry ? (
                <button type="button" className="danger" onClick={onRemoveProvider}>
                  Remove Provider
                </button>
              ) : (
                <span />
              )}
              <div className="provider-modal-footer-actions">
                <button type="button" onClick={onCloseProviderModal}>
                  Cancel
                </button>
                <button type="button" onClick={onSaveProvider}>
                  Save Provider
                </button>
              </div>
            </div>
          </section>
        </div>
      ) : null}
      {providerModalMeta && providerForm && providerModelMenuOpen && filteredProviderModels.length > 0 && providerModelMenuRect
        ? createPortal(
            <div
              ref={providerModelMenuRef}
              className="provider-model-picker-menu provider-model-picker-menu-floating"
              style={{
                top: `${providerModelMenuRect.top}px`,
                left: `${providerModelMenuRect.left}px`,
                width: `${providerModelMenuRect.width}px`
              }}
            >
              <div className="provider-model-picker-group">{providerModalMeta.title}</div>
              <div className="provider-model-options" style={{ maxHeight: `${providerModelMenuRect.maxHeight}px` }}>
                {filteredProviderModels.map((model) => (
                  <button
                    key={model.id}
                    type="button"
                    className={`provider-model-option ${providerForm.model === model.id ? "active" : ""}`}
                    onMouseDown={(event) => event.preventDefault()}
                    onClick={() => {
                      onUpdateProviderForm("model", model.id);
                      onSetProviderModelMenuOpen(false);
                      onSetProviderModelMenuRect(null);
                    }}
                  >
                    <div className="provider-model-option-main">
                      <strong>{model.title || model.id}</strong>
                      {model.contextWindow ? <span className="provider-model-context">{model.contextWindow}</span> : null}
                    </div>
                    <span>{model.id}</span>
                    {Array.isArray(model.capabilities) && model.capabilities.length > 0 ? (
                      <div className="provider-model-capabilities">
                        {model.capabilities.map((capability) => (
                          <span key={`${model.id}-${capability}`}>{capability}</span>
                        ))}
                      </div>
                    ) : null}
                  </button>
                ))}
              </div>
            </div>,
            document.body
          )
        : null}
    </div>
  );
}

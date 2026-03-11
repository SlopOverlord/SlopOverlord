import React, { useEffect, useMemo, useRef, useState } from "react";
import type { CoreApi } from "../../shared/api/coreApi";
import {
  OPENAI_OAUTH_MESSAGE_TYPE,
  OPENAI_OAUTH_REDIRECT_URI,
  buildOpenAIOAuthRedirectURI,
  clearOpenAIOAuthCallbackParams,
  openOpenAIOAuthPopup,
  postOpenAIOAuthMessage,
  readOpenAIOAuthCallbackError,
  readOpenAIOAuthCallbackURL
} from "../../shared/openaiOAuth";

type AnyRecord = Record<string, unknown>;

interface OnboardingViewProps {
  coreApi: CoreApi;
  initialConfig: AnyRecord;
  onCompleted: (config: AnyRecord) => void;
}

interface ProviderDefinition {
  id: string;
  title: string;
  description: string;
  requiresApiKey: boolean;
  authHint: string;
  defaultEntry: {
    title: string;
    apiKey: string;
    apiUrl: string;
    model: string;
  };
}

const PROVIDERS: ProviderDefinition[] = [
  {
    id: "openai-api",
    title: "OpenAI API",
    description: "Hosted OpenAI models via API key auth.",
    requiresApiKey: true,
    authHint: "Uses payload key, saved config key, or OPENAI_API_KEY.",
    defaultEntry: {
      title: "openai-api",
      apiKey: "",
      apiUrl: "https://api.openai.com/v1",
      model: "gpt-4.1-mini"
    }
  },
  {
    id: "openai-oauth",
    title: "OpenAI Codex",
    description: "ChatGPT/Codex login via OpenAI OAuth.",
    requiresApiKey: false,
    authHint: "Uses OAuth tokens stored by Core. Connection test loads Codex models from the ChatGPT backend.",
    defaultEntry: {
      title: "openai-oauth",
      apiKey: "",
      apiUrl: "https://chatgpt.com/backend-api",
      model: "gpt-5.3-codex"
    }
  },
  {
    id: "ollama",
    title: "Ollama",
    description: "Local models served from an Ollama endpoint.",
    requiresApiKey: false,
    authHint: "Connects to /api/tags and lists local models.",
    defaultEntry: {
      title: "ollama-local",
      apiKey: "",
      apiUrl: "http://127.0.0.1:11434",
      model: "qwen3"
    }
  }
];

const STEP_TITLES = [
  "First project",
  "LLM provider",
  "First agent",
  "Launch prompt"
];

const DEFAULT_PROMPT =
  "You are already configured as the CEO. Use the ceo persona found here: https://github.com/TeamSloppy/Sloppy/blob/main/Assets/Agents/ceo/AGENTS.md.\n\n" +
  "Start operating as the CEO of this company and project. First, inspect the current workspace and establish the company's immediate priorities.\n\n";

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function toSlug(value: string) {
  const slug = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");

  return slug || "id-" + Math.random().toString(36).substring(2, 7);
}

function inferProviderId(config: AnyRecord) {
  const models = Array.isArray(config.models) ? config.models : [];
  const first = models.find((item) => item && typeof item === "object") as AnyRecord | undefined;
  const title = String(first?.title || "").toLowerCase();
  const apiUrl = String(first?.apiUrl || "").toLowerCase();

  if (title.includes("oauth")) {
    return "openai-oauth";
  }
  if (title.includes("ollama") || apiUrl.includes("11434") || apiUrl.includes("ollama")) {
    return "ollama";
  }
  return "openai-api";
}

function initialProviderState(config: AnyRecord) {
  const providerId = inferProviderId(config);
  const definition = PROVIDERS.find((provider) => provider.id === providerId) || PROVIDERS[0];
  const models = Array.isArray(config.models) ? config.models : [];
  const entry = (models.find((item) => item && typeof item === "object") as AnyRecord | undefined) || {};

  return {
    providerId,
    apiKey: String(entry.apiKey || definition.defaultEntry.apiKey || ""),
    apiUrl: String(entry.apiUrl || definition.defaultEntry.apiUrl || ""),
    selectedModel: String(entry.model || "")
  };
}

function runtimeModelId(providerId: string, modelId: string) {
  if (providerId.startsWith("openai")) {
    return `openai:${modelId}`;
  }
  if (providerId === "ollama") {
    return `ollama:${modelId}`;
  }
  return modelId;
}

function shouldUseCeoPersona(agentId: string, agentName: string, agentRole: string) {
  const normalizedId = agentId.trim().toLowerCase();
  const normalizedName = agentName.trim().toLowerCase();
  const normalizedRole = agentRole.trim().toLowerCase();

  return normalizedId === "ceo" || normalizedName === "ceo" || normalizedRole === "ceo";
}

function createConfigWithProvider(
  config: AnyRecord,
  provider: ProviderDefinition,
  apiKey: string,
  apiUrl: string,
  modelId: string,
  onboardingCompleted: boolean
) {
  const next = clone(config);
  next.workspace = {
    ...(typeof next.workspace === "object" && next.workspace ? (next.workspace as AnyRecord) : {}),
    name: ".sloppy",
    basePath: String((next.workspace as AnyRecord | undefined)?.basePath || "~")
  };
  next.onboarding = { completed: onboardingCompleted };
  next.models = [
    {
      title: provider.defaultEntry.title,
      apiKey: provider.requiresApiKey ? apiKey.trim() : "",
      apiUrl: apiUrl.trim() || provider.defaultEntry.apiUrl,
      model: modelId.trim() || provider.defaultEntry.model
    }
  ];
  return next;
}

function providerCardIcon(providerId: string) {
  if (providerId === "openai-api") {
    return "auto_awesome";
  }
  if (providerId === "openai-oauth") {
    return "login";
  }
  return "deployed_code";
}

function OnboardingAsciiCanvas({
  stepIndex,
  projectName,
  agentName,
  providerTitle
}: {
  stepIndex: number;
  projectName: string;
  agentName: string;
  providerTitle: string;
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) {
      return;
    }

    const context = canvas.getContext("2d");
    if (!context) {
      return;
    }

    let frame = 0;
    let animationFrame = 0;

    function draw() {
      const parent = canvas.parentElement;
      const width = parent?.clientWidth || 640;
      const height = parent?.clientHeight || 720;
      const scale = window.devicePixelRatio || 1;
      canvas.width = Math.floor(width * scale);
      canvas.height = Math.floor(height * scale);
      canvas.style.width = `${width}px`;
      canvas.style.height = `${height}px`;
      context.setTransform(scale, 0, 0, scale, 0, 0);

      context.fillStyle = "#020403";
      context.fillRect(0, 0, width, height);

      context.font = "13px 'Fira Code', monospace";
      context.textBaseline = "top";

      const cols = Math.floor(width / 14);
      const rows = Math.floor(height / 16);
      const glyphs = [".", ":", "+", "=", "/", "\\", "[", "]", "0", "1"];

      for (let row = 0; row < rows; row += 1) {
        for (let col = 0; col < cols; col += 1) {
          const seed = (row * 17 + col * 31 + frame) % 19;
          if ((row + col + frame) % 7 !== 0 && seed % 5 !== 0) {
            continue;
          }
          const glyph = glyphs[(seed + stepIndex) % glyphs.length];
          context.fillStyle = seed % 3 === 0 ? "rgba(204,255,0,0.78)" : "rgba(204,255,0,0.22)";
          context.fillText(glyph, col * 14, row * 16);
        }
      }

      const logo = [
        "╔════════════════════╗",
        "║      SLOPPY        ║",
        "║   INIT / BOOT      ║",
        "╚════════════════════╝"
      ];
      context.fillStyle = "#d9ff57";
      logo.forEach((line, index) => {
        context.fillText(line, 56, 72 + index * 18);
      });

      const meta = [
        `STEP 0${stepIndex + 1} // ${STEP_TITLES[stepIndex].toUpperCase()}`,
        `PROJECT: ${(projectName || "untitled").slice(0, 28).toUpperCase()}`,
        `AGENT: ${(agentName || "pending").slice(0, 28).toUpperCase()}`,
        `LINK: ${(providerTitle || "No uplink").toUpperCase()}`
      ];
      context.fillStyle = "rgba(240,255,214,0.88)";
      meta.forEach((line, index) => {
        context.fillText(line, 56, height - 176 + index * 20);
      });

      context.strokeStyle = "rgba(204,255,0,0.65)";
      context.lineWidth = 1;
      context.strokeRect(34, 42, width - 68, height - 84);
      context.strokeRect(48, 56, width - 96, height - 112);

      context.fillStyle = "rgba(204,255,0,0.12)";
      context.fillRect(56, height - 212, width - 112, 108);

      frame += 1;
      animationFrame = window.requestAnimationFrame(draw);
    }

    draw();
    return () => window.cancelAnimationFrame(animationFrame);
  }, [agentName, projectName, providerTitle, stepIndex]);

  return <canvas ref={canvasRef} className="onboarding-ascii-canvas" aria-hidden="true" />;
}

export function OnboardingView({ coreApi, initialConfig, onCompleted }: OnboardingViewProps) {
  const initialProvider = useMemo(() => initialProviderState(initialConfig), [initialConfig]);
  const [stepIndex, setStepIndex] = useState(0);
  const [projectName, setProjectName] = useState("");
  const [projectDescription, setProjectDescription] = useState("");
  const [providerId, setProviderId] = useState(initialProvider.providerId);
  const [providerApiKey, setProviderApiKey] = useState(initialProvider.apiKey);
  const [providerApiUrl, setProviderApiUrl] = useState(initialProvider.apiUrl);
  const [selectedModel, setSelectedModel] = useState(initialProvider.selectedModel);
  const [modelSearchQuery, setModelSearchQuery] = useState("");
  const [oauthCallbackURL, setOAuthCallbackURL] = useState("");
  const [probeStatus, setProbeStatus] = useState("Pick a provider and test the connection.");
  const [probeOk, setProbeOk] = useState(false);
  const [probeModels, setProbeModels] = useState<AnyRecord[]>([]);
  const [agentName, setAgentName] = useState("CEO");
  const [agentRole, setAgentRole] = useState("CEO");
  const [launchPrompt, setLaunchPrompt] = useState(DEFAULT_PROMPT);
  const [statusText, setStatusText] = useState("Preparing first-run setup.");
  const [isProbing, setIsProbing] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const oauthCallbackHandledRef = useRef(false);

  const activeProvider = useMemo(
    () => PROVIDERS.find((provider) => provider.id === providerId) || PROVIDERS[0],
    [providerId]
  );
  const projectId = useMemo(() => toSlug(projectName), [projectName]);
  const agentId = useMemo(() => toSlug(agentName), [agentName]);
  const selectedRuntimeModel = useMemo(
    () => runtimeModelId(providerId, selectedModel),
    [providerId, selectedModel]
  );

  const filteredProbeModels = useMemo(() => {
    const needle = modelSearchQuery.trim().toLowerCase();
    if (!needle) return probeModels;
    return probeModels.filter(m => {
      const id = String(m.id || "").toLowerCase();
      const title = String(m.title || "").toLowerCase();
      return id.includes(needle) || title.includes(needle);
    });
  }, [probeModels, modelSearchQuery]);

  useEffect(() => {
    setProbeOk(false);
    setProbeModels([]);
    setSelectedModel("");
    setProbeStatus("Connection parameters changed. Test the provider again.");
  }, [providerId, providerApiKey, providerApiUrl]);

  async function runProviderProbe(nextProviderId = activeProvider.id, nextApiKey = providerApiKey, nextApiUrl = providerApiUrl) {
    setIsProbing(true);
    setProbeStatus(`Testing ${nextProviderId === "openai-oauth" ? "OpenAI Codex" : activeProvider.title}...`);
    const response = await coreApi.probeProvider({
      providerId: nextProviderId,
      apiKey: nextProviderId === "openai-api" ? nextApiKey : undefined,
      apiUrl: nextApiUrl
    });
    setIsProbing(false);

    if (!response) {
      setProbeOk(false);
      setProbeModels([]);
      setProbeStatus("Probe failed. Core did not return a provider response.");
      return;
    }

    const ok = Boolean(response.ok);
    const models = Array.isArray(response.models) ? response.models : [];
    setProbeOk(ok);
    setProbeModels(models);
    setProbeStatus(String(response.message || (ok ? "Provider is ready." : "Provider probe failed.")));
    if (ok && models.length > 0) {
      setSelectedModel(String(models[0]?.id || ""));
    }
  }

  async function openOAuth() {
    setProbeStatus("Preparing OpenAI OAuth...");
    const response = await coreApi.startOpenAIOAuth({
      redirectURI: buildOpenAIOAuthRedirectURI()
    });

    if (!response || typeof response.authorizationURL !== "string" || !response.authorizationURL) {
      setProbeStatus("Failed to start OpenAI OAuth.");
      return;
    }

    const popup = openOpenAIOAuthPopup(response.authorizationURL);
    if (!popup) {
      window.location.assign(response.authorizationURL);
      return;
    }

    setProbeStatus(
      `OpenAI OAuth opened. After redirect to ${OPENAI_OAUTH_REDIRECT_URI}, copy the full URL from the popup and paste it below.`
    );
  }

  async function submitOAuthCallback() {
    const callbackURL = oauthCallbackURL.trim();
    if (!callbackURL) {
      setProbeStatus("Paste the full callback URL first.");
      return;
    }

    setProbeStatus("Completing OpenAI OAuth...");
    const response = await coreApi.completeOpenAIOAuth({ callbackURL });
    const ok = Boolean(response?.ok);
    const message = String(response?.message || "Failed to complete OpenAI OAuth.");
    setProbeStatus(message);
    if (!ok) {
      setProbeOk(false);
      return;
    }

    setOAuthCallbackURL("");
    setProviderId("openai-oauth");
    const oauthApiUrl = PROVIDERS.find((provider) => provider.id === "openai-oauth")?.defaultEntry.apiUrl || providerApiUrl;
    setProviderApiUrl(oauthApiUrl);
    await runProviderProbe("openai-oauth", "", oauthApiUrl);
  }

  async function testProviderConnection() {
    if (isProbing) {
      return;
    }
    await runProviderProbe();
  }

  useEffect(() => {
    async function completeOAuthFromCallback() {
      const callbackURL = readOpenAIOAuthCallbackURL();
      if (!callbackURL || oauthCallbackHandledRef.current) {
        return;
      }

      oauthCallbackHandledRef.current = true;
      const callbackError = readOpenAIOAuthCallbackError();
      if (callbackError) {
        clearOpenAIOAuthCallbackParams();
        postOpenAIOAuthMessage({
          ok: false,
          message: `OpenAI OAuth failed: ${callbackError}`
        });
        setProbeOk(false);
        setProbeStatus(`OpenAI OAuth failed: ${callbackError}`);
        return;
      }

      setProbeStatus("Completing OpenAI OAuth...");
      const response = await coreApi.completeOpenAIOAuth({ callbackURL });
      clearOpenAIOAuthCallbackParams();

      const ok = Boolean(response?.ok);
      const message = String(response?.message || "Failed to complete OpenAI OAuth.");
      postOpenAIOAuthMessage({
        ok,
        message,
        accountId: typeof response?.accountId === "string" ? response.accountId : null,
        planType: typeof response?.planType === "string" ? response.planType : null
      });

      setProviderId("openai-oauth");
      setProviderApiUrl(PROVIDERS.find((provider) => provider.id === "openai-oauth")?.defaultEntry.apiUrl || providerApiUrl);
      if (!ok) {
        setProbeOk(false);
        setProbeStatus(message);
        return;
      }

      if (window.opener && window.opener !== window) {
        window.close();
        return;
      }

      await runProviderProbe("openai-oauth", "", PROVIDERS.find((provider) => provider.id === "openai-oauth")?.defaultEntry.apiUrl || providerApiUrl);
    }

    completeOAuthFromCallback().catch(() => {
      setProbeOk(false);
      setProbeStatus("Failed to complete OpenAI OAuth.");
    });
  }, [coreApi, providerApiUrl]);

  useEffect(() => {
    function handleOAuthMessage(event: MessageEvent) {
      if (event.origin !== window.location.origin) {
        return;
      }
      const payload = event.data;
      if (!payload || payload.type !== OPENAI_OAUTH_MESSAGE_TYPE) {
        return;
      }

      setProviderId("openai-oauth");
      setProviderApiUrl(PROVIDERS.find((provider) => provider.id === "openai-oauth")?.defaultEntry.apiUrl || providerApiUrl);
      setProbeStatus(String(payload.message || "OpenAI OAuth updated."));
      if (!payload.ok) {
        setProbeOk(false);
        return;
      }
      void runProviderProbe(
        "openai-oauth",
        "",
        PROVIDERS.find((provider) => provider.id === "openai-oauth")?.defaultEntry.apiUrl || providerApiUrl
      );
    }

    window.addEventListener("message", handleOAuthMessage);
    return () => window.removeEventListener("message", handleOAuthMessage);
  }, [providerApiUrl]);

  function canAdvance() {
    if (stepIndex === 0) {
      return projectName.trim().length > 0;
    }
    if (stepIndex === 1) {
      return probeOk && selectedModel.trim().length > 0;
    }
    if (stepIndex === 2) {
      return agentName.trim().length > 0 && agentRole.trim().length > 0 && agentId.length > 0;
    }
    return launchPrompt.trim().length > 0;
  }

  async function ensureProject() {
    const existing = await coreApi.fetchProject(projectId);
    if (existing) {
      return existing;
    }

    const created = await coreApi.createProject({
      id: projectId,
      name: projectName.trim(),
      description: projectDescription.trim(),
      channels: []
    });
    if (created) {
      return created;
    }

    const retried = await coreApi.fetchProject(projectId);
    if (retried) {
      return retried;
    }

    throw new Error("Failed to create or reuse the first project.");
  }

  async function ensureAgent() {
    const existing = await coreApi.fetchAgent(agentId);
    if (existing) {
      return existing;
    }

    const created = await coreApi.createAgent({
      id: agentId,
      displayName: agentName.trim(),
      role: agentRole.trim()
    });
    if (created) {
      return created;
    }

    const retried = await coreApi.fetchAgent(agentId);
    if (retried) {
      return retried;
    }

    throw new Error("Failed to create or reuse the first agent.");
  }

  async function completeOnboarding() {
    if (isSubmitting || !canAdvance()) {
      return;
    }

    setIsSubmitting(true);

    try {
      setStatusText("Saving provider configuration...");
      const draftConfig = createConfigWithProvider(
        initialConfig,
        activeProvider,
        providerApiKey,
        providerApiUrl,
        selectedModel,
        false
      );
      const savedConfig = await coreApi.updateRuntimeConfig(draftConfig);
      if (!savedConfig) {
        throw new Error("Failed to save runtime config.");
      }

      setStatusText("Creating the first project...");
      await ensureProject();

      setStatusText("Creating the first agent...");
      await ensureAgent();

      setStatusText("Applying agent model...");
      const agentConfig = await coreApi.fetchAgentConfig(agentId);
      if (!agentConfig) {
        throw new Error("Failed to load agent config.");
      }

      const nextDocuments =
        shouldUseCeoPersona(agentId, agentName, agentRole)
          ? {
              ...agentConfig.documents,
              agentsMarkdown: DEFAULT_PROMPT.trim()
            }
          : agentConfig.documents;

      const updatedAgentConfig = await coreApi.updateAgentConfig(agentId, {
        selectedModel: selectedRuntimeModel,
        documents: nextDocuments,
        heartbeat: agentConfig.heartbeat,
        channelSessions: agentConfig.channelSessions
      });
      if (!updatedAgentConfig) {
        throw new Error("Failed to update the first agent config.");
      }

      setStatusText("Opening the first session...");
      const session = await coreApi.createAgentSession(agentId, {
        title: "Onboarding bootstrap"
      });
      if (!session || typeof session.id !== "string") {
        throw new Error("Failed to create onboarding session.");
      }

      setStatusText("Sending launch prompt...");
      const message = await coreApi.postAgentSessionMessage(agentId, session.id, {
        userId: "onboarding",
        content: launchPrompt.trim(),
        attachments: [],
        spawnSubSession: false
      });
      if (!message) {
        throw new Error("Failed to send the launch prompt.");
      }

      setStatusText("Finalizing workspace...");
      const completedConfig = createConfigWithProvider(
        savedConfig,
        activeProvider,
        providerApiKey,
        providerApiUrl,
        selectedModel,
        true
      );
      const finalized = await coreApi.updateRuntimeConfig(completedConfig);
      if (!finalized) {
        throw new Error("Failed to mark onboarding as completed.");
      }

      window.history.pushState({}, "", `/agents/${encodeURIComponent(agentId)}/chat`);
      onCompleted(finalized);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to finish onboarding.";
      setStatusText(message);
      setIsSubmitting(false);
      return;
    }

    setIsSubmitting(false);
  }

  function nextStep() {
    if (!canAdvance()) {
      return;
    }
    if (stepIndex === STEP_TITLES.length - 1) {
      void completeOnboarding();
      return;
    }
    setStepIndex((value) => Math.min(STEP_TITLES.length - 1, value + 1));
    setStatusText(`Step ${stepIndex + 2} of ${STEP_TITLES.length}.`);
  }

  function previousStep() {
    setStepIndex((value) => Math.max(0, value - 1));
  }

  return (
    <div className="onboarding-shell">
      <section className="onboarding-panel">
        <div className="onboarding-chrome">
          <span className="onboarding-kicker">First start bootstrap</span>
          <div className="onboarding-progress">
            {STEP_TITLES.map((title, index) => (
              <span
                key={title}
                className={`onboarding-progress-segment ${index === stepIndex ? "active" : index < stepIndex ? "done" : ""}`}
              />
            ))}
          </div>
        </div>

        <div key={stepIndex} className="onboarding-stage">
          <div className="onboarding-stage-head">
            <span className="material-symbols-rounded" aria-hidden="true">
              {stepIndex === 0 ? "domain" : stepIndex === 1 ? "hub" : stepIndex === 2 ? "support_agent" : "terminal"}
            </span>
            <div>
              <p className="onboarding-stage-overline">Step {stepIndex + 1} of 4</p>
              <h1>{STEP_TITLES[stepIndex]}</h1>
              <p>{statusText}</p>
            </div>
          </div>

          {stepIndex === 0 ? (
            <div className="onboarding-form-block">
              <label>
                Project name
                <input
                  value={projectName}
                  onChange={(event) => setProjectName(event.target.value)}
                  placeholder="Acme Core"
                  autoFocus
                />
              </label>
              <label>
                Project description
                <input
                  value={projectDescription}
                  onChange={(event) => setProjectDescription(event.target.value)}
                  placeholder="The main hub for Acme operations"
                />
              </label>
              <div className="onboarding-inline-note">
                Project id preview: <strong>{projectId || "acme-core"}</strong>
              </div>
            </div>
          ) : null}

          {stepIndex === 1 ? (
            <div className="onboarding-form-block">
              <div className="onboarding-provider-grid">
                {PROVIDERS.map((provider) => (
                  <button
                    key={provider.id}
                    type="button"
                    className={`onboarding-provider-card ${provider.id === providerId ? "active" : ""}`}
                    onClick={() => {
                      setProviderId(provider.id);
                      setProviderApiKey(provider.defaultEntry.apiKey);
                      setProviderApiUrl(provider.defaultEntry.apiUrl);
                      setOAuthCallbackURL("");
                    }}
                  >
                    <span className="material-symbols-rounded" aria-hidden="true">
                      {providerCardIcon(provider.id)}
                    </span>
                    <strong>{provider.title}</strong>
                    <span>{provider.description}</span>
                  </button>
                ))}
              </div>

              {activeProvider.requiresApiKey ? (
                <label>
                  API key
                  <input
                    type="password"
                    value={providerApiKey}
                    onChange={(event) => setProviderApiKey(event.target.value)}
                    placeholder="sk-..."
                  />
                </label>
              ) : null}

              <label>
                API URL
                <input
                  value={providerApiUrl}
                  onChange={(event) => setProviderApiUrl(event.target.value)}
                  placeholder={activeProvider.defaultEntry.apiUrl}
                />
              </label>

              <div className="onboarding-provider-actions">
                {activeProvider.id === "openai-oauth" ? (
                  <button type="button" className="onboarding-ghost-button hover-levitate" onClick={openOAuth}>
                    Connect OpenAI
                  </button>
                ) : null}
                <button type="button" className="onboarding-primary-button hover-levitate" onClick={() => void testProviderConnection()} disabled={isProbing}>
                  {isProbing ? "Testing..." : "Test connection"}
                </button>
              </div>

              {activeProvider.id === "openai-oauth" ? (
                <div className="onboarding-form-block">
                  <label>
                    Callback URL
                    <input
                      value={oauthCallbackURL}
                      onChange={(event) => setOAuthCallbackURL(event.target.value)}
                      placeholder={`${OPENAI_OAUTH_REDIRECT_URI}?code=...&state=...`}
                    />
                  </label>
                  <div className="onboarding-inline-note">
                    After OpenAI redirects to <strong>{OPENAI_OAUTH_REDIRECT_URI}</strong>, copy the full URL from the popup into this field.
                  </div>
                  <div className="onboarding-provider-actions">
                    <button type="button" className="onboarding-ghost-button hover-levitate" onClick={() => void submitOAuthCallback()}>
                      Complete OAuth
                    </button>
                  </div>
                </div>
              ) : null}

              <div className={`onboarding-provider-status ${probeOk ? "ok" : "warn"}`}>
                <strong>{probeOk ? "Ready" : "Pending"}</strong>
                <span>{probeStatus}</span>
                <small>{activeProvider.authHint}</small>
              </div>

              {probeOk && probeModels.length > 0 ? (
                <div className="onboarding-model-picker-container">
                  <label>
                    Model
                    <input
                      className="onboarding-model-search"
                      value={modelSearchQuery}
                      onChange={(event) => setModelSearchQuery(event.target.value)}
                      placeholder="Search for a model..."
                    />
                  </label>
                  <div className="onboarding-model-list">
                    {filteredProbeModels.length > 0 ? (
                      filteredProbeModels.map((model) => {
                        const id = String(model.id || "");
                        const title = String(model.title || id);
                        const isActive = selectedModel === id;
                        return (
                          <button
                            key={id}
                            type="button"
                            className={`onboarding-model-item ${isActive ? "active" : ""}`}
                            onClick={() => setSelectedModel(id)}
                          >
                            <div className="onboarding-model-item-main">
                              <strong>{title}</strong>
                              <small>{id}</small>
                            </div>
                            {isActive && <span className="material-symbols-rounded">check</span>}
                          </button>
                        );
                      })
                    ) : (
                      <div className="onboarding-model-empty">No models match your search.</div>
                    )}
                  </div>
                </div>
              ) : null}
            </div>
          ) : null}

          {stepIndex === 2 ? (
            <div className="onboarding-form-block">
              <label>
                Agent name
                <input
                  value={agentName}
                  onChange={(event) => setAgentName(event.target.value)}
                  placeholder="CEO"
                  autoFocus
                />
              </label>
              <label>
                Role
                <input
                  value={agentRole}
                  onChange={(event) => setAgentRole(event.target.value)}
                  placeholder="Founding operator"
                />
              </label>
              <div className="onboarding-inline-note">
                Agent id preview: <strong>{agentId || "ceo"}</strong>
              </div>
            </div>
          ) : null}

          {stepIndex === 3 ? (
            <div className="onboarding-form-block">
              <label>
                Launch prompt
                <textarea
                  value={launchPrompt}
                  onChange={(event) => setLaunchPrompt(event.target.value)}
                  rows={14}
                  autoFocus
                />
              </label>
              <div className="onboarding-inline-note">
                Session title: <strong>Onboarding bootstrap</strong>
              </div>
            </div>
          ) : null}
        </div>

        <div className="onboarding-footer">
          <button type="button" className="onboarding-ghost-button hover-levitate" onClick={previousStep} disabled={stepIndex === 0 || isSubmitting}>
            Back
          </button>
          <button
            type="button"
            className="onboarding-primary-button hover-levitate"
            onClick={nextStep}
            disabled={!canAdvance() || isSubmitting}
          >
            {stepIndex === STEP_TITLES.length - 1 ? (isSubmitting ? "Booting..." : "Finish setup") : "Next"}
          </button>
        </div>
      </section>

      <section className="onboarding-visual">
        <div className="onboarding-visual-hud">
          <span>[ uplink // {activeProvider.title.toLowerCase()} ]</span>
          <span>[ session // preboot ]</span>
        </div>
        <div className="onboarding-project-plaque">
          <span className="onboarding-project-plaque-label">Project plaque</span>
          <strong>{projectName.trim() || "Untitled project"}</strong>
          <small>{projectId || "pending-id"}</small>
        </div>
        <div className="onboarding-micrograph onboarding-micrograph-top" />
        <div className="onboarding-micrograph onboarding-micrograph-middle" />
        <div className="onboarding-micrograph onboarding-micrograph-bottom" />
        <OnboardingAsciiCanvas
          stepIndex={stepIndex}
          projectName={projectName}
          agentName={agentName}
          providerTitle={activeProvider.title}
        />
      </section>
    </div>
  );
}

import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createDependencies } from "./app/di/createDependencies";
import { DEFAULT_AGENT_TAB, DEFAULT_PROJECT_TAB } from "./app/routing/dashboardRouteAdapter";
import { useDashboardRoute } from "./app/routing/useDashboardRoute";
import { SidebarView } from "./components/SidebarView";
import { NotificationProvider } from "./features/notifications/NotificationContext";
import { NotificationBell } from "./features/notifications/NotificationBell";
import { NotificationToastContainer } from "./features/notifications/NotificationToast";
import { emitNotification } from "./features/notifications/notificationBus";
import { useNotificationSocket } from "./features/notifications/useNotificationSocket";
import { OnboardingView } from "./features/onboarding/OnboardingView";
import { useRuntimeOverview } from "./features/runtime-overview/model/useRuntimeOverview";
import { TerminalDrawer } from "./features/terminal/TerminalDrawer";
import { UpdateBanner } from "./features/updates/UpdateBanner";
import { useUpdateCheck } from "./features/updates/useUpdateCheck";
import { AgentsView } from "./views/AgentsView";
import { ActorsView } from "./views/ActorsView";
import { VisorChatView } from "./features/visor/VisorChatView";
import { ConfigView } from "./views/ConfigView";
import { LogsView } from "./views/LogsView";
import { DebugView } from "./views/DebugView";
import { NotFoundView } from "./views/NotFoundView";
import { ProjectsView } from "./views/ProjectsView";
import { ChannelSessionView } from "./views/ChannelSessionView";
import { RuntimeOverviewView } from "./views/RuntimeOverviewView";
import {
  DASHBOARD_AUTH_INVALIDATED_EVENT,
  getDashboardAuthToken,
  hasStoredDashboardAuthToken,
  isDashboardAuthTokenPersisted,
  setDashboardAuthToken
} from "./shared/api/dashboardAuth";
import {
  getStoredApiBaseOverride,
  normalizeApiBaseInput,
  resolveApiBase,
  setStoredApiBaseOverride
} from "./shared/api/httpClient";
import { fetchProjects } from "./api";

interface SidebarItem {
  id: string;
  label: {
    icon: string;
    title: string;
  };
  content: React.ReactNode;
}

type AnyRecord = Record<string, unknown>;

function isDashboardAuthRequired(config: AnyRecord | null) {
  const uiConfig = (config?.ui as AnyRecord | undefined) ?? null;
  const dashboardAuth = (uiConfig?.dashboardAuth as AnyRecord | undefined) ?? null;
  return Boolean(dashboardAuth?.enabled) && String(dashboardAuth?.token || "").trim().length > 0;
}

async function copyTextToClipboard(text: string) {
  if (!text.trim()) {
    return false;
  }

  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Fall through to the textarea fallback below.
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "true");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  textarea.style.top = "0";
  document.body.appendChild(textarea);
  textarea.select();

  try {
    return document.execCommand("copy");
  } catch {
    return false;
  } finally {
    document.body.removeChild(textarea);
  }
}

function DashboardShell({
  dependencies,
  debugEnabled,
  terminalEnabled,
  onRuntimeConfigUpdated
}: {
  dependencies: ReturnType<typeof createDependencies>;
  debugEnabled: boolean;
  terminalEnabled: boolean;
  onRuntimeConfigUpdated: (nextConfig: AnyRecord) => void;
}) {
  const runtime = useRuntimeOverview(dependencies.coreApi);
  const { route, setSection, setConfigSection, setProjectRoute, setAgentRoute, setSessionRoute, setChatsRoute } =
    useDashboardRoute();
  const [sidebarCompact, setSidebarCompact] = useState(true);
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false);
  const [sidebarProjects, setSidebarProjects] = useState<AnyRecord[]>([]);
  const [terminalClosedHost, setTerminalClosedHost] = useState<HTMLDivElement | null>(null);
  const [issueReportLoading, setIssueReportLoading] = useState(false);
  const sidebarChatRepairRef = useRef<string | null>(null);
  const { status: updateStatus } = useUpdateCheck();
  useNotificationSocket();

  const refreshSidebarProjects = useCallback(() => {
    fetchProjects()
      .then((list) => {
        if (Array.isArray(list)) {
          setSidebarProjects(list);
        }
      })
      .catch(() => {
        setSidebarProjects([]);
      });
  }, []);

  useEffect(() => {
    document.body.classList.toggle("mobile-menu-open", mobileSidebarOpen);
    return () => {
      document.body.classList.remove("mobile-menu-open");
    };
  }, [mobileSidebarOpen]);

  useEffect(() => {
    refreshSidebarProjects();
  }, [refreshSidebarProjects]);

  /** If a project chat route targets a project missing from the rail (e.g. created before refresh), refetch once. */
  useEffect(() => {
    if (route.section !== "projects" || route.projectTab !== "chat" || !route.projectId) {
      sidebarChatRepairRef.current = null;
      return;
    }
    const pid = String(route.projectId).trim();
    if (!pid) {
      return;
    }
    const found = sidebarProjects.some((p) => String((p as AnyRecord)?.id || "").trim() === pid);
    if (found) {
      sidebarChatRepairRef.current = null;
      return;
    }
    if (sidebarChatRepairRef.current === pid) {
      return;
    }
    sidebarChatRepairRef.current = pid;
    refreshSidebarProjects();
  }, [route.section, route.projectId, route.projectTab, sidebarProjects, refreshSidebarProjects]);

  useEffect(() => {
    const mediaQuery = window.matchMedia("(min-width: 1001px)");
    function handleChange(event: MediaQueryListEvent | MediaQueryList) {
      if (event.matches) {
        setMobileSidebarOpen(false);
      }
    }
    handleChange(mediaQuery);

    if (typeof mediaQuery.addEventListener === "function") {
      mediaQuery.addEventListener("change", handleChange);
      return () => mediaQuery.removeEventListener("change", handleChange);
    }

    mediaQuery.addListener(handleChange);
    return () => mediaQuery.removeListener(handleChange);
  }, []);

  function onSelectSidebar(nextSection: string) {
    setSection(nextSection);
    setMobileSidebarOpen(false);
  }

  function onAgentRouteChange(
    agentId: string | null,
    agentTab: string | null = DEFAULT_AGENT_TAB,
    initialChatSessionId: string | null = null
  ) {
    setAgentRoute(agentId, agentTab, initialChatSessionId);
  }

  function onProjectRouteChange(
    projectId: string | null,
    projectTab: string | null = DEFAULT_PROJECT_TAB,
    projectTaskReference: string | null = null
  ) {
    setProjectRoute(projectId, projectTab, projectTaskReference);
  }

  async function handleReportIssue() {
    if (issueReportLoading) {
      return;
    }

    setIssueReportLoading(true);
    const popup = window.open("about:blank", "_blank");
    if (!popup) {
      emitNotification("system_error", "Issue report blocked", "Allow popups for this dashboard, then try Report an Issue again.");
      setIssueReportLoading(false);
      return;
    }
    popup.opener = null;

    try {
      const report = await dependencies.coreApi.createIssueReport({ logLimit: 200 });
      const issueUrl = typeof report?.issueUrl === "string" ? report.issueUrl : "";
      const logs = typeof report?.logs === "string" ? report.logs : "";
      if (!issueUrl) {
        popup.close();
        emitNotification("system_error", "Issue report failed", "Sloppy could not prepare a sanitized GitHub issue URL.");
        return;
      }

      const copiedLogs = await copyTextToClipboard(logs);
      popup.location.href = issueUrl;
      setMobileSidebarOpen(false);
      emitNotification(
        copiedLogs ? "confirmation" : "system_error",
        copiedLogs ? "Issue report ready" : "Issue report opened",
        copiedLogs
          ? "Sanitized logs were copied to the clipboard. Paste them into the GitHub log field before submitting."
          : "GitHub opened, but Sloppy could not copy logs to the clipboard. Open Logs and copy the relevant lines manually."
      );
    } catch {
      popup.close();
      emitNotification("system_error", "Issue report failed", "Sloppy could not prepare a sanitized GitHub issue URL.");
    } finally {
      setIssueReportLoading(false);
    }
  }

  const runtimeContent = (
    <RuntimeOverviewView
      workers={runtime.workers}
      events={runtime.events}
      onNavigateToProject={(projectId: string) => {
        setSection("projects");
        if (projectId) {
          onProjectRouteChange(projectId, DEFAULT_PROJECT_TAB, null);
        }
      }}
      onNavigateToChannelSession={(sessionId: string) => {
        setSessionRoute(sessionId);
      }}
      onNavigateToBots={() => setSection("agents")}
      onNavigateToAgent={(agentId: string) => {
        setSection("agents");
        onAgentRouteChange(agentId, "overview");
      }}
    />
  );

  const sidebarItems: SidebarItem[] = [
    {
      id: "overview",
      label: { icon: "dashboard", title: "Overview" },
      content: runtimeContent
    },
    {
      id: "projects",
      label: { icon: "folder", title: "Projects" },
      content: (
        <ProjectsView
          channelState={runtime.channelState}
          workers={runtime.workers}
          bulletins={runtime.bulletins}
          routeProjectId={route.projectId}
          routeProjectTab={route.projectTab}
          routeProjectTaskReference={route.projectTaskReference}
          routeProjectChatAgentId={route.projectTab === "chat" ? route.chatAgentId : null}
          routeProjectChatSessionId={route.projectTab === "chat" ? route.chatSessionId : null}
          onRouteProjectChange={onProjectRouteChange as any}
          onRouteProjectChatChange={(projectId: string, agentId: string | null, sessionId: string | null) => {
            setChatsRoute(projectId, agentId, sessionId);
          }}
          onSidebarProjectsListChanged={refreshSidebarProjects}
          onNavigateToChannelSession={(sessionId: string) => {
            setSessionRoute(sessionId);
          }}
        />
      )
    },
    {
      id: "agents",
      label: { icon: "support_agent", title: "Agents" },
      content: (
        <AgentsView
          routeAgentId={route.agentId}
          routeTab={route.agentTab}
          routeAgentInitialChatSessionId={route.agentInitialChatSessionId}
          onRouteChange={onAgentRouteChange}
          onNavigateToChannelSession={(sessionId: string) => {
            setSessionRoute(sessionId);
          }}
        />
      )
    },
    {
      id: "actors",
      label: { icon: "group", title: "Actors" },
      content: <ActorsView />
    },
    {
      id: "visor",
      label: { icon: "visibility", title: "Visor" },
      content: <VisorChatView />
    },
    {
      id: "config",
      label: { icon: "settings", title: "Settings" },
      content: (
        <ConfigView
          sectionId={route.configSection}
          onSectionChange={setConfigSection}
          onRuntimeConfigUpdated={onRuntimeConfigUpdated}
        />
      )
    },
    {
      id: "logs",
      label: { icon: "description", title: "Logs" },
      content: <LogsView coreApi={dependencies.coreApi} />
    },
    ...(debugEnabled
      ? [{
          id: "debug" as const,
          label: { icon: "bug_report", title: "Debug" },
          content: <DebugView coreApi={dependencies.coreApi} />
        }]
      : [])
  ];

  const isNotFound = route.section === "not_found";
  const activeProjectId =
    typeof route.projectId === "string" && route.projectId.trim().length > 0 ? route.projectId : null;
  const activeProjectRecord =
    activeProjectId != null
      ? sidebarProjects.find((project) => String((project as AnyRecord)?.id || "").trim() === activeProjectId)
      : null;
  const activeProjectRepoPath = activeProjectRecord
    ? String((activeProjectRecord as AnyRecord)?.repoPath || "").trim() || null
    : null;
  const sidebarActiveItemId =
    sidebarItems.find((item) => item.id === route.section)?.id ?? sidebarItems[0].id;
  const pageContent = isNotFound ? (
    <NotFoundView />
  ) : route.section === "sessions" ? (
    <ChannelSessionView
      sessionId={route.sessionId}
      onNavigateBack={() => setSection("overview")}
    />
  ) : (
    (sidebarItems.find((item) => item.id === route.section) || sidebarItems[0]).content
  );

  return (
    <div
      className="layout"
      style={
        {
          "--terminal-drawer-inset-left": sidebarCompact ? "76px" : "228px"
        } as React.CSSProperties
      }
    >
      <SidebarView
        items={sidebarItems}
        activeItemId={sidebarActiveItemId}
        isCompact={sidebarCompact}
        onToggleCompact={() => setSidebarCompact((value) => !value)}
        onSelect={onSelectSidebar}
        isMobileOpen={mobileSidebarOpen}
        onRequestClose={() => setMobileSidebarOpen(false)}
        projectRailProjects={sidebarProjects}
        selectedChatProjectId={route.section === "projects" && route.projectTab === "chat" ? route.projectId : null}
        onSelectChatProject={(projectId: string) => {
          setChatsRoute(projectId, null, null);
        }}
        footer={
          <>
            <a
              href="https://docs.sloppy.team"
              target="_blank"
              rel="noopener noreferrer"
              className="sidebar-docs-link"
              title="Documentation"
            >
              <span className="material-symbols-rounded sidebar-icon" aria-hidden="true">
                menu_book
              </span>
              {!sidebarCompact && <span className="sidebar-docs-label">[ DOCS ]</span>}
            </a>
            <button
              type="button"
              className="sidebar-report-link"
              title="Report an Issue"
              aria-label="Report an Issue"
              onClick={handleReportIssue}
              disabled={issueReportLoading}
            >
              <span className="material-symbols-rounded sidebar-icon" aria-hidden="true">
                campaign
              </span>
              {!sidebarCompact && (
                <span className="sidebar-report-label">{issueReportLoading ? "[ PREPARING ]" : "[ REPORT ISSUE ]"}</span>
              )}
            </button>
            <div className="sidebar-footer-tray">
              <NotificationBell
                isCompact={sidebarCompact}
                onNavigateToAgent={(agentId: string, sessionId?: string) => {
                  onAgentRouteChange(agentId, "chat", sessionId ?? null);
                }}
              />
              {terminalEnabled ? <div className="sidebar-footer-terminal-host" ref={setTerminalClosedHost} /> : null}
            </div>
          </>
        }
      />
      <button
        type="button"
        className={`sidebar-mobile-overlay ${mobileSidebarOpen ? "open" : ""}`}
        onClick={() => setMobileSidebarOpen(false)}
        aria-label="Close menu"
      />

      <div className={`page ${route.section === "config" ? "page-config" : ""}`} style={{ position: "relative" }}>
        <div
          style={{
            position: "absolute",
            top: "2px",
            right: "20px",
            fontSize: "10px",
            color: "var(--accent)",
            zIndex: 1000,
            pointerEvents: "none",
            opacity: 0.6,
            letterSpacing: "0.1em"
          }}
        >
          [&gt;_ SECURE_SESSION_ACTIVE // PID: 9284]
        </div>
        <div
          style={{
            position: "absolute",
            bottom: "10px",
            right: "20px",
            fontSize: "10px",
            color: "var(--muted)",
            zIndex: 1000,
            pointerEvents: "none",
            opacity: 0.5
          }}
        >
          UPLINK: ESTABLISHED / LATENCY: 12MS
        </div>
        <button
          type="button"
          className="mobile-page-menu-button"
          onClick={() =>
            setMobileSidebarOpen((value) => {
              const next = !value;
              if (next) {
                setSidebarCompact(false);
              }
              return next;
            })
          }
          aria-label={mobileSidebarOpen ? "Close menu" : "Open menu"}
          aria-expanded={mobileSidebarOpen}
        >
          <span className="material-symbols-rounded" aria-hidden="true">
            menu
          </span>
        </button>
        {updateStatus && <UpdateBanner status={updateStatus} />}
        {pageContent}
        {terminalEnabled ? (
          <TerminalDrawer
            coreApi={dependencies.coreApi}
            currentProjectId={activeProjectId}
            currentProjectRepoPath={activeProjectRepoPath}
            closedHostElement={terminalClosedHost}
            isSidebarCompact={sidebarCompact}
          />
        ) : null}
      </div>
      <NotificationToastContainer />
    </div>
  );
}

export function App() {
  const dependencies = useMemo(() => createDependencies(), []);
  const [bootState, setBootState] = useState<{
    isLoading: boolean;
    config: AnyRecord | null;
    error: string;
  }>({
    isLoading: true,
    config: null,
    error: ""
  });
  const [apiBaseInput, setApiBaseInput] = useState(() => getStoredApiBaseOverride() || resolveApiBase());
  const [apiBaseError, setApiBaseError] = useState("");
  const [bootAttempt, setBootAttempt] = useState(0);
  const [dashboardTokenInput, setDashboardTokenInput] = useState("");
  const [rememberDashboardToken, setRememberDashboardToken] = useState(() => hasStoredDashboardAuthToken());
  const [authState, setAuthState] = useState<{
    status: "checking" | "required" | "authenticated";
    error: string;
  }>({
    status: "checking",
    error: ""
  });

  useEffect(() => {
    let isCancelled = false;

    async function runBootstrap() {
      setBootState((current) => ({
        ...current,
        isLoading: true,
        error: ""
      }));

      try {
        const config = await dependencies.coreApi.fetchRuntimeConfig();
        if (isCancelled) {
          return;
        }

        if (!config) {
          setBootState({
            isLoading: false,
            config: null,
            error: "Failed to load runtime config."
          });
          return;
        }

        const requiresDashboardAuth = isDashboardAuthRequired(config);
        if (requiresDashboardAuth) {
          const existingToken = getDashboardAuthToken();
          if (existingToken) {
            setAuthState({ status: "checking", error: "" });
            const validation = await dependencies.coreApi.validateDashboardAuthToken(existingToken);
            if (isCancelled) {
              return;
            }
            if (validation) {
              setRememberDashboardToken(isDashboardAuthTokenPersisted());
              setAuthState({ status: "authenticated", error: "" });
            } else {
              setRememberDashboardToken(isDashboardAuthTokenPersisted());
              setAuthState({
                status: "required",
                error: "Saved dashboard token is no longer valid."
              });
            }
          } else {
            setAuthState({ status: "required", error: "" });
          }
        } else {
          setAuthState({ status: "authenticated", error: "" });
        }

        setBootState({
          isLoading: false,
          config,
          error: ""
        });
      } catch {
        if (isCancelled) {
          return;
        }
        setBootState({
          isLoading: false,
          config: null,
          error: "Failed to load runtime config."
        });
      }
    }

    void runBootstrap();

    return () => {
      isCancelled = true;
    };
  }, [dependencies, bootAttempt]);

  useEffect(() => {
    function handleDashboardAuthInvalidated() {
      if (!isDashboardAuthRequired(bootState.config as AnyRecord | null)) {
        return;
      }
      setRememberDashboardToken(isDashboardAuthTokenPersisted());
      setAuthState({
        status: "required",
        error: "Dashboard token is invalid or expired."
      });
      setDashboardTokenInput("");
    }

    window.addEventListener(DASHBOARD_AUTH_INVALIDATED_EVENT, handleDashboardAuthInvalidated);
    return () => {
      window.removeEventListener(DASHBOARD_AUTH_INVALIDATED_EVENT, handleDashboardAuthInvalidated);
    };
  }, [bootState.config]);

  function retryBootstrap() {
    setApiBaseError("");
    setBootAttempt((value) => value + 1);
  }

  function handleApiBaseConnect() {
    const trimmed = apiBaseInput.trim();
    if (!trimmed) {
      setStoredApiBaseOverride("");
      setApiBaseInput(resolveApiBase());
      setApiBaseError("");
      retryBootstrap();
      return;
    }

    const normalized = normalizeApiBaseInput(trimmed);
    if (!normalized) {
      setApiBaseError("Enter host:port or full http(s) URL.");
      return;
    }

    setStoredApiBaseOverride(normalized);
    setApiBaseInput(normalized);
    setApiBaseError("");
    retryBootstrap();
  }

  async function handleDashboardAuthSubmit() {
    const token = dashboardTokenInput.trim();
    if (!token) {
      setAuthState({
        status: "required",
        error: "Enter the dashboard token."
      });
      return;
    }

    setAuthState({ status: "checking", error: "" });
    const validation = await dependencies.coreApi.validateDashboardAuthToken(token);
    if (!validation) {
      setAuthState({
        status: "required",
        error: "Token invalid. Check the value and try again."
      });
      return;
    }

    setDashboardAuthToken(token, { persist: rememberDashboardToken });
    setAuthState({ status: "authenticated", error: "" });
    setDashboardTokenInput("");
  }

  if (bootState.isLoading) {
    return (
      <div className="onboarding-loading-shell">
        <div className="onboarding-loading-card">
          <span className="onboarding-loading-kicker">Sloppy init</span>
          <strong>Loading runtime config...</strong>
        </div>
      </div>
    );
  }

  if (bootState.error || !bootState.config) {
    return (
      <div className="onboarding-loading-shell">
        <div className="onboarding-loading-card onboarding-loading-card-error">
          <span className="onboarding-loading-kicker">Sloppy init</span>
          <strong>{bootState.error || "Runtime config is unavailable."}</strong>
          <div className="onboarding-loading-form">
            <label className="onboarding-loading-label" htmlFor="sloppy-api-base">
              Core API URL
            </label>
            <input
              id="sloppy-api-base"
              className="onboarding-loading-input"
              type="text"
              inputMode="url"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              placeholder="192.168.1.50:25101"
              value={apiBaseInput}
              onChange={(event) => {
                setApiBaseInput(event.target.value);
                if (apiBaseError) {
                  setApiBaseError("");
                }
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  handleApiBaseConnect();
                }
              }}
            />
            <span className="onboarding-loading-hint">
              Enter `ip:port` or a full `http://` / `https://` URL for `sloppy-core`.
            </span>
            {apiBaseError ? <span className="onboarding-loading-error">{apiBaseError}</span> : null}
          </div>
          <div className="onboarding-loading-actions">
            <button
              type="button"
              className="onboarding-ghost-button"
              onClick={retryBootstrap}
            >
              Retry
            </button>
            <button
              type="button"
              className="onboarding-primary-button"
              onClick={handleApiBaseConnect}
            >
              Connect
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (!Boolean((bootState.config.onboarding as AnyRecord | undefined)?.completed)) {
    if (isDashboardAuthRequired(bootState.config) && authState.status !== "authenticated") {
      if (authState.status === "checking") {
        return (
          <div className="onboarding-loading-shell">
            <div className="onboarding-loading-card">
              <span className="onboarding-loading-kicker">Dashboard auth</span>
              <strong>Validating dashboard token...</strong>
            </div>
          </div>
        );
      }

      return (
        <div className="onboarding-loading-shell">
          <div className="onboarding-loading-card onboarding-loading-card-error">
            <span className="onboarding-loading-kicker">Dashboard auth</span>
            <strong>Enter the dashboard operator token</strong>
            <div className="onboarding-loading-form">
              <label className="onboarding-loading-label" htmlFor="sloppy-dashboard-token-onboarding">
                Token
              </label>
              <input
                id="sloppy-dashboard-token-onboarding"
                className="onboarding-loading-input"
                type="password"
                placeholder="Paste dashboard operator token"
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                value={dashboardTokenInput}
                onChange={(event) => {
                  setDashboardTokenInput(event.target.value);
                  if (authState.error) {
                    setAuthState((current) => ({
                      ...current,
                      error: ""
                    }));
                  }
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    void handleDashboardAuthSubmit();
                  }
                }}
              />
              <label className="agent-tools-guardrail agent-tools-guardrail-toggle">
                <span className="agent-tools-guardrail-copy">
                  <span className="agent-tools-guardrail-title">Remember this token in this browser</span>
                </span>
                <span className="agent-tools-switch">
                  <input
                    type="checkbox"
                    checked={rememberDashboardToken}
                    onChange={(event) => setRememberDashboardToken(event.target.checked)}
                  />
                  <span className="agent-tools-switch-track" />
                </span>
              </label>
              <span className="onboarding-loading-hint">
                This is a convenience-first local operator mode. Stored tokens use `localStorage`.
              </span>
              {authState.error ? <span className="onboarding-loading-error">{authState.error}</span> : null}
            </div>
            <div className="onboarding-loading-actions">
              <button
                type="button"
                className="onboarding-ghost-button"
                onClick={retryBootstrap}
              >
                Retry
              </button>
              <button
                type="button"
                className="onboarding-primary-button"
                onClick={() => void handleDashboardAuthSubmit()}
              >
                Unlock
              </button>
            </div>
          </div>
        </div>
      );
    }

    return (
      <OnboardingView
        coreApi={dependencies.coreApi}
        initialConfig={bootState.config}
        onCompleted={(config) =>
          setBootState({
            isLoading: false,
            config,
            error: ""
          })
        }
      />
    );
  }

  const runtimeConfig = bootState.config as Record<string, unknown> | null;
  const uiConfig = (runtimeConfig?.ui as AnyRecord | undefined) ?? null;
  const terminalConfig = (uiConfig?.dashboardTerminal as AnyRecord | undefined) ?? null;
  const dashboardAuthRequired = isDashboardAuthRequired(runtimeConfig);

  if (dashboardAuthRequired && authState.status !== "authenticated") {
    if (authState.status === "checking") {
      return (
        <div className="onboarding-loading-shell">
          <div className="onboarding-loading-card">
            <span className="onboarding-loading-kicker">Dashboard auth</span>
            <strong>Validating dashboard token...</strong>
          </div>
        </div>
      );
    }

    return (
      <div className="onboarding-loading-shell">
        <div className="onboarding-loading-card onboarding-loading-card-error">
          <span className="onboarding-loading-kicker">Dashboard auth</span>
          <strong>Enter the dashboard operator token</strong>
          <div className="onboarding-loading-form">
            <label className="onboarding-loading-label" htmlFor="sloppy-dashboard-token">
              Token
            </label>
            <input
              id="sloppy-dashboard-token"
              className="onboarding-loading-input"
              type="password"
              placeholder="Paste dashboard operator token"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              value={dashboardTokenInput}
              onChange={(event) => {
                setDashboardTokenInput(event.target.value);
                if (authState.error) {
                  setAuthState((current) => ({
                    ...current,
                    error: ""
                  }));
                }
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  void handleDashboardAuthSubmit();
                }
              }}
            />
            <label className="agent-tools-guardrail agent-tools-guardrail-toggle">
              <span className="agent-tools-guardrail-copy">
                <span className="agent-tools-guardrail-title">Remember this token in this browser</span>
              </span>
              <span className="agent-tools-switch">
                <input
                  type="checkbox"
                  checked={rememberDashboardToken}
                  onChange={(event) => setRememberDashboardToken(event.target.checked)}
                />
                <span className="agent-tools-switch-track" />
              </span>
            </label>
            <span className="onboarding-loading-hint">
              This is a convenience-first local operator mode. Stored tokens use `localStorage`.
            </span>
            {authState.error ? <span className="onboarding-loading-error">{authState.error}</span> : null}
          </div>
          <div className="onboarding-loading-actions">
            <button
              type="button"
              className="onboarding-ghost-button"
              onClick={retryBootstrap}
            >
              Retry
            </button>
            <button
              type="button"
              className="onboarding-primary-button"
              onClick={() => void handleDashboardAuthSubmit()}
            >
              Unlock
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <NotificationProvider>
      <DashboardShell
        dependencies={dependencies}
        debugEnabled={Boolean(runtimeConfig?.debugEnabled)}
        terminalEnabled={Boolean(terminalConfig?.enabled)}
        onRuntimeConfigUpdated={(nextConfig) => {
          if (isDashboardAuthRequired(nextConfig as AnyRecord)) {
            setRememberDashboardToken(isDashboardAuthTokenPersisted());
            setAuthState({
              status: getDashboardAuthToken() ? "authenticated" : "required",
              error: ""
            });
          } else {
            setAuthState({ status: "authenticated", error: "" });
          }
          setBootState((current) => ({
            ...current,
            config: nextConfig
          }));
        }}
      />
    </NotificationProvider>
  );
}

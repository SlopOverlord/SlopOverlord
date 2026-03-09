import React, { useEffect, useMemo, useState } from "react";
import { createDependencies } from "./app/di/createDependencies";
import { DEFAULT_AGENT_TAB, DEFAULT_PROJECT_TAB } from "./app/routing/dashboardRouteAdapter";
import { useDashboardRoute } from "./app/routing/useDashboardRoute";
import { SidebarView } from "./components/SidebarView";
import { OnboardingView } from "./features/onboarding/OnboardingView";
import { useRuntimeOverview } from "./features/runtime-overview/model/useRuntimeOverview";
import { AgentsView } from "./views/AgentsView";
import { ActorsView } from "./views/ActorsView";
import { ConfigView } from "./views/ConfigView";
import { LogsView } from "./views/LogsView";
import { NotFoundView } from "./views/NotFoundView";
import { ProjectsView } from "./views/ProjectsView";
import { RuntimeOverviewView } from "./views/RuntimeOverviewView";

interface SidebarItem {
  id: string;
  label: {
    icon: string;
    title: string;
  };
  content: React.ReactNode;
}

type AnyRecord = Record<string, unknown>;

function DashboardShell({ dependencies }: { dependencies: ReturnType<typeof createDependencies> }) {
  const runtime = useRuntimeOverview(dependencies.coreApi);
  const { route, setSection, setConfigSection, setProjectRoute, setAgentRoute } = useDashboardRoute();
  const [sidebarCompact, setSidebarCompact] = useState(true);
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false);

  useEffect(() => {
    document.body.classList.toggle("mobile-menu-open", mobileSidebarOpen);
    return () => {
      document.body.classList.remove("mobile-menu-open");
    };
  }, [mobileSidebarOpen]);

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

  function onAgentRouteChange(agentId: string | null, agentTab: string | null = DEFAULT_AGENT_TAB) {
    setAgentRoute(agentId, agentTab);
  }

  function onProjectRouteChange(
    projectId: string | null,
    projectTab: string | null = DEFAULT_PROJECT_TAB,
    projectTaskReference: string | null = null
  ) {
    setProjectRoute(projectId, projectTab, projectTaskReference);
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
          onRouteProjectChange={onProjectRouteChange as any}
        />
      )
    },
    {
      id: "agents",
      label: { icon: "support_agent", title: "Agents" },
      content: <AgentsView routeAgentId={route.agentId} routeTab={route.agentTab} onRouteChange={onAgentRouteChange} />
    },
    {
      id: "actors",
      label: { icon: "group", title: "Actors" },
      content: <ActorsView />
    },
    {
      id: "config",
      label: { icon: "settings", title: "Config" },
      content: <ConfigView sectionId={route.configSection} onSectionChange={setConfigSection} />
    },
    {
      id: "logs",
      label: { icon: "description", title: "Logs" },
      content: <LogsView coreApi={dependencies.coreApi} />
    }
  ];

  const isNotFound = route.section === "not_found";
  const activeItem = sidebarItems.find((item) => item.id === route.section) || sidebarItems[0];

  return (
    <div className="layout">
      <SidebarView
        items={sidebarItems}
        activeItemId={activeItem.id}
        isCompact={sidebarCompact}
        onToggleCompact={() => setSidebarCompact((value) => !value)}
        onSelect={onSelectSidebar}
        isMobileOpen={mobileSidebarOpen}
        onRequestClose={() => setMobileSidebarOpen(false)}
      />
      <button
        type="button"
        className={`sidebar-mobile-overlay ${mobileSidebarOpen ? "open" : ""}`}
        onClick={() => setMobileSidebarOpen(false)}
        aria-label="Close menu"
      />

      <div className={`page ${activeItem.id === "config" ? "page-config" : ""}`} style={{ position: "relative" }}>
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
        {isNotFound ? <NotFoundView /> : activeItem.content}
      </div>
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

  useEffect(() => {
    let isCancelled = false;

    async function bootstrap() {
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

      setBootState({
        isLoading: false,
        config,
        error: ""
      });
    }

    bootstrap().catch(() => {
      if (isCancelled) {
        return;
      }
      setBootState({
        isLoading: false,
        config: null,
        error: "Failed to load runtime config."
      });
    });

    return () => {
      isCancelled = true;
    };
  }, [dependencies]);

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
          <button
            type="button"
            className="onboarding-primary-button"
            onClick={() => window.location.reload()}
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  if (!Boolean((bootState.config.onboarding as AnyRecord | undefined)?.completed)) {
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

  return <DashboardShell dependencies={dependencies} />;
}

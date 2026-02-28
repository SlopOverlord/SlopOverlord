import React, { useEffect, useMemo, useState } from "react";
import { createDependencies } from "./app/di/createDependencies";
import { DEFAULT_AGENT_TAB } from "./app/routing/dashboardRouteAdapter";
import { useDashboardRoute } from "./app/routing/useDashboardRoute";
import { SidebarView } from "./components/SidebarView";
import { useRuntimeOverview } from "./features/runtime-overview/model/useRuntimeOverview";
import { AgentsView } from "./views/AgentsView";
import { ActorsView } from "./views/ActorsView";
import { ConfigView } from "./views/ConfigView";
import { PlaceholderView } from "./views/PlaceholderView";
import { ProjectsView } from "./views/ProjectsView";
import { RuntimeOverviewView } from "./views/RuntimeOverviewView";
import { LogsView } from "./views/LogsView";

interface SidebarItem {
  id: string;
  label: {
    icon: string;
    title: string;
  };
  content: React.ReactNode;
}

export function App() {
  const dependencies = useMemo(() => createDependencies(), []);
  const runtime = useRuntimeOverview(dependencies.coreApi);
  const { route, setSection, setConfigSection, setAgentRoute } = useDashboardRoute();
  const [sidebarCompact, setSidebarCompact] = useState(false);
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

  const runtimeContent = (
    <RuntimeOverviewView
      title={route.section === "chats" ? "Chats" : "Overview"}
      text={runtime.text}
      onTextChange={runtime.setText}
      onSend={runtime.sendMessage}
      messages={runtime.messages}
      tasks={runtime.tasks}
      artifactId={runtime.artifactId}
      onArtifactIdChange={runtime.setArtifactId}
      onLoadArtifact={runtime.loadArtifact}
      artifactContent={runtime.artifactContent}
      bulletins={runtime.bulletins}
    />
  );

  const sidebarItems: SidebarItem[] = [
    {
      id: "chats",
      label: { icon: "CH", title: "Chats" },
      content: runtimeContent
    },
    {
      id: "projects",
      label: { icon: "PR", title: "Projects" },
      content: <ProjectsView channelState={runtime.channelState} workers={runtime.workers} />
    },
    {
      id: "sessions",
      label: { icon: "SE", title: "Sessions" },
      content: <PlaceholderView title="Sessions" />
    },
    {
      id: "overview",
      label: { icon: "OV", title: "Overview" },
      content: runtimeContent
    },
    {
      id: "actors",
      label: { icon: "AT", title: "Actors" },
      content: <ActorsView />
    },
    {
      id: "agents",
      label: { icon: "AG", title: "Agents" },
      content: <AgentsView routeAgentId={route.agentId} routeTab={route.agentTab} onRouteChange={onAgentRouteChange} />
    },
    {
      id: "usafe",
      label: { icon: "US", title: "Usafe" },
      content: <PlaceholderView title="Usafe" />
    },
    {
      id: "nodes",
      label: { icon: "ND", title: "Nodes" },
      content: <PlaceholderView title="Nodes" />
    },
    {
      id: "config",
      label: { icon: "CF", title: "Config" },
      content: <ConfigView sectionId={route.configSection} onSectionChange={setConfigSection} />
    },
    {
      id: "logs",
      label: { icon: "LG", title: "Logs" },
      content: <LogsView coreApi={dependencies.coreApi} />
    }
  ];

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

      <div className={`page ${activeItem.id === "config" ? "page-config" : ""}`}>
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
        {activeItem.content}
      </div>
    </div>
  );
}

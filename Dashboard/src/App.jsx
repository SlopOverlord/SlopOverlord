import React, { useEffect, useMemo, useState } from "react";
import { fetchArtifact, fetchBulletins, fetchChannelState, fetchWorkers, sendChannelMessage } from "./api";
import { SidebarView } from "./components/SidebarView";
import { AgentsView } from "./views/AgentsView";
import { ConfigView } from "./views/ConfigView";
import { PlaceholderView } from "./views/PlaceholderView";
import { ProjectsView } from "./views/ProjectsView";
import { RuntimeOverviewView } from "./views/RuntimeOverviewView";

const CHANNEL_ID = "general";
const DEFAULT_SECTION_ID = "overview";
const DEFAULT_AGENT_TAB = "overview";
const TOP_LEVEL_SECTIONS = new Set([
  "chats",
  "projects",
  "sessions",
  "overview",
  "agents",
  "usafe",
  "nodes",
  "config",
  "logs"
]);
const AGENT_TABS = new Set(["overview", "chat", "memories", "tasks", "skills", "cron", "config"]);

function decodePathSegment(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function resolveRouteFromPath(pathname) {
  const [sectionRaw = "", sectionArgRaw = "", sectionArg2Raw = ""] = pathname
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean);

  const section = TOP_LEVEL_SECTIONS.has(sectionRaw) ? sectionRaw : DEFAULT_SECTION_ID;
  const sectionArg = decodePathSegment(sectionArgRaw);
  const sectionArg2 = decodePathSegment(sectionArg2Raw).toLowerCase();

  const configSection = section === "config" && sectionArg ? sectionArg : null;
  const agentId = section === "agents" && sectionArg ? sectionArg : null;
  const agentTab = section === "agents" && agentId
    ? AGENT_TABS.has(sectionArg2)
      ? sectionArg2
      : DEFAULT_AGENT_TAB
    : null;

  return { section, configSection, agentId, agentTab };
}

export function App() {
  const initialRoute = useMemo(() => resolveRouteFromPath(window.location.pathname), []);
  const [activeItemId, setActiveItemId] = useState(initialRoute.section);
  const [configSectionPath, setConfigSectionPath] = useState(initialRoute.configSection);
  const [agentIdPath, setAgentIdPath] = useState(initialRoute.agentId);
  const [agentTabPath, setAgentTabPath] = useState(initialRoute.agentTab);
  const [sidebarCompact, setSidebarCompact] = useState(false);
  const [text, setText] = useState("Implement branch workflow and review");
  const [messages, setMessages] = useState([]);
  const [state, setState] = useState(null);
  const [workers, setWorkers] = useState([]);
  const [bulletins, setBulletins] = useState([]);
  const [artifactId, setArtifactId] = useState("");
  const [artifactContent, setArtifactContent] = useState("Select artifact id to preview");

  const tasks = useMemo(() => {
    if (!state) {
      return [];
    }

    const last = state.lastDecision;
    return [
      {
        id: "task-live",
        title: "Current channel route",
        status: last ? last.action : "unknown",
        reason: last ? last.reason : "not available"
      }
    ];
  }, [state]);

  async function refreshRuntime() {
    const [nextState, nextBulletins, nextWorkers] = await Promise.all([
      fetchChannelState(CHANNEL_ID),
      fetchBulletins(),
      fetchWorkers()
    ]);
    setState(nextState);
    setBulletins(nextBulletins);
    setWorkers(nextWorkers);
    setMessages(nextState?.messages || []);
  }

  async function onSend(event) {
    event.preventDefault();
    if (!text.trim()) {
      return;
    }

    await sendChannelMessage(CHANNEL_ID, { userId: "dashboard", content: text });
    setText("");
    await refreshRuntime();
  }

  async function loadArtifact() {
    if (!artifactId.trim()) {
      return;
    }

    const artifact = await fetchArtifact(artifactId.trim());
    setArtifactContent(artifact?.content || "Artifact not found");
  }

  useEffect(() => {
    refreshRuntime().catch(() => {});
  }, []);

  useEffect(() => {
    const onPopState = () => {
      const nextRoute = resolveRouteFromPath(window.location.pathname);
      setActiveItemId(nextRoute.section);
      setConfigSectionPath(nextRoute.configSection);
      setAgentIdPath(nextRoute.agentId);
      setAgentTabPath(nextRoute.agentTab);
    };

    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, []);

  function setAgentRoute(agentId, agentTab = DEFAULT_AGENT_TAB) {
    setActiveItemId("agents");
    setAgentIdPath(agentId);
    setAgentTabPath(agentId ? agentTab : null);
  }

  function onSelectSidebar(nextSection) {
    setActiveItemId(nextSection);
  }

  useEffect(() => {
    let nextPathname = `/${activeItemId}`;
    if (activeItemId === "config" && configSectionPath) {
      nextPathname = `${nextPathname}/${configSectionPath}`;
    }
    if (activeItemId === "agents") {
      nextPathname = "/agents";
      if (agentIdPath) {
        nextPathname = `/agents/${encodeURIComponent(agentIdPath)}`;
        if (agentTabPath && agentTabPath !== DEFAULT_AGENT_TAB) {
          nextPathname = `${nextPathname}/${agentTabPath}`;
        }
      }
    }

    if (window.location.pathname !== nextPathname) {
      window.history.pushState({}, "", `${nextPathname}${window.location.search}${window.location.hash}`);
    }
  }, [activeItemId, configSectionPath, agentIdPath, agentTabPath]);

  const runtimeContent = (
    <RuntimeOverviewView
      title={activeItemId === "chats" ? "Chats" : "Overview"}
      text={text}
      onTextChange={setText}
      onSend={onSend}
      messages={messages}
      tasks={tasks}
      artifactId={artifactId}
      onArtifactIdChange={setArtifactId}
      onLoadArtifact={loadArtifact}
      artifactContent={artifactContent}
      bulletins={bulletins}
    />
  );

  const sidebarItems = [
    {
      id: "chats",
      label: { icon: "CH", title: "Chats" },
      content: runtimeContent
    },
    {
      id: "projects",
      label: { icon: "PR", title: "Projects" },
      content: <ProjectsView channelState={state} workers={workers} />
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
      id: "agents",
      label: { icon: "AG", title: "Agents" },
      content: <AgentsView routeAgentId={agentIdPath} routeTab={agentTabPath} onRouteChange={setAgentRoute} />
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
      content: <ConfigView sectionId={configSectionPath} onSectionChange={setConfigSectionPath} />
    },
    {
      id: "logs",
      label: { icon: "LG", title: "Logs" },
      content: <PlaceholderView title="Logs" />
    }
  ];

  const activeItem = sidebarItems.find((item) => item.id === activeItemId) || sidebarItems[0];

  return (
    <div className="layout">
      <SidebarView
        items={sidebarItems}
        activeItemId={activeItem.id}
        isCompact={sidebarCompact}
        onToggleCompact={() => setSidebarCompact((value) => !value)}
        onSelect={onSelectSidebar}
      />

      <div className={`page ${activeItem.id === "config" ? "page-config" : ""}`}>
        <header className="hero">
          <h1>SlopOverlord Dashboard</h1>
          <p>Section: {activeItem.label.title}</p>
        </header>
        {activeItem.content}
      </div>
    </div>
  );
}

import React, { useEffect, useMemo, useState } from "react";
import { fetchArtifact, fetchBulletins, fetchChannelState, sendChannelMessage } from "./api";
import { SidebarView } from "./components/SidebarView";
import { ConfigView } from "./views/ConfigView";
import { PlaceholderView } from "./views/PlaceholderView";
import { RuntimeOverviewView } from "./views/RuntimeOverviewView";

const CHANNEL_ID = "general";

export function App() {
  const [activeItemId, setActiveItemId] = useState("overview");
  const [sidebarCompact, setSidebarCompact] = useState(false);
  const [text, setText] = useState("Implement branch workflow and review");
  const [messages, setMessages] = useState([]);
  const [state, setState] = useState(null);
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
    const [nextState, nextBulletins] = await Promise.all([fetchChannelState(CHANNEL_ID), fetchBulletins()]);
    setState(nextState);
    setBulletins(nextBulletins);
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
      content: <PlaceholderView title="Projects" />
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
      content: <PlaceholderView title="Agents" />
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
      content: <ConfigView />
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
        onSelect={setActiveItemId}
      />

      <div className="page">
        <header className="hero">
          <h1>SlopOverlord Dashboard</h1>
          <p>Section: {activeItem.label.title}</p>
        </header>
        {activeItem.content}
      </div>
    </div>
  );
}

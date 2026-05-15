import { useCallback, useEffect, useMemo, useState } from "react";
import {
  DEFAULT_AGENT_TAB,
  DEFAULT_PROJECT_TAB,
  normalizeAgentTab,
  normalizeProjectTab,
  normalizeTopLevelSection,
  parseRouteFromPath,
  pushRouteToHistory,
  subscribeToPopState,
  type DashboardRoute
} from "./dashboardRouteAdapter";

interface DashboardRouteController {
  route: DashboardRoute;
  setSection: (section: string) => void;
  setConfigSection: (sectionId: string | null) => void;
  setProjectRoute: (projectId: string | null, projectTab?: string | null, projectTaskReference?: string | null) => void;
  setAgentRoute: (agentId: string | null, agentTab?: string | null, initialChatSessionId?: string | null) => void;
  setSessionRoute: (sessionId: string | null) => void;
  setChatsRoute: (
    chatProjectId: string | null,
    chatAgentId?: string | null,
    chatSessionId?: string | null
  ) => void;
}

export function useDashboardRoute(): DashboardRouteController {
  const initialRoute = useMemo(() => parseRouteFromPath(window.location.pathname), []);
  const [route, setRoute] = useState<DashboardRoute>(initialRoute);

  useEffect(() => {
    return subscribeToPopState(() => {
      setRoute(parseRouteFromPath(window.location.pathname));
    });
  }, []);

  useEffect(() => {
    pushRouteToHistory(route);
  }, [
    route.agentId,
    route.agentTab,
    route.agentInitialChatSessionId,
    route.chatAgentId,
    route.chatProjectId,
    route.chatSessionId,
    route.configSection,
    route.projectId,
    route.projectTab,
    route.projectTaskReference,
    route.section,
    route.sessionAgentId,
    route.sessionId
  ]);

  const setSection = useCallback((section: string) => {
    const nextSection = normalizeTopLevelSection(String(section || "").trim());
    setRoute((current) => ({
      ...current,
      section: nextSection,
      agentInitialChatSessionId: nextSection === "agents" ? current.agentInitialChatSessionId : null,
      ...(nextSection !== "projects"
        ? { chatProjectId: null, chatAgentId: null, chatSessionId: null }
        : {})
    }));
  }, []);

  const setConfigSection = useCallback((sectionId: string | null) => {
    setRoute((current) => ({
      ...current,
      configSection: typeof sectionId === "string" && sectionId.trim().length > 0 ? sectionId : null
    }));
  }, []);

  const setProjectRoute = useCallback(
    (projectId: string | null, projectTab: string | null = DEFAULT_PROJECT_TAB, projectTaskReference: string | null = null) => {
      const normalizedProjectID = typeof projectId === "string" && projectId.trim().length > 0 ? projectId : null;
      const normalizedProjectTab = normalizedProjectID
        ? normalizeProjectTab(String(projectTab || DEFAULT_PROJECT_TAB).toLowerCase())
        : null;
      const normalizedTaskReference = normalizedProjectID && normalizedProjectTab === "tasks"
        ? String(projectTaskReference || "").trim() || null
        : null;

      setRoute((current) => ({
        ...current,
        section: "projects",
        projectId: normalizedProjectID,
        projectTab: normalizedProjectTab,
        projectTaskReference: normalizedTaskReference,
        agentInitialChatSessionId: null,
        chatProjectId:
          normalizedProjectID && normalizedProjectTab === "chat" ? normalizedProjectID : null,
        chatAgentId: null,
        chatSessionId: null
      }));
    },
    []
  );

  const setAgentRoute = useCallback(
    (agentId: string | null, agentTab: string | null = DEFAULT_AGENT_TAB, initialChatSessionId: string | null = null) => {
      const normalizedAgentID = typeof agentId === "string" && agentId.trim().length > 0 ? agentId : null;
      const normalizedAgentTab = normalizedAgentID
        ? normalizeAgentTab(String(agentTab || DEFAULT_AGENT_TAB).toLowerCase())
        : null;

      setRoute((current) => ({
        ...current,
        section: "agents",
        agentId: normalizedAgentID,
        agentTab: normalizedAgentTab,
        agentInitialChatSessionId:
          normalizedAgentID && normalizedAgentTab === "chat" ? initialChatSessionId : null,
        chatProjectId: null,
        chatAgentId: null,
        chatSessionId: null
      }));
    },
    []
  );

  const setSessionRoute = useCallback((sessionId: string | null) => {
    const normalizedSessionID = typeof sessionId === "string" && sessionId.trim().length > 0 ? sessionId : null;

    setRoute((current) => ({
      ...current,
      section: "sessions",
      sessionAgentId: null,
      sessionId: normalizedSessionID,
      agentInitialChatSessionId: null,
      chatProjectId: null,
      chatAgentId: null,
      chatSessionId: null
    }));
  }, []);

  const setChatsRoute = useCallback(
    (chatProjectId: string | null, chatAgentId: string | null = null, chatSessionId: string | null = null) => {
      const normalizedProjectID =
        typeof chatProjectId === "string" && chatProjectId.trim().length > 0 ? chatProjectId.trim() : null;
      const normalizedAgentID =
        normalizedProjectID && typeof chatAgentId === "string" && chatAgentId.trim().length > 0
          ? chatAgentId.trim()
          : null;
      const normalizedSessionID =
        normalizedAgentID && typeof chatSessionId === "string" && chatSessionId.trim().length > 0
          ? chatSessionId.trim()
          : null;

      setRoute((current) => ({
        ...current,
        section: "projects",
        projectId: normalizedProjectID,
        projectTab: normalizedProjectID ? "chat" : null,
        projectTaskReference: null,
        chatProjectId: normalizedProjectID,
        chatAgentId: normalizedAgentID,
        chatSessionId: normalizedSessionID,
        agentInitialChatSessionId: null
      }));
    },
    []
  );

  return {
    route,
    setSection,
    setConfigSection,
    setProjectRoute,
    setAgentRoute,
    setSessionRoute,
    setChatsRoute
  };
}

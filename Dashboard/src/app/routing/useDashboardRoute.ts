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
  setAgentRoute: (agentId: string | null, agentTab?: string | null) => void;
  setSessionRoute: (agentId: string | null, sessionId: string | null) => void;
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
      section: nextSection
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
        projectTaskReference: normalizedTaskReference
      }));
    },
    []
  );

  const setAgentRoute = useCallback((agentId: string | null, agentTab: string | null = DEFAULT_AGENT_TAB) => {
    const normalizedAgentID = typeof agentId === "string" && agentId.trim().length > 0 ? agentId : null;
    const normalizedAgentTab = normalizedAgentID
      ? normalizeAgentTab(String(agentTab || DEFAULT_AGENT_TAB).toLowerCase())
      : null;

    setRoute((current) => ({
      ...current,
      section: "agents",
      agentId: normalizedAgentID,
      agentTab: normalizedAgentTab
    }));
  }, []);

  const setSessionRoute = useCallback((agentId: string | null, sessionId: string | null) => {
    const normalizedAgentID = typeof agentId === "string" && agentId.trim().length > 0 ? agentId : null;
    const normalizedSessionID = typeof sessionId === "string" && sessionId.trim().length > 0 ? sessionId : null;

    setRoute((current) => ({
      ...current,
      section: "sessions",
      sessionAgentId: normalizedAgentID,
      sessionId: normalizedAgentID ? normalizedSessionID : null
    }));
  }, []);

  return {
    route,
    setSection,
    setConfigSection,
    setProjectRoute,
    setAgentRoute,
    setSessionRoute
  };
}

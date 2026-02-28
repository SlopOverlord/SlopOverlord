import { useCallback, useEffect, useMemo, useState } from "react";
import {
  DEFAULT_AGENT_TAB,
  normalizeAgentTab,
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
  setAgentRoute: (agentId: string | null, agentTab?: string | null) => void;
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
  }, [route.agentId, route.agentTab, route.configSection, route.section]);

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

  return {
    route,
    setSection,
    setConfigSection,
    setAgentRoute
  };
}

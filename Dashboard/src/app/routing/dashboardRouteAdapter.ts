export const TOP_LEVEL_SECTIONS = [
  "chats",
  "projects",
  "sessions",
  "overview",
  "agents",
  "usafe",
  "nodes",
  "config",
  "logs"
] as const;

export const AGENT_TABS = ["overview", "chat", "memories", "tasks", "skills", "tools", "cron", "config"] as const;

const TOP_LEVEL_SECTION_SET = new Set<string>(TOP_LEVEL_SECTIONS);
const AGENT_TAB_SET = new Set<string>(AGENT_TABS);

export type TopLevelSection = (typeof TOP_LEVEL_SECTIONS)[number];
export type AgentTab = (typeof AGENT_TABS)[number];

export const DEFAULT_SECTION_ID: TopLevelSection = "overview";
export const DEFAULT_AGENT_TAB: AgentTab = "overview";

export interface DashboardRoute {
  section: TopLevelSection;
  configSection: string | null;
  agentId: string | null;
  agentTab: AgentTab | null;
}

function decodePathSegment(value: string) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

export function normalizeTopLevelSection(value: string): TopLevelSection {
  if (TOP_LEVEL_SECTION_SET.has(value)) {
    return value as TopLevelSection;
  }
  return DEFAULT_SECTION_ID;
}

export function normalizeAgentTab(value: string): AgentTab {
  if (AGENT_TAB_SET.has(value)) {
    return value as AgentTab;
  }
  return DEFAULT_AGENT_TAB;
}

export function parseRouteFromPath(pathname: string): DashboardRoute {
  const [sectionRaw = "", sectionArgRaw = "", sectionArg2Raw = ""] = pathname
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean);

  const section = normalizeTopLevelSection(sectionRaw);
  const sectionArg = decodePathSegment(sectionArgRaw);
  const sectionArg2 = decodePathSegment(sectionArg2Raw).toLowerCase();

  const configSection = section === "config" && sectionArg ? sectionArg : null;
  const agentId = section === "agents" && sectionArg ? sectionArg : null;
  const agentTab = section === "agents" && agentId ? normalizeAgentTab(sectionArg2) : null;

  return { section, configSection, agentId, agentTab };
}

export function buildPathFromRoute(route: DashboardRoute) {
  let nextPathname = `/${route.section}`;

  if (route.section === "config" && route.configSection) {
    nextPathname = `${nextPathname}/${encodeURIComponent(route.configSection)}`;
  }

  if (route.section === "agents") {
    nextPathname = "/agents";
    if (route.agentId) {
      nextPathname = `/agents/${encodeURIComponent(route.agentId)}`;
      if (route.agentTab && route.agentTab !== DEFAULT_AGENT_TAB) {
        nextPathname = `${nextPathname}/${route.agentTab}`;
      }
    }
  }

  return nextPathname;
}

export function pushRouteToHistory(route: DashboardRoute) {
  const nextPathname = buildPathFromRoute(route);
  if (window.location.pathname === nextPathname) {
    return;
  }
  window.history.pushState({}, "", `${nextPathname}${window.location.search}${window.location.hash}`);
}

export function subscribeToPopState(listener: () => void) {
  window.addEventListener("popstate", listener);
  return () => window.removeEventListener("popstate", listener);
}

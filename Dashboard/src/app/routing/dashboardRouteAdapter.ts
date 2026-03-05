export const TOP_LEVEL_SECTIONS = [
  "chats",
  "projects",
  "sessions",
  "overview",
  "actors",
  "agents",
  "usafe",
  "nodes",
  "config",
  "logs"
] as const;

export const AGENT_TABS = ["overview", "chat", "memories", "tasks", "skills", "tools", "channels", "cron", "config"] as const;
export const PROJECT_TABS = ["overview", "tasks", "workers", "memories", "visor", "settings"] as const;

const TOP_LEVEL_SECTION_SET = new Set<string>(TOP_LEVEL_SECTIONS);
const AGENT_TAB_SET = new Set<string>(AGENT_TABS);
const PROJECT_TAB_SET = new Set<string>(PROJECT_TABS);

export type TopLevelSection = (typeof TOP_LEVEL_SECTIONS)[number];
export type AgentTab = (typeof AGENT_TABS)[number];
export type ProjectTab = (typeof PROJECT_TABS)[number];

export const DEFAULT_SECTION_ID: TopLevelSection = "overview";
export const DEFAULT_AGENT_TAB: AgentTab = "overview";
export const DEFAULT_PROJECT_TAB: ProjectTab = "overview";

export interface DashboardRoute {
  section: TopLevelSection;
  configSection: string | null;
  projectId: string | null;
  projectTab: ProjectTab | null;
  projectTaskReference: string | null;
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

export function normalizeProjectTab(value: string): ProjectTab {
  if (PROJECT_TAB_SET.has(value)) {
    return value as ProjectTab;
  }
  return DEFAULT_PROJECT_TAB;
}

export function parseRouteFromPath(pathname: string): DashboardRoute {
  const [sectionRaw = "", sectionArgRaw = "", sectionArg2Raw = "", sectionArg3Raw = ""] = pathname
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean);

  const sectionRawDecoded = decodePathSegment(sectionRaw);
  const sectionRawLower = sectionRawDecoded.toLowerCase();
  if (sectionRawLower === "tasks") {
    return {
      section: "projects",
      configSection: null,
      projectId: null,
      projectTab: "tasks",
      projectTaskReference: decodePathSegment(sectionArgRaw) || null,
      agentId: null,
      agentTab: null
    };
  }

  const section = normalizeTopLevelSection(sectionRaw);
  const sectionArg = decodePathSegment(sectionArgRaw);
  const sectionArg2 = decodePathSegment(sectionArg2Raw);
  const sectionArg3 = decodePathSegment(sectionArg3Raw);

  const sectionArgLower = sectionArg.toLowerCase();
  const sectionArg2Lower = sectionArg2.toLowerCase();

  const isDirectProjectTaskRoute = !TOP_LEVEL_SECTION_SET.has(sectionRaw) && sectionArgLower === "tasks";

  if (isDirectProjectTaskRoute) {
    return {
      section: "projects",
      configSection: null,
      projectId: decodePathSegment(sectionRaw),
      projectTab: "tasks",
      projectTaskReference: sectionArg2 || null,
      agentId: null,
      agentTab: null
    };
  }

  const configSection = section === "config" && sectionArg ? sectionArg : null;
  const projectId = section === "projects" && sectionArg ? sectionArg : null;
  const projectTab = section === "projects" && projectId ? normalizeProjectTab(sectionArg2Lower) : null;
  const projectTaskReference = section === "projects" && projectTab === "tasks" ? sectionArg3 || null : null;
  const agentId = section === "agents" && sectionArg ? sectionArg : null;
  const agentTab = section === "agents" && agentId ? normalizeAgentTab(sectionArg2Lower) : null;

  return { section, configSection, projectId, projectTab, projectTaskReference, agentId, agentTab };
}

export function buildPathFromRoute(route: DashboardRoute) {
  let nextPathname = `/${route.section}`;

  if (route.section === "config" && route.configSection) {
    nextPathname = `${nextPathname}/${encodeURIComponent(route.configSection)}`;
  }

  if (route.section === "projects") {
    if (route.projectTab === "tasks" && route.projectTaskReference) {
      nextPathname = `/tasks/${encodeURIComponent(route.projectTaskReference)}`;
    } else if (route.projectId) {
      nextPathname = `/projects/${encodeURIComponent(route.projectId)}`;
      if (route.projectTab && route.projectTab !== DEFAULT_PROJECT_TAB) {
        nextPathname = `${nextPathname}/${route.projectTab}`;
      }
    }
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

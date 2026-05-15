import { buildPathFromRoute } from "./dashboardRouteAdapter";

export function navigateToTaskScreen(taskReference: unknown): void {
  const normalizedReference = String(taskReference ?? "").trim();
  if (!normalizedReference) {
    return;
  }
  const pathname = buildPathFromRoute({
    section: "projects",
    configSection: null,
    projectId: null,
    projectTab: "tasks",
    projectTaskReference: normalizedReference,
    agentId: null,
    agentTab: null,
    agentInitialChatSessionId: null,
    sessionAgentId: null,
    sessionId: null,
    chatProjectId: null,
    chatAgentId: null,
    chatSessionId: null
  });
  const nextPath = `${pathname}${window.location.search}${window.location.hash}`;
  if (window.location.pathname === pathname) {
    return;
  }
  window.history.pushState({}, "", nextPath);
  window.dispatchEvent(new PopStateEvent("popstate"));
}

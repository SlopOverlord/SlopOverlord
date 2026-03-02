import { buildApiURL, requestJson } from "./httpClient";

type AnyRecord = Record<string, unknown>;

interface RequestOptions {
  signal?: AbortSignal;
}

interface AgentSessionStreamHandlers {
  onUpdate?: (update: AnyRecord) => void;
  onOpen?: () => void;
  onError?: () => void;
}

export interface CoreApi {
  sendChannelMessage: (channelId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchChannelState: (channelId: string) => Promise<AnyRecord | null>;
  fetchBulletins: () => Promise<AnyRecord[]>;
  fetchWorkers: () => Promise<AnyRecord[]>;
  fetchArtifact: (id: string) => Promise<AnyRecord | null>;
  fetchRuntimeConfig: () => Promise<AnyRecord | null>;
  updateRuntimeConfig: (config: AnyRecord) => Promise<AnyRecord | null>;
  fetchSystemLogs: () => Promise<AnyRecord | null>;
  fetchOpenAIModels: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchOpenAIProviderStatus: () => Promise<AnyRecord | null>;
  fetchProjects: () => Promise<AnyRecord[] | null>;
  fetchProject: (projectId: string) => Promise<AnyRecord | null>;
  createProject: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateProject: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteProject: (projectId: string) => Promise<boolean>;
  createProjectChannel: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteProjectChannel: (projectId: string, channelId: string) => Promise<AnyRecord | null>;
  createProjectTask: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  updateProjectTask: (projectId: string, taskId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteProjectTask: (projectId: string, taskId: string) => Promise<AnyRecord | null>;
  fetchAgents: () => Promise<AnyRecord[] | null>;
  fetchAgent: (agentId: string) => Promise<AnyRecord | null>;
  fetchAgentTasks: (agentId: string) => Promise<AnyRecord[] | null>;
  createAgent: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchActorsBoard: () => Promise<AnyRecord | null>;
  updateActorsBoard: (payload: AnyRecord) => Promise<AnyRecord | null>;
  resolveActorRoute: (payload: AnyRecord) => Promise<AnyRecord | null>;
  createActorNode: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateActorNode: (actorId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteActorNode: (actorId: string) => Promise<AnyRecord | null>;
  createActorLink: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateActorLink: (linkId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteActorLink: (linkId: string) => Promise<AnyRecord | null>;
  createActorTeam: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateActorTeam: (teamId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteActorTeam: (teamId: string) => Promise<AnyRecord | null>;
  fetchAgentSessions: (agentId: string) => Promise<AnyRecord[] | null>;
  createAgentSession: (agentId: string, payload?: AnyRecord) => Promise<AnyRecord | null>;
  fetchAgentSession: (agentId: string, sessionId: string) => Promise<AnyRecord | null>;
  postAgentSessionMessage: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  postAgentSessionControl: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  subscribeAgentSessionStream: (
    agentId: string,
    sessionId: string,
    handlers?: AgentSessionStreamHandlers
  ) => () => void;
  deleteAgentSession: (agentId: string, sessionId: string) => Promise<boolean>;
  fetchAgentConfig: (agentId: string) => Promise<AnyRecord | null>;
  updateAgentConfig: (agentId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchAgentToolsCatalog: (agentId: string) => Promise<AnyRecord[] | null>;
  fetchAgentToolsPolicy: (agentId: string) => Promise<AnyRecord | null>;
  updateAgentToolsPolicy: (agentId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  invokeAgentTool: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  fetchSkillsRegistry: (search?: string, sort?: string, limit?: number, offset?: number) => Promise<AnyRecord | null>;
  fetchAgentSkills: (agentId: string) => Promise<AnyRecord | null>;
  installAgentSkill: (agentId: string, owner: string, repo: string) => Promise<AnyRecord | null>;
  uninstallAgentSkill: (agentId: string, skillId: string) => Promise<boolean>;
}

export function createCoreApi(): CoreApi {
  return {
    sendChannelMessage: async (channelId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/messages`,
        method: "POST",
        body: payload
      });
      return response.data;
    },

    fetchChannelState: async (channelId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/state`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchBulletins: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/bulletins"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    fetchWorkers: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/workers"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    fetchArtifact: async (id) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/artifacts/${encodeURIComponent(id)}/content`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchRuntimeConfig: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/config"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateRuntimeConfig: async (config) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/config",
        method: "PUT",
        body: config
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchSystemLogs: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/logs"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchOpenAIModels: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/openai/models",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchOpenAIProviderStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/openai/status"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchProjects: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/projects"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchProject: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createProject: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/projects",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateProject: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteProject: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    createProjectChannel: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/channels`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteProjectChannel: async (projectId, channelId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/channels/${encodeURIComponent(channelId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createProjectTask: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateProjectTask: async (projectId, taskId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteProjectTask: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgents: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/agents"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchAgent: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentTasks: async (agentId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tasks`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    createAgent: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/agents",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchActorsBoard: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/actors/board"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorsBoard: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/board",
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    resolveActorRoute: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/route",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createActorNode: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/nodes",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorNode: async (actorId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/actors/nodes/${encodeURIComponent(actorId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteActorNode: async (actorId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/actors/nodes/${encodeURIComponent(actorId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createActorLink: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/links",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorLink: async (linkId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/actors/links/${encodeURIComponent(linkId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteActorLink: async (linkId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/actors/links/${encodeURIComponent(linkId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createActorTeam: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/teams",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorTeam: async (teamId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/actors/teams/${encodeURIComponent(teamId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteActorTeam: async (teamId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/actors/teams/${encodeURIComponent(teamId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentSessions: async (agentId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    createAgentSession: async (agentId, payload = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentSession: async (agentId, sessionId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    postAgentSessionMessage: async (agentId, sessionId, payload, options = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/messages`,
        method: "POST",
        body: payload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    postAgentSessionControl: async (agentId, sessionId, payload, options = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/control`,
        method: "POST",
        body: payload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    subscribeAgentSessionStream: (agentId, sessionId, handlers = {}) => {
      const source = new EventSource(
        buildApiURL(`/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/stream`)
      );

      const eventNames = ["session_ready", "session_event", "heartbeat", "session_closed", "session_error"];
      const onMessage = (event: MessageEvent) => {
        if (!event?.data || typeof handlers.onUpdate !== "function") {
          return;
        }

        try {
          const payload = JSON.parse(event.data);
          if (payload && typeof payload === "object") {
            handlers.onUpdate(payload as AnyRecord);
          }
        } catch {
          // Ignore malformed stream chunks and keep connection alive.
        }
      };

      for (const eventName of eventNames) {
        source.addEventListener(eventName, onMessage as EventListener);
      }

      source.onopen = () => {
        handlers.onOpen?.();
      };

      source.onerror = () => {
        handlers.onError?.();
      };

      return () => {
        for (const eventName of eventNames) {
          source.removeEventListener(eventName, onMessage as EventListener);
        }
        source.close();
      };
    },

    deleteAgentSession: async (agentId, sessionId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchAgentConfig: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/config`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateAgentConfig: async (agentId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/config`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentToolsCatalog: async (agentId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tools/catalog`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchAgentToolsPolicy: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tools`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateAgentToolsPolicy: async (agentId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tools`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    invokeAgentTool: async (agentId, sessionId, payload, options = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/tools/invoke`,
        method: "POST",
        body: payload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchSkillsRegistry: async (search, sort = "installs", limit = 20, offset = 0) => {
      const params = new URLSearchParams();
      if (search) params.append("search", search);
      params.append("sort", sort);
      params.append("limit", String(limit));
      params.append("offset", String(offset));
      const path = `/v1/skills/registry?${params.toString()}`;
      console.debug("[skills.registry] request:", { search: search ?? null, sort, limit, offset, path });
      const response = await requestJson<AnyRecord>({
        path
      });
      if (!response.ok) {
        console.debug("[skills.registry] response: ok=false", response);
        return null;
      }
      console.debug("[skills.registry] response:", {
        ok: true,
        total: response.data?.total,
        skillsCount: Array.isArray(response.data?.skills) ? (response.data?.skills as unknown[]).length : 0,
        data: response.data
      });
      return response.data;
    },

    fetchAgentSkills: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/skills`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    installAgentSkill: async (agentId, owner, repo) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/skills`,
        method: "POST",
        body: { owner, repo }
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    uninstallAgentSkill: async (agentId, skillId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/skills/${encodeURIComponent(skillId)}`,
        method: "DELETE"
      });
      return response.ok;
    }
  };
}

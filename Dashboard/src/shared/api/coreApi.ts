import { requestJson } from "./httpClient";

type AnyRecord = Record<string, unknown>;

interface RequestOptions {
  signal?: AbortSignal;
}

export interface CoreApi {
  sendChannelMessage: (channelId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchChannelState: (channelId: string) => Promise<AnyRecord | null>;
  fetchBulletins: () => Promise<AnyRecord[]>;
  fetchWorkers: () => Promise<AnyRecord[]>;
  fetchArtifact: (id: string) => Promise<AnyRecord | null>;
  fetchRuntimeConfig: () => Promise<AnyRecord | null>;
  updateRuntimeConfig: (config: AnyRecord) => Promise<AnyRecord | null>;
  fetchOpenAIModels: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchOpenAIProviderStatus: () => Promise<AnyRecord | null>;
  fetchAgents: () => Promise<AnyRecord[] | null>;
  fetchAgent: (agentId: string) => Promise<AnyRecord | null>;
  createAgent: (payload: AnyRecord) => Promise<AnyRecord | null>;
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
  deleteAgentSession: (agentId: string, sessionId: string) => Promise<boolean>;
  fetchAgentConfig: (agentId: string) => Promise<AnyRecord | null>;
  updateAgentConfig: (agentId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
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
    }
  };
}

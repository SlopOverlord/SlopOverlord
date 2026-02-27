const API_BASE = window.__SLOPOVERLORD_CONFIG__?.apiBase || "http://localhost:25101";

export async function sendChannelMessage(channelId, payload) {
  const response = await fetch(`${API_BASE}/v1/channels/${channelId}/messages`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
  return response.json();
}

export async function fetchChannelState(channelId) {
  const response = await fetch(`${API_BASE}/v1/channels/${channelId}/state`);
  if (!response.ok) return null;
  return response.json();
}

export async function fetchBulletins() {
  const response = await fetch(`${API_BASE}/v1/bulletins`);
  if (!response.ok) return [];
  return response.json();
}

export async function fetchWorkers() {
  const response = await fetch(`${API_BASE}/v1/workers`);
  if (!response.ok) return [];
  return response.json();
}

export async function fetchArtifact(id) {
  const response = await fetch(`${API_BASE}/v1/artifacts/${id}/content`);
  if (!response.ok) return null;
  return response.json();
}

export async function fetchRuntimeConfig() {
  const response = await fetch(`${API_BASE}/v1/config`);
  if (!response.ok) return null;
  return response.json();
}

export async function updateRuntimeConfig(config) {
  const response = await fetch(`${API_BASE}/v1/config`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(config)
  });

  if (!response.ok) {
    return null;
  }

  return response.json();
}

export async function fetchOpenAIModels(payload) {
  const response = await fetch(`${API_BASE}/v1/providers/openai/models`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    return null;
  }

  return response.json();
}

export async function fetchAgents() {
  const response = await fetch(`${API_BASE}/v1/agents`);
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function fetchAgent(agentId) {
  const response = await fetch(`${API_BASE}/v1/agents/${encodeURIComponent(agentId)}`);
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function createAgent(payload) {
  const response = await fetch(`${API_BASE}/v1/agents`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    return null;
  }

  return response.json();
}

export async function fetchAgentSessions(agentId) {
  const response = await fetch(`${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/sessions`);
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function createAgentSession(agentId, payload = {}) {
  const response = await fetch(`${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function fetchAgentSession(agentId, sessionId) {
  const response = await fetch(
    `${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}`
  );
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function postAgentSessionMessage(agentId, sessionId, payload) {
  const response = await fetch(
    `${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/messages`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload)
    }
  );
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function postAgentSessionControl(agentId, sessionId, payload) {
  const response = await fetch(
    `${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/control`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload)
    }
  );
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function deleteAgentSession(agentId, sessionId) {
  const response = await fetch(
    `${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}`,
    { method: "DELETE" }
  );
  if (!response.ok) {
    return false;
  }
  return true;
}

export async function fetchAgentConfig(agentId) {
  const response = await fetch(`${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/config`);
  if (!response.ok) {
    return null;
  }
  return response.json();
}

export async function updateAgentConfig(agentId, payload) {
  const response = await fetch(`${API_BASE}/v1/agents/${encodeURIComponent(agentId)}/config`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!response.ok) {
    return null;
  }
  return response.json();
}

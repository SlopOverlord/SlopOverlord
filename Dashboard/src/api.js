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

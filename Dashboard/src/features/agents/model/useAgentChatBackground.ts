import { useEffect, useRef } from "react";
import { fetchAgentSessions, subscribeAgentSessionStream } from "../../../api";
import { emitNotification } from "../../notifications/notificationBus";

function sortSessionsByUpdate<T extends Record<string, unknown>>(list: T[]): T[] {
  return [...list].sort((a, b) => {
    const aDate = new Date(String(a.updatedAt ?? 0)).getTime();
    const bDate = new Date(String(b.updatedAt ?? 0)).getTime();
    return bDate - aDate;
  });
}

function isUserCreatedSession(session: Record<string, unknown>): boolean {
  const title = String(session?.title ?? "").trim();
  return !title.startsWith("task-comment:");
}

function previewText(value: string, limit = 80): string {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim();
  if (!normalized) return "";
  return normalized.length > limit ? `${normalized.slice(0, limit)}...` : normalized;
}

function extractAssistantText(streamEvent: Record<string, unknown>): string | null {
  if (streamEvent.type !== "message") return null;
  const message = streamEvent.message as Record<string, unknown> | undefined;
  if (!message || message.role !== "assistant") return null;
  const segments = Array.isArray(message.segments) ? message.segments : [];
  const text = segments
    .filter((s: Record<string, unknown>) => s.kind === "text" && typeof s.text === "string")
    .map((s: Record<string, unknown>) => String(s.text))
    .join(" ")
    .trim();
  return text || null;
}

export function useAgentChatBackground(agentId: string, enabled: boolean): void {
  const enabledRef = useRef(enabled);
  const agentIdRef = useRef(agentId);
  const cleanupRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    enabledRef.current = enabled;
    agentIdRef.current = agentId;
  });

  useEffect(() => {
    if (!enabled || !agentId) {
      cleanupRef.current?.();
      cleanupRef.current = null;
      return;
    }

    let disposed = false;
    let streamCleanup: (() => void) | null = null;

    async function connectToLatestSession() {
      const sessions = await fetchAgentSessions(agentId, { limit: 1 });
      if (disposed || !Array.isArray(sessions)) return;

      const userSessions = sortSessionsByUpdate(
        sessions.filter(isUserCreatedSession) as Record<string, unknown>[]
      );

      if (userSessions.length === 0) return;

      const latestSessionId = String(userSessions[0].id ?? "").trim();
      if (!latestSessionId) return;

      if (streamCleanup) {
        streamCleanup();
        streamCleanup = null;
      }

      if (disposed) return;

      streamCleanup = subscribeAgentSessionStream(agentId, latestSessionId, {
        onUpdate: (update) => {
          if (!enabledRef.current || agentIdRef.current !== agentId) return;
          if (!update || typeof update !== "object") return;

          const streamEvent = update.event as Record<string, unknown> | undefined;
          if (!streamEvent) return;

          const text = extractAssistantText(streamEvent);
          if (!text) return;

          const preview = previewText(text);
          if (!preview) return;

          emitNotification("confirmation", agentId, preview, { agentId });
        }
      });
    }

    connectToLatestSession().catch(() => {});

    cleanupRef.current = () => {
      disposed = true;
      streamCleanup?.();
      streamCleanup = null;
    };

    return () => {
      disposed = true;
      streamCleanup?.();
      streamCleanup = null;
      cleanupRef.current = null;
    };
  }, [agentId, enabled]);
}

import { useEffect, useRef } from "react";
import { buildWebSocketURL } from "../../shared/api/httpClient";
import { useNotifications } from "./NotificationContext";
import type { NotificationType } from "./NotificationContext";

interface ServerNotification {
  id: string;
  type: string;
  title: string;
  message: string;
  timestamp: string;
  metadata?: Record<string, string>;
}

const RECONNECT_DELAY_MS = 3000;
const VALID_TYPES: NotificationType[] = ["confirmation", "agent_error", "system_error", "pending_approval"];

function mapServerType(raw: string): NotificationType {
  if (VALID_TYPES.includes(raw as NotificationType)) return raw as NotificationType;
  return "system_error";
}

export function useNotificationSocket() {
  const { push } = useNotifications();
  const pushRef = useRef(push);
  pushRef.current = push;

  useEffect(() => {
    let socket: WebSocket | null = null;
    let reconnectTimer: number | null = null;
    let disposed = false;

    function connect() {
      if (disposed) return;

      const url = buildWebSocketURL("/v1/notifications/ws");
      socket = new WebSocket(url);

      socket.onmessage = (event) => {
        if (!event?.data) return;
        try {
          const payload = JSON.parse(String(event.data)) as ServerNotification;
          if (payload && typeof payload.title === "string") {
            const metadata = payload.metadata && typeof payload.metadata === "object" ? payload.metadata : undefined;
            pushRef.current(mapServerType(payload.type), payload.title, payload.message || "", metadata);
          }
        } catch {
          // ignore malformed
        }
      };

      socket.onclose = () => {
        socket = null;
        if (disposed) return;
        reconnectTimer = window.setTimeout(() => {
          reconnectTimer = null;
          connect();
        }, RECONNECT_DELAY_MS);
      };

      socket.onerror = () => {
        socket?.close();
      };
    }

    connect();

    return () => {
      disposed = true;
      if (reconnectTimer != null) {
        window.clearTimeout(reconnectTimer);
      }
      if (socket) {
        socket.close();
        socket = null;
      }
    };
  }, []);
}

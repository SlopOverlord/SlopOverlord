import type { NotificationType } from "./NotificationContext";

export interface NotificationEvent {
  type: NotificationType;
  title: string;
  message: string;
  metadata?: Record<string, string>;
}

type Listener = (event: NotificationEvent) => void;

const listeners = new Set<Listener>();

export function subscribeNotificationBus(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function emitNotification(type: NotificationType, title: string, message: string, metadata?: Record<string, string>) {
  for (const listener of listeners) {
    listener({ type, title, message, metadata });
  }
}

import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { subscribeNotificationBus } from "./notificationBus";

export type NotificationType = "confirmation" | "agent_error" | "system_error" | "pending_approval";

export interface Notification {
  id: string;
  type: NotificationType;
  title: string;
  message: string;
  timestamp: number;
  read: boolean;
  metadata?: Record<string, string>;
}

interface NotificationContextValue {
  notifications: Notification[];
  unreadCount: number;
  push: (type: NotificationType, title: string, message: string, metadata?: Record<string, string>) => void;
  markRead: (id: string) => void;
  markAllRead: () => void;
  dismiss: (id: string) => void;
  clearAll: () => void;
}

const NotificationContext = createContext<NotificationContextValue | null>(null);

let nextId = 1;

export function NotificationProvider({ children }: { children: React.ReactNode }) {
  const [notifications, setNotifications] = useState<Notification[]>([]);

  const push = useCallback((type: NotificationType, title: string, message: string, metadata?: Record<string, string>) => {
    const notification: Notification = {
      id: `notif-${nextId++}-${Date.now()}`,
      type,
      title,
      message,
      timestamp: Date.now(),
      read: false,
      metadata
    };
    setNotifications((prev) => [notification, ...prev]);
  }, []);

  const markRead = useCallback((id: string) => {
    setNotifications((prev) => prev.map((n) => (n.id === id ? { ...n, read: true } : n)));
  }, []);

  const markAllRead = useCallback(() => {
    setNotifications((prev) => prev.map((n) => (n.read ? n : { ...n, read: true })));
  }, []);

  const dismiss = useCallback((id: string) => {
    setNotifications((prev) => prev.filter((n) => n.id !== id));
  }, []);

  const clearAll = useCallback(() => {
    setNotifications([]);
  }, []);

  const unreadCount = useMemo(() => notifications.filter((n) => !n.read).length, [notifications]);

  const value = useMemo<NotificationContextValue>(
    () => ({ notifications, unreadCount, push, markRead, markAllRead, dismiss, clearAll }),
    [notifications, unreadCount, push, markRead, markAllRead, dismiss, clearAll]
  );

  useEffect(() => {
    return subscribeNotificationBus((event) => {
      push(event.type, event.title, event.message, event.metadata);
    });
  }, [push]);

  return <NotificationContext.Provider value={value}>{children}</NotificationContext.Provider>;
}

export function useNotifications() {
  const ctx = useContext(NotificationContext);
  if (!ctx) {
    throw new Error("useNotifications must be used within NotificationProvider");
  }
  return ctx;
}

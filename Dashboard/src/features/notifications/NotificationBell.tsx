import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useNotifications } from "./NotificationContext";
import type { Notification, NotificationType } from "./NotificationContext";
import { ApprovalDialog } from "../config/components/ApprovalDialog";
import { ToolApprovalDialog } from "./ToolApprovalDialog";

const TYPE_META: Record<NotificationType, { icon: string; color: string; label: string }> = {
  confirmation: { icon: "help_outline", color: "var(--warn)", label: "CONFIRM" },
  agent_error: { icon: "error_outline", color: "var(--danger)", label: "AGENT" },
  system_error: { icon: "warning", color: "var(--danger)", label: "SYSTEM" },
  pending_approval: { icon: "person_add", color: "var(--accent)", label: "APPROVAL" },
  tool_approval: { icon: "approval", color: "var(--warn)", label: "TOOL" },
  task_completed: { icon: "task_alt", color: "var(--success)", label: "DONE" },
  input_required: { icon: "front_hand", color: "var(--warn)", label: "INPUT" },
  cron_attention: { icon: "schedule", color: "var(--accent)", label: "CRON" }
};

function formatTime(ts: number): string {
  const diff = Math.floor((Date.now() - ts) / 1000);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return new Date(ts).toLocaleDateString();
}

function sessionIdFromChannelId(channelId?: string): string | undefined {
  const raw = channelId || "";
  const sessionMarker = ":session:";
  const sessionIdx = raw.indexOf(sessionMarker);
  return sessionIdx >= 0 ? raw.slice(sessionIdx + sessionMarker.length) : undefined;
}

function NotificationItem({
  notification,
  onDismiss,
  onRead,
  onApprovalClick,
  onNavigateToAgent
}: {
  notification: Notification;
  onDismiss: (id: string) => void;
  onRead: (id: string) => void;
  onApprovalClick?: (approvalId: string) => void;
  onNavigateToAgent?: (agentId: string, sessionId?: string) => void;
}) {
  const meta = TYPE_META[notification.type];

  const hasAgentLink = Boolean(notification.metadata?.agentId);

  function handleClick() {
    onRead(notification.id);
    if (notification.type === "pending_approval" && notification.metadata?.approvalId) {
      onApprovalClick?.(notification.metadata.approvalId);
      return;
    }
    if (notification.type === "tool_approval" && notification.metadata?.approvalId) {
      onApprovalClick?.(notification.metadata.approvalId);
      return;
    }
    if (notification.metadata?.agentId && onNavigateToAgent) {
      const sessionId = notification.metadata.sessionId || sessionIdFromChannelId(notification.metadata.channelId);
      onNavigateToAgent(notification.metadata.agentId, sessionId);
    }
  }

  function handleNavigate(e: React.MouseEvent) {
    e.stopPropagation();
    onRead(notification.id);
    const agentId = notification.metadata?.agentId;
    if (!agentId || !onNavigateToAgent) return;
    const sessionId = notification.metadata?.sessionId || sessionIdFromChannelId(notification.metadata?.channelId);
    onNavigateToAgent(agentId, sessionId);
  }

  return (
    <div
      className={`notif-item ${notification.read ? "notif-read" : ""}`}
      onClick={handleClick}
    >
      <span className="material-symbols-rounded notif-item-icon" style={{ color: meta.color }}>
        {meta.icon}
      </span>
      <div className="notif-item-body">
        <div className="notif-item-header">
          <span className="notif-item-tag" style={{ color: meta.color }}>
            [{meta.label}]
          </span>
          <span className="notif-item-time">{formatTime(notification.timestamp)}</span>
        </div>
        <div className="notif-item-title">{notification.title}</div>
        {notification.message && <div className="notif-item-message">{notification.message}</div>}
        {hasAgentLink && onNavigateToAgent && (
          <button type="button" className="notif-item-navigate" onClick={handleNavigate}>
            <span className="material-symbols-rounded">open_in_new</span>
            View session
          </button>
        )}
      </div>
      <button
        type="button"
        className="notif-item-dismiss"
        onClick={(e) => {
          e.stopPropagation();
          onDismiss(notification.id);
        }}
        aria-label="Dismiss notification"
      >
        <span className="material-symbols-rounded">close</span>
      </button>
    </div>
  );
}

export function NotificationBell({
  isCompact = false,
  onNavigateToAgent
}: {
  isCompact?: boolean;
  onNavigateToAgent?: (agentId: string, sessionId?: string) => void;
}) {
  const { notifications, unreadCount, markRead, markAllRead, dismiss, clearAll } = useNotifications();
  const [open, setOpen] = useState(false);
  const [approvalId, setApprovalId] = useState<string | null>(null);
  const [toolApprovalId, setToolApprovalId] = useState<string | null>(null);
  const [browserPermission, setBrowserPermission] = useState<NotificationPermission | "unsupported">(() => {
    if (!("Notification" in window)) return "unsupported";
    return window.Notification.permission;
  });
  const containerRef = useRef<HTMLDivElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);

  const toggle = useCallback(() => setOpen((v) => !v), []);

  useEffect(() => {
    if (!open) return;
    if ("Notification" in window) {
      setBrowserPermission(window.Notification.permission);
    }
    function handleClickOutside(e: MouseEvent) {
      if (
        containerRef.current && !containerRef.current.contains(e.target as Node) &&
        dropdownRef.current && !dropdownRef.current.contains(e.target as Node)
      ) {
        setOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [open]);

  const requestBrowserPermission = useCallback(async () => {
    if (!("Notification" in window)) {
      setBrowserPermission("unsupported");
      return;
    }
    const nextPermission = await window.Notification.requestPermission();
    setBrowserPermission(nextPermission);
  }, []);

  const browserPermissionLabel = (() => {
    switch (browserPermission) {
      case "granted":
        return "BROWSER ON";
      case "denied":
        return "BROWSER BLOCKED";
      case "default":
        return "ENABLE BROWSER";
      case "unsupported":
        return "BROWSER N/A";
      default:
        return "BROWSER N/A";
    }
  })();

  useLayoutEffect(() => {
    if (!open || !containerRef.current || !dropdownRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    const dropdown = dropdownRef.current;
    dropdown.style.left = `${rect.right + 8}px`;
    dropdown.style.bottom = `${window.innerHeight - rect.bottom}px`;
  }, [open]);

  return (
    <div className="notif-bell-container" ref={containerRef}>
      <button type="button" className="notif-bell-button" onClick={toggle} aria-label="Notifications" title="Notifications">
        <span className="material-symbols-rounded">notifications</span>
        {unreadCount > 0 && <span className="notif-bell-badge">{unreadCount > 99 ? "99+" : unreadCount}</span>}
        {!isCompact && <span className="notif-bell-label">ALERTS</span>}
      </button>

      {open && (
        <div className="notif-dropdown" ref={dropdownRef}>
          <div className="notif-dropdown-header">
            <span className="notif-dropdown-title">[NOTIFICATIONS]</span>
            <div className="notif-dropdown-actions">
              <button
                type="button"
                className="notif-dropdown-action"
                onClick={requestBrowserPermission}
                disabled={browserPermission === "granted" || browserPermission === "denied" || browserPermission === "unsupported"}
                title={
                  browserPermission === "granted"
                    ? "Browser notifications are enabled"
                    : browserPermission === "denied"
                      ? "Browser notification permission is blocked in this browser"
                      : browserPermission === "unsupported"
                        ? "Browser notifications are not supported in this context"
                        : "Enable browser notifications"
                }
              >
                {browserPermissionLabel}
              </button>
              {unreadCount > 0 && (
                <button type="button" className="notif-dropdown-action" onClick={markAllRead}>
                  READ ALL
                </button>
              )}
              {notifications.length > 0 && (
                <button type="button" className="notif-dropdown-action" onClick={clearAll}>
                  CLEAR
                </button>
              )}
            </div>
          </div>

          <div className="notif-dropdown-list">
            {notifications.length === 0 ? (
              <div className="notif-dropdown-empty">NO NOTIFICATIONS</div>
            ) : (
              notifications.map((n) => (
                <NotificationItem
                  key={n.id}
                  notification={n}
                  onDismiss={dismiss}
                  onRead={markRead}
                  onApprovalClick={(id) => {
                    setOpen(false);
                    if (n.type === "tool_approval") {
                      setToolApprovalId(id);
                    } else {
                      setApprovalId(id);
                    }
                  }}
                  onNavigateToAgent={onNavigateToAgent ? (agentId, sessionId) => { setOpen(false); onNavigateToAgent(agentId, sessionId); } : undefined}
                />
              ))
            )}
          </div>
        </div>
      )}

      {approvalId && (
        <ApprovalDialog
          approvalId={approvalId}
          onClose={() => setApprovalId(null)}
        />
      )}

      {toolApprovalId && (
        <ToolApprovalDialog
          approvalId={toolApprovalId}
          onClose={() => setToolApprovalId(null)}
          onNavigateToAgent={onNavigateToAgent}
        />
      )}
    </div>
  );
}

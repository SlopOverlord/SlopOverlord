import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useNotifications } from "./NotificationContext";
import type { Notification, NotificationType } from "./NotificationContext";
import { ApprovalDialog } from "../config/components/ApprovalDialog";

const TYPE_META: Record<NotificationType, { icon: string; color: string; label: string }> = {
  confirmation: { icon: "help_outline", color: "var(--warn)", label: "CONFIRM" },
  agent_error: { icon: "error_outline", color: "var(--danger)", label: "AGENT" },
  system_error: { icon: "warning", color: "var(--danger)", label: "SYSTEM" },
  pending_approval: { icon: "person_add", color: "var(--accent)", label: "APPROVAL" }
};

function formatTime(ts: number): string {
  const diff = Math.floor((Date.now() - ts) / 1000);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return new Date(ts).toLocaleDateString();
}

function NotificationItem({
  notification,
  onDismiss,
  onRead,
  onApprovalClick
}: {
  notification: Notification;
  onDismiss: (id: string) => void;
  onRead: (id: string) => void;
  onApprovalClick?: (approvalId: string) => void;
}) {
  const meta = TYPE_META[notification.type];

  function handleClick() {
    onRead(notification.id);
    if (notification.type === "pending_approval" && notification.metadata?.approvalId) {
      onApprovalClick?.(notification.metadata.approvalId);
    }
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

export function NotificationBell({ isCompact = false }: { isCompact?: boolean }) {
  const { notifications, unreadCount, markRead, markAllRead, dismiss, clearAll } = useNotifications();
  const [open, setOpen] = useState(false);
  const [approvalId, setApprovalId] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);

  const toggle = useCallback(() => setOpen((v) => !v), []);

  useEffect(() => {
    if (!open) return;
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
                  onApprovalClick={(id) => { setOpen(false); setApprovalId(id); }}
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
    </div>
  );
}

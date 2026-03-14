import React, { useCallback, useEffect, useState } from "react";
import { blockPendingApproval, fetchPendingApprovals, rejectPendingApproval } from "../../../api";
import { ApprovalDialog } from "./ApprovalDialog";

interface PendingApproval {
  id: string;
  platform: string;
  platformUserId: string;
  displayName: string;
  chatId: string;
  channelId?: string;
  code: string;
  createdAt: string;
}

function timeAgo(iso: string): string {
  const diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return new Date(iso).toLocaleDateString();
}

interface PendingApprovalListProps {
  platform: "telegram" | "discord";
}

export function PendingApprovalList({ platform }: PendingApprovalListProps) {
  const [entries, setEntries] = useState<PendingApproval[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    const list = await fetchPendingApprovals(platform);
    setLoading(false);
    if (Array.isArray(list)) {
      setEntries(list as unknown as PendingApproval[]);
    }
  }, [platform]);

  useEffect(() => {
    load().catch(() => {});
  }, [load]);

  async function handleReject(id: string) {
    await rejectPendingApproval(id);
    setEntries((prev) => prev.filter((e) => e.id !== id));
  }

  async function handleBlock(id: string) {
    await blockPendingApproval(id);
    setEntries((prev) => prev.filter((e) => e.id !== id));
  }

  if (!loading && entries.length === 0) {
    return null;
  }

  return (
    <div className="tg-section">
      <div className="tg-section-head">
        <span className="tg-section-title">Pending Approvals</span>
        <button type="button" className="tg-add-btn" onClick={() => load().catch(() => {})}>
          Refresh
        </button>
      </div>

      {loading && entries.length === 0 && (
        <p className="tg-empty" style={{ color: "var(--text-muted)" }}>Loading...</p>
      )}

      {entries.map((entry) => (
        <div key={entry.id} className="tg-binding-row">
          <div className="tg-binding-info">
            <span className="tg-binding-name">{entry.displayName}</span>
            <span className="tg-binding-desc">
              ID: {entry.platformUserId}
              {entry.channelId && ` · channel: ${entry.channelId}`}
              {` · ${timeAgo(entry.createdAt)}`}
            </span>
          </div>
          <div className="tg-binding-actions">
            <button type="button" onClick={() => setSelectedId(entry.id)}>
              Approve
            </button>
            <button
              type="button"
              onClick={() => handleReject(entry.id)}
              style={{ color: "var(--text-muted)" }}
            >
              Reject
            </button>
            <button
              type="button"
              onClick={() => handleBlock(entry.id)}
              style={{ color: "var(--danger)" }}
            >
              Block
            </button>
          </div>
        </div>
      ))}

      {selectedId && (
        <ApprovalDialog
          approvalId={selectedId}
          onClose={() => setSelectedId(null)}
          onApproved={() => {
            setEntries((prev) => prev.filter((e) => e.id !== selectedId));
            setSelectedId(null);
          }}
        />
      )}
    </div>
  );
}

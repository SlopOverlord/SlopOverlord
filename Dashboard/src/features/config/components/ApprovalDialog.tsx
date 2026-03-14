import React, { useEffect, useRef, useState } from "react";
import {
  approvePendingApproval,
  blockPendingApproval,
  fetchPendingApprovals,
  rejectPendingApproval
} from "../../../api";

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

interface ApprovalDialogProps {
  approvalId: string;
  onClose: () => void;
  onApproved?: () => void;
}

export function ApprovalDialog({ approvalId, onClose, onApproved }: ApprovalDialogProps) {
  const [entry, setEntry] = useState<PendingApproval | null>(null);
  const [loading, setLoading] = useState(true);
  const [code, setCode] = useState("");
  const [status, setStatus] = useState("");
  const [working, setWorking] = useState(false);
  const codeRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const list = await fetchPendingApprovals();
      if (cancelled) return;
      if (Array.isArray(list)) {
        const found = (list as unknown as PendingApproval[]).find((a) => a.id === approvalId);
        setEntry(found ?? null);
      }
      setLoading(false);
    }
    load().catch(() => setLoading(false));
    return () => { cancelled = true; };
  }, [approvalId]);

  useEffect(() => {
    if (!loading && entry) {
      codeRef.current?.focus();
    }
  }, [loading, entry]);

  async function handleApprove() {
    if (!code.trim()) {
      setStatus("Enter the verification code.");
      return;
    }
    setWorking(true);
    setStatus("");
    const ok = await approvePendingApproval(approvalId, code.trim());
    setWorking(false);
    if (ok) {
      setStatus("Approved.");
      onApproved?.();
      setTimeout(onClose, 800);
    } else {
      setStatus("Invalid code or request not found.");
    }
  }

  async function handleReject() {
    setWorking(true);
    await rejectPendingApproval(approvalId);
    setWorking(false);
    onClose();
  }

  async function handleBlock() {
    setWorking(true);
    await blockPendingApproval(approvalId);
    setWorking(false);
    onClose();
  }

  return (
    <div className="tg-modal-overlay" onClick={onClose}>
      <div className="tg-modal" onClick={(e) => e.stopPropagation()}>
        <div className="tg-modal-header">
          <h3>Access Request</h3>
          <button type="button" className="tg-modal-close" onClick={onClose}>
            <span className="material-symbols-rounded">close</span>
          </button>
        </div>

        <div className="tg-modal-body">
          {loading && <p style={{ margin: 0, color: "var(--text-muted)" }}>Loading...</p>}

          {!loading && !entry && (
            <p style={{ margin: 0, color: "var(--text-muted)" }}>Request not found or already resolved.</p>
          )}

          {!loading && entry && (
            <>
              <div className="tg-modal-field">
                <span className="tg-modal-field-label">Platform</span>
                <span style={{ fontSize: "0.9rem", textTransform: "capitalize" }}>{entry.platform}</span>
              </div>

              <div className="tg-modal-field">
                <span className="tg-modal-field-label">User</span>
                <span style={{ fontSize: "0.9rem" }}>
                  {entry.displayName}
                  <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>({entry.platformUserId})</span>
                </span>
              </div>

              {entry.channelId && (
                <div className="tg-modal-field">
                  <span className="tg-modal-field-label">Channel</span>
                  <span style={{ fontSize: "0.9rem", color: "var(--text-muted)" }}>{entry.channelId}</span>
                </div>
              )}

              <div className="tg-modal-field">
                <span className="tg-modal-field-label">Chat ID</span>
                <span style={{ fontSize: "0.9rem", color: "var(--text-muted)" }}>{entry.chatId}</span>
              </div>

              <div className="tg-modal-field">
                <span className="tg-modal-field-label">Verification Code</span>
                <input
                  ref={codeRef}
                  value={code}
                  onChange={(e) => setCode(e.target.value.toUpperCase())}
                  placeholder="Enter code from user"
                  maxLength={8}
                  style={{ letterSpacing: "0.15em", fontFamily: "monospace" }}
                  onKeyDown={(e) => { if (e.key === "Enter") handleApprove(); }}
                />
                {status && (
                  <span style={{ fontSize: "0.82rem", color: status === "Approved." ? "var(--accent)" : "var(--danger)", marginTop: 4 }}>
                    {status}
                  </span>
                )}
              </div>
            </>
          )}
        </div>

        {!loading && entry && (
          <div className="tg-modal-actions">
            <button
              type="button"
              className="tg-modal-cancel danger hover-levitate"
              onClick={handleBlock}
              disabled={working}
              style={{ marginLeft: 4 }}
            >
              Block
            </button>
            <button
              type="button"
              className="tg-modal-cancel hover-levitate"
              onClick={handleReject}
              disabled={working}
              style={{ color: "var(--text-muted)" }}
            >
              Reject
            </button>
            <button
              type="button"
              className="tg-modal-submit hover-levitate"
              onClick={handleApprove}
              disabled={working || !code.trim()}
            >
              Approve
            </button>
          </div>
        )}

        {!loading && !entry && (
          <div className="tg-modal-actions">
            <button type="button" className="tg-modal-cancel" onClick={onClose}>
              Close
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

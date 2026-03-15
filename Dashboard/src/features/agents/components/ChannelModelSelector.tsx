import React, { useCallback, useEffect, useState } from "react";
import { clearChannelModel, fetchChannelModel, updateChannelModel } from "../../../api";

export function ChannelModelSelector({ channelId }) {
  const [modelData, setModelData] = useState(null);
  const [isSaving, setIsSaving] = useState(false);
  const [isExpanded, setIsExpanded] = useState(false);

  const load = useCallback(async () => {
    const data = await fetchChannelModel(channelId);
    if (data) setModelData(data);
  }, [channelId]);

  useEffect(() => {
    if (isExpanded && !modelData) {
      void load();
    }
  }, [isExpanded, modelData, load]);

  async function handleChange(modelId) {
    setIsSaving(true);
    let result;
    if (!modelId) {
      const ok = await clearChannelModel(channelId);
      result = ok ? { ...modelData, selectedModel: null } : null;
    } else {
      result = await updateChannelModel(channelId, modelId);
    }
    if (result) setModelData(result);
    setIsSaving(false);
  }

  const availableModels = Array.isArray(modelData?.availableModels) ? modelData.availableModels : [];
  const selectedModel = modelData?.selectedModel || "";

  return (
    <div className="channel-model-selector">
      <button
        type="button"
        className="channel-model-toggle"
        onClick={() => {
          setIsExpanded((prev) => !prev);
          if (!isExpanded && !modelData) void load();
        }}
        title="Model override for this channel"
      >
        <span className="material-symbols-rounded">model_training</span>
        {selectedModel ? (
          <span className="channel-model-badge">{selectedModel}</span>
        ) : (
          <span className="channel-model-badge channel-model-badge-default">default</span>
        )}
      </button>

      {isExpanded && (
        <div className="channel-model-popover">
          <label className="channel-model-label">
            Model override
            {modelData ? (
              <select
                value={selectedModel}
                onChange={(e) => void handleChange(e.target.value)}
                disabled={isSaving}
              >
                <option value="">default (not overridden)</option>
                {availableModels.map((m) => (
                  <option key={m.id} value={m.id}>{m.title || m.id}</option>
                ))}
              </select>
            ) : (
              <span className="placeholder-text">Loading...</span>
            )}
          </label>
        </div>
      )}
    </div>
  );
}

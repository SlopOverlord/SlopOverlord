import React, { useEffect, useMemo, useState, useCallback } from "react";
import {
  fetchSkillsRegistry,
  fetchAgentSkills,
  installAgentSkill,
  uninstallAgentSkill
} from "../../../api";

interface SkillInfo {
  id: string;
  owner: string;
  repo: string;
  name: string;
  description?: string;
  installs: number;
  githubUrl: string;
}

interface InstalledSkill {
  id: string;
  owner: string;
  repo: string;
  name: string;
  description?: string;
  installedAt: string;
  localPath: string;
}

interface AgentSkillsTabProps {
  agentId: string;
}

type TabType = "registry" | "installed";

function formatInstalls(count: number): string {
  if (count >= 1000000) {
    return `${(count / 1000000).toFixed(1)}M`;
  }
  if (count >= 1000) {
    return `${(count / 1000).toFixed(1)}k`;
  }
  return String(count);
}

function SkillCard({
  skill,
  isInstalled,
  isInstalling,
  onInstall,
  onUninstall
}: {
  skill: SkillInfo;
  isInstalled: boolean;
  isInstalling: boolean;
  onInstall: () => void;
  onUninstall: () => void;
}) {
  return (
    <div className="skill-card">
      <div className="skill-card-header">
        <h4 className="skill-name">{skill.name}</h4>
        <span className="skill-owner">{skill.owner}/{skill.repo}</span>
      </div>
      <p className="skill-description">
        {skill.description || "No description provided"}
      </p>
      <div className="skill-card-footer">
        <span className="skill-installs">{formatInstalls(skill.installs)} installs</span>
        {isInstalled ? (
          <button
            type="button"
            className="skill-button skill-button-installed"
            onClick={onUninstall}
            disabled={isInstalling}
          >
            <span className="material-symbols-rounded">check</span>
          </button>
        ) : (
          <button
            type="button"
            className="skill-button skill-button-install"
            onClick={onInstall}
            disabled={isInstalling}
          >
            {isInstalling ? (
              <span className="material-symbols-rounded">hourglass_empty</span>
            ) : (
              <span className="material-symbols-rounded">download</span>
            )}
          </button>
        )}
      </div>
    </div>
  );
}

function InstalledSkillCard({
  skill,
  isUninstalling,
  onUninstall
}: {
  skill: InstalledSkill;
  isUninstalling: boolean;
  onUninstall: () => void;
}) {
  return (
    <div className="skill-card">
      <div className="skill-card-header">
        <h4 className="skill-name">{skill.name}</h4>
        <span className="skill-owner">{skill.owner}/{skill.repo}</span>
      </div>
      <p className="skill-description">
        {skill.description || "No description provided"}
      </p>
      <div className="skill-card-footer">
        <span className="skill-installs">
          Installed {new Date(skill.installedAt).toLocaleDateString()}
        </span>
        <button
          type="button"
          className="skill-button skill-button-uninstall"
          onClick={onUninstall}
          disabled={isUninstalling}
        >
          {isUninstalling ? (
            <span className="material-symbols-rounded">hourglass_empty</span>
          ) : (
            <span className="material-symbols-rounded">delete</span>
          )}
        </button>
      </div>
    </div>
  );
}

const PAGE_SIZE = 20;

export function AgentSkillsTab({ agentId }: AgentSkillsTabProps) {
  const [activeTab, setActiveTab] = useState<TabType>("registry");
  // Input value (updates on every keystroke)
  const [searchInput, setSearchInput] = useState("");
  // Debounced value (used for API calls)
  const [searchQuery, setSearchQuery] = useState("");
  const [sortBy, setSortBy] = useState("installs");
  const [registrySkills, setRegistrySkills] = useState<SkillInfo[]>([]);
  const [registryTotal, setRegistryTotal] = useState(0);
  const [registryOffset, setRegistryOffset] = useState(0);
  const [isLoadingRegistry, setIsLoadingRegistry] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [installedSkills, setInstalledSkills] = useState<InstalledSkill[]>([]);
  const [isLoadingInstalled, setIsLoadingInstalled] = useState(false);
  const [installingSkillId, setInstallingSkillId] = useState<string | null>(null);
  const [uninstallingSkillId, setUninstallingSkillId] = useState<string | null>(null);
  const [githubInput, setGithubInput] = useState("");
  const [isInstallingFromGithub, setIsInstallingFromGithub] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Debounce search input → searchQuery
  useEffect(() => {
    const timer = setTimeout(() => setSearchQuery(searchInput), 300);
    return () => clearTimeout(timer);
  }, [searchInput]);

  // Load registry skills (fresh page)
  const loadRegistrySkills = useCallback(async (search: string, sort: string) => {
    console.debug("[AgentSkillsTab] loadRegistrySkills called:", { search: search || null, sort, offset: 0 });
    setIsLoadingRegistry(true);
    setRegistryOffset(0);
    try {
      const response = await fetchSkillsRegistry(search || undefined, sort, PAGE_SIZE, 0);
      const skillsCount = response && Array.isArray(response.skills) ? (response.skills as unknown[]).length : 0;
      const total = response && typeof response.total === "number" ? response.total : skillsCount;
      console.debug("[AgentSkillsTab] loadRegistrySkills result:", { skillsCount, total, raw: response });
      if (response && Array.isArray(response.skills)) {
        setRegistrySkills(response.skills as SkillInfo[]);
        setRegistryTotal(total);
      } else {
        setRegistrySkills([]);
        setRegistryTotal(0);
      }
    } catch (err) {
      console.debug("[AgentSkillsTab] loadRegistrySkills error:", err);
      setRegistrySkills([]);
      setRegistryTotal(0);
    } finally {
      setIsLoadingRegistry(false);
    }
  }, []);

  // Load more (append next page)
  const loadMoreSkills = useCallback(async (search: string, sort: string, offset: number) => {
    setIsLoadingMore(true);
    try {
      const response = await fetchSkillsRegistry(search || undefined, sort, PAGE_SIZE, offset);
      if (response && Array.isArray(response.skills)) {
        setRegistrySkills(prev => [...prev, ...(response.skills as SkillInfo[])]);
        setRegistryTotal(typeof response.total === "number" ? response.total : 0);
        setRegistryOffset(offset);
      }
    } catch {
      // ignore
    } finally {
      setIsLoadingMore(false);
    }
  }, []);

  // Load installed skills
  const loadInstalledSkills = useCallback(async () => {
    setIsLoadingInstalled(true);
    try {
      const response = await fetchAgentSkills(agentId);
      if (response && Array.isArray(response.skills)) {
        setInstalledSkills(response.skills as InstalledSkill[]);
      } else {
        setInstalledSkills([]);
      }
    } catch {
      setInstalledSkills([]);
    } finally {
      setIsLoadingInstalled(false);
    }
  }, [agentId]);

  // Reload registry when debounced query or sort changes
  useEffect(() => {
    loadRegistrySkills(searchQuery, sortBy);
  }, [searchQuery, sortBy, loadRegistrySkills]);

  // Initial installed load
  useEffect(() => {
    loadInstalledSkills();
  }, [loadInstalledSkills]);

  const handleInstall = async (skill: SkillInfo) => {
    setInstallingSkillId(skill.id);
    setError(null);
    try {
      const result = await installAgentSkill(agentId, skill.owner, skill.repo);
      if (result) {
        await loadInstalledSkills();
      } else {
        setError(`Failed to install ${skill.name}`);
      }
    } catch (err) {
      setError(`Failed to install ${skill.name}`);
    } finally {
      setInstallingSkillId(null);
    }
  };

  const handleUninstall = async (skillId: string) => {
    setUninstallingSkillId(skillId);
    setError(null);
    try {
      const success = await uninstallAgentSkill(agentId, skillId);
      if (success) {
        await loadInstalledSkills();
      } else {
        setError(`Failed to uninstall skill`);
      }
    } catch (err) {
      setError(`Failed to uninstall skill`);
    } finally {
      setUninstallingSkillId(null);
    }
  };

  const handleInstallFromGithub = async () => {
    const trimmed = githubInput.trim();
    if (!trimmed) return;

    // Parse owner/repo format
    const parts = trimmed.split("/").filter(Boolean);
    if (parts.length < 2) {
      setError("Please use format: owner/repo");
      return;
    }

    const [owner, repo] = parts;
    setIsInstallingFromGithub(true);
    setError(null);

    try {
      const result = await installAgentSkill(agentId, owner, repo);
      if (result) {
        setGithubInput("");
        await loadInstalledSkills();
        setActiveTab("installed");
      } else {
        setError(`Failed to install ${owner}/${repo}`);
      }
    } catch (err) {
      setError(`Failed to install ${owner}/${repo}`);
    } finally {
      setIsInstallingFromGithub(false);
    }
  };

  const installedSkillIds = useMemo(() => {
    return new Set(installedSkills.map(s => s.id));
  }, [installedSkills]);

  const filteredRegistrySkills = useMemo(() => registrySkills, [registrySkills]);

  return (
    <section className="entry-editor-card agent-content-card">
      <div className="skills-header">
        <h3>Skills</h3>
        <a
          href="https://skills.sh"
          target="_blank"
          rel="noopener noreferrer"
          className="skills-external-link"
        >
          skills.sh
          <span className="material-symbols-rounded">open_in_new</span>
        </a>
      </div>

      {/* Tabs */}
      <div className="skills-tabs">
        <button
          type="button"
          className={`skills-tab ${activeTab === "registry" ? "active" : ""}`}
          onClick={() => setActiveTab("registry")}
        >
          Browse Registry
        </button>
        <button
          type="button"
          className={`skills-tab ${activeTab === "installed" ? "active" : ""}`}
          onClick={() => setActiveTab("installed")}
        >
          Installed ({installedSkills.length})
        </button>
      </div>

      {error && (
        <div className="skills-error">
          <span className="material-symbols-rounded">error</span>
          {error}
        </div>
      )}

      {activeTab === "registry" && (
        <>
          {/* Search and Filter */}
          <div className="skills-toolbar">
            <div className="skills-search">
              <span className="material-symbols-rounded">search</span>
              <input
                type="text"
                placeholder="Search skills..."
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
              />
            </div>
            <select
              className="skills-sort"
              value={sortBy}
              onChange={(e) => setSortBy(e.target.value)}
            >
              <option value="installs">All Time</option>
              <option value="trending">Trending</option>
              <option value="recent">Recent</option>
            </select>
          </div>

          {/* Install from GitHub */}
          <div className="skills-github-section">
            <h4>Install from GitHub</h4>
            <p className="skills-github-description">
              Install any skill from a GitHub repository
            </p>
            <div className="skills-github-input-group">
              <input
                type="text"
                placeholder="owner/repo or owner/repo/skill-name"
                value={githubInput}
                onChange={(e) => setGithubInput(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && handleInstallFromGithub()}
              />
              <button
                type="button"
                className="skills-install-btn"
                onClick={handleInstallFromGithub}
                disabled={isInstallingFromGithub || !githubInput.trim()}
              >
                {isInstallingFromGithub ? (
                  <span className="material-symbols-rounded">hourglass_empty</span>
                ) : (
                  <>
                    <span className="material-symbols-rounded">download</span>
                    Install
                  </>
                )}
              </button>
            </div>
          </div>

          {/* Skills Grid */}
          <div className="skills-section-title">
            {sortBy === "trending" ? "Trending Skills" : sortBy === "recent" ? "Recent Skills" : "All Time Skills"}
            <span className="skills-count">{registryTotal > 0 ? `${registryTotal} skills` : `${filteredRegistrySkills.length} skills`}</span>
          </div>

          {isLoadingRegistry ? (
            <div className="skills-loading">
              <span className="material-symbols-rounded">hourglass_empty</span>
              Loading skills...
            </div>
          ) : filteredRegistrySkills.length === 0 ? (
            <div className="skills-empty">
              {searchInput
                ? "No skills found matching your search."
                : "No skills available."}
            </div>
          ) : (
            <>
              <div className="skills-grid">
                {filteredRegistrySkills.map((skill) => (
                  <SkillCard
                    key={skill.id}
                    skill={skill}
                    isInstalled={installedSkillIds.has(skill.id)}
                    isInstalling={installingSkillId === skill.id}
                    onInstall={() => handleInstall(skill)}
                    onUninstall={() => handleUninstall(skill.id)}
                  />
                ))}
              </div>
              {registrySkills.length < registryTotal && (
                <div className="skills-load-more">
                  <button
                    type="button"
                    className="skills-load-more-btn"
                    onClick={() => loadMoreSkills(searchQuery, sortBy, registryOffset + PAGE_SIZE)}
                    disabled={isLoadingMore}
                  >
                    {isLoadingMore ? (
                      <><span className="material-symbols-rounded">hourglass_empty</span> Loading...</>
                    ) : (
                      `Load more (${registryTotal - registrySkills.length} remaining)`
                    )}
                  </button>
                </div>
              )}
            </>
          )}
        </>
      )}

      {activeTab === "installed" && (
        <>
          {isLoadingInstalled ? (
            <div className="skills-loading">
              <span className="material-symbols-rounded">hourglass_empty</span>
              Loading installed skills...
            </div>
          ) : installedSkills.length === 0 ? (
            <div className="skills-empty">
              <p>No skills installed yet.</p>
              <button
                type="button"
                className="skills-browse-btn"
                onClick={() => setActiveTab("registry")}
              >
                Browse Registry
              </button>
            </div>
          ) : (
            <div className="skills-grid">
              {installedSkills.map((skill) => (
                <InstalledSkillCard
                  key={skill.id}
                  skill={skill}
                  isUninstalling={uninstallingSkillId === skill.id}
                  onUninstall={() => handleUninstall(skill.id)}
                />
              ))}
            </div>
          )}
        </>
      )}
    </section>
  );
}

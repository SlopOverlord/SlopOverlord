CREATE TABLE IF NOT EXISTS channels (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    status TEXT NOT NULL,
    title TEXT NOT NULL,
    objective TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    message_type TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    task_id TEXT,
    branch_id TEXT,
    worker_id TEXT,
    payload_json TEXT NOT NULL,
    extensions_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_channel_created ON events(channel_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_task_created ON events(task_id, created_at DESC);

CREATE TABLE IF NOT EXISTS artifacts (
    id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_bulletins (
    id TEXT PRIMARY KEY,
    headline TEXT NOT NULL,
    digest TEXT NOT NULL,
    items_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_entries (
    id TEXT PRIMARY KEY,
    class TEXT NOT NULL,
    kind TEXT NOT NULL,
    text TEXT NOT NULL,
    summary TEXT,
    scope_type TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    channel_id TEXT,
    project_id TEXT,
    agent_id TEXT,
    importance REAL NOT NULL DEFAULT 0.5,
    confidence REAL NOT NULL DEFAULT 0.7,
    source_type TEXT,
    source_id TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    expires_at TEXT,
    deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS memory_edges (
    id TEXT PRIMARY KEY,
    from_memory_id TEXT NOT NULL,
    to_memory_id TEXT NOT NULL,
    relation TEXT NOT NULL,
    weight REAL NOT NULL DEFAULT 1.0,
    provenance TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_provider_outbox (
    id TEXT PRIMARY KEY,
    memory_id TEXT NOT NULL,
    op TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 0,
    next_retry_at TEXT NOT NULL,
    last_error TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_recall_log (
    id TEXT PRIMARY KEY,
    query TEXT NOT NULL,
    scope_type TEXT,
    scope_id TEXT,
    top_k INTEGER NOT NULL,
    result_ids_json TEXT NOT NULL,
    latency_ms INTEGER NOT NULL,
    created_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(
    id UNINDEXED,
    text,
    summary
);

CREATE INDEX IF NOT EXISTS idx_memory_entries_scope_time ON memory_entries(scope_type, scope_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_memory_entries_kind ON memory_entries(kind);
CREATE INDEX IF NOT EXISTS idx_memory_entries_class ON memory_entries(class);
CREATE INDEX IF NOT EXISTS idx_memory_entries_expires ON memory_entries(expires_at);
CREATE INDEX IF NOT EXISTS idx_memory_edges_from ON memory_edges(from_memory_id);
CREATE INDEX IF NOT EXISTS idx_memory_edges_to ON memory_edges(to_memory_id);
CREATE INDEX IF NOT EXISTS idx_memory_outbox_retry ON memory_provider_outbox(next_retry_at, attempt);

CREATE TABLE IF NOT EXISTS token_usage (
    id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    task_id TEXT,
    prompt_tokens INTEGER NOT NULL,
    completion_tokens INTEGER NOT NULL,
    total_tokens INTEGER NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dashboard_projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    actors_json TEXT NOT NULL DEFAULT '[]',
    teams_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dashboard_project_channels (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    title TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(project_id, channel_id)
);

CREATE INDEX IF NOT EXISTS idx_dashboard_project_channels_project ON dashboard_project_channels(project_id);

CREATE TABLE IF NOT EXISTS dashboard_project_tasks (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    priority TEXT NOT NULL,
    status TEXT NOT NULL,
    actor_id TEXT,
    team_id TEXT,
    claimed_actor_id TEXT,
    claimed_agent_id TEXT,
    swarm_id TEXT,
    swarm_task_id TEXT,
    swarm_parent_task_id TEXT,
    swarm_dependency_ids_json TEXT NOT NULL DEFAULT '[]',
    swarm_depth INTEGER,
    swarm_actor_path_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dashboard_project_tasks_project ON dashboard_project_tasks(project_id);

CREATE TABLE IF NOT EXISTS channel_plugins (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    base_url TEXT NOT NULL,
    channel_ids_json TEXT NOT NULL DEFAULT '[]',
    config_json TEXT NOT NULL DEFAULT '{}',
    enabled INTEGER NOT NULL DEFAULT 1,
    delivery_mode TEXT NOT NULL DEFAULT 'http',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS channel_access_users (
    id TEXT PRIMARY KEY,
    platform TEXT NOT NULL,
    platform_user_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(platform, platform_user_id)
);

CREATE INDEX IF NOT EXISTS idx_channel_access_users_platform ON channel_access_users(platform, status);

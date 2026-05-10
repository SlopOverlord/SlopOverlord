---
layout: doc
title: Agent memory
---

# Agent memory

Sloppy gives agents two complementary ways to remember: a **hybrid memory store** (SQLite-backed, searchable entries) and **markdown documents** on disk (`USER.md`, `FRIEND_REMINDER.md`, `MEMORY.md`, and optional project `.meta/MEMORY.md`). Together they let an agent keep facts, preferences, and narrative context across sessions and restarts.

This page describes how both layers work, how they show up in the Dashboard, which tools update them, and how **memory checkpoints** refresh long-form `MEMORY.md` without polluting the chat.

## Two layers: hybrid store vs markdown files

| Layer | What it is | Where you see it |
| --- | --- | --- |
| **Hybrid memory** | Structured entries (note, summary, kind, class, scope, edges). Indexed for recall and search. | **Agents → Memories** tab (list and graph). SQLite in your workspace. |
| **Agent markdown** | Plain files in the agent catalog: `USER.md` (identity/instructions), `FRIEND_REMINDER.md` (short per-turn reminders), `MEMORY.md` (long-form narrative the model reads). | **Agents → Agent files** in the Dashboard; files under `.sloppy/agents/<agent>/` on disk. |
| **Project meta memory** | Optional workspace-private `.meta/MEMORY.md` under `~/.sloppy/projects/<projectId>/.meta/MEMORY.md`. | On disk; updated via tools when the agent targets a project. |

These are **not** the same list: saving a hybrid entry does **not** automatically rewrite `MEMORY.md`, and editing `MEMORY.md` does **not** create hybrid rows unless a workflow explicitly does both.

## Character limits (markdown files)

The API and tools enforce size limits (character counts) on bundled agent documents:

| Resource | Limit (characters) |
| --- | ---: |
| `USER.md` | 2000 |
| `FRIEND_REMINDER.md` | 2000 |
| `MEMORY.md` (agent) | 3000 |
| `.meta/MEMORY.md` (project) | 3000 |

If generated or submitted text exceeds a limit, the update may be rejected or skipped with a warning—avoid treating markdown files as unlimited storage.

## Dashboard: Memories vs Agent files

- **Memories** — shows **hybrid store** entries for that agent (scoped to the agent or to channels like `agent:<agentId>:session:<sessionId>`). This is **not** a live view of the `MEMORY.md` file.
- **Agent files → `FRIEND_REMINDER.md`** — a user-editable short reminder appended to every runtime user turn when non-empty. It is meant for tactical, current constraints rather than unlimited memory.
- **Agent files → `MEMORY.md`** — often labeled as **auto-generated** or read-only in the UI when the server maintains that file from checkpoints or refresh logic. Prefer updating via **`agent.documents.set_memory_markdown`** (or checkpoints) rather than expecting ad-hoc hybrid saves to appear here.

::: tip
`memory.search` and `memory.recall` / `memory.get` **only read** the hybrid store. They do not create rows and do not edit `MEMORY.md`.
:::

## Scopes and the Memories list

Hybrid entries are **scoped**. The **Agents → Memories** view lists entries that belong to **this agent**:

- **`agent`** scope with id equal to the agent id, or  
- **`channel`** scope whose channel id looks like `agent:<agentId>:session:<sessionId>`.

Entries saved as **`global`** (or other scopes that do not match the rules above) **do not** appear under that agent’s Memories tab, even though they exist in the database.

## Tools (runtime)

Agents use tools to read and write memory. Policy may hide some tools depending on configuration.

| Tool | Purpose |
| --- | --- |
| `memory.save` | Create a hybrid memory entry. **You must set scope** (see below). |
| `memory.search` | Keyword search over the index. |
| `memory.recall` / `memory.get` | Semantic-style recall with a query. |
| `agent.documents.set_user_markdown` | Update `USER.md` (validated limits). |
| `agent.documents.set_memory_markdown` | Update agent `MEMORY.md` (validated limits). |
| `project.meta_memory_set` | Write workspace-private project `.meta/MEMORY.md`; no repo path is required. |
| `visor.status` | Read Visor readiness and latest bulletin digest (operational snapshot, not a substitute for long-term hybrid memory). |

Direct **`files.write` / `files.edit`** on agent `USER.md` / `MEMORY.md` paths are blocked—use the `agent.documents.*` tools instead.

### `memory.save` and scope

The **caller (the model)** must attribute every save:

- Either **`scope_type` + `scope_id`** together, or  
- A **`scope`** object with **`type`** and **`id`** (and optional `channel_id`, `project_id`, `agent_id` when needed).

Examples:

- Current chat, visible under **Memories** for this agent:  
  `scope_type: channel`, `scope_id: agent:<agentId>:session:<sessionId>`
- Agent-wide fact:  
  `scope_type: agent`, `scope_id: <agentId>`

Omitting scope causes the call to fail validation—there is no silent default to “this session”.

## Memory checkpoints (shadow)

A **checkpoint** is a background pass that can refresh **`MEMORY.md`** (and optionally project meta memory) using a dedicated model turn on an **ephemeral channel**, so tool calls do **not** append to the visible chat transcript. Tool invocations during a checkpoint do **not** write tool-call rows into the session JSONL as normal user-visible events.

Typical triggers include:

- Starting a **new session** with a reference to the previous session id (e.g. Dashboard **New session** / `/new` flow).  
- **Stopping** generation (e.g. `/stop`) when the client requests a checkpoint before interrupt.  
- After enough **user turns** since the last checkpoint (server-side counter; resets after a successful checkpoint).  
- **Context compactor** threshold events for agent session channels.  
- **Gateway** channel sessions closed by inactivity (when the channel id maps to an agent session).

Checkpoints use an allowlisted set of tools (for example Visor status, agent document setters, project meta memory). They are designed to consolidate durable facts into markdown files rather than spamming hybrid entries.

## How hybrid memory works (recap)

When something worth remembering happens, a hybrid entry can be created with a note, optional summary, kind, class, scope, and metadata. Entries live in **SQLite** in your workspace. Retrieval blends semantic, keyword, and graph signals when embeddings and graph edges are available—see [Configuration reference](#configuration-reference).

### What a memory represents (kind)

| Kind | What it is |
| --- | --- |
| Fact | General knowledge: names, versions, tech choices |
| Preference | What the user prefers or avoids |
| Goal | An objective the agent or user is working toward |
| Decision | A choice that was made and should be remembered |
| Todo | An action item |
| Identity | Who the agent is working with |
| Event | Something that happened at a point in time |
| Observation | Something the agent noticed |

Kinds can be inferred from text or set explicitly on save.

### How long a class lives (memory class)

| Class | Role | Default lifespan |
| --- | --- | --- |
| Semantic | Long-term knowledge | No automatic expiry |
| Procedural | Goals, decisions, todos | No automatic expiry |
| Episodic | Time-bound events | 90 days (configurable) |
| Bulletin | System / Visor digests | 180 days (configurable) |

### Scope types (hybrid)

| Scope | Typical use |
| --- | --- |
| Global | Shared across many contexts (does **not** show on a single agent’s Memories tab unless you filter elsewhere). |
| Project | Scoped to one project |
| Channel | One channel id (for agent chat, use `agent:…:session:…`) |
| Agent | One agent id |

## How recall works

Sloppy combines **semantic** search (when embeddings or an external provider is configured), **keyword** search (SQLite FTS), and **graph expansion** over linked entries. Weights are configurable under `memory.retrieval`—defaults favor semantic recall. See the table below.

## Memory relationships

Entries can link to each other (support, contradict, derive, supersede, and so on). Branch conclusions and merges can create or update links so future recall surfaces related context.

## Automatic maintenance

Decay, pruning, and optional merge runs are driven by **Visor** on a schedule. Bulletins and merge behavior are described in [Visor: memory and bulletins](/visor/memory) and [Visor overview](/visor/overview).

## Connecting an external memory service

You can use **local embeddings**, an **HTTP** provider, or an **MCP** provider while keeping SQLite canonical. See the configuration keys below.

## Configuration reference

All memory settings live under the `memory` key in `sloppy.json`.

### Provider settings (`memory.provider`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `mode` | `local` | Where semantic indexing happens: `local`, `http`, or `mcp` |
| `endpoint` | — | URL of the external HTTP memory service (required for `http` mode) |
| `mcpServer` | — | ID of the MCP server to use (required for `mcp` mode) |
| `timeoutMs` | `2500` | Timeout in milliseconds for external provider calls |
| `apiKeyEnv` | — | Name of the environment variable holding the API key for the HTTP provider |

### Retrieval weights (`memory.retrieval`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `topK` | `8` | How many results to return per recall query |
| `semanticWeight` | `0.55` | Weight for semantic / vector search |
| `keywordWeight` | `0.35` | Weight for full-text keyword search |
| `graphWeight` | `0.10` | Weight for graph-expanded neighbors |

### Retention (`memory.retention`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `episodicDays` | `90` | Episodic memory retention |
| `todoCompletedDays` | `30` | Completed todo retention |
| `bulletinDays` | `180` | Bulletin retention |

### Embeddings (`memory.embedding`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `enabled` | `false` | Compute and store local vectors |
| `model` | `text-embedding-3-small` | Embedding model id |
| `dimensions` | `1536` | Vector size (must match the model) |
| `endpoint` | — | Embeddings API URL |
| `apiKeyEnv` | — | Env var for the embeddings API key |

## Related

- [Visor: memory and bulletins](/visor/memory) — bulletins vs hybrid memory, maintenance, `visor.status`
- [Context compactor](/agents/context-compactor) — compaction thresholds (checkpoint trigger)
- [Visor overview](/visor/overview) — supervision, bulletins, dashboard

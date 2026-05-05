# Workspace

Every Sloppy deployment has a workspace — a directory on disk where all agent data lives. This includes each agent's configuration, instructions, tool policies, installed skills, session history, and the shared memory database.

## Workspace location

By default, the workspace is created at `.sloppy/` inside the directory where Sloppy is running. Both the folder name and the base path are configurable in `sloppy.json`.

| Setting | Default | What it controls |
|---|---|---|
| `workspace.name` | `.sloppy` | Name of the workspace folder |
| `workspace.basePath` | `.` | Where the workspace folder is created |

You can use absolute paths or `~` in `basePath`. For example, to keep the workspace in your home directory: set `basePath` to `~` and `name` to `.sloppy`.

The memory database lives at `memory/core.sqlite` inside the workspace. Its path is configurable via `sqlitePath` in `sloppy.json`; if relative, it is resolved from the workspace root.

## Agent directories

Each agent gets its own subdirectory inside `agents/`. System agents (used internally by Sloppy) live in a hidden `agents/.system/` subdirectory and are not shown in normal listings.

Agent IDs can only contain letters, numbers, hyphens, underscores, and dots. They must be 120 characters or fewer and must be unique within the workspace.

## Files in an agent directory

When an agent is created, Sloppy writes a set of files that define its identity and behavior. These files can be edited at any time to change how the agent works.

### agent.json

The agent's core metadata — its ID, display name, role, creation timestamp, and whether it's a system agent. This file is written once at creation and not updated afterwards. Treat it as a record of what the agent is.

### config.json

The agent's runtime configuration. This is the file you update when you want to change settings — which model the agent uses, whether the heartbeat is enabled, and how channel sessions behave. Updated via the Dashboard or the API.

### AGENTS.md

The primary instruction document for the agent. This is where you define how the agent should approach tasks, what tools it should use, how it should communicate, and any project-specific rules you want it to follow.

A default scaffold is written on agent creation with sensible baseline behaviors (work toward user goals, keep answers actionable, fetch task details before referencing them, etc.). You should customize this file for your specific use case.

### USER.md

Describes the person the agent is working with. Use this file to tell the agent about your communication preferences, the context you're working in, and what kind of responses you find most useful. This gets injected into the system prompt alongside `AGENTS.md`.

### FRIEND_REMINDER.md

A short per-agent reminder block that is appended to each user message when the file is not empty. Use it for lightweight, always-current preferences or constraints that should sit next to the user's request rather than only in the startup context.

Sloppy creates this file empty by default. When it contains text, the runtime sends the user message to the model with an extra block:

```md
#[FRIEND_REMINDER.md]
- Do not use MCPs
- Always run git pull
```

Because this block is attached to every user turn, keep it brief and tactical. Put stable identity, collaboration style, and broad operating rules in `USER.md` or `AGENTS.md` instead.

### SOUL.md

Defines the agent's core values and behavioral constraints — things like "prioritize correctness over speed", "never hide risks", "avoid hallucinations". These act as a backstop that applies regardless of what the task instructions say.

### IDENTITY.md

A short self-description of the agent in markdown. Included during prompt construction to give the model a consistent sense of its own identity and purpose.

### HEARTBEAT.md

The template used when the heartbeat fires a background session. Write here what the agent should do during a scheduled tick — for example, checking for overdue tasks, posting a status update, or running a daily check. Empty by default; the heartbeat is disabled until you enable it in `config.json`.

### heartbeat-status.json

A record of the most recent heartbeat run: when it ran, whether it succeeded, the result summary, any error message, and the session ID. Updated automatically after each heartbeat.

### tools/tools.json

The tool access policy for this agent. Controls which tools the agent is allowed to call and sets hard limits on resource usage.

**Default policy** — either `allow` (all tools permitted unless blocked) or `deny` (all tools blocked unless permitted). Per-tool overrides are boolean: `true` to allow, `false` to block.

**Guardrails** limit what allowed tools can actually do:

| Limit | Default | What it prevents |
|---|---|---|
| `maxReadBytes` | 512 KB | Reading excessively large files |
| `maxWriteBytes` | 512 KB | Writing excessively large files |
| `execTimeoutMs` | 15,000 ms | Short commands inheriting an unbounded default runtime |
| `maxExecTimeoutMs` | 120,000 ms | Model-requested command timeouts growing without an upper bound |
| `maxExecOutputBytes` | 256 KB | Shell commands producing huge output |
| `maxProcessesPerSession` | 2 | Spawning too many concurrent processes |
| `maxToolCallsPerMinute` | 60 | Tool call rate limiting |
| `deniedCommandPrefixes` | — | Specific shell commands always blocked (e.g. `rm -rf`) |
| `allowedWriteRoots` | — | Directories the agent may write to; empty means unrestricted |
| `allowedExecRoots` | — | Directories the agent may execute within; empty means unrestricted |
| `webTimeoutMs` | 15,000 ms | Web requests taking too long |
| `webMaxBytes` | 512 KB | Web responses being too large |
| `webBlockPrivateNetworks` | true | Requests to private/loopback IP ranges |

### skills/skills.json

The manifest of skills installed for this agent. Each skill entry records its ID, owner, repository, name, description, local path, whether it can be invoked directly by users, and which tools it is allowed to use.

### skills/{owner}/{repo}/

Each installed skill has its own subdirectory with the skill's content files. The runtime reads from here when composing skill-aware prompts or invoking skill logic.

### sessions/

Stores the persisted session history for this agent. Each session is written as a separate file. Sessions are created by the session orchestrator and contain the full event log for the conversation.

## Full directory layout

```
.sloppy/agents/my-agent/
├── agent.json              ← immutable metadata
├── config.json             ← mutable runtime config
├── AGENTS.md               ← behavior instructions
├── USER.md                 ← user preferences
├── FRIEND_REMINDER.md      ← optional reminder appended to user turns
├── SOUL.md                 ← core values
├── IDENTITY.md             ← identity description
├── HEARTBEAT.md            ← heartbeat prompt template
├── heartbeat-status.json   ← last heartbeat outcome
├── tools/
│   └── tools.json          ← tool access policy + guardrails
├── skills/
│   ├── skills.json         ← installed skills manifest
│   └── {owner}/{repo}/     ← skill content directories
└── sessions/               ← persisted session history
```

## Creating an agent

Agents are created through the REST API or the Dashboard. The ID must be unique within the workspace and conform to the naming rules above. Sloppy writes all scaffold files atomically on creation — if any file write fails, the entire agent directory is removed to avoid partial state.

After creation, open the agent in the Dashboard to set the model, customize the instruction files, and configure tool access.

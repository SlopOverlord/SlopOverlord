---
layout: doc
title: Project Context
---

# Project Context

Sloppy can enrich a project's channels with **additional context from your repository**. This is useful when you want agents and actors working on a project to consistently see the same rules, memory notes, and local skill instructions — without pasting them into chat.

## What “project context” means

Project context is a **bootstrap system message** that Sloppy applies to each channel attached to a project. Once applied, it becomes part of the channel’s background context (similar in spirit to how agent instruction files like `AGENTS.md` shape agent sessions).

In practice, you refresh it when you change repo files that should influence how work is done.

## Prerequisites

- Your project must have `repoPath` set (a local directory path).
- The project must have one or more channels attached.

You can set `repoPath` in the Dashboard under **Projects → Settings**.

## What files are loaded

When you refresh project context, Sloppy loads (if present) these files from `repoPath`:

- `AGENTS.md`
- `CLAUDE.md`
- `SLOPPY.md`

It also scans for local skill docs under:

- `.skills/**/SKILL.md`

Project markdown memory is loaded separately from the Sloppy workspace-private path:

- `~/.sloppy/projects/<projectId>/.meta/MEMORY.md`

These files are treated as **read-only context**. If a file doesn’t exist, it’s skipped.

## Size limits and truncation

Project context is intentionally bounded to keep prompts stable:

| Limit | Default | Meaning |
|---|---:|---|
| Max skill files | 25 | At most 25 `.skills/**/SKILL.md` files are included |
| Max chars per file | 20,000 | Each loaded file is truncated to this size |
| Max total chars | 200,000 | Total project context budget across all loaded files |

If a limit is hit, Sloppy marks the context as **truncated** and continues with what fits.

## How to refresh project context (Dashboard)

1. Open **Projects** and select a project.
2. Go to the **Chat** tab.
3. Click **Refresh Context**.

If `repoPath` is not set, the button is disabled and you need to configure it in **Settings** first.

## How to refresh project context (HTTP API)

Call:

```bash
curl -X POST "http://localhost:25102/v1/projects/<projectId>/context/refresh"
```

The response includes which channels were updated and which file paths were loaded.

## Related

- [Project Design](/architecture/project-design)
- [Workspace](/agents/workspace)
- [About Channels](/channels/about)

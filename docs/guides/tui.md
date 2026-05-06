---
layout: doc
title: Terminal UI
---

# Terminal UI

Sloppy ships with a full-screen terminal UI for local agent work. It uses the same runtime, workspace, project resolution, providers, agents, sessions, MCP servers, and persistence as the rest of Sloppy, but keeps the main chat loop inside your terminal.

Use it when you want the fastest local path: open a project directory, start Sloppy, ask questions, attach files, switch models, and resume the same session later without opening the Dashboard.

## Start the TUI

From a project directory:

```bash
sloppy
```

The explicit command is:

```bash
sloppy tui
```

Useful variants:

```bash
sloppy tui --config-path /path/to/sloppy.json
sloppy -s <sessionId>
sloppy tui -s <sessionId>
sloppy models
```

`sloppy` with no subcommand opens the TUI. `sloppy tui` does the same thing explicitly. `sloppy -s` and `sloppy tui -s` resume an existing agent session for the current directory. `sloppy models` opens the same terminal picker directly in model-selection mode and exits after a model is chosen.

The TUI bootstraps Sloppy in-process, so you do not need a separate `sloppy run` server for a local terminal chat. It still uses the same `sloppy.json` and workspace files.

## What It Opens

On startup the TUI:

- resolves or creates a Sloppy project for the current working directory
- restores the last selected agent and session for that project
- creates a default `sloppy` agent when no user agents exist
- resumes the newest session for the selected agent, or creates a `TUI chat` session
- stores TUI state under the workspace root at `tui/state.json`

The opening screen shows the active mode, model, project, agent, and provider. The bottom composer is where you type messages or slash commands.

## Core Keys

| Key | Action |
| --- | --- |
| `Enter` | Send the current message or apply the selected picker item |
| `Tab` | Cycle chat mode when typing normally; complete/apply a command, model, session, agent, provider, or file picker when one is open |
| `Esc` | Close the active picker or command palette |
| `Up` / `Down` | Move through active picker suggestions |
| `PageUp` / `PageDown` | Scroll chat history by pages |
| `Option+Up` / `Ctrl+Up` | Scroll history upward by a few lines |
| `Option+Down` / `Ctrl+Down` | Scroll history downward by a few lines |
| `Option+Home` / `Ctrl+Home` | Jump to the start of history |
| `Option+End` / `Ctrl+End` | Jump back to the bottom |
| `Ctrl+C` | Exit the TUI |

Chat modes cycle as `Ask -> Build -> Plan -> Debug -> Ask`. The selected mode is sent with the next user message.

## Model and Provider Setup

Switch models with the picker:

```text
/model
```

Or set a model directly:

```text
/model openai:gpt-5.4-mini
/model anthropic:claude-sonnet-4-6
```

Configure providers from inside the TUI:

```text
/provider
/provider openai-api <api-key> [model]
/provider openrouter <api-key> [model]
/provider gemini <api-key> [model]
/provider anthropic <api-key> [model]
/provider ollama
/openai-device
/anthropic-oauth
```

`/provider` opens a provider picker. API-key providers save a model entry into `sloppy.json`. `ollama` uses the local Ollama server. `/openai-device` starts Codex device auth. `/anthropic-oauth` starts the Anthropic browser OAuth flow and expects the callback URL to be pasted back with `/anthropic-callback <url>`.

## Sessions, Agents, and Context

| Command | Purpose |
| --- | --- |
| `/agents` | Switch agent |
| `/sessions` or `/resume` | Switch session for the current agent and project |
| `/new` | Create a checkpointed new session from the current one |
| `/fork <task>` | Create a child session and optionally send the task immediately |
| `/status` | Show project, agent, session id, resume command, model, provider, and pet state |
| `/compact` | Request a memory checkpoint for the current session |
| `/stop` | Interrupt the current run tree |

Use `/status` when you need the exact resume command:

```text
/status
```

The card includes a shortcut such as:

```bash
sloppy -s <sessionId>
```

## Attach Files and Project Paths

Use `@path` inside a message to inline project files as explicit context:

```text
Please review @Sources/sloppy/TUI/SloppyTUIScreen.swift
```

The TUI indexes project files and offers `@path` completions. Paths with spaces are escaped automatically. Up to eight `@path` references from a single message are expanded into the prompt context.

You can also attach files by pasting file paths into the composer. On macOS, `Ctrl+V` can attach file or image data from the clipboard. Individual pasted attachments are limited to 25 MiB.

For git context:

```text
/diff
/context changes
/context diff
```

`/diff` displays the current working tree diff. `/context changes` attaches the latest watched change list to the next message. `/context diff` attaches the git diff to the next message.

## Slash Commands

| Command | Purpose |
| --- | --- |
| `/help` | Show TUI commands and scroll keys |
| `/status` | Show current project, agent, session, model, provider, and resume command |
| `/pet` | Toggle the terminal Sloppie pet and show its face/status |
| `/agents` | Switch agent |
| `/sessions`, `/resume` | Switch session |
| `/new` | Create a new session |
| `/clear` | Clear local TUI cards |
| `/stop` | Interrupt the current run |
| `/undo` | Undo file changes from the last completed TUI turn |
| `/redo` | Redo the last undone TUI turn |
| `/btw <message>` | Ask a side question without changing the current main message flow |
| `/compact` | Request session compaction |
| `/add_dir <path>` | Add a working directory to the current session |
| `/fork <task>` | Branch the current conversation |
| `/bar <color>` | Change the left accent bar color |
| `/copy` | Copy the last assistant response to the clipboard on macOS |
| `/diff` | Show uncommitted git changes |
| `/effort low\|medium\|high\|default` | Set reasoning effort for future messages |
| `/skills` | Show enabled agent skills and their slash aliases |
| `/editor` | Return focus to the composer |
| `/model [model]` | Open the model picker or switch directly |
| `/context changes\|diff` | Queue workspace changes or git diff for the next message |
| `/tasks` | Show project tasks |
| `/mcps` | Show MCP server statuses |
| `/provider [id key model]` | Configure or switch providers |
| `/openai-device` | Start OpenAI Codex device auth |
| `/anthropic-oauth` | Start Anthropic OAuth |
| `/anthropic-callback <url>` | Complete Anthropic OAuth |
| `/quit` or `/exit` | Exit the TUI |

Skill-provided slash commands also appear in the command palette and are forwarded to the agent when invoked.

## State and Persistence

The TUI uses the configured Sloppy workspace, so sessions, messages, agents, tasks, memories, logs, and MCP configuration remain shared with the Dashboard and CLI.

TUI-only state is small and local:

- last selected agent and session per project
- unsent composer drafts per project/agent/session
- terminal pet visibility

This state is stored at:

```text
<workspace-root>/tui/state.json
```

The default workspace root is controlled by `workspace.basePath` and `workspace.name` in `sloppy.json`.

# Sloppy

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/TeamSloppy/Sloppy)

Sloppy is a multi-agent runtime for building operator-visible AI workflows in Swift 6 on macOS and Linux. It combines a rule-based orchestration core, branch and worker execution, persistent runtime state, model/provider plugins, channel integrations, and a React dashboard for observing what the system is doing.

## What Is Sloppy

Sloppy is a control plane for AI agents and tool-driven workflows.

At its core, the project provides:

| Component | Purpose |
| --- | --- |
| `Core` | HTTP API, routing layer, orchestration services, persistence, scheduling, and plugin bootstrap |
| `AgentRuntime` | Runtime model built around `Channel`, `Branch`, `Worker`, `Compactor`, and `Visor` |
| `PluginSDK` | Extension points for model providers, tools, memory, and gateways |
| `Node` | Daemon for process execution |
| `Dashboard` | Vite/React UI for runtime visibility |

The runtime is designed to keep execution structured and observable instead of turning agent behavior into a single opaque prompt loop.

## Features

| Feature | What it provides |
| --- | --- |
| Channel / Branch / Worker runtime | Separates user interaction, focused work, and execution flows |
| Rule-based routing | Makes route decisions deterministic and inspectable |
| Worker modes | Supports both interactive and fire-and-forget workers |
| Compaction | Triggers summarization on context thresholds |
| Visor bulletins | Produces periodic memory digests for operators |
| SQLite persistence | Stores channels, tasks, events, artifacts, and bulletins |
| Plugin system | Extends models, tools, memory, and gateways without hard-coding providers |
| `AnyLanguageModel` bridge | Connects providers such as OpenAI and Ollama |
| Telegram gateway | Bridges Telegram chats into Sloppy channels |
| Dashboard | Exposes chat, activity, artifacts, and runtime state in the UI |

## Problems Sloppy Solves

Sloppy is built for teams that need more structure than a single-agent chatbot can provide.

| Problem | How Sloppy addresses it |
| --- | --- |
| Agent behavior is too opaque | Turns execution into explicit runtime entities and lifecycle events |
| Long-running flows are hard to understand | Persists state, artifacts, and event logs |
| Context grows too quickly | Splits work into branches and workers and returns concise outputs |
| Token costs drift upward | Uses compaction and short structured payloads |
| Integrations become fragmented | Unifies channels, tools, memory, and model providers behind one runtime |
| Operators lack visibility | Exposes the system through an API and dashboard instead of raw prompt debugging |

## Why We Are Different

What makes Sloppy distinct in its current form:

- Swift-first runtime: the orchestration layer, persistence, HTTP transport, and executables live in a single Swift package.
- Deterministic routing before autonomy: routing is policy-driven and inspectable, not hidden inside a monolithic LLM prompt.
- Runtime visibility as a product feature: channels, workers, events, artifacts, and bulletins are first-class concepts.
- Plugin boundaries instead of hard-coded providers: models, gateways, tools, and memory can evolve independently.
- Local-first development path: you can run the core, SQLite persistence, dashboard, and local model integrations without building a large distributed system first.

## Quick Start

### Prerequisites

- Swift 6 toolchain
- Node.js and npm for the dashboard
- `libsqlite3` development headers on Linux

Supported development environments:

| Platform | Notes |
| --- | --- |
| macOS 14+ | Native development target for the Swift package |
| Linux | Supported in CI and local terminal workflows; on Ubuntu/Debian install `libsqlite3-dev` |

### 1. Start the Core runtime

```bash
swift run Core
```

Notes:

- On first start, Sloppy creates a workspace layout and a default `sloppy.json` config if one does not exist.
- OpenAI-backed model flows require `OPENAI_API_KEY`.
- Ollama-backed flows use the local Ollama endpoint by default.

### 2. Start the dashboard

```bash
cd Dashboard
npm install
npm run dev
```

### More build guides

- Terminal build and local development: [docs/guides/build-from-terminal.md](docs/guides/build-from-terminal.md)
- Docker build and Docker Compose workflow: [docs/guides/build-with-docker.md](docs/guides/build-with-docker.md)
- Development workflow and project rules: [docs/guides/development-workflow.md](docs/guides/development-workflow.md)

## FAQ

### Do I need an API key to run Sloppy?

No. The runtime, tests, and dashboard can run without OpenAI credentials. You only need `OPENAI_API_KEY` for OpenAI-backed model execution.

### Where does Sloppy store data?

The default runtime uses SQLite for persistence. Workspace data, logs, artifacts, and related runtime files are created under the configured workspace root.

### Can I use a local model instead of OpenAI?

Yes. The project includes an `AnyLanguageModel` bridge and documents Ollama as a supported local path.

### Does Sloppy support Linux?

Yes. Linux is part of the active build matrix in CI. For direct terminal builds on Ubuntu/Debian-based systems, install `libsqlite3-dev` before running the Swift commands.

### Is Telegram supported?

Yes. The repository includes a Telegram channel plugin that maps Telegram chats to Sloppy channels and forwards inbound and outbound messages.

### Is the desktop app production-ready?

Not yet. `Sources/App` exists, but the current MVP path is centered on `Core` and `Dashboard`.

### Where can I read more about the runtime model?

See the specs in [docs/specs/runtime-v1.md](/Users/vprusakov/.codex/worktrees/6dcd/Sloppy/docs/specs/runtime-v1.md) and [docs/specs/prd-runtime-v1.md](/Users/vprusakov/.codex/worktrees/6dcd/Sloppy/docs/specs/prd-runtime-v1.md).

## Contributing

Contributions should stay aligned with the current architecture, validation steps, and repository rules.

Start here:

- Build and run locally: [docs/guides/build-from-terminal.md](docs/guides/build-from-terminal.md)
- Docker workflow: [docs/guides/build-with-docker.md](docs/guides/build-with-docker.md)
- Detailed development workflow and project conventions: [docs/guides/development-workflow.md](docs/guides/development-workflow.md)

## License

Sloppy is released under the MIT License. See [LICENSE](LICENSE).

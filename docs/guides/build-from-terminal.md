---
layout: doc
title: Build From Terminal
---

# Build From Terminal

This guide covers the direct local workflow for building and running Sloppy without Docker.

## Supported environments

| Platform | Status | Notes |
| --- | --- | --- |
| macOS 14+ | Supported | Primary local development environment |
| Linux | Supported | CI runs on Ubuntu with Swift 6.2 and `libsqlite3-dev` |

## Prerequisites

### Swift runtime

- Swift 6 toolchain
- `sqlite3` runtime available on the machine

### Dashboard runtime

- Node.js
- npm

### Linux packages

On Ubuntu or Debian-based systems, install the SQLite development headers before building:

```bash
sudo apt-get update
sudo apt-get install -y libsqlite3-dev
```

## Resolve dependencies

From the repository root:

```bash
swift package resolve
```

## Build the Swift targets

Development build:

```bash
swift build
```

Release builds:

```bash
swift build -c release --product Core
swift build -c release --product Node
swift build -c release --product App
```

## Run the Swift targets

Start the core runtime:

```bash
swift run Core
```

Useful runtime variants:

```bash
swift run Core --oneshot
swift run Core --run-demo-request
swift run Core --config-path sloppy.json
```

Run the other executables when needed:

```bash
swift run Node
swift run App
```

## Run the Swift tests

Full suite:

```bash
swift test --parallel
```

Run a single test or group:

```bash
swift test --filter CoreTests.postChannelMessageEndpoint
swift test --filter CoreTests
swift test --filter AgentRuntimeTests
```

List tests:

```bash
swift test list
```

## Run the dashboard

From `Dashboard/`:

```bash
npm install
npm run dev
```

Production build:

```bash
npm run build
```

Preview the production bundle:

```bash
npm run preview
```

## Typical local development loop

1. Start `Core` from the repository root with `swift run Core`.
2. Start the dashboard from `Dashboard/` with `npm run dev`.
3. Make a focused code change.
4. Run the smallest relevant verification first.
5. Before opening a PR, run the CI-parity checks listed below.

## CI-parity checks

These are the commands the repository expects contributors to keep green:

```bash
swift test --parallel
swift build -c release --product Core
swift build -c release --product Node
swift build -c release --product App
cd Dashboard
npm install
npm run build
```

## Notes

- On first `swift run Core`, Sloppy can create a workspace layout and a default `sloppy.json`.
- The generated config includes `visor.scheduler.enabled`, `visor.scheduler.intervalSeconds`, `visor.scheduler.jitterSeconds`, and `visor.bootstrapBulletin`.
- OpenAI-backed model execution requires `OPENAI_API_KEY`.
- Agent web search can use `BRAVE_API_KEY` or `PERPLEXITY_API_KEY`; environment values take precedence over `sloppy.json` `searchTools` keys.
- Ollama uses the local endpoint by default.

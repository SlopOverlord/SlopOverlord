# SlopOverlord Runtime v1

Multi-agent runtime skeleton in Swift 6.2 with Channel/Branch/Worker architecture, Core API router, Node daemon, Dashboard, docs, and Docker compose.

Includes `AnyLanguageModel` integration for agent responses via `PluginSDK.AnyLanguageModelProviderPlugin` (OpenAI/Ollama).

## Quick start

1. Run tests:
   - `swift test`
2. Run Core demo flow:
   - `swift run Core`
   - Optional: set `OPENAI_API_KEY` for OpenAI-backed channel responses
3. Start dashboard (after npm install):
   - `cd Dashboard && npm install && npm run dev`

## Repo layout

- `/Sources/Core` Core service/router/persistence
- `/Sources/Node` node daemon process executor
- `/Sources/App` desktop app placeholder
- `/Sources/PluginSDK` plugin interfaces
- `/Sources/AgentRuntime` channel/branch/worker runtime
- `/Sources/Protocols` shared protocol types
- `/Dashboard` React dashboard
- `/Demos` examples
- `/docs/adr` architecture decisions
- `/docs/specs` protocol/runtime specs
- `/utils/docker` compose and Dockerfiles

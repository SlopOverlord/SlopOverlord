# SlopOverlord Runtime v1

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/SlopOverlord/SlopOverlord)

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

## Documentation

Static docs are generated from `docs/` with `VitePress`, using the same palette and surface hierarchy as the Dashboard.

Local build:

- `cd docs`
- `npm install`
- `npm run dev`
- `npm run build`

GitLab CI publishes the generated `docs/.vitepress/dist/` site to GitHub Pages from the default branch.

Required GitLab CI variables:

- `GITHUB_PAGES_TOKEN`: GitHub token with permission to push to the Pages branch.
- `GITHUB_PAGES_REPOSITORY`: target repository in one of these formats: `owner/repo`, `owner/repo.git`, or `github.com/owner/repo.git`.

Optional GitLab CI variables:

- `GITHUB_PAGES_BRANCH`: target branch for published docs. Default: `gh-pages`.
- `GITHUB_PAGES_CNAME`: custom domain written to `CNAME`.
- `GITHUB_PAGES_AUTHOR_NAME`: git author name for publish commits.
- `GITHUB_PAGES_AUTHOR_EMAIL`: git author email for publish commits.

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

# AGENTS.md

Guidance for coding agents working in this repository.
Project type: Swift Package (Swift 6.x) + React/Vite dashboard.

## Scope and stack
- Package manager: SwiftPM (`Package.swift`)
- Swift platform: macOS 14+
- Executables: `Core`, `Node`, `App`
- Libraries: `Protocols`, `PluginSDK`, `AgentRuntime`
- Dashboard: `Dashboard/` (`react`, `vite`)
- Persistence: SQLite (`sqlite3`)
- Test framework: Swift Testing (`import Testing`, `@Test`, `#expect`)

## Build, lint, test, run
Run from repo root unless noted.

### Resolve dependencies
- `swift package resolve`

### Build (Swift)
- `swift build`
- `swift build -c release`
- `swift build -c release --product Core`
- `swift build -c release --product Node`
- `swift build -c release --product App`

### Test (Swift)
- Full suite: `swift test`
- Parallel suite: `swift test --parallel`
- List tests: `swift test list`

### Run a single Swift test (important)
- By exact name:
  - `swift test --filter CoreTests.postChannelMessageEndpoint`
- By test group:
  - `swift test --filter CoreTests`
  - `swift test --filter AgentRuntimeTests`
- Note: `swift test --list-tests` is deprecated; use `swift test list`.

### Run executables
- `swift run Core`
- `swift run Node`
- `swift run App`

Useful `Core` flags:
- `swift run Core --oneshot`
- `swift run Core --run-demo-request`
- `swift run Core --config-path slopoverlord.config.json`

### Dashboard commands (inside `Dashboard/`)
- `npm install`
- `npm run dev`
- `npm run build`
- `npm run preview`

### Lint/format status
No dedicated lint/format config is committed for SwiftLint, swift-format, ESLint, or Prettier.
When changing code, preserve local style and validate with:
- `swift test --parallel`
- `swift build -c release --product Core`
- `npm run build` (when dashboard files change)

## CI parity checklist
CI (`.github/workflows/ci.yml`) runs:
- `swift test --parallel`
- `swift build -c release --product Core`
- `swift build -c release --product Node`
- `swift build -c release --product App`
- `npm install` + `npm run build` in `Dashboard/`
Keep local changes green for the same command set.

## Code style guide

### Swift: imports and formatting
- Use 4-space indentation and no tabs.
- Keep imports minimal; place `Foundation` first when used.
- Follow existing multiline style and trailing commas.
- Keep files focused; extract helpers instead of large monolith methods.

### Swift: types and naming
- `UpperCamelCase` for types; `lowerCamelCase` for vars/functions.
- Prefer `struct` for DTO/protocol models; use `actor` for shared mutable state.
- Mark cross-target API explicitly with `public`.
- Add `Sendable` where values cross concurrency boundaries.
- Use enums for constrained state/actions (`RouteAction`, `WorkerMode`, etc.).
- For API-compatible values, use explicit raw values (snake_case when needed).

### Swift: error handling and resilience
- Use `throws` for recoverable boundary failures.
- In router/http boundaries, convert invalid payloads to stable 4xx responses.
- Prefer graceful fallback over crashing in runtime services.
- Avoid force unwraps and `fatalError` in production paths.
- Log operational failures with context and continue when safe.

### Swift: concurrency and architecture
- Prefer actor isolation to locking.
- Keep orchestration async end-to-end (`async`/`await`).
- Do not bypass actor boundaries with shared mutable globals.
- Maintain separation: transport (`CoreHTTPServer`) -> routing (`CoreRouter`) -> service (`CoreService`) -> runtime (`AgentRuntime`) -> persistence (`SQLiteStore`).

### Tests
- Use Swift Testing macros (`@Test`, `#expect`).
- Write behavior-focused tests with clear arrange/act/assert flow.
- Keep tests deterministic and isolated.
- For endpoint logic, test via router/service with realistic payloads.

### Dashboard (React)
- Use function components and hooks.
- Use named exports for components/utilities.
- Keep state local; derive computed values with `useMemo` when useful.
- Use `async/await` and handle non-OK responses explicitly.
- Match existing JS formatting: 2-space indent, semicolons, double quotes.

## Module map

### Swift targets
- `Sources/Protocols`
  - Shared domain and wire models (`APIModels`, `RuntimeModels`, JSON helpers, envelopes).
  - Base dependency for all runtime-facing modules.
- `Sources/PluginSDK`
  - Plugin contracts (`GatewayPlugin`, `ToolPlugin`, `MemoryPlugin`, `ModelProviderPlugin`).
  - AnyLanguageModel bridge implementation.
- `Sources/AgentRuntime`
  - Runtime actors and orchestration core.
  - Includes channel/worker/branch runtimes, compactor, visor, event bus, memory store, and `RuntimeSystem` facade.
- `Sources/Core`
  - Main backend executable and HTTP API server.
  - Includes config loading, router, service layer, NIO transport, and SQLite persistence.
- `Sources/Node`
  - Node daemon executable for process execution.
- `Sources/App`
  - App placeholder executable.

### Tests
- `Tests/ProtocolsTests`: protocol/model coding and compatibility.
- `Tests/AgentRuntimeTests`: routing and runtime flow.
- `Tests/CoreTests`: API/router/config behaviors.

### Frontend/docs/support
- `Dashboard/`: React dashboard for Core API.
- `docs/specs/`: protocol/runtime specs.
- `docs/adr/`: architecture decisions.
- `Demos/`: quickstart/sample payloads.
- `utils/docker/`: Dockerfiles and compose assets.

## Cursor/Copilot rules status
Checked these locations:
- `.cursorrules`
- `.cursor/rules/`
- `.github/copilot-instructions.md`
Current state: no Cursor/Copilot rule files are present.
If added later, treat them as higher-priority repository policy and update this file.

## Agent execution expectations
- Make small, targeted edits aligned with existing module boundaries.
- Avoid introducing new frameworks without strong justification.
- Keep API behavior backward-compatible unless task explicitly allows breaking change.
- Update/add tests when changing behavior.
- Run the smallest relevant verification first, then CI-parity checks.

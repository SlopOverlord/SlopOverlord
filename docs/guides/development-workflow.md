---
layout: doc
title: Development Workflow
---

# Development Workflow

This guide explains how to work on Sloppy in development and which repository rules contributors are expected to follow.

## Project structure

| Path | Responsibility |
| --- | --- |
| `Sources/Core` | Backend executable, HTTP server, routing, orchestration, config, persistence |
| `Sources/AgentRuntime` | Runtime actors and orchestration for channels, branches, workers, compactor, and visor |
| `Sources/Protocols` | Shared wire models and JSON helpers |
| `Sources/PluginSDK` | Plugin contracts for models, tools, memory, and gateways |
| `Sources/Node` | Node daemon executable |
| `Sources/App` | App executable placeholder |
| `Sources/ChannelPluginTelegram` | Telegram gateway integration |
| `Dashboard/` | React/Vite frontend |
| `Tests/` | Swift Testing suites |
| `docs/` | VitePress documentation, specs, and ADRs |

## Development setup

Pick one of the build guides first:

- [Build From Terminal](./build-from-terminal.md)
- [Build With Docker](./build-with-docker.md)

For day-to-day development, direct terminal builds are the default path because they give a faster feedback loop.

## Core development rules

### Architecture boundaries

- Keep transport, routing, services, runtime, and persistence separated.
- Preserve the flow `CoreHTTPServer -> CoreRouter -> CoreService -> AgentRuntime -> SQLiteStore`.
- Do not collapse multiple responsibilities into one large type when the repository already has a boundary for that concern.

### Swift conventions

- Use 4-space indentation.
- Keep imports minimal and put `Foundation` first when used.
- Prefer focused files and small helpers over long monolithic methods.
- Use `struct` for DTO-style data and `actor` for shared mutable state.
- Mark cross-target API as `public` when it must be consumed by another target.
- Add `Sendable` when values cross concurrency boundaries.
- Avoid force unwraps and `fatalError` in production code paths.

### Concurrency rules

- Prefer actor isolation instead of manual locking.
- Keep async flows `async`/`await` end to end.
- Do not bypass actor boundaries with shared mutable globals.
- Handle operational failures gracefully and log useful context.

### API and runtime behavior

- Keep public behavior backward-compatible unless a change explicitly allows breakage.
- Convert invalid HTTP payloads into stable 4xx responses.
- Prefer concise structured runtime payloads over large opaque blobs.
- Keep branch results concise: return conclusions and references instead of dumping full transcripts.

### Frontend conventions

- Use function components and hooks.
- Prefer named exports for components and utilities.
- Keep local state local and derive computed values when helpful.
- Use `async/await` and handle non-OK responses explicitly.
- Match the existing frontend style: 2-space indent, semicolons, and double quotes.

## Testing expectations

When behavior changes, update or add tests.

Use Swift Testing:

- `import Testing`
- `@Test`
- `#expect`

Testing guidance:

- Favor behavior-focused tests with clear arrange / act / assert flow.
- Keep tests deterministic and isolated.
- For endpoint logic, test through router or service layers with realistic payloads.

## Validation strategy

Run the smallest relevant checks first, then move to broader validation.

### Smallest relevant checks

Examples:

```bash
swift test --filter CoreTests
swift test --filter AgentRuntimeTests
swift build -c release --product Core
```

For dashboard work:

```bash
cd Dashboard
npm run build
```

### CI-parity validation

Before opening a PR, run:

```bash
swift test --parallel
swift build -c release --product Core
swift build -c release --product Node
swift build -c release --product App
cd Dashboard
npm install
npm run build
```

## Recommended contribution flow

1. Create a focused branch for one change.
2. Read the surrounding module before editing it.
3. Keep the change small and aligned with existing patterns.
4. Add or update tests if behavior changed.
5. Run the smallest relevant checks.
6. Run CI-parity validation before opening a PR.

## Documentation expectations

- Update `README.md` when the project entry point or positioning changes.
- Update `docs/specs/` when protocol or runtime behavior changes.
- Add or update ADRs when an architectural decision needs durable rationale.
- Keep docs aligned with the actual commands, targets, and files in the repository.

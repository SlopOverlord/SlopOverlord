# Runtime v1 Gap Analysis (Spec vs Current Project)

## Scope
Comparison baseline:
- Architecture document "Runtime v1: Channel/Branch/Worker"
- Current repository state as of `2026-03-03`

Verification sources:
- Code in `Sources/*`, `Dashboard/*`, `docs/specs/*`
- Tests in `Tests/*`
- Local test runs:
  - `swift test --filter RuntimeFlowTests`
  - `swift test --filter VisorTodoLoopTests`

## Executive Summary
- Core architecture skeleton is implemented and running.
- Most protocol/API blocks are already in place.
- Main gaps are in production semantics, periodic operations, persistence completeness, and token-economy enforcement.

High-level status:
- `Done`: 17
- `Partial`: 10
- `Not started`: 3

## Detailed Comparison

### 1. Runtime entities
1. `Channel`: `Done`
- Implemented: message ingest, route decision, worker attach/detach, snapshots.
- Evidence: `Sources/AgentRuntime/ChannelRuntime.swift`.
2. `Branch`: `Done`
- Implemented: spawn, memory recall/save, conclude, ephemeral branch state.
- Evidence: `Sources/AgentRuntime/BranchRuntime.swift`.
3. `Worker`: `Partial`
- Implemented: both modes, route bridge, events, artifact emission.
- Gap: real tool execution model is limited; current execution path is mostly simplified and heuristic.
- Evidence: `Sources/AgentRuntime/WorkerRuntime.swift`.
4. `Compactor`: `Partial`
- Implemented: threshold logic `80/85/95`, events, summary-apply flow.
- Gap: no real async job queue/backpressure; summary is applied immediately via simplified path.
- Evidence: `Sources/AgentRuntime/Compactor.swift`.
5. `Visor`: `Done`
- Implemented: bulletin generation, memory publish, channel digest, periodic scheduler loop, and boot-time bulletin control via config/CLI override.
- Evidence: `Sources/AgentRuntime/Visor.swift`, `Sources/Core/CoreService.swift`, `Sources/Core/VisorScheduler.swift`, `Sources/Core/CoreMain.swift`.

### 2. Protocol and types
1. New protocol types in `Protocols`: `Done`
- Present: `ChannelRouteDecision`, `BranchConclusion`, `WorkerTaskSpec`, `CompactionJob`, `MemoryBulletin`, `ArtifactRef`, `MemoryRef`, `TokenUsage`.
- Evidence: `Sources/Protocols/RuntimeModels.swift`.
2. Envelope v1: `Done`
- All required fields present.
- Evidence: `Sources/Protocols/EventEnvelope.swift`.
3. Message types list: `Done (+ additive)`
- All required types are present.
- Additional additive types also exist (`actor.discussion.*`).
- Evidence: `Sources/Protocols/EventEnvelope.swift`.

### 3. Public API
All requested endpoints are implemented: `Done`
- `POST /v1/channels/{id}/messages`
- `POST /v1/channels/{id}/route/{workerId}`
- `GET /v1/channels/{id}/state`
- `GET /v1/bulletins`
- `POST /v1/workers`
- `GET /v1/artifacts/{id}/content`
- Evidence: `Sources/Core/CoreRouter.swift`, `Sources/Core/CoreService.swift`.

### 4. Policies
1. Rule-based routing: `Done`
- Evidence: `ChannelRuntime.decideRoute`.
2. Branch persistence ephemeral: `Done`
- Branch state removed on conclusion; transcript persistence not implemented as full branch log.
- Evidence: `Sources/AgentRuntime/BranchRuntime.swift`.
3. Bulletin delivery to memory + channel digest: `Done`
- Evidence: `Visor.generateBulletin`, `RuntimeSystem.generateVisorBulletin`.
4. Token economy via typed payload + refs: `Partial`
- Typed payload and refs exist.
- Gap: no enforced payload budget test/guardrail; token usage persistence path exists but is not called.
- Evidence: `Sources/Protocols/*`, `Sources/Core/PersistenceStore.swift`, `Sources/Core/SQLiteStore.swift`.
5. Backward compatibility additive: `Partial`
- Struct model is additive-friendly and unknown JSON fields are ignored by default decoder behavior.
- Gap: no explicit compatibility test for unknown fields and schema evolution policy checks.

### 5. MVP work plan status
1. `protocol-v1.md`: `Done`
- Evidence: `docs/specs/protocol-v1.md`.
2. Event bus + broadcast: `Done`
- Evidence: `Sources/AgentRuntime/EventBus.swift`, `CoreService.startEventPersistence`.
3. Channel state machine + routing: `Done`
- Evidence: `Sources/AgentRuntime/ChannelRuntime.swift`.
4. Branch lifecycle + memory adapter: `Done`
- Evidence: `Sources/AgentRuntime/BranchRuntime.swift`, `Sources/AgentRuntime/MemoryStore.swift`.
5. Worker lifecycle + route bridge: `Partial`
- Core flow exists, but execution semantics are simplified.
6. Compactor thresholds + background jobs: `Partial`
- Threshold logic exists; production-grade background scheduling is missing.
7. Visor bulletin pipeline: `Done`
- Pipeline includes periodic scheduling plus manual trigger paths.
8. Dashboard slice (chat/tasks/artifacts/feed): `Partial`
- Chat/artifacts/bulletins/workers are visible.
- Gap: activity feed is not full event feed; branch/worker timeline granularity is limited.
- Evidence: `Dashboard/src/views/RuntimeOverviewView.jsx`, `Dashboard/src/features/runtime-overview/model/useRuntimeOverview.ts`.
9. SQLite schema: `Partial`
- Required tables exist in schema.
- Gap: `channels`, `tasks`, `token_usage` tables are not fully integrated into runtime persistence flow.
- Evidence: `Sources/Core/Storage/schema.sql`, `Sources/Core/SQLiteStore.swift`.
10. Docker Compose for `core + dashboard`: `Done`
- Evidence: `utils/docker/docker-compose.yml`.

### 6. Acceptance scenarios
1. Channel -> Branch -> Worker -> conclusion-only return: `Partial`
- Behavior exists in runtime path.
- Gap: no dedicated acceptance test asserting "only conclusion + refs" contract end-to-end.
2. Interactive worker route handling: `Done`
- Covered in tests.
3. Compactor 80/85/95 behavior: `Done`
- Covered in tests for threshold transitions.
4. Periodic visor bulletin + memory + digest: `Done`
- Memory persistence, digest delivery, and periodic scheduling are covered.
5. Token regression limit test: `Not started`
- No dedicated regression tests for payload/token envelope size.
6. Recovery after restart (channels/tasks/events/artifacts): `Partial`
- Some persistence exists; runtime state rehydration for channels/workers is not implemented end-to-end.

## What is already validated by tests
1. Runtime flow:
- route decision, interactive route completion, compactor thresholds, branch ephemerality, bulletin creation.
- Evidence: `Tests/AgentRuntimeTests/RuntimeFlowTests.swift`.
2. Core orchestration around visor/task lifecycle:
- todo extraction, auto-worker spawn, worker complete/fail transitions, actor delegation.
- Evidence: `Tests/CoreTests/VisorTodoLoopTests.swift`.
3. API endpoints:
- channel messages/state, workers, bulletins, artifacts, project/task CRUD and more.
- Evidence: `Tests/CoreTests/CoreRouterTests.swift`.

## Priority Gaps

### P0 (before marking v1 complete)
1. Wire token usage persistence (`persistTokenUsage`) into runtime event flow and add reporting endpoint/test.
2. Add explicit token/payload regression test with concrete threshold and failure condition.
3. Implement runtime recovery path for channels/tasks/events/artifacts after Core restart, with acceptance test.

### P1
1. Replace simplified worker execution with pluggable execution backends/tools abstraction for runtime workers.
2. Add dedicated activity/event feed endpoint for Dashboard (`events` timeline by channel/task).
3. Add explicit compatibility tests for unknown fields and additive schema evolution.

### P2
1. Integrate compaction jobs with queued background worker scheduling and retry policy.
2. Add richer branch conclusion schema validation and UX surfacing.

## Suggested next implementation batch
1. `VisorScheduler` actor (periodic trigger + jitter + backoff) in `AgentRuntime`.
2. `TokenUsageCollector` integration in `CoreService.startEventPersistence`.
3. `GET /v1/events` or `GET /v1/channels/{id}/events` for feed-grade timeline.
4. `RecoveryManager` to rebuild channel snapshots from persisted events.

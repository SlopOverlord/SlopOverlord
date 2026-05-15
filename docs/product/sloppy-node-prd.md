# PRD: SloppyNode Vision

Status: Internal draft for maintainers and coding agents  
Date: 2026-05-14  
Audience: Sloppy maintainers and repository-aware agents  
Public docs: Excluded from VitePress via `srcExclude`

## 1. Executive Summary

- **Problem Statement**: Sloppy needs a local executor that can perform machine-facing actions such as process execution, clicks, typing, key events, and screenshots without coupling every client directly to platform APIs. The boundary must be small, auditable, and portable across Sloppy core, standalone helpers, and future clients.
- **Proposed Solution**: Keep `SloppyNode` as a narrow JSON action executor built on `SloppyNodeCore.NodeDaemon` and `SloppyComputerControl`, with a stable request/response protocol in `Protocols` and platform-specific implementation hidden behind `ComputerControlling`.
- **Success Criteria**:
  - `swift test --filter SloppyNodeCoreTests` and `swift build -c release --product SloppyNode` pass before node behavior changes merge.
  - Every action returns `NodeActionResponse` with `ok`, `data`, or `NodeActionError`; no caller needs to parse stderr for control flow.
  - Unsupported platforms return structured `unsupported_platform` errors for computer-control actions.
  - macOS permission failures return structured `permission_denied` errors with actionable messages.
  - The standalone `sloppy-node invoke --stdin` path round-trips status, computer-control payloads, and screenshots through JSON.

## 2. User Experience & Functionality

- **User Personas**:
  - Maintainer: evolves local-control behavior while preserving protocol compatibility.
  - Coding agent: invokes local actions through explicit tools or process requests and receives structured results.
  - Desktop operator: grants macOS permissions once and expects reliable local control from Sloppy.
  - Client developer: bundles or discovers a node helper without reimplementing computer-control primitives.

- **User Stories**:
  - As a maintainer, I want all node actions represented by `NodeAction` so that clients can rely on a stable protocol.
  - As a coding agent, I want click, type, key, screenshot, and exec actions to return structured success or failure so that I can recover safely.
  - As a desktop operator, I want permission errors to identify missing Accessibility, Input Monitoring, or Screen Recording access so that setup is fixable.
  - As a client developer, I want a standalone process boundary so that Apple client, helpers, and external integrations can call local control without linking core server code.
  - As a maintainer, I want platform differences isolated in `SloppyComputerControl` so that Linux, Windows, and macOS behavior can be tested independently.

- **Acceptance Criteria**:
  - `NodeActionRequest` decodes a typed `action` and JSON `payload`.
  - `NodeActionResponse.success` includes action identity and encoded data.
  - `NodeActionResponse.failure` includes action identity, stable error code, human-readable message, and retryable flag.
  - `status` returns `nodeId`, `state`, and `platform`.
  - `exec` executes the requested command and arguments, then returns command, arguments, exit code, stdout, and stderr.
  - `computer.click` validates non-negative finite coordinates and positive optional width/height before invoking platform control.
  - `computer.typeText`, `computer.key`, and `computer.screenshot` decode payloads through `JSONValueCoder`.
  - The CLI writes only the sorted JSON response to stdout for successful decode paths and reports invalid input as `invalid_json`.
  - Built-in Sloppy computer tools can use in-process control by default or force the standalone node with `SLOPPY_NODE_PATH`.

- **Non-Goals**:
  - Do not make SloppyNode an autonomous agent runtime.
  - Do not add natural-language command interpretation inside SloppyNode.
  - Do not make the standalone node own long-lived task orchestration or scheduling in this scope.
  - Do not hide platform permission errors behind generic failure messages.
  - Do not expose unrestricted remote control without an explicit auth, pairing, or transport design.

## 3. AI System Requirements

- **Tool Requirements**:
  - Agent-visible computer tools map onto typed node actions: `computer.click`, `computer.type`, `computer.key`, and `computer.screenshot`.
  - Tool callers must pass structured coordinates, text, key descriptors, and screenshot options rather than free-form instructions.
  - The node protocol must remain deterministic enough for agents to inspect `ok`, `error.code`, and returned data fields.
  - Future remote-node support must preserve the same action envelope or provide a versioned adapter.

- **Evaluation Strategy**:
  - Protocol tests verify JSON round trips for `NodeActionRequest`, success responses, failure responses, and screenshot payloads.
  - Core tests use `FakeComputerController` to verify node behavior without requiring OS permissions.
  - Platform tests should verify unsupported-platform and permission-denied mappings where CI can exercise them.
  - CLI smoke tests should pipe a status request into `SloppyNode invoke --stdin` and assert valid JSON output.
  - Agent tool tests should assert structured errors and successful mapping without parsing localized OS strings.

## 4. Technical Specifications

- **Architecture Overview**:
  - `Sources/Protocols/NodeControlModels.swift` defines `NodeAction`, `NodeActionRequest`, `NodeActionResponse`, `NodeActionError`, and shared payload aliases.
  - `Sources/NodeCore/NodeDaemon.swift` owns action dispatch, node state, heartbeat timestamps, process execution, and controller calls.
  - `Packages/SloppyComputerControl` owns `ComputerControlling`, payload validation, platform names, and platform-specific input/screenshot code.
  - `Sources/Node/NodeMain.swift` wraps `NodeDaemon` as the standalone `sloppy-node` executable with `invoke --stdin`.
  - Sloppy core may call `SloppyComputerControl` in-process for low latency, while `SLOPPY_NODE_PATH` keeps the process boundary available.

- **Integration Points**:
  - `NodeAction` raw values are the public protocol surface: `exec`, `computer.click`, `computer.typeText`, `computer.key`, `computer.screenshot`, and `status`.
  - `NodeDaemon.invoke(_:)` is the single dispatch point for action execution.
  - `ComputerControlError.code` maps to stable node error codes: `invalid_arguments`, `unsupported_platform`, `permission_denied`, and `operation_failed`.
  - Install and guide docs live under public guides; this product document remains internal and excluded from VitePress output.
  - CI-relevant targets are `ProtocolsTests`, `SloppyNodeCoreTests`, and the `SloppyNode` product build.

- **Security & Privacy**:
  - `exec` is powerful and must stay behind explicit local invocation, tool approval, or future auth boundaries.
  - Screenshot results can contain sensitive display contents and should be returned as explicit data/path objects, not silently persisted into public logs.
  - macOS permission guidance must identify the exact binary or launcher that needs Accessibility, Input Monitoring, and Screen Recording access.
  - Future remote transports must include pairing, authentication, auditability, and clear user consent before accepting computer-control actions.
  - Error messages should be actionable but avoid dumping sensitive environment data.

## 5. Risks & Roadmap

- **Phased Rollout**:
  - MVP: maintain the current stdin/stdout JSON protocol, `NodeDaemon` dispatch, process execution, platform computer-control actions, and structured errors.
  - v1.1: add protocol versioning and capability discovery so clients can ask which actions and platforms are available.
  - v1.2: improve installation and permission diagnostics with a dedicated health-check action that reports missing macOS entitlements or Windows session limitations.
  - v2.0: design optional authenticated remote-node transport while preserving the local JSON action contract.

- **Technical Risks**:
  - `exec` can become an unsafe remote primitive if exposed through future transports without authorization and audit logs.
  - Platform APIs can fail for OS-policy reasons that are hard to reproduce in CI.
  - Screenshot payloads can become too large if the protocol grows to inline image data by default.
  - CLI stdout must remain machine-readable; logging must stay off stdout for `invoke`.
  - Windows and macOS input systems have interactive-session constraints that can make headless testing misleading.
  - Adding new actions without protocol tests can silently break downstream clients.

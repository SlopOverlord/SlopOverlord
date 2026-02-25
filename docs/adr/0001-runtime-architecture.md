# ADR-0001: Channel/Branch/Worker Runtime

## Status
Accepted

## Context
Need token-efficient multi-agent runtime with deterministic handoff and review flow.

## Decision
Use control-plane protocol with typed payloads and artifact/memory references.

## Consequences
- Better observability and scaling by event log.
- Reduced token usage due to short payloads.
- Must maintain schema compatibility across releases.

# Protocol v1

## Envelope
All control-plane events use JSON envelope:

```json
{
  "protocolVersion": "1.0",
  "messageId": "uuid",
  "messageType": "channel.route.decided",
  "ts": "2026-02-25T18:00:00Z",
  "traceId": "uuid",
  "channelId": "general",
  "taskId": "optional",
  "branchId": "optional",
  "workerId": "optional",
  "payload": {},
  "extensions": {}
}
```

## Message Types
- `channel.message.received`
- `channel.route.decided`
- `branch.spawned`
- `branch.conclusion`
- `worker.spawned`
- `worker.progress`
- `worker.completed`
- `worker.failed`
- `compactor.threshold.hit`
- `compactor.summary.applied`
- `visor.bulletin.generated`

## Core Policies
- Routing: rule-based thresholds and keyword heuristics.
- Branch persistence: ephemeral; only conclusion and references survive.
- Compactor thresholds: `>80%` soft, `>85%` aggressive, `>95%` emergency.
- Compatibility: additive changes only; unknown fields ignored.

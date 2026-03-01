# Channel Plugin Protocol v1

Channel plugins are **external processes** that bridge SlopOverlord channels to
messaging platforms (Telegram, Slack, email, etc.). Communication between Core
and each plugin uses plain HTTP/JSON — the plugin can be written in any language.

## Lifecycle

1. Plugin process starts (manually or spawned by Core).
2. Plugin reads its configuration from environment variables, CLI arguments, or
   receives it via `POST /start` from Core.
3. Plugin begins listening for inbound messages from its platform (e.g. Telegram
   long-polling) and accepts outbound delivery requests from Core.

## Inbound (platform → Core)

When the plugin receives a user message from the external platform it forwards
it to Core using the standard channel message endpoint:

```
POST {CORE_BASE_URL}/v1/channels/{channelId}/messages
Content-Type: application/json

{
  "userId": "<platform-specific user id>",
  "content": "<message text>"
}
```

`channelId` is the SlopOverlord channel identifier mapped to this external chat
in the plugin configuration.

## Outbound (Core → plugin)

Core delivers messages to the plugin by calling:

```
POST {plugin_base_url}/deliver
Content-Type: application/json

{
  "channelId": "<slopoverlord channel id>",
  "userId": "<recipient hint — may be empty for broadcast>",
  "content": "<message text>"
}
```

Response: `200 OK` with `{ "ok": true }` on success, or an appropriate error
status. Core logs failures but does not retry automatically in v1.

## Optional endpoints

### Validate

Core may call this **before** accepting an inbound message to let the plugin
decide whether the sender is allowed:

```
POST {plugin_base_url}/validate
Content-Type: application/json

{
  "channelId": "...",
  "userId": "...",
  "content": "..."
}
```

Response:

```json
{ "allowed": true }
```

or

```json
{ "allowed": false, "reason": "user not in allow list" }
```

If the endpoint is not implemented (404/501) Core treats the message as allowed.

### Start

Core may push configuration to the plugin at startup:

```
POST {plugin_base_url}/start
Content-Type: application/json

{
  "pluginId": "...",
  "channelIds": ["..."],
  "config": { "botToken": "...", "allowedUserIds": [...], ... }
}
```

The plugin should apply the received configuration and return `200 OK`.

## Plugin registration

Plugins are registered in Core via the `/v1/plugins` REST API or seeded from
the Core configuration file. Each registration record contains:

| Field        | Type     | Description                                      |
|-------------|----------|--------------------------------------------------|
| id          | string   | Unique plugin identifier (auto-generated or set) |
| type        | string   | Plugin kind, e.g. `"telegram"`, `"slack"`        |
| baseUrl     | string   | Root URL of the plugin HTTP server               |
| channelIds  | [string] | SlopOverlord channel IDs served by this plugin   |
| config      | object   | Arbitrary settings (tokens, allow-lists, etc.)   |
| enabled     | bool     | Whether Core should deliver to this plugin       |
| createdAt   | ISO 8601 | Creation timestamp                               |
| updatedAt   | ISO 8601 | Last update timestamp                            |

## Commands

Plugins may intercept platform-specific commands (e.g. `/task`, `/status`) and
either translate them into regular `content` for Core or handle them locally.
The set of supported commands is plugin-specific and should be documented per
plugin.

## Compatibility

- All payloads are JSON, UTF-8 encoded.
- Unknown fields must be ignored by both sides.
- Additive changes only; breaking changes require a version bump.

---
layout: doc
title: Plugins
---

# Plugins

Sloppy is built around a plugin system that allows you to extend its capabilities without modifying the core runtime. There are four plugin types, each targeting a different integration point, and two delivery modes: in-process Swift plugins and out-of-process HTTP plugins.

## Plugin types

| Type | Protocol | Purpose |
| --- | --- | --- |
| Gateway | `GatewayPlugin` | Bridge an external messaging platform to Sloppy channels |
| Tool | `ToolPlugin` | Expose custom tools (actions) to the agent runtime |
| Memory | `MemoryPlugin` | Add a custom memory backend for recall and save operations |
| Model Provider | `ModelProvider` | Integrate a new LLM backend |

All plugin protocols are defined in the `PluginSDK` library (`Sources/PluginSDK/PluginProtocols.swift`).

## Delivery modes

| Mode | Language | Loading mechanism |
| --- | --- | --- |
| In-process (bundled) | Swift | Linked at compile time via SwiftPM |
| In-process (external) | Swift | Loaded at runtime via `dlopen` |
| Out-of-process | Any | HTTP/JSON protocol over a local server |

---

## GatewayPlugin

A gateway plugin bridges an external messaging platform (Telegram, Discord, Slack, custom bots, etc.) to Sloppy channels. The core runtime calls the plugin to deliver outbound messages and the plugin calls back into Sloppy to deliver inbound messages.

### Protocol

```swift
public protocol GatewayPlugin: Sendable {
    var id: String { get }
    var channelIds: [String] { get }

    func start(inboundReceiver: any InboundMessageReceiver) async throws
    func stop() async
    func send(channelId: String, message: String) async throws
}
```

`channelIds` declares which Sloppy channel IDs this plugin handles. On startup, `start(inboundReceiver:)` is called with a receiver that the plugin uses to forward inbound messages. On shutdown, `stop()` is called to clean up connections.

### Streaming extension

Platforms that support editing messages in place (e.g. Telegram) can implement `StreamingGatewayPlugin` instead:

```swift
public protocol StreamingGatewayPlugin: GatewayPlugin {
    func beginStreaming(channelId: String, userId: String) async throws -> GatewayOutboundStreamHandle
    func updateStreaming(handle: GatewayOutboundStreamHandle, channelId: String, content: String) async throws
    func endStreaming(handle: GatewayOutboundStreamHandle, channelId: String, userId: String, finalContent: String?) async throws
}
```

Sloppy calls `beginStreaming` when a response starts, `updateStreaming` for each partial chunk, and `endStreaming` when the response is complete.

### Minimal example

```swift
import PluginSDK

public actor MyGatewayPlugin: GatewayPlugin {
    public nonisolated let id = "my-platform"
    public nonisolated let channelIds: [String]

    private var receiver: (any InboundMessageReceiver)?

    public init(channelIds: [String]) {
        self.channelIds = channelIds
    }

    public func start(inboundReceiver: any InboundMessageReceiver) async throws {
        self.receiver = inboundReceiver
        // Start polling or connect to the platform's API here.
        // When a user message arrives, forward it:
        //   await inboundReceiver.postMessage(channelId: "main", userId: "u1", content: "Hello")
    }

    public func stop() async {
        receiver = nil
        // Disconnect from the platform.
    }

    public func send(channelId: String, message: String) async throws {
        // Deliver `message` to the platform user associated with `channelId`.
    }
}
```

---

## ToolPlugin

A tool plugin exposes structured tools that agents can call during a session. Each tool has a name, a set of arguments, and returns a JSON result.

### Protocol

```swift
public protocol ToolPlugin: Sendable {
    var id: String { get }
    var supportedTools: [String] { get }

    func invoke(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue
}
```

`supportedTools` lists every tool name this plugin handles. `invoke` is called by the runtime for each tool call the model produces. The result must be a `JSONValue` (defined in `Protocols`).

### Minimal example

```swift
import Protocols
import PluginSDK

public struct WeatherToolPlugin: ToolPlugin {
    public let id = "weather"
    public let supportedTools = ["get_weather"]

    public func invoke(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard tool == "get_weather",
              case .string(let city) = arguments["city"]
        else {
            return .object(["error": .string("unknown tool or missing arguments")])
        }
        // Call a real weather API here.
        return .object([
            "city": .string(city),
            "temperature": .number(22),
            "condition": .string("sunny")
        ])
    }
}
```

---

## MemoryPlugin

A memory plugin adds a custom persistence backend for agent memory. The runtime calls `recall` to search for relevant notes and `save` to persist new ones.

### Protocol

```swift
public protocol MemoryPlugin: Sendable {
    var id: String { get }

    func recall(query: String, limit: Int) async throws -> [MemoryRef]
    func save(note: String) async throws -> MemoryRef
}
```

`MemoryRef` is defined in `Protocols` and carries an `id`, a relevance `score`, and optional metadata (`kind`, `memoryClass`, `source`, `createdAt`).

### Minimal example

```swift
import Protocols
import PluginSDK

public actor InMemoryPlugin: MemoryPlugin {
    public let id = "in-memory"
    private var notes: [(id: String, text: String)] = []

    public func recall(query: String, limit: Int) async throws -> [MemoryRef] {
        notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
            .prefix(limit)
            .map { MemoryRef(id: $0.id, score: 1.0) }
    }

    public func save(note: String) async throws -> MemoryRef {
        let id = UUID().uuidString
        notes.append((id: id, text: note))
        return MemoryRef(id: id, score: 1.0)
    }
}
```

---

## ModelProvider

A model provider integrates a new LLM backend. The runtime uses it to create `LanguageModel` instances (from the `AnyLanguageModel` package) and to build generation options.

### Protocol

```swift
public protocol ModelProvider: Sendable {
    var id: String { get }
    var supportedModels: [String] { get }
    var systemInstructions: String? { get }
    var tools: [any Tool] { get }

    func createLanguageModel(for modelName: String) async throws -> any LanguageModel
    func generationOptions(for modelName: String, maxTokens: Int, reasoningEffort: ReasoningEffort?) -> GenerationOptions
    func reasoningCapture(for modelName: String) -> ReasoningContentCapture?
}
```

`supportedModels` lists the model identifiers this provider handles (including the prefix, e.g. `"mycloud:fast-v1"`). `createLanguageModel(for:)` must return a conforming `LanguageModel` for the requested model. Default implementations of `systemInstructions`, `tools`, `generationOptions`, and `reasoningCapture` are provided by `PluginSDK` — only override them when needed.

### Minimal example

```swift
import AnyLanguageModel
import Foundation
import PluginSDK
import Protocols

public struct MyCloudModelProvider: ModelProvider {
    public let id = "mycloud"
    public let supportedModels: [String]
    private let apiKey: @Sendable () -> String

    public init(supportedModels: [String], apiKey: @escaping @Sendable () -> String) {
        self.supportedModels = supportedModels
        self.apiKey = apiKey
    }

    public func createLanguageModel(for modelName: String) async throws -> any LanguageModel {
        let resolved = modelName.hasPrefix("mycloud:") ? String(modelName.dropFirst(8)) : modelName
        return MyCloudLanguageModel(apiKey: apiKey(), model: resolved)
    }
}
```

`MyCloudLanguageModel` must conform to `LanguageModel` from the `AnyLanguageModel` package. See the existing `OpenAIModelProvider` and `AnthropicModelProvider` implementations in `Sources/PluginSDK/Providers/` for full working examples.

### Composite provider

If you register multiple providers, Sloppy combines them automatically using `CompositeModelProvider`, which routes each request to the sub-provider whose `supportedModels` list contains the requested model identifier.

---

## Writing an in-process Swift plugin

In-process plugins are Swift targets linked directly into the Sloppy binary. The built-in Telegram and Discord plugins follow this pattern.

### 1. Add a SwiftPM target

```swift
// Package.swift
.target(
    name: "ChannelPluginMyPlatform",
    dependencies: [
        "PluginSDK",
        "Protocols",
        .product(name: "Logging", package: "swift-log")
    ],
    path: "Sources/ChannelPluginMyPlatform"
)
```

Add the new target as a dependency of the `sloppy` executable target.

### 2. Implement the protocol

Create your plugin struct or actor in the new target, conforming to the appropriate protocol as shown in the examples above.

### 3. Instantiate and register

For `GatewayPlugin` implementations, bootstrap them inside `CoreService.bootstrapChannelPlugins()` by calling `startBuiltInPlugin(_:id:type:channelIds:)`. Tool, memory, and model provider plugins are registered with `AgentRuntime` through the `RuntimeSystem` facade — consult the corresponding registration points in `Sources/AgentRuntime/RuntimeSystem.swift`.

---

## Writing a SwiftPM source plugin

Swift source plugins are distributed as standalone SwiftPM packages. Sloppy clones the package into the workspace, builds a dynamic library for the current OS and architecture, caches the binary, and loads it with `dlopen`. Currently only `GatewayPlugin` is supported through this source-package path.

### Directory structure

```
MyPlatformPlugin/
  Package.swift
  plugin.json
  Sources/
    MyPlatformPlugin/
      MyPlatformPlugin.swift
```

### plugin.json manifest

```json
{
  "name": "my-platform",
  "protocol": "gateway",
  "version": "1.0.0"
}
```

| Field | Description |
| --- | --- |
| `name` | Unique plugin identifier. Use lowercase letters, numbers, `.`, `_`, or `-`. Must match the source package product name. |
| `protocol` | Must be `"gateway"` for external plugins. |
| `version` | Optional semver string for diagnostics. |

The package must expose a dynamic library product named exactly like `plugin.json` `name`:

```swift
.library(
    name: "my-platform",
    type: .dynamic,
    targets: ["MyPlatformPlugin"]
)
```

Install it through the API:

```bash
curl -X POST http://localhost:25101/v1/plugins/install \
  -H 'Authorization: Bearer dev-token' \
  -H 'Content-Type: application/json' \
  -d '{"sourceUrl":"https://github.com/example/my-platform-plugin.git"}'
```

Or through the CLI:

```bash
sloppy plugin install https://github.com/example/my-platform-plugin.git
sloppy plugin install https://github.com/example/my-platform-plugin.git --ref v1.0.0 --force
```

Sloppy stores the cloned source under `<workspace>/plugins/<name>/` and the built binary under `<workspace>/plugin-cache/<name>/<fingerprint>/`. The `plugin.json` file is read as-is and is not rewritten.

### C ABI entry point

The dylib must export a C function with this signature:

```c
void* sloppy_gateway_create(const char* manifest_json, void* inbound_receiver_opaque);
```

- `manifest_json` is a UTF-8 JSON string of the manifest.
- `inbound_receiver_opaque` is an opaque pointer to a retained `GatewayPluginReceiverBox`.
- Return an opaque pointer to a retained `AnyGatewayPluginBox` from `PluginSDK`, or `NULL` on failure.

Sloppy will call `start`, `stop`, and `send` on the returned object through the `GatewayPlugin` protocol.

### Legacy prebuilt plugin layout

Prebuilt dynamic libraries are still supported for backward compatibility:

```
<workspace>/
  plugins/
    my-platform/
      plugin.json
      my-platform.dylib   (or plugin.dylib, libmy-platform.dylib, .so on Linux)
```

---

## Writing an out-of-process channel plugin (HTTP)

Out-of-process plugins are standalone HTTP servers written in any language. Sloppy communicates with them over a plain JSON protocol. This is the recommended approach for non-Swift implementations.

### How it works

```
Platform (e.g. Slack)
        │
        ▼
  Plugin HTTP Server
        │  POST /v1/channels/{channelId}/messages  (inbound)
        ▼
      Sloppy Core
        │  POST {plugin_base_url}/deliver          (outbound)
        ▼
  Plugin HTTP Server
        │
        ▼
      Platform
```

### Inbound: platform → Sloppy

When a user sends a message, the plugin forwards it to Sloppy:

```
POST {CORE_BASE_URL}/v1/channels/{channelId}/messages
Content-Type: application/json

{
  "userId": "u12345",
  "content": "Hello from Slack"
}
```

`channelId` is the Sloppy channel ID mapped to this conversation.

### Outbound: Sloppy → plugin

Sloppy delivers replies by calling the plugin's `/deliver` endpoint:

```
POST {plugin_base_url}/deliver
Content-Type: application/json

{
  "channelId": "main",
  "userId": "u12345",
  "content": "Hi! How can I help?"
}
```

Response: `200 OK` with `{ "ok": true }`.

### Optional streaming endpoints

Platforms that support editing messages in place can implement three additional endpoints:

**Start a stream:**
```
POST {plugin_base_url}/stream/start
{ "channelId": "main", "userId": "u12345" }
→ { "ok": true, "streamId": "stream-abc" }
```

**Send a chunk:**
```
POST {plugin_base_url}/stream/chunk
{ "streamId": "stream-abc", "channelId": "main", "content": "Partial..." }
→ { "ok": true }
```

**End the stream:**
```
POST {plugin_base_url}/stream/end
{ "streamId": "stream-abc", "channelId": "main", "userId": "u12345", "content": "Final answer." }
→ { "ok": true }
```

If the streaming endpoints are absent (404/501), Sloppy falls back to `/deliver`.

### Minimal Python example

```python
from flask import Flask, request, jsonify
import requests

app = Flask(__name__)

SLOPPY_BASE = "http://localhost:25101"
CHANNEL_ID  = "main"

@app.post("/deliver")
def deliver():
    body = request.json
    # Send body["content"] to the external platform user identified by body["userId"].
    print(f"Outbound → {body['userId']}: {body['content']}")
    return jsonify({"ok": True})

def on_platform_message(user_id: str, text: str):
    """Called when a message arrives from the external platform."""
    requests.post(
        f"{SLOPPY_BASE}/v1/channels/{CHANNEL_ID}/messages",
        json={"userId": user_id, "content": text},
    )

if __name__ == "__main__":
    app.run(port=8080)
```

### Registering an HTTP plugin

Register the plugin via the REST API after Sloppy is running:

```bash
curl -X POST http://localhost:25101/v1/plugins \
  -H "Content-Type: application/json" \
  -d '{
    "type": "my-platform",
    "baseUrl": "http://localhost:8080",
    "channelIds": ["main"],
    "config": {}
  }'
```

Or add it to `sloppy.json` so it is registered on startup (consult the API reference for the full config schema).

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Plugin kind (`"telegram"`, `"discord"`, `"slack"`, custom) |
| `baseUrl` | string | Root URL of the plugin HTTP server |
| `channelIds` | string[] | Sloppy channel IDs served by this plugin |
| `config` | object | Arbitrary settings (tokens, allow-lists, etc.) |
| `enabled` | bool | Whether Sloppy should deliver to this plugin |

---

## Plugin lifecycle

### Startup

1. Sloppy reads `sloppy.json` and instantiates built-in gateway plugins (Telegram, Discord) if configured.
2. `PluginLoader` scans the `plugins/` directory. SwiftPM source plugins are built or reused from `plugin-cache`, then loaded via `dlopen`; legacy prebuilt dynamic libraries are loaded directly.
3. All in-process plugins are registered with `ChannelDeliveryService` and `start(inboundReceiver:)` is called.
4. HTTP plugin records stored in the database become active immediately; source plugins can be installed through `POST /v1/plugins/install` or `sloppy plugin install`.

### Message delivery

- Outbound messages are routed through `ChannelDeliveryService`, which prefers in-process plugins and falls back to HTTP delivery for out-of-process plugins.
- Inbound messages from any plugin arrive via `InboundMessageReceiver.postMessage` and are processed by `ChannelRuntime`.

### Shutdown

Sloppy calls `stop()` on every active in-process gateway plugin during shutdown. Out-of-process plugins are not notified and must handle their own cleanup.

---

## Quick reference

| Type | Protocol | Key methods | Delivery |
| --- | --- | --- | --- |
| Gateway | `GatewayPlugin` | `start`, `stop`, `send` | In-process or HTTP |
| Gateway (streaming) | `StreamingGatewayPlugin` | `beginStreaming`, `updateStreaming`, `endStreaming` | In-process or HTTP |
| Tool | `ToolPlugin` | `invoke` | In-process |
| Memory | `MemoryPlugin` | `recall`, `save` | In-process |
| Model Provider | `ModelProvider` | `createLanguageModel`, `generationOptions` | In-process |

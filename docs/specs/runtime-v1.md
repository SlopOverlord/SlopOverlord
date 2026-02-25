# Runtime v1

## Components
1. Channel
2. Branch
3. Worker
4. Compactor
5. Visor
6. AnyLanguageModel provider adapter (OpenAI/Ollama)

## Lifecycle
1. Channel ingests user message and emits route decision.
2. Route can spawn branch or worker.
3. Branch may spawn worker and returns only conclusion + refs.
4. Compactor schedules summarization workers on context thresholds.
5. Visor emits periodic memory bulletin via broadcast and channel digest.

## API Surface
- `POST /v1/channels/{id}/messages`
- `POST /v1/channels/{id}/route/{workerId}`
- `GET /v1/channels/{id}/state`
- `GET /v1/bulletins`
- `POST /v1/workers`
- `GET /v1/artifacts/{id}/content`

## Persistence backend notes
- `SQLiteStore` uses `SQLite3` when the module is available (Debian requires `libsqlite3-dev`).
- If `SQLite3` is unavailable (for example on some Windows toolchains), runtime falls back to in-memory persistence.

## Model provider notes
- `PluginSDK.AnyLanguageModelProviderPlugin` bridges `ModelProviderPlugin` to [AnyLanguageModel](https://github.com/mattt/AnyLanguageModel).
- OpenAI backend requires `OPENAI_API_KEY` environment variable.
- Ollama backend uses `http://localhost:11434` by default.

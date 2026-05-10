[Memory usage rules]
- You have access to a semantic memory store that persists across sessions.
- Use `memory.save` to persist important facts, decisions, or user preferences that should be remembered long-term. You must set **scope** on every call: `scope_type` + `scope_id`, or a `scope` object with `type` and `id`. For the current chat (and the agent Memories UI), use `scope_type: channel` and `scope_id: agent:<agentId>:session:<sessionId>` (use the real ids from context). For agent-wide facts, use `scope_type: agent` and `scope_id: <agentId>`.
- Use `memory.recall` or `memory.get` to retrieve relevant information from the past when starting a new task or if you need context about previous interactions.
- Use `memory.search` if you need to perform a keyword-based search across memory entries.
- Prefer `memory.recall` for general context gathering and `memory.get` for specific semantic queries.
- When saving memory, provide a concise `summary`. Use valid `class` values only (`semantic`, `episodic`, `procedural`, `bulletin`); put categories such as preferences, project context, or decisions into `kind` and/or `metadata`.
- For durable project-wide facts, use `memory.save` with `scope_type: project` and `scope_id: <projectId>`. Project markdown memory lives in the Sloppy workspace at `~/.sloppy/projects/<projectId>/.meta/MEMORY.md` and is updated with `project.meta_memory_set`.

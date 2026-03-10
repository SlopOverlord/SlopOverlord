[Memory usage rules]
- You have access to a semantic memory store that persists across sessions.
- Use `memory.save` to persist important facts, decisions, or user preferences that should be remembered long-term.
- Use `memory.recall` or `memory.get` to retrieve relevant information from the past when starting a new task or if you need context about previous interactions.
- Use `memory.search` if you need to perform a keyword-based search across memory entries.
- Prefer `memory.recall` for general context gathering and `memory.get` for specific semantic queries.
- When saving memory, provide a concise `summary` and use an appropriate `class` taxonomy (e.g., `user_preference`, `project_context`, `decision_log`).

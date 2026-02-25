import React from "react";

export function RuntimeOverviewView({
  title,
  text,
  onTextChange,
  onSend,
  messages,
  tasks,
  artifactId,
  onArtifactIdChange,
  onLoadArtifact,
  artifactContent,
  bulletins
}) {
  return (
    <main className="grid">
      <section className="panel">
        <h2>{title === "Chats" ? "Chat" : "Chat Stream"}</h2>
        <form onSubmit={onSend} className="chat-form">
          <textarea value={text} onChange={(event) => onTextChange(event.target.value)} rows={3} />
          <button type="submit">Send</button>
        </form>
        <div className="log">
          {messages.map((message) => (
            <article key={message.id} className="log-item">
              <strong>{message.userId}</strong>
              <p>{message.content}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="panel">
        <h2>Tasks</h2>
        {tasks.map((task) => (
          <article key={task.id} className="task-card">
            <h3>{task.title}</h3>
            <p>Status: {task.status}</p>
            <p>Reason: {task.reason}</p>
          </article>
        ))}
      </section>

      <section className="panel">
        <h2>Artifacts</h2>
        <div className="artifact-controls">
          <input
            value={artifactId}
            onChange={(event) => onArtifactIdChange(event.target.value)}
            placeholder="artifact id"
          />
          <button type="button" onClick={onLoadArtifact}>
            Load
          </button>
        </div>
        <pre>{artifactContent}</pre>
      </section>

      <section className="panel">
        <h2>Agent Feed</h2>
        <div className="feed">
          {bulletins.map((bulletin) => (
            <article key={bulletin.id} className="feed-item">
              <h3>{bulletin.headline}</h3>
              <p>{bulletin.digest}</p>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}

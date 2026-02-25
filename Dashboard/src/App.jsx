import { useEffect, useMemo, useState } from "react";
import { fetchArtifact, fetchBulletins, fetchChannelState, sendChannelMessage } from "./api";

const CHANNEL_ID = "general";

export function App() {
  const [text, setText] = useState("Implement branch workflow and review");
  const [messages, setMessages] = useState([]);
  const [state, setState] = useState(null);
  const [bulletins, setBulletins] = useState([]);
  const [artifactId, setArtifactId] = useState("");
  const [artifactContent, setArtifactContent] = useState("Select artifact id to preview");

  const tasks = useMemo(() => {
    if (!state) return [];
    const last = state.lastDecision;
    return [
      {
        id: "task-live",
        title: "Current channel route",
        status: last ? last.action : "unknown",
        reason: last ? last.reason : "not available"
      }
    ];
  }, [state]);

  async function refresh() {
    const [nextState, nextBulletins] = await Promise.all([
      fetchChannelState(CHANNEL_ID),
      fetchBulletins()
    ]);
    setState(nextState);
    setBulletins(nextBulletins);
    setMessages(nextState?.messages || []);
  }

  async function onSend(event) {
    event.preventDefault();
    if (!text.trim()) return;
    await sendChannelMessage(CHANNEL_ID, { userId: "dashboard", content: text });
    setText("");
    await refresh();
  }

  async function loadArtifact() {
    if (!artifactId.trim()) return;
    const artifact = await fetchArtifact(artifactId.trim());
    setArtifactContent(artifact?.content || "Artifact not found");
  }

  useEffect(() => {
    refresh().catch(() => {});
  }, []);

  return (
    <div className="page">
      <header className="hero">
        <h1>SlopOverlord Dashboard</h1>
        <p>Channel / Branch / Worker runtime monitor</p>
      </header>

      <main className="grid">
        <section className="panel">
          <h2>Chat</h2>
          <form onSubmit={onSend} className="chat-form">
            <textarea value={text} onChange={(e) => setText(e.target.value)} rows={3} />
            <button type="submit">Send</button>
          </form>
          <div className="log">
            {messages.map((msg) => (
              <article key={msg.id} className="log-item">
                <strong>{msg.userId}</strong>
                <p>{msg.content}</p>
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
            <input value={artifactId} onChange={(e) => setArtifactId(e.target.value)} placeholder="artifact id" />
            <button onClick={loadArtifact}>Load</button>
          </div>
          <pre>{artifactContent}</pre>
        </section>

        <section className="panel">
          <h2>Agent Feed</h2>
          <div className="feed">
            {bulletins.map((b) => (
              <article key={b.id} className="feed-item">
                <h3>{b.headline}</h3>
                <p>{b.digest}</p>
              </article>
            ))}
          </div>
        </section>
      </main>
    </div>
  );
}

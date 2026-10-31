// Share, Join, Settings and version history: the Mac's panels.
import { useLayoutEffect, useState } from "preact/hooks";
import { mcpStatus, setAssistantsEnabled } from "../assistant.ts";
import { redraw } from "../canvas/Canvas.tsx";
import { join, share } from "../session.ts";
import { getState, leave, set, settings, useStore } from "../store.ts";
import { History } from "./History.tsx";

export function Panels() {
  const state = useStore();
  // The canvas draws on request: the scene changing anywhere (an edit, a version picked, an assistant's change) asks.
  useLayoutEffect(() => redraw(), [state.revision]);
  return (
    <>
      {state.showsShare && <SharePanel />}
      {state.showsJoin && <JoinPanel />}
      {state.showsSettings && <SettingsPanel />}
      {state.showsHistory && state.path && <History path={state.path} />}
    </>
  );
}

function Panel({ title, onClose, children }: { title: string; onClose: () => void; children: preact.ComponentChildren }) {
  return (
    <div class="panel" role="dialog" aria-label={title} onKeyDown={(e) => { if (e.key === "Escape") onClose(); }}>
      <h3>{title}</h3>
      {children}
      <div class="row"><button onClick={onClose}>Done</button></div>
    </div>
  );
}

function SharePanel() {
  const { session, name } = useStore();
  const close = () => set({ showsShare: false });
  if (!session) {
    return (
      <Panel title={`Share “${name}”`} onClose={close}>
        <p>Others edit it with you, live, from a link. Everything is end-to-end encrypted through the relay, {settings.relay}.</p>
        <div class="row"><button class="primary" onClick={share}>Start Sharing</button></div>
      </Panel>
    );
  }
  return (
    <Panel title={session.role === "host" ? "Sharing" : "In a session"} onClose={close}>
      <p>{session.status}</p>
      {session.links && (
        <>
          <label>Link to edit</label>
          <Copyable text={session.links.edit} />
          <label>Link only to watch</label>
          <Copyable text={session.links.view} />
          <p class="secondary">Send them as you would a password: anyone with a link can join while sharing lasts.</p>
        </>
      )}
      <label>People</label>
      <ul class="people">
        {session.me && <li>{session.me.name} (you)</li>}
        {session.peers.map((p) => <li key={p.id}>{p.name}</li>)}
      </ul>
      <div class="row">
        <button onClick={() => { leave(); close(); }}>{session.role === "host" ? "Stop Sharing" : "Leave"}</button>
      </div>
    </Panel>
  );
}

/** Text to copy, with a button that does. */
function Copyable({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div class="copyable">
      <code>{text}</code>
      <button onClick={() => void navigator.clipboard.writeText(text).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1200); })}>
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

function JoinPanel() {
  const [link, setLink] = useState("");
  const close = () => set({ showsJoin: false });
  return (
    <Panel title="Join a Session" onClose={close}>
      <label>Share link</label>
      <input type="text" value={link} onInput={(e) => setLink((e.target as HTMLInputElement).value)} placeholder="Paste the link you were sent" autoFocus
        onKeyDown={(e) => { if (e.key === "Enter" && link.trim()) { join(link); close(); } }} />
      <div class="row"><button class="primary" disabled={!link.trim()} onClick={() => { join(link); close(); }}>Join</button></div>
    </Panel>
  );
}

function SettingsPanel() {
  const [relay, setRelay] = useState(settings.relay);
  const [name, setName] = useState(settings.name);
  const [avoid, setAvoid] = useState(settings.avoidTables);
  const [assistants, setAssistants] = useState(settings.mcpEnabled);
  const [status, setStatus] = useState(mcpStatus);
  const close = () => {
    settings.relay = relay.trim() || "http://localhost:8787";
    settings.name = name.trim() || "Me";
    settings.avoidTables = avoid;
    set({ showsSettings: false });
  };
  async function toggleAssistants(on: boolean) {
    setAssistants(on);
    await setAssistantsEnabled(on);
    setStatus(mcpStatus);
  }
  return (
    <Panel title="Settings" onClose={close}>
      <label>Your name, as others in a session see it</label>
      <input type="text" value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
      <label>Relay, for sharing</label>
      <input type="text" value={relay} onInput={(e) => setRelay((e.target as HTMLInputElement).value)} />
      <label class="check">
        <input type="checkbox" checked={avoid} onChange={(e) => setAvoid((e.target as HTMLInputElement).checked)} /> Wires bend around tables
      </label>
      <h4>AI assistants</h4>
      <label class="check">
        <input type="checkbox" checked={assistants} onChange={(e) => void toggleAssistants((e.target as HTMLInputElement).checked)} />
        Let AI assistants read and edit data models (MCP)
      </label>
      <p class="secondary">{status}</p>
      {assistants && (
        <>
          <p class="secondary">For Claude Code:</p>
          <Copyable text="claude mcp add --transport http joinery http://127.0.0.1:8723/mcp" />
          <p class="secondary">Other assistants take the address, http://127.0.0.1:8723/mcp, in their own settings. Only this computer can reach it.</p>
        </>
      )}
      <p class="secondary">Library: {getState().listing.root}</p>
    </Panel>
  );
}

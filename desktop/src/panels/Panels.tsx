// Share, Join, Settings and version history: the Mac's panels, plainly.
import { useEffect, useState } from "preact/hooks";
import { mcpStatus } from "../assistant.ts";
import { core } from "../core.ts";
import { library, type Version } from "../library.ts";
import { join, share } from "../session.ts";
import { act, fail, getState, leave, saveVersion, set, settings, useStore } from "../store.ts";

export function Panels() {
  const state = useStore();
  return (
    <>
      {state.showsShare && <SharePanel />}
      {state.showsJoin && <JoinPanel />}
      {state.showsSettings && <SettingsPanel />}
      {state.showsHistory && state.path && <HistoryPanel path={state.path} />}
    </>
  );
}

function Panel({ title, onClose, children }: { title: string; onClose: () => void; children: preact.ComponentChildren }) {
  return (
    <div class="panel" role="dialog" aria-label={title}>
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
          <code>{session.links.edit}</code>
          <label>Link only to watch</label>
          <code>{session.links.view}</code>
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

function JoinPanel() {
  const [link, setLink] = useState("");
  const close = () => set({ showsJoin: false });
  return (
    <Panel title="Join a Session" onClose={close}>
      <label>Share link</label>
      <input type="text" value={link} onInput={(e) => setLink((e.target as HTMLInputElement).value)} placeholder="Paste the link you were sent" autoFocus />
      <div class="row"><button class="primary" disabled={!link.trim()} onClick={() => { join(link); close(); }}>Join</button></div>
    </Panel>
  );
}

function SettingsPanel() {
  const [relay, setRelay] = useState(settings.relay);
  const [name, setName] = useState(settings.name);
  const [avoid, setAvoid] = useState(settings.avoidTables);
  const close = () => {
    settings.relay = relay.trim() || "http://localhost:8787";
    settings.name = name.trim() || "Me";
    settings.avoidTables = avoid;
    set({ showsSettings: false });
  };
  return (
    <Panel title="Settings" onClose={close}>
      <label>Your name, as others in a session see it</label>
      <input type="text" value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
      <label>Relay, for sharing</label>
      <input type="text" value={relay} onInput={(e) => setRelay((e.target as HTMLInputElement).value)} />
      <label class="check">
        <input type="checkbox" checked={avoid} onChange={(e) => setAvoid((e.target as HTMLInputElement).checked)} /> Wires bend around tables
      </label>
      <label>AI assistants (MCP)</label>
      <p>{mcpStatus}</p>
      <p class="secondary">For Claude Code:</p>
      <code>claude mcp add --transport http joinery http://127.0.0.1:8723/mcp</code>
      <p class="secondary">Library: {getState().listing.root}</p>
    </Panel>
  );
}

function HistoryPanel({ path }: { path: string }) {
  const [versions, setVersions] = useState<Version[]>([]);
  const [summaries, setSummaries] = useState<Record<string, string>>({});
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const list = await library.versions(path);
      if (cancelled) return;
      setVersions(list);
      const current = core.modelFile();
      const next: Record<string, string> = {};
      for (const v of list.slice(0, 40)) {
        const { model, before } = await library.readVersion(path, v.file);
        next[v.file] = v.isReview && before ? `Review: ${core.compare(before, model)}` : `Restoring: ${core.compare(current, model)}`;
      }
      if (!cancelled) setSummaries(next);
    })().catch(fail);
    return () => { cancelled = true; };
  }, [path, getState().revision]);

  async function restore(v: Version) {
    try {
      const { model } = await library.readVersion(path, v.file);
      await saveVersion("Before restoring an earlier version");
      act(() => core.edit("replace", JSON.stringify({ model })));
    } catch (error) {
      fail(error);
    }
  }

  return (
    <Panel title="Version History" onClose={() => set({ showsHistory: false })}>
      {versions.length === 0 && <p class="secondary">No versions yet.</p>}
      <ul class="versions">
        {versions.map((v) => (
          <li key={v.file}>
            <div>
              <strong>{v.reason}</strong> <span class="secondary">{new Date(v.date).toLocaleString()}</span>
            </div>
            <div class="secondary">{summaries[v.file] ?? ""}</div>
            <button onClick={() => void restore(v)}>Restore</button>
          </li>
        ))}
      </ul>
      <p class="secondary">Kept when you open it, before AI assistants' changes, before deleting or rearranging tables, and hourly while editing. Older ones thin out to one a day, then one a week. Restoring can be undone.</p>
    </Panel>
  );
}

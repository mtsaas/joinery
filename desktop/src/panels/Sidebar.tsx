// The library: models by collection, to open, rename, move and delete, and buttons for a new one and joining a session.
import { useState } from "preact/hooks";
import { library, type ModelEntry } from "../library.ts";
import { fail, moved, newModel, open, reload, set, useStore } from "../store.ts";

export function Sidebar() {
  const state = useStore();
  const [renaming, setRenaming] = useState<string | null>(null);
  const { models, collections } = state.listing;
  const loose = models.filter((m) => !m.collection);
  const favorites = models.filter((m) => m.favorite);

  async function act(body: () => Promise<unknown>) {
    try { await body(); await reload(); } catch (error) { fail(error); }
  }

  const row = (m: ModelEntry) => (
    <li key={m.path} class={m.path === state.path ? "selected" : ""}>
      {renaming === m.path ? (
        <input
          class="rename"
          defaultValue={m.name}
          ref={(el) => el?.focus()}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.target as HTMLInputElement).blur();
            if (e.key === "Escape") setRenaming(null);
          }}
          onBlur={(e) => {
            const name = (e.target as HTMLInputElement).value.trim();
            setRenaming(null);
            if (name && name !== m.name) void act(async () => moved(m.path, await library.rename(m.path, name)));
          }}
        />
      ) : (
        <button
          class="model"
          onClick={() => void open(m.path)}
          onDblClick={() => setRenaming(m.path)}
          onContextMenu={(e) => {
            e.preventDefault();
            const choice = prompt(`${m.name}: rename, duplicate, favorite, move <collection>, or delete?`)?.trim();
            if (!choice) return;
            if (choice === "rename") setRenaming(m.path);
            else if (choice === "duplicate") void act(() => library.duplicate(m.path));
            else if (choice === "favorite") void act(() => library.setFavorite(m.path, !m.favorite));
            else if (choice.startsWith("move")) void act(async () => moved(m.path, await library.move(m.path, choice.slice(5).trim() || null)));
            else if (choice === "delete" && confirm(`Move “${m.name}” to the trash?`)) {
              void act(async () => { await library.trash(m.path); if (state.path === m.path) set({ path: null, scene: null, name: "" }); });
            }
          }}
        >
          {m.favorite && <span class="star">★</span>}
          {m.name}
        </button>
      )}
    </li>
  );

  return (
    <aside class="sidebar">
      <div class="sidebar-actions">
        <button onClick={() => void newModel(null)}>New Data Model</button>
        <button onClick={() => set({ showsJoin: true })}>Join…</button>
      </div>
      {favorites.length > 0 && <Section title="Favorites">{favorites.map(row)}</Section>}
      {loose.length > 0 && <Section title="Data Models">{loose.map(row)}</Section>}
      {collections.map((c) => (
        <Section key={c} title={c} onAdd={() => void newModel(c)}>
          {models.filter((m) => m.collection === c).map(row)}
        </Section>
      ))}
      <button class="link" onClick={() => void act(() => library.newCollection("New Collection"))}>New Collection</button>
      <button class="link" onClick={() => set({ showsSettings: true })}>Settings</button>
    </aside>
  );
}

function Section({ title, children, onAdd }: { title: string; children: preact.ComponentChildren; onAdd?: () => void }) {
  return (
    <section>
      <h2>
        {title}
        {onAdd && <button class="add" title={`New data model in ${title}`} onClick={onAdd}>+</button>}
      </h2>
      <ul>{children}</ul>
    </section>
  );
}

// The library, as the Mac's sidebar has it: Recents, Favorites, data models in no collection, then each collection.
// Click to open, double-click to rename, right-click for the rest; drag a model onto a collection to move it there.
import { useState } from "preact/hooks";
import type { ModelEntry } from "../library.ts";
import { newModel, open, set, useStore } from "../store.ts";
import * as actions from "./actions.ts";
import { PopupMenu, type MenuItem } from "./Menu.tsx";

/** How many recently opened models Recents shows. */
const recentCount = 5;
/** What a dragged model carries. */
const dragType = "application/x-joinery-model";

export function Sidebar() {
  const state = useStore();
  const [renaming, setRenaming] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ items: MenuItem[]; at: [number, number] } | null>(null);
  const [dropTarget, setDropTarget] = useState<string | null>(null);
  const { models, collections } = state.listing;
  const recents = models.filter((m) => m.opened).sort((a, b) => b.opened! - a.opened!).slice(0, recentCount);
  const favorites = models.filter((m) => m.favorite);
  const loose = models.filter((m) => !m.collection);

  function modelMenu(m: ModelEntry): MenuItem[] {
    return [
      { title: "Open", run: () => void open(m.path) },
      "-",
      { title: m.favorite ? "Remove from Favorites" : "Add to Favorites", run: () => void actions.setFavorite(m, !m.favorite) },
      { title: "Rename", run: () => setRenaming(`model:${m.path}`) },
      { title: "Duplicate", run: () => void actions.duplicate(m) },
      {
        title: "Move to",
        items: [
          { title: "No Collection", disabled: !m.collection, run: () => void actions.move(m, null) },
          ...(collections.length ? ["-" as const] : []),
          ...collections.map((c) => ({ title: c, disabled: c === m.collection, run: () => void actions.move(m, c) })),
        ],
      },
      { title: "Export a Copy…", run: () => void actions.exportModel(m) },
      { title: "Show in Explorer", run: () => void actions.reveal(m.path) },
      "-",
      { title: "Move to Recycle Bin", destructive: true, run: () => void actions.trash(m) },
    ];
  }

  function collectionMenu(c: string): MenuItem[] {
    return [
      { title: "New Data Model", run: () => void newModel(c) },
      { title: "Import Data Model…", run: () => void actions.importModel(c) },
      "-",
      { title: "Rename", run: () => setRenaming(`collection:${c}`) },
      { title: "Show in Explorer", run: () => void actions.reveal(c) },
      "-",
      { title: "Move to Recycle Bin", destructive: true, run: () => void actions.trashCollection(c) },
    ];
  }

  const showMenu = (items: MenuItem[]) => (e: MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setMenu({ items, at: [e.clientX, e.clientY] });
  };

  // Where a dragged model can go: a collection, or "Data Models" for none.
  const dropZone = (collection: string | null) => ({
    onDragOver: (e: DragEvent) => {
      if (!e.dataTransfer?.types.includes(dragType)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "move";
      setDropTarget(collection ?? "");
    },
    onDragLeave: () => setDropTarget(null),
    onDrop: (e: DragEvent) => {
      e.preventDefault();
      setDropTarget(null);
      const model = models.find((m) => m.path === e.dataTransfer?.getData(dragType));
      if (model) void actions.move(model, collection);
    },
  });

  const row = (m: ModelEntry, section: string) => (
    <li key={`${section}:${m.path}`} class={m.path === state.path ? "selected" : ""}>
      {renaming === `model:${m.path}` ? (
        <Rename value={m.name} onDone={(name) => { setRenaming(null); if (name && name !== m.name) void actions.rename(m, name); }} />
      ) : (
        <button
          class="model"
          draggable
          title={m.collection ? `${m.collection} / ${m.name}` : m.name}
          onClick={() => void open(m.path)}
          onDblClick={() => setRenaming(`model:${m.path}`)}
          onContextMenu={showMenu(modelMenu(m))}
          onDragStart={(e) => { e.dataTransfer?.setData(dragType, m.path); e.dataTransfer!.effectAllowed = "move"; }}
          onKeyDown={(e) => {
            if (e.key === "F2") setRenaming(`model:${m.path}`);
            if (e.key === "Delete") void actions.trash(m);
          }}
        >
          {m.favorite && <span class="star" aria-label="Favorite">♥</span>}
          {m.name}
          {section !== "collection" && m.collection && <span class="where">{m.collection}</span>}
        </button>
      )}
    </li>
  );

  return (
    <aside class="sidebar" onContextMenu={showMenu([
      { title: "New Data Model", run: () => void newModel(null) },
      { title: "New Collection", run: () => void actions.newCollection() },
      { title: "Import Data Model…", run: () => void actions.importModel() },
    ])}>
      <div class="sidebar-actions">
        <button onClick={() => void newModel(actions.currentCollection())} title="New Data Model (Ctrl+N)">New Data Model</button>
        <button onClick={() => set({ showsJoin: true })} title="Join a session from a link">Join…</button>
      </div>
      {recents.length > 0 && <Section title="Recents">{recents.map((m) => row(m, "recents"))}</Section>}
      {favorites.length > 0 && <Section title="Favorites">{favorites.map((m) => row(m, "favorites"))}</Section>}
      <Section title="Data Models" drop={dropTarget === ""} zone={dropZone(null)} onAdd={() => void newModel(null)}>
        {loose.map((m) => row(m, "collection"))}
        {loose.length === 0 && <li class="hint">None outside collections</li>}
      </Section>
      {collections.map((c) => (
        <Section
          key={c}
          title={c}
          drop={dropTarget === c}
          zone={dropZone(c)}
          onAdd={() => void newModel(c)}
          onMenu={showMenu(collectionMenu(c))}
          renaming={renaming === `collection:${c}`}
          onRename={(to) => { setRenaming(null); if (to && to !== c) void actions.renameCollection(c, to); }}
          onStartRename={() => setRenaming(`collection:${c}`)}
        >
          {models.filter((m) => m.collection === c).map((m) => row(m, "collection"))}
        </Section>
      ))}
      <div class="sidebar-footer">
        <button class="link" onClick={() => void actions.newCollection()}>New Collection</button>
        <button class="link" onClick={() => void actions.importModel()}>Import…</button>
        <button class="link" onClick={() => set({ showsSettings: true })}>Settings</button>
      </div>
      {menu && <PopupMenu items={menu.items} at={menu.at} onClose={() => setMenu(null)} />}
    </aside>
  );
}

function Section(props: {
  title: string;
  children: preact.ComponentChildren;
  drop?: boolean;
  zone?: Record<string, (e: DragEvent) => void>;
  onAdd?: () => void;
  onMenu?: (e: MouseEvent) => void;
  renaming?: boolean;
  onRename?: (name: string | null) => void;
  onStartRename?: () => void;
}) {
  return (
    <section class={props.drop ? "drop" : ""} {...props.zone}>
      <h2 onContextMenu={props.onMenu} onDblClick={props.onStartRename}>
        {props.renaming ? <Rename value={props.title} onDone={(name) => props.onRename?.(name)} /> : <span>{props.title}</span>}
        {props.onAdd && <button class="add" title={`New data model in ${props.title}`} onClick={props.onAdd}>+</button>}
      </h2>
      <ul>{props.children}</ul>
    </section>
  );
}

/** Editing a name in place: Return or clicking away keeps it, Escape doesn't. */
function Rename({ value, onDone }: { value: string; onDone: (name: string | null) => void }) {
  let done = false;
  const finish = (name: string | null) => { if (!done) { done = true; onDone(name); } };
  return (
    <input
      class="rename"
      defaultValue={value}
      ref={(el) => { if (el && document.activeElement !== el) { el.focus(); el.select(); } }}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") finish((e.target as HTMLInputElement).value.trim());
        if (e.key === "Escape") finish(null);
      }}
      onBlur={(e) => finish((e.target as HTMLInputElement).value.trim())}
    />
  );
}

// The window: the library beside the canvas, the toolbar over it, and panels as they're opened.
import { useEffect, useState } from "preact/hooks";
import { core } from "./core.ts";
import { Canvas, canvas, onZoom } from "./canvas/Canvas.tsx";
import { CellEditor, type Editing } from "./canvas/CellEditor.tsx";
import { ComparisonBar } from "./panels/ComparisonBar.tsx";
import { ContextMenu, type Menu } from "./panels/ContextMenu.tsx";
import { Panels } from "./panels/Panels.tsx";
import { Sidebar } from "./panels/Sidebar.tsx";
import { act, set, useStore } from "./store.ts";

export function App() {
  const state = useStore();
  const [editing, setEditing] = useState<Editing | null>(null);
  const [menu, setMenu] = useState<Menu | null>(null);

  return (
    <div class="window">
      <Sidebar />
      <main class="main">
        <Toolbar />
        <div class="stage">
          <Canvas
            onEditCell={(table, column, part) => setEditing({ table, column, part })}
            onContextMenu={(hit, at) => setMenu({ hit, at })}
          />
          {editing && <CellEditor editing={editing} onDone={() => setEditing(null)} />}
          {menu && <ContextMenu menu={menu} onClose={() => setMenu(null)} />}
          <Panels />
          {!state.scene && <Empty />}
          <ComparisonBar />
          {state.notice && <div class="notice">{state.notice}</div>}
          {state.failure && (
            <div class="failure" role="alert">
              <span>{state.failure}</span>
              <button onClick={() => set({ failure: null })}>OK</button>
            </div>
          )}
        </div>
      </main>
    </div>
  );
}

function Toolbar() {
  const state = useStore();
  const [, rerender] = useState(0);
  useEffect(() => onZoom(() => rerender((n) => n + 1)), []);
  const scene = state.scene;
  return (
    <header class="toolbar">
      <span class="title">{state.name}</span>
      {state.session && <span class="badge">{state.session.status}</span>}
      <span class="spacer" />
      {scene && (
        <>
          <button title="Undo (Ctrl+Z)" disabled={!scene.canUndo} onClick={() => act(() => core.undo())}>↶</button>
          <button title="Redo (Ctrl+Y)" disabled={!scene.canRedo} onClick={() => act(() => core.redo())}>↷</button>
          <select
            class="zoom"
            title="Zoom"
            value=""
            onChange={(e) => {
              const v = (e.target as HTMLSelectElement).value;
              if (v === "fit") canvas.fit(); else canvas.zoomTo(Number(v));
            }}
          >
            <option value="" hidden>{Math.round(canvas.view.zoom * 100)}%</option>
            <option value="fit">Zoom to Fit</option>
            {[0.25, 0.5, 0.75, 1, 1.5, 2].map((z) => <option value={z}>{z * 100}%</option>)}
          </select>
          {state.path && <button onClick={() => set({ showsHistory: !state.showsHistory })} title="Version history">History</button>}
          <button onClick={() => set({ showsShare: true })} title="Share live">Share</button>
        </>
      )}
    </header>
  );
}

function Empty() {
  return (
    <div class="empty">
      <p>Open a data model from the library, or make a new one.</p>
    </div>
  );
}

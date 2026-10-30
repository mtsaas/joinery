// The window: the library beside the canvas, the toolbar over it, and panels as they're opened.
import { useEffect, useState } from "preact/hooks";
import { core } from "./core.ts";
import { Canvas, canvas, onZoom, redraw } from "./canvas/Canvas.tsx";
import { CellEditor, type Editing } from "./canvas/CellEditor.tsx";
import { cancelUntangle, currentUntangling, handleKey, onUntangle, refreshFocus, ui } from "./canvas/commands.ts";
import { Designer } from "./canvas/Designer.tsx";
import { Minimap } from "./canvas/Minimap.tsx";
import { Palette } from "./canvas/Palette.tsx";
import { ContextMenu, type Menu } from "./panels/ContextMenu.tsx";
import { Panels } from "./panels/Panels.tsx";
import { Sidebar } from "./panels/Sidebar.tsx";
import { act, set, useStore } from "./store.ts";

export function App() {
  const state = useStore();
  const [editing, setEditing] = useState<Editing | null>(null);
  const [menu, setMenu] = useState<Menu | null>(null);
  const [palette, setPalette] = useState(false);
  const [designing, setDesigning] = useState<string | null>(null);
  const [minimap, setMinimap] = useState(() => localStorage.getItem("showsMinimap") !== "0");

  useEffect(() => {
    Object.assign(ui, {
      editCell: (table: string, column: string | null, part: "name" | "type" | null) => setEditing({ table, column, part }),
      openDesigner: setDesigning,
      openPalette: () => setPalette(true),
      toggleMinimap: () => setMinimap((shown) => {
        localStorage.setItem("showsMinimap", shown ? "0" : "1");
        return !shown;
      }),
    });
    const onKey = (e: KeyboardEvent) => void handleKey(e);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  // The canvas draws on its own, as things move; a change made elsewhere (a panel, the palette, an assistant) redraws it.
  useEffect(() => {
    refreshFocus();
    redraw();
  }, [state.revision]);

  return (
    <div class="window">
      <Sidebar />
      <main class="main">
        <Toolbar />
        <div class="stage">
          <Canvas
            onEditCell={(table, column, part) => setEditing({ table, column, part })}
            onContextMenu={(hit, at) => setMenu({ hit, at })}
            onOpenDesigner={setDesigning}
          />
          {editing && <CellEditor editing={editing} onDone={() => setEditing(null)} />}
          {menu && <ContextMenu menu={menu} onClose={() => setMenu(null)} />}
          {state.scene && minimap && <Minimap />}
          {state.scene && designing && <Designer table={designing} onClose={() => setDesigning(null)} />}
          {palette && <Palette onClose={() => setPalette(false)} />}
          <UntangleBar />
          <Panels />
          {!state.scene && <Empty />}
          {state.scene?.reviewing && <ReviewBar summary={state.scene.summary} />}
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

/** While untangling: how far along, and how many crossings it's got down to. */
function UntangleBar() {
  const [, rerender] = useState(0);
  useEffect(() => onUntangle(() => rerender((n) => n + 1)), []);
  const untangling = currentUntangling();
  if (!untangling) return null;
  return (
    <div class="review-bar untangle-bar" role="status">
      <span>Untangling: {untangling.starting} crossings → {untangling.best}</span>
      <progress value={untangling.progress} max={1} />
      <button onClick={cancelUntangle}>Stop</button>
    </div>
  );
}

function Empty() {
  return (
    <div class="empty">
      <p>Open a data model from the library, or make a new one.</p>
    </div>
  );
}

function ReviewBar({ summary }: { summary: string | null }) {
  return (
    <div class="review-bar">
      <span>Reviewing: {summary ?? "No changes"}</span>
      <button onClick={() => act(() => core.endReview())}>End Review</button>
    </div>
  );
}

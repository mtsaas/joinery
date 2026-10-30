// The canvas's commands, for the palette (Ctrl+K), the shortcuts and the menus, as the Mac's PaletteCommands and
// CanvasCommands: each says what it does to what's selected now.
import { core, edit, type Point, type Rect } from "../core.ts";
import { act, getState, notify, set, settings } from "../store.ts";
import { canvas, clearSelection, deleteSelection, redraw } from "./Canvas.tsx";
import { Metrics } from "./metrics.ts";

export interface Command {
  id: string;
  title: string;
  subtitle?: string;
  /** Shown at the trailing edge, as on a menu item. */
  shortcut?: string;
  destructive?: boolean;
  run: () => void;
}

/** What the window does for the commands: set by App. */
export const ui = {
  editCell: (_table: string, _column: string | null, _part: "name" | "type" | null) => {},
  openDesigner: (_table: string) => {},
  openPalette: () => {},
  toggleMinimap: () => {},
};

/** How well `query` matches `text` as letters in order, higher being better: consecutive letters and letters starting
 * words count extra. Null if it doesn't match. As the Mac's `PaletteCommand.score`. */
export function score(query: string, text: string): number | null {
  const q = query.toLowerCase(), t = text.toLowerCase();
  let total = 0, start = 0, previous = -2;
  for (const letter of q) {
    if (letter === " ") continue;
    const found = t.indexOf(letter, start);
    if (found < 0) return null;
    total += found === previous + 1 ? 3 : 1;
    if (found === 0 || " _.".includes(t[found - 1])) total += 2;
    previous = found;
    start = found + 1;
  }
  return total;
}

/** The selected tables, with the members of selected groups, as the Mac's `selectedTablesAndMembers`. */
export function selectedTables(): string[] {
  const o = canvas.overlay, scene = getState().scene;
  const ids = new Set(o.selectedTables);
  for (const table of scene?.tables ?? []) if (table.group && o.selectedGroups.has(table.group)) ids.add(table.id);
  return [...ids];
}

function select(tables: string[]) {
  clearSelection();
  for (const id of tables) canvas.overlay.selectedTables.add(id);
  redraw();
}

/** The middle of the canvas in view, in canvas points. */
function visible(): Rect {
  const { zoom, offset, width, height } = canvas.view;
  return [-offset[0] / zoom, -offset[1] / zoom, width / zoom, height / zoom];
}

// MARK: The clipboard

/** The last clip copied here, as its file holds it, and how many times it's been pasted. */
let clip: string | null = null;
let pastes = 0;

export function copy(): boolean {
  const tables = selectedTables();
  if (!tables.length) return false;
  clip = core.copy(JSON.stringify({ tables, groups: [...canvas.overlay.selectedGroups] }));
  pastes = 0;
  void navigator.clipboard?.writeText(core.markdown(JSON.stringify({ tables }), getState().name || "Data Model")).catch(() => {});
  return true;
}

export function cut() {
  if (copy()) deleteSelection();
}

/** Pastes the clip: over the original, a step down and right each time; elsewhere, in the middle of the view. */
export function paste() {
  if (!clip) return;
  const parsed = JSON.parse(clip) as { tables: { position: Point; columns: { id: string }[] }[] };
  if (!parsed.tables?.length) return;
  const frames = parsed.tables.map((t): Rect => [t.position[0], t.position[1], Metrics.tableWidth, Metrics.headerHeight + t.columns.length * Metrics.rowHeight]);
  const left = Math.min(...frames.map((f) => f[0])), top = Math.min(...frames.map((f) => f[1]));
  const right = Math.max(...frames.map((f) => f[0] + f[2])), bottom = Math.max(...frames.map((f) => f[1] + f[3]));
  const view = visible();
  const inView = left < view[0] + view[2] && right > view[0] && top < view[1] + view[3] && bottom > view[1];
  const columns = new Set(getState().scene?.tables.flatMap((t) => t.columns.map((c) => c.id)));
  const isOverOriginal = inView && parsed.tables.some((t) => t.columns.some((c) => columns.has(c.id)));
  pastes += 1;
  const step = 32 * (isOverOriginal ? pastes : pastes - 1);
  const offset: Point = isOverOriginal ? [step, step]
    : [view[0] + view[2] / 2 - (left + right) / 2 + step, view[1] + view[3] / 2 - (top + bottom) / 2 + step];
  const pasted = act(() => edit<{ tables: string[]; ties: string[] }>("paste", { clip, offset }));
  if (pasted) {
    select(pasted.tables);
    for (const id of pasted.ties) canvas.overlay.selectedTies.add(id);
  }
}

export function duplicate() {
  if (copy()) paste();
}

export function copyMarkdown() {
  const text = core.markdown(JSON.stringify({ tables: selectedTables() }), getState().name || "Data Model");
  navigator.clipboard?.writeText(text).then(() => notify("Copied as Markdown"), () => notify("Couldn't copy to the clipboard"));
}

// MARK: Focus

/** Focus mode: the tables focused on, whose neighborhood stays bright while the rest fade. */
let focus: string[] | null = null;

function applyFocus() {
  const scene = getState().scene;
  if (!focus?.length || !scene) {
    canvas.overlay.faded = null;
  } else {
    const bright = new Set<string>(JSON.parse(core.neighborhood(JSON.stringify({ tables: focus }))));
    canvas.overlay.faded = new Set(scene.tables.filter((t) => !bright.has(t.id)).map((t) => t.id));
  }
  redraw();
}

export function toggleFocus() {
  focus = focus ? null : selectedTables();
  if (focus && !focus.length) focus = null;
  applyFocus();
}

export function focusOnSelection() {
  const tables = selectedTables();
  focus = tables.length ? tables : null;
  applyFocus();
}

export function addSelectionToFocus() {
  focus = [...new Set([...(focus ?? []), ...selectedTables()])];
  applyFocus();
}

export const isFocused = () => focus !== null;

/** Keeps focus's fading in step as the model changes. */
export function refreshFocus() {
  if (focus) applyFocus();
}

// MARK: Untangling

export interface Untangling {
  progress: number;
  starting: number;
  best: number;
}

let untangling: Untangling | null = null;
let untangleListeners = new Set<() => void>();
export const currentUntangling = () => untangling;
export function onUntangle(listener: () => void) {
  untangleListeners.add(listener);
  return () => void untangleListeners.delete(listener);
}

/** Moves the selected tables (or all of them) to cross fewer wires, showing them move, as the Mac's. */
export function untangle() {
  if (untangling) return;
  const tables = selectedTables().length ? selectedTables() : getState().scene?.tables.map((t) => t.id) ?? [];
  if (tables.length < 2) return;
  core.untangleStart(JSON.stringify({ tables }));
  untangling = { progress: 0, starting: 0, best: 0 };
  const tick = () => {
    const step = JSON.parse(core.untangleStep(8)) as ({ offsets: Record<string, Point>; done: boolean } & Untangling) | null;
    if (!step) return finish(false);
    untangling = { progress: step.progress, starting: step.starting, best: step.best };
    canvas.overlay.tableOffsets = step.offsets;
    untangleListeners.forEach((l) => l());
    redraw();
    if (step.done) finish(true); else setTimeout(tick, 4);
  };
  setTimeout(tick, 0);
}

export function cancelUntangle() {
  if (untangling) finish(false);
}

function finish(apply: boolean) {
  canvas.overlay.tableOffsets = {};
  const result = act(() => JSON.parse(core.untangleFinish(apply)) as { before: number; after: number } | null);
  untangling = null;
  untangleListeners.forEach((l) => l());
  redraw();
  if (result) {
    notify(result.after < result.before ? `${result.before} crossings → ${result.after}` : `No arrangement crosses fewer than ${result.before}`);
  }
}

// MARK: The list

export function newTable() {
  const view = visible();
  const id = act(() => edit<string>("addTable", { at: [view[0] + view[2] / 2 - Metrics.tableWidth / 2, view[1] + view[3] / 2 - 40] }));
  if (id) {
    select([id]);
    ui.editCell(id, null, null);
  }
}

/** Every command that applies now, most likely first. */
export function commands(): Command[] {
  const scene = getState().scene;
  if (!scene) return [];
  const o = canvas.overlay;
  const tables = selectedTables();
  const one = tables.length === 1 ? scene.tables.find((t) => t.id === tables[0]) : undefined;
  const groups = [...o.selectedGroups];
  const list: Command[] = [{ id: "new-table", title: "New Table", shortcut: "T", run: newTable }];
  if (one) {
    list.push(
      { id: "design", title: "Open in Designer", subtitle: one.name, run: () => ui.openDesigner(one.id) },
      { id: "rename", title: "Rename Table", subtitle: one.name, shortcut: "Return", run: () => ui.editCell(one.id, null, null) },
      { id: "add-column", title: "Add Column", subtitle: one.name, run: () => {
        const id = act(() => edit<string>("addColumn", { table: one.id, after: one.columns.at(-1)?.id ?? null }));
        if (id) ui.editCell(one.id, id, "name");
      } },
    );
  }
  if (tables.length) {
    list.push(
      { id: "group", title: "Group Tables", subtitle: "as a schema", shortcut: "Ctrl+G", run: () => {
        const id = act(() => edit<string>("group", { tables }));
        if (id) { clearSelection(); o.selectedGroups.add(id); redraw(); }
      } },
      { id: "copy", title: "Copy", shortcut: "Ctrl+C", run: () => void copy() },
      { id: "cut", title: "Cut", shortcut: "Ctrl+X", run: cut },
      { id: "duplicate", title: "Duplicate", shortcut: "Ctrl+D", run: duplicate },
      { id: "untangle", title: "Untangle Selection", subtitle: "move them to cross fewer wires", run: untangle },
      { id: "focus-selection", title: "Focus on Selection", shortcut: "Shift+F", run: focusOnSelection },
    );
    if (focus) list.push({ id: "focus-add", title: "Add Selection to Focus", run: addSelectionToFocus });
    if (tables.some((id) => scene.tables.find((t) => t.id === id)?.group)) {
      list.push({ id: "ungroup-tables", title: "Remove from Group", run: () => act(() => edit("removeFromGroups", { tables })) });
    }
    if (tables.length > 1) {
      for (const [alignment, title] of [["left", "Align Left Edges"], ["center", "Align Centers"], ["right", "Align Right Edges"],
        ["top", "Align Top Edges"], ["middle", "Align Middles"], ["bottom", "Align Bottom Edges"]] as const) {
        list.push({ id: `align-${alignment}`, title, run: () => act(() => edit("align", { tables, ties: [...o.selectedTies], alignment })) });
      }
      list.push(
        { id: "distribute-h", title: "Distribute Horizontally", run: () => act(() => edit("distribute", { tables, horizontally: true })) },
        { id: "distribute-v", title: "Distribute Vertically", run: () => act(() => edit("distribute", { tables, horizontally: false })) },
      );
    }
    list.push({ id: "arrange-selection", title: "Arrange Selection", subtitle: "hierarchical", run: () => act(() => edit("arrange", { layout: "hierarchical", tables })) });
  }
  if (groups.length) {
    list.push(
      { id: "bundle", title: "Bundle Shared Wires", subtitle: "a port for each column 3 or more go to", run: () => act(() => edit("bundle", { groups })) },
      { id: "remove-ports", title: "Remove Ports", subtitle: "wires run all the way again", run: () => act(() => edit("removePorts", { groups })) },
      { id: "ungroup", title: "Ungroup", shortcut: "Ctrl+Shift+G", run: () => act(() => edit("ungroup", { groups })) },
    );
  }
  if (tables.length || groups.length || o.selectedWires.size || o.selectedTies.size) {
    list.push({ id: "delete", title: "Delete Selection", destructive: true, shortcut: "Delete", run: deleteSelection });
  }
  list.push(
    { id: "paste", title: "Paste", shortcut: "Ctrl+V", run: paste },
    { id: "select-all", title: "Select All", shortcut: "Ctrl+A", run: () => select(scene.tables.map((t) => t.id)) },
    { id: "untangle-all", title: "Untangle", subtitle: "every table", run: () => { clearSelection(); untangle(); } },
    { id: "arrange-hierarchical", title: "Arrange: Hierarchical", subtitle: "referenced tables to the left", run: () => act(() => edit("arrange", { layout: "hierarchical" })) },
    { id: "arrange-groups", title: "Arrange: Grouped", subtitle: "related tables in blocks", run: () => act(() => edit("arrange", { layout: "orthogonalGroups" })) },
    { id: "focus", title: "Focus Mode", subtitle: focus ? "On" : "Off", shortcut: "F", run: toggleFocus },
    { id: "avoid", title: "Wires Avoid Tables", subtitle: settings.avoidTables ? "On" : "Off", run: () => { settings.avoidTables = !settings.avoidTables; redraw(); } },
    { id: "minimap", title: "Show Minimap", shortcut: "Ctrl+Shift+M", run: () => ui.toggleMinimap() },
    { id: "copy-markdown", title: "Copy as Markdown", subtitle: tables.length ? "the selected tables" : "every table", shortcut: "Ctrl+Shift+C", run: copyMarkdown },
    { id: "zoom-in", title: "Zoom In", shortcut: "Ctrl++", run: () => canvas.zoomTo(canvas.view.zoom * 1.25) },
    { id: "zoom-out", title: "Zoom Out", shortcut: "Ctrl+-", run: () => canvas.zoomTo(canvas.view.zoom * 0.8) },
    { id: "actual-size", title: "Actual Size", shortcut: "Ctrl+0", run: () => canvas.zoomTo(1) },
    { id: "fit", title: "Zoom to Fit", shortcut: "Ctrl+1", run: () => canvas.fit() },
    { id: "mcp", title: "Connect an AI Assistant", subtitle: "MCP", run: () => set({ showsSettings: true }) },
  );
  return list;
}

/** Tables to jump to from the palette: selecting one shows it in the middle of the view. */
export function tableCommands(): Command[] {
  return (getState().scene?.tables ?? []).map((table) => ({
    id: `table-${table.id}`,
    title: table.name,
    subtitle: "table",
    run: () => {
      select([table.id]);
      const [x, y, w, h] = table.frame;
      const { zoom } = canvas.view;
      canvas.view.offset = [canvas.view.width / 2 - (x + w / 2) * zoom, canvas.view.height / 2 - (y + h / 2) * zoom];
      redraw();
    },
  }));
}

/** The commands' keys, on top of the canvas's own (undo, zoom, delete): none while typing in a field. */
export function handleKey(e: KeyboardEvent): boolean {
  if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement) return false;
  if (!getState().scene) return false;
  const mod = e.ctrlKey || e.metaKey, key = e.key.toLowerCase();
  const run = (f: () => void) => { e.preventDefault(); f(); return true; };
  if (mod && key === "k") return run(ui.openPalette);
  if (mod && e.shiftKey && key === "c") return run(copyMarkdown);
  if (mod && key === "c") return run(() => void copy());
  if (mod && key === "x") return run(cut);
  if (mod && key === "v") return run(paste);
  if (mod && key === "d") return run(duplicate);
  if (mod && e.shiftKey && key === "g") return run(() => { const groups = [...canvas.overlay.selectedGroups]; if (groups.length) act(() => edit("ungroup", { groups })); });
  if (mod && key === "g") return run(() => commands().find((c) => c.id === "group")?.run());
  if (mod && e.shiftKey && key === "m") return run(ui.toggleMinimap);
  if (mod && key === "1") return run(() => canvas.fit());
  if (mod && e.altKey && key === "t") return run(newTable);
  if (mod || e.altKey) return false;
  if (key === "f") return run(e.shiftKey ? focusOnSelection : toggleFocus);
  if (key === "t") return run(newTable);
  if (e.key === "Escape" && untangling) return run(cancelUntangle);
  if (e.key === "Enter") {
    const tables = selectedTables();
    if (tables.length === 1 && canvas.overlay.selectedTables.size === 1) return run(() => ui.editCell(tables[0], null, null));
  }
  return false;
}

// The canvas: draws the open model and turns the pointer and keys into edits, as the Mac's CanvasView does.
import { useEffect, useRef } from "preact/hooks";
import { core, edit, frame as readFrame, type Frame, type Point, type Rect } from "../core.ts";
import { act, getState, saveVersionNow, settings } from "../store.ts";
import { theme as makeTheme } from "../theme.ts";
import { hitTest, type Hit } from "./hit.ts";
import { Metrics } from "./metrics.ts";
import { draw, emptyOverlay, moved, type Overlay, type View } from "./render.ts";

export interface CanvasHandle {
  view: View;
  overlay: Overlay;
  zoomTo(zoom: number, around?: Point): void;
  fit(): void;
  redraw(): void;
}

/** The canvas's state, outside Preact: it changes every frame. */
export const canvas: CanvasHandle = {
  view: { zoom: 1, offset: [80, 80], width: 0, height: 0 },
  overlay: emptyOverlay(),
  zoomTo: () => {},
  fit: () => {},
  redraw: () => {},
};

type Drag =
  | { kind: "pan"; start: Point; offset: Point }
  | { kind: "move"; start: Point; tables: string[]; moved: boolean }
  | { kind: "connect"; column: string; from: Point; color: string }
  | { kind: "marquee"; start: Point; additive: boolean; before: Set<string> }
  | { kind: "stroke"; start: Point };

const minZoom = 0.1, maxZoom = 3;

export function Canvas({ onEditCell, onContextMenu }: {
  onEditCell?: (table: string, column: string | null, part: "name" | "type" | null) => void;
  onContextMenu?: (hit: Hit, at: Point) => void;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const element = ref.current!;
    const ctx = element.getContext("2d")!;
    const media = matchMedia("(prefers-color-scheme: dark)");
    let theme = makeTheme(media.matches);
    const onScheme = () => { theme = makeTheme(media.matches); request(); };
    media.addEventListener("change", onScheme);

    let frame: Frame | null = null, animating = false, raf = 0, drag: Drag | null = null, lastRevision = -1;
    const { view, overlay } = canvas;

    const toCanvas = (e: { clientX: number; clientY: number }): Point => {
      const box = element.getBoundingClientRect();
      return [(e.clientX - box.left - view.offset[0]) / view.zoom, (e.clientY - box.top - view.offset[1]) / view.zoom];
    };

    function render(time: number) {
      raf = 0;
      const { scene, revision } = getState();
      if (!scene) {
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.fillStyle = theme.canvas;
        ctx.fillRect(0, 0, element.width, element.height);
        return;
      }
      if (revision !== lastRevision) lastRevision = revision;
      frame = readFrame(time / 1000, overlay.tableOffsets, {}, settings.avoidTables);
      draw(ctx, view, scene, frame, theme, overlay);
      animating = frame.moving;
      if (animating) request();
    }

    function request() {
      if (!raf) raf = requestAnimationFrame(render);
    }
    canvas.redraw = request;

    function resize() {
      const box = element.getBoundingClientRect();
      const dpr = window.devicePixelRatio || 1;
      view.width = box.width;
      view.height = box.height;
      element.width = Math.round(box.width * dpr);
      element.height = Math.round(box.height * dpr);
      request();
    }
    const observer = new ResizeObserver(resize);
    observer.observe(element);

    canvas.zoomTo = (zoom, around) => {
      const z = Math.min(maxZoom, Math.max(minZoom, zoom));
      const [ax, ay] = around ?? [view.width / 2, view.height / 2];
      view.offset = [ax - ((ax - view.offset[0]) / view.zoom) * z, ay - ((ay - view.offset[1]) / view.zoom) * z];
      view.zoom = z;
      zoomListeners.forEach((l) => l());
      request();
    };
    canvas.fit = () => {
      const bounds = getState().scene?.bounds;
      if (!bounds || !view.width) return;
      const pad = 60;
      const z = Math.min(1, Math.max(minZoom, Math.min((view.width - pad * 2) / bounds[2], (view.height - pad * 2) / bounds[3])));
      view.zoom = z;
      view.offset = [(view.width - bounds[2] * z) / 2 - bounds[0] * z, (view.height - bounds[3] * z) / 2 - bounds[1] * z];
      zoomListeners.forEach((l) => l());
      request();
    };

    function hit(p: Point): Hit {
      return hitTest(p, getState().scene!, frame, overlay, view.zoom);
    }

    function select(tables: string[], additive = false) {
      if (!additive) clearSelection();
      for (const id of tables) overlay.selectedTables.add(id);
      selectionListeners.forEach((l) => l());
    }

    const onDown = (e: PointerEvent) => {
      if (!getState().scene) return;
      element.focus();
      element.setPointerCapture(e.pointerId);
      const p = toCanvas(e);
      // The middle button, or the space bar held, pans.
      if (e.button === 1 || spaceDown) {
        drag = { kind: "pan", start: [e.clientX, e.clientY], offset: [...view.offset] };
        return;
      }
      if (e.button !== 0) return;
      const h = hit(p);
      if (e.altKey && h.kind !== "socket") {
        drag = { kind: "stroke", start: p };
        return;
      }
      switch (h.kind) {
        case "socket": {
          const column = h.table.columns[h.row];
          drag = { kind: "connect", column: column.id, from: h.center, color: makeTheme(media.matches).color(column.references ?? h.table.color) };
          break;
        }
        case "header":
        case "cell": {
          const additive = e.shiftKey || e.ctrlKey || e.metaKey;
          if (additive && overlay.selectedTables.has(h.table.id)) {
            overlay.selectedTables.delete(h.table.id);
            selectionListeners.forEach((l) => l());
          } else if (!overlay.selectedTables.has(h.table.id)) {
            select([h.table.id], additive);
          }
          drag = { kind: "move", start: p, tables: [...overlay.selectedTables], moved: false };
          break;
        }
        case "tie":
          clearSelection();
          overlay.selectedTies.add(h.id);
          selectionListeners.forEach((l) => l());
          break;
        case "port":
          clearSelection();
          overlay.selectedWires.add(h.id);
          selectionListeners.forEach((l) => l());
          break;
        case "group": {
          if (h.label) {
            clearSelection();
            overlay.selectedGroups.add(h.id);
            const members = getState().scene!.tables.filter((t) => t.group === h.id).map((t) => t.id);
            for (const id of members) overlay.selectedTables.add(id);
            selectionListeners.forEach((l) => l());
            drag = { kind: "move", start: p, tables: members, moved: false };
            break;
          }
          beginEmpty(e, p);
          break;
        }
        case "canvas":
          beginEmpty(e, p);
          break;
      }
      request();
    };

    function beginEmpty(e: PointerEvent, p: Point) {
      const wire = JSON.parse(core.wireAt(p[0], p[1], Metrics.wireHitRadius / view.zoom + 2));
      if (wire) {
        clearSelection();
        overlay.selectedWires.add(wire.id);
        selectionListeners.forEach((l) => l());
        return;
      }
      const additive = e.shiftKey || e.ctrlKey || e.metaKey;
      if (!additive) clearSelection();
      drag = { kind: "marquee", start: p, additive, before: new Set(overlay.selectedTables) };
    }

    const onMove = (e: PointerEvent) => {
      const scene = getState().scene;
      if (!scene) return;
      const p = toCanvas(e);
      shareCursor(p);
      if (!drag) {
        const h = hit(p);
        const socketBefore = overlay.hoveredSocket, tieBefore = overlay.hoveredTie;
        overlay.hoveredSocket = h.kind === "socket" ? { column: h.column, side: h.side } : null;
        overlay.hoveredTie = h.kind === "tie" ? h.id : null;
        element.style.cursor = h.kind === "socket" ? "crosshair" : h.kind === "header" && h.grip ? "grab" : "default";
        if (socketBefore?.column !== overlay.hoveredSocket?.column || socketBefore?.side !== overlay.hoveredSocket?.side || tieBefore !== overlay.hoveredTie) request();
        return;
      }
      switch (drag.kind) {
        case "pan":
          view.offset = [drag.offset[0] + e.clientX - drag.start[0], drag.offset[1] + e.clientY - drag.start[1]];
          break;
        case "move": {
          const by: Point = [p[0] - drag.start[0], p[1] - drag.start[1]];
          if (!drag.moved && Math.hypot(by[0], by[1]) * view.zoom < 3) return;
          drag.moved = true;
          overlay.tableOffsets = Object.fromEntries(drag.tables.map((id) => [id, by]));
          element.style.cursor = "grabbing";
          break;
        }
        case "connect": {
          const h = hit(p);
          overlay.hoveredSocket = h.kind === "socket" ? { column: h.column, side: h.side } : null;
          overlay.connecting = { from: drag.from, to: h.kind === "socket" ? h.center : p, color: drag.color };
          break;
        }
        case "marquee": {
          const r: Rect = [Math.min(drag.start[0], p[0]), Math.min(drag.start[1], p[1]), Math.abs(p[0] - drag.start[0]), Math.abs(p[1] - drag.start[1])];
          overlay.marquee = r;
          overlay.selectedTables = new Set(drag.additive ? drag.before : []);
          for (const t of scene.tables) {
            const f = t.frame;
            if (f[0] < r[0] + r[2] && f[0] + f[2] > r[0] && f[1] < r[1] + r[3] && f[1] + f[3] > r[1]) overlay.selectedTables.add(t.id);
          }
          selectionListeners.forEach((l) => l());
          break;
        }
        case "stroke":
          overlay.stroke = { start: drag.start, end: p };
          break;
      }
      request();
    };

    const onUp = (e: PointerEvent) => {
      const current = drag;
      drag = null;
      if (!current) return;
      const p = toCanvas(e);
      switch (current.kind) {
        case "move":
          if (current.moved) {
            const by: Point = [p[0] - current.start[0], p[1] - current.start[1]];
            overlay.tableOffsets = {};
            act(() => edit("move", { tables: current.tables, ties: [], by }));
          }
          element.style.cursor = "default";
          break;
        case "connect": {
          overlay.connecting = null;
          const h = hit(p);
          if (h.kind === "socket" && h.column !== current.column) act(() => edit("connect", { column: current.column, toColumn: h.column }));
          else if ((h.kind === "header" || h.kind === "cell") && !h.table.columns.some((c) => c.id === current.column)) {
            act(() => edit("connect", { column: current.column, toTable: h.table.id }));
          }
          break;
        }
        case "marquee":
          overlay.marquee = null;
          break;
        case "stroke":
          overlay.stroke = null;
          act(() => core.zipTie(current.start[0], current.start[1], p[0], p[1]));
          break;
      }
      request();
    };

    const onDouble = (e: MouseEvent) => {
      const scene = getState().scene;
      if (!scene) return;
      const p = toCanvas(e);
      const h = hit(p);
      if (h.kind === "header" && !h.grip) onEditCell?.(h.table.id, null, null);
      else if (h.kind === "cell" && h.part !== "key") onEditCell?.(h.table.id, h.column, h.part);
      else if (h.kind === "cell" && h.part === "key") {
        const column = h.table.columns[h.row];
        act(() => edit("setColumn", { column: column.id, primaryKey: !column.primaryKey }));
      } else if (h.kind === "canvas") {
        const id = act(() => edit<string>("addTable", { at: [p[0] - Metrics.tableWidth / 2, p[1] - Metrics.headerHeight / 2] }));
        if (id) {
          select([id]);
          onEditCell?.(id, null, null);
        }
      }
    };

    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const box = element.getBoundingClientRect();
      // Pinching on a trackpad arrives as the wheel with Ctrl held, as does Ctrl+wheel.
      if (e.ctrlKey || e.metaKey) {
        canvas.zoomTo(view.zoom * Math.exp(-e.deltaY * (e.deltaMode ? 0.05 : 0.0025)), [e.clientX - box.left, e.clientY - box.top]);
      } else {
        const lines = e.deltaMode === 1 ? 16 : 1;
        const [dx, dy] = e.shiftKey && !e.deltaX ? [e.deltaY, 0] : [e.deltaX, e.deltaY];
        view.offset = [view.offset[0] - dx * lines, view.offset[1] - dy * lines];
        request();
      }
    };

    const onContext = (e: MouseEvent) => {
      e.preventDefault();
      const scene = getState().scene;
      if (!scene) return;
      const p = toCanvas(e);
      const h = hit(p);
      if ((h.kind === "header" || h.kind === "cell") && !overlay.selectedTables.has(h.table.id)) select([h.table.id]);
      onContextMenu?.(h, [e.clientX, e.clientY]);
      request();
    };

    let spaceDown = false;
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      const mod = e.ctrlKey || e.metaKey;
      if (e.key === " ") { spaceDown = e.type === "keydown"; element.style.cursor = spaceDown ? "grab" : "default"; return; }
      if (e.type !== "keydown") return;
      if (mod && e.key.toLowerCase() === "z") { e.preventDefault(); act(() => (e.shiftKey ? core.redo() : core.undo())); }
      else if (mod && e.key.toLowerCase() === "y") { e.preventDefault(); act(() => core.redo()); }
      else if (mod && e.key.toLowerCase() === "s") { e.preventDefault(); void saveVersionNow(); }
      else if (mod && e.key.toLowerCase() === "a") { e.preventDefault(); select(getState().scene?.tables.map((t) => t.id) ?? []); }
      else if (mod && (e.key === "=" || e.key === "+")) { e.preventDefault(); canvas.zoomTo(view.zoom * 1.25); }
      else if (mod && e.key === "-") { e.preventDefault(); canvas.zoomTo(view.zoom / 1.25); }
      else if (mod && e.key === "0") { e.preventDefault(); canvas.zoomTo(1); }
      else if (mod && e.key === "9") { e.preventDefault(); canvas.fit(); }
      else if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); deleteSelection(); }
      else if (e.key === "Escape") { clearSelection(); selectionListeners.forEach((l) => l()); }
      else return;
      request();
    };

    element.addEventListener("pointerdown", onDown);
    element.addEventListener("pointermove", onMove);
    element.addEventListener("pointerup", onUp);
    element.addEventListener("dblclick", onDouble);
    element.addEventListener("wheel", onWheel, { passive: false });
    element.addEventListener("contextmenu", onContext);
    element.addEventListener("pointerleave", () => shareCursor(null));
    window.addEventListener("keydown", onKey);
    window.addEventListener("keyup", onKey);
    const unsubscribe = subscribeRedraw(request);
    return () => {
      cancelAnimationFrame(raf);
      observer.disconnect();
      media.removeEventListener("change", onScheme);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("keyup", onKey);
      unsubscribe();
    };
  }, []);

  return <canvas ref={ref} class="canvas" tabIndex={0} />;
}

export function clearSelection() {
  const o = canvas.overlay;
  o.selectedTables.clear();
  o.selectedWires.clear();
  o.selectedTies.clear();
  o.selectedGroups.clear();
}

export function deleteSelection() {
  const o = canvas.overlay;
  const scene = getState().scene;
  if (!scene) return;
  const ports = new Set<string>(), relationships: string[] = [];
  for (const id of o.selectedWires) relationships.push(id);
  act(() => edit("removeTables", {
    tables: [...o.selectedTables], ties: [...o.selectedTies], groups: [...o.selectedGroups].filter(() => o.selectedTables.size === 0),
    relationships, ports: [...ports],
  }));
  clearSelection();
  selectionListeners.forEach((l) => l());
}

// Others' pointers and selections go out through the session, at most every 50 ms.
let cursorTimer: number | undefined, pendingCursor: Point | null = null;
function shareCursor(p: Point | null) {
  if (!getState().session) return;
  pendingCursor = p;
  if (cursorTimer) return;
  cursorTimer = window.setTimeout(() => {
    cursorTimer = undefined;
    act(() => core.sharePresence(JSON.stringify({ cursor: pendingCursor, selection: [...canvas.overlay.selectedTables] })));
  }, 50);
}

const zoomListeners = new Set<() => void>();
const selectionListeners = new Set<() => void>();
const redrawListeners = new Set<() => void>();

export function onZoom(listener: () => void) { zoomListeners.add(listener); return () => void zoomListeners.delete(listener); }
export function onSelection(listener: () => void) { selectionListeners.add(listener); return () => void selectionListeners.delete(listener); }
function subscribeRedraw(listener: () => void) { redrawListeners.add(listener); return () => void redrawListeners.delete(listener); }

/** Redraws the canvas, after the scene or the overlay changes from outside it. */
export function redraw() { redrawListeners.forEach((l) => l()); }

export { moved };

// The canvas: draws the open model and turns the pointer and keys into edits, as the Mac's CanvasView does. Each press
// decides what it's on (hit.ts); a drag from there, or a click, does what suits it.
import { useEffect, useRef, useState } from "preact/hooks";
import { core, edit, frame as readFrame, type Frame, type Point, type Preview, type Rect, type Scene } from "../core.ts";
import { act, getState, saveVersionNow, settings } from "../store.ts";
import { fonts, theme as makeTheme } from "../theme.ts";
import { axisLocked, neighborhood, pull, snap, wiresAmong, type Pull } from "./gestures.ts";
import { hitTest, portHint, type Hit, type PortHint, type WireHit } from "./hit.ts";
import { Metrics } from "./metrics.ts";
import { draw, emptyOverlay, moved, type Overlay, type View } from "./render.ts";

export interface CanvasHandle {
  view: View;
  overlay: Overlay;
  /** Focus mode's tables, null while it's off; empty until something's selected. */
  focus: Set<string> | null;
  /** The zip-tie tool: while it's on, every drag on the canvas ties the wires it crosses. */
  tying: boolean;
  zoomTo(zoom: number, around?: Point): void;
  fit(): void;
  redraw(): void;
  /** Draws now, without waiting for a frame: webviews skip frames while the window's hidden. */
  drawNow(): void;
}

/** The canvas's state, outside Preact: it changes every frame. */
export const canvas: CanvasHandle = {
  view: { zoom: 1, offset: [80, 80], width: 0, height: 0 },
  overlay: emptyOverlay(),
  focus: null,
  tying: false,
  zoomTo: () => {},
  fit: () => {},
  redraw: () => {},
  drawNow: () => {},
};

/** The wires, ports and ties as last drawn. */
let lastFrame: Frame | null = null;

type Drag =
  | { kind: "pan"; start: Point; offset: Point }
  | { kind: "move"; start: Point; tables: string[]; ties: string[]; moved: boolean; merge: { into: string; along: Point } | null }
  | { kind: "connect"; column: string; from: Point; color: string; moved: boolean }
  | { kind: "portConnect"; port: string; isOutside: boolean; group: string; column: string | null; from: Point; moved: boolean }
  | { kind: "marquee"; start: Point; additive: boolean; before: Set<string>; beforeTies: Set<string> }
  | { kind: "stroke"; start: Point }
  | { kind: "cable"; hit: WireHit; start: Point; pull: Pull | null; extend: boolean }
  | { kind: "port"; id: string; group: string; start: Point; spot: { side: string; along: number } | null }
  | { kind: "newPort"; hint: PortHint; start: Point; screen: Point };

const minZoom = 0.1, maxZoom = 3;

export function Canvas({ onEditCell, onContextMenu, onOpenDesigner }: {
  onEditCell?: (table: string, column: string | null, part: "name" | "type" | null) => void;
  onContextMenu?: (hit: Hit, at: Point) => void;
  /** Double-clicking a table's grip opens it in the designer. */
  onOpenDesigner?: (table: string) => void;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const [renaming, setRenaming] = useState<{ group: string; name: string } | null>(null);

  useEffect(() => {
    const element = ref.current!;
    const ctx = element.getContext("2d")!;
    const media = matchMedia("(prefers-color-scheme: dark)");
    let theme = makeTheme(media.matches);
    const onScheme = () => { theme = makeTheme(media.matches); request(); };
    media.addEventListener("change", onScheme);

    let raf = 0, drag: Drag | null = null, showsPortHint = false;
    let tieOffsets: Record<string, Point> = {}, preview: Preview = {};
    const { view, overlay } = canvas;

    const toCanvas = (e: { clientX: number; clientY: number }): Point => {
      const box = element.getBoundingClientRect();
      return [(e.clientX - box.left - view.offset[0]) / view.zoom, (e.clientY - box.top - view.offset[1]) / view.zoom];
    };
    const screenDistance = (a: Point, b: Point) => Math.hypot(a[0] - b[0], a[1] - b[1]) * view.zoom;

    function render(time: number) {
      raf = 0;
      const { scene } = getState();
      if (!scene) {
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.fillStyle = theme.canvas;
        ctx.fillRect(0, 0, element.width, element.height);
        return;
      }
      highlight(scene);
      lastFrame = readFrame(time / 1000, overlay.tableOffsets, tieOffsets, settings.avoidTables, preview);
      draw(ctx, view, scene, lastFrame, theme, overlay);
      if (lastFrame.moving) request();
    }

    function request() {
      if (!raf) raf = requestAnimationFrame(render);
    }
    canvas.redraw = request;
    canvas.drawNow = () => { cancelAnimationFrame(raf); render(performance.now()); };

    /** What fades: in focus mode, tables not joined to those in focus; the wires shown over the rest are the selection's. */
    function highlight(scene: Scene) {
      const focus = canvas.focus && canvas.focus.size ? neighborhood(canvas.focus, scene) : null;
      overlay.faded = focus ? new Set(scene.tables.filter((t) => !focus.has(t.id)).map((t) => t.id)) : null;
      if (focus) { overlay.highlighted = wiresAmong(focus, scene); return; }
      const o = overlay;
      if (!o.selectedTables.size && !o.selectedWires.size && !o.selectedTies.size) { overlay.highlighted = null; return; }
      const columns = new Set(scene.tables.filter((t) => o.selectedTables.has(t.id)).flatMap((t) => t.columns.map((c) => c.id)));
      const wires = new Set(scene.wires.filter((w) => columns.has(w.from) || columns.has(w.to)).map((w) => w.id));
      for (const id of o.selectedWires) {
        wires.add(id);
        // A port's bus, with the wires through it.
        for (const w of lastFrame?.ports.find((p) => p.id === id)?.wires ?? []) wires.add(w);
      }
      for (const id of o.selectedTies) for (const w of scene.ties.find((t) => t.id === id)?.wires ?? []) wires.add(w);
      overlay.highlighted = wires;
    }

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

    const hit = (p: Point): Hit => hitTest(p, getState().scene!, lastFrame, overlay, view.zoom, showsPortHint);
    const changed = () => selectionListeners.forEach((l) => l());

    function selectTables(tables: string[], additive = false) {
      if (!additive) clearSelection();
      for (const id of tables) overlay.selectedTables.add(id);
      fillFocus();
      changed();
    }

    /** Focus turned on with nothing in it takes the first tables selected. */
    function fillFocus() {
      if (canvas.focus && !canvas.focus.size) canvas.focus = selectedTablesAndMembers();
    }

    function beginMove(p: Point) {
      drag = { kind: "move", start: p, tables: [...overlay.selectedTables], ties: [...overlay.selectedTies], moved: false, merge: null };
    }

    const onDown = (e: PointerEvent) => {
      const scene = getState().scene;
      if (!scene) return;
      element.focus();
      element.setPointerCapture(e.pointerId);
      const p = toCanvas(e);
      // The middle button, or the space bar held, pans.
      if (e.button === 1 || spaceDown) {
        drag = { kind: "pan", start: [e.clientX, e.clientY], offset: [...view.offset] };
        return;
      }
      if (e.button !== 0) return;
      const additive = e.shiftKey || e.ctrlKey || e.metaKey;
      // With the zip-tie tool, or Alt, every drag ties.
      if (canvas.tying || (e.altKey && hit(p).kind !== "socket")) {
        drag = { kind: "stroke", start: p };
        return;
      }
      const h = hit(p);
      overlay.portHint = null;
      switch (h.kind) {
        case "socket": {
          const column = h.table.columns[h.row];
          drag = { kind: "connect", column: column.id, from: h.center, color: theme.color(column.references ?? h.table.color), moved: false };
          break;
        }
        case "portSocket": {
          const port = lastFrame?.ports.find((q) => q.id === h.port);
          if (port) drag = { kind: "portConnect", port: port.id, isOutside: h.isOutside, group: port.group, column: port.column, from: h.center, moved: false };
          break;
        }
        case "port": {
          const port = lastFrame?.ports.find((q) => q.id === h.id);
          if (port) drag = { kind: "port", id: port.id, group: port.group, start: p, spot: null };
          break;
        }
        case "tie":
          if (additive && overlay.selectedTies.has(h.id)) {
            overlay.selectedTies.delete(h.id);
            changed();
            break;
          }
          if (!overlay.selectedTies.has(h.id)) {
            if (!additive) clearSelection();
            overlay.selectedTies.add(h.id);
            changed();
          }
          beginMove(p);
          break;
        case "wire":
          drag = { kind: "cable", hit: h.hit, start: p, pull: null, extend: additive };
          break;
        case "newPort":
          drag = { kind: "newPort", hint: h.hint, start: p, screen: [e.clientX, e.clientY] };
          break;
        case "header":
        case "cell":
          if (additive && overlay.selectedTables.has(h.table.id)) {
            overlay.selectedTables.delete(h.table.id);
            changed();
          } else if (!overlay.selectedTables.has(h.table.id)) {
            selectTables([h.table.id], additive);
          }
          beginMove(p);
          break;
        case "group":
          if (h.label) {
            if (!overlay.selectedGroups.has(h.id)) {
              if (!additive) clearSelection();
              overlay.selectedGroups.add(h.id);
              for (const t of scene.tables) if (t.group === h.id) overlay.selectedTables.add(t.id);
              fillFocus();
              changed();
            }
            beginMove(p);
            break;
          }
          beginMarquee(additive, p);
          break;
        case "canvas":
          beginMarquee(additive, p);
          break;
      }
      request();
    };

    function beginMarquee(additive: boolean, p: Point) {
      if (!additive) { clearSelection(); changed(); }
      drag = { kind: "marquee", start: p, additive, before: new Set(overlay.selectedTables), beforeTies: new Set(overlay.selectedTies) };
    }

    const onMove = (e: PointerEvent) => {
      const scene = getState().scene;
      if (!scene) return;
      const p = toCanvas(e);
      shareCursor(p);
      if (!drag) return hover(p, scene);
      switch (drag.kind) {
        case "pan":
          view.offset = [drag.offset[0] + e.clientX - drag.start[0], drag.offset[1] + e.clientY - drag.start[1]];
          break;
        case "move": {
          let by: Point = [p[0] - drag.start[0], p[1] - drag.start[1]];
          if (!drag.moved && Math.hypot(by[0], by[1]) * view.zoom < 3) return;
          drag.moved = true;
          by = axisLocked(by, e.shiftKey);
          overlay.guides = [];
          // Snapped into line with other tables, unless Ctrl's held.
          if (drag.tables.length && !e.ctrlKey && !e.metaKey) {
            const ids = new Set(drag.tables);
            const locked = e.shiftKey;
            const snapped = snap(scene.tables.filter((t) => ids.has(t.id)).map((t) => t.frame), by,
              scene.tables.filter((t) => !ids.has(t.id)).map((t) => t.frame), 6 / view.zoom, !locked || by[0] !== 0, !locked || by[1] !== 0);
            by = snapped.offset;
            overlay.guides = snapped.guides;
          }
          overlay.tableOffsets = Object.fromEntries(drag.tables.map((id) => [id, by]));
          tieOffsets = Object.fromEntries(drag.ties.map((id) => [id, by]));
          // A zip tie or bend point dragged alone over a zip tie: shown combined, to go in.
          drag.merge = null;
          if (drag.ties.length === 1 && !drag.tables.length) {
            const tie = drag.ties[0];
            const dragged = scene.ties.find((t) => t.id === tie);
            const at: Point | null = dragged ? [dragged.position[0] + by[0], dragged.position[1] + by[1]] : null;
            const target = at && lastFrame?.ties.find((t) => t.id !== dragged!.id && t.count > 1
              && Math.hypot(t.center[0] - at[0], t.center[1] - at[1]) <= t.halfLength + Metrics.socketHitRadius);
            if (target) drag.merge = { into: target.id, along: target.direction };
          }
          preview = drag.merge ? { merge: { tie: drag.ties[0], ...drag.merge } } : {};
          overlay.hoveredTie = drag.merge?.into ?? null;
          element.style.cursor = "grabbing";
          break;
        }
        case "connect": {
          if (!drag.moved && screenDistance(p, drag.from) < 2) return;
          drag.moved = true;
          const h = hit(p);
          overlay.hoveredSocket = h.kind === "socket" ? { column: h.column, side: h.side } : null;
          overlay.connecting = { from: drag.from, to: h.kind === "socket" ? h.center : p, color: drag.color };
          break;
        }
        case "portConnect": {
          if (!drag.moved && screenDistance(p, drag.from) < 2) return;
          drag.moved = true;
          const h = hit(p);
          overlay.hoveredSocket = h.kind === "socket" ? { column: h.column, side: h.side } : null;
          overlay.connecting = { from: drag.from, to: h.kind === "socket" ? h.center : p, color: portColor(drag.port) };
          break;
        }
        case "port": {
          if (!drag.spot && screenDistance(p, drag.start) < 2) return;
          // Along the edge, to the spot nearest the pointer, around corners and all.
          const spot = JSON.parse(core.portSpot(drag.group, p[0], p[1], "{}")) as { side: string; along: number } | null;
          if (spot) {
            drag.spot = { side: spot.side, along: spot.along };
            preview = { port: { port: drag.id, ...drag.spot } };
          }
          element.style.cursor = "grabbing";
          break;
        }
        case "cable": {
          if (!drag.pull && screenDistance(p, drag.start) < 3) return;
          if (!drag.pull) {
            drag.pull = { cable: drag.hit.id, start: drag.hit.point, point: drag.hit.point, direction: drag.hit.tangent, segment: drag.hit.segment, popped: [], target: null };
            clearSelection();
            overlay.selectedWires.add(drag.hit.id);
            changed();
          }
          drag.pull = pull(drag.pull, p, scene, lastFrame?.ties ?? []);
          const { cable, popped, point, direction, segment } = drag.pull;
          preview = { pull: { cable, popped: popped.map((q) => q.id), point, direction, segment } };
          overlay.hoveredTie = drag.pull.target?.id ?? null;
          break;
        }
        case "newPort": {
          // Moved, it wasn't for a port: it's a drag on the canvas, a selection rectangle.
          if (Math.hypot(e.clientX - drag.screen[0], e.clientY - drag.screen[1]) < 3) return;
          const start = drag.start;
          beginMarquee(e.shiftKey, start);
          return onMove(e);
        }
        case "marquee": {
          const r: Rect = [Math.min(drag.start[0], p[0]), Math.min(drag.start[1], p[1]), Math.abs(p[0] - drag.start[0]), Math.abs(p[1] - drag.start[1])];
          overlay.marquee = r;
          // Only what's wholly inside it, so it can be drawn across a crowded canvas.
          const inside = (x: number, y: number) => x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3];
          overlay.selectedTables = new Set(drag.additive ? drag.before : []);
          overlay.selectedTies = new Set(drag.additive ? drag.beforeTies : []);
          for (const t of scene.tables) {
            const f = t.frame;
            if (inside(f[0], f[1]) && inside(f[0] + f[2], f[1] + f[3])) overlay.selectedTables.add(t.id);
          }
          for (const t of scene.ties) if (inside(t.position[0], t.position[1])) overlay.selectedTies.add(t.id);
          fillFocus();
          changed();
          break;
        }
        case "stroke":
          overlay.stroke = { start: drag.start, end: p };
          break;
      }
      request();
    };

    /** Hovering: the socket or tie under the pointer, the + by a group's edge, and the pointer's shape. */
    function hover(p: Point, scene: Scene) {
      const h = hitTest(p, scene, lastFrame, overlay, view.zoom, false);
      const before = JSON.stringify([overlay.hoveredSocket, overlay.hoveredTie, overlay.portHint]);
      overlay.hoveredSocket = h.kind === "socket" ? { column: h.column, side: h.side } : null;
      overlay.hoveredTie = h.kind === "tie" ? h.id : null;
      const hint = h.kind === "canvas" || h.kind === "group" ? portHint(p, scene, lastFrame, overlay, view.zoom) : null;
      showsPortHint = hint !== null;
      overlay.portHint = hint?.point ?? null;
      element.style.cursor = canvas.tying ? "crosshair"
        : h.kind === "socket" || h.kind === "portSocket" ? "crosshair"
        : hint && Math.hypot(hint.point[0] - p[0], hint.point[1] - p[1]) <= Metrics.portHintRadius / view.zoom ? "pointer"
        : h.kind === "port" || h.kind === "tie" || (h.kind === "header" && h.grip) || (h.kind === "group" && h.label) ? "grab"
        : "default";
      if (JSON.stringify([overlay.hoveredSocket, overlay.hoveredTie, overlay.portHint]) !== before) request();
    }

    function portColor(id: string): string {
      const port = lastFrame?.ports.find((q) => q.id === id);
      return port?.plugged ? theme.color(port.color) : theme.socket;
    }

    const onUp = (e: PointerEvent) => {
      const current = drag;
      drag = null;
      if (!current) return;
      const p = toCanvas(e);
      const scene = getState().scene;
      switch (current.kind) {
        case "move": {
          const by = overlay.tableOffsets[current.tables[0]] ?? tieOffsets[current.ties[0]];
          overlay.tableOffsets = {};
          tieOffsets = {};
          preview = {};
          overlay.guides = [];
          overlay.hoveredTie = null;
          if (current.moved && by) {
            if (current.merge) {
              const into = current.merge.into;
              act(() => edit("mergeTies", { tie: current.ties[0], by, into, along: current.merge!.along }));
              clearSelection();
              overlay.selectedTies.add(into);
              changed();
            } else {
              act(() => edit("move", { tables: current.tables, ties: current.ties, by }));
            }
          }
          element.style.cursor = "default";
          break;
        }
        case "connect": {
          overlay.connecting = null;
          if (!current.moved) break;
          const h = hit(p);
          if (h.kind === "socket" && h.column !== current.column) act(() => edit("connect", { column: current.column, toColumn: h.column }));
          else if (h.kind === "cell" && h.column !== current.column) act(() => edit("connect", { column: current.column, toColumn: h.column }));
          else if (h.kind === "header" && !h.table.columns.some((c) => c.id === current.column)) {
            act(() => edit("connect", { column: current.column, toTable: h.table.id }));
          }
          break;
        }
        case "portConnect": {
          overlay.connecting = null;
          if (!current.moved) {
            selectWire(current.port);
            break;
          }
          finishPortConnection(current, hit(p), scene);
          break;
        }
        case "port":
          preview = {};
          element.style.cursor = "default";
          if (current.spot) act(() => edit("movePort", { port: current.id, ...current.spot }));
          else selectWire(current.id, e.shiftKey);
          break;
        case "cable": {
          preview = {};
          overlay.hoveredTie = null;
          const pulled = current.pull;
          if (!pulled) {
            selectWire(current.hit.id, current.extend);
            break;
          }
          // Out of the ties it was tugged out of, and into the one it's over; with neither, it springs back.
          if (pulled.popped.length || pulled.target) {
            act(() => edit("pullCable", {
              cable: pulled.cable, popped: pulled.popped.map((q) => q.id), into: pulled.target?.id ?? null, segment: pulled.segment,
              point: pulled.point, along: pulled.target?.direction ?? [0, 1],
            }));
            if (pulled.target) {
              clearSelection();
              overlay.selectedTies.add(pulled.target.id);
              changed();
            }
          }
          break;
        }
        case "newPort": {
          const { group, side, along } = current.hint;
          const id = act(() => edit<string | null>("addPort", { group, side, along }));
          if (id) selectWire(id);
          break;
        }
        case "marquee":
          overlay.marquee = null;
          break;
        case "stroke": {
          overlay.stroke = null;
          const tie = act(() => core.zipTie(current.start[0], current.start[1], p[0], p[1]));
          if (tie) {
            clearSelection();
            overlay.selectedTies.add(tie);
            changed();
          }
          break;
        }
      }
      request();
    };

    function selectWire(id: string, extend = false) {
      if (!extend) clearSelection();
      overlay.selectedWires.add(id);
      changed();
    }

    /**
     * From a port's outside, to the one column outside its group it's plugged into; from its inside, to a column in
     * the group, to reference (or be referenced by) the column it stands for, or a table in it, for a new column that does.
     */
    function finishPortConnection(c: Extract<Drag, { kind: "portConnect" }>, h: Hit, scene: Scene | null) {
      if (!scene) return;
      const column = h.kind === "socket" || h.kind === "cell" ? h.column : null;
      const table = h.kind === "socket" || h.kind === "cell" || h.kind === "header" ? h.table : null;
      if (!table) return;
      const inGroup = table.group === c.group;
      if (c.isOutside && column && !inGroup) act(() => edit("plugPort", { port: c.port, column }));
      else if (!c.isOutside && c.column && inGroup && column) act(() => edit("connect", { column, toColumn: c.column }));
      else if (!c.isOutside && c.column && inGroup && h.kind === "header") act(() => edit("connect", { column: c.column, toTable: table.id }));
    }

    const onDouble = (e: MouseEvent) => {
      const scene = getState().scene;
      if (!scene) return;
      const p = toCanvas(e);
      const h = hit(p);
      switch (h.kind) {
        case "header":
          if (h.grip) onOpenDesigner?.(h.table.id);
          else onEditCell?.(h.table.id, null, null);
          break;
        case "cell":
          if (h.part !== "key") onEditCell?.(h.table.id, h.column, h.part);
          else {
            const column = h.table.columns[h.row];
            act(() => edit("setColumn", { column: column.id, primaryKey: !column.primaryKey }));
          }
          break;
        case "tie":
          // Double-clicking a bend point straightens the wire again.
          if (scene.ties.find((t) => t.id === h.id)?.wires.length === 1) {
            act(() => edit("removeTables", { ties: [h.id] }));
            clearSelection();
            changed();
          }
          break;
        case "wire": {
          // A bend point where it's double-clicked.
          const bend = act(() => edit<string | null>("addBendPoint", { wire: h.hit.id, at: h.hit.point, direction: h.hit.tangent, segment: h.hit.segment }));
          if (bend) {
            clearSelection();
            overlay.selectedTies.add(bend);
            changed();
          }
          break;
        }
        case "port":
          // Back to facing its column.
          act(() => edit("movePort", { port: h.id }));
          break;
        case "group":
          if (h.label) {
            const group = scene.groups.find((g) => g.id === h.id);
            if (group) setRenaming({ group: group.id, name: group.name });
          }
          break;
        case "canvas": {
          const id = act(() => edit<string>("addTable", { at: [p[0] - Metrics.tableWidth / 2, p[1] - Metrics.headerHeight / 2] }));
          if (id) {
            selectTables([id]);
            onEditCell?.(id, null, null);
          }
          break;
        }
      }
      request();
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
      if ((h.kind === "header" || h.kind === "cell") && !overlay.selectedTables.has(h.table.id)) selectTables([h.table.id]);
      if (h.kind === "tie" && !overlay.selectedTies.has(h.id)) { clearSelection(); overlay.selectedTies.add(h.id); changed(); }
      if (h.kind === "wire") selectWire(h.hit.id);
      onContextMenu?.(h, [e.clientX, e.clientY]);
      request();
    };

    let spaceDown = false;
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      const mod = e.ctrlKey || e.metaKey;
      if (e.key === " ") { spaceDown = e.type === "keydown"; element.style.cursor = spaceDown ? "grab" : "default"; return; }
      if (e.type !== "keydown" || !getState().scene) return;
      const key = e.key.toLowerCase();
      if (mod && key === "z") { e.preventDefault(); act(() => (e.shiftKey ? core.redo() : core.undo())); }
      else if (mod && key === "y") { e.preventDefault(); act(() => core.redo()); }
      else if (mod && key === "s") { e.preventDefault(); void saveVersionNow(); }
      else if (mod && key === "a") {
        e.preventDefault();
        selectTables(getState().scene?.tables.map((t) => t.id) ?? []);
        for (const t of getState().scene?.ties ?? []) overlay.selectedTies.add(t.id);
      }
      else if (mod && (e.key === "=" || e.key === "+")) { e.preventDefault(); canvas.zoomTo(view.zoom * 1.25); }
      else if (mod && e.key === "-") { e.preventDefault(); canvas.zoomTo(view.zoom / 1.25); }
      else if (mod && e.key === "0") { e.preventDefault(); canvas.zoomTo(1); }
      else if (mod && (e.key === "9" || e.key === "1")) { e.preventDefault(); canvas.fit(); }
      else if (mod || e.altKey) return;
      // Z the zip-tie tool, T a new table, F focus mode (Shift+F on the selection), arrows nudge, as on the Mac.
      else if (key === "z") toggleTying();
      else if (key === "t") newTableInView();
      else if (key === "f") { if (e.shiftKey) focusOnSelection(); else toggleFocus(); }
      else if (e.key.startsWith("Arrow")) {
        e.preventDefault();
        const step = e.shiftKey ? 10 : 1;
        const by: Point = e.key === "ArrowUp" ? [0, -step] : e.key === "ArrowDown" ? [0, step] : e.key === "ArrowLeft" ? [-step, 0] : [step, 0];
        if (overlay.selectedTables.size || overlay.selectedTies.size) {
          act(() => edit("move", { tables: [...overlay.selectedTables], ties: [...overlay.selectedTies], by }));
        }
      }
      else if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); deleteSelection(); }
      else if (e.key === "Escape") {
        if (canvas.tying) toggleTying();
        else { clearSelection(); changed(); }
      }
      else return;
      request();
    };

    function newTableInView() {
      const at: Point = [(view.width / 2 - view.offset[0]) / view.zoom - Metrics.tableWidth / 2, (view.height / 3 - view.offset[1]) / view.zoom];
      const id = act(() => edit<string>("addTable", { at }));
      if (id) {
        selectTables([id]);
        onEditCell?.(id, null, null);
      }
    }

    element.addEventListener("pointerdown", onDown);
    element.addEventListener("pointermove", onMove);
    element.addEventListener("pointerup", onUp);
    element.addEventListener("dblclick", onDouble);
    element.addEventListener("wheel", onWheel, { passive: false });
    element.addEventListener("contextmenu", onContext);
    element.addEventListener("pointerleave", () => {
      shareCursor(null);
      if (overlay.portHint) { overlay.portHint = null; request(); }
    });
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

  return (
    <>
      <canvas ref={ref} class="canvas" tabIndex={0} />
      {renaming && <GroupRename {...renaming} onDone={() => { setRenaming(null); redraw(); }} />}
    </>
  );
}

/** Renaming a group in place, over its name. */
function GroupRename({ group, name, onDone }: { group: string; name: string; onDone: () => void }) {
  const frame = getState().scene?.groups.find((g) => g.id === group)?.frame;
  if (!frame) return null;
  const { zoom, offset } = canvas.view;
  const commit = (value: string) => {
    const next = value.trim();
    if (next && next !== name) act(() => edit("renameGroup", { group, name: next }));
    onDone();
  };
  return (
    <input
      class="cell-editor"
      ref={(el) => { if (el && document.activeElement !== el) { el.focus(); el.select(); } }}
      style={{
        left: `${(frame[0] + Metrics.groupPadding - 3) * zoom + offset[0]}px`, top: `${(frame[1] + 4) * zoom + offset[1]}px`,
        width: `${Math.max(120, frame[2] - Metrics.groupPadding * 2) * zoom}px`, height: `${Metrics.groupLabelHeight * zoom}px`,
        font: `600 ${12 * zoom}px ${fonts.ui}`,
      }}
      defaultValue={name}
      onKeyDown={(e) => {
        if (e.key === "Enter") commit((e.target as HTMLInputElement).value);
        else if (e.key === "Escape") onDone();
        e.stopPropagation();
      }}
      onBlur={(e) => commit((e.target as HTMLInputElement).value)}
    />
  );
}

export function clearSelection() {
  const o = canvas.overlay;
  o.selectedTables.clear();
  o.selectedWires.clear();
  o.selectedTies.clear();
  o.selectedGroups.clear();
}

/** The selected tables, a selected group's included. */
export function selectedTablesAndMembers(): Set<string> {
  const o = canvas.overlay;
  const tables = new Set(o.selectedTables);
  for (const t of getState().scene?.tables ?? []) if (t.group && o.selectedGroups.has(t.group)) tables.add(t.id);
  return tables;
}

/** Focus mode: everything but the selection and what it's joined to fades. */
export function toggleFocus() {
  canvas.focus = canvas.focus ? null : selectedTablesAndMembers();
  redraw();
}

export function focusOnSelection() {
  canvas.focus = selectedTablesAndMembers();
  redraw();
}

export function toggleTying() {
  canvas.tying = !canvas.tying;
  redraw();
}

/** Zip ties held the way they were lined up turn with their wires again. */
export function releaseTies(ids: string[]) {
  act(() => edit("releaseTie", { ties: ids }));
}

export function deleteSelection() {
  const o = canvas.overlay;
  if (!getState().scene) return;
  // A selected cable is a wire's foreign key, or a port's bus, which goes with its port.
  const ports = [...o.selectedWires].filter((id) => lastFrame?.ports.some((p) => p.id === id));
  const relationships = [...o.selectedWires].filter((id) => !ports.includes(id));
  act(() => edit("removeTables", {
    tables: [...o.selectedTables], ties: [...o.selectedTies], groups: o.selectedTables.size === 0 ? [...o.selectedGroups] : [],
    relationships, ports,
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

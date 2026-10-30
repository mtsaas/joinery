// What a press at a point is on, in canvas points, in the Mac's order (CanvasView.press(at:)): a column's socket, a
// port's socket, a port, a zip tie, a wire (off tables), the + by a group's edge, a table, a group's name, the canvas.
import { core, type Frame, type Point, type Scene, type Table } from "../core.ts";
import { Metrics, partAt, socket, socketReach, type Part } from "./metrics.ts";
import { moved, type Overlay } from "./render.ts";

export interface WireHit {
  id: string;
  point: Point;
  tangent: Point;
  segment: number;
}

export interface PortHint {
  group: string;
  side: string;
  along: number;
  point: Point;
}

export type Hit =
  | { kind: "socket"; table: Table; column: string; row: number; side: "leading" | "trailing"; center: Point }
  | { kind: "portSocket"; port: string; isOutside: boolean; center: Point }
  | { kind: "port"; id: string }
  | { kind: "tie"; id: string }
  | { kind: "wire"; hit: WireHit }
  | { kind: "newPort"; hint: PortHint }
  | { kind: "header"; table: Table; grip: boolean }
  | { kind: "cell"; table: Table; column: string; row: number; part: Part }
  | { kind: "group"; id: string; label: boolean }
  | { kind: "canvas" };

const distance = (a: Point, b: Point) => Math.hypot(a[0] - b[0], a[1] - b[1]);

function tableAt(p: Point, scene: Scene, overlay: Overlay): Table | null {
  for (let i = scene.tables.length - 1; i >= 0; i--) {
    const f = moved(scene.tables[i], overlay);
    if (p[0] >= f[0] && p[0] <= f[0] + f[2] && p[1] >= f[1] && p[1] <= f[1] + f[3]) return scene.tables[i];
  }
  return null;
}

function socketAt(p: Point, scene: Scene, overlay: Overlay, zoom: number): Hit | null {
  const reach = socketReach(zoom);
  for (let i = scene.tables.length - 1; i >= 0; i--) {
    const table = scene.tables[i];
    const f = moved(table, overlay);
    if (p[0] < f[0] - reach || p[0] > f[0] + f[2] + reach || p[1] < f[1] || p[1] > f[1] + f[3]) continue;
    for (let row = 0; row < table.columns.length; row++) {
      if (table.columns[row].former) continue;
      for (const side of ["leading", "trailing"] as const) {
        const c = socket(f, row, side);
        if (distance(p, c) <= reach) return { kind: "socket", table, column: table.columns[row].id, row, side, center: c };
      }
    }
  }
  return null;
}

/** Whether `p` is on a port's body: within its length along its normal and its width across. */
function portAt(p: Point, frame: Frame): string | null {
  for (const port of frame.ports) {
    const [length, outer, inner] = port.shape;
    const dx = p[0] - port.point[0], dy = p[1] - port.point[1];
    const along = dx * port.normal[0] + dy * port.normal[1];
    const across = -dx * port.normal[1] + dy * port.normal[0];
    if (Math.abs(along) <= length / 2 && Math.abs(across) <= Math.max(outer, inner)) return port.id;
  }
  return null;
}

function tieAt(p: Point, frame: Frame, zoom: number): string | null {
  for (const tie of frame.ties) {
    // Never smaller than a comfortable target on screen, however far out.
    const reach = Math.max(tie.halfLength + Metrics.socketHitRadius / 2, Metrics.minimumTarget / 2 / zoom);
    if (distance(p, tie.center) <= reach) return tie.id;
  }
  return null;
}

/** Where on a group's edge a port could go, with `p` close to the edge, not over a table nor near a port there. */
export function portHint(p: Point, scene: Scene, frame: Frame | null, overlay: Overlay, zoom: number): PortHint | null {
  const reach = (Metrics.portHintRadius * 1.5) / zoom;
  if (tableAt(p, scene, overlay)) return null;
  for (let i = scene.groups.length - 1; i >= 0; i--) {
    const group = scene.groups[i];
    const [x, y, w, h] = group.frame;
    const near = p[0] >= x - reach && p[0] <= x + w + reach && p[1] >= y - reach && p[1] <= y + h + reach;
    const inside = p[0] > x + reach && p[0] < x + w - reach && p[1] > y + reach && p[1] < y + h - reach;
    if (!near || inside) continue;
    const spot = JSON.parse(core.portSpot(group.id, p[0], p[1], JSON.stringify({ tables: overlay.tableOffsets }))) as
      { side: string; along: number; point: Point } | null;
    if (!spot) continue;
    // Not from inside along the top, where the group's name is, to grab it by.
    if (spot.side === "top" && p[1] > y + 2 / zoom) continue;
    if (frame?.ports.some((port) => port.group === group.id && distance(port.point, spot.point) < Metrics.portWidth / 2)) continue;
    return { group: group.id, ...spot };
  }
  return null;
}

export function hitTest(p: Point, scene: Scene, frame: Frame | null, overlay: Overlay, zoom: number, showsPortHint = false): Hit {
  const onSocket = socketAt(p, scene, overlay, zoom);
  if (onSocket) return onSocket;
  const portSocket = JSON.parse(core.portSocketAt(p[0], p[1], socketReach(zoom))) as { port: string; isOutside: boolean; center: Point } | null;
  if (portSocket) return { kind: "portSocket", ...portSocket };
  if (frame) {
    const port = portAt(p, frame);
    if (port) return { kind: "port", id: port };
    const tie = tieAt(p, frame, zoom);
    if (tie) return { kind: "tie", id: tie };
  }
  const table = tableAt(p, scene, overlay);
  if (!table) {
    const wire = JSON.parse(core.wireAt(p[0], p[1], Metrics.wireHitRadius / zoom)) as WireHit | null;
    if (wire) return { kind: "wire", hit: wire };
    if (showsPortHint) {
      const hint = portHint(p, scene, frame, overlay, zoom);
      if (hint && distance(hint.point, p) <= Metrics.portHintRadius / zoom) return { kind: "newPort", hint };
    }
  }
  if (table) {
    const f = moved(table, overlay);
    const y = p[1] - f[1];
    if (y < Metrics.headerHeight) return { kind: "header", table, grip: p[0] - f[0] < Metrics.gripWidth };
    const row = Math.min(Math.floor((y - Metrics.headerHeight) / Metrics.rowHeight), table.columns.length - 1);
    return { kind: "cell", table, column: table.columns[row].id, row, part: partAt(p[0] - f[0]) };
  }
  for (let i = scene.groups.length - 1; i >= 0; i--) {
    const [x, y, w, h] = scene.groups[i].frame;
    if (p[0] >= x && p[0] <= x + w && p[1] >= y && p[1] <= y + h) {
      return { kind: "group", id: scene.groups[i].id, label: p[1] - y < Metrics.groupPadding + Metrics.groupLabelHeight };
    }
  }
  return { kind: "canvas" };
}

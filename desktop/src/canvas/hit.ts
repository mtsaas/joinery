// What's under the pointer, in canvas points, front to back: a socket, a table's header or cell, a tie, a port, a group.
import type { Frame, Point, Scene, Table } from "../core.ts";
import { Metrics, partAt, socket, socketReach, type Part } from "./metrics.ts";
import { moved, type Overlay } from "./render.ts";

export type Hit =
  | { kind: "socket"; table: Table; column: string; row: number; side: "leading" | "trailing"; center: Point }
  | { kind: "header"; table: Table; grip: boolean }
  | { kind: "cell"; table: Table; column: string; row: number; part: Part }
  | { kind: "tie"; id: string }
  | { kind: "port"; id: string }
  | { kind: "group"; id: string; label: boolean }
  | { kind: "canvas" };

export function hitTest(p: Point, scene: Scene, frame: Frame | null, overlay: Overlay, zoom: number): Hit {
  const reach = socketReach(zoom);
  // Front to back: the last table drawn is on top.
  for (let i = scene.tables.length - 1; i >= 0; i--) {
    const table = scene.tables[i];
    const f = moved(table, overlay);
    if (p[0] < f[0] - reach || p[0] > f[0] + f[2] + reach || p[1] < f[1] || p[1] > f[1] + f[3]) continue;
    for (let row = 0; row < table.columns.length; row++) {
      if (table.columns[row].former) continue;
      for (const side of ["leading", "trailing"] as const) {
        const c = socket(f, row, side);
        if (Math.hypot(p[0] - c[0], p[1] - c[1]) <= reach) return { kind: "socket", table, column: table.columns[row].id, row, side, center: c };
      }
    }
    if (p[0] < f[0] || p[0] > f[0] + f[2]) continue;
    const y = p[1] - f[1];
    if (y < Metrics.headerHeight) return { kind: "header", table, grip: p[0] - f[0] < Metrics.gripWidth };
    const row = Math.min(Math.floor((y - Metrics.headerHeight) / Metrics.rowHeight), table.columns.length - 1);
    return { kind: "cell", table, column: table.columns[row].id, row, part: partAt(p[0] - f[0]) };
  }
  if (frame) {
    for (const tie of frame.ties) {
      const r = Math.max(tie.halfLength, Metrics.bendPointDiameter) + 3 / zoom;
      if (Math.hypot(p[0] - tie.center[0], p[1] - tie.center[1]) <= r) return { kind: "tie", id: tie.id };
    }
    for (const port of frame.ports) {
      const [length, outer] = port.shape;
      const along = (p[0] - port.point[0]) * port.normal[0] + (p[1] - port.point[1]) * port.normal[1];
      const across = -(p[0] - port.point[0]) * port.normal[1] + (p[1] - port.point[1]) * port.normal[0];
      if (Math.abs(along) <= length / 2 && Math.abs(across) <= Math.max(outer, port.shape[2])) return { kind: "port", id: port.id };
    }
  }
  for (let i = scene.groups.length - 1; i >= 0; i--) {
    const [x, y, w, h] = scene.groups[i].frame;
    if (p[0] >= x && p[0] <= x + w && p[1] >= y && p[1] <= y + h) {
      return { kind: "group", id: scene.groups[i].id, label: p[1] - y < Metrics.groupLabelHeight + 8 };
    }
  }
  return { kind: "canvas" };
}

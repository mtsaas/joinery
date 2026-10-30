// Draws the canvas as the Mac's does (Joinery/Canvas/CanvasView.swift and TableLayer.swift): the grid, groups, wires,
// ports and ties, then the tables over them, with the selection, the review's changes and others' pointers.
import type { Frame, Group, Peer, Point, Rect, Scene, Table } from "../core.ts";
import { alpha, fonts, type Theme } from "../theme.ts";
import type { Guide } from "./gestures.ts";
import { Metrics, socket } from "./metrics.ts";

export interface View {
  zoom: number;
  /** Where the canvas's origin is on screen, in CSS pixels. */
  offset: Point;
  width: number;
  height: number;
}

export interface Overlay {
  selectedTables: Set<string>;
  selectedWires: Set<string>;
  selectedTies: Set<string>;
  selectedGroups: Set<string>;
  /** Tables being dragged, by how far. */
  tableOffsets: Record<string, Point>;
  hoveredSocket: { column: string; side: "leading" | "trailing" } | null;
  hoveredTie: string | null;
  /** A wire being dragged out of a socket, to where. */
  connecting: { from: Point; to: Point; color: string } | null;
  marquee: Rect | null;
  /** A zip-tie stroke being drawn. */
  stroke: { start: Point; end: Point } | null;
  peers: Peer[];
  /** The cell being edited, whose text the editor over it shows instead. */
  editing: { table: string; column: string | null } | null;
  /** Tables not in focus, faded. */
  faded: Set<string> | null;
  /** The wires to show over the rest, which fade: the selection's, or those among the tables in focus. */
  highlighted: Set<string> | null;
  /** Lines showing a dragged table lining up with others. */
  guides: Guide[];
  /** The + by a group's edge, where a click adds a port. */
  portHint: Point | null;
}

export const emptyOverlay = (): Overlay => ({
  selectedTables: new Set(), selectedWires: new Set(), selectedTies: new Set(), selectedGroups: new Set(), tableOffsets: {},
  hoveredSocket: null, hoveredTie: null, connecting: null, marquee: null, stroke: null, peers: [], editing: null, faded: null,
  highlighted: null, guides: [], portHint: null,
});

export function moved(table: Table, overlay: Overlay): Rect {
  const offset = overlay.tableOffsets[table.id];
  const [x, y, w, h] = table.frame;
  return offset ? [x + offset[0], y + offset[1], w, h] : table.frame;
}

export function draw(ctx: CanvasRenderingContext2D, view: View, scene: Scene, frame: Frame | null, theme: Theme, overlay: Overlay) {
  const dpr = window.devicePixelRatio || 1;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = theme.canvas;
  ctx.fillRect(0, 0, view.width, view.height);
  drawGrid(ctx, view, theme);
  ctx.translate(view.offset[0], view.offset[1]);
  ctx.scale(view.zoom, view.zoom);

  // What's in view, in canvas points, with room for shadows and wires leaving tables.
  const visible: Rect = [-view.offset[0] / view.zoom - 40, -view.offset[1] / view.zoom - 40,
    view.width / view.zoom + 80, view.height / view.zoom + 80];
  for (const group of scene.groups) drawGroup(ctx, group, theme, overlay.selectedGroups.has(group.id));
  if (frame) drawWires(ctx, frame, theme, overlay);
  if (overlay.connecting) {
    const { from, to, color } = overlay.connecting;
    ctx.strokeStyle = color;
    ctx.lineWidth = Metrics.wireWidth;
    ctx.lineCap = "round";
    ctx.beginPath();
    const bend = Math.max(Math.abs(to[0] - from[0]) / 2, 40);
    ctx.moveTo(from[0], from[1]);
    ctx.bezierCurveTo(from[0] + bend * Math.sign(to[0] - from[0] || 1), from[1], to[0] - bend * Math.sign(to[0] - from[0] || 1), to[1], to[0], to[1]);
    ctx.stroke();
  }
  const tables = scene.tables.filter((t) => intersects(moved(t, overlay), visible));
  for (const table of tables) {
    ctx.globalAlpha = overlay.faded?.has(table.id) ? 0.22 : 1;
    drawTable(ctx, table, moved(table, overlay), theme, overlay, view.zoom);
  }
  ctx.globalAlpha = 1;
  for (const table of tables) {
    if (overlay.selectedTables.has(table.id)) ring(ctx, moved(table, overlay), theme.accent, false);
    else if (table.change) ring(ctx, moved(table, overlay), theme.change(table.change), table.change === "removed");
  }
  if (overlay.stroke) {
    ctx.strokeStyle = "#ff3b30";
    ctx.lineWidth = 2 / view.zoom;
    ctx.beginPath();
    ctx.moveTo(...overlay.stroke.start);
    ctx.lineTo(...overlay.stroke.end);
    ctx.stroke();
  }
  for (const peer of overlay.peers) drawPeer(ctx, peer, scene, theme, view.zoom);
  // Guides: there, but quiet.
  ctx.strokeStyle = alpha(theme.accent, 0.45);
  ctx.lineWidth = 1 / view.zoom;
  for (const g of overlay.guides) {
    ctx.beginPath();
    if (g.vertical) { ctx.moveTo(g.position, g.start); ctx.lineTo(g.position, g.end); }
    else { ctx.moveTo(g.start, g.position); ctx.lineTo(g.end, g.position); }
    ctx.stroke();
  }
  if (overlay.portHint) {
    const [x, y] = overlay.portHint;
    const r = Metrics.portHintRadius / view.zoom;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = theme.accent;
    ctx.fill();
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 1.75 / view.zoom;
    ctx.beginPath();
    ctx.moveTo(x - r * 0.5, y); ctx.lineTo(x + r * 0.5, y);
    ctx.moveTo(x, y - r * 0.5); ctx.lineTo(x, y + r * 0.5);
    ctx.stroke();
  }
  if (overlay.marquee) {
    const [x, y, w, h] = overlay.marquee;
    ctx.fillStyle = alpha(theme.accent, 0.1);
    ctx.fillRect(x, y, w, h);
    ctx.strokeStyle = alpha(theme.accent, 0.6);
    ctx.lineWidth = 1 / view.zoom;
    ctx.strokeRect(x, y, w, h);
  }
}

function drawGrid(ctx: CanvasRenderingContext2D, view: View, theme: Theme) {
  let spacing = Metrics.gridSpacing * view.zoom;
  while (spacing < 12) spacing *= 4;
  ctx.fillStyle = theme.gridDot;
  const startX = ((view.offset[0] % spacing) + spacing) % spacing, startY = ((view.offset[1] % spacing) + spacing) % spacing;
  for (let x = startX; x < view.width; x += spacing) {
    for (let y = startY; y < view.height; y += spacing) ctx.fillRect(x - 0.8, y - 0.8, 1.6, 1.6);
  }
}

function drawGroup(ctx: CanvasRenderingContext2D, group: Group, theme: Theme, selected: boolean) {
  const [x, y, w, h] = group.frame;
  const color = theme.color(group.color);
  ctx.fillStyle = alpha(color, theme.dark ? 0.08 : 0.06);
  rounded(ctx, x, y, w, h, Metrics.groupCornerRadius);
  ctx.fill();
  ctx.strokeStyle = selected ? theme.accent : alpha(color, 0.35);
  ctx.lineWidth = selected ? 2 : 1;
  ctx.stroke();
  ctx.fillStyle = color;
  ctx.font = `600 12px ${fonts.ui}`;
  ctx.textBaseline = "middle";
  ctx.fillText(group.name, x + Metrics.groupPadding, y + Metrics.groupLabelHeight / 2 + 4);
}

/** A smooth curve through the middle of each pair of points, bending at the points, as the Mac's. */
function smooth(ctx: CanvasRenderingContext2D, points: number[]) {
  ctx.beginPath();
  if (points.length < 4) return;
  ctx.moveTo(points[0], points[1]);
  for (let i = 2; i + 2 < points.length; i += 2) {
    ctx.quadraticCurveTo(points[i], points[i + 1], (points[i] + points[i + 2]) / 2, (points[i + 1] + points[i + 3]) / 2);
  }
  ctx.lineTo(points[points.length - 2], points[points.length - 1]);
}

function drawWires(ctx: CanvasRenderingContext2D, frame: Frame, theme: Theme, overlay: Overlay) {
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  // Highlighted wires last, so they're on top; otherwise in the model's order, so overlaps never swap.
  const highlighted = overlay.highlighted;
  const wires = highlighted
    ? [...frame.wires.filter((w) => !highlighted.has(w.id)), ...frame.wires.filter((w) => highlighted.has(w.id))]
    : frame.wires;
  for (const wire of wires) {
    const dimmed = highlighted ? !highlighted.has(wire.id) : false;
    const color = wire.change ? theme.change(wire.change) : theme.color(wire.color);
    smooth(ctx, wire.points);
    ctx.setLineDash([]);
    ctx.strokeStyle = theme.canvas;
    ctx.lineWidth = Metrics.tieSpacing;
    ctx.stroke();
    if (overlay.selectedWires.has(wire.id)) {
      ctx.strokeStyle = darken(color);
      ctx.lineWidth = Metrics.selectedWireWidth;
      ctx.stroke();
    }
    ctx.strokeStyle = dimmed ? alpha(color, 0.28) : color;
    ctx.lineWidth = Metrics.wireWidth;
    if (wire.change === "removed") ctx.setLineDash([6, 5]);
    ctx.stroke();
  }
  ctx.setLineDash([]);
  for (const port of frame.ports) {
    const busDimmed = highlighted ? !highlighted.has(port.id) && !port.wires.some((w) => highlighted.has(w)) : false;
    ctx.globalAlpha = busDimmed ? 0.22 : 1;
    const color = port.plugged ? theme.color(port.color) : theme.socket;
    if (port.bus) {
      smooth(ctx, port.bus);
      ctx.strokeStyle = theme.canvas;
      ctx.lineWidth = Metrics.busWidth + Metrics.tieSpacing;
      ctx.stroke();
      ctx.strokeStyle = color;
      ctx.lineWidth = Metrics.busWidth;
      ctx.stroke();
    }
    drawPort(ctx, port.point, port.normal, port.shape, color, port.label, overlay.selectedWires.has(port.id), theme);
  }
  ctx.globalAlpha = 1;
  for (const tie of frame.ties) {
    const selected = overlay.selectedTies.has(tie.id), hovered = overlay.hoveredTie === tie.id;
    ctx.globalAlpha = overlay.faded && highlighted && !tie.wires.some((w) => highlighted.has(w)) ? 0.22 : 1;
    ctx.save();
    ctx.translate(tie.center[0], tie.center[1]);
    if (tie.count === 1) {
      const r = Metrics.bendPointDiameter / 2;
      ctx.beginPath();
      ctx.arc(0, 0, r, 0, Math.PI * 2);
      ctx.fillStyle = selected ? theme.accent : theme.card;
      ctx.fill();
      ctx.strokeStyle = selected ? theme.accent : theme.color(tie.color);
      ctx.lineWidth = hovered ? 2.25 : 1.5;
      ctx.stroke();
    } else {
      ctx.rotate(Math.atan2(tie.direction[1], tie.direction[0]));
      rounded(ctx, -Metrics.tieThickness / 2, -tie.halfLength, Metrics.tieThickness, tie.halfLength * 2, Metrics.tieThickness / 2);
      ctx.fillStyle = selected ? theme.accent : hovered ? theme.tieHovered : theme.tie;
      ctx.fill();
      ctx.strokeStyle = "rgba(0,0,0,0.18)";
      ctx.lineWidth = 0.5;
      ctx.stroke();
    }
    ctx.restore();
  }
  ctx.globalAlpha = 1;
}

/** A port: a sideways T on its group's edge, a bar across its inside end and a stem out, both pills, as one shape. */
function drawPort(ctx: CanvasRenderingContext2D, point: Point, normal: Point, shape: [number, number, number], color: string,
  label: string, selected: boolean, theme: Theme) {
  const [length, outer, inner] = shape;
  const thickness = Math.min(Metrics.portHeight, length), half = length / 2;
  ctx.save();
  ctx.transform(normal[0], normal[1], -normal[1], normal[0], point[0], point[1]);
  ctx.beginPath();
  roundedPath(ctx, -half, -inner, thickness, inner * 2, Math.min(thickness, inner * 2) / 2);
  roundedPath(ctx, -half, -outer, length, outer * 2, Math.min(length, outer * 2) / 2);
  ctx.fillStyle = color;
  ctx.fill("nonzero");
  if (selected) {
    ctx.strokeStyle = theme.accent;
    ctx.lineWidth = 2;
    ctx.stroke();
  }
  ctx.restore();
  if (label) {
    ctx.fillStyle = "#ffffff";
    ctx.font = `600 11px ${fonts.ui}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, point[0], point[1]);
    ctx.textAlign = "left";
  }
}

function drawTable(ctx: CanvasRenderingContext2D, table: Table, frame: Rect, theme: Theme, overlay: Overlay, zoom: number) {
  const [x, y, w, h] = frame;
  const r = Metrics.cornerRadius;
  // The card, with the Mac's two soft shadows.
  ctx.save();
  ctx.shadowColor = "rgba(0,0,0,0.09)";
  ctx.shadowBlur = 14 * zoom;
  ctx.shadowOffsetY = 6 * zoom;
  rounded(ctx, x, y, w, h, r);
  ctx.fillStyle = theme.card;
  ctx.fill();
  ctx.shadowColor = "rgba(0,0,0,0.07)";
  ctx.shadowBlur = 1.5 * zoom;
  ctx.shadowOffsetY = 0.5 * zoom;
  ctx.fill();
  ctx.restore();

  // The header, washed with the table's color, its edge a little darker.
  ctx.save();
  rounded(ctx, x, y, w, h, r);
  ctx.clip();
  ctx.fillStyle = theme.header(table.color);
  ctx.fillRect(x, y, w, Metrics.headerHeight);
  ctx.fillStyle = theme.headerEdge(table.color);
  ctx.fillRect(x, y + Metrics.headerHeight - Metrics.headerBorderWidth, w, Metrics.headerBorderWidth);

  // Rows: changes tinted, lines between, and the key and type columns' edges.
  table.columns.forEach((column, row) => {
    const top = y + Metrics.headerHeight + row * Metrics.rowHeight;
    const change = column.former ? "removed" : column.change;
    if (change && table.change !== "added" && table.change !== "removed") {
      ctx.fillStyle = alpha(theme.change(change), 0.16);
      ctx.fillRect(x, top, w, Metrics.rowHeight);
    }
    if (row > 0) {
      ctx.fillStyle = theme.cardBorder;
      ctx.fillRect(x, top, w, 0.5);
    }
  });
  if (table.change) {
    ctx.fillStyle = alpha(theme.change(table.change), 0.16);
    ctx.fillRect(x, y, w, h);
  }
  ctx.fillStyle = theme.cardBorder;
  const rows = h - Metrics.headerHeight;
  ctx.fillRect(x + Metrics.keyColumnWidth, y + Metrics.headerHeight, 0.5, rows);
  ctx.fillRect(x + w - Metrics.typeColumnWidth, y + Metrics.headerHeight, 0.5, rows);
  ctx.restore();
  rounded(ctx, x + 0.25, y + 0.25, w - 0.5, h - 0.5, r - 0.25);
  ctx.strokeStyle = theme.cardBorder;
  ctx.lineWidth = 0.5;
  ctx.stroke();

  // The grip, then the name.
  ctx.fillStyle = alpha(theme.secondary.startsWith("#") ? theme.secondary : "#808080", 0.75);
  for (let c = 0; c < 2; c++) for (let rr = 0; rr < 3; rr++) {
    ctx.beginPath();
    ctx.arc(x + Metrics.cellInset + 1.5 + c * 4.5, y + Metrics.headerHeight / 2 - 4.5 + rr * 4.5, 1.5, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.textBaseline = "middle";
  const removed = table.change === "removed";
  if (!(overlay.editing?.table === table.id && overlay.editing.column === null)) {
    const name = table.formerName ? `${table.formerName} → ${table.name}` : table.name;
    text(ctx, name, `600 13px ${fonts.ui}`, x + Metrics.gripWidth, y + Metrics.headerHeight / 2, w - Metrics.gripWidth - Metrics.cellInset,
      removed ? theme.secondary : theme.primary, removed);
  }

  table.columns.forEach((column, row) => {
    const middle = y + Metrics.headerHeight + (row + 0.5) * Metrics.rowHeight;
    const struck = column.former || column.change === "removed";
    ctx.textAlign = "center";
    if (column.primaryKey) text(ctx, "PK", `700 9px ${fonts.ui}`, x + Metrics.keyColumnWidth / 2, middle, 30, theme.secondary);
    else if (column.references) text(ctx, "FK", `700 9px ${fonts.ui}`, x + Metrics.keyColumnWidth / 2, middle, 30, theme.color(column.references));
    else text(ctx, "·", `700 9px ${fonts.ui}`, x + Metrics.keyColumnWidth / 2, middle, 30, theme.quaternary);
    ctx.textAlign = "left";
    if (overlay.editing?.table === table.id && overlay.editing.column === column.id) return;
    let nameWidth = w - Metrics.keyColumnWidth - Metrics.typeColumnWidth - Metrics.cellInset * 2;
    if (column.unique && !column.primaryKey) {
      const bx = x + w - Metrics.typeColumnWidth - Metrics.cellInset - 20;
      ctx.fillStyle = alpha("#8e8e93", 0.16);
      rounded(ctx, bx, middle - 6, 20, 12, 6);
      ctx.fill();
      ctx.textAlign = "center";
      text(ctx, "UQ", `700 8px ${fonts.ui}`, bx + 10, middle, 20, theme.secondary);
      ctx.textAlign = "left";
      nameWidth -= 24;
    }
    const mark = column.change && table.change === "modified" ? { added: "+ ", removed: "− ", modified: "~ " }[column.change] : "";
    text(ctx, mark + column.name, `${column.primaryKey ? 500 : 400} 11px ${fonts.ui}`, x + Metrics.keyColumnWidth + Metrics.cellInset,
      middle, nameWidth, struck ? theme.secondary : theme.primary, struck);
    text(ctx, column.type + (column.nullable ? "?" : ""), `400 10px ${fonts.mono}`, x + w - Metrics.typeColumnWidth + Metrics.cellInset,
      middle, Metrics.typeColumnWidth - Metrics.cellInset * 2, theme.secondary, struck);
  });

  // Sockets on both sides of every row: rings until a wire plugs in, the hovered one larger.
  table.columns.forEach((column, row) => {
    if (column.former) return;
    for (const side of ["leading", "trailing"] as const) {
      const [cx, cy] = socket(frame, row, side);
      const hovered = overlay.hoveredSocket?.column === column.id && overlay.hoveredSocket.side === side;
      const d = hovered ? Metrics.socketDiameter + 4 : Metrics.socketDiameter;
      ctx.beginPath();
      ctx.arc(cx, cy, d / 2 - 0.75, 0, Math.PI * 2);
      ctx.fillStyle = theme.card;
      ctx.fill();
      ctx.strokeStyle = hovered ? theme.accent : theme.socket;
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }
  });
}

function drawPeer(ctx: CanvasRenderingContext2D, peer: Peer, scene: Scene, theme: Theme, zoom: number) {
  const color = theme.color(peer.color);
  for (const id of peer.selection ?? []) {
    const table = scene.tables.find((t) => t.id === id);
    if (table) ring(ctx, table.frame, color, false);
  }
  if (peer.marquee) {
    const [x, y, w, h] = peer.marquee;
    ctx.strokeStyle = color;
    ctx.lineWidth = 1 / zoom;
    ctx.strokeRect(x, y, w, h);
  }
  if (!peer.cursor) return;
  const [x, y] = peer.cursor;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(1 / zoom, 1 / zoom);
  ctx.beginPath();
  ctx.moveTo(0, 0);
  ctx.lineTo(0, 16);
  ctx.lineTo(4.5, 12);
  ctx.lineTo(8, 19);
  ctx.lineTo(10.5, 18);
  ctx.lineTo(7, 11);
  ctx.lineTo(12.5, 11);
  ctx.closePath();
  ctx.fillStyle = color;
  ctx.fill();
  ctx.strokeStyle = "#ffffff";
  ctx.lineWidth = 1.2;
  ctx.stroke();
  ctx.font = `600 11px ${fonts.ui}`;
  const width = ctx.measureText(peer.name).width + 12;
  rounded(ctx, 12, 18, width, 18, 9);
  ctx.fill();
  ctx.fillStyle = "#ffffff";
  ctx.textBaseline = "middle";
  ctx.fillText(peer.name, 18, 27);
  ctx.restore();
}

function ring(ctx: CanvasRenderingContext2D, [x, y, w, h]: Rect, color: string, dashed: boolean) {
  const gap = Metrics.selectionGap + Metrics.selectionWidth / 2;
  rounded(ctx, x - gap, y - gap, w + gap * 2, h + gap * 2, Metrics.cornerRadius + gap);
  ctx.strokeStyle = color;
  ctx.lineWidth = Metrics.selectionWidth;
  ctx.setLineDash(dashed ? [6, 4] : []);
  ctx.stroke();
  ctx.setLineDash([]);
}

function text(ctx: CanvasRenderingContext2D, s: string, font: string, x: number, y: number, width: number, color: string, struck = false) {
  ctx.font = font;
  ctx.fillStyle = color;
  let shown = s;
  if (ctx.measureText(shown).width > width) {
    while (shown.length > 1 && ctx.measureText(shown + "…").width > width) shown = shown.slice(0, -1);
    shown += "…";
  }
  ctx.fillText(shown, x, y);
  if (struck) {
    const measured = ctx.measureText(shown).width;
    const left = ctx.textAlign === "center" ? x - measured / 2 : x;
    ctx.fillRect(left, y - 0.5, measured, 1);
  }
}

function rounded(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath();
  roundedPath(ctx, x, y, w, h, r);
}

function roundedPath(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.roundRect(x, y, w, h, Math.max(0, Math.min(r, w / 2, h / 2)));
}

function darken(color: string): string {
  return color.startsWith("#") ? `color-mix(in srgb, ${color} 80%, black)` : color;
}

function intersects(a: Rect, b: Rect): boolean {
  return a[0] < b[0] + b[2] && a[0] + a[2] > b[0] && a[1] < b[1] + b[3] && a[1] + a[3] > b[1];
}

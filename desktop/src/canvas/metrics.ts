// The canvas's sizes, in canvas points, as Joinery/Document/Metrics.swift has them. The core lays everything out with
// those; these are for drawing it and for telling what's under the pointer.
export const Metrics = {
  tableWidth: 236,
  keyColumnWidth: 30,
  typeColumnWidth: 86,
  headerHeight: 30,
  gripWidth: 26,
  rowHeight: 22,
  cellInset: 8,
  cornerRadius: 10,
  selectionGap: 3,
  selectionWidth: 2,
  headerBorderWidth: 1,
  socketDiameter: 8,
  socketHitRadius: 9,
  wireHitRadius: 6,
  minimumTarget: 24,
  wireWidth: 2.25,
  busWidth: 4.5,
  selectedWireWidth: 5.25,
  tieSpacing: 4,
  tieThickness: 5,
  tieOverhang: 4.5,
  bendPointDiameter: 7,
  groupPadding: 24,
  groupLabelHeight: 22,
  groupCornerRadius: 34,
  portHeight: 20,
  portHintRadius: 10,
  gridSpacing: 24,
} as const;

export type Part = "key" | "name" | "type";

/** Which column of a table's grid `x`, from its left edge, falls in. */
export function partAt(x: number): Part {
  return x < Metrics.keyColumnWidth ? "key" : x < Metrics.tableWidth - Metrics.typeColumnWidth ? "name" : "type";
}

/** A socket's center: on either side of a row. */
export function socket(frame: [number, number, number, number], row: number, side: "leading" | "trailing"): [number, number] {
  return [side === "leading" ? frame[0] : frame[0] + frame[2], frame[1] + Metrics.headerHeight + (row + 0.5) * Metrics.rowHeight];
}

/** How far around a socket the pointer grabs it, in canvas points, at `zoom`. */
export function socketReach(zoom: number): number {
  return Math.max(Metrics.socketHitRadius * 2 * zoom, Math.min(Metrics.minimumTarget, Metrics.rowHeight * zoom)) / 2 / zoom;
}

// The canvas's gestures worked out as plain functions, as the Mac's CanvasController and CanvasView do: snapping a
// drag into line with other tables, pulling a cable out of and into zip ties, and which tables focus mode keeps.
import type { Point, Rect, Scene, Tie } from "../core.ts";
import { Metrics } from "./metrics.ts";

/** A line showing a dragged table lines up with another: vertical at x, or horizontal at y, from start to end. */
export interface Guide {
  vertical: boolean;
  position: number;
  start: number;
  end: number;
}

const lines = (r: Rect, vertical: boolean) => (vertical ? [r[0], r[0] + r[2] / 2, r[0] + r[2]] : [r[1], r[1] + r[3] / 2, r[1] + r[3]]);
const shifted = (r: Rect, by: Point): Rect => [r[0] + by[0], r[1] + by[1], r[2], r[3]];

/**
 * Snaps a drag of `moving` by `offset`, so an edge or center coming within `tolerance` of another table's lines up
 * exactly, across and down as allowed; with a guide for every line-up it leaves.
 */
export function snap(moving: Rect[], offset: Point, others: Rect[], tolerance: number, across = true, down = true): { offset: Point; guides: Guide[] } {
  const snapped: Point = [...offset];
  for (const vertical of [true, false]) {
    if (!(vertical ? across : down)) continue;
    let nearest: number | null = null;
    for (const frame of moving) {
      for (const line of lines(shifted(frame, snapped), vertical)) {
        for (const other of others) {
          for (const target of lines(other, vertical)) {
            if (Math.abs(target - line) <= Math.min(tolerance, Math.abs(nearest ?? Infinity))) nearest = target - line;
          }
        }
      }
    }
    if (nearest !== null) snapped[vertical ? 0 : 1] += nearest;
  }
  const guides: Guide[] = [];
  for (const vertical of [true, false]) {
    const spans: Guide[] = [];
    for (const frame of moving.map((f) => shifted(f, snapped))) {
      for (const line of lines(frame, vertical)) {
        for (const other of others) {
          if (!lines(other, vertical).some((l) => Math.abs(l - line) < 0.5)) continue;
          const start = vertical ? Math.min(frame[1], other[1]) : Math.min(frame[0], other[0]);
          const end = vertical ? Math.max(frame[1] + frame[3], other[1] + other[3]) : Math.max(frame[0] + frame[2], other[0] + other[2]);
          const span = spans.find((s) => Math.abs(s.position - line) < 0.5);
          if (span) { span.start = Math.min(span.start, start); span.end = Math.max(span.end, end); }
          else spans.push({ vertical, position: line, start, end });
        }
      }
    }
    guides.push(...spans);
  }
  return { offset: snapped, guides };
}

/** With Shift, a drag only along whichever way it's gone further. */
export function axisLocked(offset: Point, locked: boolean): Point {
  if (!locked) return offset;
  return Math.abs(offset[0]) >= Math.abs(offset[1]) ? [offset[0], 0] : [0, offset[1]];
}

/** A cable being pulled about by where it was grabbed. */
export interface Pull {
  cable: string;
  start: Point;
  point: Point;
  direction: Point;
  /** Which stretch between its ties it was grabbed on, from 0 at its start. */
  segment: number;
  /** The ties it's been tugged out of, last last, and whether each was before where it was grabbed. */
  popped: { id: string; before: boolean }[];
  /** The zip tie or bend point under the pointer it isn't in: where it'd go. */
  target: { id: string; direction: Point } | null;
}

const distance = (a: Point, b: Point) => Math.hypot(a[0] - b[0], a[1] - b[1]);

/**
 * Pulls a cable to `point`: out of each tie next to where it was grabbed once it's `tiePopPull` further from it than
 * the grab, back into the last it came out of within `tieSnapPull`, and over a tie it isn't in, to go in.
 */
export function pull(drag: Pull, point: Point, scene: Pick<Scene, "ties" | "cables">, drawn: Tie[]): Pull {
  const next: Pull = { ...drag, point, popped: [...drag.popped] };
  const position = (id: string) => scene.ties.find((t) => t.id === id)?.position;
  const stretch = (id: string) => {
    const p = position(id);
    return p ? distance(point, p) - distance(next.start, p) : null;
  };
  for (let last = next.popped.at(-1); last; last = next.popped.at(-1)) {
    const s = stretch(last.id);
    if (s === null || s >= Metrics.tieSnapPull) break;
    next.popped.pop();
    if (last.before) next.segment += 1;
  }
  const ties = (scene.cables[next.cable] ?? []).filter((id) => !next.popped.some((p) => p.id === id));
  for (let popping = true; popping;) {
    popping = false;
    for (const [index, before] of [[next.segment - 1, true], [next.segment, false]] as const) {
      if (index < 0 || index >= ties.length) continue;
      const s = stretch(ties[index]);
      if (s === null || s <= Metrics.tiePopPull) continue;
      next.popped.push({ id: ties[index], before });
      ties.splice(index, 1);
      if (before) next.segment -= 1;
      popping = true;
      break;
    }
  }
  const over = drawn.find((t) => !t.wires.includes(next.cable) && distance(t.center, point) <= t.halfLength + Metrics.socketHitRadius);
  next.target = over ? { id: over.id, direction: over.direction } : null;
  return next;
}

/** Focus mode's tables and every table a foreign key joins them to; the rest fade. */
export function neighborhood(focus: Set<string>, scene: Pick<Scene, "tables" | "wires">): Set<string> {
  const owner = new Map<string, string>();
  for (const t of scene.tables) for (const c of t.columns) owner.set(c.id, t.id);
  const near = new Set(focus);
  for (const w of scene.wires) {
    const a = owner.get(w.from), b = owner.get(w.to);
    if (a && b && focus.has(a)) near.add(b);
    if (a && b && focus.has(b)) near.add(a);
  }
  return near;
}

/** The wires whose both ends are among `tables`. */
export function wiresAmong(tables: Set<string>, scene: Pick<Scene, "tables" | "wires">): Set<string> {
  const owner = new Map<string, string>();
  for (const t of scene.tables) for (const c of t.columns) owner.set(c.id, t.id);
  return new Set(scene.wires.filter((w) => tables.has(owner.get(w.from) ?? "") && tables.has(owner.get(w.to) ?? "")).map((w) => w.id));
}

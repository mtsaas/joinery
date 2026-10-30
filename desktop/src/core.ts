// Joinery's core, the same Swift as the Mac app's, compiled to WebAssembly (scripts/build-core.sh). Everything that
// changes a model goes through it; after each such call, `drain()` says what to do about it.
import type { Exports } from "../core-pkg/bridge-js.js";
import { init } from "../core-pkg/index.js";

export let core: Exports;

export async function loadCore(): Promise<void> {
  const { exports } = await init({ getImports: () => ({}) });
  core = exports;
}

export type ColorName =
  | "blue" | "purple" | "pink" | "red" | "orange" | "yellow" | "green" | "teal" | "indigo" | "mint" | "cyan" | "brown";
export type Change = "added" | "removed" | "modified";
export type Rect = [number, number, number, number];
export type Point = [number, number];

export interface Column {
  id: string;
  name: string;
  type: string;
  primaryKey: boolean;
  nullable: boolean;
  unique: boolean;
  /** The color of the table a foreign key references. */
  references: ColorName | null;
  change: Change | null;
  /** A changed column as it was, shown struck through above it while reviewing. */
  former: boolean;
}

export interface Table {
  id: string;
  name: string;
  color: ColorName;
  frame: Rect;
  group: string | null;
  notes: string;
  change: Change | null;
  formerName: string | null;
  samples: number;
  columns: Column[];
}

export interface Group {
  id: string;
  name: string;
  color: ColorName;
  frame: Rect;
}

export interface Scene {
  tables: Table[];
  groups: Group[];
  reviewing: boolean;
  summary: string | null;
  canUndo: boolean;
  canRedo: boolean;
  bounds: Rect | null;
}

export interface Wire {
  id: string;
  color: ColorName | null;
  /** x, y, x, y, … */
  points: number[];
  change: Change | null;
}

export interface Port {
  id: string;
  color: ColorName | null;
  label: string;
  plugged: boolean;
  point: Point;
  normal: Point;
  /** length, outer, inner */
  shape: [number, number, number];
  wires: string[];
  bus: number[] | null;
}

export interface Tie {
  id: string;
  center: Point;
  direction: Point;
  halfLength: number;
  count: number;
  wires: string[];
  color: ColorName | null;
}

export interface Frame {
  moving: boolean;
  wires: Wire[];
  ports: Port[];
  ties: Tie[];
}

export type CoreEvent =
  | { type: "changed" }
  | { type: "version"; reason: string; before?: string }
  | { type: "baseline"; model: string }
  | { type: "connect"; socket: string }
  | { type: "send"; data: string }
  | { type: "links"; edit: string; view: string }
  | { type: "peers"; me: Peer | null; peers: Peer[] }
  | { type: "status"; status: string }
  | { type: "reconnect"; after: number }
  | { type: "refused"; reason: string }
  | { type: "joined"; title: string; canEdit: boolean }
  | { type: "ended"; reason: string };

export interface Peer {
  id: string;
  name: string;
  color: ColorName;
  cursor: Point | null;
  selection: string[] | null;
  drag: Point | null;
  marquee: Rect | null;
}

export function scene(): Scene {
  return JSON.parse(core.scene());
}

export function frame(time: number, tables: Record<string, Point>, ties: Record<string, Point>, avoiding: boolean): Frame {
  return JSON.parse(core.frame(time, JSON.stringify({ tables, ties }), avoiding));
}

/** Makes an edit, as one change and one undo; returns what it made, such as a new table's ID. */
export function edit<T = unknown>(name: string, args: Record<string, unknown> = {}): T {
  return JSON.parse(core.edit(name, JSON.stringify(args))).result as T;
}

export function drain(): CoreEvent[] {
  return JSON.parse(core.drainEvents());
}

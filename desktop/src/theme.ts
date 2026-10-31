// The Mac app's colors (Joinery/Canvas/Theme.swift), with Apple's system colors for tables, light and dark.
import type { Change, ColorName } from "./core.ts";

const system: Record<ColorName, [string, string]> = {
  blue: ["#0088ff", "#0091ff"],
  purple: ["#cb30e0", "#db34f2"],
  pink: ["#ff2d55", "#ff375f"],
  red: ["#ff383c", "#ff4245"],
  orange: ["#ff8d28", "#ff9230"],
  yellow: ["#ffcc00", "#ffd600"],
  green: ["#34c759", "#30d158"],
  teal: ["#00c3d0", "#00d2e0"],
  indigo: ["#6155f5", "#6b5dff"],
  mint: ["#00c8b3", "#00dac3"],
  cyan: ["#00c0e8", "#3cd3fe"],
  brown: ["#ac7f5e", "#b78a66"],
};

export const colorNames = Object.keys(system) as ColorName[];

export interface Theme {
  dark: boolean;
  canvas: string;
  card: string;
  cardBorder: string;
  gridDot: string;
  tie: string;
  tieHovered: string;
  socket: string;
  accent: string;
  primary: string;
  secondary: string;
  quaternary: string;
  color(name: ColorName | null): string;
  change(change: Change): string;
  /** A header's fill: the card with a wash of its color. */
  header(name: ColorName): string;
  headerEdge(name: ColorName): string;
}

export function theme(dark: boolean): Theme {
  const card = dark ? "#2c2c2c" : "#ffffff";
  const color = (name: ColorName | null) => (name ? system[name][dark ? 1 : 0] : dark ? "#8e8e93" : "#8e8e93");
  return {
    dark,
    canvas: dark ? "#1e1e1e" : "#ffffff",
    card,
    cardBorder: dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)",
    gridDot: dark ? "rgba(255,255,255,0.11)" : "rgba(0,0,0,0.13)",
    tie: dark ? "#a3a3a3" : "#8f8f8f",
    tieHovered: dark ? "#dbdbdb" : "#5c5c5c",
    socket: dark ? "rgba(255,255,255,0.3)" : "rgba(0,0,0,0.28)",
    accent: system.blue[dark ? 1 : 0],
    primary: dark ? "rgba(255,255,255,0.85)" : "rgba(0,0,0,0.85)",
    secondary: dark ? "rgba(255,255,255,0.55)" : "rgba(0,0,0,0.5)",
    quaternary: dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)",
    color,
    change: (change) => color(change === "added" ? "green" : change === "removed" ? "red" : "orange"),
    header: (name) => mix(card, color(name), 0.13),
    headerEdge: (name) => mix(mix(card, color(name), 0.13), "#000000", 0.07),
  };
}

/** Partway from one hex color to another, as SwiftUI's `mix(with:by:)`. */
export function mix(a: string, b: string, amount: number): string {
  const [ar, ag, ab] = rgb(a), [br, bg, bb] = rgb(b);
  const channel = (x: number, y: number) => Math.round(x + (y - x) * amount).toString(16).padStart(2, "0");
  return `#${channel(ar, br)}${channel(ag, bg)}${channel(ab, bb)}`;
}

/** A hex color with some transparency. */
export function alpha(hex: string, opacity: number): string {
  const [r, g, b] = rgb(hex);
  return `rgba(${r},${g},${b},${opacity})`;
}

function rgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export const fonts = {
  ui: `"Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, sans-serif`,
  mono: `"Cascadia Mono", Consolas, ui-monospace, "SF Mono", monospace`,
};

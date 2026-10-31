// The whole data model small, in a corner: its groups and tables, and a frame around the part in view. Clicking or
// dragging in it moves the view there, as the Mac's Minimap.
import { useEffect, useRef } from "preact/hooks";
import type { Rect } from "../core.ts";
import { getState } from "../store.ts";
import { alpha, theme as makeTheme } from "../theme.ts";
import { canvas, redraw } from "./Canvas.tsx";

const width = 200, inset = 8;

export function Minimap() {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const element = ref.current!;
    const ctx = element.getContext("2d")!;
    const media = matchMedia("(prefers-color-scheme: dark)");
    let last = "", raf = 0, world: Rect = [0, 0, 1, 1], scale = 1;

    const visible = (): Rect => {
      const { zoom, offset, width: w, height: h } = canvas.view;
      return [-offset[0] / zoom, -offset[1] / zoom, w / zoom, h / zoom];
    };

    // Redrawn only when the model, the view or the appearance changes; checked each frame, which costs a comparison.
    function frame() {
      raf = requestAnimationFrame(frame);
      const { scene, revision } = getState();
      if (!scene) return;
      const view = visible();
      const key = `${revision}|${view.map((v) => v.toFixed(1)).join(",")}|${media.matches}|${JSON.stringify(canvas.overlay.tableOffsets).length}`;
      if (key === last) return;
      last = key;
      const theme = makeTheme(media.matches);
      const frames = [...scene.tables.map((t) => t.frame), ...scene.groups.map((g) => g.frame), view];
      let [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity];
      for (const [x, y, w, h] of frames) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x + w); y1 = Math.max(y1, y + h); }
      const padX = (x1 - x0) * 0.03, padY = (y1 - y0) * 0.03;
      world = [x0 - padX, y0 - padY, x1 - x0 + padX * 2, y1 - y0 + padY * 2];
      scale = (width - inset * 2) / world[2];
      // As tall as the model's shape needs, within reason.
      const height = Math.min(Math.max(world[3] * scale, 60), 160) + inset * 2;
      const dpr = window.devicePixelRatio || 1;
      element.style.height = `${height}px`;
      element.width = width * dpr;
      element.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const rect = ([x, y, w, h]: Rect): Rect => [(x - world[0]) * scale + inset, (y - world[1]) * scale + inset, w * scale, h * scale];
      for (const group of scene.groups) {
        ctx.fillStyle = alpha(theme.color(group.color), 0.18);
        ctx.beginPath();
        ctx.roundRect(...rect(group.frame), 4);
        ctx.fill();
      }
      for (const table of scene.tables) {
        const offset = canvas.overlay.tableOffsets[table.id];
        const [x, y, w, h] = table.frame;
        ctx.fillStyle = alpha(theme.color(table.color), 0.5);
        ctx.beginPath();
        ctx.roundRect(...rect(offset ? [x + offset[0], y + offset[1], w, h] : table.frame), 1.5);
        ctx.fill();
      }
      ctx.beginPath();
      ctx.roundRect(...rect(view), 3);
      ctx.fillStyle = theme.dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.08)";
      ctx.fill();
      ctx.strokeStyle = theme.dark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.6)";
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    raf = requestAnimationFrame(frame);

    // Centers the view on the canvas point under the pointer.
    function show(e: PointerEvent) {
      const box = element.getBoundingClientRect();
      const x = (e.clientX - box.left - inset) / scale + world[0], y = (e.clientY - box.top - inset) / scale + world[1];
      const { zoom, width: w, height: h } = canvas.view;
      canvas.view.offset = [w / 2 - x * zoom, h / 2 - y * zoom];
      redraw();
    }
    let dragging = false;
    const onDown = (e: PointerEvent) => {
      show(e);
      dragging = true;
      try { element.setPointerCapture(e.pointerId); } catch { /* a pointer the window doesn't know, as automation's */ }
    };
    const onMove = (e: PointerEvent) => { if (dragging && e.buttons) show(e); };
    const onUp = () => { dragging = false; };
    element.addEventListener("pointerup", onUp);
    element.addEventListener("pointerdown", onDown);
    element.addEventListener("pointermove", onMove);
    return () => cancelAnimationFrame(raf);
  }, []);

  return <canvas ref={ref} class="minimap" title="Click or drag to move the view" aria-label="Minimap" style={{ width: `${width}px` }} />;
}

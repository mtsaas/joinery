// Command-line checks, as the Mac's DebugHooks: src-tauri/src/debug.rs reads the environment; scripts/smoke.sh drives it.
import { invoke } from "@tauri-apps/api/core";
import { canvas } from "./canvas/Canvas.tsx";
import { isApp } from "./library.ts";
import { getState, open, saveNow } from "./store.ts";

interface Hooks {
  open: string | null;
  snapshot: string | null;
  delay: number;
}

export async function runDebugHooks() {
  const hooks = isApp ? await invoke<Hooks | null>("debug_hooks") : null;
  if (!hooks) return;
  if (hooks.open) {
    const model = getState().listing.models.find((m) => m.name === hooks.open);
    if (model) await open(model.path);
    else console.error(`No model named ${hooks.open}`);
  }
  const path = hooks.snapshot;
  if (!path) return;
  setTimeout(async () => {
    try {
      await saveNow();
      canvas.fit();
      canvas.drawNow();
      // ponytail: the canvas only, not the sidebar; webviews have no portable whole-window capture.
      const png = document.querySelector<HTMLCanvasElement>("canvas.canvas")!.toDataURL("image/png").split(",")[1];
      const s = getState();
      const report = `snapshot: ${s.name}, ${s.scene?.tables.length ?? 0} tables${s.failure ? `, failure: ${s.failure}` : ""}`;
      await invoke("debug_snapshot", { path, png, report });
    } catch (error) {
      await invoke("debug_snapshot", { path, png: "", report: `snapshot failed: ${error}` });
    }
  }, hooks.delay * 1000);
}

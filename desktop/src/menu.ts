// What the menu bar's items do (src-tauri/src/menu.rs sends their IDs). The canvas's own commands (cut, copy, paste,
// select all, delete) go to it as the keys that do them, so it alone decides what they mean; in a text field, they're
// the field's.
import { message } from "@tauri-apps/plugin-dialog";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { canvas } from "./canvas/Canvas.tsx";
import { core } from "./core.ts";
import { isApp, library } from "./library.ts";
import * as actions from "./panels/actions.ts";
import { act, getState, newModel, saveNow, saveVersionNow, set } from "./store.ts";

const editingText = () => {
  const active = document.activeElement;
  return active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement || (active as HTMLElement | null)?.isContentEditable;
};

/** The key that does `command` on the canvas, pressed. */
function press(key: string, modifier = true) {
  window.dispatchEvent(new KeyboardEvent("keydown", { key, ctrlKey: modifier, bubbles: true, cancelable: true }));
}

const commands: Record<string, () => void | Promise<void>> = {
  "new": () => void newModel(actions.currentCollection()),
  "new-collection": () => void actions.newCollection(),
  "import": () => actions.importModel(),
  "export": () => actions.exportModel(),
  "add-examples": () => actions.addExamples(),
  "show-library": () => void library.reveal(""),
  "save-version": () => saveVersionNow(),
  "history": () => set({ showsHistory: !getState().showsHistory && !!getState().path }),
  "settings": () => set({ showsSettings: true }),
  "close": () => close(),
  "undo": () => (editingText() ? void document.execCommand("undo") : void act(() => core.undo())),
  "redo": () => (editingText() ? void document.execCommand("redo") : void act(() => core.redo())),
  "cut": () => (editingText() ? void document.execCommand("cut") : press("x")),
  "copy": () => (editingText() ? void document.execCommand("copy") : press("c")),
  "paste": () => (editingText() ? void navigator.clipboard.readText().then((t) => document.execCommand("insertText", false, t)) : press("v")),
  "delete": () => (editingText() ? void document.execCommand("delete") : press("Delete", false)),
  "select-all": () => (editingText() ? void (document.activeElement as HTMLInputElement).select() : press("a")),
  "zoom-in": () => canvas.zoomTo(canvas.view.zoom * 1.25),
  "zoom-out": () => canvas.zoomTo(canvas.view.zoom * 0.8),
  "actual-size": () => canvas.zoomTo(1),
  "zoom-fit": () => canvas.fit(),
  "connect-assistant": () => set({ showsSettings: true }),
  "about": () => void message("Joinery, for designing SQL databases on a canvas.\nhttps://github.com/mtsaas/joinery", { title: "About Joinery" }),
};

/** Saves, then closes the window, which ends the app. */
async function close() {
  await saveNow();
  await getCurrentWindow().destroy();
}

export async function installMenu() {
  if (!isApp) return;
  await listen<string>("menu", (event) => void commands[event.payload]?.());
  // Closed with its button or Alt+F4: what's not saved yet is, first.
  await getCurrentWindow().onCloseRequested(async (event) => {
    event.preventDefault();
    await close();
  });
}

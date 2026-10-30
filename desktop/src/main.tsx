import { render } from "preact";
import { App } from "./App.tsx";
import { startAssistants } from "./assistant.ts";
import "./session.ts";
import { setEditNext } from "./canvas/CellEditor.tsx";
import { loadCore } from "./core.ts";
import { exampleModels, library } from "./library.ts";
import { fail, open, reload, getState } from "./store.ts";
import { checkForUpdates } from "./updates.ts";

async function start() {
  const root = document.getElementById("app")!;
  root.textContent = "Loading…";
  await loadCore();
  render(<App />, root);
  await startAssistants();
  await reload();
  // A first run starts with the examples, as the Mac app does.
  if (getState().listing.models.length === 0) {
    for (const example of exampleModels) await library.create("Examples", example.name, example.model);
    await reload();
  }
  const last = localStorage.getItem("lastOpened");
  const models = getState().listing.models;
  const first = models.find((m) => m.path === last) ?? models[0];
  if (first) await open(first.path);
  setEditNext(() => {});
  void checkForUpdates();
}

// For checking the app from a browser's console, and for tests that drive it.
Object.assign(window, { joinery: { getState, core: () => import("./core.ts").then((m) => m.core) } });

start().catch((error) => {
  fail(error);
  console.error(error);
});

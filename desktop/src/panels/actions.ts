// What the library's menus do, the sidebar's and the menu bar's alike, as the Mac's Library does it.
import { confirm as ask, open as pick, save as pickSave } from "@tauri-apps/plugin-dialog";
import { exampleModels, isApp, library, type ModelEntry } from "../library.ts";
import { fail, getState, moved, notify, open, reload, set } from "../store.ts";

async function attempt<T>(body: () => Promise<T>): Promise<T | undefined> {
  try {
    const result = await body();
    await reload();
    return result;
  } catch (error) {
    fail(error);
    return undefined;
  }
}

async function confirmed(question: string, action: string): Promise<boolean> {
  return isApp ? ask(question, { title: "Joinery", kind: "warning", okLabel: action, cancelLabel: "Cancel" }) : window.confirm(question);
}

/** The collection of the open model, for something new to go beside it. */
export function currentCollection(): string | null {
  const { listing, path } = getState();
  return listing.models.find((m) => m.path === path)?.collection ?? null;
}

export function rename(model: ModelEntry, name: string) {
  return attempt(async () => moved(model.path, await library.rename(model.path, name)));
}

export function duplicate(model: ModelEntry) {
  return attempt(() => library.duplicate(model.path));
}

export function setFavorite(model: ModelEntry, favorite: boolean) {
  return attempt(() => library.setFavorite(model.path, favorite));
}

export function move(model: ModelEntry, collection: string | null) {
  if (model.collection === collection) return Promise.resolve(undefined);
  return attempt(async () => moved(model.path, await library.move(model.path, collection)));
}

export async function trash(model: ModelEntry) {
  if (!(await confirmed(`Move “${model.name}” to the Recycle Bin?`, "Move to Recycle Bin"))) return;
  await attempt(async () => {
    await library.trash(model.path);
    if (getState().path === model.path) set({ path: null, scene: null, name: "", preview: null });
  });
}

export function reveal(path: string) {
  return attempt(() => library.reveal(path));
}

export async function newCollection(): Promise<string | undefined> {
  return attempt(() => library.newCollection("New Collection"));
}

export function renameCollection(name: string, to: string) {
  return attempt(async () => {
    const renamed = await library.renameCollection(name, to);
    const { path } = getState();
    if (path?.startsWith(`${name}/`)) moved(path, `${renamed}/${path.slice(name.length + 1)}`);
  });
}

export async function trashCollection(name: string) {
  const count = getState().listing.models.filter((m) => m.collection === name).length;
  const what = count ? ` and the ${count === 1 ? "data model" : `${count} data models`} in it` : "";
  if (!(await confirmed(`Move “${name}”${what} to the Recycle Bin?`, "Move to Recycle Bin"))) return;
  await attempt(async () => {
    await library.trashCollection(name);
    if (getState().path?.startsWith(`${name}/`)) set({ path: null, scene: null, name: "", preview: null });
  });
}

/** A `.joinery` file, or a package's `model.json` (a folder can't be picked as a file), copied in and opened. */
export async function importModel(collection: string | null = null) {
  if (!isApp) return notify("Importing needs the app.");
  const source = await pick({
    title: "Import Data Model",
    multiple: false,
    directory: false,
    filters: [{ name: "Joinery data models", extensions: ["joinery", "json"] }],
  });
  if (typeof source !== "string") return;
  const path = await attempt(() => library.importModel(source, collection));
  if (path) await open(path);
}

/** A copy of the open model, versions and all, to send to someone. */
export async function exportModel(model: ModelEntry | null = openEntry()) {
  if (!model) return notify("Open a data model to export it.");
  if (!isApp) return notify("Exporting needs the app.");
  const destination = await pickSave({
    title: "Export a Copy",
    defaultPath: `${model.name}.joinery`,
    filters: [{ name: "Joinery data model", extensions: ["joinery"] }],
  });
  if (!destination) return;
  if (await attempt(() => library.exportModel(model.path, destination)) !== undefined) notify(`Exported “${model.name}”`);
}

export function openEntry(): ModelEntry | null {
  const { listing, path } = getState();
  return listing.models.find((m) => m.path === path) ?? null;
}

/** The examples again, in Examples, each beside any of the same name. */
export async function addExamples() {
  await attempt(async () => {
    for (const example of exampleModels) await library.create("Examples", example.name, example.model);
  });
}

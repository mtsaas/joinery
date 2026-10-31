// The library: `.joinery` packages in a folder, whose subfolders are collections, the same files the Mac app keeps.
// In the app the Rust shell keeps them (src-tauri/src/library.rs); in a plain browser, for development, they're kept in
// memory, starting with the examples.
import { invoke } from "@tauri-apps/api/core";

export interface ModelEntry {
  path: string;
  name: string;
  collection: string | null;
  favorite: boolean;
  /** When last opened, in milliseconds since 1970. */
  opened: number | null;
}

export interface Listing {
  root: string;
  models: ModelEntry[];
  collections: string[];
}

export interface Version {
  file: string;
  /** Milliseconds since 1970. */
  date: number;
  reason: string;
  isReview: boolean;
}

export interface Library {
  list(): Promise<Listing>;
  read(path: string): Promise<{ model: string; baseline: string }>;
  write(path: string, model: string): Promise<void>;
  create(collection: string | null, name: string, model: string): Promise<string>;
  rename(path: string, name: string): Promise<string>;
  move(path: string, collection: string | null): Promise<string>;
  duplicate(path: string): Promise<string>;
  trash(path: string): Promise<void>;
  newCollection(name: string): Promise<string>;
  setFavorite(path: string, favorite: boolean): Promise<void>;
  markOpened(path: string): Promise<void>;
  setBaseline(path: string, model: string): Promise<void>;
  saveVersion(path: string, reason: string, model: string, before: string | null): Promise<boolean>;
  versions(path: string): Promise<Version[]>;
  readVersion(path: string, file: string): Promise<{ model: string; before: string | null }>;
  /** A `.joinery` file or folder chosen elsewhere (or a package's `model.json`), copied into the library. */
  importModel(source: string, collection: string | null): Promise<string>;
  /** A copy of a model, versions and all, saved outside the library. */
  exportModel(path: string, destination: string): Promise<void>;
  renameCollection(name: string, to: string): Promise<string>;
  trashCollection(name: string): Promise<void>;
  /** Shows a model or a collection in Explorer. */
  reveal(path: string): Promise<void>;
}

export const isApp = "__TAURI_INTERNALS__" in window;

/** The examples, bundled: the Mac app's own (examples/ links to Joinery/Examples). */
const examples = import.meta.glob("../examples/*.joinery", { query: "?raw", import: "default", eager: true }) as
  Record<string, string>;

export const exampleModels = Object.entries(examples).map(([path, model]) => ({
  name: decodeURIComponent(path.split("/").at(-1)!.replace(/\.joinery$/, "")),
  model,
}));

const app: Library = {
  list: () => invoke("list_library"),
  read: (path) => invoke("read_model", { path }),
  write: (path, model) => invoke("write_model", { path, model }),
  create: (collection, name, model) => invoke("create_model", { collection, name, model }),
  rename: (path, name) => invoke("rename_model", { path, name }),
  move: (path, collection) => invoke("move_model", { path, collection }),
  duplicate: (path) => invoke("duplicate_model", { path }),
  trash: (path) => invoke("trash_model", { path }),
  newCollection: (name) => invoke("new_collection", { name }),
  setFavorite: (path, favorite) => invoke("set_favorite", { path, favorite }),
  markOpened: (path) => invoke("mark_opened", { path }),
  setBaseline: (path, model) => invoke("set_baseline", { path, model }),
  saveVersion: (path, reason, model, before) => invoke("save_version", { path, reason, model, before }),
  versions: (path) => invoke("list_versions", { path }),
  readVersion: (path, file) => invoke("read_version", { path, file }),
  importModel: (source, collection) => invoke("import_model", { source, collection }),
  exportModel: (path, destination) => invoke("export_model", { path, destination }),
  renameCollection: (name, to) => invoke("rename_collection", { name, to }),
  trashCollection: (name) => invoke("trash_collection", { name }),
  reveal: (path) => invoke("reveal", { path }),
};

/** Kept in memory, for a browser without the shell. */
function memory(): Library {
  interface Stored { model: string; baseline: string; favorite: boolean; opened: number | null; versions: (Version & { model: string; before: string | null })[] }
  const files = new Map<string, Stored>();
  const collections = new Set<string>(["Examples"]);
  for (const example of exampleModels) {
    files.set(`Examples/${example.name}.joinery`, { model: example.model, baseline: "", favorite: false, opened: null, versions: [] });
  }
  const parts = (path: string) => {
    const slash = path.lastIndexOf("/");
    return { collection: slash < 0 ? null : path.slice(0, slash), name: path.slice(slash + 1).replace(/\.joinery$/, "") };
  };
  const unique = (collection: string | null, name: string) => {
    let candidate = name, n = 2;
    const at = (n: string) => (collection ? `${collection}/` : "") + `${n}.joinery`;
    while (files.has(at(candidate))) candidate = `${name} ${n++}`;
    return at(candidate);
  };
  const get = (path: string) => {
    const file = files.get(path);
    if (!file) throw new Error(`There's no data model at ${path}.`);
    return file;
  };
  const relocate = (path: string, to: string) => {
    files.set(to, get(path));
    files.delete(path);
    return to;
  };
  return {
    async list() {
      return {
        root: "(in memory)",
        models: [...files].map(([path, f]) => ({ path, ...parts(path), favorite: f.favorite, opened: f.opened })),
        collections: [...collections].sort(),
      };
    },
    async read(path) { const f = get(path); return { model: f.model, baseline: f.baseline }; },
    async write(path, model) { get(path).model = model; },
    async create(collection, name, model) {
      const path = unique(collection, name);
      files.set(path, { model, baseline: "", favorite: false, opened: null, versions: [] });
      if (collection) collections.add(collection);
      return path;
    },
    async rename(path, name) { return relocate(path, unique(parts(path).collection, name)); },
    async move(path, collection) { if (collection) collections.add(collection); return relocate(path, unique(collection, parts(path).name)); },
    async duplicate(path) {
      const { collection, name } = parts(path);
      const copy = unique(collection, `${name} copy`);
      files.set(copy, { ...get(path), favorite: false, versions: [...get(path).versions] });
      return copy;
    },
    async trash(path) { files.delete(path); },
    async newCollection(name) { let n = name, i = 2; while (collections.has(n)) n = `${name} ${i++}`; collections.add(n); return n; },
    async setFavorite(path, favorite) { get(path).favorite = favorite; },
    async markOpened(path) { get(path).opened = Date.now(); },
    async setBaseline(path, model) { get(path).baseline = model; },
    async saveVersion(path, reason, model, before) {
      const f = get(path);
      const latest = f.versions[0];
      if (!before && latest && !latest.isReview && latest.model === model) return false;
      const date = Math.max(Date.now(), (latest?.date ?? 0) + 1);
      f.versions.unshift({ file: `${date} ${reason}.json`, date, reason, isReview: before !== null, model, before });
      return true;
    },
    async versions(path) { return get(path).versions.map(({ file, date, reason, isReview }) => ({ file, date, reason, isReview })); },
    async readVersion(path, file) {
      const v = get(path).versions.find((v) => v.file === file);
      if (!v) throw new Error("That version is gone.");
      return { model: v.model, before: v.before };
    },
    async importModel() { throw new Error("Importing needs the app."); },
    async exportModel() { throw new Error("Exporting needs the app."); },
    async renameCollection(name, to) {
      let target = to.trim() || name, i = 2;
      while (target !== name && collections.has(target)) target = `${to.trim()} ${i++}`;
      if (target === name) return name;
      collections.delete(name);
      collections.add(target);
      for (const [path, f] of [...files]) {
        if (!path.startsWith(`${name}/`)) continue;
        files.delete(path);
        files.set(`${target}/${path.slice(name.length + 1)}`, f);
      }
      return target;
    },
    async trashCollection(name) {
      collections.delete(name);
      for (const path of [...files.keys()]) if (path.startsWith(`${name}/`)) files.delete(path);
    },
    async reveal() {},
  };
}

export const library: Library = isApp ? app : memory();

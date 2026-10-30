// The app's state, and what changes it: the library, the open model, and its session. The model itself is the core's;
// this keeps what's drawn from it and acts on the core's events (saving, versions, the relay).
import { useLayoutEffect, useReducer } from "preact/hooks";
import { core, drain, scene as readScene, type CoreEvent, type Peer, type Scene } from "./core.ts";
import { library, type Listing } from "./library.ts";

export interface Session {
  role: "host" | "guest";
  status: string;
  links: { edit: string; view: string } | null;
  me: Peer | null;
  peers: Peer[];
  canEdit: boolean;
  title: string;
}

export interface State {
  listing: Listing;
  /** The open model's path in the library, or null while none's open (or one joined, which isn't kept). */
  path: string | null;
  name: string;
  scene: Scene | null;
  session: Session | null;
  /** Briefly shown over the canvas. */
  notice: string | null;
  /** Something that went wrong, until dismissed. */
  failure: string | null;
  showsHistory: boolean;
  showsSettings: boolean;
  showsShare: boolean;
  showsJoin: boolean;
  /** Bumped whenever the scene changes, for the canvas to redraw. */
  revision: number;
}

let state: State = {
  listing: { root: "", models: [], collections: [] }, path: null, name: "", scene: null, session: null, notice: null,
  failure: null, showsHistory: false, showsSettings: false, showsShare: false, showsJoin: false, revision: 0,
};
const listeners = new Set<() => void>();

export function getState(): State {
  return state;
}

export function set(patch: Partial<State>) {
  state = { ...state, ...patch };
  for (const listener of listeners) listener();
}

/** The state, re-rendering when it changes. */
export function useStore(): State {
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  // A layout effect, so it subscribes at once: an effect waits for a frame, which a hidden window may never draw.
  useLayoutEffect(() => {
    listeners.add(rerender);
    return () => void listeners.delete(rerender);
  }, []);
  return state;
}

export const settings = {
  get relay(): string { return localStorage.getItem("relay") || "http://localhost:8787"; },
  set relay(value: string) { localStorage.setItem("relay", value); },
  get name(): string { return localStorage.getItem("name") || "Me"; },
  set name(value: string) { localStorage.setItem("name", value); },
  get avoidTables(): boolean { return localStorage.getItem("avoidTables") === "1"; },
  set avoidTables(value: boolean) { localStorage.setItem("avoidTables", value ? "1" : "0"); },
  get mcpEnabled(): boolean { return localStorage.getItem("mcpEnabled") !== "0"; },
  set mcpEnabled(value: boolean) { localStorage.setItem("mcpEnabled", value ? "1" : "0"); },
};

// MARK: The library

export async function reload() {
  set({ listing: await library.list() });
}

export async function open(path: string) {
  try {
    await saveNow();
    if (state.session) leave();
    const { model, baseline } = await library.read(path);
    core.openModel(model, baseline);
    await library.markOpened(path);
    set({ path, name: nameOf(path), showsHistory: false });
    localStorage.setItem("lastOpened", path);
    await saveVersion("Opened");
    handle(drain());
    await reload();
  } catch (error) {
    fail(error);
  }
}

export function nameOf(path: string): string {
  return path.split(/[\\/]/).at(-1)!.replace(/\.joinery$/, "");
}

export async function newModel(collection: string | null, name = "Untitled Data Model"): Promise<string | null> {
  try {
    const path = await library.create(collection, name, core.emptyModelFile());
    await reload();
    await open(path);
    return path;
  } catch (error) {
    fail(error);
    return null;
  }
}

/** The open model was renamed or moved: keep it open, at its new path. */
export function moved(from: string, to: string) {
  if (state.path === from) set({ path: to, name: nameOf(to) });
}

export function fail(error: unknown) {
  set({ failure: error instanceof Error ? error.message : String(error) });
}

let noticeTimer: number | undefined;
export function notify(notice: string) {
  set({ notice });
  clearTimeout(noticeTimer);
  noticeTimer = window.setTimeout(() => set({ notice: null }), 1600);
}

// MARK: Saving

let saveTimer: number | undefined;

function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = window.setTimeout(saveNow, 500);
}

export async function saveNow() {
  clearTimeout(saveTimer);
  saveTimer = undefined;
  if (!state.path || !core) return;
  try {
    await library.write(state.path, core.modelFile());
  } catch (error) {
    fail(`Couldn't save “${state.name}”: ${error instanceof Error ? error.message : error}`);
  }
}

export async function saveVersion(reason: string, before: string | null = null): Promise<boolean> {
  if (!state.path) return false;
  try {
    return await library.saveVersion(state.path, reason, core.modelFile(), before);
  } catch (error) {
    fail(`Couldn't save a version: ${error instanceof Error ? error.message : error}`);
    return false;
  }
}

/** Ctrl+S: writes it out and keeps a version, one never thinned out. */
export async function saveVersionNow() {
  await saveNow();
  notify((await saveVersion("Saved")) ? "Version saved" : "No changes since the last version");
}

// MARK: The core's events

/** Session hooks, set by the session module, which holds the WebSocket. */
export const sessionHooks = {
  connect: (_url: string) => {},
  send: (_data: string) => {},
  reconnect: (_after: number) => {},
  close: () => {},
};

/** Acts on what the core says happened. Call after every core call that can change anything. */
export function handle(events: CoreEvent[]) {
  let changed = false;
  for (const event of events) {
    switch (event.type) {
      case "changed":
        changed = true;
        break;
      case "version":
        // Before the change: the model as it was is what's still on disk and in the core's last save.
        void saveVersion(event.reason, event.before ?? null);
        break;
      case "baseline":
        if (state.path) void library.setBaseline(state.path, event.model);
        break;
      case "connect":
        sessionHooks.connect(event.socket);
        break;
      case "send":
        sessionHooks.send(event.data);
        break;
      case "links":
        updateSession({ links: { edit: event.edit, view: event.view } });
        break;
      case "peers":
        updateSession({ me: event.me, peers: event.peers });
        break;
      case "status":
        updateSession({ status: event.status });
        break;
      case "reconnect":
        sessionHooks.reconnect(event.after);
        break;
      case "refused":
        notify(`Your change wasn't kept: ${event.reason}`);
        break;
      case "joined":
        updateSession({ title: event.title, canEdit: event.canEdit });
        set({ name: event.title });
        break;
      case "ended":
        sessionHooks.close();
        if (state.session?.role === "guest") set({ path: null, scene: null, name: "" });
        set({ session: null });
        notify(event.reason);
        break;
    }
  }
  if (changed) {
    set({ scene: readScene(), revision: state.revision + 1 });
    if (state.path) scheduleSave();
  }
}

function updateSession(patch: Partial<Session>) {
  if (state.session) set({ session: { ...state.session, ...patch } });
}

/** Runs `body` on the core, then acts on what happened; failures are shown. */
export function act<T>(body: () => T): T | undefined {
  try {
    return body();
  } catch (error) {
    fail(error);
    return undefined;
  } finally {
    handle(drain());
  }
}

export function leave() {
  act(() => core.leaveSession());
}

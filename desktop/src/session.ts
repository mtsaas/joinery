// A live session's WebSocket. The protocol is the core's (Joinery/Collaboration/Protocol): this only carries its bytes,
// reconnects when it says to, and ticks it once a second.
import { core } from "./core.ts";
import { act, getState, notify, set, sessionHooks, settings } from "./store.ts";

let socket: WebSocket | null = null;
let url = "";
let ticker: number | undefined;
let reconnecting: number | undefined;

function connect() {
  socket?.close();
  const ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => act(() => core.sessionConnected());
  ws.onmessage = (e) => act(() => core.sessionReceived(base64(new Uint8Array(e.data as ArrayBuffer))));
  ws.onclose = () => { if (socket === ws) act(() => core.sessionDisconnected()); };
  socket = ws;
}

sessionHooks.connect = (address) => {
  url = address;
  clearInterval(ticker);
  ticker = window.setInterval(() => act(() => core.sessionTick()), 1000);
  connect();
};

sessionHooks.send = (data) => {
  if (socket?.readyState === WebSocket.OPEN) socket.send(bytes(data));
};

sessionHooks.reconnect = (after) => {
  socket?.close();
  socket = null;
  clearTimeout(reconnecting);
  reconnecting = window.setTimeout(connect, after * 1000);
};

sessionHooks.close = () => {
  clearInterval(ticker);
  clearTimeout(reconnecting);
  const closing = socket;
  socket = null;
  // What's queued, the goodbye among it, goes before the connection's let go.
  setTimeout(() => closing?.close(), 500);
};

/** Shares the open model; the links arrive as the relay makes the room. */
export function share() {
  const state = getState();
  if (state.session) return;
  set({ session: { role: "host", status: "Connecting to the relay…", links: null, me: null, peers: [], canEdit: true, title: state.name } });
  act(() => core.hostSession(settings.relay, settings.name, state.name));
}

/** Joins the session a link names; the model opens once the host's copy arrives. */
export function join(link: string) {
  try {
    core.joinSession(link.trim(), settings.name);
  } catch (error) {
    notify(error instanceof Error ? error.message : String(error));
    return;
  }
  set({ path: null, session: { role: "guest", status: "Connecting…", links: null, me: null, peers: [], canEdit: false, title: "" } });
  act(() => {});
}

function base64(data: Uint8Array): string {
  let s = "";
  for (let i = 0; i < data.length; i += 0x8000) s += String.fromCharCode(...data.subarray(i, i + 0x8000));
  return btoa(s);
}

function bytes(data: string): Uint8Array<ArrayBuffer> {
  const s = atob(data);
  const out = new Uint8Array(new ArrayBuffer(s.length));
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

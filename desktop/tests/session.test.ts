// A live session between two copies of the core, through the real relay, as two people's desktop apps would share one:
// the host shares a model, the guest joins from the link, and each sees the other's edits. Needs the relay built
// (`zig build` in relay/), or JOINERY_RELAY naming its binary; skipped otherwise.
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:net";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { drain, edit, example, loadCore, scene, type Core, type Event } from "./harness.ts";

const binary = process.env.JOINERY_RELAY ?? fileURLToPath(new URL("../../relay/zig-out/bin/joinery-relay", import.meta.url));
const skip = existsSync(binary) ? false : `no relay at ${binary}; build it with zig build in relay/`;

let relay: ChildProcess | undefined;
after(() => relay?.kill());

async function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const server = createServer().listen(0, "127.0.0.1", () => {
      const { port } = server.address() as { port: number };
      server.close(() => resolve(port));
    });
  });
}

/** One person's app: a core, its WebSocket to the relay, and what it's heard. */
class Person {
  socket: WebSocket | null = null;
  heard: Event[] = [];
  core: Core;
  constructor(core: Core) { this.core = core; }

  /** Acts on the core's events, as the app's store and session module do. */
  pump() {
    for (const event of drain(this.core)) {
      this.heard.push(event);
      if (event.type === "connect") this.connect(event.socket as string);
      if (event.type === "send" && this.socket?.readyState === WebSocket.OPEN) this.socket.send(Buffer.from(event.data as string, "base64"));
    }
  }

  connect(url: string) {
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    ws.onopen = () => { this.core.sessionConnected(); this.pump(); };
    ws.onmessage = (e) => { this.core.sessionReceived(Buffer.from(e.data as ArrayBuffer).toString("base64")); this.pump(); };
    this.socket = ws;
  }

  async until<T>(find: () => T | undefined, what: string): Promise<T> {
    for (let i = 0; i < 200; i++) {
      const found = find();
      if (found !== undefined) return found;
      await new Promise((r) => setTimeout(r, 25));
    }
    throw new Error(`Timed out waiting for ${what}`);
  }

  event(type: string): Event | undefined {
    return this.heard.find((e) => e.type === type);
  }
}

test("a guest joins a desktop host's session and both see each other's edits", { skip }, async () => {
  const port = await freePort(), metrics = await freePort();
  relay = spawn(binary, ["--port", String(port), "--metrics-port", String(metrics)], { stdio: "ignore" });
  await new Promise((r) => setTimeout(r, 300));

  const host = new Person(await loadCore());
  host.core.openModel(example("Chinook"), "");
  host.core.hostSession(`http://127.0.0.1:${port}`, "Ada", "Chinook");
  host.pump();
  const links = await host.until(() => host.event("links"), "the share links");

  const guest = new Person(await loadCore());
  guest.core.joinSession(links.edit as string, "Grace");
  guest.pump();
  const joined = await guest.until(() => guest.event("joined"), "the guest to join");
  assert.equal(joined.title, "Chinook");
  assert.equal(joined.canEdit, true);
  assert.deepEqual(scene(guest.core).tables.map((t) => t.name).sort(), scene(host.core).tables.map((t) => t.name).sort());

  // The host's edit reaches the guest…
  edit(host.core, "addTable", { at: [0, -400] });
  const added = scene(host.core).tables.length;
  host.pump();
  await guest.until(() => (scene(guest.core).tables.length === added ? true : undefined), "the host's table at the guest");

  // …and the guest's reaches the host.
  const id = scene(guest.core).tables.find((t) => t.name === "Artist")!.id;
  edit(guest.core, "renameTable", { table: id, name: "Performer" });
  guest.pump();
  await host.until(() => (scene(host.core).tables.some((t) => t.name === "Performer") ? true : undefined), "the guest's rename at the host");

  // Both are in the room, by name.
  await host.until(() => {
    const peers = [...host.heard].reverse().find((e) => e.type === "peers");
    return (peers?.peers as { name: string }[] | undefined)?.some((p) => p.name === "Grace") ? true : undefined;
  }, "the host to see Grace");

  guest.core.leaveSession();
  guest.pump();
  host.core.leaveSession();
  host.pump();
  host.socket?.close();
  guest.socket?.close();
});

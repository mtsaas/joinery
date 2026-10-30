// Loads Joinery's core (core-pkg, from scripts/build-core.sh) in Node, as many separate copies as a test needs: each
// is its own WebAssembly instance, with its own open model and session, as two people's apps would be.
import { readFileSync } from "node:fs";
import type { Exports } from "../core-pkg/bridge-js.js";
import { instantiate } from "../core-pkg/instantiate.js";
import { defaultNodeSetup } from "../core-pkg/platforms/node.js";

export type Core = Exports;

export async function loadCore(): Promise<Core> {
  const options = await defaultNodeSetup({ args: [] });
  const { exports } = await instantiate({ ...options, getImports: () => ({}) });
  return exports;
}

export function example(name: string): string {
  return readFileSync(new URL(`../examples/${name}.joinery`, import.meta.url), "utf8");
}

export interface Event {
  type: string;
  [key: string]: unknown;
}

export function drain(core: Core): Event[] {
  return JSON.parse(core.drainEvents());
}

export interface Scene {
  tables: { id: string; name: string; columns: { id: string; name: string }[] }[];
  canUndo: boolean;
  canRedo: boolean;
  summary: string | null;
}

export function scene(core: Core): Scene {
  return JSON.parse(core.scene());
}

export function edit<T = unknown>(core: Core, name: string, args: Record<string, unknown> = {}): T {
  return JSON.parse(core.edit(name, JSON.stringify(args))).result as T;
}

/** An HTTP request to the MCP server, in base64, as the shell hands it over. */
export function mcpRequest(body: unknown): string {
  const json = JSON.stringify(body);
  const http = `POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(json)}\r\n\r\n${json}`;
  return Buffer.from(http).toString("base64");
}

/** The JSON body of an HTTP response in base64. */
export function mcpBody(response: string): any {
  const text = Buffer.from(response, "base64").toString("utf8");
  return JSON.parse(text.slice(text.indexOf("\r\n\r\n") + 4));
}

// The MCP server, for AI assistants. The shell listens (src-tauri/src/mcp.rs) and the core answers
// (Joinery/MCP/Protocol): the library tools, which need the library, are here, as the Mac's are in MCPServer.swift.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { core } from "./core.ts";
import { isApp, library } from "./library.ts";
import { act, getState, nameOf, newModel, open, reload } from "./store.ts";
import { share } from "./session.ts";

export let mcpStatus = isApp ? "Starting…" : "Needs the app";

async function libraryTool(name: string, args: Record<string, unknown>): Promise<string> {
  const state = getState();
  const all = state.listing.models;
  switch (name) {
    case "list_models": {
      const lines = all.map((m) => `- ${m.collection ? `${m.collection}/` : ""}${m.name}${m.path === state.path ? " (open)" : ""}`);
      return lines.length ? lines.join("\n") : "The library is empty.";
    }
    case "open_model": {
      const wanted = String(args.name ?? "").toLowerCase();
      const found = all.find((m) => m.name.toLowerCase() === wanted);
      if (!found) throw new Error(`There's no data model called ${args.name}. Use list_models to see them.`);
      await open(found.path);
      return `Opened ${found.name}.`;
    }
    case "new_model": {
      const collection = all.find((m) => m.path === state.path)?.collection ?? null;
      const path = await newModel(collection, String(args.name || "Untitled Data Model"));
      return `Opened a new, empty data model: ${path ? nameOf(path) : "Untitled Data Model"}.`;
    }
    case "start_review": {
      const title = String(args.title ?? "").replaceAll(":", " –").replaceAll("/", "-").trim() || "Review";
      const path = await newModel("Reviews", title);
      if (!path) throw new Error(`Couldn't start a review: ${getState().failure ?? "no data model opened"}.`);
      return `Opened ${nameOf(path)}, a new, empty data model in Reviews. Next, draw the schema as it was before the change with create_tables, arrange it, then call mark_baseline.`;
    }
    case "mark_baseline": {
      if (!getState().scene) throw new Error("No data model is open in Joinery. Use start_review first.");
      if (core.tableCount() === 0) throw new Error("The data model is empty. Draw the schema as it was before the change with create_tables first.");
      act(() => core.markBaseline());
      return `Took the ${core.tableCount()} tables in ${getState().name} as the baseline: Joinery now shows changes from here as a diff. Next, make the change with alter_table, create_tables, drop_tables, add_foreign_key and remove_foreign_key.`;
    }
    case "get_changes": {
      if (!getState().scene) throw new Error("No data model is open in Joinery. Use start_review first.");
      const report = core.changesReport();
      if (!report) throw new Error("There's no baseline to compare with: call mark_baseline first.");
      return report;
    }
    case "start_sharing": {
      if (!getState().scene) throw new Error("No data model is open in Joinery. Use open_model or new_model first.");
      if (getState().session?.role === "guest") throw new Error(`${getState().name} is a session joined from someone else; only its host can share it.`);
      share();
      // The relay makes the room a moment after connecting, or can't be reached.
      for (let i = 0; i < 100 && !getState().session?.links && getState().session; i++) await new Promise((r) => setTimeout(r, 50));
      const session = getState().session;
      if (!session?.links) throw new Error(`Couldn't start sharing: ${session?.status ?? "the session ended"}. Check the relay in Joinery's Settings.`);
      const others = session.peers.length ? `${session.peers.length} others have joined.` : "No one else has joined yet.";
      return `Sharing ${getState().name}. Edit link: ${session.links.edit} View link: ${session.links.view} Send them as you would a password; each is pasted into Join in Joinery's library. ${others}`;
    }
  }
  throw new Error(`There's no tool called ${name}.`);
}

/** Starts answering assistants, in the app. */
export async function startAssistants() {
  Object.assign(window, {
    joineryHost: { libraryTool: (name: string, args: string) => libraryTool(name, JSON.parse(args)).finally(reload) },
  });
  if (!isApp) return;
  await listen<{ id: number; request: string }>("mcp-request", async (event) => {
    const response = await core.answerMCP(event.payload.request);
    act(() => {});
    await invoke("mcp_respond", { id: event.payload.id, response });
  });
  try {
    await invoke("mcp_start");
    mcpStatus = "Running at http://127.0.0.1:8723/mcp";
  } catch (error) {
    mcpStatus = String(error);
  }
  void library;
}

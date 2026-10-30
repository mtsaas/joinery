// The core as the desktop app drives it: opening, editing, undoing, reviewing, and answering AI assistants.
import assert from "node:assert/strict";
import { test } from "node:test";
import { drain, edit, example, loadCore, mcpBody, mcpRequest, scene } from "./harness.ts";

const core = await loadCore();

test("opens a model and draws its tables and wires", () => {
  core.openModel(example("Sakila"), "");
  assert.ok(drain(core).some((e) => e.type === "changed"));
  const s = scene(core);
  assert.ok(s.tables.length > 10);
  assert.ok(s.tables.some((t) => t.name === "film"));
  const frame = JSON.parse(core.frame(0, JSON.stringify({ tables: {}, ties: {} }), false));
  assert.ok(frame.wires.length > 10);
  assert.ok(frame.wires.every((w: { points: number[] }) => w.points.length >= 4));
});

test("edits are one change each, and undo and redo", () => {
  core.openModel(example("Sakila"), "");
  drain(core);
  const before = scene(core).tables.length;
  const id = edit<string>(core, "addTable", { at: [100, 100] });
  assert.equal(scene(core).tables.length, before + 1);
  edit(core, "renameTable", { table: id, name: "notes" });
  assert.ok(scene(core).tables.some((t) => t.name === "notes"));
  core.undo();
  assert.ok(!scene(core).tables.some((t) => t.name === "notes"));
  core.undo();
  assert.equal(scene(core).tables.length, before);
  assert.equal(scene(core).canRedo, true);
  core.redo();
  assert.equal(scene(core).tables.length, before + 1);
  // Changes ask the shell to save.
  assert.ok(drain(core).some((e) => e.type === "changed"));
});

test("deleting a table asks for a version first", () => {
  core.openModel(example("Chinook"), "");
  drain(core);
  const table = scene(core).tables[0];
  edit(core, "removeTables", { tables: [table.id] });
  const versions = drain(core).filter((e) => e.type === "version");
  assert.deepEqual(versions.map((e) => e.reason), [`Before deleting ${table.name}`]);
});

test("a review shows what changed since the baseline", () => {
  core.openModel(core.emptyModelFile(), "");
  edit(core, "create_tables", { tables: [{ name: "users", columns: [{ name: "id", type: "uuid", primary_key: true }] }] });
  core.markBaseline();
  edit(core, "alter_table", { table: "users", rename_to: "accounts" });
  assert.match(core.changesReport(), /accounts/);
  assert.equal(scene(core).summary, "1 table renamed");
  drain(core);
});

test("answers AI assistants over MCP, leaving the library tools to the shell", async () => {
  core.openModel(core.emptyModelFile(), "");
  drain(core);
  const asked: string[] = [];
  Object.assign(globalThis, {
    joineryHost: { libraryTool: async (name: string) => { asked.push(name); return "- Examples/Sakila (open)"; } },
  });

  const initialized = mcpBody(await core.answerMCP(mcpRequest({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })));
  assert.equal(initialized.result.serverInfo.name, "joinery");

  const listed = mcpBody(await core.answerMCP(mcpRequest({ jsonrpc: "2.0", id: 2, method: "tools/list" })));
  const names = listed.result.tools.map((t: { name: string }) => t.name);
  for (const name of ["list_models", "start_review", "create_tables", "get_changes"]) assert.ok(names.includes(name), name);

  const created = mcpBody(await core.answerMCP(mcpRequest({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: { name: "create_tables", arguments: { tables: [{ name: "orders", columns: [{ name: "id", type: "uuid", primary_key: true }] }] } },
  })));
  assert.equal(created.result.isError, undefined);
  assert.deepEqual(scene(core).tables.map((t) => t.name), ["orders"]);
  // An assistant's first change saves a version before it.
  assert.ok(drain(core).some((e) => e.type === "version" && e.reason === "Before AI assistant changes"));

  const models = mcpBody(await core.answerMCP(mcpRequest({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "list_models" } })));
  assert.equal(models.result.content[0].text, "- Examples/Sakila (open)");
  assert.deepEqual(asked, ["list_models"]);
});

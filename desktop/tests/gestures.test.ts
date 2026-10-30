import assert from "node:assert/strict";
import { test } from "node:test";
import { neighborhood, pull, snap, type Pull } from "../src/canvas/gestures.ts";

test("a drag within tolerance snaps into line, with a guide", () => {
  const { offset, guides } = snap([[0, 0, 100, 50]], [3, 40], [[105, 200, 100, 50]], 6);
  // Its right edge, moved to 103, is 2 from the other's left edge at 105, so it snaps there; down, nothing's near.
  assert.deepEqual(offset, [5, 40]);
  assert.ok(guides.some((g) => g.vertical && g.position === 105));
});

test("held to one axis, it doesn't snap the other way", () => {
  const { offset } = snap([[0, 0, 100, 50]], [3, 0], [[0, 2, 100, 50]], 6, true, false);
  assert.equal(offset[1], 0);
});

const ties = [{ id: "a", position: [100, 0] as [number, number], direction: [0, 1] as [number, number], held: false, wires: ["w", "x"] }];
const grab = (): Pull => ({ cable: "w", start: [150, 0], point: [150, 0], direction: [1, 0], segment: 1, popped: [], target: null });

test("pulled far enough from a tie, a cable pops out of it, and back in when it returns", () => {
  const scene = { ties, cables: { w: ["a"] } };
  const out = pull(grab(), [150 + 90, 0], scene, []);
  assert.deepEqual(out.popped, [{ id: "a", before: true }]);
  assert.equal(out.segment, 0);
  const back = pull(out, [160, 0], scene, []);
  assert.deepEqual(back.popped, []);
  assert.equal(back.segment, 1);
});

test("over a tie it isn't in, that's where it'd go", () => {
  const drawn = [{ id: "b", center: [300, 300] as [number, number], direction: [0, 1] as [number, number], halfLength: 8, count: 2, wires: ["y", "z"], color: null }];
  const over = pull(grab(), [302, 301], { ties, cables: { w: ["a"] } }, drawn);
  assert.equal(over.target?.id, "b");
});

test("focus keeps the tables joined to those in focus", () => {
  const scene = {
    tables: [
      { id: "t1", columns: [{ id: "c1" }] }, { id: "t2", columns: [{ id: "c2" }] }, { id: "t3", columns: [{ id: "c3" }] },
    ],
    wires: [{ id: "w", from: "c2", to: "c1" }],
  } as never;
  assert.deepEqual([...neighborhood(new Set(["t1"]), scene)].sort(), ["t1", "t2"]);
});

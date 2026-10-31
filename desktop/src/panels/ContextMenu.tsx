// Right-clicking: what can be done to what's under the pointer, as the Mac's command wheel and palette offer.
import { useEffect } from "preact/hooks";
import { edit, type Point } from "../core.ts";
import { canvas, clearSelection, deleteSelection, redraw } from "../canvas/Canvas.tsx";
import { ui } from "../canvas/commands.ts";
import type { Hit } from "../canvas/hit.ts";
import { act, getState } from "../store.ts";
import { colorNames } from "../theme.ts";

export interface Menu {
  hit: Hit;
  at: Point;
}

interface Item {
  title: string;
  run: () => void;
  destructive?: boolean;
}

export function ContextMenu({ menu, onClose }: { menu: Menu; onClose: () => void }) {
  useEffect(() => {
    const close = () => onClose();
    window.addEventListener("pointerdown", close);
    window.addEventListener("blur", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("blur", close);
    };
  }, []);

  const o = canvas.overlay;
  const tables = [...o.selectedTables];
  const items: (Item | "-")[] = [];
  const h = menu.hit;
  if (h.kind === "cell") {
    const column = h.table.columns[h.row];
    items.push({ title: column.primaryKey ? "Not a Primary Key" : "Primary Key", run: () => edit("setColumn", { column: column.id, primaryKey: !column.primaryKey }) });
    items.push({ title: column.nullable ? "Required" : "Nullable", run: () => edit("setColumn", { column: column.id, nullable: !column.nullable }) });
    items.push({ title: column.unique ? "Not Unique" : "Unique", run: () => edit("setColumn", { column: column.id, unique: !column.unique }) });
    items.push({ title: "Add Column Below", run: () => edit("addColumn", { table: h.table.id, after: column.id }) });
    items.push({ title: "Delete Column", destructive: true, run: () => edit("removeColumns", { columns: [column.id] }) });
    items.push("-");
  }
  if (tables.length) {
    if (h.kind === "header" || h.kind === "cell") {
      const id = h.table.id;
      items.push({ title: "Open in Designer", run: () => ui.openDesigner(id) });
    }
    if (h.kind === "header") items.push({ title: "Add Column", run: () => edit("addColumn", { table: h.table.id, after: h.table.columns.at(-1)?.id ?? null }) });
    if (tables.length > 1) {
      items.push({ title: "Group as Schema", run: () => edit("group", { tables }) });
      for (const [alignment, title] of [["left", "Align Left Edges"], ["top", "Align Top Edges"], ["center", "Align Centers"]] as const) {
        items.push({ title, run: () => edit("align", { tables, alignment }) });
      }
      items.push({ title: "Distribute Horizontally", run: () => edit("distribute", { tables, horizontally: true }) });
    }
    if (tables.some((id) => getState().scene?.tables.find((t) => t.id === id)?.group)) {
      items.push({ title: "Remove from Schema", run: () => edit("removeFromGroups", { tables }) });
    }
    items.push({ title: "Arrange Selected", run: () => edit("arrange", { layout: "hierarchical", tables }) });
    items.push("-");
    for (const color of colorNames) items.push({ title: `Color: ${color[0].toUpperCase()}${color.slice(1)}`, run: () => edit("recolor", { tables, groups: [], color }) });
    items.push("-");
    items.push({ title: tables.length > 1 ? `Delete ${tables.length} Tables` : "Delete Table", destructive: true, run: deleteSelection });
  } else if (h.kind === "group") {
    items.push({ title: "Bundle Shared Wires", run: () => edit("bundle", { groups: [h.id] }) });
    items.push({ title: "Remove Ports", run: () => edit("removePorts", { groups: [h.id] }) });
    items.push({ title: "Ungroup", destructive: true, run: () => edit("ungroup", { groups: [h.id] }) });
  } else if (h.kind === "tie") {
    items.push({ title: "Turn with Wires", run: () => edit("releaseTie", { ties: [h.id] }) });
    items.push({ title: "Remove Zip Tie", destructive: true, run: () => edit("removeTables", { ties: [h.id] }) });
  } else if (h.kind === "port") {
    items.push({ title: "Remove Port", destructive: true, run: () => edit("removeTables", { ports: [h.id] }) });
  } else if (o.selectedWires.size) {
    items.push({ title: "Delete Foreign Key", destructive: true, run: deleteSelection });
  } else {
    items.push({ title: "New Table", run: () => {
      const [x, y] = canvasPoint(menu.at);
      const id = edit<string>("addTable", { at: [x, y] });
      clearSelection();
      o.selectedTables.add(id);
    } });
    items.push({ title: "Arrange All: Hierarchical", run: () => edit("arrange", { layout: "hierarchical" }) });
    items.push({ title: "Arrange All: Grouped", run: () => edit("arrange", { layout: "orthogonalGroups" }) });
    items.push({ title: "Zoom to Fit", run: () => canvas.fit() });
  }

  return (
    <div class="menu" style={{ left: `${menu.at[0]}px`, top: `${menu.at[1]}px` }} onPointerDown={(e) => e.stopPropagation()}>
      {items.map((item, i) =>
        item === "-" ? <hr key={i} /> : (
          <button key={i} class={item.destructive ? "destructive" : ""} onClick={() => { onClose(); act(item.run); redraw(); }}>
            {item.title}
          </button>
        ),
      )}
    </div>
  );
}

function canvasPoint([x, y]: Point): Point {
  const stage = document.querySelector(".stage")!.getBoundingClientRect();
  const { zoom, offset } = canvas.view;
  return [(x - stage.left - offset[0]) / zoom, (y - stage.top - offset[1]) / zoom];
}

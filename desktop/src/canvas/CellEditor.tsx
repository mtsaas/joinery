// Editing a table's name or a column's name or type in place, over the cell, at the canvas's zoom.
import { useEffect, useRef } from "preact/hooks";
import { edit } from "../core.ts";
import { act, getState } from "../store.ts";
import { fonts } from "../theme.ts";
import { canvas, redraw } from "./Canvas.tsx";
import { Metrics } from "./metrics.ts";
import { moved } from "./render.ts";

export interface Editing {
  table: string;
  /** Null for the table's name. */
  column: string | null;
  part: "name" | "type" | null;
}

export function CellEditor({ editing, onDone }: { editing: Editing; onDone: () => void }) {
  const input = useRef<HTMLInputElement>(null);
  const table = getState().scene?.tables.find((t) => t.id === editing.table);
  const row = table?.columns.findIndex((c) => c.id === editing.column) ?? -1;
  const column = row >= 0 ? table!.columns[row] : null;

  useEffect(() => {
    canvas.overlay.editing = { table: editing.table, column: editing.column };
    redraw();
    input.current?.focus();
    input.current?.select();
    return () => {
      canvas.overlay.editing = null;
      redraw();
    };
  }, [editing.table, editing.column, editing.part]);

  if (!table) return null;
  const [fx, fy] = moved(table, canvas.overlay);
  const { zoom, offset } = canvas.view;
  let x: number = fx + Metrics.gripWidth, y: number = fy, width: number = Metrics.tableWidth - Metrics.gripWidth - Metrics.cellInset, height: number = Metrics.headerHeight;
  let font = `600 ${13 * zoom}px ${fonts.ui}`, value = table.name;
  if (column) {
    y = fy + Metrics.headerHeight + row * Metrics.rowHeight;
    height = Metrics.rowHeight;
    if (editing.part === "type") {
      x = fx + Metrics.tableWidth - Metrics.typeColumnWidth + Metrics.cellInset - 3;
      width = Metrics.typeColumnWidth - Metrics.cellInset;
      font = `400 ${10 * zoom}px ${fonts.mono}`;
      value = column.type + (column.nullable ? "?" : "");
    } else {
      x = fx + Metrics.keyColumnWidth + Metrics.cellInset - 3;
      width = Metrics.tableWidth - Metrics.keyColumnWidth - Metrics.typeColumnWidth - Metrics.cellInset;
      font = `${column.primaryKey ? 500 : 400} ${11 * zoom}px ${fonts.ui}`;
      value = column.name;
    }
  }

  function commit(next: string | null) {
    const text = input.current?.value.trim() ?? "";
    if (text && text !== value) {
      if (!column) act(() => edit("renameTable", { table: table!.id, name: text }));
      else if (editing.part === "type") act(() => edit("setColumn", { column: column.id, type: text, nullable: text.endsWith("?") }));
      else act(() => edit("setColumn", { column: column.id, name: text }));
    }
    onDone();
    if (next === "down") {
      // Return on the last column adds another, as on the Mac.
      const after = getState().scene?.tables.find((t) => t.id === table!.id);
      const index = column ? after!.columns.findIndex((c) => c.id === column.id) : -1;
      const following = after?.columns[index + 1];
      if (following) setTimeout(() => editNext(table!.id, following.id));
      else {
        const id = act(() => edit<string>("addColumn", { table: table!.id, after: column?.id ?? null }));
        if (id) setTimeout(() => editNext(table!.id, id));
      }
    }
  }

  return (
    <input
      ref={input}
      class="cell-editor"
      style={{ left: `${x * zoom + offset[0]}px`, top: `${y * zoom + offset[1]}px`, width: `${width * zoom}px`, height: `${height * zoom}px`, font }}
      defaultValue={value}
      onKeyDown={(e) => {
        if (e.key === "Enter") { e.preventDefault(); commit(e.shiftKey ? null : "down"); }
        else if (e.key === "Escape") { e.preventDefault(); onDone(); }
        else if (e.key === "Tab") { e.preventDefault(); commit(null); }
        e.stopPropagation();
      }}
      onBlur={() => commit(null)}
    />
  );
}

/** Set by the app: starts editing another cell. */
export let editNext: (table: string, column: string) => void = () => {};
export function setEditNext(f: typeof editNext) { editNext = f; }

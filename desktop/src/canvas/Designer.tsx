// A panel over the canvas's right side for working on one table, as the Mac's TableDesigner: its name and color, its
// columns (name, type, key, required, unique, what each references), made-up rows to show the kind of data it holds,
// and notes. Text applies on Return, Tab or clicking away, one undoable change each.
import { useEffect, useState } from "preact/hooks";
import { core, edit, type ColorName } from "../core.ts";
import { act, useStore } from "../store.ts";
import { colorNames, theme } from "../theme.ts";

interface Detail {
  table: {
    id: string;
    name: string;
    color: ColorName;
    notes: string;
    samples: Record<string, string>[];
    columns: { id: string; name: string; type: string; isPrimaryKey: boolean; isNullable: boolean; isUnique: boolean }[];
  };
  /** What each foreign key references, as "table.column", by column. */
  references: Record<string, string>;
}

/** A field whose text applies only when done with, so typing isn't a change a letter at a time. */
function Field({ value, onCommit, label, mono, multiline }: {
  value: string; onCommit: (text: string) => void; label: string; mono?: boolean; multiline?: boolean;
}) {
  const commit = (e: Event) => {
    const text = (e.target as HTMLInputElement | HTMLTextAreaElement).value;
    if (text !== value) onCommit(text);
  };
  if (multiline) {
    return <textarea key={value} aria-label={label} defaultValue={value} onBlur={commit} onKeyDown={(e) => e.stopPropagation()} rows={4} />;
  }
  return (
    // Keyed by its value, so it shows a change made elsewhere but keeps what's being typed through other redraws.
    <input
      key={value}
      type="text"
      aria-label={label}
      class={mono ? "mono" : ""}
      defaultValue={value}
      onBlur={commit}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") (e.target as HTMLInputElement).blur();
        if (e.key === "Escape") { (e.target as HTMLInputElement).value = value; (e.target as HTMLInputElement).blur(); }
      }}
    />
  );
}

export function Designer({ table: id, onClose }: { table: string; onClose: () => void }) {
  const { revision } = useStore();
  const [detail, setDetail] = useState<Detail | null>(null);
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;

  useEffect(() => {
    const next = JSON.parse(core.tableDetail(id)) as Detail | null;
    if (!next) onClose(); else setDetail(next);
  }, [id, revision]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape" && !(e.target instanceof HTMLInputElement)) onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (!detail) return null;
  const { table, references } = detail;
  const set = (column: string, change: Record<string, unknown>) => act(() => edit("setColumn", { column, ...change }));
  const rows = Math.max(table.samples.length, 0);

  /** Rewrites the sample rows without one, through the assistant's tool, which takes them by column name. */
  function removeRow(row: number) {
    const byName = (sample: Record<string, string>) =>
      Object.fromEntries(table.columns.filter((c) => sample[c.id]).map((c) => [c.name, sample[c.id]]));
    act(() => edit("set_sample_data", { table: table.name, rows: table.samples.filter((_, i) => i !== row).map(byName), append: false }));
  }

  return (
    <aside class="designer" aria-label={`Designing ${table.name}`} onPointerDown={(e) => e.stopPropagation()}>
      <header class="designer-header">
        <Field label="Table name" value={table.name} onCommit={(name) => name.trim() && act(() => edit("renameTable", { table: id, name: name.trim() }))} />
        <button class="designer-close" onClick={onClose} title="Close (Escape)">Done</button>
      </header>
      <div class="swatches" role="radiogroup" aria-label="Color">
        {colorNames.map((color) => (
          <button
            key={color}
            role="radio"
            aria-checked={table.color === color}
            title={color}
            class={`swatch${table.color === color ? " chosen" : ""}`}
            style={{ background: theme(dark).color(color) }}
            onClick={() => act(() => edit("recolor", { tables: [id], groups: [], color }))}
          />
        ))}
      </div>

      <h4>Columns</h4>
      <table class="designer-grid">
        <thead>
          <tr><th /><th>Name</th><th>Type</th><th title="Primary key">PK</th><th title="Required (NOT NULL)">Req</th><th title="Unique">UQ</th><th>References</th><th /></tr>
        </thead>
        <tbody>
          {table.columns.map((column, row) => (
            <tr key={column.id}>
              <td class="reorder">
                <button title="Move up" disabled={row === 0} onClick={() => act(() => edit("moveColumn", { column: column.id, table: id, to: row - 1 }))}>↑</button>
                <button title="Move down" disabled={row === table.columns.length - 1} onClick={() => act(() => edit("moveColumn", { column: column.id, table: id, to: row + 2 }))}>↓</button>
              </td>
              <td><Field label="Column name" value={column.name} onCommit={(name) => name.trim() && set(column.id, { name: name.trim() })} /></td>
              <td><Field label="Type" mono value={column.type} onCommit={(type) => type.trim() && set(column.id, { type: type.trim(), nullable: type.trim().endsWith("?") || column.isNullable })} /></td>
              <td><input type="checkbox" aria-label="Primary key" checked={column.isPrimaryKey} onChange={() => set(column.id, { primaryKey: !column.isPrimaryKey })} /></td>
              <td><input type="checkbox" aria-label="Required" checked={!column.isNullable} onChange={() => set(column.id, { nullable: !column.isNullable })} /></td>
              <td><input type="checkbox" aria-label="Unique" checked={column.isUnique} onChange={() => set(column.id, { unique: !column.isUnique })} /></td>
              <td class="references">
                <Field label="References" value={references[column.id] ?? ""} onCommit={(target) =>
                  act(() => edit("alter_table", { table: table.name, change_columns: [{ name: column.name, references: target.trim() }] }))} />
              </td>
              <td><button class="destructive" title="Delete column" onClick={() => act(() => edit("removeColumns", { columns: [column.id] }))}>×</button></td>
            </tr>
          ))}
        </tbody>
      </table>
      <button class="designer-add" onClick={() => act(() => edit("addColumn", { table: id, after: table.columns.at(-1)?.id ?? null }))}>Add Column</button>

      <h4>Sample Data</h4>
      {table.columns.length > 0 && (
        <div class="samples">
          <table class="designer-grid">
            <thead><tr>{table.columns.map((c) => <th key={c.id}>{c.name}</th>)}<th /></tr></thead>
            <tbody>
              {Array.from({ length: rows }, (_, row) => (
                <tr key={row}>
                  {table.columns.map((c) => (
                    <td key={c.id}>
                      <Field label={`${c.name}, row ${row + 1}`} value={table.samples[row]?.[c.id] ?? ""}
                        onCommit={(value) => act(() => edit("setSample", { table: id, row, column: c.id, value }))} />
                    </td>
                  ))}
                  <td><button class="destructive" title="Delete row" onClick={() => removeRow(row)}>×</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <button class="designer-add" disabled={!table.columns.length}
        onClick={() => act(() => edit("setSample", { table: id, row: rows, column: table.columns[0].id, value: "" }))}>Add Row</button>

      <h4>Notes</h4>
      <Field label="Notes" multiline value={table.notes} onCommit={(notes) => act(() => edit("setNotes", { table: id, notes }))} />
    </aside>
  );
}

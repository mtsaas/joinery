// The open model's earlier versions, by day, as the Mac's VersionHistory.swift: pick one (or step with the arrow keys)
// and it shows on the canvas, read-only, compared with now, or, a review's, as the change it was, until it's restored or
// "Now" is picked again.
import { useEffect, useRef, useState } from "preact/hooks";
import { core } from "../core.ts";
import { library, type Version } from "../library.ts";
import { act, fail, getState, saveVersion, set, useStore } from "../store.ts";

interface Read {
  model: string;
  before: string | null;
}

export function History({ path }: { path: string }) {
  const state = useStore();
  const [versions, setVersions] = useState<Version[]>([]);
  const [read, setRead] = useState<Record<string, Read | null>>({});
  const list = useRef<HTMLDivElement>(null);
  const picked = state.preview?.file ?? null;

  // Listed again as the model changes: a change can save a version.
  useEffect(() => {
    let cancelled = false;
    void library.versions(path).then(async (found) => {
      if (cancelled) return;
      setVersions(found);
      const next: Record<string, Read | null> = { ...read };
      for (const v of found) {
        if (v.file in next) continue;
        next[v.file] = await library.readVersion(path, v.file).catch(() => null);
      }
      if (!cancelled) setRead(next);
    }).catch(fail);
    return () => { cancelled = true; };
  }, [path, state.revision]);

  useEffect(() => list.current?.focus(), []);

  async function pick(version: Version | null) {
    if (!version) {
      act(() => core.endPreview());
      set({ preview: null });
      return;
    }
    const contents = read[version.file] ?? await library.readVersion(path, version.file).catch(() => null);
    if (!contents) return fail("That version can't be read.");
    act(() => core.showVersion(contents.model, version.isReview ? contents.before ?? "" : ""));
    set({ preview: version });
  }

  async function restore(version: Version) {
    const contents = read[version.file] ?? await library.readVersion(path, version.file).catch(() => null);
    if (!contents) return fail("Couldn't restore that version: it can't be read.");
    await saveVersion("Before restoring an earlier version");
    act(() => core.endPreview());
    set({ preview: null });
    act(() => core.edit("replace", JSON.stringify({ model: contents.model })));
  }

  // Up and down step through the versions, Now first; Return restores the one picked.
  function onKey(e: KeyboardEvent) {
    const order: (Version | null)[] = [null, ...versions];
    const index = order.findIndex((v) => (v?.file ?? null) === picked);
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const next = order[Math.min(order.length - 1, Math.max(0, index + (e.key === "ArrowDown" ? 1 : -1)))];
      void pick(next);
    } else if (e.key === "Enter" && state.preview) {
      e.preventDefault();
      void restore(state.preview);
    } else if (e.key === "Escape") {
      set({ showsHistory: false });
    }
    e.stopPropagation();
  }

  const now = core.modelFile();
  const days = groupByDay(versions);
  return (
    <div class="panel history" role="dialog" aria-label="Version History">
      <h3>Version History</h3>
      <div class="history-list" ref={list} tabIndex={0} role="listbox" aria-label="Versions" onKeyDown={onKey}>
        <button role="option" aria-selected={picked === null} class={`version ${picked === null ? "picked" : ""}`} onClick={() => void pick(null)}>
          <span class="reason">Now</span>
          <span class="secondary">As it is, to edit</span>
        </button>
        {days.map(([day, inDay]) => (
          <section key={day}>
            <h4>{dayTitle(new Date(inDay[0].date))}</h4>
            {inDay.map((v) => (
              <button key={v.file} role="option" aria-selected={picked === v.file} class={`version ${picked === v.file ? "picked" : ""}`}
                onClick={() => void pick(v)} onDblClick={() => void restore(v)}>
                <span class="line">
                  <span class="reason">{v.reason}</span>
                  <span class="time">{new Date(v.date).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span>
                </span>
                <span class="secondary">{caption(read[v.file], v, now)}</span>
              </button>
            ))}
          </section>
        ))}
        {versions.length === 0 && (
          <p class="secondary empty-history">No versions yet. One is kept the next time this data model is opened, or changed in a big way.</p>
        )}
      </div>
      <div class="history-footer">
        {state.preview && <button class="primary wide" onClick={() => void restore(state.preview!)}>Restore This Version</button>}
        <p class="secondary">
          Kept when you open it, before AI assistants' changes, before deleting or rearranging tables, hourly while editing, and
          when a review ends, showing its change. Older ones thin out to one a day, then one a week; reviews and those saved with
          Ctrl+S stay. Restoring can be undone.
        </p>
        <div class="row"><button onClick={() => set({ showsHistory: false })}>Close</button></div>
      </div>
    </div>
  );
}

function caption(contents: Read | null | undefined, version: Version, now: string): string {
  if (contents === undefined) return "";
  if (contents === null) return "Can't be read";
  if (version.isReview && contents.before) return `Review: ${core.compare(contents.before, contents.model)}`;
  return change(contents.model, now);
}

interface Model {
  tables: { id: string; name: string; position?: unknown }[];
  zipTies?: unknown[];
  relationships?: { zipTies?: unknown[] }[];
}

/** What restoring `earlier` would do to `now`, as the Mac says it. */
export function change(earlier: string, now: string): string {
  if (earlier === now) return "The same as now";
  let then: Model, current: Model;
  try {
    then = JSON.parse(earlier);
    current = JSON.parse(now);
  } catch {
    return "Can't be read";
  }
  const currentIDs = new Set(current.tables.map((t) => t.id)), thenIDs = new Set(then.tables.map((t) => t.id));
  const back = then.tables.filter((t) => !currentIDs.has(t.id)).map((t) => t.name);
  const gone = current.tables.filter((t) => !thenIDs.has(t.id)).map((t) => t.name);
  const list = (names: string[]) => (names.length <= 2 ? names.join(" and ") : `${names.length} tables`);
  const parts = [];
  if (back.length) parts.push(`brings back ${list(back)}`);
  if (gone.length) parts.push(`removes ${list(gone)}`);
  if (!parts.length) return arrangementless(then) === arrangementless(current) ? "Tables in other places" : "Different columns or keys";
  return `Restoring ${parts.join(" and ")}`;
}

/** Without where things are: tables at the origin, no zip ties. */
function arrangementless(model: Model): string {
  return JSON.stringify({
    ...model,
    tables: model.tables.map((t) => ({ ...t, position: null })),
    zipTies: [],
    relationships: (model.relationships ?? []).map((r) => ({ ...r, zipTies: [] })),
  });
}

function groupByDay(versions: Version[]): [string, Version[]][] {
  const days = new Map<string, Version[]>();
  for (const v of versions) {
    const key = new Date(v.date).toDateString();
    days.set(key, [...(days.get(key) ?? []), v]);
  }
  return [...days];
}

export function dayTitle(day: Date): string {
  const today = new Date(), yesterday = new Date(Date.now() - 86_400_000);
  if (day.toDateString() === today.toDateString()) return "Today";
  if (day.toDateString() === yesterday.toDateString()) return "Yesterday";
  return day.toLocaleDateString([], { weekday: "long", year: "numeric", month: "long", day: "numeric" });
}

/** "Today at 5:15 PM", for the comparison bar. */
export function when(date: number): string {
  return `${dayTitle(new Date(date))} at ${new Date(date).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`;
}

void getState;

// Ctrl+K: a search field over every command and table, as the Mac's CommandPalette. Arrow keys move, Return runs,
// Escape closes.
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { redraw } from "./Canvas.tsx";
import { commands, score, tableCommands, type Command } from "./commands.ts";

export function Palette({ onClose }: { onClose: () => void }) {
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  const list = useRef<HTMLDivElement>(null);
  const all = useMemo(() => [...commands(), ...tableCommands()], []);

  // Best match first, then the shorter title; with no query, in their order, so New Table comes first.
  const matches = useMemo(() => {
    if (!query.trim()) return all.filter((c) => !c.id.startsWith("table-"));
    return all
      .map((command, index) => ({ command, index, score: score(query, command.title) }))
      .filter((m) => m.score !== null)
      .sort((a, b) => b.score! - a.score! || a.command.title.length - b.command.title.length || a.index - b.index)
      .map((m) => m.command);
  }, [query, all]);
  const selected = Math.min(Math.max(highlight, 0), matches.length - 1);

  useEffect(() => {
    list.current?.querySelector(".highlighted")?.scrollIntoView({ block: "nearest" });
  }, [selected]);

  function run(command: Command) {
    onClose();
    command.run();
    redraw();
  }

  return (
    <div class="palette-backdrop" onPointerDown={onClose}>
      <div class="palette" role="dialog" aria-label="Commands" onPointerDown={(e) => e.stopPropagation()}>
        <input
          class="palette-search"
          placeholder="Search commands and tables"
          value={query}
          autoFocus
          ref={(el) => el?.focus()}
          onInput={(e) => { setQuery((e.target as HTMLInputElement).value); setHighlight(0); }}
          onKeyDown={(e) => {
            e.stopPropagation();
            if (e.key === "ArrowDown") { e.preventDefault(); setHighlight(selected + 1 >= matches.length ? 0 : selected + 1); }
            else if (e.key === "ArrowUp") { e.preventDefault(); setHighlight(selected <= 0 ? matches.length - 1 : selected - 1); }
            else if (e.key === "Enter") { e.preventDefault(); if (matches[selected]) run(matches[selected]); }
            else if (e.key === "Escape") { e.preventDefault(); onClose(); }
          }}
        />
        <div class="palette-list" ref={list} role="listbox">
          {matches.length === 0 && <div class="palette-empty">No matches</div>}
          {matches.map((command, i) => (
            <button
              key={command.id}
              role="option"
              aria-selected={i === selected}
              class={`palette-row${i === selected ? " highlighted" : ""}${command.destructive ? " destructive" : ""}`}
              onPointerEnter={() => setHighlight(i)}
              onClick={() => run(command)}
            >
              <span class="palette-title">{command.title}</span>
              {command.subtitle && <span class="palette-subtitle">{command.subtitle}</span>}
              {command.shortcut && <span class="palette-shortcut">{command.shortcut}</span>}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

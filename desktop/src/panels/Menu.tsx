// A context menu: items, separators and submenus, closed by clicking elsewhere or Escape. The canvas's and the
// sidebar's share it.
import { useEffect, useState } from "preact/hooks";

export type MenuItem =
  | { title: string; run: () => void; destructive?: boolean; disabled?: boolean }
  | { title: string; items: MenuItem[] }
  | "-";

export function PopupMenu({ items, at, onClose }: { items: MenuItem[]; at: [number, number]; onClose: () => void }) {
  useEffect(() => {
    const close = () => onClose();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("pointerdown", close);
    window.addEventListener("blur", close);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("blur", close);
      window.removeEventListener("keydown", key);
    };
  }, []);
  // Kept on screen: flipped up or left where it would run off the window's edge.
  const x = Math.min(at[0], window.innerWidth - 230), y = Math.min(at[1], window.innerHeight - 40 - items.length * 26);
  return (
    <div class="menu" role="menu" style={{ left: `${Math.max(4, x)}px`, top: `${Math.max(4, y)}px` }} onPointerDown={(e) => e.stopPropagation()}>
      <Items items={items} onClose={onClose} />
    </div>
  );
}

function Items({ items, onClose }: { items: MenuItem[]; onClose: () => void }) {
  const [open, setOpen] = useState<number | null>(null);
  return (
    <>
      {items.map((item, i) => {
        if (item === "-") return <hr key={i} />;
        if ("items" in item) {
          return (
            <div key={i} class="submenu" onPointerEnter={() => setOpen(i)} onPointerLeave={() => setOpen(null)}>
              <button role="menuitem" aria-haspopup="menu" aria-expanded={open === i} onClick={() => setOpen(i)}>
                {item.title}<span class="chevron">›</span>
              </button>
              {open === i && <div class="menu nested" role="menu"><Items items={item.items} onClose={onClose} /></div>}
            </div>
          );
        }
        return (
          <button key={i} role="menuitem" class={item.destructive ? "destructive" : ""} disabled={item.disabled}
            onClick={() => { onClose(); item.run(); }}>
            {item.title}
          </button>
        );
      })}
    </>
  );
}

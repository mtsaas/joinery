# Joinery

An infinite canvas for sketching SQL schemas on macOS, in the spirit of Freeform. Tables sit on the canvas. Each column has a socket on both sides, and you drag from one socket to another to add a foreign key. Foreign keys are drawn as springy wires, and you can zip-tie wires together into bundles.

Requires macOS 26 and Xcode 26 or later. Open `Joinery.xcodeproj` and press ⌘R. To try it out, open `Samples/Storefront.joinery`.

## Using it

| Action | How |
| --- | --- |
| Command palette | ⌘K: every command, plus each table to jump to; arrows, Return, Escape |
| Add a table | **T**, the toolbar table button, or Insert ▸ Table (⌥⌘T); type its name straight away |
| Edit cells | Double-click a cell, or press Return with a table selected |
| Move between cells | Tab / Shift-Tab; Return goes name → type → new column; Tab past the last cell adds a column |
| Set a type | Type it or its start: `int`, `ts`, `bool`, `jsonb`; end with `?` for nullable |
| Primary key / delete column | ⇧⌘K / ⌘⌫ while editing, or double-click the key cell to toggle PK |
| Finish editing | Escape (a first Escape closes the type suggestions) |
| Add a foreign key | Drag from a column's socket onto another column (the referenced one) |
| Wires avoid tables | View ▸ Wires Avoid Tables, or from the palette: wires bend around tables in their way |
| Reroute a wire | Click it to add a bend point there, or drag it to add one and move it; double-click a bend point to remove it |
| Zip-tie wires | Option-drag a line across two or more wires, or turn on the Zip Tie tool and drag |
| Select | Click; Shift-click to add; drag on empty canvas for a box; ⌘A for everything; Option-click a wire |
| Move | Drag anything selected to move the whole selection; arrow keys nudge (Shift for 10 points) |
| Delete | Delete removes the selection; right-click tables, ties and bend points for more |
| Pan / zoom | Scroll, or hold Space and drag / pinch, ⌘-scroll, ⌘+ ⌘- ⌘0, Zoom to Fit ⌘1 |

Each wire takes the color of the table it references, and FK cells match it. Wires leave sockets and pass through
ties and bend points square to them.

## Layout

```
Joinery/
  App/         App entry, document window, menu commands, debug hooks
  Document/    Schema model (Codable JSON, .joinery) and its edits
  Canvas/      Canvas view, table cards, routing, wire physics, zip tying
JoineryTests/  Swift Testing: physics, zip ties and bend points, type parsing, schema repair
scripts/       build.sh (unsandboxed CLI build), make_icon.swift
```

The wires work in two steps. `Routing` computes each wire's rest curve: Bézier segments from socket to socket that pass through the wire's zip ties. `WireSimulation` then springs a chain of points toward that curve. The ends of each wire are stiff and the middle is loose, and neighboring points pull on each other, so a wobble travels along the wire. The simulation runs only while something is moving.

## Checking from the command line

Debug builds have hooks for checking the app from the command line (see `App/DebugHooks.swift`):

```sh
scripts/build.sh /tmp/joinery-dd
JOINERY_SCRIPT="tie 320 -20 320 140" JOINERY_SNAPSHOT=/tmp/out.png \
  /tmp/joinery-dd/Build/Products/Debug/Joinery.app/Contents/MacOS/Joinery "$PWD/Samples/Storefront.joinery"
```

To run the tests, use ⌘U in Xcode, or `xcodebuild -project Joinery.xcodeproj -scheme Joinery test`.

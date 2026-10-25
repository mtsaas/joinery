# Joinery

An infinite canvas for sketching SQL schemas on macOS, in the spirit of Freeform. Tables sit on the canvas. Each column has a socket on both sides, and you drag from one socket to another to add a foreign key. Foreign keys are drawn as springy wires, and you can zip-tie wires together into bundles.

Requires macOS 26 and Xcode 26 or later. Open `Joinery.xcodeproj` and press ⌘R.

## Library

Schemas live in a library shown in the sidebar. Each schema is a plain `.joinery` file (readable JSON) in the app's own storage, and each collection is a folder. File ▸ Show Library in Finder shows where they are.

- **New:** ⌘N makes a schema, in the selected schema's collection. ⇧⌘N makes a collection, which you can name straight away.
- **Rename, duplicate, move, delete:** right-click a schema or collection. You can also drag schemas onto a collection or onto the Schemas heading. Move to Trash can be undone from the Trash.
- **Saving and undo:** changes save themselves, half a second after you stop and whenever you switch schemas. Undo (⌘Z) covers the open schema.
- **Opening and importing:** double-clicking a `.joinery` file in Finder, or File ▸ Import Schema… (⌘O), copies it into the library and opens it.
- **Examples:** a new library starts with an Examples collection containing Chinook, Northwind, Sakila, the Stack Overflow data dump, and Storefront. File ▸ Add Examples puts back any you've deleted. `scripts/make_examples.py` generates them.

## Using it

| Action | How |
| --- | --- |
| Command palette | ⌘K: every command, plus each table to jump to; arrows, Return, Escape |
| Align / distribute | With tables selected, ⌘K then Align Left Edges, Align Centers, … Distribute Horizontally |
| Add a table | **T**, the toolbar table button, or Insert ▸ Table (⌥⌘T); type its name straight away |
| Edit cells | Double-click a cell, or press Return with a table selected |
| Move between cells | Tab / Shift-Tab; Return goes name → type → new column; Tab past the last cell adds a column |
| Set a type | Type it or its start: `int`, `ts`, `bool`, `jsonb`; end with `?` for nullable |
| Primary key / delete column | ⇧⌘K / ⌘⌫ while editing, or double-click the key cell to toggle PK |
| Finish editing | Escape (a first Escape closes the type suggestions) |
| Add a foreign key | Drag from a socket onto another column; if one end is a primary key, it's the one referenced |
| Add a column for a key | Drag from a socket onto a table's header: it gets a column named for yours (`users.id` gives `user_id`), of its type, referencing it |
| Wires avoid tables | View ▸ Wires Avoid Tables, or from the palette: wires bend around tables in their way |
| Reroute a wire | Double-click it to add a bend point there, then drag the point; double-click a bend point to remove it |
| Zip-tie wires | Right-drag (or Option-drag) a line across two or more wires, starting off a table |
| Select | Click tables, wires, ties; Shift-click to add; drag a box over tables and wires; ⌘A for everything |
| Move | Drag anything selected to move the whole selection; arrow keys nudge (Shift for 10 points) |
| Delete | Delete removes the selection; right-click tables, ties and bend points for more |
| Pan / zoom | Scroll, or hold Space and drag / pinch, ⌘-scroll, ⌘+ ⌘- ⌘0, Zoom to Fit ⌘1 |

Each wire takes the color of the table it references, and FK cells match it. Wires leave sockets and pass through
ties and bend points square to them.

## Layout

```
Joinery/
  App/         App entry, menu commands, debug hooks
  Library/     The library of files and collections, the sidebar, the editor for an open schema
  Document/    Schema model (Codable JSON, .joinery), its edits, reading and writing files
  Examples/    The bundled example schemas
  Canvas/      Canvas view, table cards, routing, wire physics, zip tying
JoineryTests/  Swift Testing: physics, zip ties and bend points, type parsing, schema repair, library file operations
scripts/       build.sh (unsandboxed CLI build), make_icon.swift, make_examples.py
```

The wires work in two steps. `Routing` computes each wire's rest curve: Bézier segments from socket to socket that pass through the wire's zip ties. `WireSimulation` then springs a chain of points toward that curve. The ends of each wire are stiff and the middle is loose, and neighboring points pull on each other, so a wobble travels along the wire. The simulation runs only while something is moving.

## Checking from the command line

Debug builds have hooks for checking the app from the command line (see `App/DebugHooks.swift`):

```sh
scripts/build.sh /tmp/joinery-dd
JOINERY_LIBRARY=/tmp/joinery-library JOINERY_OPEN=Sakila JOINERY_SCRIPT="tie 320 -20 320 140" JOINERY_SNAPSHOT=/tmp/out.png \
  /tmp/joinery-dd/Build/Products/Debug/Joinery.app/Contents/MacOS/Joinery
```

To run the tests, use ⌘U in Xcode, or `xcodebuild -project Joinery.xcodeproj -scheme Joinery test`.

# Joinery

An infinite canvas for sketching SQL data models on macOS, in the spirit of Freeform. Tables sit on the canvas. Each column has a socket on both sides, and you drag from one socket to another to add a foreign key. Foreign keys are drawn as springy wires, and you can zip-tie wires together into bundles.

Requires macOS 26 and Xcode 26 or later. Open `Joinery.xcodeproj` and press ⌘R.

## Library

Data models live in a library you browse as in Freeform. The sidebar has All Data Models, Recents (opened or changed in the last month), Favorites, and your collections. The main area shows the chosen group's data models as a grid of live previews, or as a list with table counts. Search matches data model and table names. Each data model is a plain `.joinery` file (readable JSON) in the app's own storage, and each collection is a folder. File ▸ Show Library in Finder shows where they are.

- **Open:** double-click a data model, or click it and press Return. It fills the window. ⌘↑ or the back button returns to the library.
- **New:** ⌘N or the toolbar's compose button makes a data model, in the collection being shown, and opens it. ⇧⌘N or the folder button makes a collection, which you can name straight away.
- **Rename, duplicate, favorite, move, delete:** right-click a data model or collection. You can also drag data models onto a collection in the sidebar. Delete moves the clicked data model to the Trash, from where it can be put back. Favorites and when a data model was last opened are kept on the file itself, so they follow it through renames and moves.
- **Saving and undo:** changes save themselves, half a second after you stop and whenever you switch data models. Undo (⌘Z) covers the open data model.
- **Opening and importing:** double-clicking a `.joinery` file in Finder, or File ▸ Import Data Model… (⌘O), copies it into the library and opens it.
- **Examples:** a new library starts with an Examples collection containing Chinook, Northwind, Sakila, the Stack Overflow data dump, and Storefront. File ▸ Add Examples puts back any you've deleted. `scripts/make_examples.py` generates them.

## Using it

| Action | How |
| --- | --- |
| Command wheel | Right-click: commands in a ring around the pointer. Move toward one and click. With tables or ties selected, aligning points the way things go: left edges west, top edges north; on a table, rename, add a column, delete or recolor; on a wire, add a bend point or delete it |
| Command palette | ⌘K: every command, plus each table to jump to; arrows, Return, Escape |
| Align / distribute | With tables or zip ties selected, right-click for the wheel, or ⌘K then Align Left Edges, Align Centers, … Distribute Horizontally (tables). Aligned ties stand on the line and are held square to it; right-click one for Turn with Wires to free it |
| Add a table | **T**, the toolbar table button, or Insert ▸ Table (⌥⌘T); type its name straight away |
| Edit cells | Tables are grids, like a spreadsheet: click a cell to put the cursor there and just type to replace it; double-click or F2 edits it in place. Return on a selected table renames it |
| Move between cells | Arrow keys; Tab / Shift-Tab along the row; Return goes down, and past the last row adds a column; Delete clears a cell |
| Set a type | Type it or its start: `int`, `ts`, `bool`, `jsonb`, and the rest shows faded; end with `?` for nullable |
| Primary key / columns | Space (or ⇧⌘K) toggles the key; ⌘↩ inserts a column below, ⌘⌫ deletes one |
| Required / unique | Columns are required (NOT NULL) unless their type ends in `?`; ⇧⌘R toggles it. ⇧⌘U makes a column unique, shown as UQ after its name. Right-clicking a column row also offers both, with the primary key, rename, type, insert and delete |
| Finish editing | Escape cancels a cell's edit; Escape again leaves the grid |
| Add a foreign key | Drag from a socket onto another column; if one end is a primary key, it's the one referenced |
| Add a column for a key | Drag from a socket onto a table's header: it gets a column named for yours (`users.id` gives `user_id`), of its type, referencing it |
| Wires avoid tables | View ▸ Wires Avoid Tables, or from the palette: wires bend around tables in their way |
| Reroute a wire | Double-click it to add a bend point there, then drag the point; double-click a bend point to remove it |
| Focus | Turn on focus mode (F, or the toolbar's scope button), then select a table or group: it, the tables its foreign keys join it to, and the wires among them stay; everything else fades |
| Group (schemas) | Select tables and press ⌘G (or right-click ▸ Group) to draw a named boundary around them, and type its name; for a database, its schema. Click a group's name to select it with its tables and the zip ties inside it, drag the name to move them all, double-click it to rename. Drop a table inside a group to put it there; right-click a table ▸ Remove from Group to take it out. ⇧⌘G ungroups, leaving the tables |
| Zip-tie wires | Turn on the zip-tie tool (Z, or the toolbar's tie button), then drag a line across two or more wires; it stays on until you press Z or Escape. Option-drag ties without it |
| Select | Click tables, wires, ties; Shift-click to add; drag a box around tables, ties and wires to select those wholly inside it; ⌘A for everything |
| Move | Drag anything selected to move the whole selection. Tables snap into line with others, edges or centers, and guides show where they line up; hold ⌘ to move freely. Hold Shift to keep a move horizontal or vertical. Arrow keys nudge (Shift for 10 points) |
| Delete | Delete removes the selection, or from the wheel |
| Pan / zoom | Scroll, right-drag, or hold Space and drag / pinch, ⌘-scroll, ⌘+ ⌘- ⌘0, Zoom to Fit ⌘1 |

Each wire takes the color of the table it references, and FK cells match it. Wires leave sockets and pass through
ties and bend points square to them.

## AI assistants (MCP)

While Joinery is open it runs an MCP server at `http://127.0.0.1:8723/mcp`, reachable only from this Mac. An assistant connected to it can read and edit the data model open in the window. Changes show up as they're made, save themselves, and undo with ⌘Z.

Joinery ▸ Settings (⌘,) ▸ AI Assistants shows whether the server is running, has copyable setup for each kind of assistant, and can turn the server off. "Connect an AI Assistant" in the ⌘K palette opens it. To connect Claude Code, run:

```bash
claude mcp add --transport http joinery http://127.0.0.1:8723/mcp
```

Other assistants can use the same URL. Those that only run local commands can bridge to it with `npx -y mcp-remote http://127.0.0.1:8723/mcp`.

| Tool | Does |
| --- | --- |
| `list_models`, `open_model`, `new_model` | Choose what to work on |
| `get_model` | Every table, column, type, key and foreign key |
| `create_tables` | Adds tables, placed clear of the others (beside the rest of their schema, given one). A column's `references` (`"users"` or `"users.id"`) makes it a foreign key, so a whole data model can be made in one call |
| `alter_table` | Renames, recolors, moves to another schema, adds, drops or changes columns |
| `set_schema`, `drop_schema` | Make, fill, rename or recolor a schema, drawn as a group around its tables; or remove it, keeping the tables |
| `drop_tables`, `add_foreign_key`, `remove_foreign_key` | What they say |

Tables take `schema`, the group they're drawn in. Columns take `primary_key`, `nullable` (or `required`), `unique` and `references`. Types accept SQL spellings, such as `varchar(255)`, `decimal(10,2)`, `bigserial` and `timestamp with time zone`. Each call applies completely or not at all.

## Frame rate (Debug builds)

The bottom-left corner shows frames per second while anything moves, and what the last frame cost: routing the wires and drawing them. `JOINERY_SCRIPT="shake <table> <seconds>"` drags a table about and prints the frame rate and how long each whole update took.

## Scale test

`scripts/scale-test.sh` builds an optimized copy with the debug hooks. For data models of 10 to 200 made-up tables (the same each run), it drags a table about, zoomed to fit and at 50%, with wires running under tables and then avoiding them. It prints frames per second, our own work per frame (routing and drawing wires), and the whole view update each move causes. Give it other sizes as `scripts/scale-test.sh <derived-data-dir> "300:450 500:800"`.

At 200 tables and 300 foreign keys, with wires avoiding tables, a drag holds 120 fps, and our work plus the view update takes about 6 ms of the 8.3 ms a frame allows.

## Routing feedback (Debug builds)

To show how a cable *should* run, use Debug ▸ Routing Feedback Mode (⌥⌘R, also in the ⌘K palette).

1. Click a cable. A grey copy appears with points along it; its sockets and ties stay fixed.
2. Drag the points to where the cable should go. The area between the grey line and the real cable is shaded. Click the grey line to add a point; right-click a point to remove it.
3. Optionally add a note, then press Return to save or Esc to discard.

Each saved correction records:
- **Replay data:** the whole data model as it was, which foreign key, and whether wires were avoiding tables.
- **The routing that produced the line:** `Routing.version` and its parameters.
- **Both lines:** the routed line and the expected one, plus your control points and note.

Corrections are kept inside the library. Debug ▸ Export Routing Feedback… writes them all to one JSON file. `scripts/score-feedback.sh routing-feedback.json` then replays every case against the current routing and reports how far each lands from the expected line, then and now.

## Layout

```
Joinery/
  App/         App entry, menu commands, debug hooks
  Library/     The library of files and collections, the sidebar, the editor for an open data model
  Document/    The data model (Codable JSON, .joinery), its edits, reading and writing files
  Examples/    The bundled example data models
  Debug/       Routing feedback mode, frame-rate readout, made-up data models for the scale test (Debug builds only)
  MCP/         The MCP server for AI assistants, and its data model tools
  Canvas/      Canvas view, table drawing, routing, wire physics, zip tying
JoineryTests/  Swift Testing: physics, zip ties and bend points, type parsing, data model repair, library file operations
scripts/       build.sh (unsandboxed CLI build), make_icon.swift, make_examples.py, score-feedback.sh
```

The wires work in two steps. `Routing` computes each wire's rest curve: Bézier segments from socket to socket that pass through the wire's zip ties. `WireSimulation` then springs a chain of points toward that curve. The ends of each wire are stiff and the middle is loose, and neighboring points pull on each other, so a wobble travels along the wire. The simulation runs only while something is moving.

It stays fast as data models grow:
- **Routing:** each wire's route is reused until its ends, ties or nearby tables move, so dragging a table reroutes only its own wires and those near it. Wires that do need bending around tables are spread across the cores.
- **Tables:** all tables are drawn directly in one layer (`TableLayer`), not as views. Only tables in view are drawn, shapes of one color are filled together, and text is laid out once per string and drawn with Core Text, so it's sharp at any zoom.

## Checking from the command line

Debug builds have hooks for checking the app from the command line (see `App/DebugHooks.swift`):

```sh
scripts/build.sh /tmp/joinery-dd
JOINERY_LIBRARY=/tmp/joinery-library JOINERY_OPEN=Sakila JOINERY_SCRIPT="tie 320 -20 320 140" JOINERY_SNAPSHOT=/tmp/out.png \
  /tmp/joinery-dd/Build/Products/Debug/Joinery.app/Contents/MacOS/Joinery
```

To run the tests, use ⌘U in Xcode, or `xcodebuild -project Joinery.xcodeproj -scheme Joinery test`.

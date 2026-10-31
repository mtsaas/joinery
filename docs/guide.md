# Joinery guide

An infinite canvas for sketching SQL data models on macOS, in the spirit of Freeform. Tables sit on the canvas. Each column has a socket on both sides, and you drag from one socket to another to add a foreign key. Foreign keys are drawn as springy wires, and you can zip-tie wires together into bundles.

Requires macOS 26 and Xcode 26 or later. Open `Joinery.xcodeproj` and press ⌘R. Joinery for Windows and Linux opens the
same `.joinery` files, joins the same sessions and serves the same MCP tools; its library is `Joinery` in your Documents
folder, and Ctrl takes the place of ⌘.

## Library

Data models live in a library you browse as in Freeform. The sidebar has All Data Models, Recents (opened or changed in the last month), Favorites, and your collections. The main area shows the chosen group's data models as a grid of live previews, or as a list with table counts. Search matches data model and table names. Each data model is a `.joinery` package in the app's own storage: a folder Finder shows as one file, holding the model as readable JSON (`model.json`) and its version history (`Versions/`). Each collection is a folder. Older single-file `.joinery` models still open, and become packages the first time they're opened. File ▸ Show Library in Finder shows where they are. Click an open data model's title, above the canvas, to rename it.

- **Open:** double-click a data model, or click it and press Return. It fills the window. ⌘↑ or the back button returns to the library.
- **New:** ⌘N or the toolbar's compose button makes a data model, in the collection being shown, and opens it. ⇧⌘N or the folder button makes a collection, which you can name straight away.
- **Rename, duplicate, favorite, move, delete:** right-click a data model or collection. You can also drag data models onto a collection in the sidebar. Delete moves the clicked data model to the Trash, from where it can be put back. Favorites and when a data model was last opened are kept on the file itself, so they follow it through renames and moves.
- **Saving and undo:** changes save themselves, half a second after you stop and whenever you switch data models. Undo (⌘Z) covers the open data model.
- **Version history:** the clock button lists earlier versions, by day. Arrow through them and each shows on the canvas, read-only, until Done or Escape; Restore This Version brings one back, undoably. Versions are kept when you open a data model, before an AI assistant's first change in a while, before deleting or rearranging tables, hourly while editing, when a review ends, and whenever you press ⌘S. Everything from the last two days stays, then one a day for a month, then one a week; reviews and ⌘S versions are never thinned out. They live in the `.joinery` package, so they go wherever the file goes. The bar at the bottom switches between Then, Changes and Now. Changes draws both at once, as a code diff would:
  - Tables and columns added are green; removed ones are put back where they were, dashed red and struck through.
  - A changed column shows twice, as it was (struck through) and as it is, marked ~ in orange.
  - Foreign keys added are green; removed ones are dashed red. Everything unchanged fades.
  - Things are matched by ID, so a rename shows as a change. Moving tables isn't one.
- **Opening and importing:** double-clicking a `.joinery` file in Finder, or File ▸ Import Data Model… (⌘O), copies it into the library and opens it.
- **Examples:** a new library starts with an Examples collection containing Chinook, Northwind, Sakila, the Stack Overflow data dump, and Storefront. File ▸ Add Examples puts back any you've deleted. `scripts/make_examples.py` generates them.

## Using it

| Action | How |
| --- | --- |
| Command wheel | Right-click: commands in a ring around the pointer. Move toward one and click. With tables or ties selected, aligning points the way things go: left edges west, top edges north; on a table, rename, add a column, delete or recolor; on several tables, recolor them all; in a group (anywhere in its empty space), rename, ungroup or recolor it; on a wire, add a bend point or delete it. The command palette (⌘K) has Color commands for whatever's selected, tables and groups |
| Command palette | ⌘K: every command, plus each table to jump to; arrows, Return, Escape |
| Align / distribute | With tables or zip ties selected, right-click for the wheel, or ⌘K then Align Left Edges, Align Centers, … Distribute Horizontally (tables). Aligned ties stand on the line and are held square to it; right-click one for Turn with Wires to free it |
| Add a table | **T**, the toolbar table button, or Insert ▸ Table (⌥⌘T); type its name straight away |
| Edit cells | Tables are grids, like a spreadsheet: click a cell to put the cursor there and just type to replace it; double-click or F2 edits it in place. Return on a selected table renames it |
| Table designer | Right-click a table ▸ Open in Designer (or ⌘K ▸ Open in Designer) for a large panel over the canvas's right side: the table's name and color; its columns, with name, type, key, required and unique, what each references, and buttons to add and delete them; a spreadsheet of sample rows, a column per column, to show the kind of data it holds; and notes. It floats over the canvas as a glass panel, its columns, sample rows and notes in rounded cards. Tab goes field to field and on to the next row, past the last adding a column or a row; Return goes down. Edits apply when you press Return, Tab or click away, each one undoable. Esc or the round × closes it. Return on a selected header still renames the table in place |
| Reorder columns | Drag a column's row up or down its table: a line shows where it'll go. Its wires follow it |
| Move between cells | Arrow keys; Tab / Shift-Tab along the row; Return goes down, and past the last row adds a column; Delete clears a cell |
| Set a type | Type it or its start: `int`, `ts`, `bool`, `jsonb`, and the rest shows faded; end with `?` for nullable |
| Primary key / columns | Space (or ⇧⌘K) toggles the key; ⌘↩ inserts a column below, ⌘⌫ deletes one |
| Required / unique | Columns are required (NOT NULL) unless their type ends in `?`; ⇧⌘R toggles it. ⇧⌘U makes a column unique, shown as UQ after its name. Right-clicking a column row also offers both, with the primary key, rename, type, insert and delete |
| Finish editing | Escape cancels a cell's edit; Escape again leaves the grid |
| Add a foreign key | Drag from a socket onto another column; if one end is a primary key, it's the one referenced |
| Add a column for a key | Drag from a socket onto a table's header: the column it'll get shows in the table, wired up, as you hold it there, named for yours (`users.id` gives `user_id`) and of its type; let go to make it |
| Wires avoid tables | View ▸ Wires Avoid Tables, or from the palette: wires bend around tables in their way |
| Pull a cable | Drag a wire (or a bus) anywhere along it and it follows the pointer, springing back when let go. Pull it far enough from a zip tie or bend point next to where you grabbed it (80 points further than it was) and it pops out, then the next one along, so a long pull tugs it out of a run of ties; bring it back close (within 30 points) and it snaps back in, last one first. Let go over a zip tie (it lights up) to put it in. One undoable change |
| Reroute a wire | Double-click it to add a bend point there, then drag the point; double-click a bend point to remove it. Drop a bend point on a zip tie (it lights up) to add its wire to the tie |
| Combine zip ties | Drag a zip tie onto another: it lights up and the wires show running through it together; let go to combine them, each wire in the slot nearest where it was. One undoable change |
| Auto layout | The toolbar's Layout menu lays the selected tables (and selected groups' tables) out afresh, where they were, moved into open space only if they'd land on something; with nothing selected, every table. Orthogonal Groups, as in DataGrip, packs each group (and each set of joined tables) as a compact block of related tables; Hierarchical puts referenced tables left of those referencing them, block by block. Either way, tables then swap places with nearby ones (within their column, for Hierarchical) while that shortens their wires, each crossing counting as 400 points of wire, so related tables end up close and wires cross less; the same every time. `scripts/layout-bench.sh` measures it. Zip ties and bend points on their wires are removed, as they were placed for the old layout. ⌘Z puts everything back |
| Untangle Selection | Layout ▸ Untangle Selection (also in the command palette and right-click wheel) moves the selected tables, step by step, toward fewer crossing wires: gradient descent on how deeply wires cross, not random, so the same selection always comes out the same. Tables stay within a little more than the area they spanned. Zip ties in the selection and on the moved tables' wires are deleted (hidden as soon as it starts). Esc stops it; ⌘Z undoes the whole thing at once |
| Focus | Turn on focus mode (F, or the toolbar's scope button) with a table or group selected, or select one after: it, the tables its foreign keys join it to, the wires among them and their zip ties stay; everything else fades. Focus stays put while you click about and build, and tables you add join it. ⇧F focuses on the selection instead; the palette can add the selection to focus |
| Group (schemas) | Select tables and press ⌘G (or right-click ▸ Group) to draw a named boundary around them, and type its name; for a database, its schema. Click a group's name to select it with its tables and the zip ties inside it, drag the name to move them all, double-click it to rename. Drag a table into a group (its middle inside the boundary) to put it there: the group lights up and stretches round it while you drag, so you see it'll join before you let go. Dragged from one group into another, it moves across; right-click a table ▸ Remove from Group to take it out. ⇧⌘G ungroups, leaving the tables |
| Ports (buses between groups) | Hover near a group's edge and click the + that appears to add a port there (only a click on the + itself, not anywhere near the edge): a small solid pill on the edge, growing out of the +, with an end inside the group and one outside. Drag from the outside socket to a column outside the group (or drag that column's socket onto the port) to plug it in; it takes that column's name, one connection only. Every wire between that column and the group's tables then runs to the port's inside end, side by side, and one bus, a cable twice a wire's width, from its outside end to the column. The port grows a bar across its inside end to take its wires, a pill with one, a sideways T with many, easing as they come and go. Drag from the inside socket to a column or table in the group, or drag a column's socket onto the port, to add a foreign key through it. A bus is a cable like any other: zip-tie it, double-click it for a bend point, select it, delete it (which removes the port). Click a port (or either of its sockets) to select it, and press Delete, or right-click it ▸ Delete Port, to remove it; a new port starts selected, so Delete right after takes back a stray one. Drag a port along the edge, around corners too, to move it; double-click it to put it back facing its column. Right-click a group ▸ Bundle Shared Wires adds a port for each outside column 3 or more of its wires go to; Remove Ports takes them all away |
| Zip-tie wires | Turn on the zip-tie tool (Z, or the toolbar's tie button), then drag a line across two or more wires; it stays on until you press Z or Escape. Option-drag ties without it |
| Select | Click tables, wires, ties; Shift-click to add; drag a box around tables, ties and wires to select those wholly inside it; ⌘A for everything |
| Rename a table | Double-click its header and type; Tab goes on to its first column's name, then type, and so on, making a new column after the last |
| Move | Drag a table by its header (a grip shows there under the pointer); with several things selected, drag any of them to move the whole selection. Tables snap into line with others, edges or centers, and guides show where they line up; hold ⌘ to move freely. Hold Shift to keep a move horizontal or vertical. Arrow keys nudge (Shift for 10 points) |
| Copy as Markdown | Edit ▸ Copy as Markdown (⇧⌘C), ⌘K, or right-click: the selected tables (a selected group's included), or every table with nothing selected, as Markdown to paste into a chat with an AI assistant. A Tables section lists each table's schema and columns, with type, keys, whether required, what each references and what references the table; a Schema section has the PostgreSQL to create them; a Notes section has their notes |
| Copy and paste | ⌘C copies the selected tables (a selected group's included), with their foreign keys, zip ties and groups, then offers, in a popover over them, the tables they're joined to by foreign keys, nearest first (joined directly, 2 keys away, …), to search and check; Copy copies again with those, their groups holding only the tables copied; ⌘X cuts; ⌘V pastes, on the same canvas (a little offset, further each time) or in another data model (in the middle of the view). Names that are taken get a number; pasted tables join a group of the same name; foreign keys to tables left behind stay where those tables exist |
| Delete | Delete removes the selection, or from the wheel |
| Minimap | Bottom right: the whole data model small, with a frame around what's in view; click or drag in it to go there. View ▸ Show Minimap (⇧⌘M) hides it |
| Pan / zoom | Scroll, right-drag, or hold Space and drag / pinch, ⌘-scroll, ⌘+ ⌘- ⌘0, Zoom to Fit ⌘1 |

Each wire takes the color of the table it references, and FK cells match it. Wires leave sockets and pass through
ties and bend points square to them.

## Live sessions

Share a data model live and others can edit it with you, each in their own Joinery.

- **Share:** the people button at the top right of the editor. Start Sharing connects to a relay and gives two links: one to edit, one only to watch. The `start_sharing` MCP tool does the same for an AI assistant.
- **The relay** passes changes between everyone and can't read them: everything is encrypted end to end, with a key only the links carry. Settings ▸ Sharing says which relay to use, such as `wss://relay.example.com`; left empty, it's one on this Mac (`http://localhost:8787`). Run your own from the container image or Helm chart in `relay/`. Links name their relay, so people joining needn't set anything.
- **Joining:** paste the link into Join in the library's toolbar. The data model is open only while the session is: it isn't added to the library, and it closes when you leave or the host stops sharing.
- **Seeing each other:** everyone's pointer shows with their name, what they've selected is ringed in their color, and tables they drag move as they drag them.
- **Undo** undoes only your own changes. If your change refers to something that's just been deleted, it's taken back and you're told.
- **Dropped connections:** Joinery reconnects on its own and sends what was edited meanwhile, each change made once. A host gone more than 30 seconds ends the session.
- **The host's copy** is the one that's saved, with its version history.

A link is the only thing between the internet and your data model, so share it as you would a password. `docs/relay.md` describes the protocol.

## AI assistants (MCP)

While Joinery is open it runs an MCP server at `http://127.0.0.1:8723/mcp`, reachable only from this Mac. An assistant connected to it can read and edit the data model open in the window. Changes show up as they're made, save themselves, and undo with ⌘Z. Before an assistant's first change in a while, a version is kept to go back to (see Version history).

Joinery ▸ Settings (⌘,) ▸ AI Assistants shows whether the server is running, has copyable setup for each kind of assistant, and can turn the server off. "Connect an AI Assistant" in the ⌘K palette opens it. To connect Claude Code, run:

```bash
claude mcp add --transport http joinery http://127.0.0.1:8723/mcp
```

Other assistants can use the same URL. Those that only run local commands can bridge to it with `npx -y mcp-remote http://127.0.0.1:8723/mcp`.

| Tool | Does |
| --- | --- |
| `list_models`, `open_model`, `new_model` | Choose what to work on |
| `start_review` | Starts reviewing a schema change: see below |
| `save_version`, `list_versions`, `compare`, `restore_version`, `delete_version` | Named versions, such as `main` and `draft 1`, and what changed between any two: see below |
| `get_model` | Every table, column, type, key and foreign key, and where everything is: each table's and schema's frame, and the bounds of it all |
| `create_tables` | Adds tables. A column's `references` (`"users"` or `"users.id"`) makes it a foreign key, so a whole data model can be made in one call. They're placed in open space, clear of every table and schema: a schema's new tables as a compact block beside the rest of it, otherwise beside the tables they reference, otherwise beside everything |
| `set_sample_data` | Fills a table's sample data (the spreadsheet in its designer) with rows of column name to value, replacing or appending. `create_tables` takes `sample_rows` and `notes` too, `alter_table` takes `notes`, and `get_model` returns both |
| `move_tables` | Moves tables as a block: beside a table or schema, in the nearest open space, or to given coordinates |
| `alter_table` | Renames, recolors, moves to another schema, adds, drops or changes columns |
| `arrange` | Lays every table, or only the `tables` given, out afresh: `orthogonal_groups` or `hierarchical`; removes the zip ties on their wires |
| `set_schema`, `drop_schema` | Make, fill, rename or recolor a schema, drawn as a group around its tables (tables that would stretch it over others are brought beside the rest); or remove it, keeping the tables |
| `drop_tables`, `add_foreign_key`, `remove_foreign_key` | What they say |

Tables take `schema`, the group they're drawn in. Columns take `primary_key`, `nullable` (or `required`), `unique` and `references`. Types accept SQL spellings, such as `varchar(255)`, `decimal(10,2)`, `bigserial` and `timestamp with time zone`. Each call applies completely or not at all.

### Reviewing schema changes

Ask an assistant to show how a pull request, branch or uncommitted change alters the database, and it can draw the change in Joinery as a diff. The server offers a `review_schema_changes` prompt with the steps (in Claude Code, `/mcp__joinery__review_schema_changes 482`), and the tools say them too:

1. `start_review` makes an empty data model, named for the change, in a Reviews collection, and opens it.
2. The assistant draws the tables the change touches as they were before it, with those their foreign keys join, using `create_tables`, then `arrange`.
3. `save_version` saves that as the base, named for it, such as `main`.
4. The assistant makes the change with the editing tools. A rename is made as a rename, so it shows as one.
5. `compare` from `main` to `current` (the data model as it is now) lists what changed, for the assistant to check and sum up, and shows it in the window.

When the change is updated later, such as new commits on the pull request, the assistant opens the same review, saves the state reviewed so far (`draft 1`), makes only what's new, and compares any pair: `main` to `draft 1`, `draft 1` to `current`, `main` to `current`.

### Named versions

A data model can keep any number of named versions, each the whole model as it was when saved under that name. They're only saved and deleted on purpose, never thinned out, and kept in the package, in `named-versions.json`, so they go where it goes.

- `save_version` saves the model as it is under a name. A name already used isn't saved over unless asked.
- `list_versions` lists them, oldest first, with what changed from each to the next, and how the model as it is now stands.
- `compare` lists what changed from one to another, either side a version or `current`, and shows it in the window.
- `restore_version` makes the model as a version is, to try something else from there. It can be undone, and it won't lose changes saved in no version unless told to.
- `delete_version` deletes one; `get_model` with `version` reads one.

While two are compared, the canvas shows the comparison bar: Before, Changes and After, and From and To menus to pick another pair. You can move tables, zip-tie wires and change table and group colors in whatever version is shown, and open tables in the designer to read them, but not change its schema; each change is kept in that version (in Changes, a table removed since belongs to the earlier version, and every other table to the later one). The same goes for versions picked from Version History. A comparison with now follows the assistant's changes as they're made, and the view follows them until you pan or zoom. Version History lists the named versions first; picking one compares it with now. The ⊗ button ends the comparison and goes back to editing the data model as it is. The named versions stay, and the change compared is kept in the version history too, as a review: picking it there shows the change as it was, however much you've edited since. Reviews are never thinned out.

A review from before named versions, with its `baseline.json`, becomes a named version called `Before`, compared with now, when it's next opened.

Building, testing and releasing Joinery are in [development.md](development.md).

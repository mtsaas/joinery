# Joinery

An infinite canvas for sketching SQL schemas on macOS, in the spirit of Freeform. Tables sit on the canvas. Each column has a socket on both sides, and you drag from one socket to another to add a foreign key. Foreign keys are drawn as springy wires, and you can zip-tie wires together into bundles.

Requires macOS 26 and Xcode 26 or later. Open `Joinery.xcodeproj` and press ⌘R. To try it out, open `Samples/Storefront.joinery`.

## Using it

| Action | How |
| --- | --- |
| Add a table | Toolbar table button, or Insert ▸ Table (⌥⌘T) |
| Edit tables and columns | Select a table, then show the inspector (toolbar, right) |
| Add a foreign key | Drag from a column's socket onto another column (the referenced one) |
| Zip-tie wires | Option-drag a line across two or more wires, or turn on the Zip Tie tool and drag |
| Move a zip tie | Drag it |
| Cut a zip tie | Select it and press Delete, or use its context menu |
| Pan / zoom | Scroll or drag empty canvas / pinch, ⌘-scroll, ⌘+ ⌘- ⌘0, Zoom to Fit ⌘1 |

Each wire takes the color of the table it references. Selecting a table, wire or tie highlights its wires.

## Layout

```
Joinery/
  App/         App entry, document window, menu commands, debug hooks
  Document/    Schema model (Codable JSON, .joinery) and its edits
  Canvas/      Canvas view, table cards, routing, wire physics, zip tying
  Inspector/   Inspector for the selection
JoineryTests/  Swift Testing: physics, zip tying, schema repair
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

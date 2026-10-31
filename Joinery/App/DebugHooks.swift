#if DEBUG
import SwiftUI

/// Lets the app be checked from the command line, without clicking. Set in the environment:
/// - `JOINERY_LIBRARY=<dir>`: use that folder as the library (see `Library`), so tests never touch the real one.
/// - `JOINERY_OPEN=<name>`: select the model with that name. A `.joinery` path passed as an argument is imported and
///   selected too.
/// - `JOINERY_SETTINGS=themes|sharing|assistants`: opens Settings at that pane, and snapshots it rather than the main window.
/// - `JOINERY_APPEARANCE=light|dark`: whatever the system's set to. `JOINERY_WINDOW_SIZE=2560x1080`: the window's size,
///   in points, on the widest screen.
/// - `JOINERY_SNAPSHOT=out.png`: saves the front window to `out.png` and quits. `JOINERY_SNAPSHOT_FRAMES=n` saves n
///   frames 50 ms apart (out-0.png, out-1.png, …) to check an animation; `JOINERY_SNAPSHOT_DELAY` sets the wait.
/// - `JOINERY_SCRIPT`: semicolon-separated steps run against the first document after a second:
///   `move <table> <dx> <dy>`, `tie <x1> <y1> <x2> <y2>` (canvas points; shows the line for half a second, then
///   ties), `select <table>`, `edit <table>`, `space` (toggles held), `click <x> <y>` (on canvas or a wire), `nudge <dx> <dy>` (moves the selection), `place <x> <y>` (puts the selected ties there),
///   `type <text>` and `key tab|return|escape|up|down|cmd+<letter>|shift+cmd+<letter>` (real key events), `selection`, `counts`, `rightdrag <x1> <y1> <x2> <y2>`, `rightclick <x> <y>`, `drop-preview <table.column> <x> <y>`, `open-palette`, `feedback-on`, `handle <n> <dx> <dy>`, `feedback-note <text>`, `feedback-save`, `palette` (prints its state), `dump` (prints the tables), `zoom <factor>`, `look <x> <y> <zoom>` (centers on that canvas point), `focus <table> <zoom>` (centers on that table), `shake <table> <seconds>` (drags it about and prints frame stats), `generate <tables> <foreign keys>` (replaces the model with a made-up one; see `scripts/scale-test.sh`), `quit`, `select-ties`, `group <table> <table>…` (groups them, as ⌘G), `groups` (prints them), `hold-drag <table> <dx> <dy>` (drags it that far in view points and holds), `wheel` (prints it), `wheel-pick <direction>` (east, northWest, …), `wheel-color <color>`, `ties` (prints them),
///   `end-review` (as End Comparison), `theme <name>` (chooses that palette), `history [index]` (opens version history at that version), `wait <seconds>`.
@MainActor
enum DebugHooks {
    private static let environment = ProcessInfo.processInfo.environment
    private static var hasRunScript = false

    static func launched() {
        if let name = environment["JOINERY_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        if let pane = environment["JOINERY_SETTINGS"] {
            UserDefaults.standard.set(pane, forKey: "settingsPane")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let index = menu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) else { return print("no Settings item") }
                menu.performActionForItem(at: index)
            }
        }
        if let name = environment["JOINERY_OPEN"] {
            let library = Library.shared
            library.selection = (library.models + library.collections.flatMap(\.models)).first { Library.name(of: $0) == name }
        }
        if environment["JOINERY_SCRIPT"] != nil {
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                print("menu opened:", (note.object as? NSMenu)?.items.map(\.title) ?? [])
            }
        }
        guard let path = environment["JOINERY_SNAPSHOT"] else { return }
        let delay = environment["JOINERY_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 2
        let frames = environment["JOINERY_SNAPSHOT_FRAMES"].flatMap(Int.init) ?? 1
        for frame in 0..<frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(frame) * 0.05) {
                let output = frames == 1 ? path : path.replacingOccurrences(of: ".png", with: "-\(frame).png")
                Self.capture(to: output)
                if frame == frames - 1 { exit(0) }
            }
        }
    }

    /// CGWindowListCreateImage is obsoleted in the SDK, but an app may still capture its own windows without Screen
    /// Recording permission, so it's looked up at run time. The biggest window, with any of the app's others over it
    /// (popovers, menus) drawn where they are.
    private static func capture(to path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return print("snapshot failed") }
        let image = { (window: NSWindow) in
            unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
        }
        var windows = NSApp.windows.filter(\.isVisible).sorted { $0.orderedIndex > $1.orderedIndex }
        if environment["JOINERY_SETTINGS"] != nil { windows.removeAll { $0.title == "Joinery" } }
        guard let main = windows.max(by: { $0.frame.width < $1.frame.width }), let base = image(main) else { return print("snapshot failed") }
        // Wide enough for what hangs over its edges, as a popover by the toolbar can.
        let over = windows.filter { $0 !== main && $0.frame.intersects(main.frame) }
        let bounds = over.reduce(main.frame) { $0.union($1.frame) }
        let scale = CGFloat(base.width) / main.frame.width
        guard let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return print("snapshot failed") }
        for window in [main] + over {
            guard let picture = window === main ? base : image(window) else { continue }
            context.draw(picture, in: CGRect(x: (window.frame.minX - bounds.minX) * scale, y: (window.frame.minY - bounds.minY) * scale,
                                             width: window.frame.width * scale, height: window.frame.height * scale))
        }
        guard let composite = context.makeImage() else { return print("snapshot failed") }
        try? NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    static func script(_ document: Binding<DataModel>, canvas: CanvasController) async {
        // Once, though a tool may open another model, and so another editor, partway through.
        guard let script = ProcessInfo.processInfo.environment["JOINERY_SCRIPT"], !hasRunScript else { return }
        hasRunScript = true
        try? await Task.sleep(for: .seconds(1))
        if let size = environment["JOINERY_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
           let window = NSApp.windows.first(where: \.isVisible) {
            // On the largest screen, as an ultra-wide display would have it.
            let screen = NSScreen.screens.max { $0.frame.width < $1.frame.width } ?? window.screen
            let origin = screen.map { CGPoint(x: $0.visibleFrame.minX, y: $0.visibleFrame.maxY - size[1]) } ?? .zero
            window.setFrame(CGRect(origin: origin, size: CGSize(width: size[0], height: size[1])), display: true)
            try? await Task.sleep(for: .seconds(0.5))
        }
        // Menu shortcuts only reach the active app, and a launch from a shell starts in the background.
        NSApp.activate()
        NSApp.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.3))
        for step in script.split(separator: ";") {
            let words = step.split(separator: " ").map(String.init)
            let numbers = words.dropFirst().compactMap(Double.init).map { CGFloat($0) }
            let table = document.wrappedValue.tables.firstIndex { $0.name == words.dropFirst().first }
            switch words.first {
            case "move" where table != nil && numbers.count == 2:
                document.wrappedValue.tables[table!].position += CGPoint(x: numbers[0], y: numbers[1])
            case "select" where table != nil:
                canvas.selection = [.table(document.wrappedValue.tables[table!].id)]
            case "edit" where table != nil:
                canvas.edit(.name(of: document.wrappedValue.tables[table!].id))
            case "click" where numbers.count == 2:
                NotificationCenter.default.post(name: .click, object: canvas, userInfo: ["point": CGPoint(x: numbers[0], y: numbers[1])])
            case "place" where numbers.count == 2:
                // Moves the selected ties to a point, in canvas points.
                for index in document.wrappedValue.zipTies.indices where canvas.selectedTies.contains(document.wrappedValue.zipTies[index].id) {
                    document.wrappedValue.zipTies[index].position = CGPoint(x: numbers[0], y: numbers[1])
                }
            case "nudge" where numbers.count == 2:
                document.wrappedValue.move(tables: canvas.selectedTables, ties: canvas.selectedTies, by: CGPoint(x: numbers[0], y: numbers[1]))
            case "type" where words.count > 1:
                for character in step.drop(while: { $0 == " " }).dropFirst(5) { await press(String(character)) }
            case "key" where words.count == 2:
                // A named key, or ⌘ plus a letter as "cmd+k".
                let codes: [String: (UInt16, String)] = ["tab": (48, "\t"), "return": (36, "\r"), "escape": (53, "\u{1b}"),
                                                          "delete": (51, "\u{7f}"),
                                                          "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
                                                          "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "f2": (120, "\u{F705}"),
                                                          "space": (49, " ")]
                if let (code, characters) = codes[words[1]] {
                    await press(characters, keyCode: code)
                } else if words[1] == "cmd+up" {
                    await press("\u{F700}", keyCode: 126, modifiers: .command)
                } else if words[1] == "cmd+delete" {
                    await press("\u{7f}", keyCode: 51, modifiers: .command)
                } else if words[1].hasPrefix("shift+cmd+"), let letter = words[1].last {
                    await press(String(letter), keyCode: ["u": 32, "r": 15, "k": 40][String(letter)] ?? 0, modifiers: [.command, .shift])
                } else if words[1].hasPrefix("cmd+"), let letter = words[1].last {
                    await press(String(letter), keyCode: ["k": 40, "a": 0, "c": 8, "v": 9, "x": 7][String(letter)] ?? 0, modifiers: .command)
                }
            case "open-palette":
                canvas.togglePalette()
            case "windows":
                print("windows:", NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) })
            case "cell":
                let model = document.wrappedValue
                let row: String = switch canvas.cell?.row {
                case .header?: "header"
                case .column(let id)?: model.columnLocations[id].map { $0.table.columns[$0.row].name } ?? "?"
                case nil: "none"
                }
                print("cell \(row).\(canvas.cell.map { "\($0.part)" } ?? "-") editing=\(canvas.isEditingCell) draft=\"\(canvas.draft)\"")
            case "shake" where (table != nil || words.count > 1) && numbers.count == 1:
                // Drags the table (or the group, by name) back and forth as fast as a hand would, every display frame, as
                // a drag does.
                if let group = document.wrappedValue.groups.first(where: { $0.name == words[1] }) {
                    canvas.selectGroup(group.id, in: document.wrappedValue, extending: false)
                } else if let table {
                    canvas.selection = [.table(document.wrappedValue.tables[table].id)]
                } else {
                    print("shake: no table or group called \(words[1])")
                    break
                }
                _ = FrameMeter.shared.report(over: 1)
                let start = ProcessInfo.processInfo.systemUptime
                var layouts: [Double] = [], displays: [Double] = []
                let window = NSApp.windows.first(where: \.isVisible)
                while ProcessInfo.processInfo.systemUptime - start < numbers[0] {
                    let t = ProcessInfo.processInfo.systemUptime - start
                    // The whole update a move causes, done now rather than at the next display frame, and timed.
                    let (_, layout) = FrameMeter.time {
                        canvas.dragOffset = CGPoint(x: 120 * sin(t * 12), y: 60 * sin(t * 7))
                        window?.contentView?.layoutSubtreeIfNeeded()
                    }
                    let (_, display) = FrameMeter.time {
                        window?.displayIfNeeded()
                        CATransaction.flush()
                    }
                    layouts.append(layout)
                    displays.append(display)
                    try? await Task.sleep(for: .seconds(1.0 / 240))
                }
                canvas.dragOffset = nil
                // The view update a move causes, SwiftUI's and ours; not the display flush after it, which once frames come
                // fast enough mostly waits for the screen.
                layouts.sort()
                print("shake:", FrameMeter.shared.report(over: numbers[0]),
                      String(format: "| update %.1f ms median, %.1f ms worst", layouts[layouts.count / 2], layouts.last ?? 0),
                      String(format: "| display %.1f ms median", displays.sorted()[displays.count / 2]))
            case "select-ties":
                canvas.selection = Set(document.wrappedValue.zipTies.map { .zipTie($0.id) })
            case "ties":
                for tie in document.wrappedValue.zipTies {
                    print(String(format: "tie at %.0f, %.0f held %@ selected %@", tie.position.x, tie.position.y,
                                 tie.heldDirection.map { "\($0)" } ?? "no", canvas.selection.contains(.zipTie(tie.id)) ? "yes" : "no"))
                }
            case "scroll-at" where numbers.count == 4:
                // A trackpad scroll by (dx, dy) points with the pointer at a window point (top-left origin).
                guard let window = NSApp.windows.first(where: \.isVisible), let height = window.contentView?.bounds.height,
                      let screenHeight = NSScreen.screens.first?.frame.height,
                      let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                          wheel1: Int32(numbers[3]), wheel2: Int32(numbers[2]), wheel3: 0) else { break }
                let inWindow = CGPoint(x: numbers[0], y: height - numbers[1])
                let onScreen = window.convertPoint(toScreen: inWindow)
                event.location = CGPoint(x: onScreen.x, y: screenHeight - onScreen.y)
                if let scroll = NSEvent(cgEvent: event) { NSApp.postEvent(scroll, atStart: false) }
            case "wheel":
                if let wheel = canvas.wheel {
                    print("wheel at \(Int(wheel.center.x)), \(Int(wheel.center.y)) on \(wheel.target)")
                } else {
                    print("wheel closed")
                }
            case "wheel-pick" where words.count == 2:
                // Synthesized pointer moves don't reach SwiftUI's hover, so pick by name: east, northWest, …
                let direction = CommandWheel.Direction.allCases.first { "\($0)" == words[1] }
                NotificationCenter.default.post(name: .pickFromWheel, object: canvas, userInfo: ["direction": direction as Any])
            case "wheel-color" where words.count == 2:
                // One of the wheel's colors, by name.
                NotificationCenter.default.post(name: .pickFromWheel, object: canvas, userInfo: ["color": TableColor(rawValue: words[1]) as Any])
            case "generate" where numbers.count >= 2:
                document.wrappedValue = .synthetic(tables: Int(numbers[0]), foreignKeys: Int(numbers[1]),
                                                   groups: numbers.count > 2 ? Int(numbers[2]) : 0)
                canvas.zoomToFit(document.wrappedValue.bounds)
            case "quit":
                exit(0)
            case "library":
                let library = Library.shared
                print("library open: \(library.open?.name ?? "none"), recents: \(library.recents.map(Library.name(of:)).prefix(3))")
            case "mcp" where words.count > 2:
                // An assistant's tool call, as the MCP server would make it: "mcp create_tables {json}".
                let json = words.dropFirst(2).joined(separator: " ")
                let arguments = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
                do { print("mcp:", try await MCP.call(words[1], arguments, host: MCPServer.shared)) } catch { print("mcp failed:", error.localizedDescription) }
            case "add-port" where words.count >= 4:
                // The + on a group's edge clicked, and the new port maybe plugged in: "add-port hierarchy left 0.2 user_account.user_id".
                let model = document.wrappedValue
                guard let group = model.groups.first(where: { $0.name == words[1] }), let side = Side4(rawValue: words[2]),
                      let port = document.wrappedValue.addPort(to: group.id, at: (side, numbers.first ?? 0.5)) else { print("add-port: no such group"); break }
                if words.count == 5 {
                    let parts = words[4].split(separator: ".").map(String.init)
                    if let column = model.tables.first(where: { $0.name == parts.first })?.columns.first(where: { $0.name == parts.last }) {
                        document.wrappedValue.plug(port, into: column.id)
                    }
                }
                print("add-port:", document.wrappedValue.portPlacements().values.map { "\($0.label) (\($0.wires.count)) at \(Int($0.point.x)), \(Int($0.point.y))" })
            case "hint" where words.count == 4:
                // The + shown by a group's edge, as if hovered: "hint hierarchy bottom 0.5".
                let model = document.wrappedValue
                if let group = model.groups.first(where: { $0.name == words[1] }), let side = Side4(rawValue: words[2]),
                   let point = model.edgePoint(of: group.id, at: (side, numbers[0])) {
                    canvas.portHint = (group.id, (side, numbers[0]), point)
                }
            case "plug-first" where words.count == 2:
                // The first port's outside plugged into a column, as a drop would: "plug-first entity.entity_id".
                let parts = words[1].split(separator: ".").map(String.init)
                guard let port = document.wrappedValue.groups.lazy.flatMap(\.ports).first?.id,
                      let column = document.wrappedValue.tables.first(where: { $0.name == parts.first })?.columns.first(where: { $0.name == parts.last })
                else { break }
                document.wrappedValue.plug(port, into: column.id)
            case "pull-start" where numbers.count == 2:
                // A cable grabbed: "pull-start 0 0.5" grabs wire 0 halfway along.
                NotificationCenter.default.post(name: .pull, object: canvas, userInfo: ["step": "start", "wire": Int(numbers[0]), "t": Double(numbers[1])])
            case "pull-move" where numbers.count == 2:
                NotificationCenter.default.post(name: .pull, object: canvas, userInfo: ["step": "move", "offset": CGPoint(x: numbers[0], y: numbers[1])])
            case "pull-to-tie":
                NotificationCenter.default.post(name: .pull, object: canvas, userInfo: ["step": "tie"])
            case "pull-end":
                NotificationCenter.default.post(name: .pull, object: canvas, userInfo: ["step": "end"])
            case "merge-preview":
                // The newest zip tie dragged onto the one before it, and held there.
                let ties = document.wrappedValue.zipTies
                guard ties.count >= 2 else { break }
                let (dragged, target) = (ties[ties.count - 1], ties[ties.count - 2])
                canvas.selection = [.zipTie(dragged.id)]
                canvas.dragOffset = target.position - dragged.position
                canvas.tieMerge = (dragged.id, target.id, target.direction)
                canvas.hoveredTie = target.id
            case "merge-drop":
                guard let merge = canvas.tieMerge else { break }
                document.wrappedValue.merge(merge.tie, by: canvas.dragOffset ?? .zero, into: merge.target, along: merge.direction)
                (canvas.tieMerge, canvas.dragOffset, canvas.hoveredTie) = (nil, nil, nil)
                print("merge-drop:", document.wrappedValue.zipTies.map(\.relationships.count))
            case "tie-wires" where numbers.count >= 2 || words.contains("bus"):
                // Wires tied together where they're nearest each other's middle: "tie-wires 0 1"; "bus" is the first
                // port's bus.
                var model = document.wrappedValue
                let routing = Routing(model: model)
                let bus = words.contains("bus") ? model.groups.lazy.flatMap(\.ports).first(where: { $0.column != nil })?.id : nil
                let ids = numbers.map { model.relationships[Int($0)].id } + [bus].compactMap { $0 }
                let middles = ids.compactMap { routing.routes[$0].map { $0.points[$0.points.count / 2] } }
                let center = middles.reduce(.zero, +) / CGFloat(middles.count)
                let tie = ZipTie(position: center, direction: CGPoint(x: 1, y: 0), relationships: ids)
                model.zipTies.append(tie)
                for id in ids { model.setZipTies(onCable: id, (model.zipTies(onCable: id) ?? []) + [tie.id]) }
                document.wrappedValue = model
                print("tie-wires: tied \(ids.count) at \(Int(center.x)), \(Int(center.y))")
            case "press" where numbers.count == 2:
                // A click at a canvas point, through the canvas's own press handling.
                NotificationCenter.default.post(name: .pressAt, object: canvas, userInfo: ["point": CGPoint(x: numbers[0], y: numbers[1])])
            case "hover" where numbers.count == 2:
                // The pointer over a canvas point, for what hovering shows there.
                NotificationCenter.default.post(name: .hover, object: canvas, userInfo: ["point": CGPoint(x: numbers[0], y: numbers[1])])
            case "column-drag" where words.count == 3 && numbers.count == 1:
                // A column mid-drag, to go before the one at an index: "column-drag orders.user_id 3".
                let parts = words[1].split(separator: ".").map(String.init)
                if let table = document.wrappedValue.tables.first(where: { $0.name == parts.first }),
                   let column = table.columns.first(where: { $0.name == parts.last }) {
                    canvas.columnDrag = (table.id, column.id, Int(numbers[0]))
                }
            case "design" where table != nil:
                canvas.designing = document.wrappedValue.tables[table!].id
            case "sample" where table != nil && words.count >= 5:
                // A sample value: "sample orders 0 status shipped".
                let row = Int(words[2]) ?? 0, value = words.dropFirst(4).joined(separator: " ")
                if let column = document.wrappedValue.tables[table!].columns.first(where: { $0.name == words[3] }) {
                    document.wrappedValue.tables[table!].setSample(row, column.id, to: value)
                }
            case "notes" where table != nil && words.count >= 3:
                document.wrappedValue.tables[table!].notes = words.dropFirst(2).joined(separator: " ")
            case "header-hover" where table != nil:
                canvas.hoveredHeader = document.wrappedValue.tables[table!].id
            case "capture" where words.count == 2:
                // The window now, to a file: for frames of an animation, between short waits.
                capture(to: words[1])
            case "title-click":
                NotificationCenter.default.post(name: .renameTitle, object: nil)
            case "rename-model" where words.count == 2:
                // As editing the window's title would: "rename-model Shop".
                if let open = Library.shared.open { Library.shared.rename(open.url, to: words[1]) }
                print("open:", Library.shared.open.map { "\($0.name), \($0.model.tables.count) tables" } ?? "nothing")
            case "click-plus" where words.count == 4:
                // The + on a group's edge clicked: "click-plus hierarchy left 0.45".
                guard let group = document.wrappedValue.groups.first(where: { $0.name == words[1] }), let side = Side4(rawValue: words[2]),
                      let port = document.wrappedValue.addPort(to: group.id, at: (side, numbers[0])) else { break }
                canvas.portHint = nil
                canvas.appearingPort = (port, ProcessInfo.processInfo.systemUptime)
            case "bend-bus":
                // A bend point halfway along the first plugged port's bus.
                let model = document.wrappedValue
                guard let port = model.groups.lazy.flatMap(\.ports).first(where: { $0.column != nil }),
                      let route = Routing(model: model).routes[port.id] else { break }
                let middle = route.points[route.points.count / 2], next = route.points[route.points.count / 2 + 1]
                print("bend-bus:", document.wrappedValue.addBendPoint(on: port.id, at: middle + CGPoint(x: 0, y: 160),
                                                                     direction: (next - middle).normalized ?? CGPoint(x: 1, y: 0), segment: 0) != nil)
            case "port" where words.count >= 2:
                // The first port put on a side ("port bottom 0.3"), or back facing its column ("port auto").
                guard let id = document.wrappedValue.groups.lazy.flatMap(\.ports).first?.id else { break }
                document.wrappedValue.movePort(id, to: Side4(rawValue: words[1]).map { ($0, numbers.first ?? 0.5) })
            case "bundle":
                // Every group's shared wires bundled into ports.
                var model = document.wrappedValue
                let added = model.groups.map(\.id).reduce(0) { $0 + model.bundleSharedWires(in: $1) }
                document.wrappedValue = model
                print("bundled: \(added) ports", model.portPlacements().values.map { "\($0.label) (\($0.wires.count)) at \(Int($0.point.x)), \(Int($0.point.y))" }.sorted())
            case "end-review":
                Library.shared.open?.endComparison()
            case "history":
                // Version history open, with the version at an index selected ("history" alone: "Now").
                NotificationCenter.default.post(name: .pickVersion, object: numbers.first.map { Int($0) })
                try? await Task.sleep(for: .seconds(0.5))
                NotificationCenter.default.post(name: .pickVersion, object: numbers.first.map { Int($0) })
            case "settings":
                // Settings, alone on screen, for a snapshot to show.
                NotificationCenter.default.post(name: .openSettings, object: canvas)
                try? await Task.sleep(for: .seconds(0.8))
                for window in NSApp.windows where window.isVisible && window.identifier?.rawValue.contains("Settings") != true {
                    window.orderOut(nil)
                }
                print("windows:", NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "?") \($0.title)" })
            case "view":
                print(String(format: "view offset %.0f, %.0f zoom %.2f, tying %@", canvas.offset.x, canvas.offset.y, canvas.zoom,
                             canvas.isTying ? "on" : "off"),
                      "designer:", canvas.designerFrame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "closed",
                      "focus:", canvas.focus.map { focus in document.wrappedValue.tables.filter { focus.contains($0.id) }.map(\.name) } ?? ["off"])
            case "hold-drag" where table != nil && numbers.count == 2:
                // A table dragged this far (view points) and held there, through the real drag, snapping and all; and let go, with `drop`.
                NotificationCenter.default.post(name: .holdDrag, object: canvas, userInfo: [
                    "table": document.wrappedValue.tables[table!].id, "translation": CGSize(width: numbers[0], height: numbers[1]),
                    "drop": words.last == "drop",
                ])
            case "group" where words.count > 1:
                // Groups the named tables, as ⌘G would with them selected.
                let names = Set(words.dropFirst())
                canvas.selection = Set(document.wrappedValue.tables.filter { names.contains($0.name) }.map { .table($0.id) })
                canvas.groupSelection(in: &document.wrappedValue)
            case "select-group" where words.count == 2:
                if let group = document.wrappedValue.groups.first(where: { $0.name == words[1] }) {
                    canvas.selectGroup(group.id, in: document.wrappedValue, extending: false)
                }
            case "groups":
                let model = document.wrappedValue
                for group in model.groups {
                    print("group \(group.name) \(group.color): \(model.members(of: group.id).map(\.name).sorted().joined(separator: ", "))")
                }
            case "arrange" where words.count == 2:
                if let layout = DataModel.Layout(rawValue: words[1]) {
                    let selected = canvas.selectedTablesAndMembers(in: document.wrappedValue)
                    document.wrappedValue.arrange(layout, only: selected.isEmpty ? nil : selected)
                    canvas.zoomToFit(document.wrappedValue.bounds)
                }
            case "clipboard" where words.count == 2:
                // What Copy, Cut and Paste do on the canvas, without needing the app in front for the menu.
                switch words[1] {
                case "copy": canvas.copySelection(from: document.wrappedValue)
                case "cut": canvas.cutSelection(from: &document.wrappedValue)
                case "paste": canvas.paste(into: &document.wrappedValue)
                default: break
                }
            case "share":
                // Hosts a session on the open model, through JOINERY_RELAY if given, and prints its links.
                guard let open = Library.shared.open else { break }
                let host = SessionHost(model: open, relay: environment["JOINERY_RELAY"].flatMap(URL.init(string:)) ?? SessionHost.relay)
                open.session = host
                for _ in 0..<50 where host.links == nil { try? await Task.sleep(for: .milliseconds(100)) }
                print("sharing:", host.status, host.links?.edit ?? "", host.links?.view ?? "")
            case "join" where words.count == 2:
                print("join:", Library.shared.join(words[1]) ? "connecting" : "not a link")
            case "presence" where numbers.count == 2 || numbers.count == 6:
                // The pointer at a canvas point, and if four more are given, a selection rectangle from it.
                let marquee = numbers.count == 6 ? CGRect(x: numbers[2], y: numbers[3], width: numbers[4], height: numbers[5]) : nil
                Library.shared.open?.session?.share(Relay.Presence(cursor: CGPoint(x: numbers[0], y: numbers[1]), selection: canvas.selectedTables,
                                                                   drag: canvas.dragOffset, marquee: marquee))
            case "peers":
                let session = Library.shared.open?.session
                print("peers:", session?.status ?? "no session", (session?.peers.values.map { "\($0.name) \($0.cursor ?? [])" } ?? []).sorted())
            case "share-panel":
                NotificationCenter.default.post(name: .showSharing, object: nil)
            case "join-panel":
                // Back to the library, with the Join popover open.
                Library.shared.selection = nil
                try? await Task.sleep(for: .seconds(0.5))
                NotificationCenter.default.post(name: .showJoin, object: nil)
            case "undo", "redo":
                // The window's own undo, as ⌘Z and ⇧⌘Z would.
                let manager = Library.shared.open?.undoManager
                words[0] == "undo" ? manager?.undo() : manager?.redo()
                print("\(words[0]): can undo \(manager?.canUndo ?? false), can redo \(manager?.canRedo ?? false)")
            case "menu" where words.count > 1:
                // Chooses a menu item by its title, as a click would.
                let title = words.dropFirst().joined(separator: " ")
                func choose(in menu: NSMenu) -> Bool {
                    for (index, item) in menu.items.enumerated() {
                        if item.title == title { menu.performActionForItem(at: index); return true }
                        if let submenu = item.submenu, choose(in: submenu) { return true }
                    }
                    return false
                }
                print("menu \(title): active \(NSApp.isActive), key window \(NSApp.keyWindow != nil), responder \(NSApp.keyWindow?.firstResponder.map { "\(type(of: $0))" } ?? "none")")
                if let menu = NSApp.mainMenu, !choose(in: menu) { print("menu: no item called \(title)") }
            case "scramble":
                // Each table swapped with one across the grid, so wires criss-cross.
                let positions = document.wrappedValue.tables.map(\.position)
                for index in document.wrappedValue.tables.indices {
                    document.wrappedValue.tables[index].position = positions[(index * 7) % positions.count]
                }
            case "untangle":
                canvas.selectAll(in: document.wrappedValue)
                canvas.untangleSelection(of: document)
                let started = ProcessInfo.processInfo.systemUptime
                while canvas.isUntangling {
                    if let state = canvas.untangling { print(String(format: "untangling %.0f%%: %d → %d", state.progress * 100, state.from, state.best)) }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                let frames = document.wrappedValue.tables.map(Metrics.frame)
                let overlapping = frames.indices.flatMap { i in frames.indices.filter { $0 > i && frames[i].intersects(frames[$0]) } }.count
                print(String(format: "untangled in %.1f s, %d overlapping pairs", ProcessInfo.processInfo.systemUptime - started, overlapping))
            case "routings":
                print("routings built: \(Routing.built)")
            case "clock":
                print(String(format: "clock %.3f s", ProcessInfo.processInfo.systemUptime))
            case "counts":
                let model = document.wrappedValue
                print("tables \(model.tables.count), foreign keys \(model.relationships.count), ties \(model.zipTies.count),",
                      "selected wires \(canvas.selection.filter { if case .relationship = $0 { true } else { false } }.count)")
            case "drop-preview" where words.count == 4 && numbers.count == 2:
                // Shows a wire dragged from table.column to a point, as if mid-drag.
                let parts = words[1].split(separator: ".").map(String.init)
                let model = document.wrappedValue
                if let table = model.tables.first(where: { $0.name == parts.first }),
                   let row = table.columns.firstIndex(where: { $0.name == parts.last }) {
                    let end = CGPoint(x: numbers[0], y: numbers[1])
                    canvas.connection = .init(from: table.columns[row].id,
                                              start: Metrics.socket(row: row, side: .trailing, in: Metrics.frame(of: table)),
                                              end: end, target: model.dropTarget(at: end))
                }
            case "markdown":
                // What Copy as Markdown would copy for the selection.
                canvas.copyMarkdown(from: document.wrappedValue, title: "Storefront")
                print(NSPasteboard.general.string(forType: .string) ?? "")
            case "drop-finish":
                // Lets go of the wire shown by drop-preview, as a real drop would.
                NotificationCenter.default.post(name: .pull, object: canvas, userInfo: ["step": "drop-wire"])
            case "palette":
                print("palette open:", canvas.showsPalette, "highlight:", canvas.paletteHighlight)
            case "selection":
                print("selected", canvas.selection.compactMap { item in
                    if case .table(let id) = item { document.wrappedValue.table(id)?.name } else { nil }
                })
            case "dump":
                for table in document.wrappedValue.tables {
                    print(table.name, table.columns.map { "\($0.name):\($0.typeLabel)" }.joined(separator: " "))
                }
            case "space":
                canvas.isSpaceHeld.toggle()
            case "theme":
                let name = words.dropFirst().joined(separator: " ")
                if let palette = Palette.light.first(where: { $0.name == name }) { Themes.shared.light = palette }
                if let palette = Palette.dark.first(where: { $0.name == name }) { Themes.shared.dark = palette }
            case "zoom" where numbers.count == 1:
                canvas.zoom(by: numbers[0])
            case "focus" where table != nil && numbers.count == 1:
                let frame = Metrics.frame(of: document.wrappedValue.tables[table!])
                canvas.zoom(by: numbers[0] / canvas.zoom)
                canvas.pan(by: CGPoint(x: canvas.viewSize.width / 2, y: canvas.viewSize.height / 2)
                    - canvas.viewPoint(CGPoint(x: frame.midX, y: frame.midY)))
            case "look" where numbers.count == 3:
                canvas.zoom(by: numbers[2] / canvas.zoom)
                canvas.pan(by: CGPoint(x: canvas.viewSize.width / 2, y: canvas.viewSize.height / 2)
                    - canvas.viewPoint(CGPoint(x: numbers[0], y: numbers[1])))
            case "tie" where numbers.count == 4:
                canvas.stroke = .init(start: CGPoint(x: numbers[0], y: numbers[1]), end: CGPoint(x: numbers[2], y: numbers[3]))
                try? await Task.sleep(for: .seconds(0.5))
                canvas.isStrokeFinished = true
            case "rightdrag" where numbers.count == 4, "rightclick" where numbers.count == 2:
                // Real right-button events, from one canvas point to another (or a click at one).
                let start = CGPoint(x: numbers[0], y: numbers[1])
                let end = numbers.count == 4 ? CGPoint(x: numbers[2], y: numbers[3]) : start
                guard let window = NSApp.windows.first(where: \.isVisible), let height = window.contentView?.bounds.height else { break }
                // Where on screen they are now: a pan along the way mustn't carry the pointer with it.
                let startView = canvas.viewPoint(start), endView = canvas.viewPoint(end)
                func post(_ type: NSEvent.EventType, _ view: CGPoint) {
                    if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: view.x, y: height - view.y), modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                post(.rightMouseDown, startView)
                for step in 1...20 where start != end {
                    try? await Task.sleep(for: .seconds(0.02))
                    post(.rightMouseDragged, startView + (endView - startView) * (CGFloat(step) / 20))
                }
                try? await Task.sleep(for: .seconds(0.05))
                post(.rightMouseUp, endView)
            case "window-click" where numbers.count == 2:
                // A real left click at a point in the window, from its top left: on a control, say.
                guard let window = NSApp.windows.first(where: \.isVisible), let height = window.contentView?.bounds.height else { break }
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: numbers[0], y: height - numbers[1]), modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    try? await Task.sleep(for: .seconds(0.05))
                }
            case "feedback-on":
                canvas.isFeedbackMode = true
            case "handle" where numbers.count == 3:
                // Moves the nth movable point of the correction by dx, dy.
                if let edit = canvas.feedback {
                    let movable = edit.points.indices.filter { !edit.isAnchor[$0] }
                    if movable.indices.contains(Int(numbers[0])) {
                        canvas.feedback?.points[movable[Int(numbers[0])]] += CGPoint(x: numbers[1], y: numbers[2])
                    }
                }
            case "feedback-note" where words.count > 1:
                canvas.feedback?.note = String(step.drop(while: { $0 == " " }).dropFirst(14))
            case "feedback-save":
                NotificationCenter.default.post(name: .saveFeedback, object: canvas)
            case "wait" where numbers.count == 1:
                try? await Task.sleep(for: .seconds(numbers[0]))
            default:
                print("JOINERY_SCRIPT: can't run \"\(step)\"")
            }
        }
    }
}

extension DebugHooks {
    /// Presses a key through the window like a keyboard would; text fields and key monitors see it as real.
    @MainActor
    private static func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(for: .seconds(0.08))
    }
}

extension Notification.Name {
    /// Saves the routing correction being drawn.
    static let saveFeedback = Notification.Name("JoinerySaveFeedback")
    /// Clicks the empty canvas or a wire at `userInfo["point"]`, in canvas points.
    static let click = Notification.Name("JoineryClick")
    static let pickFromWheel = Notification.Name("JoineryPickFromWheel")
    static let openSettings = Notification.Name("JoineryOpenSettings")
    static let hover = Notification.Name("JoineryHover")
    static let pressAt = Notification.Name("JoineryPressAt")
    static let pull = Notification.Name("JoineryPull")
    static let holdDrag = Notification.Name("JoineryHoldDrag")
}
#endif

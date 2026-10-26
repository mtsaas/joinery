#if DEBUG
import SwiftUI

/// Lets the app be checked from the command line, without clicking. Set in the environment:
/// - `JOINERY_LIBRARY=<dir>`: use that folder as the library (see `Library`), so tests never touch the real one.
/// - `JOINERY_OPEN=<name>`: select the model with that name. A `.joinery` path passed as an argument is imported and
///   selected too.
/// - `JOINERY_APPEARANCE=light|dark`: whatever the system's set to. `JOINERY_WINDOW_SIZE=2560x1080`: the window's size,
///   in points, on the widest screen.
/// - `JOINERY_SNAPSHOT=out.png`: saves the front window to `out.png` and quits. `JOINERY_SNAPSHOT_FRAMES=n` saves n
///   frames 50 ms apart (out-0.png, out-1.png, …) to check an animation; `JOINERY_SNAPSHOT_DELAY` sets the wait.
/// - `JOINERY_SCRIPT`: semicolon-separated steps run against the first document after a second:
///   `move <table> <dx> <dy>`, `tie <x1> <y1> <x2> <y2>` (canvas points; shows the line for half a second, then
///   ties), `select <table>`, `edit <table>`, `space` (toggles held), `click <x> <y>` (on canvas or a wire), `nudge <dx> <dy>` (moves the selection), `place <x> <y>` (puts the selected ties there),
///   `type <text>` and `key tab|return|escape|up|down|cmd+<letter>|shift+cmd+<letter>` (real key events), `selection`, `counts`, `rightdrag <x1> <y1> <x2> <y2>`, `rightclick <x> <y>`, `drop-preview <table.column> <x> <y>`, `open-palette`, `feedback-on`, `handle <n> <dx> <dy>`, `feedback-note <text>`, `feedback-save`, `palette` (prints its state), `dump` (prints the tables), `zoom <factor>`, `look <x> <y> <zoom>` (centers on that canvas point), `focus <table> <zoom>` (centers on that table), `shake <table> <seconds>` (drags it about and prints frame stats), `generate <tables> <foreign keys>` (replaces the model with a made-up one; see `scripts/scale-test.sh`), `quit`, `select-ties`, `group <table> <table>…` (groups them, as ⌘G), `groups` (prints them), `hold-drag <table> <dx> <dy>` (drags it that far in view points and holds), `wheel` (prints it), `wheel-pick <direction>` (east, northWest, …), `ties` (prints them),
///   `wait <seconds>`.
@MainActor
enum DebugHooks {
    private static let environment = ProcessInfo.processInfo.environment

    static func launched() {
        if let name = environment["JOINERY_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
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
        let windows = NSApp.windows.filter(\.isVisible).sorted { $0.orderedIndex > $1.orderedIndex }
        guard let main = windows.max(by: { $0.frame.width < $1.frame.width }), let base = image(main),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return print("snapshot failed") }
        let scale = CGFloat(base.width) / main.frame.width
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for window in windows where window !== main && window.frame.intersects(main.frame) {
            guard let over = image(window) else { continue }
            context.draw(over, in: CGRect(x: (window.frame.minX - main.frame.minX) * scale, y: (window.frame.minY - main.frame.minY) * scale,
                                          width: window.frame.width * scale, height: window.frame.height * scale))
        }
        guard let composite = context.makeImage() else { return print("snapshot failed") }
        try? NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    static func script(_ document: Binding<DataModel>, canvas: CanvasController) async {
        guard let script = ProcessInfo.processInfo.environment["JOINERY_SCRIPT"] else { return }
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
                do { print("mcp:", try ModelTools.call(words[1], arguments, on: &document.wrappedValue)) } catch { print("mcp failed:", error.localizedDescription) }
            case "add-port" where words.count == 3:
                // A socket dropped on a group: "add-port hierarchy user_account.user_id".
                let model = document.wrappedValue
                let parts = words[2].split(separator: ".").map(String.init)
                guard let group = model.groups.first(where: { $0.name == words[1] }),
                      let column = model.tables.first(where: { $0.name == parts.first })?.columns.first(where: { $0.name == parts.last })
                else { print("add-port: no such group or column"); break }
                print("add-port:", document.wrappedValue.connect(dragging: column.id, onto: .group(group.id)).map { "\($0)" } ?? "no wire",
                      document.wrappedValue.portPlacements().values.map { "\($0.label) (\($0.wires.count))" })
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
                      "focus:", canvas.focus.map { focus in document.wrappedValue.tables.filter { focus.contains($0.id) }.map(\.name) } ?? ["off"])
            case "hold-drag" where table != nil && numbers.count == 2:
                // A table dragged this far (view points) and held there, through the real drag, snapping and all.
                NotificationCenter.default.post(name: .holdDrag, object: canvas, userInfo: [
                    "table": document.wrappedValue.tables[table!].id, "translation": CGSize(width: numbers[0], height: numbers[1]),
                ])
            case "group" where words.count > 1:
                // Groups the named tables, as ⌘G would with them selected.
                let names = Set(words.dropFirst())
                canvas.selection = Set(document.wrappedValue.tables.filter { names.contains($0.name) }.map { .table($0.id) })
                canvas.groupSelection(in: &document.wrappedValue)
            case "groups":
                let model = document.wrappedValue
                for group in model.groups {
                    print("group \(group.name): \(model.members(of: group.id).map(\.name).sorted().joined(separator: ", "))")
                }
            case "arrange" where words.count == 2:
                if let layout = DataModel.Layout(rawValue: words[1]) {
                    document.wrappedValue.arrange(layout)
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
    static let holdDrag = Notification.Name("JoineryHoldDrag")
}
#endif

#if DEBUG
import SwiftUI

/// Lets the app be checked from the command line, without clicking. Set in the environment:
/// - `JOINERY_SNAPSHOT=out.png`: saves the front window to `out.png` and quits. `JOINERY_SNAPSHOT_FRAMES=n` saves n
///   frames 50 ms apart (out-0.png, out-1.png, …) to check an animation; `JOINERY_SNAPSHOT_DELAY` sets the wait.
/// - `JOINERY_SCRIPT`: semicolon-separated steps run against the first document after a second:
///   `move <table> <dx> <dy>`, `tie <x1> <y1> <x2> <y2>` (canvas points; shows the line for half a second, then
///   ties), `select <table>`, `edit <table>`, `space` (toggles held), `click <x> <y>` (on canvas or a wire), `nudge <dx> <dy>` (moves the selection),
///   `type <text>` and `key tab|return|escape|up|down|cmd+<letter>` (real key events), `selection`, `counts`, `drop-preview <table.column> <x> <y>`, `open-palette`, `palette` (prints its state), `dump` (prints the tables), `zoom <factor>`, `look <x> <y> <zoom>` (centers on that canvas point),
///   `wait <seconds>`.
@MainActor
final class DebugHooks: NSObject, NSApplicationDelegate {
    private let environment = ProcessInfo.processInfo.environment

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    /// Recording permission, so it's looked up at run time.
    private static func capture(to path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let window = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width }),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?
                .takeRetainedValue()
        else { return print("snapshot failed") }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    static func script(_ document: Binding<Schema>, canvas: CanvasController) async {
        guard let script = ProcessInfo.processInfo.environment["JOINERY_SCRIPT"] else { return }
        try? await Task.sleep(for: .seconds(1))
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
                canvas.edit(.tableName(document.wrappedValue.tables[table!].id))
            case "click" where numbers.count == 2:
                NotificationCenter.default.post(name: .click, object: canvas, userInfo: ["point": CGPoint(x: numbers[0], y: numbers[1])])
            case "nudge" where numbers.count == 2:
                document.wrappedValue.move(tables: canvas.selectedTables, ties: canvas.selectedTies, by: CGPoint(x: numbers[0], y: numbers[1]))
            case "type" where words.count > 1:
                for character in step.drop(while: { $0 == " " }).dropFirst(5) { await press(String(character)) }
            case "key" where words.count == 2:
                // A named key, or ⌘ plus a letter as "cmd+k".
                let codes: [String: (UInt16, String)] = ["tab": (48, "\t"), "return": (36, "\r"), "escape": (53, "\u{1b}"),
                                                          "delete": (51, "\u{7f}"),
                                                          "down": (125, "\u{F701}"), "up": (126, "\u{F700}")]
                if let (code, characters) = codes[words[1]] {
                    await press(characters, keyCode: code)
                } else if words[1].hasPrefix("cmd+"), let letter = words[1].last {
                    await press(String(letter), keyCode: ["k": 40, "a": 0][String(letter)] ?? 0, modifiers: .command)
                }
            case "open-palette":
                canvas.togglePalette()
            case "counts":
                let schema = document.wrappedValue
                print("tables \(schema.tables.count), foreign keys \(schema.relationships.count), ties \(schema.zipTies.count),",
                      "selected wires \(canvas.selection.filter { if case .relationship = $0 { true } else { false } }.count)")
            case "drop-preview" where words.count == 4 && numbers.count == 2:
                // Shows a wire dragged from table.column to a point, as if mid-drag.
                let parts = words[1].split(separator: ".").map(String.init)
                let schema = document.wrappedValue
                if let table = schema.tables.first(where: { $0.name == parts.first }),
                   let row = table.columns.firstIndex(where: { $0.name == parts.last }) {
                    let end = CGPoint(x: numbers[0], y: numbers[1])
                    canvas.connection = .init(from: table.columns[row].id,
                                              start: Metrics.socket(row: row, side: .trailing, in: Metrics.frame(of: table)),
                                              end: end, target: schema.dropTarget(at: end))
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
            case "look" where numbers.count == 3:
                canvas.zoom(by: numbers[2] / canvas.zoom)
                canvas.pan(by: CGPoint(x: canvas.viewSize.width / 2, y: canvas.viewSize.height / 2)
                    - canvas.viewPoint(CGPoint(x: numbers[0], y: numbers[1])))
            case "tie" where numbers.count == 4:
                canvas.stroke = .init(start: CGPoint(x: numbers[0], y: numbers[1]), end: CGPoint(x: numbers[2], y: numbers[3]))
                try? await Task.sleep(for: .seconds(0.5))
                NotificationCenter.default.post(name: .finishStroke, object: canvas)
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
    /// Ends the canvas's tie line as if the drag had finished.
    static let finishStroke = Notification.Name("JoineryFinishStroke")
    /// Clicks the empty canvas or a wire at `userInfo["point"]`, in canvas points.
    static let click = Notification.Name("JoineryClick")
}
#endif

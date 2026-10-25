#if DEBUG
import SwiftUI

/// Lets the app be checked from the command line, without clicking. Set in the environment:
/// - `JOINERY_SNAPSHOT=out.png`: saves the front window to `out.png` and quits. `JOINERY_SNAPSHOT_FRAMES=n` saves n
///   frames 50 ms apart (out-0.png, out-1.png, …) to check an animation; `JOINERY_SNAPSHOT_DELAY` sets the wait.
/// - `JOINERY_SCRIPT`: semicolon-separated steps run against the first document after a second:
///   `move <table> <dx> <dy>`, `tie <x1> <y1> <x2> <y2>` (canvas points; shows the line for half a second, then
///   ties), `select <table>`, `inspect`, `zoom <factor>`, `look <x> <y> <zoom>` (centers on that canvas point),
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
        for step in script.split(separator: ";") {
            let words = step.split(separator: " ").map(String.init)
            let numbers = words.dropFirst().compactMap(Double.init).map { CGFloat($0) }
            let table = document.wrappedValue.tables.firstIndex { $0.name == words.dropFirst().first }
            switch words.first {
            case "move" where table != nil && numbers.count == 2:
                document.wrappedValue.tables[table!].position += CGPoint(x: numbers[0], y: numbers[1])
            case "select" where table != nil:
                canvas.selection = .table(document.wrappedValue.tables[table!].id)
            case "inspect":
                canvas.showsInspector = true
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

extension Notification.Name {
    /// Ends the canvas's tie line as if the drag had finished.
    static let finishStroke = Notification.Name("JoineryFinishStroke")
}
#endif

import AppKit
import SwiftUI

/// Input SwiftUI has no gesture or key handler for, watched in the window over the canvas's frame:
/// - Two-finger scrolling or the mouse wheel pans; pinching or ⌘-scrolling zooms, around the pointer.
/// - Holding Space turns dragging anywhere into panning.
/// - In the command palette, the arrow keys move through the matches and Escape closes it.
/// - While a table's cells are being edited, Tab and Shift-Tab step through them in our order (adding a column past
///   the last), and Escape stops editing; the text field would otherwise move focus anywhere in the window.
struct CanvasEventMonitor: NSViewRepresentable {
    let canvas: CanvasController

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.canvas = canvas
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.canvas = canvas
    }

    final class EventView: NSView {
        var canvas: CanvasController?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        /// Clicks go through to the canvas; this only watches events through its monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown, .keyUp]) { [weak self] event in
                let isHandled = MainActor.assumeIsolated { self?.handle(event) == true }
                return isHandled ? nil : event
            }
        }

        private enum Key {
            static let tab: UInt16 = 48, space: UInt16 = 49, escape: UInt16 = 53, down: UInt16 = 125, up: UInt16 = 126
        }

        /// - Returns: Whether the event was used.
        private func handle(_ event: NSEvent) -> Bool {
            guard let canvas, let window, event.window === window else { return false }
            let isTyping = window.firstResponder is NSTextView
            switch event.type {
            case .keyDown where isTyping && canvas.showsPalette:
                switch event.keyCode {
                case Key.down: canvas.paletteHighlight += 1
                case Key.up: canvas.paletteHighlight = max(canvas.paletteHighlight - 1, 0)
                case Key.escape: canvas.showsPalette = false
                default: return false
                }
            case .keyDown where isTyping:
                guard canvas.editingTable != nil else { return false }
                switch event.keyCode {
                case Key.tab: canvas.fieldKey = event.modifierFlags.contains(.shift) ? .previous : .next
                case Key.escape: canvas.fieldKey = .done
                default: return false
                }
            case .keyDown, .keyUp:
                guard !isTyping, event.keyCode == Key.space,
                      event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else { return false }
                canvas.isSpaceHeld = event.type == .keyDown
            case .magnify, .scrollWheel:
                let location = convert(event.locationInWindow, from: nil)
                guard bounds.contains(location) else { return false }
                if event.type == .magnify {
                    canvas.zoom(by: 1 + event.magnification, around: location)
                } else if event.modifierFlags.contains(.command) {
                    canvas.zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)), around: location)
                } else {
                    // A mouse wheel reports lines, not points.
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    canvas.pan(by: CGPoint(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale))
                }
            default:
                return false
            }
            return true
        }
    }
}

import AppKit
import SwiftUI

/// Pans the canvas with two-finger scrolling or the mouse wheel, and zooms it with pinches and ⌘-scroll, all around
/// the pointer. SwiftUI has no gesture for raw scrolling, so this watches the window's events over its own frame.
struct ScrollWheelReader: NSViewRepresentable {
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                let isHandled = MainActor.assumeIsolated { self?.handle(event) == true }
                return isHandled ? nil : event
            }
        }

        /// - Returns: Whether the event was used.
        private func handle(_ event: NSEvent) -> Bool {
            guard let canvas, event.window === window else { return false }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return false }
            switch event.type {
            case .magnify:
                canvas.zoom(by: 1 + event.magnification, around: location)
            case .scrollWheel where event.modifierFlags.contains(.command):
                canvas.zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)), around: location)
            case .scrollWheel:
                // A mouse wheel reports lines, not points.
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                canvas.pan(by: CGPoint(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale))
            default:
                return false
            }
            return true
        }
    }
}
